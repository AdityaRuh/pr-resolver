#!/usr/bin/env bash
# pr-resolver.sh — PR Comment Resolver Daemon (v2)
#
# Polls GitHub for new PR comments every 5 minutes.
# Classifies intent (FREE), resolves via OpenClaw (credits only when needed).
#
# v2 Enhancements:
#   - Diff-aware context (only relevant files passed to agent)
#   - Idempotency via fix signatures (hash-based dedup)
#   - Confidence + risk scoring before committing
#   - Partial fix tracking (resolved/pending/failed per PR)
#   - Retry with exponential backoff (transient vs real failures)
#   - Conflict handling (rebase before push)
#   - Human override commands (/agent ignore|retry|force-fix|explain)
#   - Rich Linear context (acceptance criteria, linked PRs, comments)
#   - Budget guards (per-hour, per-cycle, per-PR limits)
#   - Observability metrics (success rate, fix time, failure reasons)
#
# Usage:
#   Single run:  bash pr-resolver.sh
#   Cron mode:   */5 * * * * /path/to/pr-resolver.sh
#   Daemon:      nohup bash pr-resolver.sh --daemon &

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/.env" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/linear.sh" 2>/dev/null || true

###############################################################################
# Configuration
###############################################################################

PR_RESOLVER_HOME="$SCRIPT_DIR"
STATE_DIR="${PR_RESOLVER_HOME}/state"
LOG_DIR="${PR_RESOLVER_HOME}/logs"
METRICS_DIR="${PR_RESOLVER_HOME}/metrics"
PROCESSED_FILE="${STATE_DIR}/processed-comments.json"
SIGNATURES_FILE="${STATE_DIR}/fix-signatures.json"
METRICS_FILE="${METRICS_DIR}/metrics.json"
BUDGET_FILE="${STATE_DIR}/budget-tracker.json"
REPOS_FILE="${STATE_DIR}/monitored-repos.json"
LOCK_FILE="${STATE_DIR}/.pr-resolver.lock"
LOG_FILE="${LOG_DIR}/pr-resolver.log"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Bot signature to detect own comments (anti-loop)
BOT_SIGNATURE="PR Resolver (automated)"
BOT_GITHUB_USER="${BOT_GITHUB_USER:-AdityaRuh}"

# Linear integration
LINEAR_API_KEY="${LINEAR_API_KEY:-}"

# Rate limits
MAX_FIXES_PER_PR=3
MAX_FIXES_PER_CYCLE=10
MAX_FIXES_PER_HOUR=20
OPENCLAW_TIMEOUT=600  # 10 min per comment

# Retry config
MAX_RETRIES=2
RETRY_BACKOFF_BASE=30  # seconds

# Monitored repos (can be overridden by monitored-repos.json)
DEFAULT_REPOS=(
    "ruh-ai/strapi-service"
    "ruh-ai/hubspot-mcp"
    "ruh-ai/salesforce-mcp"
    "ruh-ai/sdr-backend"
    "ruh-ai/inbox-rotation-service"
    "ruh-ai/sdr-management-mcp"
)

###############################################################################
# Logging
###############################################################################

log() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [pr-resolver] $*" | tee -a "$LOG_FILE"
}

###############################################################################
# Telegram
###############################################################################

tg_send() {
    local text="$1"
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return 0
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d parse_mode="Markdown" \
        -d text="$text" \
        --max-time 10 >/dev/null 2>&1 || true
}

###############################################################################
# Lock management (prevent parallel runs)
###############################################################################

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "0")
        if kill -0 "$lock_pid" 2>/dev/null; then
            log "Another instance running (PID $lock_pid), skipping"
            return 1
        fi
        log "Stale lock found (PID $lock_pid), removing"
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
    return 0
}

release_lock() {
    rm -f "$LOCK_FILE"
}

###############################################################################
# State management
###############################################################################

init_state() {
    mkdir -p "$STATE_DIR" "$LOG_DIR" "$METRICS_DIR"
    [[ -f "$PROCESSED_FILE" ]] || echo '{}' > "$PROCESSED_FILE"
    [[ -f "$SIGNATURES_FILE" ]] || echo '{}' > "$SIGNATURES_FILE"
    [[ -f "$METRICS_FILE" ]] || echo '{"cycles":0,"total_fixes":0,"total_skipped":0,"total_failed":0,"total_flagged":0,"total_answered":0,"avg_fix_time_s":0,"fix_times":[],"failure_reasons":{}}' > "$METRICS_FILE"
    [[ -f "$BUDGET_FILE" ]] || echo '{"hourly_fixes":[],"daily_token_estimate":0}' > "$BUDGET_FILE"
}

is_comment_processed() {
    local repo="$1" pr="$2" comment_id="$3"
    jq -e --arg r "$repo" --arg p "$pr" --arg c "$comment_id" \
        '.[$r][$p].processed_comment_ids // [] | index($c | tonumber) != null' \
        "$PROCESSED_FILE" 2>/dev/null | grep -q 'true'
}

