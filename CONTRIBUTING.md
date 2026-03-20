# Contributing to claude-orchestrator

Thank you for your interest in contributing! This guide will help you get started.

## Getting Started

1. **Fork** the repository
2. **Clone** your fork locally
3. **Run** `cco init` to set up the development environment
4. **Read** the [architecture docs](docs/maintainer/architecture/architecture.md) to understand the system design

## Reporting Bugs

Open a [GitHub Issue](../../issues/new?template=bug_report.md) with:
- Steps to reproduce
- Expected vs actual behavior
- Your environment (OS, Docker version, Claude Code version)

For security vulnerabilities, see [SECURITY.md](SECURITY.md).

## Proposing Features

Open a [GitHub Issue](../../issues/new?template=feature_request.md) describing:
- The problem you're trying to solve
- Your proposed solution
- Alternatives you considered

**Tip:** Run `cco start tutorial` to launch an interactive session with an agent that knows the full codebase and documentation. Use it to explore architecture, clarify design decisions, evaluate ideas for consistency with the current design, or get guidance before writing a proposal.

## Submitting Changes

### Branch Strategy

- **`main`**: stable releases only. Never push directly.
- **`develop`**: active development. PRs go here.
- Feature branches: `feat/<scope>/<description>` (e.g., `feat/cli/add-edit-command`)
- Fix branches: `fix/<scope>/<description>` (e.g., `fix/entrypoint/socket-gid`)

### Workflow

1. Create a feature branch from `develop`
2. Make your changes
3. Run `bin/test` and ensure all tests pass
4. Commit using [conventional commits](#commit-messages)
5. Push to your fork
6. Open a PR targeting `develop`

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add user authentication
fix: resolve race condition in queue processor
docs: update API endpoint documentation
refactor: extract validation logic to shared module
test: add integration tests for payment flow
chore: update dependencies
```

### Code Style

- **Bash 3.2 compatible** — must work with macOS default `/bin/bash`
- Guard empty arrays: `[[ ${#arr[@]} -gt 0 ]]` or `${arr[@]+"${arr[@]}"}`
- Code comments and variable names in **English**
- Documentation files in **English**

### Testing

- Run the full test suite: `bin/test`
- Run specific tests: `bin/test tests/test_<name>.sh`
- Tests are dry-run (no Docker required) — they validate config generation and CLI behavior
- Add tests for new features; update tests for changed behavior

## Project Structure

| Directory | Purpose |
|-----------|---------|
| `bin/cco` | CLI entrypoint |
| `lib/` | CLI modules (one per command group) |
| `config/` | Docker entrypoint, hooks, tmux config |
| `proxy/` | Go Docker socket proxy |
| `defaults/managed/` | Framework infrastructure (baked in image) |
| `defaults/global/` | User defaults (copied on init) |
| `templates/` | Project and pack templates |
| `tests/` | Bash test suite |
| `docs/` | Documentation (user guides, reference, maintainer) |

For detailed architecture, see [docs/maintainer/architecture/architecture.md](docs/maintainer/architecture/architecture.md).

## Code of Conduct

Be respectful, constructive, and collaborative. We're building something useful together.
