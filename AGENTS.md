# Agents — PR Resolver v3 (Ticket-Driven)

## Agent Portfolio

| # | Agent | Role | Trigger | Cost |
|---|-------|------|---------|------|
| 1 | Linear Ticket Poller | Poll Linear for "In Development" tickets | Every 30 min | FREE |
| 2 | Ticket Detail Fetcher | Fetch rich ticket context via API | Per ticket | FREE |
| 3 | PR Identifier | Detect associated PR from ticket links/metadata | Per ticket | FREE |
| 4 | Comment Fetcher | Fetch inline + discussion comments | Per PR | FREE |
| 5 | Comment Deduplicator | Skip processed/bot/self comments | Per comment | FREE |
| 6 | Comment Classifier | Classify comment intent (regex + LLM) | Per comment | FREE (regex) / LLM (semantic) |
| 7 | Intent Router | Route to skip/flag/answer/fix based on intent | Per comment | FREE |
| 8 | Context Summarizer | Summarize Linear ticket via LLM | Per PR with ticket | LLM Credits (fast model) |
| 9 | Diff Extractor | Extract PR diff + changed files | Per PR | FREE |
| 10 | Codebase Explorer | Understand project structure + conventions | Before fix | FREE |
| 11 | Planning Agent | Create modification plan with files + approach | Before fix | LLM Credits |
| 12 | Branch Preparer | Checkout/create branch from latest dev | Before fix | FREE |
| 13 | Code Fixer | Read context, make fix, validate (no commit) | Per actionable comment | LLM Credits |
| 14 | Independent Code Reviewer | Verify fixer diff before commit | After fixer output | LLM Credits |
| 15 | Test Runner | Run lint + tests after fix | After fix | FREE |
| 16 | Committer | Stage + commit changes | After tests pass | FREE |
| 17 | Branch Pusher | Push branch to origin | After commit | FREE |
| 18 | PR Creator | Create PR if none exists | When no PR found | FREE |
| 19 | CI Observer | Watch pipeline, fix failures, re-push | After push | FREE → LLM if fix needed |
| 20 | Linear State Transitioner | Move ticket to "Code Review" | All resolved + CI green | FREE |
| 21 | Summary Reporter | Post final summary | End of cycle | FREE |
| 22 | Agent Command Handler | Process /agent override commands | AGENT_COMMAND intent | FREE |
| 23 | Idempotency Checker | Detect duplicate fixes via hash | Before fix | FREE |
| 24 | Budget Guard | Enforce per-hour, per-cycle limits | Every fix attempt | FREE |
| 25 | Retry Manager | Retry transient failures with backoff | On timeout/unclear | LLM Credits |
| 26 | Conflict Handler | Rebase + detect merge conflicts | Before push | FREE |
| 27 | Partial Fix Reporter | Track resolved/pending/failed per PR | After all comments | FREE |
| 28 | Metrics Recorder | Track success rate, fix times, failures | Every action | FREE |
| 29 | Conflict Flagger | Detect subjective/unclear, notify human | SUBJECTIVE intent | FREE |
| 30 | Question Answerer | Read context, answer question | QUESTION intent | LLM Credits |

## Monitored Repos

```yaml
repos:
  - name: strapi-service
    org: ruh-ai
    url: https://github.com/ruh-ai/strapi-service
    status: active

  - name: hubspot-mcp
    org: ruh-ai
    url: https://github.com/ruh-ai/hubspot-mcp
    status: active

  - name: salesforce-mcp
    org: ruh-ai
    url: https://github.com/ruh-ai/salesforce-mcp
    status: active

  - name: sdr-backend
    org: ruh-ai
    url: https://github.com/ruh-ai/sdr-backend
    status: active

  - name: inbox-rotation-service
    org: ruh-ai
    url: https://github.com/ruh-ai/inbox-rotation-service
    status: active

  - name: sdr-management-mcp
    org: ruh-ai
    url: https://github.com/ruh-ai/sdr-management-mcp
    status: active
```

## Sub-Agent Details

### 1. Linear Ticket Poller
```
Method:    Linear GraphQL API (curl + jq)
Cost:      Zero credits
Input:     Linear state filter ("In Development")
Output:    List of tickets with linked PR references
Speed:     <3s
Schedule:  Every 30 min (*/30 * * * *)
Requires:  LINEAR_API_KEY env var
```

### 2. Ticket Detail Fetcher
```
Method:    Linear GraphQL API (curl + jq)
Cost:      Zero credits
Input:     Ticket ID
Output:    Title, description, acceptance criteria, labels, metadata,
           linked PR references, comments, attachments, integrations
Speed:     <2s per ticket
Requires:  LINEAR_API_KEY env var
```