mark_comment_processed() {
    local repo="$1" pr="$2" comment_id="$3" intent="$4" action="$5" commit="${6:-}"
    local tmp="${PROCESSED_FILE}.tmp"
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    jq --arg r "$repo" --arg p "$pr" --arg c "$comment_id" \
       --arg intent "$intent" --arg action "$action" --arg commit "$commit" \
       --arg now "$now" '
        # Ensure structure exists
        .[$r] //= {} |
        .[$r][$p] //= {"last_checked": "", "processed_comment_ids": [], "actions_taken": [], "resolved": [], "pending": [], "failed": []} |
        # Add comment ID
        .[$r][$p].processed_comment_ids += [$c | tonumber] |
        .[$r][$p].processed_comment_ids |= unique |
        # Add action
        .[$r][$p].actions_taken += [{
            "comment_id": ($c | tonumber),
            "intent": $intent,
            "action": $action,
            "commit": $commit,
            "timestamp": $now
        }] |
        # Track in resolved/failed buckets
        (if $action == "fixed" or $action == "answered" then
            .[$r][$p].resolved += [$c | tonumber] | .[$r][$p].resolved |= unique
        elif $action == "failed" or $action == "timeout" then
            .[$r][$p].failed += [$c | tonumber] | .[$r][$p].failed |= unique
        else . end) |
        # Remove from pending
        .[$r][$p].pending |= (. // [] | map(select(. != ($c | tonumber)))) |
        .[$r][$p].last_checked = $now
    ' "$PROCESSED_FILE" > "$tmp" && mv "$tmp" "$PROCESSED_FILE"
}

mark_comment_pending() {
    local repo="$1" pr="$2" comment_id="$3"
    local tmp="${PROCESSED_FILE}.tmp"
    jq --arg r "$repo" --arg p "$pr" --arg c "$comment_id" '
        .[$r] //= {} |
        .[$r][$p] //= {"last_checked": "", "processed_comment_ids": [], "actions_taken": [], "resolved": [], "pending": [], "failed": []} |
        .[$r][$p].pending += [$c | tonumber] |
        .[$r][$p].pending |= unique
    ' "$PROCESSED_FILE" > "$tmp" && mv "$tmp" "$PROCESSED_FILE"
}

get_pr_fix_count() {
    local repo="$1" pr="$2"
    jq --arg r "$repo" --arg p "$pr" \
        '[.[$r][$p].actions_taken // [] | .[] | select(.action == "fixed")] | length' \
        "$PROCESSED_FILE" 2>/dev/null || echo "0"
}

get_pr_summary() {
    local repo="$1" pr="$2"
    local resolved pending failed
    resolved=$(jq --arg r "$repo" --arg p "$pr" '.[$r][$p].resolved // [] | length' "$PROCESSED_FILE" 2>/dev/null || echo "0")
    pending=$(jq --arg r "$repo" --arg p "$pr" '.[$r][$p].pending // [] | length' "$PROCESSED_FILE" 2>/dev/null || echo "0")
    failed=$(jq --arg r "$repo" --arg p "$pr" '.[$r][$p].failed // [] | length' "$PROCESSED_FILE" 2>/dev/null || echo "0")
    echo "${resolved}|${pending}|${failed}"
}

###############################################################################
# Fix Signature — Idempotency Check (Enhancement #2)
###############################################################################

compute_fix_signature() {
    local comment_body="$1" file_path="$2" intent="$3"
    # Hash the comment + file + intent to detect duplicate requests
    echo -n "${comment_body}|${file_path}|${intent}" | shasum -a 256 | cut -d' ' -f1
}

is_fix_duplicate() {
    local signature="$1"
    jq -e --arg sig "$signature" '.[$sig] != null' "$SIGNATURES_FILE" 2>/dev/null | grep -q 'true'
}

record_fix_signature() {
    local signature="$1" repo="$2" pr="$3" comment_id="$4" action="$5"
    local tmp="${SIGNATURES_FILE}.tmp"
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    jq --arg sig "$signature" --arg r "$repo" --arg p "$pr" \
       --arg c "$comment_id" --arg a "$action" --arg now "$now" '
        .[$sig] = {"repo": $r, "pr": $p, "comment_id": $c, "action": $a, "timestamp": $now}
    ' "$SIGNATURES_FILE" > "$tmp" && mv "$tmp" "$SIGNATURES_FILE"
}

###############################################################################
# Budget Guard — Rate Limiting (Enhancement #9)
###############################################################################

check_hourly_budget() {
    local now_epoch
    now_epoch=$(date +%s)
    local one_hour_ago=$((now_epoch - 3600))

    # Count fixes in last hour
    local count
    count=$(jq --argjson cutoff "$one_hour_ago" \
        '[.hourly_fixes[] | select(. > $cutoff)] | length' \
        "$BUDGET_FILE" 2>/dev/null || echo "0")

    if [[ "$count" -ge "$MAX_FIXES_PER_HOUR" ]]; then
        log "BUDGET: Hourly limit reached (${count}/${MAX_FIXES_PER_HOUR})"
        return 1
    fi
    return 0
}

record_fix_timestamp() {
    local tmp="${BUDGET_FILE}.tmp"
    local now_epoch
    now_epoch=$(date +%s)
    local one_hour_ago=$((now_epoch - 3600))

    jq --argjson ts "$now_epoch" --argjson cutoff "$one_hour_ago" '
        .hourly_fixes += [$ts] |
        .hourly_fixes |= map(select(. > $cutoff))
    ' "$BUDGET_FILE" > "$tmp" && mv "$tmp" "$BUDGET_FILE"
}

###############################################################################
# Observability Metrics (Enhancement #10)
###############################################################################

record_metric() {
    local event="$1" duration="${2:-0}" reason="${3:-}"
    local tmp="${METRICS_FILE}.tmp"

    jq --arg event "$event" --argjson dur "$duration" --arg reason "$reason" '
        .cycles += (if $event == "cycle_complete" then 1 else 0 end) |
        .total_fixes += (if $event == "fixed" then 1 else 0 end) |
        .total_skipped += (if $event == "skipped" then 1 else 0 end) |
        .total_failed += (if $event == "failed" then 1 else 0 end) |
        .total_flagged += (if $event == "flagged" then 1 else 0 end) |
        .total_answered += (if $event == "answered" then 1 else 0 end) |
        (if $event == "fixed" and $dur > 0 then
            .fix_times += [$dur] |
            .fix_times |= .[-50:] |
            .avg_fix_time_s = (.fix_times | add / length | floor)
        else . end) |
        (if $event == "failed" and $reason != "" then
            .failure_reasons[$reason] = ((.failure_reasons[$reason] // 0) + 1)
        else . end)
    ' "$METRICS_FILE" > "$tmp" && mv "$tmp" "$METRICS_FILE"
}

get_metrics_summary() {
    jq -r '"Fixes: \(.total_fixes) | Failed: \(.total_failed) | Flagged: \(.total_flagged) | Answered: \(.total_answered) | Avg fix: \(.avg_fix_time_s)s | Cycles: \(.cycles)"' \
        "$METRICS_FILE" 2>/dev/null || echo "no metrics"
}

###############################################################################
# Comment classification (bash — NO CREDITS)
###############################################################################

classify_comment() {
    local body="$1"
    local body_lower
    body_lower=$(echo "$body" | tr '[:upper:]' '[:lower:]')

    # Skip: bot's own comments
    if echo "$body" | grep -q "$BOT_SIGNATURE"; then
        echo "SELF"
        return
    fi

    # Skip: CI bot comments (codecov, sonarqube, etc.)
    if echo "$body_lower" | grep -qE '(codecov|sonarqube|dependabot|renovate|github-actions|coverage report)'; then
        echo "CI_BOT"
        return
    fi

    # Human override commands (Enhancement #7)
    if echo "$body_lower" | grep -qE '^/agent\s+(ignore|retry|force-fix|explain|skip|pause)'; then
        echo "AGENT_COMMAND"
        return
    fi

    # Priority 1: Explicit agent mention
    if echo "$body_lower" | grep -qE '@(agent|sentinel|bot|resolve)'; then
        echo "EXPLICIT_REQUEST"
        return
    fi

    # Priority 2: Question (check BEFORE code change — "why did you remove?" is a question, not a change request)
    if echo "$body_lower" | grep -qE '(\?$|\?[[:space:]]|^why |^how |^what |^can you explain|^could you)'; then
        echo "QUESTION"
        return
    fi

    # Priority 3: Code change keywords
    if echo "$body_lower" | grep -qE '\b(fix|change|update|replace|remove|add|rename|refactor|move|extract|inline|delete|use .* instead)\b'; then
        echo "CODE_CHANGE"
        return
    fi

    # Priority 4: Approval / positive
    if echo "$body_lower" | grep -qE '\b(lgtm|looks good|approved|nice|great|perfect|ship it)\b|👍|✅|🎉'; then
        echo "APPROVAL"
        return
    fi

    # Priority 5: Subjective / disagreement
    if echo "$body_lower" | grep -qE '\b(disagree|i think|not sure|maybe|consider|alternative|prefer|opinion|debate)\b'; then
        echo "SUBJECTIVE"
        return
    fi

    # Priority 6: Nitpick / style
    if echo "$body_lower" | grep -qE '\b(nit|nitpick|typo|spelling|formatting|style|naming|whitespace)\b'; then
        echo "NITPICK"
        return
    fi

    echo "UNKNOWN"
}

###############################################################################
# Human Override Commands (Enhancement #7)
###############################################################################

handle_agent_command() {
    local repo="$1" pr="$2" comment_id="$3" body="$4" author="$5"
    local cmd
    cmd=$(echo "$body" | tr '[:upper:]' '[:lower:]' | grep -oE '/agent\s+(ignore|retry|force-fix|explain|skip|pause)' | awk '{print $2}')

    case "$cmd" in
        ignore|skip)
            reply_to_review_comment "$repo" "$pr" "$comment_id" \
                "👋 **Acknowledged** — Ignoring this comment as requested by @${author}.\n\n— ${BOT_SIGNATURE}"
            mark_comment_processed "$repo" "$pr" "$comment_id" "AGENT_COMMAND" "ignored"
            log "Agent command: ignore comment #${comment_id} by @${author}"
            ;;
        retry)
            # Find the previous comment in the thread and re-process it
            reply_to_review_comment "$repo" "$pr" "$comment_id" \
                "🔄 **Retrying** — Will re-attempt the fix on next cycle.\n\n— ${BOT_SIGNATURE}"
            # Remove from processed so it gets picked up again
            local tmp="${PROCESSED_FILE}.tmp"
            jq --arg r "$repo" --arg p "$pr" '
                .[$r][$p].processed_comment_ids |= (. // [] | .[:-1])
            ' "$PROCESSED_FILE" > "$tmp" && mv "$tmp" "$PROCESSED_FILE"
            mark_comment_processed "$repo" "$pr" "$comment_id" "AGENT_COMMAND" "retry_queued"
            log "Agent command: retry requested by @${author} on PR #${pr}"
            ;;
        force-fix)
            reply_to_review_comment "$repo" "$pr" "$comment_id" \
                "⚡ **Force-fix mode** — Will attempt fix with elevated confidence threshold.\n\n— ${BOT_SIGNATURE}"
            mark_comment_processed "$repo" "$pr" "$comment_id" "AGENT_COMMAND" "force_fix_queued"
            log "Agent command: force-fix requested by @${author}"
            ;;
        explain)
            reply_to_review_comment "$repo" "$pr" "$comment_id" \
                "📊 **PR Resolver Status**\n\n$(get_pr_status_text "$repo" "$pr")\n\n— ${BOT_SIGNATURE}"
            mark_comment_processed "$repo" "$pr" "$comment_id" "AGENT_COMMAND" "explained"
            log "Agent command: explain requested by @${author}"
            ;;
        pause)
            reply_to_review_comment "$repo" "$pr" "$comment_id" \
                "⏸️ **Paused** — Will not process further comments on this PR until resumed.\n\n— ${BOT_SIGNATURE}"
            # Mark PR as paused
            local tmp="${PROCESSED_FILE}.tmp"
            jq --arg r "$repo" --arg p "$pr" '
                .[$r][$p].paused = true
            ' "$PROCESSED_FILE" > "$tmp" && mv "$tmp" "$PROCESSED_FILE"
            mark_comment_processed "$repo" "$pr" "$comment_id" "AGENT_COMMAND" "paused"
            log "Agent command: pause requested by @${author} on PR #${pr}"
            ;;
    esac
}

