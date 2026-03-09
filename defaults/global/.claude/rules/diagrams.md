# Diagram Conventions

## Where Mermaid Applies

Mermaid diagrams are **required in written artifacts** — files written to the filesystem (via Write, Edit, or MCP tools):
- Documentation files (README, guides, changelogs)
- Design documents and architecture specs
- Roadmaps and implementation plans saved to disk
- Any `.md` or similar file produced as output

Mermaid diagrams are **NOT used in**:
- Direct chat responses displayed in the terminal (CLI output is not rendered)
- Claude's native plan mode output (displayed inline in terminal)
- Any content rendered exclusively in the terminal/shell

In terminal output, use plain text, bullet lists, or indented outlines to convey structure.

## Mermaid Rules (for written artifacts)
- Always use Mermaid syntax for diagrams, never ASCII art
- Wrap diagrams in fenced code blocks: ```mermaid ... ```
- Use diagrams for: sequence diagrams, flowcharts, class diagrams, ER diagrams, state diagrams, gitGraph, and other UML diagrams
- If a diagram is very complex, split it into multiple smaller, focused diagrams
- Do NOT use diagrams when a bullet list or descriptive text is more effective
- Prefer text/lists for: simple lists, short comparisons, configurations, linear steps without branching
