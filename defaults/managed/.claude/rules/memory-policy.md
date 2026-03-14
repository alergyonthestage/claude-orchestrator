# Memory vs. Documentation Policy

## When to use MEMORY.md

Write to memory (`~/.claude/projects/-workspace/memory/`) for:
- Session-specific working notes and scratch pad
- Sprint or task progress tracking (e.g., "Sprint 7: #A done, #B in progress")
- Personal interaction preferences for this project
- Self-improvement feedback received from the user
- Short-lived context (e.g., "mid-refactor, skip module X for now")
- Observations about tools or model behavior

Memory is personal, machine-synced via vault, and NOT shared when projects
are published. Treat it as a private notebook.

## When to use project documentation

Write to project docs (`.claude/CLAUDE.md`, `.claude/rules/`, `docs/`) for:
- Architecture decisions and rationale
- Learned code patterns that future sessions should know
- Conventions, naming rules, style guides → `.claude/rules/<topic>.md`
- "Always do X when working on Y" rules → `.claude/rules/`
- Gotchas, known issues, workarounds
- API reference, configuration docs

Documentation is per-project, persistent, and shared when projects are
published. Treat it as the project's permanent knowledge base.

## Key distinction

- **Memory** = per-user, transient, vault-synced, never published
- **Docs** = per-project, persistent, repo-committed, shareable

## Documentation file precedence

When the user has defined documentation files for a specific purpose
(e.g., `docs/roadmap.md`, `docs/maintainer/decisions/`), those files
ALWAYS take precedence over memory for that type of information.

- If `docs/roadmap.md` exists → update the roadmap there, not in memory
- If `.claude/rules/` has conventions → don't duplicate in memory
- Memory can supplement docs with personal annotations, task checklists,
  or sprint-specific working notes that don't belong in permanent docs

Rule: docs define the canonical location; memory is the overflow for
transient, personal, or in-progress notes.

## User-owned config files

Rules (`.claude/rules/`), agents, skills, and other config files are
user-configured resources. Do NOT modify them without explicit user
approval. When the memory policy says "move knowledge to rules," this
means proposing the change to the user, not writing directly.

## Memory maintenance

- Review memory entries at the start of each session
- Remove completed tasks, resolved issues, and outdated context
- When a memory entry becomes permanent knowledge, propose moving it
  to docs/rules (with user approval)
- Keep MEMORY.md under 200 lines (only the first 200 are auto-loaded)
