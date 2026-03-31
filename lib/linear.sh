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
# LLM Context Summarizer [NEW]
#
# Reads the raw Linear ticket text and produces a concise 3-sentence summary
# of the business logic and acceptance criteria. This avoids overwhelming the
# fixer/reviewer agents with irrelevant Linear/Jira fluff.
###############################################################################

linear_summarize_context() {
    local raw_context="$1"
    [[ -z "$raw_context" ]] && return 1

    # Truncate input to avoid token explosion in the summarizer itself
    local truncated_input
    truncated_input=$(echo "$raw_context" | head -c 3000)

    local summarize_prompt
    summarize_prompt="You are a technical writer summarizing Linear (project management) ticket context for a code-reviewing AI agent.

Read the following ticket data and produce a clear, concise summary in EXACTLY 3 sentences:
1. What is the goal of this ticket? (the business problem being solved)
2. What are the key acceptance criteria or constraints the code must satisfy?
3. What should the PR reviewer know to evaluate whether a code comment is valid or out of scope?

Be specific and technical. Avoid filler phrases. Do not include the ticket ID or title in your output.

Ticket data:
\"\"\"${truncated_input}\"\"\"

SUMMARY:"

    local summary
    local summarize_session_id="pr-summarize-$(date +%s)-$$-${RANDOM}"
    summary=$(timeout "${LLM_SUMMARIZE_TIMEOUT:-20}" openclaw agent --local \
        \
        --session-id "$summarize_session_id" \
        --message "$summarize_prompt" \
        --timeout "${LLM_SUMMARIZE_TIMEOUT:-20}" \
        2>/dev/null) || true

    if [[ -z "$summary" ]]; then
        # Graceful degradation: return original truncated context if LLM fails
        echo "$raw_context"
        return 0
    fi

    echo "$summary"
}

###############################################################################
# Fetch issues by state and extract attached GitHub PRs [NEW]
###############################################################################

linear_get_issues_by_state() {
    local state_name="$1"
    [[ -z "$state_name" ]] && return 1

    # Step 1: Fetch all matching issue identifiers (assigned to me, in given state)
    local list_query='
    {
      issues(filter: {
        state: { name: { eq: "'"$state_name"'" } },
        assignee: { email: { eq: "aditya@ruh.ai" } }
      }) {
        nodes {
          identifier
          title
          description
          branchName
          attachments(first: 25) {
            nodes { sourceType url }
          }
          comments(first: 50) {
            nodes { body user { name } }
          }
        }
      }
    }'

    local response
    response=$(linear_graphql "$list_query") || return 1

    # Output Format: TicketID|RepoName|PRNumber|BranchName|TicketTitle
    #
    # PR source: ONLY the latest comment by shivam@ruh.ai (Sentinel PR Review Bot).
    # The Sentinel bot posts PR URLs in the format:
    #   "PR: https://github.com/org/repo/pull/NUMBER"
    # We find the most recent such comment and extract the PR URL from it.
    echo "$response" | jq -r '
      .data.issues.nodes[] |
      .identifier as $ticketId |
      .title as $title |
      .branchName as $branch |
      # Get the latest comment by shivam@ruh.ai (comments are ordered oldest-first, so last = newest)
      ([ .comments.nodes[] | select(.user.name == "shivam@ruh.ai") ] | last) as $sentinelComment |
      # Skip ticket if no Sentinel comment found
      if $sentinelComment == null then empty else
        ($sentinelComment.body |
          scan("https?://(?:www\\.)?github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+") |
          capture("https?://(?:www\\.)?github\\.com/(?<org>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+)/pull/(?<pr>[0-9]+)") |
          "\($ticketId)|\(.org)/\(.repo)|\(.pr)|\($branch // "")|\($title)"
        )
      end
    ' 2>/dev/null | sort -u
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

    # --- Build the full raw context block ---
    local raw_context
    raw_context=$(cat <<EOF
**${identifier}: ${title}**
- State: ${state} | Priority: ${priority} | Assignee: ${assignee}
- Labels: ${labels} | Parent: ${parent}

Description:
${description}

Related Issues: ${relations}
Sub-tasks: ${subtasks}

Recent Team Comments:
  - ${comments}

Linked PRs:
  - ${pr_links}
EOF
)

    # Pipe through LLM summarizer to produce a compact 3-sentence context block
    local summary
    summary=$(linear_summarize_context "$raw_context") || summary="$raw_context"

    cat <<EOF
## Linear Ticket Context — ${identifier}: ${title}

${summary}

---

**Goal of this PR:** Implement ${title} as described above.
**Evaluate comments against this context:**
- **Valid**: Aligns with ticket intent or is a genuine code quality issue
- **Invalid**: Contradicts ticket requirements or is out of scope
- **Actionable**: Specific enough to implement (clear expected outcome)
- **Not actionable**: Vague, opinion-based, or requires a product decision
Only implement changes that are both VALID and ACTIONABLE.
EOF
}

