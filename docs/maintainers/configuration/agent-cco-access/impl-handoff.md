# Handover — agent ↔ cco access & context: IMPLEMENTATION

> **Created** 2026-07-02 · **Last updated** 2026-07-02 (consolidated: integrates ADR-0043).
> **Branch**: all work lands **directly on `feat/config-access/capability-model`** (stacked on
> workstream B; commit here, **push from the Mac**).
>
> **Authoritative design (read first, then build — do not re-litigate):**
> - [`design.md`](design.md) + [ADR-0042](decisions/0042-agent-cco-interaction-model.md) — the
>   three-level A/B/C interaction model; retires the `workspace.yml` *file* of ADR-0041.
> - [ADR-0043](../../cli/decisions/0043-unified-cli-environment-access-scope.md) +
>   [CLI environment-awareness v1.1](../../cli/design/design-cli-environment-awareness.md) — the
>   unified env & access-scope layer that scopes read-verb **output** (added mid-sprint after the
>   step-4 `read-project` narrowing; see step 4.5).
> - Builds on ADR-0036 (capability knobs).
>
> **Nature**: additive at the schema level (optional `project.yml` fields + new access enum
> values) **plus** a cleanup migration (014) for retired generated files, **plus** the ADR-0043
> read-verb scoping layer. Follow-on sprint; does not gate the capability-model (B) release.

---

## Status at a glance (2026-07-02)

| Step | Title | State | Commit |
|---|---|---|---|
| 1 | Symmetric read scoping + scope-aware operator help | ✅ done | `0e6bc87` |
| 2 | Level A hook injection — retire the `workspace.yml` file | ✅ done | `8183b4a` |
| 3 | Optional `repos[]/extra_mounts[].description` | ✅ done | `a098719` |
| 4 | config-editor broad-UX + `read-project` mount narrowing | ✅ done | `9e4535f` |
| **4.5** | **Unified env & access-scope layer → scope read-verb OUTPUT (ADR-0043)** | **▶ next** | — |
| 5 | Managed Level-C config-interaction rule + Level-A awareness | ⏳ pending | — |
| 6 | Migration 014 — remove committed generated files + `.gitignore` | ⏳ pending | — |
| 7 | Docs cutover + suite green → merge `develop` + push | ⏳ pending | — |

Suite after step 4: **1106 / 1** — the single failure is pre-existing + env-only
(`test_paths_symlink_safe_tool_root`, sandbox XDG-DATA perms; `migration_010` also fails only in
isolation). Both unrelated to this sprint.

---

## What's done (condensed — full detail in git)

- **Step 1 (`0e6bc87`)** — `_ACCESS_CCO_VALUES` + `_start_resolve_access` gained
  `read-project/read-global/read-all` (bare `read` = back-compat alias → `read-all`); normal +
  tutorial presets default to `read-project`; `_cco_operator_shim` gates the personal-global
  namespaces (`template …`, `remote list`) behind `read-global+` while `cco list`/`cco docs`
  stay open; `usage()` is scope-aware in operator mode. This established the **project|global
  scope taxonomy** that ADR-0043 now reuses for output scoping.
- **Step 2 (`8183b4a`)** — Level-A context is computed host-side (`lib/session-context.sh`) and
  injected as `CCO_SESSION_CONTEXT`/`CCO_SUBAGENT_CONTEXT` (base64) env vars; the SessionStart/
  SubagentStart hooks decode + merge with in-container discovery. `lib/workspace.sh`, the `:ro`
  overlay, and all `workspace.yml` reads are gone. **No file written anywhere** (INV-2).
  `path_map` gated by `show_host_paths` (INV-4).
- **Step 3 (`a098719`)** — optional `repos[].description` + `extra_mounts[].description` in
  `project.yml`, rendered into Level A (INV-3 single source). `changelog #32`. Additive, no migration.
