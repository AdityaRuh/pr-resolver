#!/usr/bin/env bash
# linear.sh — Linear integration for PR Resolver
#
# Wraps the ClawHub Linear skill (manuelhettich/linear) for:
#   - Extracting ticket IDs from branch names
#   - Fetching issue details via the installed skill
#   - Posting comments on Linear issues
#   - Formatting ticket context for agent prompts
#   - Fetching rich context: acceptance criteria, linked PRs, comments
#
# Requires: LINEAR_API_KEY env var
# Depends:  ClawHub linear skill installed at ~/.openclaw/workspace/skills/linear

# Path to the ClawHub Linear skill's CLI script
LINEAR_SKILL_SCRIPT="${LINEAR_SKILL_SCRIPT:-${HOME}/.openclaw/workspace/skills/linear/scripts/linear.sh}"

###############################################################################
# Extract ticket ID from branch name
###############################################################################

linear_extract_ticket_id() {
    local branch="$1"
    # Match patterns like RP-358, PROJ-12, AB-1234 (1-5 uppercase letters + dash + digits)
    # Handles prefixes like dev/ or feature/ before the ticket ID
    echo "$branch" | grep -oE '[A-Z]{1,5}-[0-9]+' | head -1
}

###############################################################################
# Call the ClawHub Linear skill CLI
###############################################################################

linear_cli() {
    [[ -z "${LINEAR_API_KEY:-}" ]] && return 1
    [[ ! -f "$LINEAR_SKILL_SCRIPT" ]] && return 1
    LINEAR_API_KEY="$LINEAR_API_KEY" bash "$LINEAR_SKILL_SCRIPT" "$@" 2>/dev/null
}

###############################################################################
# Direct GraphQL query to Linear API (for fields the skill doesn't expose)
###############################################################################

linear_graphql() {
    local query="$1"
    [[ -z "${LINEAR_API_KEY:-}" ]] && return 1
    curl -s -X POST "https://api.linear.app/graphql" \
        -H "Content-Type: application/json" \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -d "{\"query\": $(echo "$query" | jq -Rs .)}" \
        --max-time 15 2>/dev/null
}

###############################################################################
# Fetch issue details by identifier (e.g., RP-358) — uses ClawHub skill
###############################################################################

linear_get_issue() {
    local ticket_id="$1"
    [[ -z "$ticket_id" ]] && return 1
    [[ -z "${LINEAR_API_KEY:-}" ]] && return 1

    local detail
    detail=$(linear_cli issue "$ticket_id") || return 1
    [[ -z "$detail" ]] && return 1

    echo "$detail"
}

###############################################################################
# Fetch rich context: acceptance criteria, comments, linked issues, labels
###############################################################################

linear_get_rich_context() {
    local ticket_id="$1"
    [[ -z "$ticket_id" ]] && return 1

    local query='
    {
      issue(id: "'"$ticket_id"'") {
        identifier
        title
        description
        state { name }
        priority
        priorityLabel
        assignee { name }
        labels { nodes { name } }
        comments(first: 5) {
          nodes { body user { name } createdAt }
        }
        relations {
          nodes {
            type
            relatedIssue { identifier title state { name } }
          }
        }
        attachments(first: 5) {
          nodes { title url sourceType }
        }
        parent { identifier title }
        children { nodes { identifier title state { name } } }
      }
    }'

    local response
    response=$(linear_graphql "$query") || return 1

    # Extract the issue node
    local node
    node=$(echo "$response" | jq -r '.data.issue // empty' 2>/dev/null)
    [[ -z "$node" || "$node" == "null" ]] && return 1

    echo "$node"
}

###############################################################################
# Format issue details into a context block for agent prompts
###############################################################################

linear_format_context() {
    local issue_detail="$1"
    [[ -z "$issue_detail" ]] && return 1

    # Truncate description to first 1500 chars for prompt efficiency
    local truncated
    truncated=$(echo "$issue_detail" | head -c 1500)

    cat <<EOF
## Linear Ticket Context
${truncated}

Use this context to evaluate whether review comments are valid and actionable:
- **Valid**: Comment aligns with the ticket's intent or is a genuine code quality issue
- **Invalid**: Comment contradicts the ticket requirements or is out of scope
- **Actionable**: Specific enough to implement (has a clear expected outcome)
- **Not actionable**: Vague, opinion-based, or requires a product decision
Only implement changes that are both VALID and ACTIONABLE.
EOF
}

