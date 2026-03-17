# Sharing Enhancements — Analysis

> **Scope**: Enhancements to the base Config Repo sharing system.
> This document builds on the base [analysis](./analysis.md) and [design](./design.md)
> (Sprint 6+10), identifying gaps, naming issues, and missing features discovered
> during real-world usage and review.
>
> **Date**: 2026-03-05
> **Design**: [enhancements-design.md](./enhancements-design.md)

---

## 1. Context

The Config Repo infrastructure (Sprint 6 + Sprint 10) is fully implemented:
`pack install`, `pack update`, `pack export`, `project install`, `share refresh/validate/show`,
and `vault init/sync/diff/log/status/restore/remote/push/pull` — 359 tests passing.

This analysis identifies **gaps, naming problems, and missing features** discovered
during real-world usage and review.

---

## 2. Naming Problems

### 2.1 `cco share` does not share anything

The `cco share` command manages the manifest file (`share.yml`) — it refreshes,
validates, and shows its contents. It does not share resources with anyone.
The name misleads users into expecting a sharing action.

**Decision**: rename to `cco manifest` (and `share.yml` → `manifest.yml`).

### 2.2 `pack install` is ambiguous

"Install" could mean:
- Download a pack from a remote Config Repo into `user-config/packs/` (current behavior)
- Add a pack to a project's `packs:` list in `project.yml` (not implemented)

These are fundamentally different operations: one fetches remote resources, the other
configures a local project.

**Decision**: keep `pack install` for remote download. Introduce `project add-pack`
and `project remove-pack` for the local project configuration action.

### 2.3 `pack export` vs publish

`pack export` creates a `.tar.gz` archive for offline distribution. A new `pack publish`
command is needed to push packs to a remote Config Repo. These must remain separate
commands with distinct semantics:

| Command | Direction | Output | Requires remote? |
|---|---|---|---|
| `cco pack export <name>` | local → file | `.tar.gz` in cwd | No |
| `cco pack publish <name> [<remote>]` | local → git repo | Commit + push | Yes |

---

## 3. Missing Features

### 3.1 No way to add a pack to a project

Users must manually edit `project.yml` YAML to add/remove packs from a project's
`packs:` list. This is error-prone and undiscoverable.

**Need**: `cco project add-pack <project> <pack>` and `cco project remove-pack`.

### 3.2 No way to publish packs/projects to remote repos

The system supports *consuming* from Config Repos (`install`, `update`) but has no
*producing* mechanism. Users must manually copy files and manage git commits.

**Need**: `cco pack publish` and `cco project publish` to push resources to named
remote Config Repos.

### 3.3 No top-level remote management

Vault has `cco vault remote add/remove`, but remotes are useful beyond vault:
publishing packs/projects also targets remote Config Repos. Remote management
should be a top-level concern.

**Need**: `cco remote add/remove/list` as top-level commands, with vault delegating
to them internally.

### 3.4 Manifest is misplaced

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

## 4. Portability Problems

### 4.1 Repository paths in project.yml

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

**Decision**: add optional `url:` field to repo entries in templates. During
`project publish`, real paths are reverse-templated and URLs are inferred from
`git remote`. During `project install`, URLs are shown as hints and auto-clone
is offered.

### 4.2 Knowledge packs with external source

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

## 5. Publish Target: Alternatives to `--to`

Research on CLI patterns (npm, cargo, gem, brew, git) identified five approaches
for specifying publish targets:

### 5.1 Named remotes (git pattern)

```bash
cco remote add alberghi git@github.com:alberghi-it/cco-config.git
cco pack publish alberghi-it alberghi
```

**Pros**: reusable, memorable, git-familiar, works for multiple targets.
**Cons**: requires setup step.

### 5.2 Positional URL

```bash
cco pack publish alberghi-it git@github.com:alberghi-it/cco-config.git
```

**Pros**: no setup needed, works in CI.
**Cons**: verbose for repeated use, error-prone (typos).

### 5.3 Per-pack metadata (remembers target)

```bash
cco pack publish alberghi-it alberghi    # first time: remembers
cco pack publish alberghi-it             # later: uses cached target
```

**Pros**: zero-arg for subsequent publishes, clear per-pack intent.
**Cons**: extra metadata to manage.

### 5.4 Interactive prompt

```bash
cco pack publish alberghi-it
> Target? []: alberghi
```

**Pros**: friendly. **Cons**: not scriptable, slow for repeated use.

### 5.5 Global default registry

```bash
# In settings: default_publish_target: alberghi
cco pack publish alberghi-it
```

**Pros**: zero-arg. **Cons**: one default doesn't fit multi-repo workflows.

### Decision: Named remotes + per-pack memory (5.1 + 5.3 hybrid)

1. `cco remote add <name> <url>` — registers a Config Repo remote (shared between
   vault and publish)
2. `cco pack publish <name> <remote>` — publishes and remembers the remote in
   `.cco/source` as `publish_target:`
3. `cco pack publish <name>` — reuses cached `publish_target` from `.cco/source`
4. Positional URL also accepted as fallback: `cco pack publish <name> <url>`
   (auto-detected by presence of `:` or `/` in the argument)

---

## 6. Auto-Install Pack Dependencies

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

## 7. Auto-Clone Repositories on Project Install

When installing a project template, repo entries may include `url:` metadata.
The install flow should offer to clone missing repos.

**Flow**:

```
Installing project 'albit-book'...

This project requires 2 repositories:

  backend-api (git@github.com:acme-corp/backend-api.git)
    Local path [~/repos/backend-api]: ▌

  web-frontend (git@github.com:acme-corp/web-frontend.git)
    Local path [~/repos/web-frontend]: ▌
```

For each repo:
1. Show name + URL (if available)
2. Prompt for local path (default: `~/repos/<name>`)
3. If path exists → use it (no clone)
4. If path doesn't exist and URL is available → offer to clone:
   ```
   ~/repos/backend-api does not exist.
   Clone from git@github.com:acme-corp/backend-api.git? [Y/n]: Y
   Cloning into ~/repos/backend-api...
   ```
5. If path doesn't exist and no URL → error, ask user to provide valid path
6. Update `project.yml` with the resolved local paths

**Non-interactive mode** (CI/scripts): require all paths via `--var REPO_X=/path`
or fail with clear error listing required repos.

**Default clone directory**: `~/repos/<name>`. No `~/.cco/repos/` — keeps repos
in a standard location that users expect.

---

## 8. Revised Command Taxonomy

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
