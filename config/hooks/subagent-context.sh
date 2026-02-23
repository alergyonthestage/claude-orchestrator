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

# Add packs reference if present (file list only, not full descriptions)
if [ -f /workspace/.claude/packs.md ]; then
    pack_files=$(grep -v '^<!--' /workspace/.claude/packs.md \
        | grep '^-' \
        | sed 's/ — .*//')
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
