# Agents — PR Resolver v3 (LLM-Upgraded)

## Agent Portfolio

| Agent | Role | Trigger | Cost |
|-------|------|---------|------|
| Linear State Poller | Poll Linear for 'In Development' tickets | Every 30 min | FREE |
| Comment Classifier | Classify comment intent (regex + LLM) | Every comment | LLM Credits (fast model) |
| Agent Command Handler | Process /agent override commands | AGENT_COMMAND intent | FREE |
| Context Summarizer | Summarize Linear ticket via LLM | Every PR with ticket branch | LLM Credits (fast model) |
| Linear Context Fetcher | Fetch rich ticket context via API | Every PR with ticket branch | FREE |
| Diff Extractor | Extract PR diff + changed files | Before LLM invocation | FREE |
| Idempotency Checker | Detect duplicate fixes via hash | Before LLM invocation | FREE |
| Code Fixer | Read context, make fix, validate (no commit) | CODE_CHANGE / NITPICK / EXPLICIT | LLM Credits |
| Independent Code Reviewer | Verify fixer diff before commit | After fixer agent output | LLM Credits |
| Question Answerer | Read context, answer question | QUESTION intent | LLM Credits |
| Confidence Scorer | Assess fix confidence + risk | After agent output | Included in LLM |
| Retry Manager | Retry transient failures with backoff | On timeout/unclear | LLM Credits |
| Conflict Handler | Rebase + detect merge conflicts | Before push | FREE |
| Partial Fix Reporter | Track resolved/pending/failed per PR | After all comments processed | FREE |
| Budget Guard | Enforce per-hour, per-cycle limits | Every fix attempt | FREE |
| Metrics Recorder | Track success rate, fix times, failures | Every action | FREE |
| Conflict Flagger | Detect subjective/unclear, notify human | SUBJECTIVE / LOW confidence | FREE |
| Linear State Transitioner | Move ticket to 'Code Review' after all resolved | All comments resolved + CI green | FREE |

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

### Comment Classifier [UPGRADED — LLM-backed]
```
Method:    Hybrid: regex (SELF, CI_BOT, AGENT_COMMAND) + LLM (all others)
Cost:      LLM credits (fast model, ~15s timeout) for semantic classification
           Zero credits for regex tier (bot/CI/command detection)
Input:     Comment body text
Output:    Intent classification string
Speed:     <1ms (regex tier) / <15s (LLM tier)
Intents:   SELF, CI_BOT, AGENT_COMMAND, EXPLICIT_REQUEST, CODE_CHANGE,
           QUESTION, APPROVAL, SUBJECTIVE, NITPICK, UNKNOWN
Upgrade:   Handles sarcasm, implicit requests, and nuanced language that
           keyword matching misses. Highest ROI upgrade for reducing false
           positives and wasted fixer credits.
```

### Agent Command Handler [NEW]
```
Method:    Bash pattern matching (no LLM)
Cost:      Zero credits
Input:     /agent <command> comment
Output:    Command execution + PR reply
Commands:  ignore, retry, force-fix, explain, pause
Speed:     <2s per command
```

### Linear Context Fetcher [ENHANCED]
```
Method:    curl + jq (no LLM) — GraphQL API
Cost:      Zero credits
Input:     PR branch name (e.g., RP-358-fix-logout)
Output:    Rich context: title, description, acceptance criteria,
           labels, comments, related issues, sub-tasks, linked PRs
Speed:     <2s per ticket
Requires:  LINEAR_API_KEY env var
Fallback:  Basic context → no context (graceful degradation)
```

### Context Summarizer [NEW — LLM-backed]
```
Method:    OpenClaw agent (fast LLM) — reads raw Linear ticket data
Cost:      LLM credits (fast model, ~20s timeout)
Input:     Raw ticket text (description, comments, relations, criteria)
Output:    3-sentence technical summary of business logic + acceptance criteria
Speed:     <20s
Purpose:   Avoid overwhelming fixer/reviewer agents with irrelevant Linear fluff.
           Saves context window space and reduces hallucination risk.
Fallback:  Returns original truncated context if LLM fails (graceful degradation)
```

