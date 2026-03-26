---
description: Resolve PR review comments — read comment, fix code, run tests, push, reply.
---

# /resolve-pr

Usage: `/resolve-pr [repo] [pr-number]`

> Read the comment. Fix the code. Reply with proof.

## What It Does

1. Fetches all unresolved review comments on the PR
2. Classifies each comment (code fix, question, approval, subjective)
3. For actionable comments:
   - Checks out PR branch
   - Makes minimal fix
   - Runs lint + tests
   - Commits and pushes
   - Replies on PR with structured response
4. For unclear comments: asks for clarification
5. For subjective issues: flags to human via Telegram

## Example

```
/resolve-pr ruh-ai/sdr-backend 52

🔍 Checking PR #52 for unresolved comments...

Found 3 new comments:
  1. @reviewer on src/services/email.ts:45 — "Add null check here"
     → Intent: CODE_CHANGE (HIGH confidence)
     → Fixing...
     → ✅ Resolved: Added null check, tests passing

  2. @reviewer on src/utils/date.ts:12 — "Why not use dayjs?"
     → Intent: QUESTION
     → Replied with explanation

  3. @reviewer on src/api/routes.ts:88 — "I think this should be POST not PUT"
     → Intent: SUBJECTIVE
     → Flagged to Telegram for human decision

Summary: 1 fixed, 1 answered, 1 flagged
```

## Automatic Mode (Cron)

When running via cron (every 5 min), it:
- Polls ALL monitored repos
- Processes only NEW comments (tracks by comment ID)
- Skips bot's own comments
- Skips already-processed comments
- Rate limits: max 3 fixes per PR per cycle

## Manual Mode

```
/resolve-pr ruh-ai/strapi-service 77
```

Processes all unresolved comments on that specific PR.

## Rules

- **Never force-push** — always new commits
- **Never push broken code** — tests must pass
- **Never auto-resolve subjective feedback** — flag to human
- **One commit per comment thread** — clean history
- **Always reply** — don't leave reviewers hanging
- **Track everything** — audit log in state/processed-comments.json
