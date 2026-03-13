# Sprint 5b — Analysis: Defaults, Templates & Update System

**Date**: 2026-03-13
**Scope**: Architecture-level

---

## 1. Current State Summary

### 1.1 Directory Structure

```
defaults/
├── managed/        → Baked in Docker image at /etc/claude-code/ (immutable)
├── global/         → Copied to user-config/global/ at cco init (user-owned after)
├── _template/      → Scaffolded per project via cco project create
└── tutorial/       → Copied as project at cco init
```

### 1.2 File Count & Roles

- **managed/**: 3 files (managed-settings.json, CLAUDE.md, init-workspace skill)
- **global/**: 14 files (CLAUDE.md, settings.json, mcp.json, 2 agents, 4 rules, 4 skills, setup.sh, setup-build.sh)
- **_template/**: 9 files (project.yml, setup.sh, secrets.env, mcp-packages.txt, CLAUDE.md, settings.json, language.md, .gitkeep files)
- **tutorial/**: 8 files (project.yml, setup.sh, CLAUDE.md, settings.json, tutorial-behavior.md, 3 skills)

### 1.3 Code References

**~45 lines reference `defaults/`** across:
- `bin/cco` (lines 7-8): Defines `DEFAULTS_DIR` and `TEMPLATE_DIR`
- `lib/cmd-init.sh` (lines 70, 110-138): Copies global config, setup scripts, tutorial
- `lib/cmd-project.sh` (lines 54, 61-71): Copies template, substitutes placeholders
- `lib/update.sh` (lines 491, 523, 569, 665, 686): Source for update comparisons
- `Dockerfile` (line 117): COPY defaults/managed/ → /etc/claude-code/
- Tests: ~6 assertions on structure

**Impact of reorganization**: ~15 path references to update. Low risk.

---

## 2. Update System — Current Implementation

### 2.1 Architecture

Hybrid checksum + migrations in `lib/update.sh` (743 lines):

- **Checksum engine**: SHA256 hashing, `.cco-meta` manifest, 6-state file classification
- **Migration runner**: Sequential `migrations/{global,project}/NNN_*.sh`, idempotent
- **Conflict resolution**: 4 modes (force/keep/backup/interactive)

### 2.2 File Classification

Current approach uses multiple hardcoded lists:

```bash
GLOBAL_USER_FILES=("mcp.json" "setup.sh" "setup-build.sh")     # Never updated
PROJECT_USER_FILES=("CLAUDE.md" "rules/language.md")            # Never updated
GLOBAL_SPECIAL_FILES=("rules/language.md")                       # Regenerated
GLOBAL_ROOT_COPY_IF_MISSING=("setup.sh" "setup-build.sh")       # Copy if absent
PROJECT_ROOT_COPY_IF_MISSING=("setup.sh" "secrets.env" "mcp-packages.txt")
```

**Problem**: 5 different lists with overlapping concerns. Adding a new file requires checking all lists.

### 2.3 What the Update Engine Tracks

| Scope | Tracked (in .cco-meta) | NOT Tracked |
|-------|----------------------|-------------|
| Global | `.claude/` files (CLAUDE.md, settings.json, agents, rules, skills) | setup.sh, setup-build.sh, mcp.json |
| Project | `.claude/settings.json` only | project.yml, setup.sh, secrets.env, mcp-packages.txt, CLAUDE.md |

**Critical gap**: project.yml — the most important config file — is not tracked at all.

### 2.4 Conflict Resolution — Current Limitations

The interactive mode offers 4 choices per file:
- (K)eep your version
- (U)pdate to new default
- (B)ackup yours (.bak) + update
- (S)kip (decide later)

**Missing**: No way to see WHAT changed, no line-level merge, no diff preview.

### 2.5 Migrations Inventory

**6 global + 6 project migrations** implemented:

Global: managed_scope, managed_init_workspace, user-config-dir, rename_share_to_manifest, split_global_setup, vault_gitignore_tmp

Project: memory_to_claude_state, add_browser_section, managed_dir, add_github_section, pack_mount_cleanup, mount_socket_default_false

---

## 3. Template System — Current State

### 3.1 Project Templates

Single hardcoded template at `defaults/_template/`. No `--template` flag.

**Template substitution** is ad-hoc sed:
```bash
# In cmd-project.sh
sed -i "s/{{PROJECT_NAME}}/$name/g" "$project_dir/project.yml"
sed -i "s/{{DESCRIPTION}}/$description/g" "$project_dir/project.yml"
```

4 placeholder types used across templates:
- `{{PROJECT_NAME}}`, `{{DESCRIPTION}}` — in project.yml, CLAUDE.md
- `{{COMM_LANG}}`, `{{DOCS_LANG}}`, `{{CODE_LANG}}` — in language.md
- `{{CCO_REPO_ROOT}}`, `{{CCO_USER_CONFIG_DIR}}` — in tutorial/project.yml

### 3.2 Pack Templates

**None** — `cco pack create` generates pack.yml inline via heredoc in cmd-pack.sh.

### 3.3 Project Install (from Remote)

`cco project install <url>` clones from Config Repo and resolves template variables.
This is separate from local templates — it's a remote-first flow.

---

## 4. Vault & Share — Merge Capabilities

### 4.1 Vault

Git wrapper in `lib/cmd-vault.sh` (560 lines). Operations: init, sync, diff, log, restore, push, pull.

**Merge support**: None. `git pull` can generate unhandled merge conflicts.

### 4.2 Relevance to Update System

Vault is **orthogonal** to update:
- Vault = user versioning (backup/restore of entire user-config)
- Update = framework → user propagation (selective file updates)

Potential integration: vault snapshot before destructive update operations.

---

## 5. Key Problems Identified

1. **`defaults/` mixes concerns**: Defaults (managed, global) and templates (_template, tutorial) have different lifecycles and ownership models

2. **Single template**: No way to create projects from different archetypes

3. **No pack template**: Pack scaffolding is inline code, not a template

4. **Incomplete tracking**: Root files (project.yml, setup.sh) not in .cco-meta

5. **Atomic file replacement**: No line-level merge — all-or-nothing per file

6. **Migration proliferation**: Every project.yml change needs a migration script

7. **No diff preview**: Users can't see what changed before deciding

8. **5 classification lists**: Adding files requires checking multiple lists

9. **No base version stored**: Only hashes in .cco-meta, not the actual file content needed for 3-way merge