### Diff Extractor [NEW]
```
Method:    gh CLI (no LLM)
Cost:      Zero credits
Input:     Repo + PR number + optional file path
Output:    Changed files list + file-specific diff hunks
Speed:     <3s per PR
Purpose:   Scope agent to ONLY PR-relevant files (reduces tokens + prevents off-target changes)
```

### Idempotency Checker [NEW]
```
Method:    SHA-256 hash + JSON lookup (no LLM)
Cost:      Zero credits
Input:     comment_body + file_path + intent
Output:    is_duplicate: true/false
Speed:     <1ms
Storage:   state/fix-signatures.json
Purpose:   Prevent duplicate fixes when same issue raised in multiple comments
```

### Code Fixer [UPGRADED — no longer commits]
```
Method:    OpenClaw agent (LLM)
Cost:      Credits per invocation
Input:     Summarized Linear context + PR diff + comment + file context
Output:    Code fix on disk + confidence/risk assessment (NO commit/push)
Timeout:   600s (10 min)
Retries:   Up to 2 (transient failures only)
Backoff:   30s, 60s (exponential)
Skill:     skills/pr-comment-resolver/SKILL.md
Upgrade:   Fixer modifies files and runs tests but does NOT commit.
           Commit/push is orchestrated by bash after independent review.
           Outputs CONFIDENCE + RISK for the reviewer to assess.
```

### Independent Code Reviewer [UPGRADED — impact-focused with retry loop]
```
Method:    OpenClaw agent (LLM) — separate from fixer
Cost:      Credits per invocation (up to 3 review cycles per comment)
Input:     Original comment + fixer's proposed diff
Output:    APPROVED or REJECTED: <reason>
Timeout:   120s (2 min)
Purpose:   Impact analysis gate — checks if the change breaks existing
           functionality or introduces bugs. Does NOT gate on confidence
           level or style preferences. Only rejects if there's a concrete
           functional issue.
Retry:     On REJECT → fixer receives previous diff + rejection reason
           → fixer tries a different approach with full context of what
           it tried before and why it was rejected (up to 3 attempts)
Action:    APPROVED → commit + push → observe CI pipeline
           REJECTED 3x → escalate to human with all attempt details
```

### Question Answerer
```
Method:    OpenClaw agent (LLM)
Cost:      Credits per invocation
Input:     Linear context + PR diff + question + file context
Output:    Reply on PR with answer
Timeout:   120s (2 min)
Skill:     skills/pr-comment-resolver/SKILL.md
```

### Confidence Scorer [DOWNGRADED — logging only]
```
Method:    Parsed from LLM agent output
Cost:      Included in Code Fixer invocation
Input:     Agent's CONFIDENCE + RISK output lines
Output:    Logged to metrics (does NOT gate push decisions)
Purpose:   Observability — track confidence trends over time
```

### Retry Manager [NEW]
```
Method:    Bash loop with exponential backoff
Cost:      Credits per retry (LLM re-invocation)
Input:     Failed comment resolution
Output:    Retry attempt or permanent failure
Max:       2 retries
Backoff:   30s → 60s
Detects:   Transient (timeout, unclear) vs permanent (test fail, clarification)
```

### Conflict Handler [NEW]
```
Method:    git pull --rebase (no LLM)
Cost:      Zero credits
Input:     PR branch after fix
Output:    Clean push OR conflict abort + notification
Speed:     <5s
Action:    On conflict: abort rebase, reply on PR, notify Telegram
```

### Partial Fix Reporter [NEW]
```
Method:    Bash + JSON state (no LLM)
Cost:      Zero credits
Input:     Per-PR comment resolution results
Output:    Summary comment: "Resolved 2/4, 1 failed, 1 remaining"
Trigger:   After processing all comments on a PR with mixed results
```

### Budget Guard [NEW]
```
Method:    JSON timestamp tracking (no LLM)
Cost:      Zero credits
Limits:    3 per PR per cycle, 10 per cycle, 20 per hour
Storage:   state/budget-tracker.json
Action:    Skip processing when limits reached
```

### Metrics Recorder [NEW]
```
Method:    JSON append (no LLM)
Cost:      Zero credits
Tracks:    total_fixes, total_failed, total_flagged, total_answered,
           avg_fix_time_s, failure_reasons{}, cycles
Storage:   metrics/metrics.json
CLI:       bash lib/pr-resolver.sh --metrics
```

