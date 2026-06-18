# Decentralized In-Repo Config — Requirements

**Status**: Approved for implementation (model finalized 2026-06-15). This is the
authoritative requirements document; the detailed design is in `design.md` and the
decision records (ADRs 0001–0010) in `decisions/`.
**Date**: 2026-06-15
**Supersedes**: the central git-backed vault (`user-config/` projects + branch
profiles) and `../vault/profile-isolation-design.md`. Reuses the `@local` path
contract from `../vault/local-path-resolution-design.md`.
**Decision history (historical, do not edit)**:
`reviews/15-06-2026-sync-adversarial-review.md` (adversarial review refuting the custom
sync/merge engine) and `reviews/15-06-2026-simplification-analysis.md` (diff
archaeology + plain-git feasibility that drove the sync-as-copy model).

---

## 1. Context & Motivation

The central vault stored all projects under `user-config/projects/<name>/` and used
git **branches as profiles**: switching profile did a `git checkout` that swapped
which projects existed on disk. This coupled two orthogonal concerns — *config
storage* and *workspace selection* — and produced a recurring structural bug class
(#B13–#B23), opaque failures, and a hard limit: only one profile's projects on disk
at a time (no concurrent cross-profile sessions).

A second, subtler source of complexity: committed config was **not** machine-neutral.
Real filesystem paths in `project.yml` were rewritten to `@local` markers on save
and back to real paths on read. Because the same committed file differed from its
on-disk form, a plain `git diff` "lied", so the vault carried a **custom diff/save**
layer (sanitize-on-save, virtual-diff, extract/restore, backup + ERR-trap) purely to
hide that discrepancy. Much of the vault's fragility lived here, not only in the
branch switch.

**Insight**: *selection* (which projects are visible) and *storage* (where config
lives) are orthogonal; and if committed config is made **100% machine-agnostic**,
plain `git` becomes a truthful, sufficient transport and the entire custom
diff/save/merge layer is unnecessary. Decentralizing storage into each repo and
removing all machine-specific data from committed files eliminates both fragility
sources at the root and aligns config with the developer's IDE workflow.

```mermaid
flowchart LR
  subgraph OLD["Before — central vault + branch switch + @local sanitize"]
    V[(user-config vault)] -->|checkout profile| FS[disk: only that profile]
    V -.->|sanitize/virtual-diff| CD[custom diff/save layer]
  end
  subgraph NEW["After — decentralized, machine-agnostic in-repo config"]
    R1["repo A/.cco/ (machine-agnostic, git-tracked)"] --> S[cco]
    R2["repo B/.cco/"] --> S
    IDX[("machine-local index: name -> abs path")] --> S
    REG[("~/.cco store + system cache/state dirs")] --> S
    S --> SESS["docker session"]
  end
```

---

## 2. Goals / Non-Goals

**Goals**
- G1 — Each project's cco config lives in its own repo, versioned with the code.
- G2 — Any project is startable any time, concurrently, on the same machine.
- G3 — IDE-first: configure and run from a repo you already have open.
- G4 — Net **reduction** in framework machinery: delete the vault, the
  profile/switch layer, **and** the custom config diff/save/merge layer.
- G5 — Multi-repo agentic sessions preserved (e.g. `repo1` + `repo2` + `repo3` of one
  project in a single session).
- G6 — Per-project git history for config (config commits ride with code commits).
- G7 — Structural secret-leak safety.
- G8 — **Truthful diff**: a plain `git diff` on `.cco/` always reflects real config
  changes; cco never maintains a diff view that diverges from git's.

**Non-Goals**
- N1 — A custom 3-way merge / sync-base / commit-time reconciliation engine for
  config sync. (Sync is a plain **copy** from a chosen source — see §5. A background
  daemon or git hooks are possible **future opt-in** evolutions, not in scope.)
- N2 — The monolithic vault (projects + profiles + filesystem switch + custom diff).
- N3 — Cross-team config governance beyond the existing Config Repo sharing.
- N4 — Packaging cco as an installable npm/npx artifact + image registry — a valuable
  **separate future workstream**, not part of this refactor (§9).
- N5 — Reworking the `cco update` engine. The 3-way merge engine stays **as-is** for
  framework→user template/pack updates; it is unrelated to config sync. A future
  evolution (cco fully agnostic + opinionated packs/templates distributed via native
  publish/install) is recorded in the roadmap, out of scope here (§9).

---

## 3. Agreed Architectural Decisions

| # | Decision |
|---|----------|
| **AD1** | Config is **decentralized**: `<repo>/.cco/` holds a project's committed cco config, versioned with the code. The central vault is retired. |
| **AD2** | **Profiles → tags (ADR-0010).** No git-branch profiles, no `vault switch` — the profile system is removed and replaced by a net-new, **multi-valued, per-user** tag system (no overlap). Tags live in a per-user registry `~/.cco/tags.yml` (`resource → [tags]`, packs **and** projects), synced across the *user's* machines (Domain A) but **never** shared with third parties (Domain B) — so never in `pack.yml`/`project.yml`/manifest/index. `cco list [--tag]` filters; the IDE is the project browser. |
| **AD3** | **Machine-agnostic committed config (G8).** Committed files contain **no machine-specific data** — no real paths. `project.yml` references repos and extra mounts by **logical name** only and is **byte-identical across a project's repos**. Real absolute paths live in a machine-local index outside the repo (AD5). A plain `git diff` is therefore always truthful; the custom diff/save/sanitize/virtual-diff layer is removed. |
| **AD4** | **Dual `.claude` scope** (verified: `/workspace/.claude` IS loaded at WORKDIR `/workspace`, plus nested `<repo>/.claude` on-demand). **Project/cross-repo** Claude config lives at `<repo>/.cco/claude/` → mounted `/workspace/.claude`. **Repo-local** Claude config stays at `<repo>/.claude/` → `/workspace/<repo>/.claude`, never part of project config. |
| **AD5** | **`@local` retained, resolved via a machine-local index (AD3).** The index maps `logical-name → absolute path` for repos and extra mounts, is **per-machine, never committed, never synced**, and is maintained by dedicated CLI commands (manual edit allowed but discouraged). It stores **absolute paths only**; CLI commands accept paths relative to the cwd and resolve them to absolute. The index also records `project → [member repo names]` (it subsumes the old registry). |
| **AD6** | **No privileged repo.** Any repo carrying a `.cco/` is a valid project entry point. `cco start` uses the config of the **invoking repo** (cwd) by default, or the one given by flag. The session's source is therefore always unambiguous. An optional per-project *entry* repo is only a tie-breaker for name-based `cco start <project>`. |
| **AD7** | **Sync is a plain copy (N1).** `cco sync` copies a source repo's committed `.cco/` set into target repos. No merge engine, no `sync-base`, no commit-time heuristic, no peer/root modes, no confirm/last-commit-wins policies. Works on the **same machine over the filesystem** (so it does not require repos to be git). Divergence between repos is allowed and visible; the user picks the source. |
| **AD8** | **Git is the only cross-PC transport.** A repo's `.cco/` travels on the repo's own git remote (clone/pull brings it). Concurrent cross-PC edits surface as ordinary git merge conflicts the user resolves in their IDE. No cco-specific cross-PC reconciliation. A non-git repo simply does not travel across machines (sync within a project on one machine still works — AD7). |
| **AD9** | **Config / state / cache are separated by location.** The committed `<repo>/.cco/` holds **only** machine-agnostic user config. Machine/runtime **state** (generated compose, claude-state, auto-memory (ADR-0009), the local-path index, temp) and **cache** (llms, installed resources) live in **system directories outside the repo**, hidden from the user. `secrets.env` is the one exception that stays in the repo (gitignored) because the user edits it by hand. Exact filesystem locations: resolved by ADR-0007 (XDG state/cache). |
| **AD10** | A central **`~/.cco/`** holds the user's **global resources** (authored packs, templates, global `.claude`) as a personal git store, plus references. Two strictly-separated sync domains: **A** personal multi-PC (the user's own `~/.cco` + per-repo git) and **B** team/external sharing (**sharing repos**, publish/install of packs/templates — realigned by ADR-0018/0019/0020; projects ride the code-repo remote, P5/P13). `~/.cco` **versioning model is resolved by ADR-0008** (explicit manual commits + allowlist + reminders); only the optional background/managed auto-sync is deferred (RD-triggers). |
| **AD11** | cco may later be distributed as an installable package (npm/npx) + image registry. **This design stays packaging-aware**: no tool code in any `.cco/`, no requirement to clone the cco source to run; hooks (if any) invoke `cco` by PATH. Detailed packaging design is a separate workstream (§9). |
| **AD12** | **Breaking cutover + lazy per-project migration.** The refactor is a **direct breaking change**: no legacy runtime support, no dual-read, no deprecation window (the user base is tiny and known; migration is lossless). On first run of the new version with a legacy vault present, cco **backs up the vault** to a user-accessible location, tells the user, and offers to remove the old vault. Migration is then **lazy and per-project**: inside an already-cloned repo, `cco migrate <project>` initializes that repo's `.cco/` from the backup (instead of `cco init` clean), leaving the project in Case A; the user then chooses Case A/B/C via `cco sync`/`cco init`. See ADR-0006. |

