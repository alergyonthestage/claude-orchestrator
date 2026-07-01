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

# Inject knowledge + llms indexes from the unified workspace.yml (ADR-0041 R1).
# The YAML carries the data (path + description); the instructional preamble is
# rendered here, per-consumer (R1-D2). Extract "<path>\t<description>" per entry
# from a given list section.
WS_YML="${CCO_WORKSPACE_YML:-/workspace/.claude/workspace.yml}"
_ws_section() {  # $1 = section name (knowledge|llms)
    [ -f "$WS_YML" ] || return 0
    awk -v sec="$1" '
        /^[A-Za-z_]+:/ { insec = ($0 ~ "^" sec ":"); next }
        insec && /^  - path:/ { p=$0; sub(/^  - path: */,"",p); next }
        insec && /^    description:/ {
            d=$0; sub(/^    description: *"?/,"",d); sub(/"$/,"",d); print p "\t" d
        }
    ' "$WS_YML"
}

knowledge=$(_ws_section knowledge)
if [ -n "$knowledge" ]; then
    ctx="${ctx}

The following knowledge files provide project-specific conventions and context.
Read the relevant files BEFORE starting any implementation, review, or design task.
Do not ask the user for context that is covered by these files.
"
    while IFS="$(printf '\t')" read -r kpath kdesc; do
        [ -z "$kpath" ] && continue
        if [ -n "$kdesc" ]; then
            ctx="${ctx}
- ${kpath} — ${kdesc}"
        else
            ctx="${ctx}
- ${kpath}"
        fi
    done <<EOF
${knowledge}
EOF
fi

llms=$(_ws_section llms)
if [ -n "$llms" ]; then
    ctx="${ctx}

## Official Framework Documentation (llms.txt)

The following official framework documentation files are installed.
Consult them BEFORE writing code that uses these frameworks — do not rely solely on training data.
For large files, read selectively using offset/limit. For index files, WebFetch specific pages as needed.
"
    while IFS="$(printf '\t')" read -r lpath ldesc; do
        [ -z "$lpath" ] && continue
        if [ -n "$ldesc" ]; then
            ctx="${ctx}
- ${lpath} — ${ldesc}"
        else
            ctx="${ctx}
- ${lpath}"
        fi
    done <<EOF
${llms}
EOF
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
