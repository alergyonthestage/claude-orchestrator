# Git Practices

## Branch Strategy
- Main branch: `main` (never commit directly)
- Feature branches: `feat/<scope>/<description>`
- Fix branches: `fix/<scope>/<description>`
- Always branch from the latest main

## Commit Messages
Follow conventional commits:
- `feat: add user authentication`
- `fix: resolve race condition in queue processor`
- `docs: update API endpoint documentation`
- `refactor: extract validation logic to shared module`
- `test: add integration tests for payment flow`
- `chore: update dependencies`

## Commit Frequency
- Commit after each logical, working unit of change
- Each commit should leave the codebase in a working state
- Prefer many small commits over few large ones