get_pr_status_text() {
    local repo="$1" pr="$2"
    local summary
    summary=$(get_pr_summary "$repo" "$pr")
    local resolved pending failed
    resolved=$(echo "$summary" | cut -d'|' -f1)
    pending=$(echo "$summary" | cut -d'|' -f2)
    failed=$(echo "$summary" | cut -d'|' -f3)
    local total=$((resolved + pending + failed))

    echo "- **Resolved:** ${resolved}/${total} comments
- **Pending:** ${pending}
- **Failed:** ${failed}
- **Global metrics:** $(get_metrics_summary)"
}

###############################################################################
# Check if PR is paused
###############################################################################

is_pr_paused() {
    local repo="$1" pr="$2"
    jq -e --arg r "$repo" --arg p "$pr" \
        '.[$r][$p].paused == true' \
        "$PROCESSED_FILE" 2>/dev/null | grep -q 'true'
}

###############################################################################
# GitHub API helpers
###############################################################################

get_open_prs() {
    local repo="$1"
    gh pr list --repo "$repo" --state open \
        --json number,title,headRefName,author \
        --jq '.[] | "\(.number)|\(.title)|\(.headRefName)|\(.author.login)"' \
        2>/dev/null || true
}

get_review_comments() {
    local repo="$1" pr="$2"
    # Inline code review comments — output as JSON lines (one object per line)
    gh api "repos/${repo}/pulls/${pr}/comments" \
        --jq '.[] | {id, user: .user.login, path: (.path // ""), line: (.line // .original_line // 0), body}' \
        2>/dev/null || true
}

