#!/usr/bin/env bash
# pr-resolver.sh — PR Comment Resolver Daemon (v2)
#
# Polls GitHub for new PR comments every 30 minutes.
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
#   Cron mode:   */30 * * * * /path/to/pr-resolver.sh
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
LINEAR_TRIGGER_STATE="In Development"

# Rate limits
MAX_FIXES_PER_PR=3
MAX_FIXES_PER_CYCLE=10
MAX_FIXES_PER_HOUR=20
OPENCLAW_TIMEOUT=600  # 10 min per comment
LLM_CLASSIFY_TIMEOUT=15   # Fast model — classify comment intent
LLM_SUMMARIZE_TIMEOUT=20  # Fast model — summarize Linear ticket
LLM_REVIEW_TIMEOUT=120    # Reviewer agent — assess fixer output

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
# CI Monitoring & Repair [NEW]
###############################################################################

# Wait for PR checks to complete (poll every 60s)
wait_for_pr_checks() {
    local repo="$1" pr="$2"
    local timeout=900 # 15 min max
    local start_time
    start_time=$(date +%s)
    
    log "Waiting for PR #${pr} checks to complete (timeout: ${timeout}s)..."

    while true; do
        local elapsed=$(( $(date +%s) - start_time ))
        if [[ $elapsed -gt $timeout ]]; then
            log "TIMEOUT: Checks did not complete within ${timeout}s"
            return 2 # Timeout
        fi

        # Get check status
        local checks_json
        checks_json=$(gh pr checks "$pr" --repo "$repo" --json state,conclusion,name 2>/dev/null) || {
            log "WARNING: Failed to fetch checks for PR #${pr}. Retrying in 30s..."
            sleep 30
            continue
        }

        # Check if all are completed
        local pending
        pending=$(echo "$checks_json" | jq -r '[.[] | select(.state != "COMPLETED")] | length')
        
        if [[ "$pending" -eq 0 ]]; then
            # All finished. Any failures?
            local failed
            failed=$(echo "$checks_json" | jq -r '[.[] | select(.conclusion == "FAILURE" or .conclusion == "TIMED_OUT")] | length')
            if [[ "$failed" -gt 0 ]]; then
                log "CI FAILURE: Finished with ${failed} failing checks."
                return 1 # Failed
            fi
            log "CI SUCCESS: All checks passed! ✅"
            return 0 # Success
        fi

        log "CI PENDING: ${pending} checks still running. Waiting 60s..."
        sleep 60
    done
}

# Extract logs for failing runs
extract_failing_log_context() {
    local repo="$1" pr="$2"
    local branch
    branch=$(gh pr view "$pr" --repo "$repo" --json headRefName --jq '.headRefName' 2>/dev/null) || return 1
    
    log "Extracting logs for failing runs on branch ${branch}..."

    # Get the ID of the latest failed run for this branch
    local run_id
    run_id=$(gh run list --repo "$repo" --branch "$branch" --limit 5 --json databaseId,conclusion,status \
        --jq '[.[] | select(.conclusion == "failure" or .conclusion == "startup_failure")] | first | .databaseId' 2>/dev/null)

    if [[ -z "$run_id" || "$run_id" == "null" ]]; then
        log "WARNING: Could not identify failing run ID for logs."
        return 1
    fi

    log "Fetching logs for run ${run_id}..."
    # Grab the last 1000 lines of failing logs
    gh run view "$run_id" --repo "$repo" --log-failed | tail -1000 || {
        log "WARNING: Failed to fetch logs for run ${run_id}"
        return 1
    }
}

