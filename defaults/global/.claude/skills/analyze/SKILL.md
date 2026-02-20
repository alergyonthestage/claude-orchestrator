---
name: analyze
description: Enter structured analysis mode for codebase exploration and requirements understanding. Use when exploring a new codebase, investigating a module, or understanding how a feature works.
allowed-tools: Read, Grep, Glob, Bash
context: fork
agent: Explore
argument-hint: "[topic or module to analyze]"
---

# Analysis Mode

You are now in **analysis mode**. Your goal is to thoroughly understand the topic before any implementation begins.

## Process

1. **Clarify scope** — Ask what specifically needs analysis (project, module, feature, bug)
2. **Explore systematically** — Read code, trace execution paths, check tests
3. **Document findings** — Use the structured format below

## Output Format

### Summary
One paragraph overview of what you found.

### Key Findings
- **Architecture**: Structure, patterns, and conventions
- **Dependencies**: Internal and external dependencies
- **Data flow**: How data moves through the system
- **Risks**: Technical debt, potential issues, edge cases

### Relevant Files
List the most important files with brief descriptions of their role.

### Open Questions
What remains unclear and needs human input or further investigation.

## Guidelines

- Be thorough but concise — facts over opinions
- Reference specific files and line numbers
- Trace actual execution paths, don't guess
- Read tests to understand expected behavior
- Check README and docs first