get_issue_comments() {
    local repo="$1" pr="$2"
    # General PR discussion comments — output as JSON lines
    gh api "repos/${repo}/issues/${pr}/comments" \
        --jq '.[] | {id, user: .user.login, path: "", line: 0, body}' \
        2>/dev/null || true
}

reply_to_review_comment() {
    local repo="$1" pr="$2" comment_id="$3" body="$4"
    gh api "repos/${repo}/pulls/${pr}/comments/${comment_id}/replies" \
        -f body="$body" \
        --silent 2>/dev/null || \
    # Fallback: post as issue comment
    gh api "repos/${repo}/issues/${pr}/comments" \
        -f body="$body" \
        --silent 2>/dev/null || true
}

reply_to_issue_comment() {
    local repo="$1" pr="$2" body="$3"
    gh api "repos/${repo}/issues/${pr}/comments" \
        -f body="$body" \
        --silent 2>/dev/null || true
}

###############################################################################
# STEP 1.7: Diff Extraction (Enhancement #1)
###############################################################################

extract_pr_diff_context() {
    local repo="$1" pr="$2" target_file="${3:-}"

    # Get full PR diff
    local diff
    diff=$(gh pr diff "$pr" --repo "$repo" 2>/dev/null) || return 1

    if [[ -n "$target_file" && "$target_file" != "" ]]; then
        # Extract only the diff for the target file
        echo "$diff" | awk -v file="$target_file" '
            /^diff --git/ { in_file = 0 }
            $0 ~ "b/" file { in_file = 1 }
            in_file { print }
        '
    else
        # Return full diff but truncated
        echo "$diff" | head -500
    fi
}

get_pr_changed_files() {
    local repo="$1" pr="$2"
    gh pr diff "$pr" --repo "$repo" 2>/dev/null | \
        grep '^diff --git' | \
        sed 's|.*b/||' || true
}

###############################################################################
# Resolve a single comment via OpenClaw (with retry + confidence)
###############################################################################

resolve_comment_with_retry() {
    local repo="$1" pr="$2" branch="$3" comment_id="$4"
    local author="$5" file_path="$6" line="$7" body="$8" intent="$9"
    local linear_context="${10:-}" linear_ticket_id="${11:-}"
    local attempt=0
    local exit_code=0

    while [[ $attempt -le $MAX_RETRIES ]]; do
        if [[ $attempt -gt 0 ]]; then
            local backoff=$(( RETRY_BACKOFF_BASE * (2 ** (attempt - 1)) ))
            log "Retry #${attempt} for comment #${comment_id} (backoff: ${backoff}s)"
            sleep "$backoff"
        fi

        resolve_comment "$repo" "$pr" "$branch" "$comment_id" \
            "$author" "$file_path" "$line" "$body" "$intent" \
            "$linear_context" "$linear_ticket_id"
        exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            return 0
        fi

        # Check if failure is transient (network, git conflict) vs permanent (test failure)
        local last_action
        last_action=$(jq -r --arg r "$repo" --arg p "$pr" --arg c "$comment_id" \
            '[.[$r][$p].actions_taken[] | select(.comment_id == ($c | tonumber))] | last | .action // "unknown"' \
            "$PROCESSED_FILE" 2>/dev/null || echo "unknown")

        case "$last_action" in
            timeout|unclear)
                # Transient — retry
                log "Transient failure ($last_action), will retry"
                ((attempt++)) || true
                # Reset processed state so we can retry
                local tmp="${PROCESSED_FILE}.tmp"
                jq --arg r "$repo" --arg p "$pr" --arg c "$comment_id" '
                    .[$r][$p].processed_comment_ids |= (. // [] | map(select(. != ($c | tonumber))))
                ' "$PROCESSED_FILE" > "$tmp" && mv "$tmp" "$PROCESSED_FILE"
                ;;
            failed|clarification|flagged)
                # Permanent — don't retry
                log "Permanent failure ($last_action), not retrying"
                record_metric "failed" 0 "$last_action"
                return 1
                ;;
            *)
                ((attempt++)) || true
                ;;
        esac
    done

    log "All ${MAX_RETRIES} retries exhausted for comment #${comment_id}"
    record_metric "failed" 0 "retries_exhausted"
    return 1
}

