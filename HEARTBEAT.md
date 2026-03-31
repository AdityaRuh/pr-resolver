# Heartbeat — PR Resolver v3 (Ticket-Driven)

> Every 30 minutes, poll Linear for "In Development" tickets and process associated PRs.

## Checklist (in order)

### 1. Poll Linear Tickets
```bash
# Fetch all tickets in "In Development" state with linked PRs
linear_get_issues_by_state "In Development"
# Output: TicketID|Repo|PRNumber|BranchName|TicketTitle
```
- If tickets found → start full processing
- If none → remain idle with `HEARTBEAT_OK`

### 2. Fetch Ticket Details
For each ticket:
```bash
# Rich context: title, description, acceptance criteria, labels, linked PRs
linear_get_rich_context "$TICKET_ID"
```

### 3. Identify Associated PR
From ticket data, extract:
- GitHub links inside ticket
- Linked PR metadata
- Comments referencing a PR

If no PR found → skip or trigger new branch + PR creation flow.

### 4. Fetch PR Comments
For each associated PR:
```bash
# Inline review comments (on specific code lines)
gh api repos/{owner}/{repo}/pulls/{pr}/comments

# General discussion comments
gh api repos/{owner}/{repo}/issues/{pr}/comments
```

### 5. Deduplicate
- Skip already-processed comments (check `processed-comments.json` by ID)
- Skip bot's own comments (`BOT_SIGNATURE` check)
- Skip CI bot comments (codecov, dependabot, etc.)

### 6. Classify Intent
**Stage 1 — Rule-based (FREE)**
- Bot comments → `SELF` / `CI_BOT`
- Self comments → `SELF`
- Command comments → `AGENT_COMMAND` (`/agent ignore|retry|force-fix|explain|pause`)

**Stage 2 — Model-based (FAST LLM)**
- `CODE_CHANGE` / `QUESTION` / `APPROVAL` / `SUBJECTIVE` / `NITPICK` / `EXPLICIT_REQUEST` / `UNKNOWN`

### 7. Route by Intent

| Intent | Action |
|--------|--------|
| `SELF / CI_BOT / APPROVAL / UNKNOWN` | Skip |
| `AGENT_COMMAND` | Execute command |
| `SUBJECTIVE` | Escalate to Telegram |
| `QUESTION` | Generate explanation reply |
| `CODE_CHANGE / NITPICK / EXPLICIT_REQUEST` | Proceed to fix ↓ |

### 8. Context Summarization (FAST LLM)
- Summarize ticket content, requirements, acceptance criteria
- Fallback to truncated context if too long

### 9. Extract PR Diff (FREE)
```bash
gh pr diff <pr-number> --repo <repo>
```
- Only changed files
- Ignore irrelevant files

### 10. Codebase Exploration (FREE)
```bash
find <working_dir> -maxdepth 3 -type f | grep -v node_modules | grep -v .git | grep -v dist
grep -r "<keyword>" <working_dir> --include="*.ts" --include="*.js" --include="*.py" -l
```
Determine: files to modify, modules affected, pattern conventions.

### 11. Planning Phase (LLM)
Create structured plan: files to modify/create, approach, risks/assumptions.

### ✅ 12. Prepare Working Branch (MANDATORY)
```bash
cd <working_dir>
git fetch origin
git stash
git checkout dev
git pull origin dev              # ← NEVER SKIP THIS
BRANCH_NAME="<branch-from-PR>"
git checkout -B "$BRANCH_NAME" "origin/$BRANCH_NAME" 2>/dev/null || git checkout "$BRANCH_NAME"
git merge dev
```
🚨 **CRITICAL:** Never skip `git pull origin dev`

### 13. Code Implementation (LLM CREDITS)
- Minimal changes, follow conventions
- Avoid: `.env`, secrets, build artifacts, `node_modules`
- Output: `CONFIDENCE` + `RISK` assessment
- Do NOT commit or push — only modify files on disk

### 14. Independent Review (LLM CREDITS)
- Separate reviewer agent checks correctness + regression risk
- `APPROVED` → continue
- `REJECTED` → fixer retries with rejection reason (up to 3 attempts)
- All retries fail → escalate to human

### 15. Run Tests & Linting (FREE)
```bash
# JS/TS
npm run lint || yarn lint
npm test || yarn test

# Python
pytest
flake8 || ruff
```
If tests fail: autofix if obvious, otherwise proceed with warning.

### 16. Commit Changes
```bash
git add -A
git commit -m "<TICKET-ID>: <title>

<summary>

Resolves: <TICKET-ID>"
```

### 17. Push Branch
```bash
git push origin <branch>
```
Stop if authentication fails.

### 18. Create PR (if needed)
```bash
gh pr create --base dev --head <branch>
```
Include: summary, ticket reference, changes made, tests status.

### 19. CI Pipeline Observation
- Watch until ALL checks green (poll every 60s, 15 min timeout)
- If fails → extract logs → fix → push → re-observe (max 5 attempts)
- If still failing after 5 → notify human

### 20. Update Linear Ticket
- Move state: `In Development` → `Code Review`
- Post comment: 🚀 Development complete + branch + PR URL

### 21. Final Summary
```
Completed for <TICKET-ID>:
✔ Ticket processed
✔ Code updated
✔ Branch created
✔ PR created/updated
✔ Tests executed
✔ Ticket moved to Code Review
```

## Rate Limits

| Limit | Value |
|-------|-------|
| Max fixes per PR per cycle | 3 |
| Max fixes per cycle total | 10 |
| Max fixes per hour | 20 |
| Agent timeout per comment | 600s |
| Max retries per comment | 2 |
| Retry backoff | 30s → 60s |
| Max CI repair attempts | 5 |
| Polling interval | 30 min (cron) |

## Error Handling

| Scenario | Action |
|----------|--------|
| Ticket not found | Stop |
| Branch exists (dirty) | Ask or reuse |
| Push fails | Stop + notify |
| CLI unavailable | Provide manual link |
| Tests fail | Autofix or warning |
| Not a git repo | Stop |
| Merge conflict | Abort rebase + notify |
| CI fails 5x | Escalate to human |
| Budget exhausted | Skip + report |

## Key Principles
- Ticket-driven execution — Linear is the trigger
- Minimal, safe code changes
- Deterministic workflow
- Optional human input
- Consistent behavior across all monitored repos
