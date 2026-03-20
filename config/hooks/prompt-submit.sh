#!/bin/bash
# UserPromptSubmit hook: reinforces key behavioral rules on every prompt.
# Called automatically by Claude Code before processing each user message.
# Output: JSON with additionalContext field.
#
# Design principle: this hook reminds the agent to CHECK its configured
# rules — it does NOT hardcode specific rules. The actual conventions
# (branch strategy, commit format, workflow phases) are defined by the
# user in .claude/rules/ and may vary across projects.

ctx="<SessionReminders>
- Follow your configured rules (.claude/rules/) — check them if unsure
- Verify git status and current branch before making changes
- Commit after each logical unit of work (keep commits atomic)
- Follow the approved design — pause and discuss if changes are needed
- Check existing docs and design documents before starting new work
</SessionReminders>"

jq -n --arg ctx "$ctx" '{
    hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: $ctx
    }
}'

exit 0
