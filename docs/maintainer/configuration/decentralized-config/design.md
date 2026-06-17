# Decentralized In-Repo Config — Design

**Status**: Approved for implementation (2026-06-15). Authoritative design; drives
the phased implementation (§9).
**Requirements**: `requirements.md` (AD1-AD12, FR-*).
**Decision records**: `decisions/` — ADR-0001 (decentralization), 0002
(machine-agnostic config), 0003 (sync-as-copy), 0004 (config/state/cache separation),
0005 (dual `.claude` scope), 0006 (breaking cutover + lazy migration), 0007 (system-dir
locations / XDG), 0008 (config versioning model), 0009 (auto-memory is machine-local STATE),
0010 (resource authoring + per-user tags).
**Decision history (historical)**: `reviews/15-06-2026-sync-adversarial-review.md`,
`reviews/15-06-2026-simplification-analysis.md`.

> `requirements.md` says **what** and **why**; this document says **how**. It is the
> single source of truth for the refactor. Open questions are isolated in §13 and are
> the subject of dedicated follow-up analyses; everything else is decided.

---

## 1. Architecture Overview

Three ideas, no custom diff/merge: **machine-agnostic committed config**, **plain
git as the cross-PC transport**, and **sync = copy** within a project on one machine.

```mermaid
flowchart TB
  subgraph repoA["repo A"]
    A1[".cco/project.yml (logical names, no paths)"]
    A2[".cco/claude/ (project scope)"]
    A3[".claude/ (repo scope)"]
    A4[".cco/secrets.env (gitignored)"]
  end
  subgraph repoB["repo B (member)"]
    B1[".cco/ (identical copy after cco sync)"]
  end
  subgraph sys["system dirs (per machine, hidden)"]
    IDX["index: name->abs path, project->repos"]
    ST["state/ per project (compose, claude-state, tmp)"]
    CA["cache/ (llms, installed)"]
  end
  subgraph home["~/.cco (personal git store)"]
    P["packs/ (authored)"]
    T["templates/"]
    G["global/.claude"]
  end
  A1 -- "cco sync = copy (filesystem)" --> B1
  IDX --> CCO[cco]
  repoA --> CCO
  home --> CCO
  CCO --> SESS["docker session: /workspace/<repo> + /workspace/.claude"]
  repoA -. "git push/pull (cross-PC transport)" .-> REM[(repo A remote)]
  home -. "Domain A (managed, deferred)" .-> PREM[(personal remote)]
  CCO -. "Domain B: publish/install" .-> CR[(Config Repos)]
```

- **Committed `<repo>/.cco/`** — machine-agnostic config, versioned with the code.
- **System dirs** — per-machine state, cache, and the name→path index; hidden, never committed.
- **`~/.cco/`** — personal git store for global resources (Domain A; depth deferred).
- **Sync** — a plain copy from a chosen source repo to targets (no merge engine).
- **Cross-PC** — plain `git` on each repo's own remote.

---

## 2. Layout

### 2.1 In-repo (committed) — machine-agnostic only
```
<repo>/
├── .claude/                  # COMMITTED — repo-local Claude config → /workspace/<repo>/.claude
├── .cco/
│   ├── .gitignore            # ignores secrets.env (+ secret patterns)
│   ├── project.yml           # logical names only; identical across the project's repos
│   ├── secrets.env.example   # COMMITTED skeleton
│   ├── secrets.env           # GITIGNORED — real values, user-edited (only in-repo exception)
│   └── claude/               # COMMITTED + (copy-)synced → /workspace/.claude
│       └── CLAUDE.md, rules/, agents/, skills/   # authored config ONLY — no generated files
```
This tree holds **authored config only**. Framework-generated files (`packs.md`,
`workspace.yml`) are NOT written here — they would pollute the truthful `git diff` and
the sync (ADR-0002/0004). They are produced in the machine-local cache (§2.2) and
overlaid into `/workspace/.claude` via nested `:ro` mounts, exactly like pack/llms
resources (RD-claude-mount, ADR-0005). `packs/` and `llms/` are framework-reserved
sub-paths within `/workspace/.claude`; committed config must not author into them.
`.cco/.gitignore` (committed):
```gitignore
secrets.env
*.env
*.key
*.pem
.credentials.json
!secrets.env.example
```
A pre-commit/pre-push scan (reused from `lib/secrets.sh`) refuses real secrets and
**exempts `*.example` from the content scan** (FR-S3).

### 2.2 System dirs (per machine, hidden, never committed) — ADR-0007
```
<state>/cco/projects/<id>/   # generated docker-compose.yml, claude-state/, memory/, .tmp/, meta
<state>/cco/index            # name -> absolute path; project -> [repo names]; tags
<state>/cco/                 # remotes+tokens, last_seen/last_read, sync-meta (§4.6), seeds
<cache>/cco/                 # llms/, installed/ (Config-Repo caches)
<cache>/cco/projects/<id>/   # generated .claude overlays (packs.md, workspace.yml) → :ro into /workspace/.claude
```
**Locations (ADR-0007)** — XDG layout on both Linux *and* macOS (no `~/Library`):
- `<state>` = `$CCO_STATE_HOME` → `$XDG_STATE_HOME/cco` → `~/.local/state/cco`
- `<cache>` = `$CCO_CACHE_HOME` → `$XDG_CACHE_HOME/cco` → `~/.cache/cco`

