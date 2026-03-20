# Documentation Practices

## Structure
- Write documentation in the repository's /docs directory
- Organize by domain or module, not by document type
- Use consistent naming conventions within the project
- Keep related documentation close to the code it describes
- After completing a development cycle, review and update stale docs
- Periodically evaluate if docs need reorganization for better discovery

## Project Tracking
- Maintain a roadmap file (e.g., docs/roadmap.md) as the single source
  of truth for planned work, priorities, and known issues
- Update it at the end of each development cycle
- Include status markers for completed, in-progress, and planned items

## Architecture Decision Records (ADR)

- Record significant decisions in `docs/` as ADR documents
- Each ADR captures: context, decision, alternatives considered, and rationale
- ADRs are essential for agent continuity — they preserve the reasoning behind
  decisions across sessions, preventing re-discussion of settled questions
- Update ADRs when decisions are revisited or superseded (mark as superseded,
  link to the new ADR)
- Keep ADRs close to the domain they affect (e.g., `docs/auth/decisions/`,
  `docs/maintainer/decisions/`)

## Diagrams

Mermaid diagrams are required in written artifacts — files written
to the filesystem:
- Documentation files (README, guides, changelogs)
- Design documents and architecture specs
- Any .md file produced as output

Mermaid diagrams are NOT used in:
- Direct chat responses displayed in the terminal
- Plan mode output (displayed inline in terminal)

In terminal output, use plain text, bullet lists, or indented outlines.

### Rules
- Always use Mermaid syntax, never ASCII art
- Wrap in fenced code blocks: ```mermaid ... ```
- Split complex diagrams into multiple smaller ones
- Prefer text/lists when a diagram adds no value