---

## 4. `.cco/` Structure & Secret Safety (FR-S)

The committed `<repo>/.cco/` contains only machine-agnostic user config. All
machine/runtime state and cache live outside the repo (AD9).

```
<repo>/
├── .claude/                  # COMMITTED, repo root — REPO-LOCAL Claude config
│                             #   → /workspace/<repo>/.claude  (project-independent)
├── .cco/                     # COMMITTED — machine-agnostic project config
│   ├── .gitignore            #   ignores secrets.env (+ secret patterns)
│   ├── project.yml           #   logical names only, NO real paths, identical across repos
│   ├── secrets.env.example   #   committed skeleton (no real values)
│   ├── secrets.env           #   GITIGNORED — real values, user-edited (the one in-repo exception)
│   └── claude/               #   PROJECT/cross-repo Claude config → /workspace/.claude
│       └── CLAUDE.md, rules/, agents/, skills/
└── (no state/, no cache/, no local-paths in the repo — see system dirs below)
```

State/cache/index live in system directories (AD9; exact paths = RD-paths):
```
<state-dir>/cco/projects/<id>/   # generated docker-compose, claude-state, memory (ADR-0009), .tmp, meta
<state-dir>/cco/index            # machine-local name→abs-path + project→repos index (AD5)
<cache-dir>/cco/                 # llms, installed resources
~/.cco/                          # personal git store: packs/, templates/, global/.claude/  (AD10)
```