### Conflict Flagger
```
Method:    Bash + Telegram API (no LLM)
Cost:      Zero credits
Input:     Comment classified as SUBJECTIVE
Output:    Telegram notification + PR reply
Speed:     <2s per comment
```

### Linear State Transitioner [NEW]
```
Method:    Linear API via ClawHub skill (no LLM)
Cost:      Zero credits
Input:     Ticket ID + resolution status of all PR comments
Output:    Ticket moved to "Code Review" + transition comment posted
Trigger:   ALL actionable comments resolved + ZERO failures + CI green
Speed:     <2s
Purpose:   Automatically moves the Linear ticket to "Code Review" state
           once the bot has finished resolving all review comments and the
           CI pipeline is green. This signals to the human reviewer that
           the PR is ready for final sign-off.
```

## Architecture Diagram

```
                    ┌──────────────────┐
                    │  Linear Tickets  │
                    │(In Development) │
                    └────────┬─────────┘
                             │ poll every 30 min
                             ▼
                    ┌──────────────────┐
                    │ GitHub PR Mapper │  FREE
                    │ (Attachments)    │
                    └────────┬─────────┘
                             │
                             ▼
                    ┌──────────────────┐
                    │ Comment Classifier│  FAST LLM
                    │ (regex + LLM)     │  (+ regex FREE tier)
                    └────────┬─────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
        ┌──────────┐  ┌──────────┐  ┌──────────┐
        │ Skip     │  │ Flag     │  │ Act      │
        │ (no-op)  │  │ (Telegram)│ │ (LLM)    │
        └──────────┘  └──────────┘  └────┬─────┘
                                         │
                              ┌──────────┼──────────┐
                              ▼          ▼          ▼
                        ┌──────────┐┌────────┐┌──────────┐
                        │ Linear   ││  Diff  ││Idempotency│ FREE
                        │ Context  ││Extract ││  Check    │
                        └────┬─────┘└───┬────┘└────┬─────┘
                             │          │          │
                             ▼          │          │
                     ┌──────────────┐   │          │
                     │  Context     │   │          │
                     │  Summarizer  │   │  FAST LLM
                     │  (LLM)      │   │          │
                     └──────┬───────┘   │          │
                            └───────────┼──────────┘
                                        ▼
                              ┌──────────────────┐
                              │  Code Fixer       │ CREDITS
                              │  (modify files,   │
                              │   NO commit)      │
                              └────────┬─────────┘
                                       │
                                       ▼
                              ┌──────────────────┐
                              │  Independent      │ CREDITS
                              │  Code Reviewer    │
                              │  (approve/reject) │
                              └────────┬─────────┘
                                       │
                        ┌──────────────┼──────────────┐
                        ▼              │              ▼
                 ┌──────────┐          │       ┌──────────┐
                 │ REJECTED │          │       │ APPROVED │
                 │ discard  │          │       │ proceed  │
                 │ + notify │          │       └────┬─────┘
                 └──────────┘          │            │
                                       │            ▼
                              ┌────────┼────────┐
                              ▼        ▼        ▼
                        ┌──────┐ ┌────────┐ ┌──────┐
                        │Confi-│ │ Retry  │ │Confl-│ FREE
                        │dence │ │Manager │ │ict   │
                        │Score │ │(backoff)│ │Check │
                        └──┬───┘ └───┬────┘ └──┬───┘
                           └─────────┼─────────┘
                                     ▼
                           ┌──────────────────┐
                           │  Commit + Push    │
                           │  + Reply on PR    │
                           │  + Linear Update  │
                           │  + Metrics Log    │
                           └────────┬─────────┘
                                    │
                                    ▼
                           ┌──────────────────┐
                           │  CI Pipeline      │
                           │  Observation      │
                           │  (watch → fix →   │
                           │   push, ≤5 tries) │
                           └────────┬─────────┘
                                    │ all green
                                    ▼
                           ┌──────────────────┐
                           │  Move Linear      │  FREE
                           │  Ticket →         │
                           │  "Code Review"    │
                           └──────────────────┘
```
