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

### Step 0: Understand Ticket Context (if available)

When a **Linear Ticket Context** block is included in the prompt:
1. Read the ticket title, description, and priority first
2. Understand the **purpose** of this PR — what problem it solves
3. Use this context to evaluate review comments:
   - **Valid + Actionable**: Comment aligns with ticket intent AND is specific enough to implement → Fix it
   - **Valid + Not actionable**: Genuine concern but vague or opinion-based → Ask for clarification
   - **Invalid**: Comment contradicts ticket requirements or is out of scope → Flag as SUBJECTIVE
   - **Code quality**: Style, bugs, or correctness issues are always valid regardless of ticket → Fix them
4. When answering questions, reference the ticket context to explain *why* the code was written this way

If no Linear context is provided, proceed normally without ticket awareness.

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

### Step 2.5: Assess Confidence & Risk (for logging only)

Output your assessment:

```
CONFIDENCE: HIGH|MEDIUM|LOW
RISK: LOW|MEDIUM|HIGH
REASON: <1-line explanation>
```

These scores are logged for metrics but do NOT gate the push. The actual gates are:
1. **Independent Reviewer** — checks if the change breaks existing functionality or introduces bugs. If no impact → approved.
2. **CI Pipeline** — after push, the bot watches the pipeline until all checks are green. If tests fail, the bot auto-fixes and pushes again (up to 5 attempts).

Only output `NEEDS_CLARIFICATION` if the comment is genuinely ambiguous and you cannot determine what change to make.

### Step 3: Make the Fix

Rules for code changes:
- **One commit per comment** — don't batch unrelated fixes
- **Touch only the file(s) in the PR diff** — never modify files outside the diff
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

### Step 5: Stage Changes (Do NOT Commit or Push)

After making your changes and validating they pass:

1. **Leave the modified files on disk** — do NOT run `git add`, `git commit`, or `git push`
2. The orchestrator script will handle committing and pushing after an independent review step
3. If you need to revert your changes (e.g., tests failed), run `git checkout -- .`

```
IMPORTANT: Your job ends at modifying files + running tests.
The orchestrator handles: git add → git commit → independent review → git push
```

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

## Handling CI Failure Logs [NEW]

When you are provided with CI failure logs instead of a review comment:
1.  **Analyze the Logs**: Focus on keywords like `error`, `failed`, `exception`, `FAIL`, or stack traces.
2.  **Locate the Error**: Identify which file and which line caused the failure.
3.  **Correlate**: Look at your recent changes in the PR diff to see if your fix introduced a syntax error, broke a test, or missed a dependency.
4.  **Fix and Validate**: Apply the necessary corrections and ensure you run local tests to double-check the logic.
5.  **Output Format**: Same as standard fixes (SUMMARY, CONFIDENCE, RISK).

Your priority is to get the build status to GREEN.
- Fix ALL errors identified in the provided logs.
- If the error is unrelated to the PR, mention it in the SUMMARY but try to fix it if it's within your repo access.
- If you cannot find the cause, output **FAILED: Could not identify root cause from logs.**

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