###############################################################################
# Post a comment on a Linear issue — direct GraphQL (ClawHub skill not required)
###############################################################################

linear_post_comment() {
    local ticket_id="$1"
    local comment_body="$2"
    [[ -z "$ticket_id" || -z "$comment_body" ]] && return 1
    [[ -z "${LINEAR_API_KEY:-}" ]] && return 1

    # Step 1: Resolve ticket identifier to UUID
    local issue_data issue_uuid
    issue_data=$(curl -s -X POST "https://api.linear.app/graphql" \
        -H "Content-Type: application/json" \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -d "{\"query\": \"{ issue(id: \\\"${ticket_id}\\\") { id } }\"}" \
        --max-time 15 2>/dev/null)
    issue_uuid=$(echo "$issue_data" | jq -r '.data.issue.id // empty')
    [[ -z "$issue_uuid" ]] && return 1

    # Step 2: Create the comment
    local result
    result=$(curl -s -X POST "https://api.linear.app/graphql" \
        -H "Content-Type: application/json" \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -d "$(jq -n --arg issueId "$issue_uuid" --arg body "$comment_body" \
            '{query: "mutation CreateComment($issueId: String!, $body: String!) { commentCreate(input: { issueId: $issueId, body: $body }) { success } }", variables: {issueId: $issueId, body: $body}}')" \
        --max-time 15 2>/dev/null)

    echo "$result" | jq -e '.data.commentCreate.success == true' >/dev/null 2>&1
}

###############################################################################
# Update issue status — direct GraphQL (ClawHub skill not required)
###############################################################################

linear_update_status() {
    local ticket_id="$1"
    local new_status="$2"
    [[ -z "$ticket_id" || -z "$new_status" ]] && return 1
    [[ -z "${LINEAR_API_KEY:-}" ]] && return 1

    # Step 1: Get the issue's UUID and team name
    local issue_data
    issue_data=$(curl -s -X POST "https://api.linear.app/graphql" \
        -H "Content-Type: application/json" \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -d "{\"query\": \"{ issue(id: \\\"${ticket_id}\\\") { id team { id name } } }\"}" \
        --max-time 15 2>/dev/null)

    local issue_uuid team_id
    issue_uuid=$(echo "$issue_data" | jq -r '.data.issue.id // empty')
    team_id=$(echo "$issue_data" | jq -r '.data.issue.team.id // empty')
    [[ -z "$issue_uuid" || -z "$team_id" ]] && return 1

    # Step 2: Find the workflow state ID for the given name within this team
    local states_data state_id
    states_data=$(curl -s -X POST "https://api.linear.app/graphql" \
        -H "Content-Type: application/json" \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -d "{\"query\": \"{ workflowStates(filter: { name: { eq: \\\"${new_status}\\\" }, team: { id: { eq: \\\"${team_id}\\\" } } }) { nodes { id name } } }\"}" \
        --max-time 15 2>/dev/null)

    state_id=$(echo "$states_data" | jq -r '.data.workflowStates.nodes[0].id // empty')
    [[ -z "$state_id" ]] && return 1

    # Step 3: Update the issue state
    local update_result
    update_result=$(curl -s -X POST "https://api.linear.app/graphql" \
        -H "Content-Type: application/json" \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -d "{\"query\": \"mutation { issueUpdate(id: \\\"${issue_uuid}\\\", input: { stateId: \\\"${state_id}\\\" }) { success } }\"}" \
        --max-time 15 2>/dev/null)

    echo "$update_result" | jq -e '.data.issueUpdate.success == true' >/dev/null 2>&1
}
