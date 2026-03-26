# Skill: PR Comment Resolver

> Resolve PR review comments with minimal, targeted code changes.

## When to Use

When a reviewer leaves a comment on a PR that requires a code change, fix, or answer.

## Philosophy

Act like a **smart junior developer**, not an auto-fixer bot:
- Read the full context before touching code
- Make the smallest possible change
- Validate before committing
- Ask when unsure — don't guess

## Workflow

### Step 1: Understand the Comment

Before writing any code:
1. Read the comment carefully — what exactly is being asked?
2. Read the file where the comment was left — understand the surrounding code
3. Read the full PR diff — understand what this PR is doing
4. Check previous comments in the thread — is there context you're missing?

### Step 2: Classify Intent

| Intent | Action | Credits |
|--------|--------|---------|
| Code fix (`fix this`, `change X to Y`, `remove this`) | Fix + test + push + reply | ✅ Yes |
| Style/nitpick (`rename`, `formatting`, `typo`) | Fix + push + reply "Fixed" | ✅ Yes |
| Question (`why did you`, `can you explain`) | Reply with explanation | ✅ Yes |
| Suggestion (`consider`, `maybe`, `what about`) | Post as GitHub suggested change | ✅ Yes |
| Approval (`LGTM`, `looks good`) | Skip — no action needed | ❌ No |
| Disagreement (`I disagree`, `not sure about`) | Flag to human via Telegram | ❌ No |

### Step 3: Make the Fix

Rules for code changes:
- **One commit per comment** — don't batch unrelated fixes
- **Touch only the file(s) mentioned** — never modify unrelated code
- **Preserve existing style** — match indentation, naming, patterns
- **Read the test file first** — understand what's already tested
- **Never delete tests** — only add or modify

### Step 4: Validate

Before committing, ALWAYS run:

**Python repos:**
```bash
# Lint
ruff check . --fix 2>/dev/null || flake8 .
# Type check
mypy . --ignore-missing-imports 2>/dev/null || true
# Tests
pytest --tb=short -q
```

**Node.js repos:**
```bash
# Lint
npm run lint 2>/dev/null || npx eslint .
# Type check
npx tsc --noEmit 2>/dev/null || true
# Tests
npm test
```

**If ANY check fails → do NOT commit. Report what failed.**

### Step 5: Commit & Push

```bash
git add <only-changed-files>
git commit -m "fix: resolve review — <1-line summary>"
git push origin <pr-branch>
```

Never `git add .` — only add specific files you changed.

### Step 6: Reply on PR

Use the appropriate template:

**Resolved:**
```
✅ **Resolved** — Updated error handling in userService.ts to handle null response as suggested.

**File:** `src/services/userService.ts`
**Change:** Added null check before accessing response.data (line 45)
**Tests:** All 142 tests passing ✅

— PR Resolver (automated)
```

**Clarification needed:**
```
❓ **Clarification needed** — The comment mentions updating the error handler, but there are two error paths in this function (L45 for API errors, L62 for validation errors). Which one should be updated?

— PR Resolver (automated)
```

## Patterns & Anti-Patterns

### DO
- Read full file context (not just the diff hunk)
- Check if the suggested change already exists elsewhere in the file
- Match the repo's existing code style
- Run the specific test file for the changed code, not just `pytest`
- Reply even if no code change needed (acknowledge the comment)

### DON'T
- Rewrite large sections of code
- Add imports that aren't used
- Change function signatures without updating all callers
- Create new files to resolve a comment
- Respond to bot-generated comments (CI bots, coverage bots)
- Respond to your own comments (infinite loop!)
- Make optimistic changes ("while I'm here, let me also...")

## Edge Cases

### Comment on deleted line
Read the PR diff to understand why the line was removed. Reply explaining the removal reason.

### Comment references another file
Read both files. Make changes in the referenced file if that's what the reviewer wants.

### Comment is about test quality
Improve the specific test mentioned. Don't rewrite the entire test file.

### Comment is a multi-part request
Break into steps. Fix each part in a single commit. Reply addressing each point.

### Merge conflict after fix
Don't resolve merge conflicts. Flag to Telegram: "PR #{number} has merge conflicts after fix attempt."

## GitHub API Patterns

### Get PR review comments (inline on code)
```bash
gh api repos/{owner}/{repo}/pulls/{pr}/comments \
  --jq '.[] | {id, body, path, line, user: .user.login, created_at}'
```

### Get issue comments (general PR discussion)
```bash
gh api repos/{owner}/{repo}/issues/{pr}/comments \
  --jq '.[] | {id, body, user: .user.login, created_at}'
```

### Reply to a review comment
```bash
gh api repos/{owner}/{repo}/pulls/{pr}/comments/{comment_id}/replies \
  -f body="✅ Resolved — {summary}\n\n— PR Resolver (automated)"
```

### Reply to issue comment
```bash
gh api repos/{owner}/{repo}/issues/{pr}/comments \
  -f body="✅ Resolved — {summary}\n\n— PR Resolver (automated)"
```

### Get PR diff
```bash
gh pr diff {pr_number} --repo {owner}/{repo}
```

### Get PR branch
```bash
gh pr view {pr_number} --repo {owner}/{repo} --json headRefName --jq '.headRefName'
```
