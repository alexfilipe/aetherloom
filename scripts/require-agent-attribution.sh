#!/usr/bin/env bash
# PreToolUse hook: refuse to post a GitHub comment as the user without agent
# attribution. Wired up for both Claude Code (.claude/settings.json) and Codex
# (.codex/hooks/hooks.json), which share this hook protocol.
#
# A comment reads as written by whoever's account posted it, so an agent
# posting under the maintainer's account silently claims authorship. AGENTS.md
# requires every agent-posted PR comment to begin with "Authored by agent: ";
# this makes the rule fail loudly instead of depending on the agent to
# remember it.
#
# Commits are deliberately out of scope: automating those is expected, and
# their authorship is a separate mechanism (git config, not the API token).
#
# Reads the PreToolUse payload on stdin. Silence means allow; the JSON at the
# bottom denies the call and tells the agent how to fix it.
set -uo pipefail

PREFIX='Authored by agent: '

# The two harnesses spell the command differently: Claude Code sends a shell
# string, Codex sends argv. Accept either, and any of the keys they use, so one
# script covers both.
command_text=$(jq -r '
  [.tool_input // {} | .command?, .argv?, .cmd?]
  | map(select(. != null))
  | map(if type == "array" then map(tostring) | join(" ") else tostring end)
  | join(" ")
' 2>/dev/null) || exit 0
[ -n "$command_text" ] || exit 0

matches() { printf '%s' "$command_text" | grep -qE "$1"; }

# Subcommands that exist only to post a comment or review.
posts_via_subcommand='gh[[:space:]]+(pr[[:space:]]+(comment|review)|issue[[:space:]]+comment)'
# Raw API calls against a comment/review collection.
touches_comment_api='gh[[:space:]]+api[[:space:]][^|;&]*(comments|reviews)'

if ! matches "$posts_via_subcommand" && ! matches "$touches_comment_api"; then
  exit 0
fi

# Reading comments is fine — only gate an API call that writes one. gh api
# defaults to GET, so require a sign of a write before treating it as a post.
if ! matches "$posts_via_subcommand"; then
  writes='(-f|-F|--field|--raw-field|--input|-X[[:space:]]*(POST|PATCH|PUT)|--method[[:space:]]+(POST|PATCH|PUT))'
  matches "$writes" || exit 0
fi

# A review that only approves or requests changes carries no comment body.
if matches 'gh[[:space:]]+pr[[:space:]]+review' && ! matches '(--body|--body-file|-b[[:space:]])'; then
  exit 0
fi

if printf '%s' "$command_text" | grep -qF "$PREFIX"; then
  exit 0
fi

cat <<JSON
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"This posts a GitHub comment under the maintainer's account without agent attribution. AGENTS.md requires an agent-posted comment to begin with the exact prefix '${PREFIX}'. Put that prefix at the start of the comment body and run it again. (Commits are out of scope for this rule.)"}}
JSON
