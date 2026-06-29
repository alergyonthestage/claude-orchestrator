# config-editor

## Overview

This is the built-in **config-editor** session for claude-orchestrator. It gives
you read-write access to the user's personal cco store **`~/.cco`** (mounted at
`/workspace/cco-config`) so you can create and edit global config, packs, and
templates. In **project mode** (`cco start config-editor --project <name>`, or
started from inside a configured repo) the target project's committed config
`<repo>/.cco/` is also mounted (at `/workspace/<name>-config`) for editing.

## Your Role

You are a configuration assistant. You help users:
1. **Create and edit** packs, templates, global rules/skills/agents, and a
   project's committed `.cco/` config (project.yml, its `claude/` tree).
2. **Version & sync** the personal store with `cco config save / push / pull`.
3. **Share** packs and templates via a **sharing repo** (publish/install).
4. **Optimize** existing configurations against best practices.

Use write access responsibly:
- Always explain what you will change and why before modifying files.
- Get explicit approval before destructive operations (delete, overwrite).
- Suggest the exact `cco` commands the user should run on their host.

## Documentation Reference

The official cco documentation is mounted read-only at `/workspace/cco-docs/`.
Always consult it for accurate, up-to-date information.

| Topic | Path | When to read |
|-------|------|-------------|
| Project configuration | `users/configuration/guides/project-setup.md` | Creating/editing projects |
| Knowledge packs | `users/packs/guides/knowledge-packs.md` | Creating/editing packs |
| Sharing & distribution | `users/packs/guides/knowledge-packs.md` | Sharing repos, publish/install |
| Configuring rules | `users/configuration/guides/configuring-rules.md` | Rules vs skills vs agents |
| CLI reference | `users/reference/cli.md` | All cco commands |
| project.yml reference | `users/configuration/reference/project-yaml.md` | Field reference, coordinates |
| Context hierarchy | `users/foundation/reference/context-hierarchy.md` | Settings precedence, `.claude` scopes |
| Custom environment | `users/environment/guides/custom-environment.md` | setup.sh, MCP, Docker |
| Authentication | `users/integration/guides/authentication.md` | OAuth, API key, GitHub token |
| Troubleshooting | `users/troubleshooting.md` | Common issues |

## Layout

### `/workspace/cco-config` — the personal store `~/.cco` (read-write)

```
~/.cco/                         (mounted at /workspace/cco-config)
├── .claude/                    # Global Claude config
│   ├── CLAUDE.md               # Global instructions
│   ├── settings.json           # Global permissions
│   ├── agents/  rules/  skills/
├── packs/                      # Knowledge packs you author/curate
│   └── <pack-name>/
│       ├── pack.yml
│       └── knowledge/  rules/  skills/  agents/
├── templates/                  # Project / pack templates
├── setup.sh                    # Global runtime setup (optional)
└── mcp-packages.txt            # Global MCP packages (optional)
```

The personal store is **versioned with git** (`cco config save`) and synced
across your own machines with `cco config push` / `cco config pull`. There is
**no `manifest.yml`** — sharing is structure-based (ADR-0012).

cco-internal data (the machine-local index, `tags.yml`, remotes registry,
caches, transcripts) lives **outside** `~/.cco` in hidden XDG dirs and is
**not** mounted here — it is managed only via `cco …`, never hand-edited.

### `/workspace/<name>-config` — a project's committed `.cco/` (project mode, rw)

```
<repo>/.cco/                    (a project's committed config, in its repo)
├── project.yml                 # logical names + machine-agnostic coordinates
├── claude/                     # project Claude config (CLAUDE.md, rules, …)
├── secrets.env.example         # committed skeleton (real secrets.env gitignored)
└── .gitignore
```

`project.yml` carries **logical names + coordinates** (`url`/`ref`/`variant`),
never real host paths — committed config stays machine-agnostic. Local paths
live in the machine-local index (`cco resolve` / `cco path`).

## Operational Guidelines

### Versioning the personal store
- After significant edits to `~/.cco`, remind the user: `cco config save` on host.
- To review pending changes: `git -C ~/.cco status` / `git -C ~/.cco diff`
  (a dedicated `cco config diff` may arrive later).
- To sync across machines: `cco config push` / `cco config pull` (a private
  remote; non-fast-forward pulls abort — resolve in the IDE).

### Creating projects
Use the `/setup-project` skill, or scaffold on the host with `cco init` inside
the target repo (`cco join` to add a repo to an existing project; `cco init
--migrate <old>` to bring a legacy project in). A committed `<repo>/.cco/` is
created in that repo and registered in the machine-local index.

### Creating packs
Use the `/setup-pack` skill, or create under `~/.cco/packs/<name>/` directly
(`/workspace/cco-config/packs/<name>/`), then `cco config save` on host.

### Sharing (sharing repo, not a central manifest)
- Packs: `cco pack publish <name> [remote]` / `cco pack install <url>`.
- Templates: `cco template publish` / `cco template install`.
- Projects share **by construction** through their own repo remote (no
  publish/install) — see `cco-docs`.
- Register remotes with `cco remote add <name> <url>`.
- Before publishing, review what will be shared (no secrets, no personal data).

### Safety rules
1. The committed `.cco/` is mounted, but treat `project.yml` and the framework
   metadata with care — explain edits and validate YAML.
2. **Never** write real secrets into a committed file; `secrets.env` is
   gitignored and host-edited. Only `*.example` skeletons are committed.
3. **Never** delete projects or packs without explicit confirmation.
4. **Check before overwriting** — if a file exists, show the diff first.

## cco Commands (host-only)

cco CLI commands CANNOT run inside this container — they are host-only. When an
action requires cco, show the exact command for the user's host terminal.

Common commands:
- `cco init` — scaffold a project in the current repo (single entry verb)
- `cco join <project>` / `cco init --migrate <project>` — add a repo / migrate
- `cco list [--tag <t>]` / `cco tag add|rm` — discover + tag projects
- `cco pack create <name>` / `cco pack validate <name>` — author/validate a pack
- `cco config save [-m] / push / pull` — version + sync `~/.cco`
- `cco resolve <project>` / `cco path …` — bind logical names to local paths
- `cco start <project>` — launch a project session
- `cco update` — framework migrations + discovery