- **FR-S1** — All committed cco config is under `<repo>/.cco/` (plus the repo-root
  `<repo>/.claude/` repo-local Claude config). No machine state is committed.
- **FR-S2** — Because runtime **state lives outside the repo entirely** (AD9), a
  secret cannot structurally end up in a committed state directory. The only
  in-repo secret file is `secrets.env`, blanket-gitignored.
- **FR-S3** — Defense-in-depth: secret patterns (`secrets.env`, `*.env`, `*.key`,
  `*.pem`, `.credentials.json`) in `.gitignore` **and** a pre-commit/pre-push scan
  reusing `lib/secrets.sh`. The scan MUST exempt `*.example` files from the
  **content** check (a skeleton documents `API_KEY=…` by design) and MUST keep
  `secrets.env.example` stageable while refusing `secrets.env`.
- **FR-S4** — `secrets.env.example` (committed, no values) documents required vars;
  `secrets.env` (gitignored, in-repo) holds real values, copy-if-missing.
- **FR-S5** — Path helpers (`lib/paths.sh`) target the new layout only. **No
  dual-read** of any legacy layout at runtime (breaking cutover, AD12); the only
  reader of the old format is `cco migrate`, which consumes the vault backup.

---

## 5. Machine-Agnostic Config, Local Paths & Sync (FR-Y)