### 3. PR Identifier
```
Method:    Regex + API parsing (no LLM)
Cost:      Zero credits
Input:     Ticket data (comments, attachments, metadata)
Output:    GitHub repo + PR number, or "no PR found"
Speed:     <1s
Fallback:  No PR found → skip OR trigger new branch + PR creation
```

### 4. Comment Fetcher
```
Method:    gh CLI / GitHub API
Cost:      Zero credits
Input:     Repo + PR number
Output:    Inline review comments + general discussion comments (JSON)
Speed:     <2s per PR
```

### 5. Comment Deduplicator
```
Method:    JSON lookup (processed-comments.json)
Cost:      Zero credits
Input:     Comment IDs
Output:    Filtered list (new comments only)
Speed:     <1ms
Checks:    Already processed IDs, bot signatures, own comments
```

### 6. Comment Classifier [Hybrid: regex + LLM]
```
Method:    Stage 1: regex (SELF, CI_BOT, AGENT_COMMAND)
           Stage 2: LLM (all others)
Cost:      Zero (regex tier) / LLM credits (semantic tier, fast model ~15s)
Input:     Comment body text
Output:    Intent classification string
Intents:   SELF, CI_BOT, AGENT_COMMAND, EXPLICIT_REQUEST, CODE_CHANGE,
           QUESTION, APPROVAL, SUBJECTIVE, NITPICK, UNKNOWN
```

### 7. Intent Router
```
Method:    Bash case/switch (no LLM)
Cost:      Zero credits
Input:     Classified intent
Output:    Action routing decision
Speed:     <1ms
```

### 8. Context Summarizer [LLM-backed]
```
Method:    OpenClaw agent (fast LLM)
Cost:      LLM credits (fast model, ~20s timeout)
Input:     Raw ticket text (description, comments, relations, criteria)
Output:    3-sentence technical summary of business logic + acceptance criteria
Fallback:  Returns original truncated context if LLM fails
```

### 9. Diff Extractor
```
Method:    gh CLI (no LLM)
Cost:      Zero credits
Input:     Repo + PR number + optional file path
Output:    Changed files list + file-specific diff hunks
Speed:     <3s per PR
```

### 10. Codebase Explorer [NEW]
```
Method:    find + grep (no LLM)
Cost:      Zero credits
Input:     Working directory + keywords from comment
Output:    Project structure map, affected modules, pattern conventions
Speed:     <5s
Commands:  find <dir> -maxdepth 3 -type f (excluding node_modules, .git, dist)
           grep -r "<keyword>" <dir> --include="*.ts" --include="*.js" --include="*.py" -l
Purpose:   Understand codebase structure before making changes
```

### 11. Planning Agent [NEW]
```
Method:    LLM-backed planning
Cost:      LLM credits
Input:     Ticket context + PR diff + codebase structure + comment
Output:    Structured plan: files to modify/create, approach, risks
Format:    ## Plan for <TICKET-ID>
           Files to modify: ...
           Files to create: ...
           Approach: ...
           Risks / Assumptions: ...
```

### 12. Branch Preparer [NEW — MANDATORY]
```
Method:    git CLI (no LLM)
Cost:      Zero credits
Input:     PR branch name
Output:    Clean working branch synced with latest dev
Speed:     <10s
Steps:     fetch → stash → checkout dev → pull dev → checkout PR branch → merge dev
Critical:  NEVER skip git pull origin dev
Handles:   Remote exists (sync), local only (reuse/ask), no branch (create from dev)
```

### 13. Code Fixer [UPGRADED — no commit]
```
Method:    OpenClaw agent (LLM)
Cost:      Credits per invocation
Input:     Summarized context + PR diff + comment + file context + codebase structure
Output:    Code fix on disk + CONFIDENCE + RISK assessment (NO commit/push)
Timeout:   600s (10 min)
Retries:   Up to 2 (transient failures only)
Backoff:   30s, 60s (exponential)
Guidelines: Minimal changes, follow conventions, avoid .env/secrets/build artifacts
```

### 14. Independent Code Reviewer [Impact-focused with retry loop]
```
Method:    OpenClaw agent (LLM) — separate from fixer
Cost:      Credits per invocation (up to 3 review cycles per comment)
Input:     Original comment + fixer's proposed diff
Output:    APPROVED or REJECTED: <reason>
Timeout:   120s (2 min)
Focus:     ONLY checks if change breaks existing functionality or introduces bugs
           Does NOT gate on confidence level or style preferences
Retry:     On REJECT → fixer receives previous diff + rejection reason
           → fixer tries again with full context (up to 3 attempts)
Action:    APPROVED → commit + push → observe CI
           REJECTED 3x → escalate to human
```

