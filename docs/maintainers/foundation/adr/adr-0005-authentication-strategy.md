# ADR-0005: Authentication Strategy

> **Status**: accepted

## Context

Container sessions need multiple authentication mechanisms — Claude subscription
OAuth, direct API keys, GitHub access for git/PR/MCP, and arbitrary service tokens
— each suited to a different use case, and layered per project.

## Decision

Support multiple auth mechanisms, layered per project.

| Method | Mechanism | Use Case |
|--------|-----------|----------|
| OAuth (default) | Credentials seeded from macOS Keychain to STATE (`<state>/cco/.credentials.json`) | Pro/Team/Enterprise subscriptions |
| API Key | `ANTHROPIC_API_KEY` env var | Direct API access, CI/CD |
| GitHub auth | `GITHUB_TOKEN` env var → `gh auth login --with-token` + `gh auth setup-git` | git push (HTTPS), `gh pr create`, MCP GitHub server |
| Per-project secrets | `secrets.env` at global and project level, loaded as runtime `-e` flags | Service tokens (never written to docker-compose.yml) |

### Implementation

- **OAuth**: On macOS, the CLI extracts credentials from macOS Keychain
  (`Claude Code-credentials`) and seeds them to STATE
  (`<state>/cco/.credentials.json`). Inside the container, Claude Code reads from
  `~/.claude/.credentials.json` (the Linux plaintext location). The
  `~/.claude.json` file (seeded from STATE `<state>/cco/claude.json`) stores
  preferences and MCP servers — NOT auth tokens.
- **API Key**: `ANTHROPIC_API_KEY` env var passed to container via `--env` or
  `.env` file.
- **GitHub**: `GITHUB_TOKEN` env var triggers `gh auth login --with-token` +
  `gh auth setup-git` in the entrypoint. This enables git push (HTTPS),
  `gh pr create`, and MCP GitHub server — all with a single token.
- **Secrets**: `secrets.env` at both global and project level, loaded as runtime
  `-e` flags (never written to `docker-compose.yml`).

## Alternatives considered

**Why not just mount `~/.claude.json` read-write?**
The current model uses a shared writable `<state>/cco/claude.json` (machine-local
STATE) that is synced from host when host has more recent data (by comparing
`numStartups`). This avoids race conditions from concurrent writes by host and
container Claude Code instances (which previously caused JSON corruption —
"control characters are not allowed" errors). The `claude.json` file stores only
preferences and MCP server config; OAuth credentials are handled separately via
`.credentials.json`.
