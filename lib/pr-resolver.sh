#!/usr/bin/env bash
# pr-resolver.sh — PR Comment Resolver Daemon
#
# Polls GitHub for new PR comments every 5 minutes.
# Classifies intent (FREE), resolves via OpenClaw (credits only when needed).
#
# Usage:
#   Single run:  bash pr-resolver.sh
#   Cron mode:   */5 * * * * /path/to/pr-resolver.sh
#   Daemon:      nohup bash pr-resolver.sh --daemon &

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/.env" 2>/dev/null || true

###############################################################################
# Configuration
###############################################################################

PR_RESOLVER_HOME="$SCRIPT_DIR"
STATE_DIR="${PR_RESOLVER_HOME}/state"
LOG_DIR="${PR_RESOLVER_HOME}/logs"
PROCESSED_FILE="${STATE_DIR}/processed-comments.json"
REPOS_FILE="${STATE_DIR}/monitored-repos.json"
LOCK_FILE="${STATE_DIR}/.pr-resolver.lock"
LOG_FILE="${LOG_DIR}/pr-resolver.log"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Bot signature to detect own comments (anti-loop)
BOT_SIGNATURE="PR Resolver (automated)"
BOT_GITHUB_USER="${BOT_GITHUB_USER:-AdityaRuh}"

# Rate limits
MAX_FIXES_PER_PR=3
MAX_FIXES_PER_CYCLE=10
OPENCLAW_TIMEOUT=600  # 10 min per comment

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
    mkdir -p "$STATE_DIR" "$LOG_DIR"
    [[ -f "$PROCESSED_FILE" ]] || echo '{}' > "$PROCESSED_FILE"
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
        .[$r][$p] //= {"last_checked": "", "processed_comment_ids": [], "actions_taken": []} |
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
        .[$r][$p].last_checked = $now
    ' "$PROCESSED_FILE" > "$tmp" && mv "$tmp" "$PROCESSED_FILE"
}

