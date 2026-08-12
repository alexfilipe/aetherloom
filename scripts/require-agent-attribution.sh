#!/usr/bin/env bash
# PreToolUse hook: refuse to post a GitHub comment without agent attribution.
#
# A comment is attributed to whoever's account posted it, so an agent posting
# under the maintainer's account silently claims authorship. AGENTS.md requires
# an agent-posted comment to begin with "Authored by agent: "; this makes that
# fail loudly instead of relying on the agent to remember.
#
# Commits are out of scope: automating those is expected, and their authorship
# comes from git config rather than the API token.
#
# Wired up for Claude Code (.claude/settings.json) and Codex
# (.codex/hooks/hooks.json), which share this hook protocol. Silence allows the
# call; the JSON at the end denies it. Anything not recognized as a comment post
# is allowed; anything recognized as one must show the prefix at the body's
# start, so an unverifiable post is refused rather than let through.
set -uo pipefail

PREFIX='Authored by agent: '

payload=$(cat)
get() { printf '%s' "$payload" | jq -r "$1" 2>/dev/null; }

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}' \
    "$(printf '%s posts a GitHub comment under the maintainer'"'"'s account without agent attribution. AGENTS.md requires the body to begin with the exact prefix "%s". Put it at the very start of the body — not elsewhere in it — and run again. Commits are out of scope. A body passed by file or stdin cannot be checked here, so inline it with --body.' "$1" "$PREFIX" | jq -Rs .)"
  exit 0
}

# Claude Code sends a shell string; Codex sends argv. Accept either.
cmd=$(get '[.tool_input // {} | .command?, .argv?, .cmd?]
  | map(select(. != null))
  | map(if type == "array" then map(tostring) | join(" ") else tostring end)
  | join(" ")')

# The prefix must sit at the start of a body, i.e. directly after a body
# specifier: --body, -b, body= (gh api field) or body: (GraphQL literal).
anchored="(--body|-b|body)[=:[:space:]]+[\"']?${PREFIX}"

if [ -n "$cmd" ]; then
  case $cmd in *gh*) ;; *) exit 0 ;; esac

  posts=0
  # Subcommands that exist to write a comment or review.
  [[ $cmd =~ gh[[:space:]]+(pr[[:space:]]+(comment|review)|issue[[:space:]]+comment) ]] && posts=1
  # REST writes against a comment/review collection (gh api defaults to GET).
  [[ $cmd =~ gh[[:space:]]+api ]] && [[ $cmd =~ (comments|reviews|replies) ]] &&
    [[ $cmd =~ (-f|-F|--field|--raw-field|--input|-X[[:space:]]*(POST|PATCH|PUT)|--method[[:space:]]+(POST|PATCH|PUT)) ]] && posts=1
  # GraphQL mutations that create or edit a comment or review body.
  [[ $cmd =~ gh[[:space:]]+api[[:space:]]+graphql ]] &&
    [[ $cmd =~ (addComment|addDiscussionComment|addPullRequestReview|addPullRequestReviewComment|submitPullRequestReview|updateIssueComment|updateDiscussionComment|updatePullRequestReview|updatePullRequestReviewComment) ]] && posts=1

  (( posts )) || exit 0

  # Forms that post no agent-written body: deleting one, or handing authoring
  # to a human in the browser.
  [[ $cmd =~ --delete-last ]] && exit 0
  [[ $cmd =~ (--web|[[:space:]]-w([[:space:]]|$)) ]] && exit 0
  # A review that only approves or requests changes carries no body.
  [[ $cmd =~ gh[[:space:]]+pr[[:space:]]+review ]] && ! [[ $cmd =~ (--body|-b[[:space:]]) ]] && exit 0

  [[ $cmd =~ $anchored ]] && exit 0
  deny "This command"
fi

# No shell command: a connector/MCP tool that writes a comment through
# structured input. Only what this hook can see is covered.
tool=$(get '.tool_name // ""')
if [[ $tool =~ (github|GitHub|gh_) ]] && [[ $tool =~ (comment|review|reply|discussion) ]] &&
   ! [[ $tool =~ (list|get_|read|search|fetch) ]]; then
  body=$(get '.tool_input.body // .tool_input.comment // .tool_input.text // ""')
  [ -z "$body" ] && exit 0
  case $body in "$PREFIX"*) exit 0 ;; esac
  deny "The $tool tool"
fi

exit 0
