# ADR 0026 — `cco init`: idempotent global ensure + per-repo project scaffold

**Status**: Accepted (2026-06-23)
**Deciders**: maintainer (proposed the architecture), implementer (validated it)
**Context docs**: `../design.md` §7/§8/§9 P3, `../P3-handoff-legacy-cutover.md` §5,
`../P3b-handoff-init-scaffold.md`
**Related ADRs**: 0017 D3 (J0 first-run bootstrap — **refined here**: J0 owns empty *roots*, init
owns global *content* for fresh installs), 0025 (migration ownership: eager global via `cco update`,
lazy per-project via `cco init --migrate` — **refined here**: the idempotency gate moves to a
migration-state marker), 0021 (entry verbs; `cco init --migrate` mode), 0008 (`~/.cco` personal store),
0024 D1 (one repo = one config home), 0012 (`manifest.yml` removed — new `cco init` emits none)

---

## Context

Design §7 says `cco init` (clean) **scaffolds a clean `<repo>/.cco/` in the current repo**. But Phase 2
left the clean `cco init` as the **legacy central global-init** (`cmd-init.sh`: copy
`defaults/global/.claude` → `$GLOBAL_DIR`, create `$PROJECTS_DIR`, `manifest_init`, build the image;
its closing hint even points to `cco project create`). So:

- The **per-repo scaffold** of design §7 was never built (`cco join` only registers an *existing*
  `.cco/`; `cco init --migrate` hydrates from the vault backup). **`cco project create` therefore has
  no decentralized replacement** — the P3-3 cutover surfaced this gap.
- A second, **genuinely under-specified** question (flagged in the P2 analysis): for a **fresh user**
  (no legacy vault, so no `cco update` migration), **who populates `~/.cco/global` from the framework
  defaults?** J0 (ADR-0017 D3) creates the four roots **empty**; `cco update` (ADR-0025) migrates only
  **from the vault**. Nothing seeds a fresh `~/.cco/global`.

This blocks deleting `cco project create` (P3-3b) and must be resolved before the per-repo scaffold is
built.

## Decision

**`cco init` is the single project entry point and also bootstraps the global config on first use —
idempotently.** Run inside a repo, `cco init`:

1. **Ensures the global config (only if absent).** If `~/.cco/global/.claude` is missing, seed it from
   the framework defaults (`defaults/global/.claude` → `~/.cco/global/.claude`), set languages, copy the
   global `setup*.sh`/`mcp-packages.txt`, and build the global STATE meta/base — the existing global-init
   logic **retargeted from `$GLOBAL_DIR` (central) to `~/.cco/global`**. If `~/.cco/global` already
   exists, **skip this step** (idempotent). The new `cco init` **emits no `manifest.yml`** (ADR-0012).
2. **Scaffolds the per-repo `<repo>/.cco/`** (the design §7 core): from `templates/project/base/`, write
   `<repo>/.cco/{project.yml (logical names + coordinates), claude/, secrets.env.example, .gitignore}`
   (+ optional `mcp.json`/`setup.sh`/`mcp-packages.txt`), and **register the project in the STATE index**
   (`name → repo path`, `project → members`). Refuse (or `--force`) if `<repo>/.cco/` already exists.

**Ownership split (refines ADR-0017 D3 / ADR-0025):**

| Concern | Owner |
|---|---|
| Create the four **roots** (empty, `~/.cco` git-init'd) | **J0**, on any command (ADR-0017 D3, unchanged) |
| Populate `~/.cco/global` from **framework defaults** (fresh user) | **`cco init`** (idempotent ensure, **NEW**) |
| Populate `~/.cco` from the **legacy vault** (migrating user) | **`cco update`** (eager global migration, ADR-0025) |
| Scaffold a repo's `<repo>/.cco/` | **`cco init`** (design §7) |
| Hydrate a repo's `.cco/` from the vault backup | **`cco init --migrate <project>`** (ADR-0021) |

This keeps a **single `cco init` path** for projects, manages the global + internal dirs
**automatically** (at the first project `cco init` OR via `cco update` migration), and **introduces no
new verb** — the design explicitly left `cco setup` as an optional future (§8), so folding the
global-ensure into `cco init` is the design-faithful choice.

**Required refinement to the migration idempotency gate (ADR-0025).** `_cco_migrate_global` currently
treats **`~/.cco/global/.claude` presence** as "already migrated" (`migrate.sh:254`). With `cco init`
now able to populate `~/.cco/global` from defaults, that gate would make a later `cco update`
**silently skip** a legacy user's vault migration (losing their customizations). The gate therefore
moves to an explicit **migration-state marker** (`<state>/cco/migration-state` → `global-migrated`),
**not** `~/.cco/global` presence. So a legacy user who runs `cco init` **before** `cco update` still
gets migrated: `cco update` detects the verified vault backup **and** no `global-migrated` marker →
**offers a non-destructive migration** — **back up the current `~/.cco`** (restorable) and **ask for
explicit confirmation** because `~/.cco/global` already exists — then migrates and sets the marker.
`cco update` is never destructive and stays runnable post-init.

## Alternatives considered

- **`cco init` = per-repo scaffold ONLY; `cco update` seeds a fresh `~/.cco/global` from defaults.**
  Rejected: it forces a fresh (never-migrating) user to run `cco update` for global setup, splitting the
  natural first-run flow across two verbs; the maintainer's "init is the new user's first command" is
  the realistic path. (This was the implementer's first-offered option; the maintainer's is cleaner.)
- **A dedicated `cco setup` verb for global bootstrap.** Rejected by the design (§8 "an explicit
  `cco setup` is an optional future convenience") and by the maintainer (avoids an extra verb).
- **Keep the legacy central global-init unchanged + add a separate scaffold path.** Rejected: leaves the
  central `$GLOBAL_DIR`/`$PROJECTS_DIR`/`manifest` world alive against the AD12 breaking cutover.

## Consequences

- **Positive**: one entry verb; fresh and migrating users both reach a populated `~/.cco`; no `cco setup`;
  `cco project create` gains its replacement so it can be deleted (P3-3b); the central global-init world
  is removed; `cco update` stays a safe, non-destructive, idempotent migration even after `cco init`.
- **Negative / accepted**: `cco init` carries two responsibilities (global ensure + project scaffold),
  mitigated by strict idempotency (global-ensure is a one-time no-op afterwards). A user who runs
  `cco start`/`cco new` *before* any `cco init` sees an unpopulated `~/.cco/global` — accepted (the
  realistic flow is init-first; a future enhancement could ensure-global on first `cco start`).
- **Migration safety**: the idempotency-gate change (presence → marker) must ship **with** the
  non-destructive `cco update` backup+confirm, or a legacy user who inits first could be asked to migrate
  over a defaults-populated `~/.cco` — the backup makes it restorable and the confirm makes it explicit.

## Implementation (Phase 3, commit P3-3b)

See `../P3b-handoff-init-scaffold.md` for the code-grounded plan: transform `cmd-init.sh` (idempotent
global ensure retargeted to `~/.cco/global` + per-repo scaffold + index register, no `manifest_init`);
move the migration-idempotency gate to the `migration-state` marker + non-destructive `cco update`
confirm; delete `cco project create` (`lib/cmd-project-create.sh` + the `create)` arm) and migrate the
six fixture-using test files to the harness `create_project` helper; remove `test_project_create.sh`,
extend `test_init.sh`. Delta-green stays at the P3-3 end-state (3 P4–5 failures).
