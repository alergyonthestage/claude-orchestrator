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

AUTH_TAG=""
CREDS="/home/claude/.claude/.credentials.json"
if [ -f "$CREDS" ]; then
    EXPIRES=$(jq -r '.claudeAiOauth.expiresAt // 0' "$CREDS" 2>/dev/null || echo 0)
    NOW_MS=$(($(date +%s) * 1000))
    REMAINING_MIN=$(( (EXPIRES - NOW_MS) / 60000 ))
    if [ "$REMAINING_MIN" -le 0 ]; then
        AUTH_TAG=" | AUTH EXPIRED"
    elif [ "$REMAINING_MIN" -le 10 ]; then
        AUTH_TAG=" | AUTH ${REMAINING_MIN}m!"
    elif [ "$REMAINING_MIN" -le 30 ]; then
        AUTH_TAG=" | auth ${REMAINING_MIN}m"
    fi
fi

printf "[%s] %s | ctx %s%% | \$%s%s" "$PROJECT" "$MODEL" "$CTX" "$COST" "$AUTH_TAG"
