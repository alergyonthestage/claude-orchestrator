#!/bin/bash
# SessionStart hook: injects project context into Claude's session.
# Called automatically by Claude Code at session startup.
# Output: JSON with additionalContext field.

PROJECT="${PROJECT_NAME:-unknown}"
TMODE="${TEAMMATE_MODE:-tmux}"

# Discover repos (directories with .git under /workspace)
repos=""
repo_count=0
for dir in /workspace/*/; do
    [ -d "${dir}.git" ] && {
        name=$(basename "$dir")
        repos="${repos}
- /workspace/${name}/"
        repo_count=$((repo_count + 1))
    }
done

# Count MCP servers from merged ~/.claude.json
mcp_count=0
mcp_names=""
if [ -f /home/claude/.claude.json ]; then
    mcp_count=$(jq -r '.mcpServers // {} | length' /home/claude/.claude.json 2>/dev/null || echo 0)
    if [ "$mcp_count" -gt 0 ]; then
        mcp_names=$(jq -r '.mcpServers // {} | keys | join(", ")' /home/claude/.claude.json 2>/dev/null || echo "")
    fi
fi

# Discover available skills (global + project scope)
skills=""
for d in /home/claude/.claude/skills/*/; do
    [ -d "$d" ] && skills="${skills} /$(basename "$d")"
done
for d in /workspace/.claude/skills/*/; do
    [ -d "$d" ] && skills="${skills} /$(basename "$d")"
done

# Discover available agents (global + project scope)
agents=""
for f in /home/claude/.claude/agents/*.md; do
    [ -f "$f" ] && agents="${agents} $(basename "$f" .md)"
done
for f in /workspace/.claude/agents/*.md; do
    [ -f "$f" ] && agents="${agents} $(basename "$f" .md)"
done

# Build context string
ctx="<SessionContext>
Project: ${PROJECT}
Teammate mode: ${TMODE}
Repositories (${repo_count}):${repos}"

if [ "$mcp_count" -gt 0 ]; then
    ctx="${ctx}
MCP servers (${mcp_count}): ${mcp_names}"
fi

if [ -n "$skills" ]; then
    ctx="${ctx}
Available skills:${skills}"
fi

if [ -n "$agents" ]; then
    ctx="${ctx}
Available agents:${agents}"
fi

ctx="${ctx}
</SessionContext>"

# Inject knowledge packs (immutable, automatic — independent of CLAUDE.md)
if [ -f /workspace/.claude/packs.md ]; then
    packs_section=$(grep -v '^<!--' /workspace/.claude/packs.md)
    [ -n "$packs_section" ] && ctx="${ctx}

${packs_section}"
fi

# Persist key session variables for all subsequent Bash tool calls
if [ -n "$CLAUDE_ENV_FILE" ]; then
    echo "export PROJECT_NAME=${PROJECT}" >> "$CLAUDE_ENV_FILE"
    echo "export TEAMMATE_MODE=${TMODE}" >> "$CLAUDE_ENV_FILE"
fi

# Output JSON using jq for proper escaping
jq -n --arg ctx "$ctx" '{
    hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: $ctx
    }
}'

exit 0