### 5.1 Machine-agnostic config (FR-Y-A)
- **FR-Y-A1** — `project.yml` lists **all** member repos and extra mounts by
  **logical name**; no real paths; no implicit-host rewriting. It is identical in
  every repo of the project, so `git diff` is truthful (G8, AD3).
- **FR-Y-A2** — The machine-local index (AD5) resolves logical names to absolute
  paths at consumption time (`cco start`). It is never committed/synced.
- **FR-Y-A3** — Dedicated CLI maintains the index: resolve on first use, update when
  the user moves directories, when external projects are installed, or on
  divergence. Manual edit of the index file remains an escape hatch (discouraged).
  Commands accept relative paths (resolved to absolute); the file stores absolute.

### 5.2 Sync = copy (FR-Y-S)
Sync keeps a project's committed `.cco/` set identical across its repos by
**copying** from a chosen source. The synced set is `project.yml` + `claude/**`
(+ `secrets.env.example`). **Never**: `secrets.env`, the repo-root `.claude/`, or
anything in system dirs.

Command forms (positional arg = **target**, `--from` = **source**; default source =
current repo):

| Command | Source | Targets |
|---------|--------|---------|
| `cco sync` | current repo | all repos in `project.yml` |
| `cco sync <repo>` | current repo | only `<repo>` |
| `cco sync --from <repo>` | `<repo>` | all repos in `project.yml` |
| `cco sync <repoA> --from <repoB>` | `<repoB>` | only `<repoA>` |

- **FR-Y-S1** — Sync is a filesystem copy (AD7); it does **not** require repos to be
  git and does not use git history/commit-time.
- **FR-Y-S2** — Sync is **optional**. A project may run with no sync and
  deliberately divergent repo configs (Case C below). Divergence is allowed and
  visible; `cco start` always uses an unambiguous source (AD6).
- **FR-Y-S3** — By default sync shows a **truthful diff and asks for confirmation**;
  `--auto-approve` (or equivalent) skips the prompt. `--dry-run` previews without
  writing. *(Snapshot/rollback and user-vs-sync change detection — see FR-Y-S6 / design §4.6.)*
- **FR-Y-S4** — A repo without `.cco/` is a code-only member (Case A): it is a valid
  target of sync (gains a copy) but cannot be a start source.
- **FR-Y-S5 (membership / `cco join`)** — A repo becomes a **member** of a project
  either by listing its name in `project.yml` `repos[]`, or by running
  `cco join <project>` from that repo (registers it in the index and adds it to
  `repos[]`). Since `project.yml` is a synced file, the `repos[]` edit must reach every
  repo that holds a copy: in **Case B** (repos in sync) join updates `project.yml` in
  **all synced repos**; in **Case C** (divergent, no sync) join **prompts** which
  repo's `project.yml` to update, or all (membership only, no content sync). The
  joining repo gets **no `.cco/`** (code-only member) unless `cco join --sync` (or
  interactive confirm), which copies the project's `.cco/` into it (source prompted if
  divergent).
- **FR-Y-S6 (sync-state tracking)** — cco keeps lightweight **per-machine** sync
  metadata (in the system state dir, never committed; not a merge `sync-base`):
  which member repos carry a synced copy vs are divergent, and a **last-synced
  fingerprint** per repo to distinguish a repo edited **locally since the last sync**
  from one that merely **received** a sync. It drives `cco sync`/`cco join` target
  selection (Case B all vs Case C prompt), divergence flagging before `cco start`, and
  optional fast rollback. Exact format / rollback richness = implementation detail.

### 5.3 Supported cases (project: repo1 + repo2 + repo3)
- **Case A — single-config, no copies.** `cco init` only in repo1; sync off. repo2/3
  are members of repo1's `project.yml` (added by hand or via `cco join` from each) and
  mounted as **code only** (no `.cco/`). `cco start` runs from repo1.
