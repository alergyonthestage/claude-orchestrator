# ADR-0011: External Service Authentication via Tokens

> **Status**: implemented

## Context

Container sessions need to push to GitHub, create PRs, and interact with external
services via MCP servers. SSH keys mounted from the host fail due to UID mismatch
and `:ro` permissions. `gh` CLI is not installed. There's no standardized way to
provide service tokens.

## Decision

Use fine-grained GitHub PAT (`GITHUB_TOKEN`) as the primary auth mechanism. Install
`gh` CLI in the Dockerfile. Configure git credential helper via `gh auth setup-git`
in the entrypoint. Remove SSH key mount from the default compose template (opt-in
via `docker.mount_ssh_keys`). Support per-project `secrets.env` that overrides
global values.

## Rationale

- One token handles git push (HTTPS), `gh` CLI, and MCP GitHub — no separate auth
  per tool
- Fine-grained PATs can be scoped to specific repos and permissions (principle of
  least privilege)
- SSH keys grant access to ALL repos — over-permissive for agent use
- Per-project secrets enable different token scopes per project
- `secrets.env` values are passed as runtime `-e` flags — never written to
  `docker-compose.yml`

## Consequences

- Users must create a GitHub PAT and save it in `secrets.env`
- SSH-only remotes (non-GitHub) require explicit opt-in
- `gh` CLI adds ~50 MB to the Docker image
- Existing SSH key mount is removed from default — breaking change for users
  relying on it (but it was broken anyway)

## References

- **Design doc**: [design-auth.md](../../integration/auth/design/design-auth.md)
- **Analysis**: [analysis-001-auth.md](../../integration/auth/analysis/analysis-001-auth.md)
