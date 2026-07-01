# Handover — Session config capability model: IMPLEMENTATION

> **Created**: 2026-07-01 · **Track**: implementation of the design accepted in this session.
> Runs on `develop`. **Additive — does not gate the merge or the release.** Design-only work is
> complete; this artifact hands the build to a fresh session.
> **Predecessor**: `config-editor-access-design-handoff.md` (Handover B — the design brief that
> started this track).

Authoritative design (do not re-litigate — read, then build):
[ADR-0036](decisions/0036-session-config-capability-model.md) (capability model) +
[ADR-0041](decisions/0041-unified-session-info-surface.md) (R1 self-info). Living design docs:
`../../internal-projects/config-editor/design/design-config-editor.md` (rewritten to target) and
`../../internal-projects/tutorial/design/design-tutorial.md` §0.

Design branch with the ADRs + doc rewrites: `feat/config-access/capability-model` (commits
`d9e312b`, `54fa34c`, `3b1e85c`, `db2d0bc`, `7b67580`). Implementation continues on it (chosen
2026-07-01).

---

## 0. Implementation progress (update as steps land)

- **Step 1 — caller-context (D8): ✅ done** (2026-07-01, branch
  `feat/config-access/capability-model`). `_cco_caller_context()` (`host` | `container-agent`)
  added to `lib/paths.sh`; `_cco_resolver_guard` re-expressed on it — **behavior-preserving**
  (the `CCO_ALLOW_HOST_RESOLVE=1` hatch and the anti-in-container die() are unchanged).
  Implemented as a **pure function** (re-evaluated like `_cco_in_container`, not memoized) to
  avoid subshell-inherited staleness in the test harness. Container-operator mode (D4) will layer
  on top in step 4 — not inferred here (ADR-0007 invariant intact). Tests: 3 in
  `tests/test_paths.sh` (container-marker / host / guard-linkage). Suite **1043 pass / 1 fail**;
  the single fail is the **pre-existing, env-only** `test_paths_symlink_safe_tool_root` (DATA
  bucket unwritable inside the self-dev container — not a regression, reproduced on the unchanged
  tree). No `changelog.yml` / migration (purely-internal helper + guard refactor).
- **Step 2 — access resolution: ✅ done** (2026-07-01, same branch). Three knobs resolved by
  precedence `CLI > project.yml access: > ~/.cco/access.yml > preset default (repo/none/on)`.
  **Decided formats** (maintainer): `project.yml` `access:` block uses **short nested keys**
  (`access.claude` / `access.cco` / `access.show_host_paths`); the global default lives in
  **`~/.cco/access.yml`** (keys `claude`/`cco`/`show_host_paths`). Added: `_cco_access_file()`
  (`lib/paths.sh`); pure helpers `_access_is_member` / `_access_norm_bool` / `_access_pick` +
  `_start_resolve_access` (`lib/cmd-start.sh`, called after `_start_load_config`); CLI flags
  `--claude-access` / `--cco-access` / `--show-host-paths` / `--no-show-host-paths`;
  `--enable-config-edit` → `--cco-access edit-project` alias (deprecated). **Note:** `access.<key>`
  is a 2-level block → read with **`yml_get`** (auto-depth 2), NOT `yml_get_deep` (depth 3). Enum
  validation dies on bad values. **Scope boundary:** resolution only — mounts still driven by the
  legacy `enable_config_edit`/`is_internal` path until step 3 switches them over; **no
  `changelog.yml` / template `access:` block yet** (deferred to step 3, when the knobs become
  user-visible by driving mounts — per `documentation-lifecycle`). Tests:
  `tests/test_access_resolution.sh` (12 — pure helpers, 4-layer precedence, alias, enum
  validation, CLI-reaches-resolution). Suite **1055 pass / 1 fail** (same pre-existing env-only
  symlink test).
- **Step 3 — Axis-B/Axis-A mount generation: ✅ done** (2026-07-01, same branch). Mount modes
  now derive from the resolved knobs (`lib/cmd-start.sh` `_start_generate_compose`):
  **Axis B** (`claude_access`) — `none` = B1 `<repo>/.claude` overlaid `:ro` + B2 `/workspace/.claude`
  `:ro` + B3 global authoring `:ro`; `repo` (default) = B1+B2 rw, B3 authoring ro; `all` = + B3
  authoring rw. `settings.json` is **always rw** (runtime prefs, not authoring). **Axis A**
  (`cco_access`) — the `<repo>/.cco` `:ro` overlay (generalized `_committed_ro`) is dropped only
  under `edit-project`/`edit-all` (or `is_internal`, until step 5). `--enable-config-edit` flows
  through the step-2 alias (`cco_access=edit-project`) so the old hatch still unlocks A1. Resolved
  access shown in the dry-run summary. **User-visible → update-system obligations landed**:
  `changelog.yml` **#28** (additive) + optional `access:` block in
  `templates/project/base/project.yml`. **No migration** (purely-optional block, code defaults on
  absence). Tests: 4 mount-mode assertions added to `tests/test_access_resolution.sh` (B2 rw
  default / B3 authoring ro; claude none locks B1+B2; claude all unlocks B3; cco edit-project
  unlocks A1). Suite **1059 pass / 1 fail** (same pre-existing env-only symlink test).
  **Not yet done (deferred to step 4/5):** A2 `~/.cco` structural mount + secret filtering + the
  wrapped-cco shim / A3 / R2 / container-operator; the built-in **presets** (config-editor
  `edit-all`/`all`, tutorial `read`/`none`) still ride the legacy `is_internal` branch.