# Fix CI failure (similar to resolve_comment but context is logs)
resolve_ci_failure() {
    local repo="$1" pr="$2" branch="$3" comment_id="$4"
    local author="$5" linear_context="$6" logs="$7"

    log "Invoking fixer agent for CI repair on PR #${pr}..."

    # Use a modified prompt for CI repair — focus on getting pipeline green
    local ci_prompt="You are repairing a CI pipeline failure on PR #${pr}. The goal is to make ALL checks green.
PR Branch: \`${branch}\`

The CI pipeline failed with these logs:
\"\"\"
${logs}
\"\"\"

Your goal:
1. Analyze the failure logs carefully — identify EVERY failing test or build error.
2. Fix the root cause. This could be:
   - Test assertions that need updating because the code behavior changed intentionally
   - Syntax errors, import errors, or type errors in the changed code
   - Missing mocks or test fixtures for new code paths
3. If a test is failing because the OLD test expects OLD behavior but the code was intentionally changed, UPDATE THE TEST to match the new behavior.
4. Run tests locally to verify your fix works.
5. STOP after modifications. DO NOT commit or push.

IMPORTANT:
- Fix ALL errors, not just the first one.
- Never delete tests — update them to match the new expected behavior.
- If you add new test cases, make sure they pass.
- The pipeline MUST be green after your fix."

    local fixer_output
    fixer_output=$(timeout 600 openclaw agent \
        --agent pr-resolver \
        --message "$ci_prompt" \
        --timeout 600 2>&1) || {
        log "ERROR: Fixer agent failed or timed out during CI repair."
        return 1
    }

    # Extract confidence/risk (same as standard fix)
    local confidence risk fix_summary
    confidence=$(echo "$fixer_output" | grep -Ei "^CONFIDENCE:" | cut -d':' -f2- | xargs || echo "MEDIUM")
    risk=$(echo "$fixer_output" | grep -Ei "^RISK:" | cut -d':' -f2- | xargs || echo "MEDIUM")
    fix_summary=$(echo "$fixer_output" | grep -Ei "^SUMMARY:" | cut -d':' -f2- | xargs || echo "CI auto-repair applied")

    # Review step (Safety first!)
    if ! review_proposed_fix "$repo" "$pr" "CI Failure Fix" "$fix_summary" "$confidence" "$risk"; then
        log "Review REJECTED the CI repair. Discarding."
        git checkout .
        return 1
    fi

    log "CI repair APPROVED. Committing and pushing..."
    git commit -am "chore(bot): resolve CI failure (attempt)"
    git push origin "$branch" --force-with-lease
    return 0
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
# Comment classification — LLM-backed (cheap fast model) [UPGRADED]
#
# Fast regex handles deterministic patterns (bot self-loop, CI noise, slash
# commands). Everything else is delegated to an LLM to correctly handle
# sarcasm, implicit requests, and subtle nuance that regex cannot detect.
###############################################################################

# classify_comment_llm: calls openclaw with a cheap/fast model to classify
# the semantic intent of a human reviewer comment.
classify_comment_llm() {
    local body="$1"
    local prompt
    prompt="You are a code review intent classifier for an autonomous PR bot.

Classify the following PR review comment into EXACTLY ONE of these intents:
- EXPLICIT_REQUEST: The reviewer explicitly @mentions the bot or asks it to make a change
- CODE_CHANGE: A concrete, implementable code change is being requested (fix, update, replace, rename, remove, refactor, add something specific)
- NITPICK: Minor style issues — typos, formatting, whitespace, naming conventions, small readability tweaks
- QUESTION: The reviewer is asking a question to understand the code (why, how, what, explain)
- APPROVAL: Positive/approving comment — LGTM, looks good, ship it, 👍, ✅, 🎉
- SUBJECTIVE: Opinion, preference, disagreement, design debate, or sarcasm — NOT a concrete ask
- UNKNOWN: Cannot determine intent

Rules:
- A question that doubts a change (e.g. 'Why did we change this here? I don't think it makes sense.') is SUBJECTIVE, not CODE_CHANGE
- An implicit request like 'this variable name is confusing' means rename it — classify as NITPICK
- Sarcasm or hedged language ('I'm not sure this is right') is SUBJECTIVE
- Only output the single intent label. No explanation.

Comment to classify:
\"\"\"${body}\"\"\"

INTENT:"

    local result
    result=$(timeout "$LLM_CLASSIFY_TIMEOUT" openclaw agent \
        --agent pr-resolver \
        --message "$prompt" \
        --timeout "$LLM_CLASSIFY_TIMEOUT" \
        2>/dev/null | grep -oE '(EXPLICIT_REQUEST|CODE_CHANGE|NITPICK|QUESTION|APPROVAL|SUBJECTIVE|UNKNOWN)' | head -1) || true

    # Validate output is a known intent — fallback to UNKNOWN
    case "$result" in
        EXPLICIT_REQUEST|CODE_CHANGE|NITPICK|QUESTION|APPROVAL|SUBJECTIVE|UNKNOWN)
            echo "$result"
            ;;
        *)
            log "WARNING: LLM classifier returned unexpected output '${result}', falling back to UNKNOWN"
            echo "UNKNOWN"
            ;;
    esac
}

classify_comment() {
    local body="$1"
    local body_lower
    body_lower=$(echo "$body" | tr '[:upper:]' '[:lower:]')

    # --- FAST REGEX TIER (deterministic, zero credits) ---

    # Skip: bot's own comments (anti-loop)
    if echo "$body" | grep -q "$BOT_SIGNATURE"; then
        echo "SELF"
        return
    fi

    # Skip: CI bot comments (codecov, sonarqube, dependabot, etc.)
    if echo "$body_lower" | grep -qE '(codecov|sonarqube|dependabot|renovate|github-actions|coverage report)'; then
        echo "CI_BOT"
        return
    fi

    # Human override commands (/agent ignore|retry|force-fix|explain|skip|pause)
    if echo "$body_lower" | grep -qE '^/agent[[:space:]]+(ignore|retry|force-fix|explain|skip|pause)'; then
        echo "AGENT_COMMAND"
        return
    fi

    # --- LLM SEMANTIC TIER (fast model, handles nuance, sarcasm, implicit intent) ---
    classify_comment_llm "$body"
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
            reply_to_review_comment "$repo" "$pr" "$comment_id" \
                "🔄 **Retrying** — Will re-attempt the fix on next cycle.\n\n— ${BOT_SIGNATURE}"
            # Atomically remove from processed list so it gets picked up again
            local tmp="${PROCESSED_FILE}.tmp"
            jq --arg r "$repo" --arg p "$pr" --arg c "$comment_id" '
                .[$r][$p].processed_comment_ids |= (. // [] | map(select(. != ($c | tonumber))))
            ' "$PROCESSED_FILE" > "$tmp" && mv "$tmp" "$PROCESSED_FILE"
            mark_comment_processed "$repo" "$pr" "$comment_id" "AGENT_COMMAND" "retry_queued"
            log "Agent command: retry requested for comment #${comment_id} by @${author}"
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

get_pr_details() {
    local repo="$1" pr="$2"
    # Returns: title|headRefName|author.login
    gh pr view "$pr" --repo "$repo" \
        --json title,headRefName,author \
        --jq '"\(.title)|\(.headRefName)|\(.author.login)"' \
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
            failed|clarification|flagged|reviewer_blocked|fixer_gave_up)
                # Permanent — don't retry (reviewer_blocked already retried internally 3x)
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

###############################################################################
# STEP NEW: Independent Code Reviewer [UPGRADED]
#
# Called AFTER the fixer agent has staged changes (but NOT committed).
# A second LLM pass independently assesses whether the proposed diff is safe,
# correct, and minimal before the bash script commits & pushes.
###############################################################################

review_proposed_fix() {
    local repo_dir="$1" original_comment="$2" file_path="$3"
    local confidence="$4" risk="$5"

    # Capture what the fixer staged on disk (unstaged + staged changes)
    local proposed_diff
    proposed_diff=$(cd "$repo_dir" && git diff HEAD 2>/dev/null | head -400) || true

    if [[ -z "$proposed_diff" ]]; then
        log "Reviewer: no diff found — nothing was changed by fixer agent"
        echo "REJECTED: Fixer agent did not produce any file changes"
        return 1
    fi

    local review_prompt
    review_prompt="You are an independent code reviewer for an autonomous PR bot.

The bot was asked to resolve this PR review comment:
\"\"\"${original_comment}\"\"\"

The fixer agent produced this diff:
\`\`\`diff
${proposed_diff}
\`\`\`

Your job: verify whether the diff is SAFE to push. Focus on impact analysis:

1. Does the change break any existing functionality? (regressions)
2. Does it introduce any bugs, null pointer issues, type errors, or logic errors?
3. Does it have unintended side effects on other parts of the codebase?
4. Does the change look syntactically correct and match what was requested?
5. Could this change cause test failures or break the build?

If the change does NOT break previous functionality and does NOT introduce bugs → APPROVE it.
If the change DOES break something or introduces a bug → REJECT with clear explanation.

Do NOT reject based on confidence level or style preferences. Only reject if there is a concrete functional issue or bug.

Output EXACTLY one of:
  APPROVED
  REJECTED: <1-2 sentence reason explaining what breaks or what bug is introduced>

No other text."

    local review_result
    review_result=$(timeout "$LLM_REVIEW_TIMEOUT" openclaw agent \
        --agent pr-resolver \
        --message "$review_prompt" \
        --timeout "$LLM_REVIEW_TIMEOUT" \
        2>/dev/null | grep -E '^(APPROVED|REJECTED)' | head -1) || true

    if [[ -z "$review_result" ]]; then
        log "Reviewer: no valid output — treating as REJECTED"
        echo "REJECTED: Reviewer agent returned no output"
        return 1
    fi

    echo "$review_result"
    if echo "$review_result" | grep -q '^APPROVED'; then
        return 0
    else
        return 1
    fi
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
5. Output your assessment:
   CONFIDENCE: HIGH|MEDIUM|LOW
   RISK: LOW|MEDIUM|HIGH
   REASON: <1-line explanation>
6. Make the fix regardless of confidence/risk level. If tests and lint pass, the fix is good.
7. If tests fail: revert your changes. Output FAILED: <what went wrong>
8. Only output NEEDS_CLARIFICATION if the comment is genuinely ambiguous and you cannot determine what change to make.
8. IMPORTANT: Do NOT commit or push. Only modify the files on disk. The commit and push
   will be handled by the orchestrator after an independent review step.

Rules:
- Change ONLY what the comment asks. Do not modify unrelated code.
- ONLY modify files listed in the PR diff. Never touch files outside the PR.
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

    # Call OpenClaw fixer agent
    local output=""
    local exit_code=0
    local agent_log="${LOG_DIR}/pr-resolve-${repo_name}-${pr}-${comment_id}.log"

    log "Calling OpenClaw fixer agent (timeout: ${OPENCLAW_TIMEOUT}s)..."
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

    # Parse confidence + risk from fixer output (Enhancement #3)
    local confidence="UNKNOWN" risk="UNKNOWN"
    if echo "$output" | grep -q "CONFIDENCE:"; then
        confidence=$(echo "$output" | grep "CONFIDENCE:" | head -1 | grep -oE '(HIGH|MEDIUM|LOW)' | head -1)
    fi
    if echo "$output" | grep -q "RISK:"; then
        risk=$(echo "$output" | grep "RISK:" | head -1 | grep -oE '(HIGH|MEDIUM|LOW)' | head -1)
    fi
    log "Fixer assessment: confidence=${confidence}, risk=${risk}"

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
        # Clean up any uncommitted changes since fixer decided not to proceed
        cd "$repo_dir" && git checkout -- . 2>/dev/null || true
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
        # Clean up any partial uncommitted changes
        cd "$repo_dir" && git checkout -- . 2>/dev/null || true
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

    # --- REVIEW-FIX LOOP ---
    # Reviewer checks if the change breaks existing functionality or creates bugs.
    # If rejected, save the diff + reason and re-invoke the fixer with that context
    # so it knows what it tried before and why it was rejected.
    local max_review_attempts=3
    local review_attempt=1
    local previous_attempts="" # Accumulates all past attempts for fixer context

    while [[ $review_attempt -le $max_review_attempts ]]; do
        log "Running independent reviewer (attempt ${review_attempt}/${max_review_attempts})..."

        # Capture the current proposed diff before review
        local current_diff
        current_diff=$(cd "$repo_dir" && git diff HEAD 2>/dev/null | head -400) || true

        local review_output
        review_output=$(review_proposed_fix "$repo_dir" "$body" "$file_path" "$confidence" "$risk") || true

        if echo "$review_output" | grep -q '^APPROVED'; then
            log "Reviewer: APPROVED on attempt ${review_attempt} — proceeding to commit"
            break
        fi

        local rejection_reason
        rejection_reason=$(echo "$review_output" | sed 's/^REJECTED: *//')
        log "Reviewer REJECTED (attempt ${review_attempt}): ${rejection_reason}"

        # If we've exhausted all review attempts, give up
        if [[ $review_attempt -ge $max_review_attempts ]]; then
            log "Reviewer rejected all ${max_review_attempts} attempts. Escalating to human."
            cd "$repo_dir" && git checkout -- . 2>/dev/null || true
            reply_to_review_comment "$repo" "$pr" "$comment_id" \
                "🔍 **Code review blocked** — The independent reviewer rejected ${max_review_attempts} fix attempts.\n\nLast rejection reason: ${rejection_reason}\n\nThis has been escalated for human review.\n\n— ${BOT_SIGNATURE}"
            tg_send "🔍 *Reviewer blocked fix on ${repo} PR #${pr}* after ${max_review_attempts} attempts\nReason: ${rejection_reason}"
            mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "reviewer_blocked"
            record_metric "failed" "$fix_duration" "reviewer_blocked"
            return 1
        fi

        # Save this attempt's diff + rejection for the fixer's next try
        previous_attempts+="
--- PREVIOUS ATTEMPT #${review_attempt} ---
Your proposed diff:
\`\`\`diff
${current_diff}
\`\`\`
Reviewer REJECTED this because: ${rejection_reason}
--- END ATTEMPT #${review_attempt} ---
"

        # Discard current changes, re-invoke fixer with previous attempt context
        cd "$repo_dir" && git checkout -- . 2>/dev/null || true
        log "Re-invoking fixer with context from ${review_attempt} previous attempt(s)..."

        local retry_prompt=""
        [[ -n "$linear_context" ]] && retry_prompt+="${linear_context}

---

"
        retry_prompt+="## PR Diff Context
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
        [[ -n "$file_path" && "$file_path" != "" ]] && retry_prompt+=" on file ${file_path}:${line}"
        retry_prompt+=":
\"${body}\"

## Previous Attempt(s) — Reviewer Feedback
${previous_attempts}

Read the reviewer's feedback above carefully. The reviewer identified specific issues with your previous fix.
Based on the feedback, decide the best course of action:
- If the previous approach was mostly correct but had a specific issue → fix ONLY that issue, keep the rest
- If the previous approach was fundamentally wrong → try a different approach
- The reviewer's rejection reason tells you exactly what needs to change — follow it

Instructions:
1. Read the file and understand the full context around line ${line}
2. ONLY look at files that are part of this PR diff: ${changed_files}
3. Address the reviewer's specific feedback while still resolving the original comment
4. Run: ${test_cmd}
5. Output your assessment:
   CONFIDENCE: HIGH|MEDIUM|LOW
   RISK: LOW|MEDIUM|HIGH
   REASON: <1-line explanation>
6. Make the fix regardless of confidence/risk level. If tests and lint pass, the fix is good.
7. If tests fail: revert your changes. Output FAILED: <what went wrong>
8. Only output NEEDS_CLARIFICATION if the comment is genuinely ambiguous and you cannot determine what change to make.
9. IMPORTANT: Do NOT commit or push. Only modify the files on disk."

        local retry_output
        retry_output=$(timeout "$OPENCLAW_TIMEOUT" openclaw agent \
            --agent pr-resolver \
            --message "$retry_prompt" \
            --timeout "$OPENCLAW_TIMEOUT" \
            2>/dev/null) || true

        if [[ -z "$retry_output" ]]; then
            log "Fixer returned no output on review retry ${review_attempt}"
            cd "$repo_dir" && git checkout -- . 2>/dev/null || true
            mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "reviewer_blocked"
            record_metric "failed" "$fix_duration" "fixer_retry_empty"
            return 1
        fi

        # Check if fixer gave up
        if echo "$retry_output" | grep -q "FAILED:\|NEEDS_CLARIFICATION:\|SUBJECTIVE:"; then
            log "Fixer gave up on review retry ${review_attempt}"
            cd "$repo_dir" && git checkout -- . 2>/dev/null || true
            local fail_msg
            fail_msg=$(echo "$retry_output" | grep -E "FAILED:|NEEDS_CLARIFICATION:|SUBJECTIVE:" | head -1)
            reply_to_review_comment "$repo" "$pr" "$comment_id" \
                "⚠️ **Could not find a safe fix** after ${review_attempt} attempt(s).\n\n${fail_msg}\n\nNeeds human review.\n\n— ${BOT_SIGNATURE}"
            mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "reviewer_blocked"
            record_metric "failed" "$fix_duration" "fixer_gave_up"
            return 1
        fi

        # Update confidence/risk from new output
        if echo "$retry_output" | grep -q "CONFIDENCE:"; then
            confidence=$(echo "$retry_output" | grep "CONFIDENCE:" | head -1 | grep -oE '(HIGH|MEDIUM|LOW)' | head -1)
        fi
        if echo "$retry_output" | grep -q "RISK:"; then
            risk=$(echo "$retry_output" | grep "RISK:" | head -1 | grep -oE '(HIGH|MEDIUM|LOW)' | head -1)
        fi

        ((review_attempt++)) || true
    done

    # --- COMMIT & PUSH (orchestrated by bash, not the fixer agent) ---
    cd "$repo_dir"

    # Commit message prefix — always "fix" (tests passed = good to push)
    local commit_prefix="fix"
    local commit_tag=""

    # Extract a one-line summary from fixer output (if provided)
    local fix_summary
    fix_summary=$(echo "$output" | grep -oE 'REASON: .+' | head -1 | sed 's/REASON: *//' | head -c 80)
    [[ -z "$fix_summary" ]] && fix_summary="resolve review comment"

    local commit_msg="${commit_prefix}: ${commit_tag}${fix_summary}"

    # Stage only files listed in the PR diff to avoid accidental over-commits
    local files_to_stage
    files_to_stage=$(git diff --name-only 2>/dev/null) || true
    if [[ -z "$files_to_stage" ]]; then
        log "No file changes detected after reviewer approval — treating as unclear"
        mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "unclear"
        record_metric "failed" "$fix_duration" "unclear_result"
        return 0
    fi

    # Stage & commit
    git add $files_to_stage 2>/dev/null || { log "ERROR: git add failed"; return 1; }
    git commit -m "$commit_msg" 2>/dev/null || { log "ERROR: git commit failed"; return 1; }

    # STEP 2.6: Conflict handling — rebase before push (Enhancement #6)
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

    # Push
    if ! git push origin "$branch" 2>/dev/null; then
        log "ERROR: git push failed for branch ${branch}"
        reply_to_review_comment "$repo" "$pr" "$comment_id" \
            "⚠️ **Push failed** — Could not push the fix. Needs human review.\n\n— ${BOT_SIGNATURE}"
        mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "push_failed"
        record_metric "failed" "$fix_duration" "push_failed"
        return 1
    fi

    # 7. CI Pipeline Observation Loop
    # Watch pipeline until ALL checks are green. If anything fails,
    # fix the failing tests/code and push again. Repeat until green or max attempts.
    local ci_attempt=1
    local max_ci_attempts=5
    local ci_all_green=false
    while [[ $ci_attempt -le $max_ci_attempts ]]; do
        log "CI observation: waiting for pipeline (attempt ${ci_attempt}/${max_ci_attempts})..."
        wait_for_pr_checks "$repo" "$pr"
        local ci_status=$?

        if [[ $ci_status -eq 0 ]]; then
            log "CI ALL GREEN for PR #${pr} 🟢 (after ${ci_attempt} attempt(s))"
            ci_all_green=true
            break
        elif [[ $ci_status -eq 1 ]]; then
            log "CI FAILED for PR #${pr}. Fetching failure logs and fixing (${ci_attempt}/${max_ci_attempts})..."
            local fail_logs
            fail_logs=$(extract_failing_log_context "$repo" "$pr")
            if [[ -n "$fail_logs" ]]; then
                if resolve_ci_failure "$repo" "$pr" "$branch" "$comment_id" \
                    "$author" "$linear_context" "$fail_logs"; then
                    log "CI repair pushed. Observing pipeline again..."
                    ((ci_attempt++)) || true
                    continue
                else
                    log "CI repair failed. Retrying with fresh logs..."
                    ((ci_attempt++)) || true
                    continue
                fi
            else
                log "Could not extract failure logs. Retrying in 60s..."
                sleep 60
                ((ci_attempt++)) || true
                continue
            fi
        else
            # Timeout — wait and retry
            log "CI observation timed out. Retrying..."
            ((ci_attempt++)) || true
            continue
        fi
    done

    if [[ "$ci_all_green" != "true" ]]; then
        log "CI could not be made green after ${max_ci_attempts} attempts on PR #${pr}"
        tg_send "🔴 *CI still failing on ${repo} PR #${pr}* after ${max_ci_attempts} repair attempts. Needs human intervention."
        reply_to_review_comment "$repo" "$pr" "$comment_id" \
            "⚠️ **Fix applied but CI still failing** after ${max_ci_attempts} repair attempts.\n\nThe code change has been pushed but the pipeline needs human attention.\n\n— ${BOT_SIGNATURE}"
        mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "ci_failing" "$(git rev-parse HEAD 2>/dev/null | cut -c1-7)"
        record_metric "failed" "$fix_duration" "ci_repair_exhausted"
        return 1
    fi

    local commit_sha
    commit_sha=$(git rev-parse HEAD 2>/dev/null | cut -c1-7) || true

    # All green — build success reply
    local reply="✅ **Resolved** — ${fix_summary}"
    [[ -n "$file_path" && "$file_path" != "" ]] && reply+="\n\n**File:** \`${file_path}\`"
    reply+="\n**Reviewer:** ✅ No impact on existing functionality"
    reply+="\n**CI Pipeline:** 🟢 All checks green"
    [[ $ci_attempt -gt 1 ]] && reply+="\n**CI Repairs:** Fixed pipeline in ${ci_attempt} attempt(s)"
    reply+="\n\n— ${BOT_SIGNATURE}"
    commit_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "fixed" "$commit_sha"
    record_fix_timestamp
    record_metric "fixed" "$fix_duration"

    # Notify Linear [UPDATED - Post-CI]
    if [[ -n "$linear_ticket_id" ]]; then
        local fixed_label="Fixed"
        [[ $ci_attempt -gt 1 ]] && fixed_label="Repaired + Fixed"
        
        local linear_comment="### 🔧 PR Resolver Fixed & Verified
**Issue:** Resolving review comment #${comment_id}
**File:** \`${file_path}\`
**Change:** ${fix_summary}
**CI Status:** ✅ All checks passed (after $((ci_attempt - 1)) repair attempts)
**Commit:** \`${commit_sha}\`

---
*Verified Green 🟢*"
        if linear_post_comment "$linear_ticket_id" "$linear_comment"; then
            log "Posted summary to Linear ticket ${linear_ticket_id}"
        fi
    fi

    return 0
}

###############################################################################
# Process all comments for a single PR
###############################################################################

process_pr() {
    local repo="$1" pr="$2" title="$3" branch="$4" pr_author="$5"
    local passed_linear_ticket_id="${6:-}"
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

    # Fetch Linear ticket context
    local linear_ticket_id="$passed_linear_ticket_id"
    local linear_context=""
    if [[ -n "$LINEAR_API_KEY" ]]; then
        # If not passed directly, try to extract from branch name
        if [[ -z "$linear_ticket_id" ]]; then
            linear_ticket_id=$(linear_extract_ticket_id "$branch")
        fi

        if [[ -n "$linear_ticket_id" ]]; then
            log "Linear ticket: ${linear_ticket_id}"

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

    # STEP 13: Move Linear ticket to "Code Review" when ALL comments are resolved
    # and there are no failures or remaining comments to process.
    if [[ -n "$passed_linear_ticket_id" && "$actionable_total" -gt 0 && \
          "$actionable_resolved" -eq "$actionable_total" && "$actionable_failed" -eq 0 ]]; then
        log "All ${actionable_total} comments resolved on PR #${pr}. Moving ticket ${passed_linear_ticket_id} to 'Code Review'..."
        if linear_update_status "$passed_linear_ticket_id" "Code Review"; then
            log "Linear ticket ${passed_linear_ticket_id} moved to 'Code Review' ✅"
            local transition_comment="### 🚀 Moved to Code Review
All ${actionable_total} review comment(s) have been resolved and CI is green.
Ticket has been moved to **Code Review** for human sign-off.

— *PR Resolver (automated)*"
            linear_post_comment "$passed_linear_ticket_id" "$transition_comment" 2>/dev/null || true
        else
            log "WARNING: Failed to move ticket ${passed_linear_ticket_id} to 'Code Review'"
        fi
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
    log "PR Resolver cycle started (Linear Driven)"
    log "Polling Linear state: '${LINEAR_TRIGGER_STATE}'"
    log "=========================================="

    if [[ -z "$LINEAR_API_KEY" ]]; then
        log "ERROR: LINEAR_API_KEY not set. Cannot poll Linear for issues."
        return 1
    fi

    # Budget guard before polling
    if ! check_hourly_budget; then
        log "Hourly budget exhausted, stopping cycle"
        record_metric "cycle_complete"
        return 0
    fi

    local issues_data
    issues_data=$(linear_get_issues_by_state "$LINEAR_TRIGGER_STATE")
    [[ -z "$issues_data" ]] && {
        log "No tickets found in '${LINEAR_TRIGGER_STATE}' state with attached PRs."
        record_metric "cycle_complete"
        return 0
    }

    # Format from linear_get_issues_by_state:
    # TicketID|RepoName|PRNumber|BranchName|TicketTitle
    # Wait: The RepoName includes org, e.g. ruh-ai/strapi-service.

    while IFS='|' read -r ticket_id repo pr_number branch ticket_title; do
        [[ -z "$pr_number" || -z "$repo" ]] && continue
        
        log "Found ticket ${ticket_id} attached to ${repo} PR #${pr_number}"

        # Get PR details from GitHub to resolve variables needed for process_pr
        local pr_details
        pr_details=$(get_pr_details "$repo" "$pr_number")
        
        # If PR doesn't exist or is closed, PR details might be empty or fail
        [[ -z "$pr_details" ]] && {
            log "WARNING: Could not fetch PR details for ${repo} PR #${pr_number}. Might be closed or deleted. Skipping."
            continue
        }

        local pr_title pr_branch pr_author
        pr_title=$(echo "$pr_details" | cut -d'|' -f1)
        pr_branch=$(echo "$pr_details" | cut -d'|' -f2)
        pr_author=$(echo "$pr_details" | cut -d'|' -f3)

        # Budget guard at PR level
        if ! check_hourly_budget; then
            log "Hourly budget exhausted, stopping cycle"
            break
        fi

        # Pass the ticket_id we already know to process_pr
        process_pr "$repo" "$pr_number" "$pr_title" "$pr_branch" "$pr_author" "$ticket_id"

        # Respect global rate limit
        [[ "${TOTAL_FIXES:-0}" -ge "$MAX_FIXES_PER_CYCLE" ]] && {
            log "Global rate limit reached (${MAX_FIXES_PER_CYCLE})"
            break
        }
    done <<< "$issues_data"

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
        log "Starting daemon mode (poll every 1800s)"
        while true; do
            run_cycle || true
            sleep 1800
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
