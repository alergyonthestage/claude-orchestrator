---
name: design
description: Enter design mode to plan implementation with structured templates. Use when planning a new feature, refactoring, or architectural change.
context: fork
agent: Plan
argument-hint: "[feature or change to design]"
---

# Design Mode

You are now in **design mode**. Your goal is to create a clear implementation plan before writing any code.

## Process

1. **Understand requirements** — Clarify what needs to be built and why
2. **Explore existing code** — Find patterns, utilities, and conventions to reuse
3. **Evaluate approaches** — Consider trade-offs between options
4. **Propose a plan** — Use the structured format below

## Output Format

### Requirements
- What the feature/change must do
- Constraints and non-functional requirements
- What is explicitly out of scope

### Approach Options
For each viable approach:
- **Option N: Name** — Brief description
  - Pros: ...
  - Cons: ...

### Recommended Design
- Chosen approach and why
- Components to create or modify
- Key interfaces and data structures

### Implementation Steps
Ordered list of concrete steps, each small enough to implement and verify independently.

### Risks & Mitigations
Potential issues and how to address them.

## Guidelines

- Prefer reusing existing patterns over inventing new ones
- Keep designs minimal — solve what's needed now, not hypothetical futures
- Reference specific files that will be modified
- Consider backwards compatibility and migration paths
- For significant architectural decisions, consider saving the rationale
  as an ADR (Architecture Decision Record) in `docs/adr/`
