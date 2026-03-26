# Heartbeat — PR Resolver

> Every 5 minutes, check all monitored repos for new PR comments.

## Checklist (in order)

### 1. Poll Open PRs
```bash
for repo in monitored_repos:
    gh pr list --repo $repo --state open --json number,title,headRefName,author
```

### 2. Fetch New Comments
For each open PR:
```bash
# Inline review comments (on specific code lines)
gh api repos/{owner}/{repo}/pulls/{pr}/comments

# General discussion comments
gh api repos/{owner}/{repo}/issues/{pr}/comments
```

### 3. Filter
- Skip already-processed comments (check processed-comments.json by ID)
- Skip bot's own comments (BOT_SIGNATURE check)
- Skip CI bot comments (codecov, dependabot, etc.)

### 4. Classify (FREE)
Run bash keyword classifier on each new comment body.

### 5. Act (credits only when needed)
- EXPLICIT_REQUEST / CODE_CHANGE / NITPICK → invoke Code Fixer agent
- QUESTION → invoke Question Answerer agent
- SUBJECTIVE → Telegram notification (no credits)
- APPROVAL / UNKNOWN / SELF → skip (no credits)

### 6. Log
Update processed-comments.json with:
- comment_id
- intent
- action taken
- commit SHA (if fix)
- timestamp

## Rate Limits
- Max 3 fixes per PR per cycle
- Max 10 fixes per cycle total
- 600s timeout per fix
- 5 min between cycles (cron)
