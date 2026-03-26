# Agents — PR Resolver

## Agent Portfolio

| Agent | Role | Trigger |
|-------|------|---------|
| Comment Classifier | Classify comment intent (bash, no LLM) | Every comment |
| Code Fixer | Read context, make fix, validate, push | CODE_CHANGE / NITPICK / EXPLICIT |
| Question Answerer | Read context, answer question | QUESTION intent |
| Conflict Flagger | Detect subjective/unclear, notify human | SUBJECTIVE / LOW confidence |

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
```

### Code Fixer
```
Method:    OpenClaw agent (LLM)
Cost:      Credits per invocation
Input:     Comment + file context + PR diff
Output:    Code fix → commit → push → reply
Timeout:   600s (10 min)
Skill:     skills/pr-comment-resolver/SKILL.md
```

### Question Answerer
```
Method:    OpenClaw agent (LLM)
Cost:      Credits per invocation
Input:     Question + file context
Output:    Reply on PR with answer
Timeout:   120s (2 min)
Skill:     skills/pr-comment-resolver/SKILL.md
```

### Conflict Flagger
```
Method:    Bash + Telegram API (no LLM)
Cost:      Zero credits
Input:     Comment classified as SUBJECTIVE
Output:    Telegram notification + PR reply
Speed:     <2s per comment
```
