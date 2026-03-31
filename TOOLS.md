# TOOLS.md — PR Resolver Local Notes

## GitHub CLI (`gh`)
- Authenticated as: `AdityaRuh`
- Used for: PR listing, comment fetching, diff extraction, PR creation, CI checks
- All 6 monitored repos are under `ruh-ai` org

## Linear API
- Auth: `LINEAR_API_KEY` env var (Personal API Key)
- Used for: Ticket polling ("In Development"), rich context fetch, state transitions, comment posting
- GraphQL endpoint: `https://api.linear.app/graphql`
- Ticket ID patterns: `RP-XXX`, `SDR-XXX`, etc.

## Linear Skill (ClawHub)
- Installed at: `~/.openclaw/workspace/skills/linear`
- Script: `~/.openclaw/workspace/skills/linear/scripts/linear.sh`
- Commands: `issue`, `comment`, `status`

## Telegram Notifications
- Bot token: `TELEGRAM_BOT_TOKEN` env var
- Chat ID: `TELEGRAM_CHAT_ID` env var
- Used for: Escalating subjective comments, merge conflicts, CI failures, budget alerts

## OpenClaw Agents
- Agent name: `pr-resolver`
- Fast model: Used for comment classification (~15s) and context summarization (~20s)
- Full model: Used for code fixing (~600s) and independent review (~120s)

## Git Configuration
- Bot commits as: `AdityaRuh`
- Bot signature in PR replies: `PR Resolver (automated)`
- Repos cloned to: `/home/aditya/repos/<repo-name>/`
- Never force-push — always new commits on PR branches

## State Files
- `state/processed-comments.json` — tracks processed comment IDs per repo/PR
- `state/fix-signatures.json` — SHA-256 hashes for idempotency
- `state/budget-tracker.json` — hourly fix timestamps for rate limiting
- `metrics/metrics.json` — success rate, fix times, failure breakdown