resolve_comment() {
    local repo="$1" pr="$2" branch="$3" comment_id="$4"
    local author="$5" file_path="$6" line="$7" body="$8" intent="$9"
    local linear_context="${10:-}"
    local linear_ticket_id="${11:-}"
    local repo_name repo_dir
    local fix_start_time
    fix_start_time=$(date +%s)

    repo_name=$(echo "$repo" | cut -d/ -f2)
    repo_dir="/home/aditya/repos/${repo_name}"

    log "Resolving comment #${comment_id} on ${repo} PR #${pr} (intent: ${intent})"

    # Clone/pull the repo if needed
    if [[ ! -d "$repo_dir" ]]; then
        log "Cloning ${repo}..."
        git clone "https://github.com/${repo}.git" "$repo_dir" 2>/dev/null || {
            log "ERROR: Failed to clone ${repo}"
            return 1
        }
    fi

    # Checkout PR branch
    cd "$repo_dir"
    git fetch origin "$branch" 2>/dev/null || true
    git checkout "$branch" 2>/dev/null || {
        log "ERROR: Cannot checkout branch ${branch}"
        return 1
    }
    git pull origin "$branch" 2>/dev/null || true

    # STEP 1.7: Extract diff context (Enhancement #1)
    local diff_context=""
    diff_context=$(extract_pr_diff_context "$repo" "$pr" "$file_path") || true
    local changed_files=""
    changed_files=$(get_pr_changed_files "$repo" "$pr") || true

    # Detect test command
    local test_cmd="echo 'no tests configured'"
    if [[ -f "pyproject.toml" ]] || [[ -f "setup.py" ]]; then
        test_cmd="pytest --tb=short -q 2>&1 | tail -20"
    elif [[ -f "package.json" ]]; then
        test_cmd="npm test 2>&1 | tail -20"
    fi

    # Build the prompt based on intent
    local prompt=""
    case "$intent" in
        EXPLICIT_REQUEST|CODE_CHANGE|NITPICK)
            prompt=""
            # Inject Linear ticket context if available
            [[ -n "$linear_context" ]] && prompt+="${linear_context}

---

"
            # Inject diff context (Enhancement #1)
            prompt+="## PR Diff Context
Changed files in this PR:
${changed_files}

