# Design: Config Repo — Versioning & Sharing

> **Status**: Design — approved
> **Date**: 2026-03-04
> **Scope**: Sprint 6 (Sharing & Import) + Sprint 10 (Config Vault)
> **Analysis**: [analysis.md](./analysis.md)
> **Roadmap**: [roadmap.md](../roadmap.md) §Sprint 6, §Sprint 10

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Config Repo Structure](#2-config-repo-structure)
3. [Directory Restructuring — user-config/](#3-directory-restructuring--user-config)
4. [Vault Commands — cco vault](#4-vault-commands--cco-vault)
5. [Install Commands — cco pack install / cco project install](#5-install-commands--cco-pack-install--cco-project-install)
6. [Pack Source Metadata](#6-pack-source-metadata)
7. [Vault .gitignore Template](#7-vault-gitignore-template)
8. [Access Control Patterns](#8-access-control-patterns)
9. [share.yml — Optional Sharing Manifest](#9-shareyml--optional-sharing-manifest)
10. [Code Changes Required](#10-code-changes-required)
11. [Migration from Current Structure](#11-migration-from-current-structure)
12. [Future Evolution](#12-future-evolution)

---

## 1. Architecture Overview

A **Config Repo** is a git repository that follows the standard CCO directory convention. It serves as:
- **Vault**: private, versioned backup of all user configuration
- **Shared bundle**: a repo (or remote branch) that other users install from

The vault is the superset. Sharing is done by pointing to a repo (private or public) that follows the same convention.

```
                     ┌─────────────────────────────────┐
                     │       user-config/               │
                     │       (Config Repo — vault)      │
                     │                                  │
                     │  packs/      global/  projects/  │
                     │  templates/                      │
                     └──────────────┬──────────────────┘
                                    │ git push
               ┌────────────────────┴──────────────────────┐
               │                                           │
    ┌──────────┴──────────┐               ┌────────────────┴──────────┐
    │  github.com/user/   │               │  github.com/company/      │
    │  vault-private      │               │  team-config              │
    │  (private remote)   │               │  (private, team access)   │
    └─────────────────────┘               └───────────────────────────┘
               │                                           │
    Personal backup / restore            cco pack install <team-url>
```

**Rule**: CCO does not implement access control. Visibility is a git hosting concern.

---

## 2. Config Repo Structure

Any directory that follows this convention is a valid Config Repo (installable by CCO):

```
<config-repo>/
├── .gitignore                    # CCO-generated, excludes secrets + runtime files
│
├── packs/                        # Reusable knowledge packs
│   ├── <pack-name>/
│   │   ├── pack.yml              # Pack manifest (required)
│   │   ├── knowledge/            # Fallback knowledge files (if no knowledge.source)
│   │   ├── skills/
│   │   ├── agents/
│   │   └── rules/
│   └── ...
│
├── templates/                    # Shareable project templates
│   ├── <template-name>/
│   │   ├── project.yml           # May contain {{PLACEHOLDER}} variables
│   │   └── .claude/
│   │       ├── CLAUDE.md
│   │       └── rules/
│   └── ...
│
├── global/                       # Personal .claude/ settings (vault only)
│   └── .claude/
│       ├── CLAUDE.md
│       ├── settings.json
│       ├── mcp.json
│       ├── agents/
│       ├── skills/
│       └── rules/
│
├── projects/                     # Personal project configs (vault only)
│   └── <project-name>/
│       ├── project.yml
│       └── .claude/
│
└── share.yml                     # Optional: resource index for discoverability
```

### Repo type detection

CCO auto-detects the repo type at install time:

| Condition | Interpretation |
|---|---|
| Root has `pack.yml` | Single-pack repo — install the pack directly |
| Root has `packs/` directory | Multi-pack repo — list available packs; use `--pick` for one |
| Root has `templates/` directory | Repo contains project templates |
| Root has `share.yml` | Use manifest as authoritative resource index |
| Root has `global/` or `projects/` | Full vault — install commands apply only to `packs/` and `templates/` |

---

## 3. Directory Restructuring — user-config/

### Before (current)

```
claude-orchestrator/
├── global/              ← user config + packs (gitignored)
│   ├── .claude/
│   └── packs/           ← packs nested inside global
├── projects/            ← project configs (gitignored)
└── ...tool code...
```

### After

```
claude-orchestrator/
├── user-config/         ← single user data root (gitignored in parent repo)
│   ├── packs/           ← elevated: packs are now top-level
│   ├── templates/       ← new: project templates
│   ├── global/
│   │   └── .claude/
│   └── projects/
└── ...tool code...
```

OR, external directory (same structure, different path):

```
~/.cco/                  ← or any path via CCO_USER_CONFIG_DIR
├── packs/
├── templates/
├── global/
│   └── .claude/
└── projects/
```

### Environment variables

```bash
# Primary: controls where all user data lives
CCO_USER_CONFIG_DIR="${CCO_USER_CONFIG_DIR:-$REPO_ROOT/user-config}"

# Derived: still overridable individually for advanced users
CCO_GLOBAL_DIR="${CCO_GLOBAL_DIR:-$CCO_USER_CONFIG_DIR/global}"
CCO_PROJECTS_DIR="${CCO_PROJECTS_DIR:-$CCO_USER_CONFIG_DIR/projects}"
CCO_PACKS_DIR="${CCO_PACKS_DIR:-$CCO_USER_CONFIG_DIR/packs}"
CCO_TEMPLATES_DIR="${CCO_TEMPLATES_DIR:-$CCO_USER_CONFIG_DIR/templates}"
```

If `CCO_GLOBAL_DIR` or `CCO_PROJECTS_DIR` are set explicitly, they override the derived values. This preserves backward compatibility for users who already use these env vars.

### Choosing a location

| Mode | When to use | Setup |
|---|---|---|
| `user-config/` inside repo | Single machine, tool and config together | Default, no configuration needed |
| External directory (`~/.cco/`) | Multi-machine sync, separate git lifecycle, prefer dotfiles style | Set `CCO_USER_CONFIG_DIR=~/.cco` in shell profile |

---

## 4. Vault Commands — cco vault

The vault wraps git operations on the `user-config/` directory (or `CCO_USER_CONFIG_DIR`).

```bash
cco vault init [<path>]
```
Initializes the Config Repo:
- Creates `user-config/` (or the specified path) if it does not exist
- Runs `git init` inside the directory
- Writes the CCO `.gitignore` template (see §7)
- If path differs from `CCO_USER_CONFIG_DIR`, writes the path to `~/.cco-vault-path` and prints an export instruction

```bash
cco vault sync [<message>]
```
Commits the current state:
- `git add -A` (respecting `.gitignore`)
- `git commit -m "vault: <message>"` (default message: `"snapshot $(date +%Y-%m-%d)"`)
- Prints a summary of changed files

```bash
cco vault diff
```
Shows uncommitted changes:
- `git diff` + `git status --short`
- Groups output by category (packs, projects, global settings)

```bash
cco vault log [--limit N]
```
Shows commit history with one-line summaries (default: last 20).

```bash
cco vault restore <ref>
```
Restores config to a previous state:
- Runs `git checkout <ref> -- .` (does not move HEAD)
- Prompts for confirmation: shows affected files
- Excludes `secrets.env` and other sensitive files from restore

```bash
cco vault remote add <name> <url>
cco vault push [<remote>]
cco vault pull [<remote>]
```
Standard git remote operations, delegated directly to git.

```bash
cco vault status
```
Shows:
- Whether vault is initialized (git repo exists)
- Current remote(s) and sync status (ahead/behind)
- Count of uncommitted changes by category

---

## 5. Install Commands — cco pack install / cco project install

### cco pack install

```bash
cco pack install <git-url>                    # all packs from repo
cco pack install <git-url> --pick <name>      # one specific pack by name
cco pack install <git-url>:<subpath>          # explicit subpath (for non-CCO repos)
cco pack install <git-url>@<ref>              # pin to branch/tag/commit
cco pack install <git-url> --token <token>    # explicit auth token (HTTPS)
```

**Install flow:**

```
1. Resolve URL → detect auth method (SSH key / GITHUB_TOKEN / --token)
2. git clone --no-checkout --filter=blob:none <url> /tmp/cco-XXXX
3. Auto-detect repo type (single-pack / multi-pack / vault)
4. If multi-pack and no --pick:
     List available packs from packs/ directory
     Prompt user to select one or all
5. git sparse-checkout set <target-path>
6. git checkout
7. Copy pack to $CCO_PACKS_DIR/<name>/
8. Write .cco-source metadata (see §6)
9. Print confirmation with resource summary
```

**Conflict handling:**
- If a pack with the same name exists locally:
  - If source matches → offer to update
  - If source differs → warn, ask: overwrite / keep / abort
- If pack was created locally (`source: local`) → always ask before overwriting

### cco pack update

```bash
cco pack update <name>      # update one pack from its recorded source
cco pack update --all       # update all packs with a remote source
```

Reads `.cco-source`, re-runs the sparse-checkout with the same ref (or latest if ref was a branch). Does not overwrite local modifications unless `--force`.

### cco project install

```bash
cco project install <git-url>
cco project install <git-url> --pick <template-name>
cco project install <git-url> --as <local-name>     # rename on install
```

Install flow mirrors `cco pack install`. Template `project.yml` may contain `{{PLACEHOLDER}}` variables; CCO prompts for values at install time and resolves them before writing to `projects/<name>/project.yml`.

---

## 6. Pack Source Metadata

Every pack installed from a remote source carries a `.cco-source` file in its directory:

```yaml
# $CCO_PACKS_DIR/<name>/.cco-source

source: https://github.com/team/team-config
path: packs/react-guidelines         # subdirectory within the repo
ref: main                            # branch, tag, or commit SHA
installed: 2026-03-04
updated: 2026-03-04
```

Locally created packs (via `cco pack create`) have:

```yaml
source: local
installed: 2026-03-04
```

The `.cco-source` file is:
- Tracked in the vault (versioning records where each pack came from)
- Excluded from `cco pack export` outputs (source is specific to the installer)

---

## 7. Vault .gitignore Template

Written by `cco vault init` to `<user-config>/.gitignore`:

```gitignore
# Secrets — never committed
secrets.env
*.env
.credentials.json
*.key
*.pem

# Runtime files — generated, not user config
projects/*/docker-compose.yml
projects/*/.managed/
projects/*/.pack-manifest
projects/*/.cco-meta

# Session state — transient, large, personal
projects/*/claude-state/
projects/*/rag-data/

# Pack install temporary files
packs/*/.cco-install-tmp/
```

The template is conservative. Users may remove entries that do not apply to their setup, but CCO emits a warning if `secrets.env` is ever staged for commit.

---

## 8. Access Control Patterns

### Pattern 1: Personal vault only

```
github.com/alice/cco-vault (private)
└── packs/ global/ projects/ templates/
```

All config in one private repo. Backup via `cco vault push`. No sharing.

### Pattern 2: Vault + public packs

```
github.com/alice/cco-vault (private)   ← full personal config
github.com/alice/cco-packs (public)    ← curated subset for sharing
```

Alice maintains both repos. When she wants to make a pack public:
1. Copy or develop the pack in `cco-packs/packs/<name>/`
2. Or: `git subtree push` from the vault to the public repo (future command: `cco pack publish`)

Others install with `cco pack install https://github.com/alice/cco-packs`.

### Pattern 3: Team config

```
github.com/acme/cco-config (private, org members only)
└── packs/
    ├── acme-conventions/
    └── acme-deploy/
```

Team members install with `cco pack install git@github.com:acme/cco-config`. Auth via SSH key or `GITHUB_TOKEN` (already configured for `gh` CLI).

### Pattern 4: Mixed access (two repos)

```
github.com/alice/cco-vault    (private) ← personal vault
github.com/acme/cco-config    (private, team) ← team packs
github.com/alice/cco-open     (public) ← open-source packs
```

Alice installs from all three. Each has its own auth level. CCO treats them the same — just different git URLs.

---

## 9. share.yml — Optional Sharing Manifest

An optional file at the Config Repo root that improves discoverability. Not required for install to work.

```yaml
# share.yml

name: "acme-team-config"
description: "Engineering configuration bundle for ACME Corp"
author: "ACME Platform Team"
homepage: https://github.com/acme/cco-config

packs:
  - name: acme-conventions
    description: "Code style, commit conventions, and review standards"
    tags: [conventions, style, team]
  - name: acme-deploy
    description: "Deployment scripts and infrastructure patterns"
    tags: [deploy, infra, aws]

templates:
  - name: acme-service
    description: "Microservice template with standard ACME setup"
    tags: [microservice, fastapi, postgres]

rules:
  - name: security.md
    description: "Security review checklist"
```

`cco share list` reads `share.yml` from all registered remote sources. Future: a public registry would index `share.yml` files from user-submitted repos.

---

## 10. Code Changes Required

### 10.1 New environment variables (bin/cco)

```bash
# Add after existing GLOBAL_DIR / PROJECTS_DIR:
USER_CONFIG_DIR="${CCO_USER_CONFIG_DIR:-$REPO_ROOT/user-config}"

# Override derived vars only if not explicitly set
GLOBAL_DIR="${CCO_GLOBAL_DIR:-$USER_CONFIG_DIR/global}"
PROJECTS_DIR="${CCO_PROJECTS_DIR:-$USER_CONFIG_DIR/projects}"
PACKS_DIR="${CCO_PACKS_DIR:-$USER_CONFIG_DIR/packs}"
TEMPLATES_DIR="${CCO_TEMPLATES_DIR:-$USER_CONFIG_DIR/templates}"
```

### 10.2 lib/packs.sh

Change all references from `$GLOBAL_DIR/packs` to `$PACKS_DIR`.

### 10.3 cmd-pack.sh

- `cco pack install` — new command (lib/cmd-pack.sh, new `cmd_pack_install` function)
- `cco pack update` — new command
- `cco pack export` — new command (archive for manual sharing)
- Existing commands: no changes to logic, only path references

### 10.4 New lib/cmd-vault.sh

Implements all `cco vault` subcommands. Thin wrappers around git with CCO-specific defaults (`.gitignore` template, secret detection, categorized output).

### 10.5 New lib/cmd-project-install.sh (or extend cmd-project.sh)

`cco project install` — mirrors `cco pack install` for project templates.

### 10.6 cco init

Update `cco init` to create `user-config/` instead of separate `global/` + `projects/`. Existing installations handled by migration (see §11).

### 10.7 .gitignore in tool repo

Change:
```
global/
projects/
```
To:
```
user-config/
```

---

## 11. Migration from Current Structure

### For existing users (cco update migration)

Migration script: `migrations/global/004_user-config-dir.sh`

```
Actions:
1. Create user-config/
2. Move global/ → user-config/global/
3. Move global/packs/ → user-config/packs/   (elevated out of global/)
4. Move projects/ → user-config/projects/
5. Create user-config/templates/ (empty)
6. Update .gitignore in tool repo
7. Write migration note: "Run 'cco vault init' to enable versioning"
```

**Idempotent**: checks if `user-config/` already exists before moving.

**CCO_GLOBAL_DIR / CCO_PROJECTS_DIR backward compatibility**: if a user has these set in their shell profile pointing to the old paths, they continue to work (the derived vars are only used when the explicit vars are not set). CCO prints a hint suggesting they switch to `CCO_USER_CONFIG_DIR`.

### For new users (cco init)

`cco init` directly creates the `user-config/` structure. No migration needed.

---

## 12. Future Evolution

### Short-term (next sprints)

| Feature | Sprint | Notes |
|---|---|---|
| `cco pack publish <name> --to <remote>` | S8 | `git subtree push` wrapper — publishes one pack to a separate remote without maintaining a separate repo manually |
| `share.yml` generation | S8 | `cco share init` scaffolds a `share.yml` from existing packs |
| Template variable resolution | S6 | `{{PLACEHOLDER}}` substitution in `project.yml` at install time |

### Medium-term

| Feature | Notes |
|---|---|
| Registry index | A publicly crawled index of `share.yml` files — browse and search available packs without knowing specific URLs. No server required from CCO side; the index is a static file hosted on GitHub Pages or similar. |
| `cco pack install acme/conventions` | Short-form install via registry (resolves to full git URL) |
| Lockfile for reproducible project setups | `project.yml` records installed pack version (git ref); `cco project sync` ensures exact versions are installed |

### Invariants to preserve

- Git is the only required transport (no custom protocol, no registry server)
- Auth is always delegated to the system git credential layer (SSH, GITHUB_TOKEN, or `--token`)
- Secrets are never committed (`.gitignore` enforced with warning on `cco vault sync`)
- The Config Repo structure is the same regardless of host (GitHub, GitLab, Gitea, bare server)