- **Case B — synced copies.** From Case A, `cco sync` (or `cco join --sync`) gives
  repo2/3 a copy of `.cco/`. `cco start` uses the invoking repo's `.cco` (or `--from`);
  if copies diverge it is always clear which was used; sync anytime.
- **Case C — intentional divergence.** `cco init` in all three with **different**
  `.cco/`; sync off. Repos diverge by design; `cco start` uses the invoking repo's
  config; running `cco sync` at any time converges to Case B.

```mermaid
flowchart TD
  U["cco sync [target] [--from source]"] --> SRC["pick source (default: cwd)"]
  SRC --> D{diff vs targets}
  D -->|no change| NOOP[no-op]
  D -->|change| C{"confirm? (unless --auto-approve)"}
  C -->|yes| CP["copy source .cco -> targets"]
  C -->|no| ABORT[abort, nothing written]
```

---

## 6. Central Store `~/.cco` & Domains (FR-C) — versioning model = ADR-0008; auto-sync deferred (RD-triggers)

- **FR-C1** — `~/.cco/` holds the user's **global resources**: authored `packs/`,
  `templates/`, and `global/.claude/`. It is a personal git store (Domain A).
- **FR-C2** — The machine-local index (AD5) is the source for `cco list` and tag
  filtering; it lives in a system dir, is per-machine, and is rebuildable by scanning
  known directories (`cco index refresh --scan`) so a fresh machine can repopulate.
- **FR-C3 (Domain A)** — Personal multi-PC: per-repo `.cco/` rides each repo's own
  remote; `~/.cco` global resources sync via the personal store. **Versioning model =
  ADR-0008 (RD-home resolved)**: a single **explicit, manual, semantic-commit** model
  across `~/.cco` and `<repo>/.cco` — **no auto-commit in v1** (`~/.cco` content is
  hand-authored; cco only scaffolds via `cco pack create`). `~/.cco` committed via git
  or `cco config save [-m]`; remote sync explicit (`cco config push/pull`), never
  per-command; pull non-fast-forward → abort + notify (resolve in IDE), no auto-merge.
  Commit via an **explicit allowlist** (`packs/ templates/ global/.claude/`) + a
  committed whitelist `.gitignore`, **never `git add -A`**; a 2-pass secret scan (with
  `.example` exemption) blocks on hit. **Non-blocking reminders** at config-sensitive
  commands flag uncommitted `~/.cco`, uncommitted involved `<repo>/.cco`, and cross-repo
  divergence (the old clean-tree gate is now advisory — no branch switch to protect).
  Sync transports commits, never fabricates them; background/managed auto-sync is
  deferred to **RD-triggers**.
