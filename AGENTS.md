# Agents — PR Resolver v2

## Agent Portfolio

| Agent | Role | Trigger | Cost |
|-------|------|---------|------|
| Comment Classifier | Classify comment intent (bash, no LLM) | Every comment | FREE |
| Agent Command Handler | Process /agent override commands | AGENT_COMMAND intent | FREE |
| Linear Context Fetcher | Fetch rich ticket context via API | Every PR with ticket branch | FREE |
| Diff Extractor | Extract PR diff + changed files | Before LLM invocation | FREE |
| Idempotency Checker | Detect duplicate fixes via hash | Before LLM invocation | FREE |
| Code Fixer | Read context, make fix, validate, push | CODE_CHANGE / NITPICK / EXPLICIT | LLM Credits |
| Question Answerer | Read context, answer question | QUESTION intent | LLM Credits |
| Confidence Scorer | Assess fix confidence + risk | After agent output | Included in LLM |
| Retry Manager | Retry transient failures with backoff | On timeout/unclear | LLM Credits |
| Conflict Handler | Rebase + detect merge conflicts | Before push | FREE |
| Partial Fix Reporter | Track resolved/pending/failed per PR | After all comments processed | FREE |
| Budget Guard | Enforce per-hour, per-cycle limits | Every fix attempt | FREE |
| Metrics Recorder | Track success rate, fix times, failures | Every action | FREE |
| Conflict Flagger | Detect subjective/unclear, notify human | SUBJECTIVE / LOW confidence | FREE |

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

### Comment Classifier
```
Method:    Bash keyword matching (no LLM)
Cost:      Zero credits
Input:     Comment body text
Output:    Intent classification string
Speed:     <1ms per comment
Intents:   SELF, CI_BOT, AGENT_COMMAND, EXPLICIT_REQUEST, CODE_CHANGE,
           QUESTION, APPROVAL, SUBJECTIVE, NITPICK, UNKNOWN
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

### Code Fixer [ENHANCED]
```
Method:    OpenClaw agent (LLM)
Cost:      Credits per invocation
Input:     Linear context + PR diff + comment + file context
Output:    Code fix → confidence/risk assessment → commit → push → reply
Timeout:   600s (10 min)
Retries:   Up to 2 (transient failures only)
Backoff:   30s, 60s (exponential)
Skill:     skills/pr-comment-resolver/SKILL.md
New:       Outputs CONFIDENCE + RISK before committing
           Only pushes if confidence >= MEDIUM and risk <= MEDIUM
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

### Confidence Scorer [NEW]
```
Method:    Parsed from LLM agent output
Cost:      Included in Code Fixer invocation
Input:     Agent's CONFIDENCE + RISK output lines
Output:    Push decision: auto-push / push-with-tag / block
Levels:    HIGH+LOW→🟢 / MEDIUM→🟡 / LOW or HIGH risk→🔴
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

## Architecture Diagram

```
                    ┌──────────────────┐
                    │   GitHub PRs     │
                    │  (6 repos)       │
                    └────────┬─────────┘
                             │ poll every 5 min
                             ▼
                    ┌──────────────────┐
                    │ Comment Classifier│  FREE
                    │ (bash keywords)   │
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
                             └──────────┼──────────┘
                                        ▼
                              ┌──────────────────┐
                              │  OpenClaw Agent   │ CREDITS
                              │  (fix or answer)  │
                              └────────┬─────────┘
                                       │
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
                           │  Push + Reply     │
                           │  + Linear Update  │
                           │  + Metrics Log    │
                           └──────────────────┘
```
