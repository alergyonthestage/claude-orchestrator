# ADR-0012: Environment Extensibility

> **Status**: implemented

## Context

The Docker image is built once and shared across all projects. Some projects need
additional system packages, npm packages, or runtime configuration. The only
extension mechanism is `--mcp-packages` for global npm packages. Users have no way
to customize the environment per project without editing the Dockerfile.

## Decision

Provide five complementary extension mechanisms:

1. `~/.cco/setup-build.sh` — executed during `cco build` for system-level packages
   (all projects, root)
2. `~/.cco/setup.sh` — executed at container start for global runtime config
   (all projects, user `claude`)
3. `<repo>/.cco/setup.sh` — executed at container start for per-project runtime
   setup
4. `<repo>/.cco/mcp-packages.txt` — per-project npm MCP packages (runtime install)
5. `docker.image` in project.yml — use a completely custom Docker image per project

## Rationale

- Build-time setup (1) handles heavy dependencies without per-session startup cost
- Global runtime setup (2) handles dotfiles, aliases, tmux config for all projects
- Per-project runtime setup (3, 4) enables per-project customization without image
  rebuild
- Custom image (5) gives full control for projects with complex needs
- All four are opt-in with no impact on default behavior

## Consequences

- `~/.cco/setup-build.sh` requires `cco build` after changes
- `~/.cco/setup.sh` runs at every `cco start` as user `claude` (not root)
- Runtime setup scripts (2, 3, 4) increase container startup time proportionally to
  install size
- Custom images must be maintained by the user, but can extend the base image
- Template files are created by `cco init` (and seeded into a repo's `.cco/` on
  `cco init` / `cco join`)

## References

- **Design doc**: [design-environment.md](../../environment/design/design-environment.md)
- **Analysis**: [analysis-001-environment.md](../../environment/analysis/analysis-001-environment.md)
