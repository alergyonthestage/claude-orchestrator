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

# Add knowledge + llms references if present (paths only, not full descriptions).
# Source is the unified workspace.yml (ADR-0041 R1); collect the `path:` lines
# from the knowledge and llms sections.
WS_YML="${CCO_WORKSPACE_YML:-/workspace/.claude/workspace.yml}"
if [ -f "$WS_YML" ]; then
    pack_files=$(awk '
        /^[A-Za-z_]+:/ { insec = ($0 ~ /^(knowledge|llms):/); next }
        insec && /^  - path:/ { p=$0; sub(/^  - path: */,"",p); print "- " p }
    ' "$WS_YML")
    [ -n "$pack_files" ] && ctx="${ctx}
Knowledge packs (read before implementation tasks):
${pack_files}"
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