### 15. Test Runner
```
Method:    Shell commands (no LLM)
Cost:      Zero credits
Input:     Working directory
Output:    Pass/fail status
Commands:  JS/TS: npm run lint || yarn lint; npm test || yarn test
           Python: pytest; flake8 || ruff
On fail:   Autofix if obvious, otherwise warning
```

### 16. Committer
```
Method:    git CLI (no LLM)
Cost:      Zero credits
Input:     Changed files + ticket ID + summary
Output:    Commit with message: "<TICKET-ID>: <title>\n\n<summary>\n\nResolves: <TICKET-ID>"
```

### 17. Branch Pusher
```
Method:    git CLI (no LLM)
Cost:      Zero credits
Input:     Branch name
Output:    Pushed branch or error
Action:    Stop if authentication fails
```

### 18. PR Creator [NEW]
```
Method:    gh CLI (no LLM)
Cost:      Zero credits
Input:     Branch name + ticket context
Output:    PR URL
Command:   gh pr create --base dev --head <branch>
Includes:  Summary, ticket reference, changes made, tests status
Fallback:  Provide manual PR link if CLI unavailable
```

### 19. CI Observer
```
Method:    gh CLI + LLM for repairs
Cost:      Zero (polling) / LLM credits (repair)
Input:     Repo + PR number
Output:    CI status (green/red) + repair attempts
Max:       5 repair attempts
Polling:   Every 60s, 15 min timeout
On fail:   Extract logs → fix → push → re-observe
```

### 20. Linear State Transitioner
```
Method:    Linear API (no LLM)
Cost:      Zero credits
Input:     Ticket ID + resolution status
Output:    Ticket moved to "Code Review" + transition comment posted
Trigger:   ALL actionable comments resolved + ZERO failures + CI green
Speed:     <2s
```

### 21. Summary Reporter
```
Method:    Template rendering (no LLM)
Cost:      Zero credits
Output:    Final summary:
           ✔ Ticket processed
           ✔ Code updated
           ✔ Branch created
           ✔ PR created/updated
           ✔ Tests executed
           ✔ Ticket moved to Code Review
```

### 22. Agent Command Handler
```
Method:    Bash pattern matching (no LLM)
Cost:      Zero credits
Input:     /agent <command> comment
Output:    Command execution + PR reply
Commands:  ignore, retry, force-fix, explain, pause
Speed:     <2s per command
```

### 23. Idempotency Checker
```
Method:    SHA-256 hash + JSON lookup (no LLM)
Cost:      Zero credits
Input:     comment_body + file_path + intent
Output:    is_duplicate: true/false
Speed:     <1ms
Storage:   state/fix-signatures.json
```

### 24. Budget Guard
```
Method:    JSON timestamp tracking (no LLM)
Cost:      Zero credits
Limits:    3 per PR per cycle, 10 per cycle, 20 per hour
Storage:   state/budget-tracker.json
Action:    Skip processing when limits reached
```

### 25. Retry Manager
```
Method:    Bash loop with exponential backoff
Cost:      Credits per retry (LLM re-invocation)
Input:     Failed comment resolution
Output:    Retry attempt or permanent failure
Max:       2 retries
Backoff:   30s → 60s
Detects:   Transient (timeout, unclear) vs permanent (test fail, clarification)
```

### 26. Conflict Handler
```
Method:    git pull --rebase (no LLM)
Cost:      Zero credits
Input:     PR branch after fix
Output:    Clean push OR conflict abort + notification
Speed:     <5s
Action:    On conflict: abort rebase, reply on PR, notify Telegram
```

### 27. Partial Fix Reporter
```
Method:    Bash + JSON state (no LLM)
Cost:      Zero credits
Input:     Per-PR comment resolution results
Output:    Summary comment: "Resolved 2/4, 1 failed, 1 remaining"
Trigger:   After processing all comments on a PR with mixed results
```

### 28. Metrics Recorder
```
Method:    JSON append (no LLM)
Cost:      Zero credits
Tracks:    total_fixes, total_failed, total_flagged, total_answered,
           avg_fix_time_s, failure_reasons{}, cycles
Storage:   metrics/metrics.json
CLI:       bash lib/pr-resolver.sh --metrics
```