###############################################################################
# Format RICH context (with acceptance criteria, comments, relations)
###############################################################################

linear_format_rich_context() {
    local rich_json="$1"
    [[ -z "$rich_json" ]] && return 1

    local identifier title description state priority assignee
    identifier=$(echo "$rich_json" | jq -r '.identifier // "unknown"')
    title=$(echo "$rich_json" | jq -r '.title // "untitled"')
    description=$(echo "$rich_json" | jq -r '.description // "no description"' | head -c 1200)
    state=$(echo "$rich_json" | jq -r '.state.name // "unknown"')
    priority=$(echo "$rich_json" | jq -r '.priorityLabel // "none"')
    assignee=$(echo "$rich_json" | jq -r '.assignee.name // "unassigned"')

    # Labels
    local labels
    labels=$(echo "$rich_json" | jq -r '[.labels.nodes[].name] | join(", ")' 2>/dev/null)
    [[ -z "$labels" ]] && labels="none"

    # Parent issue
    local parent
    parent=$(echo "$rich_json" | jq -r 'if .parent then .parent.identifier + ": " + .parent.title else "none" end' 2>/dev/null)

    # Related issues
    local relations
    relations=$(echo "$rich_json" | jq -r '[.relations.nodes[] | .type + " " + .relatedIssue.identifier + " (" + .relatedIssue.state.name + ")"] | join("\n  - ")' 2>/dev/null)
    [[ -z "$relations" ]] && relations="none"

    # Sub-tasks
    local subtasks
    subtasks=$(echo "$rich_json" | jq -r '[.children.nodes[] | .identifier + ": " + .title + " (" + .state.name + ")"] | join("\n  - ")' 2>/dev/null)
    [[ -z "$subtasks" ]] && subtasks="none"

    # Recent comments (last 3, truncated)
    local comments
    comments=$(echo "$rich_json" | jq -r '[.comments.nodes[:3][] | .user.name + ": " + (.body | gsub("\n"; " ") | .[:200])] | join("\n  - ")' 2>/dev/null)
    [[ -z "$comments" ]] && comments="none"

    # GitHub PR links from attachments
    local pr_links
    pr_links=$(echo "$rich_json" | jq -r '[.attachments.nodes[] | select(.sourceType == "github") | .title + " → " + .url] | join("\n  - ")' 2>/dev/null)
    [[ -z "$pr_links" ]] && pr_links="none"

    cat <<EOF
## Linear Ticket Context (Rich)

**${identifier}: ${title}**
- **State:** ${state} | **Priority:** ${priority} | **Assignee:** ${assignee}
- **Labels:** ${labels}
- **Parent:** ${parent}

### Description
${description}

### Acceptance Criteria
$(echo "$description" | grep -iE '(accept|criteria|requirement|must|should|given|when|then|todo|checklist|\[ \]|\[x\])' | head -10)

### Related Issues
  - ${relations}

### Sub-tasks
  - ${subtasks}

### Recent Team Comments
  - ${comments}

### Linked PRs
  - ${pr_links}

---

**Use this context to evaluate review comments:**
- **Valid**: Aligns with ticket intent or is a genuine code quality issue
- **Invalid**: Contradicts ticket requirements or is out of scope
- **Actionable**: Specific enough to implement (clear expected outcome)
- **Not actionable**: Vague, opinion-based, or requires a product decision
- **Goal of this PR:** Implement ${title} as described above
Only implement changes that are both VALID and ACTIONABLE.
EOF
}

###############################################################################
# Post a comment on a Linear issue — uses ClawHub skill
###############################################################################

linear_post_comment() {
    local ticket_id="$1"
    local comment_body="$2"
    [[ -z "$ticket_id" || -z "$comment_body" ]] && return 1
    [[ -z "${LINEAR_API_KEY:-}" ]] && return 1

    local result
    result=$(linear_cli comment "$ticket_id" "$comment_body") || return 1

    # ClawHub skill returns "Comment added" on success
    echo "$result" | grep -qi "comment added"
}

###############################################################################
# Update issue status — uses ClawHub skill
###############################################################################

linear_update_status() {
    local ticket_id="$1"
    local new_status="$2"
    [[ -z "$ticket_id" || -z "$new_status" ]] && return 1
    [[ -z "${LINEAR_API_KEY:-}" ]] && return 1

    linear_cli status "$ticket_id" "$new_status" 2>/dev/null || return 1
}
