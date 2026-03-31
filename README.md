# 🔧 PR Resolver

> An autonomous AI agent that reads your PR review comments, fixes the code, runs tests, watches CI, and replies with proof — all without you lifting a finger.

---

## What Is This?

PR Resolver is a ticket-driven agent built on [OpenClaw](https://openclaw.ai). It polls **Linear** for tickets in "In Development", finds their associated GitHub PRs, and processes every unresolved review comment — automatically.

It doesn't blindly auto-fix. It thinks like a smart junior developer:
- Reads the full file before touching anything
- Makes the **smallest possible change**
- Validates with an independent AI reviewer
- Won't push until CI is green
- Asks when unsure. Flags opinions to humans.

---

## How It Works

```
Linear "In Development" tickets  (every 30 min)
            ↓
    Find attached GitHub PRs
            ↓
    Fetch all review comments
            ↓
  Classify each comment (regex → AI)
            ↓
  ┌─────────┬──────────┬──────────┬──────────┐
 SKIP      FLAG      ANSWER      FIX
 (bots,   (opinions) (questions) (code changes)
 approvals)  Telegram    AI reply      ↓
                                  Explore codebase
                                       ↓
                                  Plan the fix
                                       ↓
                                  Prepare branch
                                  (git pull dev)
                                       ↓
                              AI Fixer makes change
                              (NO commit yet)
                                       ↓
                            Independent AI Reviewer
                            APPROVED or REJECTED (×3)
                                       ↓
                              Commit → Push
                                       ↓
                           Watch CI pipeline (×5 repairs)
                                       ↓
                         Reply on PR + Update Linear ticket
```

---

## Features

| Feature | Detail |
|---------|--------|
| **Ticket-driven** | Linear "In Development" is the trigger — not random GitHub polling |
| **Hybrid classifier** | Regex for obvious patterns (free) → AI for semantic nuance (fast, low cost) |
| **Diff-scoped fixes** | Agent only touches files in the PR diff. Never wanders |
| **Independent reviewer** | A separate AI checks the fix for bugs before anything is committed |
| **CI observation loop** | Polls pipeline after push, auto-repairs failures up to 5 times |
| **Idempotency** | SHA-256 hash dedup — same comment won't be fixed twice |
| **Budget guards** | 3 fixes/PR/cycle · 10 fixes/cycle · 20 fixes/hour |
| **Human escalation** | Subjective comments, design debates, and merge conflicts go to Telegram |
| **Linear state transitions** | Moves ticket to "Code Review" when all comments resolved + CI green |
| **Full audit trail** | Every action logged with intent, result, duration, and commit SHA |

---

## Architecture

PR Resolver has two layers:

**1. Bash Orchestrator** (`lib/pr-resolver.sh`)
The deterministic brain. Handles polling, state management, git operations, GitHub/Linear API calls, rate limiting, retry logic — everything that doesn't need AI.

**2. OpenClaw Agent** (AI, invoked 5 times per fix)
Called only when intelligence is needed:

| Call | Purpose | Timeout |
|------|---------|---------|
| Comment Classifier | Understand reviewer intent | 15s |
| Context Summarizer | Compress Linear ticket | 20s |
| **Code Fixer** | Read code, make fix, run tests | 600s |
| **Independent Reviewer** | Approve or reject the diff | 120s |
| **CI Failure Fixer** | Diagnose logs, repair pipeline | 600s |

The fixer runs from inside the repo directory (`cd repo && openclaw agent --local`), giving Claude direct access to the filesystem. It reads files, edits code, runs tests — and stops there. **It never commits or pushes.** The orchestrator handles that after the reviewer approves.

---

## Monitored Repositories

- `ruh-ai/strapi-service`
- `ruh-ai/hubspot-mcp`
- `ruh-ai/salesforce-mcp`
- `ruh-ai/sdr-backend`
- `ruh-ai/inbox-rotation-service`
- `ruh-ai/sdr-management-mcp`

---

## Setup

### Prerequisites

- [OpenClaw](https://openclaw.ai) installed and configured
- `gh` CLI authenticated (`gh auth login`)
- Linear API key
- Telegram bot (for human escalations)

### Environment

Copy `.env.template` to `.env` and fill in:

```bash
cp .env.template .env
```

```bash
LINEAR_API_KEY=lin_api_...
GITHUB_TOKEN=ghp_...
TELEGRAM_BOT_TOKEN=...
TELEGRAM_CHAT_ID=...
BOT_GITHUB_USER=YourGitHubUsername
```

### Run

**Single cycle** (good for cron):
```bash
bash lib/pr-resolver.sh
```

**Daemon mode** (runs every 30 min):
```bash
nohup bash lib/pr-resolver.sh --daemon &
```

**Cron** (recommended):
```bash
*/30 * * * * /path/to/pr-resolver/lib/pr-resolver.sh >> /path/to/logs/cron.log 2>&1
```

**Specific PR** (manual override):
```bash
/resolve-pr ruh-ai/sdr-backend 52
```

---

## Human Override Commands

Post these in any PR comment to control the agent:

| Command | Effect |
|---------|--------|
| `/agent ignore` | Skip this comment permanently |
| `/agent retry` | Re-process the last comment |
| `/agent force-fix` | Attempt with elevated confidence |
| `/agent explain` | Show resolution status for this PR |
| `/agent pause` | Pause all processing on this PR |

---

## Observability

**Check metrics:**
```bash
bash lib/pr-resolver.sh --metrics
```

**Check PR status:**
```bash
bash lib/pr-resolver.sh --status
```

**Live logs:**
```bash
tail -f logs/pr-resolver.log
```

**State files:**
```
state/processed-comments.json   — which comments have been handled
state/fix-signatures.json       — dedup hashes
state/budget-tracker.json       — hourly rate limit tracking
metrics/metrics.json            — success rate, fix times, failure breakdown
```

---

## What It Will Never Do

- Force-push
- Push broken code (tests must pass first)
- Auto-resolve design debates or subjective feedback
- Modify files outside the PR diff
- Delete tests
- Respond to its own comments
- Skip `git pull origin dev`
- Exceed budget limits silently

---

## Example Output

When a fix lands, the PR gets a reply like:

```
✅ Resolved — Added null check before response.data access

File: src/services/userService.ts
Change: Added guard clause on line 45 before accessing response.data
Reviewer: ✅ No impact on existing functionality
CI Pipeline: 🟢 All checks green

— PR Resolver (automated)
```

And the Linear ticket gets a comment + moves to **Code Review** automatically.

---

## Built By

**Aditya Singh / Ruh AI** — powered by [OpenClaw](https://openclaw.ai) + Claude Sonnet via OpenRouter.
