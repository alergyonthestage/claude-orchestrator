# Sharing & Backup

> Back up your configuration, sync across machines, and share packs with your team.
>
> Related: [cli.md](../reference/cli.md) | [project-setup.md](./project-setup.md) | [knowledge-packs.md](./knowledge-packs.md) | [Config Repo Design](../maintainer/configuration/config-repo/design.md)

---

## 1. Overview

A **Config Repo** is a git repository that follows the CCO directory convention. It serves two purposes:

- **Vault**: a private, versioned backup of all your user configuration (packs, projects, global settings, templates)
- **Shared bundle**: a repository that others can install packs and project templates from

Use a Config Repo when you want to:

- **Back up** your configuration and restore it on another machine
- **Share** knowledge packs with your team (conventions, guidelines, deployment patterns)
- **Distribute** project templates so teammates can bootstrap projects with a single command
- **Sync** your personal setup across multiple workstations

CCO does not implement access control. Visibility is a git hosting concern — use private repos for personal vaults and team configs, public repos for open-source packs.

### Config Repo Structure

```
my-config-repo/
├── manifest.yml           # Manifest: declares available packs and templates
├── .gitignore             # CCO-generated, excludes secrets + runtime files
├── packs/                 # Reusable knowledge packs
│   ├── react-guidelines/
│   │   ├── pack.yml
│   │   ├── knowledge/
│   │   ├── skills/
│   │   ├── agents/
│   │   └── rules/
│   └── deploy-patterns/
│       └── ...
├── templates/             # Shareable project templates
│   └── microservice/
│       ├── project.yml
│       └── .claude/
├── global/                # Personal settings (vault only, not shared)
│   └── .claude/
└── projects/              # Personal projects (vault only, not shared)
    └── my-app/
```

When someone runs `cco pack install` against your repo, only `packs/` and `templates/` are available. The `global/` and `projects/` directories are personal and stay in your vault.

---

## 2. Setting Up Your Config Repo

### Initialize the vault

```bash
cco vault init
```

This creates a git repository in your `user-config/` directory (or `CCO_USER_CONFIG_DIR` if set), writes a `.gitignore` that excludes secrets and runtime files, generates an initial `manifest.yml`, and creates the first commit.

If you want to use a custom path:

```bash
cco vault init ~/my-cco-vault
```

### Add a remote

```bash
cco vault remote add origin git@github.com:youruser/cco-vault.git
```

### Push your configuration

```bash
cco vault push
```

This pushes the current branch to the remote. On the first push, it sets the upstream tracking branch automatically.

### Day-to-day workflow

After making changes to your packs, projects, or global settings:

```bash
# See what changed
cco vault diff

# Commit with a summary
cco vault sync "added react-guidelines pack"

# Push to remote
cco vault push
```

`cco vault sync` shows a categorized summary of changes before committing:

```
Changes to commit:
  packs:     2 file(s)
  projects:  1 file(s)
  global:    1 file(s)
  total:     4 file(s)

Proceed? [Y/n]
```

It also detects secret files (`.env`, `.key`, `.pem`, `.credentials.json`) and aborts if any are staged, preventing accidental exposure.

---

## 3. Sharing Packs

### manifest.yml

Every Config Repo contains a `manifest.yml` at the root. This manifest declares which packs and templates are available for installation. CCO generates and maintains it automatically — you never need to write it by hand.

```yaml
# manifest.yml
name: "acme-team-config"
description: "Engineering configuration for ACME Corp"

packs:
  - name: acme-conventions
    description: "Code style, commit conventions, and review standards"
    tags: [conventions, style]
  - name: acme-deploy
    description: "Deployment scripts and infrastructure patterns"
    tags: [deploy, infra]

templates:
  - name: acme-service
    description: "Microservice template with standard ACME setup"
    tags: [microservice, fastapi]
```

### Keeping manifest.yml in sync

CCO updates `manifest.yml` automatically when you create or remove packs. To manually regenerate it from disk:

```bash
cco manifest refresh
```

This scans the `packs/` and `templates/` directories and rebuilds `manifest.yml`, preserving any custom name, description, and tags you have edited.

### Validating manifest.yml

```bash
cco manifest validate
```

Cross-checks `manifest.yml` against what exists on disk. Warns about:

- **Stale entries**: a pack listed in `manifest.yml` that no longer exists in `packs/`
- **Missing entries**: a pack directory that exists on disk but is not listed in `manifest.yml`

If issues are found, run `cco manifest refresh` to fix them.

### Viewing manifest.yml contents

```bash
cco manifest show
```

Displays a formatted view of your Config Repo's name, description, available packs, and templates.

---

## 4. Installing Packs from a Remote

### Install all packs from a Config Repo

```bash
cco pack install https://github.com/acme/cco-config
```

This clones the repo, reads `manifest.yml`, and installs every pack listed under `packs:` into your local `user-config/packs/` directory.

### Install a specific pack

```bash
cco pack install https://github.com/acme/cco-config --pick acme-conventions
```

Only installs the `acme-conventions` pack. If the name does not match any entry in `manifest.yml`, CCO prints the available pack names and exits.

### Overwrite existing packs

```bash
cco pack install https://github.com/acme/cco-config --force
```

By default, if a pack with the same name already exists locally:

- If it was installed from the **same source** — CCO updates it automatically
- If it was installed from a **different source** or created locally — CCO aborts and asks you to use `--force`

With `--force`, existing packs are overwritten without prompting.

### Private repositories

For SSH-based repos, authentication uses your existing SSH key:

```bash
cco pack install git@github.com:my-org/cco-config
```

For HTTPS repos, save a token with the remote for automatic authentication:

```bash
cco remote add team https://github.com/my-org/cco-config.git --token ghp_xxx
cco pack install https://github.com/my-org/cco-config.git   # token auto-resolved
```

Or pass a token directly:

```bash
cco pack install https://github.com/my-org/cco-config --token ghp_xxx
```