### 29. Conflict Flagger
```
Method:    Bash + Telegram API (no LLM)
Cost:      Zero credits
Input:     Comment classified as SUBJECTIVE
Output:    Telegram notification + PR reply
Speed:     <2s per comment
```

### 30. Question Answerer
```
Method:    OpenClaw agent (LLM)
Cost:      Credits per invocation
Input:     Linear context + PR diff + question + file context
Output:    Reply on PR with answer
Timeout:   120s (2 min)
```

## Architecture Diagram

```
                    ┌──────────────────┐
                    │  Linear Tickets  │
                    │(In Development) │
                    └────────┬─────────┘
                             │ poll every 30 min
                             ▼
              ┌─────────────────────────────┐
              │  Step 1: Poll Linear         │  FREE
              │  Step 2: Fetch Ticket Details │
              └────────────┬────────────────┘
                           │
                           ▼
              ┌─────────────────────────────┐
              │  Step 3: Identify PR         │  FREE
              │  (links, metadata, comments) │
              └────────────┬────────────────┘
                           │
              ┌────────────┼────────────────┐
              │ PR found                    │ No PR found
              ▼                             ▼
    ┌──────────────────┐          ┌──────────────────┐
    │ Step 4: Fetch    │          │ Skip or create   │
    │ PR Comments      │          │ new branch + PR  │
    └────────┬─────────┘          └──────────────────┘
             │
             ▼
    ┌──────────────────┐
    │ Step 5: Dedup    │  FREE
    │ Step 6: Classify │  FREE (regex) / FAST LLM
    └────────┬─────────┘
             │
    ┌────────┼──────────────┐──────────────┐
    ▼        ▼              ▼              ▼
 ┌──────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
 │ Skip │ │ Flag     │ │ Answer   │ │ Fix      │
 │      │ │(Telegram)│ │(Question)│ │(Code)    │
 └──────┘ └──────────┘ └──────────┘ └────┬─────┘
                                         │
              ┌──────────────────────────┘
              ▼
    ┌──────────────────┐
    │ Step 8: Context  │  FAST LLM
    │ Summarize        │
    ├──────────────────┤
    │ Step 9: Extract  │  FREE
    │ PR Diff          │
    ├──────────────────┤
    │ Step 10: Explore │  FREE
    │ Codebase         │
    ├──────────────────┤
    │ Step 11: Plan    │  LLM
    └────────┬─────────┘
             │
             ▼
    ┌──────────────────┐
    │ Step 12: Prepare │  FREE
    │ Working Branch   │
    │ (pull dev FIRST) │
    └────────┬─────────┘
             │
             ▼
    ┌──────────────────┐
    │ Step 13: Code    │  LLM CREDITS
    │ Implementation   │
    │ (NO commit)      │
    └────────┬─────────┘
             │
             ▼
    ┌──────────────────┐
    │ Step 14: Review  │  LLM CREDITS
    │ (approve/reject) │  (up to 3 cycles)
    └────────┬─────────┘
             │
    ┌────────┼────────────┐
    ▼                     ▼
 ┌──────────┐      ┌──────────┐
 │ REJECTED │      │ APPROVED │
 │ retry or │      └────┬─────┘
 │ escalate │           │
 └──────────┘           ▼
              ┌──────────────────┐
              │ Step 15: Test    │  FREE
              │ + Lint           │
              ├──────────────────┤
              │ Step 16: Commit  │  FREE
              ├──────────────────┤
              │ Step 17: Push    │  FREE
              ├──────────────────┤
              │ Step 18: Create  │  FREE
              │ PR (if needed)   │
              └────────┬─────────┘
                       │
                       ▼
              ┌──────────────────┐
              │ Step 19: CI      │  FREE → LLM
              │ Observation      │  (fix → push ≤5x)
              └────────┬─────────┘
                       │ all green
                       ▼
              ┌──────────────────┐
              │ Step 20: Linear  │  FREE
              │ → "Code Review"  │
              ├──────────────────┤
              │ Step 21: Final   │
              │ Summary          │
              └──────────────────┘
```

## Error Handling Matrix

| Scenario | Action |
|----------|--------|
| Ticket not found | Stop |
| Branch exists (dirty) | Ask or reuse |
| Push fails | Stop + notify |
| CLI unavailable | Provide manual link |
| Tests fail | Autofix if obvious, otherwise warning |
| Not a git repo | Stop |
| Merge conflict | Abort rebase + notify |
| CI fails 5x | Escalate to human |
| Budget exhausted | Skip + report |
| Linear API down | Proceed without ticket context |
| GitHub API rate limited | Backoff + retry |
