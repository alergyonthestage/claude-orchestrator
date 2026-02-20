#!/bin/bash
# StatusLine script: shows project info in Claude Code's status bar.
# Receives JSON on stdin with session data, outputs a single line.
# Must be fast (<100ms) — called frequently.

INPUT=$(cat)
PROJECT="${PROJECT_NAME:-cco}"

MODEL=$(echo "$INPUT" | jq -r '.model.display_name // "unknown"' 2>/dev/null)
MODEL=$(echo "$MODEL" | sed 's/Claude //')

CTX=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0' 2>/dev/null)
COST=$(echo "$INPUT" | jq -r '.cost.total_cost_usd // 0' 2>/dev/null)

printf "[%s] %s | ctx %s%% | \$%s" "$PROJECT" "$MODEL" "$CTX" "$COST"