- **FR-C4 (Domain B)** — Team/external sharing **realigned by the S cycle (ADR-0018/0019/0020)**:
  the term "Config Repo" → **sharing repo** (config bucket vs sharing repo); a symmetric **2×2**
  surface (`publish`↔`install` for packs/templates; `export`↔`import` tar for all incl. projects);
  **projects do NOT publish/install** (they ride the code-repo remote, P5/P13); **structure-based**
  sharing-repo discovery (manifest removed); referenced resources (repos/llms/**packs**) travel as
  **coordinates** with layered reachability (P14); pack **working-copy lifecycle** + sync-before-publish
  (P16); **permissions delegated to git** (P17). `cco update --check` lists available updates. Authoring
  of global resources happens **directly in `~/.cco`** (opened in an IDE, or via the rehomed
  `config-editor` agent); cco only scaffolds (`pack/template create`) — ADR-0010.
  Per-user **tags** (`~/.cco/tags.yml`) organize resources locally and sync across the
  user's PCs (Domain A) but are **never** shared via Domain B.

---

## 7. Migration & Constraints

- **FR-M1 (first-run backup)** — On first run of the new version with a legacy vault
  present, cco archives it to a user-accessible location
  (`~/.cco/backups/vault-<date>.tar.gz`), informs the user, prints migration
  instructions, and offers to remove the old vault. No project is migrated
  automatically. **The backup MUST be all-profiles-complete (see design §9 migration
  constraints):** legacy profiles are git branches that do not survive into the new model,
  so the **save/backup step flattens** every profile branch into a **plain, branchless
  backup** (translating each profile into a **tag** on its resources — profiles → tags),
  and must capture **uncommitted working-tree changes** of the active profile so no WIP is
  lost. `cco migrate` then reads the plain backup with a normal retrieve (no branch
  traversal).
- **FR-M2 (lazy per-project migrate)** — `cco migrate <project>` is run **inside an
  already-cloned repo**: instead of `cco init` (clean scaffold), it initializes that
  repo's `.cco/` from the backup's project config (machine-agnostic), registers it in
  the index. The repo lands in **Case A**; the user then opts into Case B (`cco sync`)
  or Case C (`cco init` other repos) or stays in A. Idempotent: never overwrites an
  existing `.cco/` without confirm. A `cco migrate --all` convenience is **optional and
  discouraged** (no per-project A/B/C control; would default to B) — evaluate before
  adding. **Breaking cutover**: no dual-read; the legacy vault is read only from the
  backup, only by `cco migrate`.
- **C1** — bash 3.2 compatibility (macOS default) — no bash-4 constructs.
- **C2** — `.claude/` must remain at the repo root (Claude Code native).
- **C3** — Repos may be plain directories (not git). The model must not assume git
  for core operation; git is required only to enable cross-PC travel/sync (opt-in).
- **C4** — Teardown removes the vault profile/switch/shadow machinery **and** the
  custom config diff/save/sanitize/virtual-diff layer; reused: `@local` resolution,
  secret-scan, gitignore-heal. The 3-way merge engine is **kept** for `cco update`.

---

## 8. Decisions & Open Questions

**Decided (2026-06-15):**
| # | Decision |
|---|----------|
| Machine-agnostic committed config (AD3, G8) | ✅ no real paths in committed files; `git diff` truthful |
| Global machine-local index for paths (AD5) | ✅ absolute paths, CLI-managed, subsumes registry |
| No privileged repo; cwd is the start source (AD6) | ✅ entry repo only a name-based tie-breaker |
| Sync = copy, 4 command forms (AD7, §5.2) | ✅ no merge engine / sync-base / commit-time / peer-root / confirm-LCW policies |
| Git is the only cross-PC transport (AD8) | ✅ conflicts resolved natively in IDE |
| Config/state/cache separated by location (AD9) | ✅ state+cache out of repo; `secrets.env` the in-repo exception |
| Vault removed; `project create` removed | ✅ surface = `cco init` + `cco join` + `cco migrate` + `cco sync` + `cco start` + global-store mgmt + existing publish/install/remote/pack/llms/update |
| Breaking cutover; lazy per-project migration (AD12, ADR-0006) | ✅ no dual-read / no deprecation window; first-run backup + `cco migrate <project>` from backup |
| Sync default = diff + confirm; `--auto-approve` | ✅ |
| Sync-state tracking in scope (FR-Y-S6, design §4.6) | ✅ per-machine metadata: sync-set membership + last-synced fingerprint (not a merge sync-base); exact format/rollback richness = impl |
| Merge engine stays for `cco update` only (N5) | ✅ |
| RD-claude-mount resolved (2026-06-16, ADR-0005) | ✅ single `/workspace/.claude` rw mount + nested `:ro` pack/llms overlays = source-agnostic composition, no shadowing; generated files (`packs.md`/`workspace.yml`) → machine-local cache + `:ro` overlay, never into committed `.cco/claude/`; `packs/`/`llms/` reserved |
| RD-paths resolved (2026-06-16, ADR-0007) | ✅ XDG on both OSes (no `~/Library`): STATE `$CCO_STATE_HOME`→`$XDG_STATE_HOME/cco`→`~/.local/state/cco`; CACHE `$CCO_CACHE_HOME`→`$XDG_CACHE_HOME/cco`→`~/.cache/cco`; index in STATE; CONFIG keeps `~/.cco` dotdir; host-side resolution, XDG-validation, `0700` |
| RD-home resolved (2026-06-16, ADR-0008) | ✅ Unified explicit manual commit model for `~/.cco` + `<repo>/.cco` (semantic snapshots, NO auto-commit in v1); non-blocking reminders (uncommitted `~/.cco`/`<repo>/.cco` + cross-repo divergence); allowlist double-barrier (never `git add -A`); 2-pass secret scan + `.example` exemption; explicit `cco config push/pull` (sync moves commits, never fabricates); auto-sync + atomic-command auto-commit → deferred (RD-triggers / future) |
| RD-memory resolved (2026-06-16, ADR-0009) | ✅ Auto-memory is **machine-local STATE** (`<state>/cco/projects/<id>/memory/`, co-located with transcripts) — not config, never in `~/.cco`/`<repo>/.cco`; NO versioning/sync in v1 (vault auto-commit D33 + `.gitkeep` D32 dropped); `cco migrate` relocates memory from backup (lossless); team-shared knowledge stays in committed docs/rules. **Satisfies the Phase-3 gate (review BL2).** Cross-PC/cross-team state sync (memory + transcripts) deferred → R-state-sync |
| RD-authoring resolved (2026-06-16, ADR-0010) | ✅ Authoring = **direct `~/.cco` edit** (IDE / rehomed `config-editor`); cco only scaffolds; no author-in-repo+promote in v1. Organization = **tags not profiles** (clean removal + net-new, multi-valued, flat store — no subdirs). Tags **per-user** in `~/.cco/tags.yml` (Domain A synced, never Domain B); not in `pack.yml`/`project.yml`/manifest/index (project tags removed from `project.yml`+index); `cco list --tag` reads it; migration **prompts** profile→tag conversion. Next: global resource-coherence inventory |

**Open — deferred to dedicated analyses (run after this design is persisted):**
| # | Question |
|---|----------|
| **RD-triggers** | Future opt-in auto-sync: background daemon and/or native hooks in select cco commands vs opt-in git hooks vs manual-only. Manual-only is the v1 default. |

---

## 9. Impact / Supersession & Future Workstreams

- Supersedes the central-vault project store and `../vault/profile-isolation-design.md`;
  reuses `../vault/local-path-resolution-design.md` (`@local`).
- Roadmap: update the "Vault Simplification" entry to **decentralized in-repo config
  (sync-as-copy)**; mark vault profile/switch and custom-diff items removed.

**Separate roadmap items (NOT in this refactor's scope):**
- **R-pkg** — Distribute cco as npm/npx + container image (AD11, N4).
- **R-update-native** — Evolve `cco update`: make cco fully agnostic and distribute
  opinionated packs/project-templates via native publish/install (like any user),
  keeping a `cco update` for installed packs (merge local edits vs replace/discard).
  Recorded now so it is not forgotten; designed separately (N5).
- **R-state-sync** — Opt-in cross-PC / cross-team sync of *state* (auto-memory **and**
  session transcripts), the capability the vault gave memory and that v1 drops (ADR-0009).
  Scenarios: (a) one user's multiple machines; (b) team members on a shared project. Kept
  separate from CONFIG sync (ADR-0008) so state and config responsibilities stay distinct.
- **R-workspace** — Persistent `/workspace` root.

**Artifacts (produced):** `design.md`, ADR 0001–0010, and the
**`resource-coherence-inventory.md`** (every skill/agent/rule/template/doc/managed file
referencing the old model + required change + phase — surfaced by ADR-0010). Remaining: a
dedicated analysis for the open RD-triggers question, plus the follow-ups raised by the 16-06
coherence review (`reviews/16-06-2026-design-coherence-review.md`).