- **Step 4 (`9e4535f`)** — **(a)** config-editor UX: bare = BROAD (`~/.cco` + every resolvable
  project's `<repo>/.cco`, no repos); `--all` = back-compat alias; `--project` (repeatable)
  narrows + **mounts that project's repos**; new `--repo <name>`. **(b)** `read-project` **mount
  narrowing**: the operator CONFIG bucket is no longer bind-mounted whole — only referenced
  personal-store packs mount at `/home/claude/.cco/packs/<name>` (ro; invalid pack.yml skipped).
  `read-global/read-all/edit-*` still mount the whole store; DATA/STATE-index/CACHE unchanged.
  **This narrowing is what necessitated ADR-0043 / step 4.5.**

---

## Remaining roadmap (dependency-ordered)

### ▶ Step 4.5 — Unified env & access-scope layer; scope read-verb OUTPUT (ADR-0043)

**Why now**: step 4 narrowed the *mount* at `read-project`, but the *CLI output* is still
misaligned — `cco list pack` is scoped (scans the narrowed mount) yet `cco list template` is
falsely empty and `cco list project` shows all projects. Fix via **one shared layer** so
commands implement only their own differentiation (maintainer's explicit requirement).

**Deliverables**
- **(a) `lib/access-scope.sh`** (depends on `lib/paths.sh`) — the single source for
  environment + permission resolution. API (names finalise at build):
  `_env_context` (`host|operator`) · `_env_access` (resolved scope) ·
  `_env_current_project` (`PROJECT_NAME`) · `_env_scope_class <kind>` (`project|global`,
  reusing the step-1 taxonomy) · `_env_in_scope <kind> <name> [owner]` (0/1; **host → always
  visible**, INV-A) · `_env_note_hidden <kind>` · `_env_flush_hidden_notice` (one standardized
  **count-only notice on stderr**, INV-B/C) · `_env_require_visible <kind> <name>` (graceful
  "not available at this scope — use read-global / the host" for `show`/detail verbs).
- **(b) Wire the read surface** (ADR-0043 §4): `cco list`; the five `cco list <kind>`
  (project·pack·template·llms·remote); the five `cco <kind> show`; `cco … validate`;
  `cco path list`; `cco project coords`. Each: `_env_in_scope` while iterating, `_env_note_hidden`
  on skip, `_env_flush_hidden_notice` at the end; `show`/detail verbs call `_env_require_visible`
  first. Never re-derive context (INV-E).
- **(c) Robustness** (absorbs the earlier "point 3"): no raw errors when a resource is unmounted
  under a scope — `show` degrades via `_env_require_visible`; `list` skips + counts. The STATE
  index stays the complete internal map; scoping is a **presentation filter** (INV-D).
- **(d) Tests**: new `tests/test_access_scope.sh` (scope logic + host-open invariant) +
  scoped-output assertions on the wired verbs (operator mode: `read-project` hides
  templates/other projects with a stderr notice; `read-global/all` shows all; host shows all).
  `tests/test_operator_shim.sh` must stay green (gating unchanged).

**Notes / gotchas**
- Signals already exported by `cco start`: `PROJECT_NAME` + `CCO_CCO_ACCESS`. Export
  `CCO_CLAUDE_ACCESS` / `CCO_SHOW_HOST_PATHS` **only if** a wired verb needs them (keep the
  module extensible, don't pre-wire).
- Notice on **stderr** (stdout stays machine-readable). Count-only — never leak hidden names.
- `cco list pack` already scopes *by accident* (dir scan of the narrowed mount) — route it
  through the layer too so the behaviour is intentional and uniform with the other kinds.
- **Follow the CLI environment-awareness checklist (v1.1 §5).**

### Step 5 — Level C managed config-interaction rule + Level-A awareness

- New `defaults/managed/.claude/rules/cco-config-interaction.md`, **access-gated** (applies at
  `cco_access ≥ edit`): verify `git diff`/status before editing config, atomic config commits,
  use `cco config save` / **`cco project save`**, never write secrets into committed files,
  mutate internal XDG only via wrapped `cco`, show host-only verbs for the host terminal.
- **Awareness (ADR-0043 §5, INV-B pairing)**: Level A **and** this rule must state that at
  `read-project` the `~/.cco` view is **project-scoped** — a subset, not the whole store; use
  `read-global`/`read-all` (or the host) for the full picture. Level A already declares the
  wrapped-`cco` scope (step 2); add the project-scoped-view line.
- Managed files are baked → **requires `cco build`** to take effect.
- > **`cco project save` is forthcoming (workstream D).** Write the rule as if it exists; D's
  > design session verifies the integration (verb name, operator-shim classification,
  > wrapped-`cco` reachability). `cco config save` exists today.

### Step 6 — Migration 014 (project scope) + `.gitignore` + packs.md investigation

- Migration `migrations/project/014_*.sh` (**next id — current max = 013**): idempotently
  `git rm`/remove committed generated files from `<repo>/.cco/claude/`: `workspace.yml`,
  `packs.md`, `scheduled_tasks.lock`.
- Scaffold generated-file exclusions in **`templates/project/base/.cco/.gitignore`** (it does
  **not exist yet**) and propagate to existing projects via the migration.
- Tests: idempotency, files removed, gitignore present.
- > **Scouted this session (grounding):** in *this* repo `<repo>/.cco/claude/` still tracks
  > `workspace.yml` + `scheduled_tasks.lock` (committed) — 014 removes them. The empty `packs.md`
  > **reappears** because this self-dev session runs the **pre-ADR-0042 image**: the old generator
  > wrote `workspace.yml`/`packs.md` into `/workspace/.claude/` = the bind-mount of
  > `<repo>/.cco/claude/` (the committed tree) — that is also how they were first committed.
  > Post-step-2 **no write path remains** (grep of `lib/`/`bin/` is clean). So the "reappearance"
  > resolves once this container is rebuilt on the new image; 014 cleans the already-committed copies.

### Step 7 — Docs cutover + suite green → merge

- **User docs to the new truth**: `cli.md` (access enum incl. `read-project`, config-editor
  `--project`/`--repo`, the read-verb scoping + hidden-notice behaviour), `project-yaml.md`
  (descriptions — done in step 3, verify), the **config-editor guide**
  `docs/users/internal-projects/guides/config-editor.md`, context-hierarchy, docker-and-networking.
- **Built-in config-editor** `internal/config-editor/.claude/CLAUDE.md` + `config-safety.md`:
  reflect broad-default UX + `--repo`; and (for any read-scoped built-in) the ADR-0043 awareness.
- Retire remaining `workspace.yml` references across docs; forward-annotate as needed
  (documentation-lifecycle rule — ADRs are history, living docs rewritten to truth).
- `./bin/test` green. Then **merge → `develop` + push (from the Mac)**.

---

## Ratified decisions (build to these)

1. Normal-project default `cco_access` = **`read-project`** (was `none`).
2. **Full symmetric read scoping**: `none · read-project · read-global · read-all · edit-project ·
   edit-global · edit-all`.
3. **config-editor UX**: bare = all projects' `<repo>/.cco` + `~/.cco` (no repos);
   `--project <name>` (repeatable) = that project's `.cco` **+ its repos**; `--repo <name>` = add
   one repo. Broad-by-default; repos are an explicit opt-in.
4. **`cco docs`** reachable at any read level in every session (no extra mount).
5. **`read-project` mount narrowing + unified output scoping (ADR-0043)**: `read-project` exposes
   only the project's referenced packs (mount, step 4b); read verbs scope their **output** to
   match via one shared layer, with a count-only "hidden by scope" notice on stderr (step 4.5).

## Cross-cutting principles

- **CLI environment-awareness** ([v1.1](../../cli/design/design-cli-environment-awareness.md)) —
  the whole CLI surface is dual-context (host + in-container agent). Two orthogonal layers:
  **verb gating** (§4 — host-only vs read(scope) vs write(scope), via the shim/resolver-guard) and
  **output scoping** (§4b — what a permitted read verb shows, via `lib/access-scope.sh`). Any verb
  touched MUST follow the §5 checklist and test both contexts. A **full CLI-surface audit** is
  scheduled once B2 lands (roadmap → broader planned work); step 4.5 pulls the *read* surface in.
- **Invariants** — design §5: **INV-1** Level A carries only session-fixed info · **INV-2** no
  generated artifact in committed trees · **INV-3** descriptions single-source in `project.yml` ·
  **INV-4** host paths only in the gated `path_map`. ADR-0043: **INV-A** host-open · **INV-B**
  hidden ≠ absent (announce) · **INV-C** notice on stderr · **INV-D** index stays complete
  (presentation filter) · **INV-E** single source for context/permissions.

## Prerequisite / branching

Stacks on workstream B (capability model, branch `feat/config-access/capability-model`,
implementation complete, pending merge to `develop` + push from the Mac). Recommended: **merge B
into `develop` first**, then continue this sprint; if B is not yet merged, keep stacking on its
branch and rebase after. Commit on branch B; **push from the Mac**.

## Definition of done

- Read axis symmetric; normal default `read-project`; `cco docs` at any read level. ✅ (1)
- Level A = injected context, **no `workspace.yml` file anywhere**; parity verified. ✅ (2)
- Descriptions single-sourced in `project.yml`, rendered into context; no round-trip. ✅ (3)
- config-editor broad default + `--project` repo-aware + `--repo`; `read-project` mount narrowed. ✅ (4)
- **Read verbs scope their output via `lib/access-scope.sh`; hidden resources announced; no raw
  errors on unmounted resources.** ⏳ (4.5)
- Managed config-interaction rule active at edit levels; Level A + rule carry the project-scoped-
  view awareness. ⏳ (5)
- Migration 014 removes stale generated files + scaffolds `.gitignore`; empty-`packs.md` cause
  understood. ⏳ (6)
- All `workspace.yml` plumbing retired; user docs cut over; suite green; `changelog #32`. ⏳ (7)

## Deferred / open

- **~~`read-project` mount narrowing~~ / ~~scope-aware read verbs~~ — CLOSED**: narrowed in step 4
  (`9e4535f`); output scoping decided (option A) and formalised in **ADR-0043** → step 4.5.
- **Language rule** (`.claude/rules/language.md`) → move from template interpolation into Level
  A/C injection (design §9 deferral). Not this sprint.
- **`CCO_CLAUDE_ACCESS` / `CCO_SHOW_HOST_PATHS` export** — add only when a wired verb needs them
  (step 4.5 keeps `lib/access-scope.sh` extensible for these signals).