- **Step 4 — Wrapped-`cco` shim + container-operator mode: ✅ done** (2026-07-01, same branch;
  commits after `9f60cf1`). Delivered in 4 atomic commits: **(4a)** `_cco_container_operator()` +
  operator branch in `_cco_resolver_guard` (`lib/paths.sh`) — true only under
  `CCO_CONTAINER_OPERATOR=1` **and** three absolute `CCO_{DATA,STATE,CACHE}_HOME`, so it can
  never be inferred; the anti-in-container `die()` still fires for any silent resolve (ADR-0007
  intact). **(4b)** `_cco_operator_shim` in `bin/cco` — default-deny whitelist/blocklist run
  before dispatch; host-only verbs (`start/stop/build/new`, `resolve/sync/init/join/forget/
  update/clean`, `project rename`, `chrome`, `path set`, `publish/export`, `config push/pull`,
  `remote set-token/remove-token`) die with a host hint; read verbs pass at any operator level,
  write verbs gated on `CCO_CCO_ACCESS ∈ edit-*`; host first-run bootstrap skipped in operator
  mode. **(4c)** `Dockerfile` bakes `bin/`+`lib/`+`templates/`+`changelog.yml`+`package.json` to
  `/opt/cco` + symlink (defaults/migrations NOT baked — their verbs are host-only). **(4d/4e)**
  `_start_generate_compose` emits the operator env + bucket mounts (`~/.cco` A2 at the natural
  `$HOME/.cco`; DATA + CACHE/llms follow the edit level; **STATE index-file only, ro** —
  transcripts/memory/**remotes-token** excluded) and masks real secret files
  (`secrets.env`/`*.env`/`*.key`/`*.pem`, not `*.example`) with an empty `:ro` overlay on **every**
  `.cco` mount **and** `~/.cco` (capability-matrix: filtered in every column). **Two mechanism
  choices, grounded from the ADR (flagged for review):** (i) CONFIG resolved via the natural
  `$HOME/.cco` mount, **no `CCO_CONFIG_HOME`** (D4 lists only DATA/STATE/CACHE — invariant intact);
  (ii) a **B3 guard overlay** re-overlays `~/.cco/.claude` `:ro` under the A2 path when
  `claude_access!=all`, keeping the `.claude`/`.cco` axes separate. `changelog.yml` **#29**
  (additive, "requires `cco build`"). **No migration** (env/mount/Dockerfile only). Tests: 3
  (`test_paths.sh` operator guard), 10 (new `test_operator_shim.sh` whitelist/blocklist +
  write-gating), 8 (`test_access_resolution.sh` operator buckets + secret masking + B3 guard).
  Suite **1079 pass / 1 fail** (same pre-existing env-only `test_paths_symlink_safe_tool_root`).
  **Not done in step 4 (deferred):** built-in presets still ride the legacy `is_internal` branch
  (they do **not** get the operator env yet) → **step 5**; `show_host_paths` read-output toggle +
  R1 `path_map` → **step 6**; the built-in CLAUDE.md/`config-safety.md` rewrites (they still say
  "cco is host-only", which is still TRUE for the built-ins until step 5) → **step 5/7**.
- **Steps 5–7 — pending.** Next up: **step 5** (express tutorial `read`/`none` + config-editor
  `edit-all`/`all` as presets that emit the operator env; `--all` / repeatable `--project` over
  `<repo>/.cco` only). Then step 6 (R1, ADR-0041) and step 7 (docs + remaining tests).

---

## 1. What was decided (one-paragraph recap)

Session resources classified on **two axes** — B (`.claude` authoring: repo/project/global) and
A (`.cco` wiring: `<repo>/.cco`, `~/.cco`+packs/templates, internal XDG) — plus a **managed
floor** (`/etc/claude-code`, always ro) and a **read surface** R (R1 self-info, R2 global-read).
**Three orthogonal knobs**: `claude_access` (none|repo|all), `cco_access`
(none|read|edit-project|edit-global|edit-all), `show_host_paths` (on|off, default on), resolved
**CLI > project.yml `access:` > global default > preset**. Internal XDG is mutated **only via a
whitelisted wrapped `cco`** in a **container-operator mode** (no logic duplication; tokens +
real secret files host-only/filtered; `config push`/`pull` host-only). Built-ins are **presets**:
normal = `repo`/`none`; config-editor = `all`/`edit-all` (+`--all`/`--project` over `<repo>/.cco`
only); tutorial = `none`/`read` (read-all scope). Project-scope selector (`--all`/`--project`/
current) is orthogonal to the level and applies to `read` too.

## 2. Implementation order (dependency-first — from ADR-0036 §Implementation)

> **Status (2026-07-01): steps 1–4 ✅ done, step 5 is next.** Per-step detail + test/suite
> results live in §0 (the progress log). Steps 1–4 landed on `feat/config-access/capability-model`
> (commits after `e533093`).

1. **Caller-context (D8)** — ✅ **done** — `_cco_caller_context()` (`host` | `container-agent`) in
   `lib/paths.sh`; re-express `_cco_resolver_guard` on it. Foundational.
2. **Access resolution** — ✅ **done** — parse/resolve the three knobs + precedence;
   `--enable-config-edit` → `--cco-access edit-project` alias.
3. **Axis-B / Axis-A mount generation** — ✅ **done** — drive `.claude` + `.cco` mount modes from
   the resolved knobs (generalizes `_committed_ro`).
4. **Wrapped-`cco` shim + container-operator mode** — ✅ **done** — whitelist/blocklist shim
   (`config save` in, `config push`/`pull` host-only); bucket mounts (DATA/CACHE per edit level /
   STATE **index-only** ro / **tokens excluded**); real secret files filtered via an empty `:ro`
   overlay on every `.cco` mount + `~/.cco` (only `*.example` visible); `CCO_CONTAINER_OPERATOR` +
   `CCO_{DATA,STATE,CACHE}_HOME`; `bin/cco`+`lib/` baked into the image. Ships R2. (Host-path
   *labelling in read output* + `path_map` toggle deferred to step 6 per the reading below.)
5. **Built-in presets** — ◀ **START HERE (fresh session)** — express tutorial (`read`/`none`) +
   config-editor (`edit-all`/`all`) as presets **that emit the step-4 operator env** (they still
   ride the legacy `is_internal` branch today); config-editor `--all` / repeatable `--project`
   (only `<repo>/.cco`); then rewrite the built-in CLAUDE.md + `config-safety.md` to the
   wrapped-`cco` model (they still say "cco is host-only", true until this step lands).
6. **R1 self-info (ADR-0041)** — unified `workspace.yml` (+`knowledge`/`llms`, gated `path_map`;
   **session-start snapshot** per R1-D6). **NET CUT** (R1-D4, maintainer decision): migrate the
   three consumers **and delete `packs.md` in one change** — no dual-emit, no legacy window.
   Validate on `develop` (`./bin/test` + real `cco start` dogfood) **before release** (R1-D5).
7. **Docs + tests** — see §4/§5.

Steps 1–5 + 7 are independent of R1's format; step 6 follows ADR-0041. R2 (step 4) is independent
of R1.

### Guiding principles & invariants to honor (foundation)

`docs/maintainers/foundation/design/guiding-principles.md` + the machine-agnostic invariant:

- **P1 — config vs internal (edit criterion)**: the two axes rest on this. A `.cco` structural +
  B `.claude` = user-editable config; A3 (tags/remotes/index) = **internal**, CLI-only.
- **P6 — hide internal files**: internal XDG is never hand-edited by the agent → mutate **only via
  wrapped `cco`** (D4). Never mount+free-edit `tags.yml`/`remotes`/index.
- **P9 — hooks/agents invoke `cco` by PATH; no tool code in data buckets**: the in-container shim
  is `cco` on PATH (container-operator mode), not a reimplementation.
- **P17 — delegate enforcement to git; cco assists, never gatekeeps**: the knobs are **runtime
  guardrails**, not permission gatekeeping (ADR-0027's reconciliation carries over).
- **P18 — one repo, one config home**: `--all`/`--project` mount `<repo>/.cco` per member; never
  full code repos.
- **AD3 — committed config is machine-agnostic**: never write host paths into committed files;
  `show_host_paths` is a *read-only runtime view*, not committed state (ADR-0041 R1-D3).
- **ADR-0007 — cco is host-side**: the container-operator mode mounts real buckets + sets
  `CCO_*_HOME` deliberately; the resolver guard (re-expressed on D8's caller-context) still fires
  for any *silent* in-container resolve.

## 3. Key files (code-grounded; line numbers drift — re-read)

- `lib/cmd-start.sh` — arg parsing (~1072–1080: add `--claude-access`/`--cco-access`/
  `--show-host-paths`/`--no-show-host-paths`); `_committed_ro` + mount generation (~673–782 →
  knob-driven); `_setup_internal_config_editor` (60–127) + `_start_resolve_project` (142–227 →
  preset resolution); `--all`/repeatable-`--project` for config-editor.
- `lib/paths.sh` — `_cco_caller_context` + guard (281–299); container-operator env wiring.
- `bin/cco` — the whitelist/blocklist shim dispatch when in container-operator mode.
- `Dockerfile` — bake `bin/cco` + `lib/` (jq already present) for the in-container shim.
- `lib/workspace.sh` (13–99) + the `packs.md` generator in `lib/cmd-start.sh` (~875–947) — R1.
- Consumers to migrate for R1: `config/hooks/session-context.sh` (75–80),
  `config/hooks/subagent-context.sh` (23–29), `defaults/managed/.claude/skills/init-workspace`
  (step 1 reads workspace.yml), and reconcile `defaults/managed/.claude/rules/memory-policy.md`.
- **R1 doc-sweep at impl (shipped-behavior docs, update WHEN the code lands — not before, per
  `documentation-lifecycle`)**: docs that describe `packs.md` as the current surface —
  `packs/design/design-packs.md`, `environment/design/design-docker.md`,
  `configuration/file-destinations/design/design-file-destinations.md`,
  `configuration/scope-hierarchy/design/design-scope-hierarchy.md`,
  `configuration/llms/design/design-llms.md`, `update-system/design/design-update-system.md`,
  `foundation/design/architecture.md`, `foundation/analysis/spec.md`,
  `configuration/decentralized-config/design.md`. Repoint each to the unified `workspace.yml`.
- `internal/config-editor/.claude/{CLAUDE.md,rules/config-safety.md}` + `internal/tutorial/.claude/*`
  — preset behaviors, host-path labelling note, wrapped-`cco` usage.
- `project.yml` schema — new optional `access:` block (`claude_access`/`cco_access`/
  `show_host_paths`); global default datum under `~/.cco`.

## 4. Update-system obligations

- **Additive**: `--*-access` flags + `access:` block → code-level defaults + `changelog.yml`
  entry + `templates/project/base/project.yml`.
- **Migration**: since `project.yml` gains an `access:` block, add `migrations/project/NNN_*.sh`
  (idempotent) if any structural rewrite is needed; base templates updated.
- **Opinionated**: updated `config-safety.md` / built-in CLAUDE.md → `defaults/`/`internal/`.

## 5. Tests

Extend `tests/test_config_editor.sh` (+ `test_tutorial.sh`): knob precedence
(CLI>project>global>preset); granular `cco_access` (`edit-project` vs `edit-global` vs `edit-all`
mount modes); `claude_access` `none|repo|all`; `--all`/`--project` mounts (only `<repo>/.cco`,
skip unresolved); wrapped-`cco` whitelist allowed + blocklist refused (incl. `config push`/`pull`
host-only); **token + secret-file exclusion** (`remotes-token` not mounted, `remote set-token`
blocked, `secrets.env`/`*.key`/`*.pem` never in any mount — even under `--all`/tutorial read-all —
only `*.example` visible); caller-context guard; R1 unified-file
shape + `path_map` toggling with `show_host_paths`; R1 consumer parity (hooks + init-workspace);
description-seeding idempotency; completeness gate before `packs.md` removal.

## 6. Definition of done

- Steps 1–7 implemented; suite green; `./bin/test` clean.
- The three knobs work end-to-end with correct precedence; built-ins behave as presets.
- Wrapped-`cco` enforces whitelist/blocklist (`config push`/`pull` host-only); internal XDG
  mutated only via `cco`; **tokens and real secret files never reach the container** (even under
  `--all`/tutorial read-all — only `*.example` visible).
- R1 ships per ADR-0041 with the completeness gate satisfied; old surfaces removed only after.
- Docs (design docs already rewritten) + `config-safety.md` + `changelog.yml` + migration done.

## 7. Self-development caveat

All touched files are host-side (`lib/`, `bin/cco`, `internal/`, `config/`, `Dockerfile`,
`defaults/`). Changes are live for a **fresh** `cco start` / after `cco build` (shim baking),
**not** the running session. Test via `./bin/test`. Baking the image from inside the container
rebuilds under-foot (harmless, but see project CLAUDE.md note).

## 8. Reading order

ADR-0036 → ADR-0041 → `design-config-editor.md` → `design-tutorial.md` §0 → this handover →
`lib/cmd-start.sh` + `lib/paths.sh`.
