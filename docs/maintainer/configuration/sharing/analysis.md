# Analysis: Config Repo — Versioning & Sharing

> **Status**: Analysis — approved, proceeding to design
> **Date**: 2026-03-04
> **Scope**: Sprint 6 (Sharing & Import) + Sprint 10 (Config Vault)
> **Related**: [roadmap.md](../../decisions/roadmap.md) §Sprint 6, §Sprint 10
> **Enhancements**: Integrated below (§8–§14)

---

## Table of Contents

1. [Context and Motivation](#1-context-and-motivation)
2. [Problem Space](#2-problem-space)
3. [Current Limitations](#3-current-limitations)
4. [Options Evaluated](#4-options-evaluated)
5. [Key Decisions](#5-key-decisions)
6. [Access Control Model](#6-access-control-model)
7. [Constraints and Non-Goals](#7-constraints-and-non-goals)

---

## 1. Context and Motivation

Sprint 6 (Sharing & Import) and Sprint 10 (Config Vault) address two related but distinct needs:

- **Versioning**: personal backup and rollback of user configuration (global settings, projects, packs)
- **Sharing**: distributing packs, project templates, and rules between users or teams

These sprints were originally designed independently. After analysis, a unified "Config Repo" model was chosen that covers both needs with a single concept and minimal surface area.

**Current users**: the tool author + ~7 team members in a single organization. No public registry exists yet. The design must be simple enough to work today while being extensible toward a future ecosystem of publicly shared packs.

---

## 2. Problem Space

Two orthogonal axes define the requirements:

|                  | **Personal** | **Team / Public** |
|---|---|---|
| **Versioning**   | Rollback config changes, restore after machine loss | Track which pack version each project uses |
| **Sharing**      | Export a specific pack to share with a colleague | Distribute a curated set of packs across the organization |

Key constraint: sharing must be **granular** (share one pack, not everything) without causing **repo proliferation** (not one git repo per pack).

---

## 3. Current Limitations

| Limitation | Impact |
|---|---|
| `global/` and `projects/` are gitignored | No versioning or backup for user configuration |
| Packs are local only (`global/packs/`) | No mechanism to share a pack with another user |
| Packs are nested inside `global/` | Makes `global/` serve two different purposes: personal `.claude/` config AND reusable packs |
| No `templates/` concept | Project templates (shareable `project.yml` scaffolds) have no dedicated location |
| `global/`, `projects/` are separate top-level dirs | Two directories to manage, gitignore, or version — no single root for user data |

---

## 4. Options Evaluated

### Option A — Two separate systems (original plan)
- **Vault** (S10): a git repo wrapping `global/` + `projects/`
- **Share** (S6): `cco pack install <git-url>` with a `manifest.yml` manifest in each shared repo

**Rejected because**: vault and share repos have identical structure — two separate concepts for the same thing. If the user wants to share something from their vault, they need to configure two systems.

---

### Option B — Unified git model ("vault IS the share")
`global/` becomes a git repo. Versioning and sharing are the same concept: share by pushing (or making public) the repo or a branch.

**Rejected in pure form because**: within a single git repo, you cannot have some directories public and others private. Granular access control is impossible without multiple repos.

---

### Option C — Per-pack git repos
Each pack is an autonomous git repo cloned into `global/packs/<name>/`.

**Rejected because**: repo proliferation (10 packs = 10 repos to manage). No versioning for global `.claude/` settings. Vault would remain a separate system.

---

### Option D — Tarball / archive exchange
`cco pack export` → `.tar.gz`, `cco pack import` → extract.

**Rejected because**: no incremental updates, no history, no integrity guarantees without checksums. Manual file transfer does not scale even for a small team.

---

### Option E — External config directory (dotfiles style)
Dedicated config directory outside the tool repo, managed by CCO, versioned separately.

**Partial adoption**: the external directory concept (`~/.cco/`) is adopted, but as one of two supported modes rather than as a replacement. Users can choose between an in-repo `user-config/` and an external directory.

---

### Chosen: Config Repo model (B + E hybrid)

**Core insight**: the granular-without-proliferation requirement is solved by **git sparse-checkout**, not by per-resource repos.

```bash
# Install one pack from a repo that contains many
git clone --no-checkout --filter=blob:none <repo-url> /tmp/cco-tmp
git -C /tmp/cco-tmp sparse-checkout set packs/my-pack
git -C /tmp/cco-tmp checkout
```

This allows a single shared repo to contain multiple packs, while consumers install only the subset they need. Works with any git host (GitHub, GitLab, self-hosted Gitea).

---

## 5. Key Decisions

### KD-1: One concept — Config Repo

A Config Repo is a git repository that follows a standard directory convention. It can serve as:
1. **Personal vault**: private repo backing all user config
2. **Shared bundle**: public or team-private repo with selected resources
3. **Both**: the vault made public (or specific branches/remotes)

The user manages access at the git hosting level, not through CCO.

### KD-2: Packs elevated out of `global/`

Currently packs live at `global/packs/`. In the new model, `packs/` is a top-level directory of the Config Repo, at the same level as `global/` and `projects/`. This reflects the different nature of packs (reusable, shareable) vs global settings (personal).

### KD-3: Unified user data root — `user-config/`

Instead of separate top-level `global/` and `projects/` directories in the tool repo, a single `user-config/` directory holds all user-owned data. This directory:
- Is gitignored in the claude-orchestrator tool repo
- Can be initialized as a git repo independently (the vault)
- Has the same structure whether it lives inside the tool repo or at an external path (e.g. `~/.cco/`)

### KD-4: Access control delegated to git hosting

CCO does not implement resource-level access control. Visibility and authentication are properties of the git repo, not of individual resources within it. Consequence: resources with different visibility levels require different repos.

### KD-5: Pack source tracking

Each pack installed from a remote source stores a `.cco/source` metadata file recording the origin URL, path, and ref. This enables `cco pack update <name>` to pull the latest version from the original source without user intervention.

---

## 6. Access Control Model

### Visibility is per-repo, not per-resource

| Visibility | Mechanism | Example |
|---|---|---|
| Private (only you) | Private git repo | vault at `github.com/user/my-cco-config` (private) |
| Team-private | Private repo with org/team access | `github.com/company/team-config` (private, members only) |
| Public | Public git repo | `github.com/user/public-packs` (public) |

Within a single repo, all resources share the same access level. To share pack A publicly and keep pack B private, they must live in separate repos.

### Repo proliferation is bounded

The key observation: resources with the **same access level** coexist in the **same repo**. The number of repos is proportional to the number of distinct access tiers, not to the number of resources.

Typical user:
- 1 private vault (all personal config + private packs)
- 0–1 public repo (public packs, if any)
- 0–1 team repo (team-shared packs)

A team of 7 sharing a common pack set: 1 team repo. Not 7 × N repos.

### Authentication in CCO

CCO resolves credentials in this order:
1. SSH agent (SSH git URLs)
2. `GITHUB_TOKEN` environment variable (already used for `gh` CLI)
3. `--token <value>` flag on install commands
4. System git credential helper

No custom token storage is needed. Users configure credentials once at the system level.

### Future: selective publishing

A future `cco pack publish <name> --to <remote>` command could automate `git subtree push` to push a specific pack subdirectory to a separate remote (e.g. public). This avoids maintaining a separate repo manually. Deferred — not needed for Sprint 6.

---

## 7. Constraints and Non-Goals

**Constraints**:
- Must work without a registry or dedicated server
- Must not require per-user account management in CCO
- Installation must work with any git host (not GitHub-specific)
- Secrets (`secrets.env`, `.credentials.json`) must never appear in a shared or versioned repo

**Non-goals for Sprint 6 + 10**:
- Public registry / index of shared repos (future sprint)
- Selective per-directory publishing within a repo (`git subtree push`)
- Fine-grained token scoping per resource within a repo
- Dependency resolution between packs (Pack A requires Pack B)
- Semantic versioning / lockfile for pack dependencies

---

## Post-Implementation Refinements

> Sections 8–14 were identified after the base Config Repo implementation
> (359 tests passing) during real-world usage and review.

---

## 8. Naming Problems

### 8.1 `cco share` does not share anything

The `cco share` command manages the manifest file (`share.yml`) — it refreshes,
validates, and shows its contents. It does not share resources with anyone.
The name misleads users into expecting a sharing action.

**Decision**: rename to `cco manifest` (and `share.yml` → `manifest.yml`).

### 8.2 `pack install` is ambiguous

"Install" could mean:
- Download a pack from a remote Config Repo into `user-config/packs/` (current behavior)
- Add a pack to a project's `packs:` list in `project.yml` (not implemented)

These are fundamentally different operations: one fetches remote resources, the other
configures a local project.

**Decision**: keep `pack install` for remote download. Introduce `project add-pack`
and `project remove-pack` for the local project configuration action.

### 8.3 `pack export` vs publish

`pack export` creates a `.tar.gz` archive for offline distribution. A new `pack publish`
command is needed to push packs to a remote Config Repo. These must remain separate
commands with distinct semantics:

| Command | Direction | Output | Requires remote? |
|---|---|---|---|
| `cco pack export <name>` | local → file | `.tar.gz` in cwd | No |
| `cco pack publish <name> [<remote>]` | local → git repo | Commit + push | Yes |

---

## 9. Missing Features

### 9.1 No way to add a pack to a project

Users must manually edit `project.yml` YAML to add/remove packs from a project's
`packs:` list. This is error-prone and undiscoverable.

**Need**: `cco project add-pack <project> <pack>` and `cco project remove-pack`.

### 9.2 No way to publish packs/projects to remote repos

The system supports *consuming* from Config Repos (`install`, `update`) but has no
*producing* mechanism. Users must manually copy files and manage git commits.

**Need**: `cco pack publish` and `cco project publish` to push resources to named
remote Config Repos.

### 9.3 No top-level remote management

Vault has `cco vault remote add/remove`, but remotes are useful beyond vault:
publishing packs/projects also targets remote Config Repos. Remote management
should be a top-level concern.

**Need**: `cco remote add/remove/list` as top-level commands, with vault delegating
to them internally.

### 9.4 Manifest is misplaced

Currently `share.yml` lives in `user-config/` and is auto-refreshed there. But:

- In the **user-config** (local): the manifest is nearly useless. The user already
  knows what packs/projects they have — they created them. The manifest only matters
  if the user exposes the entire user-config as a public Config Repo (rare).

- In a **shared Config Repo** (remote): the manifest is essential. It's the index
  that `cco pack install` reads to discover available resources.

**Implication**: `cco manifest refresh` is primarily useful when working on a
**shared repo**, not on user-config. The auto-refresh on `pack create`/`pack remove`
in user-config is harmless but not the primary use case.

When a user runs `cco pack publish my-pack alberghi`, the publish command should
auto-refresh the **remote repo's** manifest, not the local one.

---

## 10. Portability Problems

### 10.1 Repository paths in project.yml

Project configs contain absolute host paths:

```yaml
repos:
  - path: ~/projects/backend-api
    name: backend-api
```

When shared, these paths don't exist on the recipient's machine.

**Observations**:
- `cco project install` already supports `{{VARIABLE}}` template substitution
- Repo paths could use template variables: `path: "{{REPO_BACKEND_API}}"`
- But the recipient doesn't know *what* repo to clone or *where* to find it

**Original decision**: add optional `url:` field to repo entries in templates.
During `project publish`, real paths are reverse-templated and URLs are inferred
from `git remote`. During `project install`, URLs are shown as hints and
auto-clone is offered.

> **SUPERSEDED by unified design**: The publish/install path handling has been
> unified with vault push/pull into a single mechanism. Both scenarios now use
> `@local` markers (replacing `{{REPO_*}}` template variables for publish) and
> `.cco/local-paths.yml` for machine-specific path storage. The `url:` field is
> retained and extended to vault save as well.
>
> See `../vault/local-path-resolution-design.md` for the complete unified design.
> Legacy `{{REPO_*}}` templates remain supported for backward compatibility.

### 10.2 Knowledge packs with external source

Packs can reference knowledge files from external directories:

```yaml
# pack.yml
knowledge:
  source: ~/projects/shared-knowledge
  files:
    - coding-conventions.md
```

These files are **not in the pack directory** — they're mounted at `cco start` time
from the host path. When published to a shared repo, the external files are absent
and the `source:` path won't exist on the recipient's machine.

**Two pack types**:

| Type | `source:` field | Files location | Shareable? |
|---|---|---|---|
| Self-contained | Absent (default) | `packs/<name>/knowledge/` | Yes |
| Source-referencing | Present (`~/path`) | External directory | No (broken paths) |

**Decision**: during `publish`, source-referencing packs are **automatically
internalized** in the published copy:

1. Files listed in `pack.yml` are copied from `source:` into `knowledge/` in the
   published version
2. The `source:` field is removed from the published `pack.yml`
3. The local pack remains unchanged (still source-referencing)

If the source directory is missing or files can't be found, publish aborts with
a clear error listing the missing files.

An explicit `cco pack internalize <name>` command is also provided for users who
want to permanently convert a source-referencing pack to self-contained.

---

## 11. Publish Target: Alternatives to `--to`

Research on CLI patterns (npm, cargo, gem, brew, git) identified five approaches
for specifying publish targets:

### 11.1 Named remotes (git pattern)

```bash
cco remote add alberghi git@github.com:alberghi-it/cco-config.git
cco pack publish alberghi-it alberghi
```

**Pros**: reusable, memorable, git-familiar, works for multiple targets.
**Cons**: requires setup step.

### 11.2 Positional URL

```bash
cco pack publish alberghi-it git@github.com:alberghi-it/cco-config.git
```

**Pros**: no setup needed, works in CI.
**Cons**: verbose for repeated use, error-prone (typos).

### 11.3 Per-pack metadata (remembers target)

```bash
cco pack publish alberghi-it alberghi    # first time: remembers
cco pack publish alberghi-it             # later: uses cached target
```

**Pros**: zero-arg for subsequent publishes, clear per-pack intent.
**Cons**: extra metadata to manage.

### Decision: Named remotes + per-pack memory (11.1 + 11.3 hybrid)

1. `cco remote add <name> <url>` — registers a Config Repo remote (shared between
   vault and publish)
2. `cco pack publish <name> <remote>` — publishes and remembers the remote in
   `.cco/source` as `publish_target:`
3. `cco pack publish <name>` — reuses cached `publish_target` from `.cco/source`
4. Positional URL also accepted as fallback: `cco pack publish <name> <url>`
   (auto-detected by presence of `:` or `/` in the argument)

---

## 12. Auto-Install Pack Dependencies

When a project template declares `packs: [pack-a, pack-b]` and the user runs
`cco project install`, the packs may not be installed locally.

**Current behavior**: no validation, no install. Packs are only checked at
`cco start` time (and skipped with a warning if missing).

**Desired behavior**:
1. After template installation, check which declared packs are missing locally
2. If the source Config Repo contains the missing packs → auto-install them
3. If the source repo doesn't contain them → warn with pack name (user installs
   manually from elsewhere)

This leverages the fact that `project install` already has the cloned Config Repo
in a temp directory — the packs are right there if they exist.

---

## 13. Auto-Clone Repositories on Project Install

When installing a project template, repo entries may include `url:` metadata.
The install flow should offer to clone missing repos.

**Flow**:

```
Installing project 'albit-book'...

This project requires 2 repositories:

  backend-api (git@github.com:acme-corp/backend-api.git)
    Local path [~/repos/backend-api]: _

  web-frontend (git@github.com:acme-corp/web-frontend.git)
    Local path [~/repos/web-frontend]: _
```

For each repo:
1. Show name + URL (if available)
2. Prompt for local path (default: `~/repos/<name>`)
3. If path exists → use it (no clone)
4. If path doesn't exist and URL is available → offer to clone
5. If path doesn't exist and no URL → error, ask user to provide valid path
6. Update `project.yml` with the resolved local paths

**Non-interactive mode** (CI/scripts): require all paths via `--var REPO_X=/path`
or fail with clear error listing required repos.

**Default clone directory**: `~/repos/<name>`. No `~/.cco/repos/` — keeps repos
in a standard location that users expect.

---

## 14. Revised Command Taxonomy

### Local operations

| Command | Action |
|---|---|
| `cco pack create <name>` | Create empty pack in `packs/` |
| `cco pack remove <name>` | Remove pack |
| `cco pack list / show / validate` | Info and validation |
| `cco pack internalize <name>` | Convert source-referencing → self-contained |
| `cco project create <name>` | Create project from template |
| `cco project add-pack <project> <pack>` | Add pack to project's `packs:` list |
| `cco project remove-pack <project> <pack>` | Remove pack from project's `packs:` list |

### Remote → Local (consume)

| Command | Action |
|---|---|
| `cco pack install <url> [--pick]` | Download pack(s) from Config Repo |
| `cco pack update <name> [--all]` | Update from recorded source |
| `cco project install <url> [--pick] [--as]` | Install template + auto-install packs + clone repos |

### Local → Remote (produce)

| Command | Action |
|---|---|
| `cco pack publish <name> [<remote>]` | Push pack to Config Repo (internalizes source packs) |
| `cco project publish <name> [<remote>]` | Push project template (reverse-templates paths, adds URLs) |
| `cco pack export <name>` | Create `.tar.gz` archive (offline, separate from publish) |

### Remote management

| Command | Action |
|---|---|
| `cco remote add <name> <url>` | Register a Config Repo remote |
| `cco remote remove <name>` | Unregister |
| `cco remote list` | List registered remotes |

### Manifest

| Command | Action |
|---|---|
| `cco manifest refresh` | Regenerate `manifest.yml` (primarily for shared repos) |
| `cco manifest validate` | Cross-check manifest vs disk |
| `cco manifest show` | Display manifest contents |

### Vault (personal versioning)

| Command | Action |
|---|---|
| `cco vault init / sync / diff / log / status` | As currently implemented |
| `cco vault push / pull` | Delegates to `cco remote` internally |
