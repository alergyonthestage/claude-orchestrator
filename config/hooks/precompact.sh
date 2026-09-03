#!/bin/bash
# PreCompact hook: provides instructions to guide context compaction.
# Called before auto-compact (context window full) or manual /compact.
# Stdout is passed as custom_instructions to the compaction model.

PROJECT="${PROJECT_NAME:-unknown}"

# List repos so the compaction summary preserves them.
# ⚠ `-e`, never `-d`: in a git WORKTREE `.git` is a regular FILE, so a `-d` probe drops
# every worktree from the list a compaction is told to preserve — the moment context is
# scarcest. Same correction as ADR-0060 Amendment A5 made in lib/.
repos=""
for dir in /workspace/*/; do
    [ -e "${dir}.git" ] && repos="${repos}
- /workspace/$(basename "$dir")/"
done

# Build compaction instructions
cat <<INSTRUCTIONS
When summarizing this session, preserve the following information:

1. Project: ${PROJECT}
   Repos in workspace:${repos}

2. Any in-progress task, its current phase (analysis/design/implementation),
   and what has been completed vs. what remains.

3. Any design decisions or architectural choices made during this session.

4. The current git branch and any uncommitted changes that were discussed.

5. Knowledge pack files are at /workspace/.claude/packs/ — do not summarize their
   contents, just note which ones were consulted.

Keep the summary under 400 words. Prioritize actionable state over background context.
INSTRUCTIONS

exit 0