See [Authentication — Config Repo Authentication](./authentication.md#config-repo-authentication) for full details on token management, access control patterns, and multi-organization setups.

### Pin to a branch or tag

Append `@ref` to the URL to install from a specific branch, tag, or commit:

```bash
# Install from the v2.0 tag
cco pack install https://github.com/acme/cco-config@v2.0

# Install from a feature branch
cco pack install https://github.com/acme/cco-config@next
```

### Single-pack repositories

If a repository contains a single `pack.yml` at the root (no `manifest.yml`), CCO recognizes it as a single-pack repo and installs it directly:

```bash
cco pack install https://github.com/alice/react-best-practices
```

No `manifest.yml` is required in this case.

---

## 5. Updating Packs

Every pack installed from a remote carries a `.cco-source` metadata file that records where it came from:

```yaml
source: https://github.com/acme/cco-config
path: packs/acme-conventions
ref: main
installed: 2026-03-01
updated: 2026-03-01
```

### Update a single pack

```bash
cco pack update acme-conventions
```

Re-fetches the pack from its recorded source and replaces the local copy. If the pack has been modified locally, use `--force` to overwrite:

```bash
cco pack update acme-conventions --force
```

### Update all remote packs

```bash
cco pack update --all
```

Updates every pack that has a remote source (skips locally created packs). Combine with `--force` to overwrite local modifications:

```bash
cco pack update --all --force
```

Packs created locally with `cco pack create` have `source: local` in their `.cco-source` and are never touched by `--all`.

---

## 6. Exporting Packs

To share a pack as a standalone archive (without requiring git):

```bash
cco pack export acme-conventions
```

This creates `acme-conventions.tar.gz` in the current directory. The archive excludes the `.cco-source` metadata file, so the recipient gets a clean copy.

The recipient can extract it into their packs directory:

```bash
tar xzf acme-conventions.tar.gz -C user-config/packs/
```

---

## 7. Installing Project Templates

Project templates are stored under `templates/` in a Config Repo. They contain a `project.yml` and `.claude/` directory that may include `{{PLACEHOLDER}}` variables resolved at install time.

### Install a template

```bash
cco project install https://github.com/acme/cco-config --pick acme-service
```

If the repo contains a single template, `--pick` is optional — CCO auto-selects it.

If there are multiple templates and you omit `--pick`, CCO lists the available templates and asks you to choose:

```bash
cco project install https://github.com/acme/cco-config
# Available templates:
#   - acme-service
#   - acme-frontend
# Multiple templates found. Use --pick <name> to select one.
```

### Rename the project on install

```bash
cco project install https://github.com/acme/cco-config --pick acme-service --as my-api
```

By default, the project is created with the template's name. Use `--as` to give it a different name.

### Pre-set template variables

Templates may contain `{{VARIABLE}}` placeholders in `project.yml` and `.claude/CLAUDE.md`. CCO resolves them at install time.

Predefined variables:

| Variable | Source | Default |
|---|---|---|
| `{{PROJECT_NAME}}` | `--as` flag or template name | Template name |
| `{{DESCRIPTION}}` | Interactive prompt | `TODO: Add project description` |

Any other `{{VARIABLE}}` triggers an interactive prompt. You can pre-set values with `--var`:

```bash
cco project install https://github.com/acme/cco-config \
  --pick acme-service \
  --as my-api \
  --var DESCRIPTION="My REST API" \
  --var DB_NAME=myapp_db
```

Multiple `--var` flags can be used. Variables not covered by `--var` are prompted interactively.

### Authentication and ref pinning

The same options available for `cco pack install` work here:

```bash
# Private repo with token
cco project install https://github.com/acme/cco-config --pick acme-service --token ghp_xxx

# Specific branch
cco project install https://github.com/acme/cco-config@v2.0 --pick acme-service

# Overwrite existing project
cco project install https://github.com/acme/cco-config --pick acme-service --force
```

---

## 8. Vault Commands Reference

| Command | Description |
|---------|-------------|
| `cco vault init [<path>]` | Initialize git-backed vault for config versioning |
| `cco vault sync [<message>]` | Commit current state with pre-commit summary |
| `cco vault sync --dry-run` | Show summary without committing |
| `cco vault sync --yes` | Skip confirmation prompt |
| `cco vault diff` | Show uncommitted changes grouped by category |
| `cco vault log [--limit N]` | Show commit history (default: last 20) |
| `cco vault restore <ref>` | Restore config to a previous state (does not move HEAD) |
| `cco vault remote add <name> <url>` | Add a git remote |
| `cco vault remote remove <name>` | Remove a git remote |
| `cco vault push [<remote>]` | Push to remote (default: origin) |
| `cco vault pull [<remote>]` | Pull from remote (default: origin) |
| `cco vault status` | Show vault state, remotes, and uncommitted changes |
| `cco vault profile create <name>` | Create a new vault profile (branch-based isolation) |
| `cco vault profile list` | List all profiles with resource counts |
| `cco vault profile show` | Show current profile details and sync state |
| `cco vault profile switch <name>` | Switch to another profile (auto-commits pending changes) |
| `cco vault profile rename <new-name>` | Rename the current profile |
| `cco vault profile delete <name>` | Delete a profile (moves exclusive resources to main first) |
| `cco vault profile add project <name>` | Mark a project as exclusive to this profile |
| `cco vault profile add pack <name>` | Mark a pack as exclusive to this profile |
| `cco vault profile remove project <name>` | Make a project shared again (removes profile exclusivity) |
| `cco vault profile remove pack <name>` | Make a pack shared again (removes profile exclusivity) |
| `cco vault profile move project <name> --to <profile>` | Move a project to a specific profile or main |
| `cco vault profile move pack <name> --to <profile>` | Move a pack to a specific profile or main |

---

## 9. Multi-Machine Workflow

### Machine A — Set up and push

```bash
# 1. Initialize (if not already done)
cco init

# 2. Create some packs
cco pack create react-guidelines
# ... add knowledge files, skills, rules ...

cco pack create deploy-patterns
# ... add deployment knowledge ...

# 3. Initialize the vault
cco vault init

# 4. Add your remote
cco vault remote add origin git@github.com:youruser/cco-vault.git

# 5. Sync and push
cco vault sync "initial config setup"
cco vault push
```

### Machine B — Clone and use

```bash
# 1. Install the orchestrator
git clone <orchestrator-url> ~/claude-orchestrator
cd ~/claude-orchestrator
cco init

# 2. Pull your configuration from the vault
cco vault init
cco vault remote add origin git@github.com:youruser/cco-vault.git
cco vault pull

# 3. Your packs, projects, templates, and global settings are now available
cco pack list
cco project list
```

### Keeping machines in sync

On either machine, after making changes:

```bash
cco vault sync "updated react-guidelines"
cco vault push
```

On the other machine:

```bash
cco vault pull
```

### Profiles for different project sets per machine

If you have different project sets on different machines (e.g., work projects on one PC, personal projects on another), use vault profiles to keep them isolated while sharing global settings, packs, and templates.

```bash
# On your work machine — create a profile for work projects
cco vault profile create work
cco vault profile add project work-api
cco vault profile add project work-frontend
cco vault sync "add work projects"
cco vault push

# On your personal machine — create a profile for personal projects
cco vault profile create personal
cco vault profile add project side-project
cco vault profile add project blog
cco vault sync "add personal projects"
cco vault push
```

Profiles use git branches under the hood. Shared resources (global config, packs, templates) live on `main` and are automatically synced between profiles when you push or pull. Each profile only sees its own exclusive projects plus the shared resources.

> **Note — Tracking-only isolation**: Profile assignment (`profile add` / `profile remove`) is a tracking declaration in `.vault-profile` — it does not physically move or delete files. Resources remain on all branches. Isolation is enforced at sync time: `vault sync`, `vault push`, and `vault pull` use the profile's declared paths to selectively stage and commit only the relevant resources.

Without profiles, the vault works exactly as before — everything on a single `main` branch. Profiles are opt-in and only needed when you want selective sync across machines.

### Memory and session data

Each project has two separate directories for Claude Code state:

- **`projects/<name>/memory/`** — Auto memory files (`MEMORY.md` and topic files). This directory is **vault-tracked** and syncs across machines when you push/pull. It contains personal working notes, task progress, and session-specific context.
- **`projects/<name>/claude-state/`** — Session transcripts (used by `/resume`). This directory is **local only** (gitignored in the vault). Transcripts are large and machine-specific, so they are not synced.

Both are mounted into the container at runtime. The `memory/` directory is mounted as a Docker child mount that overrides the `memory/` subdirectory within `claude-state/`, ensuring the two remain separate.

### Team sharing (separate repos)

For team use, keep your personal vault private and maintain a separate shared repo:

```bash
# Personal vault (private)
github.com/alice/cco-vault

# Team config (private, org members)
github.com/acme/cco-config
```

Teammates install packs from the team repo:

```bash
cco pack install git@github.com:acme/cco-config
```

Each person's vault tracks where each pack was installed from via the `.cco-source` metadata.

---

## 10. manifest.yml Format

The `manifest.yml` manifest is auto-generated and maintained by CCO. You can edit the `name`, `description`, and per-entry `description`/`tags` fields — they are preserved across `cco manifest refresh` runs.

```yaml
# Auto-generated by cco — edit name, description, and tags as needed
name: "my-config-repo"
description: "Personal knowledge packs and project templates"

packs:
  - name: react-guidelines
    description: "React patterns, hooks conventions, testing approach"
    tags: [react, frontend, testing]
  - name: deploy-patterns
    description: "AWS deployment automation and IaC patterns"
    tags: [deploy, aws, terraform]

templates:
  - name: fullstack-app
    description: "Full-stack template with Next.js + FastAPI"
    tags: [nextjs, fastapi, postgres]

# Empty sections use []:
# packs: []
# templates: []
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | No | Human-readable name for the Config Repo |
| `description` | No | Brief description of the repo's purpose |
| `packs` | Yes | List of available packs (or `[]` if none) |
| `packs[].name` | Yes | Pack directory name (must match `packs/<name>/`) |
| `packs[].description` | No | What the pack provides |
| `packs[].tags` | No | Categorization tags |
| `templates` | Yes | List of available templates (or `[]` if none) |
| `templates[].name` | Yes | Template directory name (must match `templates/<name>/`) |
| `templates[].description` | No | What the template provides |
| `templates[].tags` | No | Categorization tags |

### Auto-management

| Action | Effect on manifest.yml |
|--------|---------------------|
| `cco pack create <name>` | Adds entry under `packs:` |
| `cco pack remove <name>` | Removes entry from `packs:` |
| `cco manifest refresh` | Regenerates from disk, preserving custom metadata |
| `cco manifest validate` | Cross-checks manifest vs. disk contents |
