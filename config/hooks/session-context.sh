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
Repositories (${repo_count}):${repos}
Workspace persistence: Repository directories are persisted on the host. Files at /workspace/ root are temporary (container-only, lost on exit). Persistent work should go in repos and be versioned with git."

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

# Append the host-computed Level-A session context (ADR-0042): resources +
# descriptions, packs, knowledge/llms indexes, gated path_map, and the wrapped-cco
# access declaration. cco start injects it (base64) as CCO_SESSION_CONTEXT — no
# workspace.yml file anymore (INV-2). Decode and append verbatim.
if [ -n "$CCO_SESSION_CONTEXT" ]; then
    injected=$(printf '%s' "$CCO_SESSION_CONTEXT" | base64 -d 2>/dev/null)
    [ -n "$injected" ] && ctx="${ctx}

${injected}"
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