The **index lives in STATE** (machine-local, non-portable, scan-rebuildable — not
CONFIG). Resolve bases **host-side only** (never compute `$XDG_*` inside the
container); ignore unset/empty/non-absolute XDG values; create `0700`. Rationale: keep
the committed `.cco/` small and clean, make state un-committable by construction, and
protect it from accidental edits.

**Auto-memory is STATE (ADR-0009).** Claude Code's auto-memory (`memory/`) is, like
session transcripts (`claude-state/`), session/runtime **state** — not config. It lives
**machine-local** in `<state>/cco/projects/<id>/memory/`, never in `~/.cco` or
`<repo>/.cco/` (which hold only authored config, ADR-0008). It is **not versioned and not
synced cross-PC in v1**: the vault's auto-commit (D33) + `.gitkeep` (D32) machinery is
dropped with the vault (§9). Cross-PC / cross-team sync of *state* (memory **and**
transcripts) is a deferred opt-in feature (R-state-sync, §12). This resolves RD-memory and
satisfies the Phase-3 gate (review BL2).

### 2.3 `~/.cco/` — personal git store (Domain A; management model = ADR-0008)
> CONFIG store deliberately keeps the `~/.cco` **dotdir** (ADR-0007), not
> `$XDG_CONFIG_HOME/cco`: it is a user-facing, git-versioned tree the user authors in
> directly (docker `~/.docker` / cargo `~/.cargo` precedent). Clean split: `~/.cco` =
> what you edit and version; XDG state/cache = machine-internal plumbing you never touch.
```
~/.cco/
├── .git/                # personal store, opt-in remote
├── .gitignore           # allowlist discipline: only packs/ templates/ global/.claude + tags.yml committed
├── packs/               # authored packs (flat, one dir per pack)
├── templates/           # authored templates
├── global/.claude/      # global Claude config
├── tags.yml             # per-user tag registry: resource -> [tags] (ADR-0010; Domain A, never Domain B)
└── backups/             # vault migration archives
```
> **⚠️ Nature/placement updated by ADR-0011 (2026-06-17).** Tags are **CLI-canonical → internal**
> (not hand-edited config); ADR-0010's provisional "config in `~/.cco`" framing below is **superseded
> for nature**. The **physical placement** (dedicated 4th "internal-but-synced" bucket vs co-locate in
> `~/.cco`) and the **`.gitignore` allowlist / sync transport** are **deferred to the Cat-4 synthesis**
> (after R1–R4); the tree/allowlist lines above are therefore **provisional**. Full §2 rewrite lands at
> **M**. Semantics (per-user, never-team, cross-PC) are unchanged.
>
> **Resource organization → tags, not profiles (semantics RESOLVED — ADR-0010).** Legacy vault
> profiles (git branches) are **removed entirely** (ADR-0006); a **net-new `tags`** system
> replaces them — **no overlap, no dual-axis machinery**. Tags are **multi-valued per
> resource** and transversal (the correct semantics vs a profile's single membership); the
> store stays **flat** (no per-profile subdirs — subdirs break the repo-wide flat-by-name
> assumptions + manifest scan, force single membership, and don't even solve filename
> collisions since resource files mount flat into the container). Tags are **per-user**: they
> live in a per-user registry **`~/.cco/tags.yml`** (`resource → [tags]`, packs **and**
> projects), synced across the *user's* machines (Domain A, `cco config push/pull`) but
> **never shared with third parties** (Domain B) — so they are **not** in `pack.yml`/
> `project.yml`/manifest/index. `cco list [--tag <t>]` reads the registry. **Authoring** is
> **direct `~/.cco` edit** (IDE or the rehomed `config-editor` agent); cco only scaffolds
> (`cco pack create`, `cco template create`). Migration: `cco migrate` **prompts** whether to
> convert legacy profiles into tags (seed origin profile as a tag) or start untagged.

### 2.4 `project.yml` (machine-agnostic, symmetric)
```yaml
name: projectA
# NOTE: no `tags:` here — tags are per-user and live in ~/.cco/tags.yml (ADR-0010),
# never in the committed/published project.yml (would leak to third parties on publish).
repos:                   # ALL members by logical name; no paths; identical in every repo
  - repo1
  - repo2
  - repo3
extra_mounts:            # auxiliary mounts by logical name; default readonly
  - name: shared-assets
    readonly: true
entry: repo1             # OPTIONAL tie-breaker for `cco start projectA` (name-based); not a privilege
packs: [...]             # references only; packs live in ~/.cco, not in the repo
```
The host repo is **not** written in the file — it is the invoking repo at runtime
(AD6). Absolute paths for every `repos[]`/`extra_mounts[]` name come from the
machine-local index (§3).

---

## 3. Machine-Agnostic Config & the Local Path Index

The single source of machine-specific truth is the **index** (`<state>/cco/index`),
never committed, never synced:
```yaml
version: 1
paths:                       # logical name -> absolute path (repos AND extra mounts)
  repo1:          /Users/me/dev/repo1
  repo2:          /Users/me/dev/repo2
  shared-assets:  /Users/me/assets
projects:                    # subsumes the old registry — paths/repos only, NO tags
  projectA: { repos: [repo1, repo2, repo3] }
```
> Tags are **not** in the index (ADR-0010): the index is machine-local STATE (paths/repos
> only, ADR-0002/0007). Per-user tags live in `~/.cco/tags.yml` (Domain A synced).
- **Uniqueness invariant (AD5)**: a logical name maps to exactly one absolute path
  per machine. `cco init`/`cco join` refuse a name already bound to a different path.
- **Absolute paths only**; CLI commands accept paths relative to the cwd and resolve
  to absolute before storing.
- **Maintenance CLI**: `cco resolve [project]` (interactive resolve/repair),
  `cco path set <name> <path>` / `cco path list` (move dirs, fix divergence,
  external installs). Manual edit allowed but discouraged.
- **Bootstrap / fresh machine**: `cco index refresh --scan <dir>` rebuilds the index
  by scanning for `.cco/project.yml`; first `cco start` resolves any missing name via
  prompt/clone. So a fresh clone is not stranded by an empty index (closes the old
  registry-bootstrap gap).
- **`@local`** resolution logic is reused; it now reads the index instead of a
  per-repo `local-paths.yml`. Because no real path is ever written into `project.yml`,
  there is nothing to sanitize and `git diff` is always truthful (AD3/G8).

---

## 4. Sync = Copy

### 4.1 Model
`cco sync` copies a **source** repo's committed `.cco/` set into **target** repos on
the same machine (filesystem copy). Synced set: `project.yml` + `claude/**`
(+ `secrets.env.example`). Never: `secrets.env`, repo-root `.claude/`, system dirs.

No merge engine, no `sync-base`, no commit-time, no peer/root modes, no
confirm/last-commit-wins policies. Divergence is allowed and visible; the user picks
the source. (This is the deliberate replacement for the old vault's opaque
merge/diff failures — the review's C1/C2/C3 and H1/H3/H4/H5/H6 dissolve because there
is no reconciliation algorithm, only a copy.)

### 4.2 Command surface (positional = target, `--from` = source; default source = cwd)
| Command | Source | Targets |
|---------|--------|---------|
| `cco sync` | current repo | all repos in `project.yml` |
| `cco sync <repo>` | current repo | only `<repo>` |
| `cco sync --from <repo>` | `<repo>` | all repos |
| `cco sync <repoA> --from <repoB>` | `<repoB>` | only `<repoA>` |

Flags: `--dry-run` (preview), `--auto-approve` (skip the confirm), `--check`
(exit-code only, for the user's own CI/hooks).

### 4.3 Behavior
1. Resolve source and targets (names → paths via the index).
2. Compute a **truthful diff** (plain diff; machine-agnostic content) source↔each target.
3. If no differences → no-op (exit 0).
4. Otherwise show the diff and **ask for confirmation** (unless `--auto-approve`).
5. On confirm, copy the source set into each target. A target without `.cco/`
   (code-only member, Case A) simply receives a copy.
6. Targets that are non-git or on any branch are irrelevant — sync is a filesystem
   copy, not a git operation. The user commits each repo with their normal git flow
   (`git log -- .cco/` isolates config history). `cco sync` prints a reminder of
   which repos changed.

```mermaid
sequenceDiagram
  participant Dev
  participant Src as source repo (.cco)
  participant Tgt as target repos
  Dev->>Src: edit .cco in the IDE
  Dev->>Tgt: cco sync   (source = cwd)
  Tgt-->>Dev: truthful diff + confirm (unless --auto-approve)
  Dev->>Tgt: confirm -> filesystem copy
  Dev->>Tgt: git commit/push each changed repo (normal git)
```

### 4.4 `cco start` source selection & divergence
- **From a repo dir**: use the invoking repo's `.cco/` (AD6). Unambiguous.
- **By name `cco start <project>`**: if repos are aligned, any copy works; if they
  diverge and there is no clear source, use the optional `entry` repo, else prompt.
- **Divergence is never silently reconciled**: if a project's repos have divergent
  `.cco/`, `cco start` uses the chosen source and **prints a non-blocking notice**
  ("project repos have divergent .cco; started from <repo>; run `cco sync` to
  converge"). This realizes the user policy: sync-off → use cwd; sync-on → user runs
  `cco sync` to converge from a chosen source. This notice is one facet of the unified
  non-blocking reminder aggregator (ADR-0008): the same command surface also flags
  uncommitted changes in `~/.cco` and in the involved `<repo>/.cco/`.

**Ordered `cco start` sequence (H1 — resolution before notices).** The divergence notice
and the reminder aggregator both read the members' `.cco/`, which requires the members to
be resolved first; on a fresh machine the index is empty, so notices/reminders cannot be
computed before resolution. The defined order is therefore:
1. resolve the **source** (cwd repo's `.cco/`, AD6; or by-name via the index);
2. resolve the project **members** via the index (a missing `cco start <project>` name
   triggers/suggests `cco index refresh --scan`, §3);
3. for any **unresolved** member/mount → resolve or clone (journey JF);
4. **only now** compute divergence + the uncommitted/divergence reminders;
5. start the session.

> **Global invariant (H1):** any cross-repo divergence check or reminder is computed
> **after** member resolution — never against an unresolved/empty index. This invariant
> is shared by `cco start`, `cco sync`, and the reminder aggregator.

### 4.5 Cases (see requirements §5.3)
- **A** code-only members (no `.cco/`), single config in the host repo.
- **B** synced copies kept identical via `cco sync`.
- **C** intentional divergence (sync off); `cco sync` converges to B anytime.

### 4.6 Sync-state tracking (internal, per-machine)
cco keeps lightweight **per-machine** sync metadata in the system state dir (§2.2, never
committed). This is **not** a merge `sync-base` (no 3-way merge) — just bookkeeping that
records, per project:
- **which member repos carry a synced copy** (vs code-only) and which are currently
  **divergent** from each other;
- a **last-synced fingerprint** per repo (e.g. a content hash of the synced set at the
  last `cco sync`), so cco can tell a repo edited **locally by the dev since the last
  sync** apart from one that merely **received** a sync.

This tracking drives:
- **`cco sync` / `cco join` target selection** — knowing which repos are in sync (update
  all — Case B) vs divergent (prompt — Case C);
- **divergence flagging before `cco start`** — a non-blocking "repos diverged since last
  sync" notice (§4.4);
- optional **fast rollback** of the last sync.

Exact format and the rollback-snapshot richness are implementation details (this was
previously a separate open question, now folded into scope as FR-Y-S6 — requirements §8).

---

## 5. `@local` Path Resolution (reused, index-backed)

Retained from `../vault/local-path-resolution-design.md`; now resolves against the
machine-local index (§3) rather than a per-repo file. `project.yml` carries only
logical names; the index provides absolute paths; bootstrap on a fresh machine via
`cco index refresh --scan` + on-demand prompt/clone at `cco start`.

---

## 6. Two Sync Domains

### 6.1 Domain A — personal multi-PC
- Per-repo `.cco/` rides each repo's **own git remote** (AD8): clone/pull brings it;
  concurrent cross-PC edits are ordinary git conflicts resolved in the IDE.
- `~/.cco` global resources sync via the **personal git store**. Versioning model =
  **ADR-0008** (unified across `~/.cco` and `<repo>/.cco`): **explicit, manual,
  semantic commits — no auto-commit in v1**. `~/.cco` content (packs, templates,
  global `.claude`) is hand-authored (IDE / `config-editor` agent; cco only scaffolds
  via `cco pack create`); committed via git or a thin `cco config save [-m]`
  (allowlist staging + secret scan); remote sync **explicit** (`cco config push/pull`),
  never per-command; pull non-FF → abort + notify. `<repo>/.cco/` is committed with the
  user's normal git flow (rides the repo remote). **Allowlist = double barrier**
  (whitelist `.gitignore` `*`→`!packs/ !templates/ !global/.claude/ !tags.yml` +
  explicit-path staging, never `git add -A`); 2-pass secret scan + `.example` exemption.
- **Non-blocking reminders** (ADR-0008): the old clean-tree gate is now advisory (no
  branch switch to protect, ADR-0006). Config-sensitive commands warn (never block;
  user may proceed) about (a) uncommitted `~/.cco`, (b) uncommitted `<repo>/.cco` of
  involved repos, (c) cross-repo divergence within a project (see §4.4 / §4.6).
- Sync **transports commits, never fabricates them** — so a future background auto-sync
  (RD-triggers) and semantic snapshots do not conflict.

### 6.2 Domain B — team/external (unchanged)
Publish/install/update/export over Config Repos (`cmd-project-publish.sh`,
`cmd-project-install.sh`, `cmd-pack.sh`, `cmd-remote.sh`, `remote.sh`) — unchanged.

---

## 7. Command Surface

| Area | Command | Status |
|------|---------|--------|
| Entry: clean | `cco init` (scaffold a clean `<repo>/.cco/` in the current repo) | NEW/transform |
| Entry: join | `cco join <project>` (add the current repo to `<project>` as a **member**: register it in the index + add it to `repos[]` in the project's `project.yml`). The new member's `repos[]` edit propagates to **every repo that carries a synced copy** (Case B); in a divergent project (Case C) join **prompts** which repo's `project.yml` to update, or all. The joining repo gets **no `.cco/`** (code-only member) **unless** `--sync` / interactive confirm, which copies the project's `.cco/` into it (source prompted if divergent) — **alternative to `cco init`** | NEW |
| Entry: migrate | `cco migrate <project>` (current repo, from the legacy vault backup: write `.cco/` with the migrated project config) — **alternative to `cco init`** | NEW |
| Run | `cco start [project]` (cwd-aware source; index-resolve `@local`; resolve unresolved repos/mounts) | transform |
| Sync | `cco sync [target] [--from <src>] [--dry-run\|--auto-approve\|--check]` | NEW |
| Paths/resolve | `cco resolve [project]` (resolve unresolved repos/mounts: pick a local path **or** clone from remote to a chosen destination), `cco path set/list`, `cco index refresh --scan` | NEW |
| Discovery | `cco list [--tag <t>]`, tag set/edit (reads/writes the per-user `~/.cco/tags.yml`, ADR-0010) | transform |
| Authoring | Direct `~/.cco` edit (IDE or rehomed `config-editor` agent); cco only **scaffolds**: `cco pack create`, `cco template create` (ADR-0008/0010) | transform |
| Global store | `cco config …` (manage `~/.cco`; versioning model = ADR-0008) | NEW |
| Sharing | `cco pack/project publish\|install\|update\|export`, `cco remote …` | unchanged |
| Update | `cco update …` (framework→user; merge engine unchanged) | unchanged |

**`cco init` / `cco join` / `cco migrate` are mutually exclusive** entry points for a
repo: `init` = clean config; `join` = become a **member** of a project already defined
in another repo; `migrate` = bring a legacy vault project's config into this repo.
Because the new member is added to `project.yml` (a synced file), the edit must reach
every repo holding a copy: in **Case B** (repos in sync) join updates `project.yml` in
**all synced repos**; in **Case C** (divergent, no sync) join **prompts** which repo's
`project.yml` to update, or all (membership only, no content sync). The joining repo
gets a `.cco/` copy only with `--sync` (source prompted if divergent). cco knows which
repos are synced vs divergent from its internal sync-state tracking (§4.6).
**Removed (breaking, no alias)**: the entire `cco vault *` surface
(save/diff/switch/move/profile) and `cco project create`. **First run** with no
`~/.cco`/system dirs bootstraps global resources first (journey J0); with a legacy
vault present it backs the vault up and prints migration instructions (FR-M1).
Discovery is **cwd-first**: if the cwd (or an ancestor) has `.cco/project.yml`, use
it; else resolve `<project>` via the index.

---

## 8. Key User Journeys

Entry points per repo are mutually exclusive: **init** (clean) | **join** (existing
project) | **migrate** (from legacy backup). `cco start` runs once configured.

```mermaid
flowchart TD
  subgraph J0["First run on a machine (D)"]
    z1["any cco command"] --> z2{"~/.cco + system dirs exist?"}
    z2 -->|no| z3["bootstrap global resources (~/.cco, system dirs)"]
    z2 -->|yes| z4["proceed"]
    z3 --> z4
  end
  subgraph JB["New project (B)"]
    b1["cco init in repo1"] --> b2["edit .cco; add repo2/3 to project.yml repos[]"]
    b2 --> b3["optional: cco sync (-> Case B)"] --> b4["cco start"]
  end
  subgraph JE["Join an existing project (E) — alternative to init"]
    e1["enter repo3 (new member)"] --> e2["cco join projectA"]
    e2 --> e3["register repo3 + add it to project.yml repos[] (in the holder repo)"]
    e3 --> e4{"--sync / confirm?"}
    e4 -->|yes| e5["repo3 gets a .cco copy (-> Case B)"]
    e4 -->|no| e6["repo3 stays code-only member (Case A)"]
  end
  subgraph JC["Clone a shared repo that already has .cco (C)"]
    c1["git clone repo"] --> c2["cco start  (no init; .cco already present)"]
  end
  subgraph JA["Migrate a legacy project (A) — lazy, per-project"]
    a1["first run: cco backs up the legacy vault + instructions"] --> a2["enter cloned repo"]
    a2 --> a3["cco migrate projectA  (from backup -> Case A)"]
    a3 --> a4["optional cco sync / cco init others -> Case B or C"]
  end
  subgraph JF["Resolve unresolved repos/mounts (F)"]
    f1["cco start with an unresolved repo/mount"] --> f2{"resolve"}
    f2 -->|local| f3["point to an existing local path"]
    f2 -->|remote| f4["clone from remote to a chosen destination"]
  end
```

---

## 9. Teardown & Migration (phased)

**Breaking cutover** (AD12): no dual-read, no deprecation window. Development happens on
`feat/*` → `develop`; only a working version is merged to `main` for release. Each
phase leaves cco runnable + tests green.

- **Phase 0 — machine-agnostic layout + index + path helpers.** New committed `.cco/`
  (logical names only, **new layout only — no dual-read**), system-dir state/cache,
  machine-local index. `/workspace/.claude` mount vs pack injection resolved
  (RD-claude-mount / ADR-0005): nested-overlay composition is source-agnostic — no
  shadowing. Action items it surfaced: (F1) generate `packs.md`/`workspace.yml` into the
  machine-local cache and overlay them `:ro` instead of writing into committed
  `.cco/claude/`; (F2) treat `packs/`/`llms/` as reserved + warn on cross-tree name
  collisions; (F3) keep the parent mount rw, overlays `:ro`.
  **Additional Phase-0 action items** (from the 16-06 coherence review):
  - **Absolute mounts (BL3)**: convert every *framework* compose mount source from the
    current relative `./…` (anchored to one `project_dir`, `cmd-start.sh:454-495`) to a
    **host-absolute path**, and pick the compose base dir (STATE), since config/state/cache
    now live under three different roots and `--project-directory` can anchor only one.
  - **Host-side resolver guard (H4)**: the XDG resolver (in `lib/paths.sh`) must refuse to
    compute bases inside the container (`$HOME=/home/claude` / `/.dockerenv`); see ADR-0007
    Robustness rules.
  - **Symlink-safe tool root (L5)**: while rewriting `lib/paths.sh`, fix `bin/cco`
    self-location to resolve through symlinks (`BASH_SOURCE` + `readlink` loop) so a
    PATH-symlinked `cco` resolves the real install dir.
- **Phase 1 — sync-as-copy + resolve.** `lib/cmd-sync.sh` (the 4 command forms,
  diff+confirm, copy; no merge engine, no sync-base). `cco resolve`/`cco path`/`cco
  index` (incl. clone-from-remote resolution). Also the **non-blocking reminder
  aggregator** observable from here (ADR-0008): reminders (a) uncommitted `~/.cco` and
  (b) uncommitted involved `<repo>/.cco`, plus (c) cross-repo divergence (with the
  sync-state tracking, §4.6). All reminders fire **after** member resolution (H1
  invariant, §4.4). `cco config save/push/pull` + allowlist staging land in Phase 3.
- **Phase 2 — migration + first-run bootstrap.** First-run global bootstrap
  (`~/.cco` + system dirs when missing — journey J0); first-run **legacy-vault backup**
  + instructions; `cco migrate <project>` (lazy, per-project, from the backup);
  `cco init`/`cco join`. A minimal legacy-vault reader exists **only** inside
  `cco migrate`. **Memory relocation (ADR-0009)**: `cco migrate` copies the project's
  `memory/` from the backup into `<state>/cco/projects/<id>/memory/` (one-time file copy,
  machine-local, no versioning) so accumulated auto-memory is not lost in the cutover.
  **Profile→tag prompt (ADR-0010)**: migration **asks the user (CLI)** whether to convert
  legacy profiles into tags (seed each resource's origin profile as a tag value in
  `~/.cco/tags.yml`) or start untagged — lossless either way.
- **Phase 3 — remove the legacy vault entirely (breaking).** Delete the
  profile/switch/shadow machinery, `cco vault *`, `cco project create`, and the
  custom `project.yml` sanitize/virtual-diff/extract-restore/backup-trap (unnecessary
  under AD3). Keep `@local` (index-backed), secret-scan, gitignore-heal. **Profiles → tags
  (ADR-0010)**: remove the profile-branch system entirely; add the per-user tag registry
  `~/.cco/tags.yml` + `cco list --tag` (allowlist gains `!tags.yml`). **Authoring (ADR-0010)**:
  rehome the `config-editor` template to mount `~/.cco` (was `user-config/`) and update its
  `setup-pack`/`setup-project` skills (write into `~/.cco/packs|templates/`) and `config-safety`
  rule (`cco vault save` → `cco config save`). `cco config` (`~/.cco`; versioning model per
  ADR-0008) + allowlist staging + whitelist `.gitignore` + `.example` exemption. Also re-home the `cco update` merge
  engine artifacts (`.cco/base/`, `.cco/meta`) out of the committed `.cco/` into STATE
  (H6 — "unchanged" is true for the merge logic, not its paths).
  **Auto-memory (ADR-0009)**: drop the vault's memory auto-commit
  (`_auto_resolve_framework_changes`, D33) and `.gitkeep` tracking (D32) along with the
  vault; `memory/` is now machine-local STATE (§2.2). Update the managed rule
  `defaults/managed/.claude/rules/memory-policy.md` and `docs/reference/context-hierarchy.md`
  to drop *"vault-synced"* / the `user-config/projects/<n>/memory/` location → *"machine-local
  STATE; cross-PC sync = future opt-in (R-state-sync)"*.
  > **GATE (BL2) — SATISFIED (2026-06-16, ADR-0009).** Phase 3 was gated on **RD-memory**
  > assigning `memory/` a home; ADR-0009 resolves it: auto-memory is **machine-local STATE**
  > (`<state>/cco/projects/<id>/memory/`), preserved across the cutover by `cco migrate`
  > (Phase 2). The vault's auto-commit (D33) is the only cross-PC sync today; v1 **drops** it
  > intentionally (the accepted regression, ADR-0009 Consequences) and reframes cross-PC /
  > cross-team *state* sync as a deferred opt-in feature (R-state-sync, §12). Phase 3 may now
  > proceed.

**Migration flow** (lazy, per-project, idempotent, backed-up):
1. **First run** detects a legacy vault → archive it to
   `~/.cco/backups/vault-<date>.tar.gz`, inform the user, print instructions, offer to
   remove the old vault. No project migrated automatically. **Ordering invariant (M8):**
   `~/.cco` is bootstrapped *before* the backup is written; the backup is **verified**
   (archive integrity) before the offer-to-remove; the legacy vault is removed **only**
   after a verified backup. A second first-run must not re-archive (a "backed-up" marker
   in STATE meta guards idempotency).
2. Per project: in an already-cloned repo, `cco migrate <project>` reads that
   project's config from the backup → writes a machine-agnostic `.cco/` in the repo →
   registers it in the index. The repo lands in **Case A**. `cco migrate` **verifies the
   backup exists and is readable before reading** (M8) — Phase 3 deletes the only
   surviving legacy reader, so a migrate against a missing/corrupt backup must fail
   loudly, never silently.

> **Migration constraint — multi-profile + uncommitted (note for the detailed migration
> design/impl).** In the legacy vault, **profiles are git branches** and a single checkout
> exposes only the active profile's resources. Profile branches **do not survive** into
> decentralized cco, so the branch-awareness lives entirely in the **save/backup step**,
> which must **flatten** the profiles into a plain, branchless backup layout; the migrate
> reader then does an ordinary plain retrieve.
> - The backup step **iterates all profile branches** and serializes their resources into
>   a **plain backup** (no git branches in the archive). The flatten **translates each
>   profile into a tag** on its resources (profiles → tags, the new model), so nothing is
>   lost and the origin profile is preserved as metadata.
> - **Uncommitted working-tree changes** belong only to the *active* profile; the backup
>   must capture them (include the dirty working tree as-is, and/or warn the user to
>   commit first) so no WIP is dropped. Other (non-checked-out) profiles contribute only
>   their committed state by construction.
> - `cco migrate <project>` reads the project's config from the **plain** backup with a
>   normal retrieve — **no branch traversal** (the flatten already happened at save time).
3. The user opts into Case B (`cco sync`) or Case C (`cco init` other repos), or stays
   in A. Re-runs never overwrite an existing `.cco/` without confirm. Rollback: `.cco/`
   is in the repo's git; the backup archive preserves full vault history.
A `cco migrate --all` is **optional and discouraged** (no A/B/C control; would default
to B) — evaluate before adding.

---

## 10. Packaging-Awareness (AD11)

Decentralization separates **tool** (`bin/cco`, `lib/`, `defaults/`, `templates/`,
`proxy/`, Dockerfile) from **user data** (`~/.cco`, per-repo `.cco`, system dirs). No
design choice may put tool code inside a `.cco/` or require a source clone to run;
any future hooks invoke `cco` by PATH. This keeps a future npm/npx + image package
(R-pkg) a drop-in.

---

## 11. Test Plan

| Phase | New | Rewrite | Remove |
|-------|-----|---------|--------|
| 0 | machine-agnostic layout + index tests (new layout only, no dual-read); **XDG resolver matrix** (unset/empty/relative + `CCO_*_HOME` override, `0700`, host-side/anti-in-container guard); **absolute-mount generation** in compose; **F2 cross-tree collision warning** (committed `rules/foo.md` vs pack `rules/foo.md`, pack `:ro` wins); symlink-safe tool root | `test_local_paths.sh` | — |
| 1 | `test_sync.sh` (copy semantics, 4 forms, confirm); resolve incl. clone-from-remote; **reminder aggregator** (a/b/c) + **H1 ordering** (resolve before notices) | — | — |
| 2 | `test_migrate.sh` (lazy per-project from backup; backup-verified-before-read, M8; **memory relocation backup→`<state>/cco/projects/<id>/memory/`**, ADR-0009; **profile→tag prompt** both branches — convert vs untagged, ADR-0010); first-run bootstrap (per-root idempotent) | — | — |
| 3 | multi-project coexistence; truthful-diff (no sanitize) tests; `test_config.sh` (Domain A: allowlist staging never `git add -A`, **secret-scan `.example` exemption** — skeleton passes, real `secrets.env` blocked); merge-engine path remap (`.cco/base`/`meta` in STATE); **memory-as-STATE** (ADR-0009: `memory/` in STATE persists across starts, no auto-commit, no `.gitkeep`); **per-user tags** (ADR-0010: `~/.cco/tags.yml` registry, `cco list --tag` filter, tags NOT in `pack.yml`/`project.yml`/manifest/index, allowlist `!tags.yml`) | `test_vault.sh` (shrink to migrate-reader) | `test_vault_profiles.sh`; custom-diff/sanitize tests; **D33 memory auto-commit / D32 `.gitkeep` tests** |

Net: a narrower surface — no custom diff/save/merge sync code to test, no dual-read; the
`cco update` merge engine **logic** tests are untouched (only its paths are remapped, H6).

---

## 12. Future Evolutions (out of scope)

- **Auto-sync triggers (RD-triggers)** — opt-in background daemon and/or native hooks
  in select cco commands vs opt-in git hooks. Manual `cco sync` is the v1 model.
- **`~/.cco` background auto-sync (RD-triggers)** — managed pull/commit/push. The
  *versioning model* (explicit manual commits + allowlist) is resolved by ADR-0008; only
  the optional background/managed auto-sync is future work, owned by RD-triggers.
- **State sync (R-state-sync)** — opt-in cross-PC / cross-team sync of *state*
  (auto-memory **and** session transcripts), the capability the vault provided for memory
  and that v1 drops (ADR-0009). Two scenarios to design separately: (a) one user's multiple
  machines; (b) team members on a shared project. Kept out of the CONFIG sync (ADR-0008) so
  state and config responsibilities stay separate; a single transport can serve both memory
  and transcripts since both are STATE.
- **`cco update` native (R-update-native)** — cco fully agnostic; opinionated
  packs/templates via native publish/install; keep a `cco update` for installed packs.
- **cco packaging (R-pkg)** — npm/npx + image registry.
- **Persistent `/workspace` root (R-workspace).**

---

## 13. Open Questions (dedicated follow-up analyses)

These are deliberately **not** decided here; each gets its own analysis after this
design is persisted.

| # | Question |
|---|----------|
| **RD-triggers** | Future opt-in auto-sync (daemon / native hooks / git hooks / manual-only). Now also owns `~/.cco` background/managed auto-sync (ADR-0008). |

**Resolved:**
| # | Resolution |
|---|----------|
| **RD-claude-mount** | ✅ 2026-06-16 (ADR-0005). Nested-overlay composition is source-agnostic → no bind-mount shadowing. Surfaced F1 (generate `packs.md`/`workspace.yml` into cache + `:ro` overlay, not into committed `.cco/claude/`), F2 (reserve `packs/`/`llms/`, warn on cross-tree collisions), F3 (parent rw, overlays `:ro`). |
| **RD-paths** | ✅ 2026-06-16 (ADR-0007). XDG on both OSes: STATE `$CCO_STATE_HOME`→`$XDG_STATE_HOME/cco`→`~/.local/state/cco`, CACHE `$CCO_CACHE_HOME`→`$XDG_CACHE_HOME/cco`→`~/.cache/cco`; index in STATE; CONFIG keeps `~/.cco` dotdir; host-side resolution, `0700`, XDG-validation. |
| **RD-home** | ✅ 2026-06-16 (ADR-0008). Unified **explicit manual commit** model for `~/.cco` + `<repo>/.cco` (semantic user-named snapshots; **no auto-commit** in v1 — deferred for atomic config-mutating commands). Non-blocking **reminders** (old clean-tree gate, now advisory) flag uncommitted `~/.cco`, uncommitted involved `<repo>/.cco`, cross-repo divergence. Allowlist double-barrier (whitelist `.gitignore` + explicit staging, never `git add -A`); 2-pass secret scan + `.example` exemption; explicit `cco config push/pull` (sync transports commits, never fabricates them); auto-sync → RD-triggers. |
| **RD-memory** | ✅ 2026-06-16 (ADR-0009). Auto-memory is **machine-local STATE** (`<state>/cco/projects/<id>/memory/`), co-located with transcripts — not config, never in `~/.cco`/`<repo>/.cco`. **No versioning/sync in v1**: the vault auto-commit (D33) + `.gitkeep` (D32) machinery is dropped; `cco migrate` relocates memory from the backup (lossless). Team-shared project knowledge stays in committed docs/rules (not memory). **Satisfies the Phase-3 gate (BL2).** Cross-PC/cross-team *state* sync (memory + transcripts) deferred → R-state-sync (§12). |
| **RD-authoring** | ✅ 2026-06-16 (ADR-0010). Authoring = **direct `~/.cco` edit** (IDE / rehomed `config-editor` agent); cco only scaffolds (`pack/template create`); no author-in-repo+promote in v1. Organization = **tags, not profiles** (clean removal + net-new system, multi-valued, flat store — no subdirs). Tags are **per-user** in `~/.cco/tags.yml` (Domain A synced, **never** Domain B); **not** in `pack.yml`/`project.yml`/manifest/index (project tags moved out of `project.yml` §2.4 + index §3). `cco list --tag` reads the registry. Migration **prompts** profile→tag conversion. |
