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
`d9e312b`, `54fa34c`, `3b1e85c`, `db2d0bc`, `7b67580`). Implementation can continue on it or a
sibling `feat/config-access/*` branch off `develop`.

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

1. **Caller-context (D8)** — `_cco_caller_context()` (`host` | `container-agent`) in `lib/paths.sh`;
   re-express `_cco_resolver_guard` on it. Foundational.
2. **Access resolution** — parse/resolve the three knobs + precedence; `--enable-config-edit` →
   `--cco-access edit-project` alias.
3. **Axis-B / Axis-A mount generation** — drive `.claude` + `.cco` mount modes from the resolved
   knobs (generalizes `_committed_ro`).
4. **Wrapped-`cco` shim + container-operator mode** — whitelist/blocklist shim (`config save` in,
   `config push`/`pull` host-only); bucket mounts (DATA rw / STATE index ro / **tokens
   excluded**); **filter real secret files** (`secrets.env`, `*.env`/`*.key`/`*.pem`) out of every
   `<repo>/.cco` mount (`:ro`-hide/tmpfs/filtered-copy — expose only `*.example`);
   `CCO_CONTAINER_OPERATOR` + `CCO_*_HOME`; host-path labelling; bake/mount `bin/cco`+`lib/` into
   the image. Ships R2.
5. **Built-in presets** — express tutorial (`read`/`none`) + config-editor (`edit-all`/`all`) as
   presets; config-editor `--all` / repeatable `--project` (only `<repo>/.cco`).
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
