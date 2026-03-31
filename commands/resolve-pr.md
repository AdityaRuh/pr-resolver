---
description: Resolve PR review comments — read comment, fix code, run tests, push, reply.
---

# /resolve-pr

Usage: `/resolve-pr [repo] [pr-number]`

> Read the comment. Fix the code. Reply with proof.

## What It Does

1. Fetches all unresolved review comments on the PR
2. Fetches Linear ticket context (if ticket ID found in branch name)
3. Classifies each comment (code fix, question, approval, subjective)
4. For actionable comments:
   - Explores codebase structure
   - Creates a fix plan
   - Prepares working branch (always pulls latest `dev`)
   - Makes minimal fix (does NOT commit)
   - Independent reviewer verifies (up to 3 attempts)
   - Runs lint + tests
   - Commits and pushes
   - Watches CI pipeline until green (auto-repairs up to 5x)
   - Replies on PR with structured response
5. For questions: answers with context from ticket + code
6. For subjective issues: flags to human via Telegram
7. When all comments resolved + CI green → moves Linear ticket to "Code Review"

## Example

```
/resolve-pr ruh-ai/sdr-backend 52

🔍 Checking PR #52 for unresolved comments...
📋 Linear ticket: SDR-142 — "Add webhook retry logic"

Found 3 new comments:
  1. @reviewer on src/services/email.ts:45 — "Add null check here"
     → Intent: CODE_CHANGE (HIGH confidence)
     → Exploring codebase...
     → Planning fix...
     → Branch prepared (pulled latest dev ✅)
     → Fixing...
     → Reviewer: APPROVED ✅
     → Tests: passing ✅
     → CI Pipeline: 🟢 All checks green
     → ✅ Resolved: Added null check, tests passing

  2. @reviewer on src/utils/date.ts:12 — "Why not use dayjs?"
     → Intent: QUESTION
     → Replied with explanation (referenced ticket context)

  3. @reviewer on src/api/routes.ts:88 — "I think this should be POST not PUT"
     → Intent: SUBJECTIVE
     → Flagged to Telegram for human decision

Summary: 1 fixed, 1 answered, 1 flagged
📋 Linear: SDR-142 → not all resolved, staying in "In Development"
```

## Automatic Mode (Cron)

When running via cron (every 30 min), it:
- Polls Linear for "In Development" tickets
- Identifies associated PRs from ticket links/metadata
- Processes only NEW comments (tracks by comment ID)
- Skips bot's own comments
- Skips already-processed comments
- Rate limits: max 3 fixes per PR per cycle, 10 per cycle, 20 per hour
- Moves ticket to "Code Review" when all comments are resolved + CI green

## Manual Mode

```
/resolve-pr ruh-ai/strapi-service 77
```

Processes all unresolved comments on that specific PR.

## Rules

- **Never force-push** — always new commits
- **Never push broken code** — tests must pass + reviewer must approve
- **Never auto-resolve subjective feedback** — flag to human
- **Never skip `git pull origin dev`** — always work on latest code
- **One commit per comment thread** — clean history
- **Always reply** — don't leave reviewers hanging
- **Track everything** — audit log in `state/processed-comments.json`
- **Budget-aware** — respect hourly and per-cycle limits
