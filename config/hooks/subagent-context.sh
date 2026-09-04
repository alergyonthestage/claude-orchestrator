#!/bin/bash
# SubagentStart hook: injects condensed project context into spawned subagents.
# Called automatically by Claude Code when a Task tool spawns a subagent.
# Output: JSON with additionalContext field.

PROJECT="${PROJECT_NAME:-unknown}"
TMODE="${TEAMMATE_MODE:-tmux}"

# Condensed repo list (names only — subagent knows /workspace/<name> convention).
# ⚠ `-e`, never `-d`: in a git WORKTREE `.git` is a regular FILE (a gitfile holding
# `gitdir: <path>`), so a `-d` probe omits every worktree — and rules/git-practices.md
# makes one worktree per agent the default for concurrent work, i.e. exactly the case a
# subagent is spawned into. Same correction as ADR-0060 Amendment A5 made in lib/.
repos=""
for dir in /workspace/*/; do
    [ -e "${dir}.git" ] && repos="${repos} $(basename "$dir")"
done

# Build condensed context (smaller than SessionStart — subagents need key facts only)
ctx="<SubagentContext>
Project: ${PROJECT}
Repos mounted at /workspace/:${repos}
Working dir: /workspace
Teammate mode: ${TMODE}"

# Append the host-computed condensed subagent context (ADR-0042): knowledge +
# llms PATHS only, no descriptions. cco start injects it (base64) as
# CCO_SUBAGENT_CONTEXT — no workspace.yml file anymore. Decode and append.
if [ -n "$CCO_SUBAGENT_CONTEXT" ]; then
    injected=$(printf '%s' "$CCO_SUBAGENT_CONTEXT" | base64 -d 2>/dev/null)
    if [ -n "$injected" ]; then
        ctx="${ctx}
${injected}"
    else
        echo "cco: warning: CCO_SUBAGENT_CONTEXT set but failed to base64-decode — subagent context omitted." >&2
    fi
fi

ctx="${ctx}
</SubagentContext>"

jq -n --arg ctx "$ctx" '{
    hookSpecificOutput: {
        hookEventName: "SubagentStart",
        additionalContext: $ctx
    }
}'

exit 0
