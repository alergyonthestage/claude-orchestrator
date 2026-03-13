---
name: tutorial
description: >
  Start or resume the interactive claude-orchestrator tutorial. Use when the
  user wants a guided walkthrough of cco features, concepts, and workflows.
  Adapts to the user's experience level.
argument-hint: "[beginner | intermediate | advanced | topic]"
---

# Tutorial Mode

Start the interactive tutorial. Adapt based on the argument or user's context.

## Determine Starting Point

Parse `$ARGUMENTS`:
- `beginner` or empty → Start from Module 1 (What is claude-orchestrator)
- `intermediate` → Start from Module 4 (Knowledge packs)
- `advanced` → Start from Module 10 (Structured development workflow)
- Any other text → Treat as a topic query, find the most relevant module

Also check `/workspace/user-config/`:
- If no projects exist beyond `tutorial/` → likely a new user, suggest beginner path
- If projects and packs exist → likely intermediate+, suggest advanced topics or
  offer to review their setup

## Guided Flow

For each module:
1. **Explain** the concept in 2-3 paragraphs with practical context
2. **Show** a real example (from user's config if available, otherwise generic)
3. **Suggest exercise**: a practical task the user can try
4. **Reference**: point to the specific documentation file for deeper reading
5. **Ask**: "Ready for the next topic, or do you have questions about this?"

## Proactive Discovery

While presenting modules, watch for opportunities to suggest related features:
- Discussing projects → mention packs if they don't use any
- Discussing packs → mention Config Repos for sharing
- Discussing CLAUDE.md → mention /init-workspace skill
- Discussing agents → mention agent teams (tmux)

## Important

- Always read the relevant documentation file before explaining a topic
- Use the user's actual configuration as examples when possible
- Never skip ahead without the user's consent
- If the user asks a question outside the current module, answer it
  (don't force them back to the sequence)