get_pr_fix_count() {
    local repo="$1" pr="$2"
    jq --arg r "$repo" --arg p "$pr" \
        '[.[$r][$p].actions_taken // [] | .[] | select(.action == "fixed")] | length' \
        "$PROCESSED_FILE" 2>/dev/null || echo "0"
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

    # Priority 1: Explicit agent mention
    if echo "$body_lower" | grep -qE '@(agent|sentinel|bot|resolve)'; then
        echo "EXPLICIT_REQUEST"
        return
    fi

    # Priority 2: Code change keywords
    if echo "$body_lower" | grep -qE '\b(fix|change|update|replace|remove|add|rename|refactor|move|extract|inline|delete|use .* instead)\b'; then
        echo "CODE_CHANGE"
        return
    fi

    # Priority 3: Question
    if echo "$body_lower" | grep -qE '(\?|^why |^how |^what |^can you explain|^could you)'; then
        echo "QUESTION"
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
# Resolve a single comment via OpenClaw
###############################################################################

resolve_comment() {
    local repo="$1" pr="$2" branch="$3" comment_id="$4"
    local author="$5" file_path="$6" line="$7" body="$8" intent="$9"
    local repo_name repo_dir

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
            prompt="You are resolving a PR review comment on repo: ${repo_dir}
Branch: ${branch}
PR #${pr}

Comment by @${author}"
            [[ -n "$file_path" && "$file_path" != "" ]] && prompt+=" on file ${file_path}:${line}"
            prompt+=":
\"${body}\"

Instructions:
1. Read the file and understand the full context around line ${line}
2. Make the MINIMAL change to resolve this comment
3. Run: ${test_cmd}
4. If tests pass: commit with message 'fix: resolve review — <1-line summary of change>'
5. If tests fail: do NOT commit. Output FAILED: <what went wrong>
6. Push to origin/${branch}

Rules:
- Change ONLY what the comment asks. Do not modify unrelated code.
- Never force-push. Always a new commit.
- If the request is unclear: output NEEDS_CLARIFICATION: <your question>
- If you disagree: output SUBJECTIVE: <your reason>"
            ;;
        QUESTION)
            prompt="A reviewer asked a question on PR #${pr} in repo ${repo_dir}.
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

    # Parse result
    if [[ $exit_code -eq 124 ]]; then
        log "TIMEOUT resolving comment #${comment_id}"
        reply_to_review_comment "$repo" "$pr" "$comment_id" \
            "⏱️ **Timed out** — This comment requires more complex changes than I can handle automatically. Needs human review.\n\n— ${BOT_SIGNATURE}"
        mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "timeout"
        return 1
    fi

    # Check for NEEDS_CLARIFICATION
    if echo "$output" | grep -q "NEEDS_CLARIFICATION:"; then
        local question
        question=$(echo "$output" | grep "NEEDS_CLARIFICATION:" | head -1 | sed 's/.*NEEDS_CLARIFICATION: *//')
        reply_to_review_comment "$repo" "$pr" "$comment_id" \
            "❓ **Clarification needed**\n\n${question}\n\n— ${BOT_SIGNATURE}"
        mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "clarification"
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
        log "Answered question on comment #${comment_id}"
        return 0
    fi

    # Check if a new commit was pushed (success case)
    local latest_commit
    latest_commit=$(cd "$repo_dir" && git log --oneline -1 --format="%H %s" 2>/dev/null)

    if echo "$latest_commit" | grep -qi "resolve review\|fix:\|review comment"; then
        local commit_sha
        commit_sha=$(echo "$latest_commit" | cut -d' ' -f1)
        local commit_msg
        commit_msg=$(echo "$latest_commit" | cut -d' ' -f2-)

        # Build reply
        local reply="✅ **Resolved** — ${commit_msg}"
        [[ -n "$file_path" && "$file_path" != "" ]] && reply+="\n\n**File:** \`${file_path}\`"
        reply+="\n**Tests:** All passing ✅"
        reply+="\n\n— ${BOT_SIGNATURE}"

        reply_to_review_comment "$repo" "$pr" "$comment_id" "$reply"
        mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "fixed" "$commit_sha"
        log "✅ Resolved comment #${comment_id} (commit: ${commit_sha:0:7})"
        return 0
    fi

    # Fallback: agent ran but unclear result
    log "Agent completed but no clear result for comment #${comment_id}"
    mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "unclear"
    return 0
}

###############################################################################
# Process all comments for a single PR
###############################################################################

process_pr() {
    local repo="$1" pr="$2" title="$3" branch="$4" pr_author="$5"
    local fixes_this_pr=0

    log "Processing ${repo} PR #${pr}: ${title} (branch: ${branch})"

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

        case "$intent" in
            SELF|CI_BOT|APPROVAL|UNKNOWN)
                mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "skipped"
                continue
                ;;
            SUBJECTIVE)
                local body_short
                body_short=$(echo "$body" | head -c 200 | tr '\n' ' ')
                tg_send "🤔 *Subjective comment on ${repo} PR #${pr}*
By @${author}: ${body_short}"
                mark_comment_processed "$repo" "$pr" "$comment_id" "$intent" "flagged"
                log "Flagged subjective comment #${comment_id} to Telegram"
                continue
                ;;
        esac

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

        # Resolve via OpenClaw (USES CREDITS)
        resolve_comment "$repo" "$pr" "$branch" "$comment_id" \
            "$author" "$file_path" "$line" "$body" "$intent" || true

        ((fixes_this_pr++)) || true
        ((TOTAL_FIXES++)) || true

        # Global rate limit
        if [[ "${TOTAL_FIXES:-0}" -ge "$MAX_FIXES_PER_CYCLE" ]]; then
            log "Global rate limit reached (${TOTAL_FIXES}/${MAX_FIXES_PER_CYCLE})"
            return 0
        fi

    done < "$all_comments_file"

    rm -f "$all_comments_file"
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
    log "=========================================="

    # Summary to Telegram (only if actions taken)
    if [[ "${TOTAL_FIXES:-0}" -gt 0 ]]; then
        tg_send "🔧 *PR Resolver Summary*
Fixes applied: ${TOTAL_FIXES}
Check logs for details."
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
    else
        # Single run (for cron)
        run_cycle
    fi
}

main "$@"
