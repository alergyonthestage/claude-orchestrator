#!/bin/bash
# SubagentStart hook: injects condensed project context into spawned subagents.
# Called automatically by Claude Code when a Task tool spawns a subagent.
# Output: JSON with additionalContext field.

PROJECT="${PROJECT_NAME:-unknown}"
TMODE="${TEAMMATE_MODE:-tmux}"

# Condensed repo list (names only — subagent knows /workspace/<name> convention)
repos=""
for dir in /workspace/*/; do
    [ -d "${dir}.git" ] && repos="${repos} $(basename "$dir")"
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
    [ -n "$injected" ] && ctx="${ctx}
${injected}"
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