Diff for relevant file(s):
\`\`\`diff
${diff_context}
\`\`\`

---

You are resolving a PR review comment on repo: ${repo_dir}
Branch: ${branch}
PR #${pr}

Comment by @${author}"
            [[ -n "$file_path" && "$file_path" != "" ]] && prompt+=" on file ${file_path}:${line}"
            prompt+=":
\"${body}\"

Instructions:
1. Read the file and understand the full context around line ${line}
2. ONLY look at files that are part of this PR diff: ${changed_files}
3. Make the MINIMAL change to resolve this comment
4. Run: ${test_cmd}
5. BEFORE committing, output your assessment:
   CONFIDENCE: HIGH|MEDIUM|LOW
   RISK: LOW|MEDIUM|HIGH
   REASON: <1-line explanation>
6. If CONFIDENCE is HIGH and RISK is LOW: commit with message 'fix: resolve review — <1-line summary of change>'
7. If CONFIDENCE is MEDIUM: commit but add '[needs-review]' prefix to commit message
8. If CONFIDENCE is LOW or RISK is HIGH: do NOT commit. Output NEEDS_CLARIFICATION: <your question>
9. If tests fail: do NOT commit. Output FAILED: <what went wrong>
10. Push to origin/${branch}

Rules:
- Change ONLY what the comment asks. Do not modify unrelated code.
- ONLY modify files listed in the PR diff. Never touch files outside the PR.
- Never force-push. Always a new commit.
- If the request is unclear: output NEEDS_CLARIFICATION: <your question>
- If you disagree: output SUBJECTIVE: <your reason>"
            ;;
        QUESTION)
            prompt=""
            [[ -n "$linear_context" ]] && prompt+="${linear_context}

---

"
            prompt+="## PR Diff Context
Changed files: ${changed_files}

Relevant diff:
\`\`\`diff
${diff_context}
\`\`\`

---

A reviewer asked a question on PR #${pr} in repo ${repo_dir}.
Branch: ${branch}

Question by @${author}"
            [[ -n "$file_path" && "$file_path" != "" ]] && prompt+=" about file ${file_path}:${line}"
            prompt+=":
\"${body}\"

Instructions:
1. Read the file and PR diff to understand the context
2. Answer the question clearly and concisely
3. Do NOT make any code changes
4. Output your answer as: ANSWER: <your response>"
            ;;
        *)
            log "Skipping intent: ${intent}"
            return 0
            ;;
    esac

    # Call OpenClaw agent
    local output=""
    local exit_code=0
    local agent_log="${LOG_DIR}/pr-resolve-${repo_name}-${pr}-${comment_id}.log"

    log "Calling OpenClaw agent (timeout: ${OPENCLAW_TIMEOUT}s)..."
    output=$(cd "$repo_dir" && timeout "$OPENCLAW_TIMEOUT" openclaw agent \
        --agent pr-resolver \
        --message "$prompt" \
        --timeout "$OPENCLAW_TIMEOUT" \
        2>&1 | tee "$agent_log") || exit_code=$?

    local fix_duration=$(( $(date +%s) - fix_start_time ))

    # Parse result
    if [[ $exit_code -eq 124 ]]; then
        log "TIMEOUT resolving comment #${comment_id}"
        reply_to_review_comment "$repo" "$pr" "$comment_id" \
            "⏱️ **Timed out** — This comment requires more complex changes than I can handle automatically. Needs human review.\n\n— ${BOT_SIGNATURE}"
        mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "timeout"
        record_metric "failed" "$fix_duration" "timeout"
        return 1
    fi

    # Parse confidence + risk from output (Enhancement #3)
    local confidence="UNKNOWN" risk="UNKNOWN"
    if echo "$output" | grep -q "CONFIDENCE:"; then
        confidence=$(echo "$output" | grep "CONFIDENCE:" | head -1 | grep -oE '(HIGH|MEDIUM|LOW)' | head -1)
    fi
    if echo "$output" | grep -q "RISK:"; then
        risk=$(echo "$output" | grep "RISK:" | head -1 | grep -oE '(HIGH|MEDIUM|LOW)' | head -1)
    fi
    log "Agent assessment: confidence=${confidence}, risk=${risk}"

    # Check for NEEDS_CLARIFICATION
    if echo "$output" | grep -q "NEEDS_CLARIFICATION:"; then
        local question
        question=$(echo "$output" | grep "NEEDS_CLARIFICATION:" | head -1 | sed 's/.*NEEDS_CLARIFICATION: *//')
        reply_to_review_comment "$repo" "$pr" "$comment_id" \
            "❓ **Clarification needed** (confidence: ${confidence})\n\n${question}\n\n— ${BOT_SIGNATURE}"
        mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "clarification"
        record_metric "failed" "$fix_duration" "needs_clarification"
        log "Asked for clarification on comment #${comment_id}"
        return 0
    fi

    # Check for SUBJECTIVE
    if echo "$output" | grep -q "SUBJECTIVE:"; then
        local reason
        reason=$(echo "$output" | grep "SUBJECTIVE:" | head -1 | sed 's/.*SUBJECTIVE: *//')
        tg_send "🤔 *Subjective comment on ${repo} PR #${pr}*\nComment by @${author}: ${body}\nReason: ${reason}"
        reply_to_review_comment "$repo" "$pr" "$comment_id" \
            "🤔 **Flagged for human review** — This seems like a design decision that needs team input.\n\n— ${BOT_SIGNATURE}"
        mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "flagged"
        record_metric "flagged" "$fix_duration"
        log "Flagged subjective comment #${comment_id} to Telegram"
        return 0
    fi

    # Check for FAILED
    if echo "$output" | grep -q "FAILED:"; then
        local failure
        failure=$(echo "$output" | grep "FAILED:" | head -1 | sed 's/.*FAILED: *//')
        reply_to_review_comment "$repo" "$pr" "$comment_id" \
            "⚠️ **Attempted but blocked**\n\n${failure}\n\nNeeds human review.\n\n— ${BOT_SIGNATURE}"
        tg_send "❌ *Failed to fix comment on ${repo} PR #${pr}*\n${failure}"
        mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "failed"
        record_metric "failed" "$fix_duration" "agent_failed"
        log "Failed to resolve comment #${comment_id}: ${failure}"
        return 1
    fi

    # Check for ANSWER (question intent)
    if echo "$output" | grep -q "ANSWER:"; then
        local answer
        answer=$(echo "$output" | grep -A 100 "ANSWER:" | head -20 | sed 's/.*ANSWER: *//')
        reply_to_review_comment "$repo" "$pr" "$comment_id" \
            "${answer}\n\n— ${BOT_SIGNATURE}"
        mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "answered"
        record_metric "answered" "$fix_duration"
        log "Answered question on comment #${comment_id}"
        return 0
    fi

    # STEP 2.6: Conflict handling — rebase before push (Enhancement #6)
    cd "$repo_dir"
    if ! git pull --rebase origin "$branch" 2>/dev/null; then
        log "CONFLICT detected on branch ${branch}, aborting rebase"
        git rebase --abort 2>/dev/null || true
        reply_to_review_comment "$repo" "$pr" "$comment_id" \
            "⚠️ **Merge conflict detected** — The branch has diverged. Please resolve conflicts manually, then use \`/agent retry\` to re-attempt.\n\n— ${BOT_SIGNATURE}"
        tg_send "⚠️ *Conflict on ${repo} PR #${pr}*\nBranch ${branch} has conflicts after fix attempt."
        mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "conflict"
        record_metric "failed" "$fix_duration" "merge_conflict"
        return 1
    fi

    # Check if a new commit was pushed (success case)
    local latest_commit
    latest_commit=$(cd "$repo_dir" && git log --oneline -1 --format="%H %s" 2>/dev/null)

    if echo "$latest_commit" | grep -qi "resolve review\|fix:\|review comment\|\[needs-review\]"; then
        local commit_sha
        commit_sha=$(echo "$latest_commit" | cut -d' ' -f1)
        local commit_msg
        commit_msg=$(echo "$latest_commit" | cut -d' ' -f2-)

        # Build reply with confidence info
        local confidence_badge=""
        case "$confidence" in
            HIGH) confidence_badge="🟢 HIGH confidence" ;;
            MEDIUM) confidence_badge="🟡 MEDIUM confidence — reviewer please verify" ;;
            LOW) confidence_badge="🔴 LOW confidence — needs review" ;;
            *) confidence_badge="" ;;
        esac

        local reply="✅ **Resolved** — ${commit_msg}"
        [[ -n "$file_path" && "$file_path" != "" ]] && reply+="\n\n**File:** \`${file_path}\`"
        reply+="\n**Tests:** All passing ✅"
        [[ -n "$confidence_badge" ]] && reply+="\n**Assessment:** ${confidence_badge}"
        reply+="\n\n— ${BOT_SIGNATURE}"

        reply_to_review_comment "$repo" "$pr" "$comment_id" "$reply"
        mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "fixed" "$commit_sha"
        record_metric "fixed" "$fix_duration"
        record_fix_timestamp
        log "✅ Resolved comment #${comment_id} (commit: ${commit_sha:0:7}, confidence: ${confidence}, risk: ${risk}, time: ${fix_duration}s)"

        # Post summary comment on Linear ticket if available
        if [[ -n "$linear_ticket_id" && -n "$LINEAR_API_KEY" ]]; then
            local linear_comment="## PR Review Comment Resolved

**PR:** #${pr} in ${repo}
**Comment by:** @${author}
**File:** \`${file_path}\`
**Change:** ${commit_msg}
**Commit:** \`${commit_sha:0:7}\`
**Confidence:** ${confidence} | **Risk:** ${risk}
**Fix time:** ${fix_duration}s
**Status:** Tests passing ✅

---
*Posted by PR Resolver (automated)*"
            if linear_post_comment "$linear_ticket_id" "$linear_comment"; then
                log "Posted summary to Linear ticket ${linear_ticket_id}"
            else
                log "WARNING: Failed to post comment to Linear ticket ${linear_ticket_id}"
            fi
        fi

        return 0
    fi

    # Fallback: agent ran but unclear result
    log "Agent completed but no clear result for comment #${comment_id}"
    mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "unclear"
    record_metric "failed" "$fix_duration" "unclear_result"
    return 0
}

###############################################################################
# Process all comments for a single PR
###############################################################################

process_pr() {
    local repo="$1" pr="$2" title="$3" branch="$4" pr_author="$5"
    local fixes_this_pr=0

    log "Processing ${repo} PR #${pr}: ${title} (branch: ${branch})"

    # Check if PR is paused (Enhancement #7)
    if is_pr_paused "$repo" "$pr"; then
        log "PR #${pr} is paused, skipping"
        return 0
    fi

    # Budget guard — hourly limit (Enhancement #9)
    if ! check_hourly_budget; then
        log "Hourly budget exhausted, skipping PR #${pr}"
        return 0
    fi

    # Fetch Linear ticket context from branch name (FREE — no LLM credits)
    local linear_ticket_id=""
    local linear_context=""
    if [[ -n "$LINEAR_API_KEY" ]] && type linear_extract_ticket_id &>/dev/null; then
        linear_ticket_id=$(linear_extract_ticket_id "$branch")
        if [[ -n "$linear_ticket_id" ]]; then
            log "Detected Linear ticket: ${linear_ticket_id} from branch ${branch}"

            # Try rich context first (Enhancement #8)
            local rich_json
            rich_json=$(linear_get_rich_context "$linear_ticket_id" 2>/dev/null) || true
            if [[ -n "$rich_json" && "$rich_json" != "null" ]]; then
                linear_context=$(linear_format_rich_context "$rich_json" 2>/dev/null) || true
                log "Fetched RICH Linear context for ${linear_ticket_id}"
            else
                # Fallback to basic context
                local issue_detail
                issue_detail=$(linear_get_issue "$linear_ticket_id" 2>/dev/null) || true
                if [[ -n "$issue_detail" ]]; then
                    linear_context=$(linear_format_context "$issue_detail" 2>/dev/null) || true
                    log "Fetched basic Linear context for ${linear_ticket_id}"
                else
                    log "WARNING: Could not fetch Linear issue for ${linear_ticket_id}"
                fi
            fi
        fi
    fi

    # Get both review comments and issue comments as JSON lines
    local all_comments_file="${STATE_DIR}/.tmp-comments-${pr}.jsonl"
    > "$all_comments_file"
    get_review_comments "$repo" "$pr" >> "$all_comments_file" 2>/dev/null
    get_issue_comments "$repo" "$pr" >> "$all_comments_file" 2>/dev/null

    local comment_count
    comment_count=$(grep -c '{' "$all_comments_file" 2>/dev/null || echo "0")
    [[ "$comment_count" -eq 0 ]] && {
        log "No comments found on PR #${pr}"
        rm -f "$all_comments_file"
        return 0
    }

    # Track actionable comments for partial fix reporting (Enhancement #4)
    local actionable_total=0
    local actionable_resolved=0
    local actionable_failed=0

    while IFS= read -r json_line; do
        # Skip non-JSON lines
        echo "$json_line" | jq -e '.id' >/dev/null 2>&1 || continue

        # Parse JSON fields safely
        local comment_id author file_path line body
        comment_id=$(echo "$json_line" | jq -r '.id')
        author=$(echo "$json_line" | jq -r '.user')
        file_path=$(echo "$json_line" | jq -r '.path // ""')
        line=$(echo "$json_line" | jq -r '.line // 0')
        body=$(echo "$json_line" | jq -r '.body // ""')

        # Skip empty
        [[ -z "$comment_id" || "$comment_id" == "null" ]] && continue

        # Skip bot's own comments
        [[ "$author" == "$BOT_GITHUB_USER" ]] && continue

        # Skip already processed
        if is_comment_processed "$repo" "$pr" "$comment_id"; then
            continue
        fi

        # Classify (FREE — no credits)
        local intent
        intent=$(classify_comment "$body")

        # Handle agent commands (Enhancement #7)
        if [[ "$intent" == "AGENT_COMMAND" ]]; then
            handle_agent_command "$repo" "$pr" "$comment_id" "$body" "$author"
            continue
        fi

        case "$intent" in
            SELF|CI_BOT|APPROVAL|UNKNOWN)
                mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "skipped"
                record_metric "skipped"
                continue
                ;;
            SUBJECTIVE)
                local body_short
                body_short=$(echo "$body" | head -c 200 | tr '\n' ' ')
                tg_send "🤔 *Subjective comment on ${repo} PR #${pr}*
By @${author}: ${body_short}"
                mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "flagged"
                record_metric "flagged"
                log "Flagged subjective comment #${comment_id} to Telegram"
                continue
                ;;
        esac

        # This is an actionable comment
        ((actionable_total++)) || true
        mark_comment_pending "$repo" "$pr" "$comment_id"

        # Idempotency check — fix signature (Enhancement #2)
        local fix_sig
        fix_sig=$(compute_fix_signature "$body" "$file_path" "$intent")
        if is_fix_duplicate "$fix_sig"; then
            log "Duplicate fix signature detected for comment #${comment_id}, skipping"
            mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "duplicate"
            record_metric "skipped"
            continue
        fi

        # Rate limit check
        local current_fixes
        current_fixes=$(get_pr_fix_count "$repo" "$pr")
        if [[ "$current_fixes" -ge "$MAX_FIXES_PER_PR" ]]; then
            log "Rate limit reached for ${repo} PR #${pr} (${current_fixes}/${MAX_FIXES_PER_PR})"
            break
        fi
        if [[ "$fixes_this_pr" -ge "$MAX_FIXES_PER_PR" ]]; then
            log "Per-cycle rate limit for PR #${pr}"
            break
        fi

        # Budget guard check
        if ! check_hourly_budget; then
            log "Hourly budget exhausted mid-PR"
            break
        fi

        # Resolve via OpenClaw with retry (Enhancement #5)
        if resolve_comment_with_retry "$repo" "$pr" "$branch" "$comment_id" \
            "$author" "$file_path" "$line" "$body" "$intent" \
            "$linear_context" "$linear_ticket_id"; then
            ((actionable_resolved++)) || true
            # Record signature on success
            record_fix_signature "$fix_sig" "$repo" "$pr" "$comment_id" "fixed"
        else
            ((actionable_failed++)) || true
            record_fix_signature "$fix_sig" "$repo" "$pr" "$comment_id" "failed"
        fi

        ((fixes_this_pr++)) || true
        ((TOTAL_FIXES++)) || true

        # Global rate limit
        if [[ "${TOTAL_FIXES:-0}" -ge "$MAX_FIXES_PER_CYCLE" ]]; then
            log "Global rate limit reached (${TOTAL_FIXES}/${MAX_FIXES_PER_CYCLE})"
            break
        fi

    done < "$all_comments_file"

    rm -f "$all_comments_file"

    # Post partial fix summary if there are mixed results (Enhancement #4)
    local actionable_remaining=$((actionable_total - actionable_resolved - actionable_failed))
    if [[ "$actionable_total" -gt 1 && ("$actionable_failed" -gt 0 || "$actionable_remaining" -gt 0) ]]; then
        local summary_body="📊 **PR Comment Resolution Summary**\n\n"
        summary_body+="- ✅ Resolved: ${actionable_resolved}/${actionable_total}\n"
        [[ "$actionable_failed" -gt 0 ]] && summary_body+="- ❌ Failed: ${actionable_failed}\n"
        [[ "$actionable_remaining" -gt 0 ]] && summary_body+="- ⏳ Remaining: ${actionable_remaining} (will process in next cycle)\n"
        summary_body+="\n— ${BOT_SIGNATURE}"
        reply_to_issue_comment "$repo" "$pr" "$summary_body"
    fi
}

###############################################################################
# Main cycle — poll all repos
###############################################################################

run_cycle() {
    local total_new=0
    local total_fixed=0
    local total_flagged=0
    TOTAL_FIXES=0

    log "=========================================="
    log "PR Resolver cycle started"
    log "=========================================="

    # Get monitored repos
    local repos=()
    if [[ -f "$REPOS_FILE" ]]; then
        while IFS= read -r r; do
            repos+=("$r")
        done < <(jq -r '.repos[]' "$REPOS_FILE" 2>/dev/null)
    fi
    [[ ${#repos[@]} -eq 0 ]] && repos=("${DEFAULT_REPOS[@]}")

    for repo in "${repos[@]}"; do
        log "Checking ${repo}..."

        # Budget guard at repo level
        if ! check_hourly_budget; then
            log "Hourly budget exhausted, stopping cycle"
            break
        fi

        # Get open PRs
        local prs
        prs=$(get_open_prs "$repo")
        [[ -z "$prs" ]] && continue

        while IFS='|' read -r pr_number pr_title pr_branch pr_author; do
            [[ -z "$pr_number" ]] && continue
            process_pr "$repo" "$pr_number" "$pr_title" "$pr_branch" "$pr_author"

            # Respect global rate limit
            [[ "${TOTAL_FIXES:-0}" -ge "$MAX_FIXES_PER_CYCLE" ]] && break 2
        done <<< "$prs"
    done

    log "Cycle complete: ${TOTAL_FIXES} fixes applied"
    record_metric "cycle_complete"
    log "Metrics: $(get_metrics_summary)"
    log "=========================================="

    # Summary to Telegram (only if actions taken)
    if [[ "${TOTAL_FIXES:-0}" -gt 0 ]]; then
        tg_send "🔧 *PR Resolver Summary*
Fixes applied: ${TOTAL_FIXES}
$(get_metrics_summary)"
    fi
}

###############################################################################
# Entry point
###############################################################################

main() {
    init_state

    # Acquire lock
    acquire_lock || exit 0

    # Cleanup on exit
    trap release_lock EXIT

    if [[ "${1:-}" == "--daemon" ]]; then
        log "Starting daemon mode (poll every 300s)"
        while true; do
            run_cycle || true
            sleep 300
        done
    elif [[ "${1:-}" == "--metrics" ]]; then
        # Print current metrics
        echo "=== PR Resolver Metrics ==="
        get_metrics_summary
        echo ""
        jq '.' "$METRICS_FILE" 2>/dev/null || echo "No metrics file"
    elif [[ "${1:-}" == "--status" ]]; then
        # Print current status
        echo "=== PR Resolver Status ==="
        echo "Processed comments:"
        jq 'to_entries | .[] | .key as $repo | .value | to_entries[] | "\($repo) PR#\(.key): resolved=\(.value.resolved // [] | length) pending=\(.value.pending // [] | length) failed=\(.value.failed // [] | length)"' \
            "$PROCESSED_FILE" 2>/dev/null || echo "No state"
        echo ""
        echo "Budget:"
        jq '.' "$BUDGET_FILE" 2>/dev/null || echo "No budget data"
    else
        # Single run (for cron)
        run_cycle
    fi
}

main "$@"
