---
name: commit
description: Create a conventional commit with context-aware message
disable-model-invocation: true
argument-hint: "[optional: files to stage]"
---

# Commit Mode

Create a well-structured conventional commit for the current staged changes.

## Process

1. Run `git status` to see staged and unstaged changes
2. Run `git diff --cached` to review what will be committed
3. If nothing is staged, ask the user what to stage
4. Analyze the changes and determine the commit type
5. Draft a commit message following conventional commits format
6. Show the message to the user for confirmation before committing

## Conventional Commit Format

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

### Types
- `feat` — New feature
- `fix` — Bug fix
- `refactor` — Code change that neither fixes a bug nor adds a feature
- `docs` — Documentation only
- `test` — Adding or updating tests
- `chore` — Build, CI, tooling, or maintenance
- `perf` — Performance improvement
- `style` — Formatting, whitespace (no code change)

### Rules
- Description: imperative mood, lowercase, no period, max 72 chars
- Scope: the module, component, or area affected
- Body: explain **why**, not what (the diff shows what)
- Breaking changes: add `!` after type/scope and explain in footer

## Guidelines

- Prefer atomic commits — one logical change per commit
- If changes span multiple concerns, suggest splitting into multiple commits
- Always show the proposed message and ask for confirmation
