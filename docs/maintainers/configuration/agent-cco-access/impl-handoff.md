# Handover — agent ↔ cco access & context: IMPLEMENTATION

> **Created**: 2026-07-02. **Track**: build the model approved in this session.
> **Additive** at the schema level (optional `project.yml` fields + new access enum
> values) **plus** a cleanup migration for retired generated files. Does not gate the
> capability-model release; it is a follow-on sprint.
>
> **Authoritative, approved design (read first, then build — do not re-litigate)**:
> [`design.md`](design.md) + [ADR-0042](decisions/0042-agent-cco-interaction-model.md).
> Builds on ADR-0036 (capability knobs); retires the `workspace.yml` *file* of ADR-0041.

## Progress

- **✅ Step 1 — DONE** (2026-07-02, `0e6bc87` on `feat/config-access/capability-model`,
  stacked directly on B). Symmetric read scoping (`read-project/global/all`) + `read`
  kept as a back-compat alias → `read-all`; normal + tutorial presets default to
  `read-project`; operator shim gates the personal-global management namespaces
  (`template …`, `remote list`) behind `read-global+` while `cco list` stays open at any
  read level; `cco docs` unconditional; scope-aware `usage()` in container-operator mode
  (host-only verbs flagged, write-only `tag` marked at read levels); inline `--cco-access`
  help updated. +6 tests; suite `1101/1` (the 1 fail pre-existing, unrelated `migration_010`).
  **Decisions taken where the handoff had latitude** (open for revisit): (a) `read` is a
  *deprecated alias*, not removed — zero breakage on existing config/tests; (b) shim
  scope-gating is deliberately minimal (`template`/`remote list` only) — `list`/`project show`
  stay open since self-vs-other is indistinguishable in the shim without a current-project
  signal; (c) **mount footprint unchanged** — `read-project` still bind-mounts the personal
  store `~/.cco` read-only as before. **Physical mount narrowing for `read-project`
  (hiding templates/other-projects) is folded into Step 2 (Level A)**, where resource
  injection is reworked anyway and touches the shipped edit-* mount behavior less. This is
  the one place `read-project` is currently broader than ADR-0042's stated risk profile —
  close it in Step 2.
- **✅ Step 2 — DONE** (2026-07-02, `8183b4a`). Level-A hook injection replaces `workspace.yml`
  (the net cut). `cco start` computes the session-info surface host-side and injects it as
  the `CCO_SESSION_CONTEXT` / `CCO_SUBAGENT_CONTEXT` env vars (**base64**, single-line — sidesteps
  compose-YAML escaping) via `lib/session-context.sh` (`_build_session_context` /
  `_build_subagent_context`); `lib/workspace.sh` retired. Hooks decode + append, keeping their
  in-container discovery (`_ws_section`/`CCO_WORKSPACE_YML`/all workspace.yml reads dropped). The
  `:ro` overlay + dry-run line are gone; `init-workspace` reads the injected context/`project.yml`
  and Step 6 is dropped (descriptions single-source in `project.yml` at edit levels, INV-3; nudge
  when CLAUDE.md absent). Wrapped-cco access scope declared in the block; `path_map` gated by
  `show_host_paths` (INV-4); **no file written anywhere** (INV-2). Tests rewritten to the injected-
  context parity surface (new `decode_session_context` helper). Suite `1100/1` (the 1 fail
  pre-existing + env-only — the sandbox `test_paths_symlink_safe_tool_root`; also `migration_010`
  fails in isolation, both unrelated to this change). **Decision:** the deferred **read-project
  mount narrowing** (from Step 1) is **still open** — not folded in here to keep the cut focused;
  re-evaluate alongside Step 4 (config-editor mounts).
- **✅ Step 3 — DONE** (2026-07-02, `a098719`). Optional `repos[].description` +
  `extra_mounts[].description` in `project.yml`, rendered into the Level-A context (INV-3
  single source, no round-trip). Repo descriptions were already rendered in step 2
  (`_session_repo_description`); this adds `_session_mount_description` (keyed by the mount's
  **effective** container target, since `_effective_extra_mounts` drops the logical name) +
  the extra_mount render. Template `project.yml` + `docs/.../project-yaml.md` document both
  fields; **changelog #32**. +1 test (`test_session_context_extra_mount_description`: described
  → `mount: target (read-only) — desc`; undescribed → target-only). Suite `1101/1` (the 1 fail
  pre-existing + env-only — sandbox `test_paths_symlink_safe_tool_root`, XDG DATA perms).
  Purely additive; no migration.
- **✅ Step 4 — DONE** (2026-07-02, `9e4535f`). Two parts. **(a) config-editor UX** (design §8):
  bare `config-editor` is now BROAD (`~/.cco` + every resolvable project's `<repo>/.cco`, no
  repos — the former `--all`); `--all` kept as a back-compat alias; `--project <name>` (repeatable)
  NARROWS to those projects' `.cco` **and mounts their repos** (repo-aware authoring); new
  `--repo <name>` adds one resolvable repo. The generated config-editor `project.yml` gained a
  `repos:` block (names resolve via the STATE index); `_start_collect_config_editor_targets` sets
  `_ce_targets` + `_ce_repos`. **(b) read-project mount narrowing** (the OPEN decision from steps
  1–2 — **maintainer chose to narrow now**): at `read-project` the operator CONFIG bucket is no
  longer bind-mounted whole — only referenced personal-store packs mount at
  `/home/claude/.cco/packs/<name>` (ro; invalid pack.yml skipped, mirroring the knowledge
  collector); `~/.cco/templates` + other/unreferenced packs stay physically hidden.
  `read-global/read-all/edit-*` still mount the whole store; DATA/STATE-index/CACHE unchanged
  (needed for `cco list`). +7 tests. Suite `1106/1` (pre-existing env-only fail).
- **⏸ OPEN DESIGN DISCUSSION (raised by maintainer 2026-07-02, mid-step-4 — resume here).**
  The narrowing exposed a **3-layer misalignment** at `read-project`: (i) *mount* = referenced
  packs only; (ii) *CLI verbs* = `cco list pack` scans the narrowed mount → already scoped, but
  `cco list template` scans the unmounted `~/.cco/templates` → **empty (false-negative)** and
  `cco list project` reads the STATE index → **all projects (unscoped)**; (iii) *index* references
  host paths not mounted in-container. Three asks:
  1. **Awareness** — the agent must know `read-project` gives a *project-scoped* view of `~/.cco`
     (not "these resources don't exist"); `read-global/read-all` = complete. → inject in **Level A**
     + the **managed rule (step 5)**. *Agreed: do regardless.*
  2. **Scope-aware read verbs?** — should `cco list`/`show` filter by `cco_access`? Options:
     **(A)** full scope-aware (a normal `read-project` session has exactly ONE current project, so
     scope list→that project + its packs/llms; needs a current-project env signal + per-verb
     filter); **(B, recommended)** keep `cco list` as index-based discovery + a "project-scoped"
     footer, rely on awareness (1) + graceful `show` (3), fold full per-verb scoping into the
     **scheduled post-B2 CLI-surface audit**; **(C)** do only 1+3 now, defer ALL verb scoping.
     **← DECISION PENDING (maintainer stepped away; re-ask).**
  3. **CLI robustness** — read verbs (`list`, `<kind> show`, `validate`, `path list`,
     `project coords`) must not crash / must degrade clearly when a resource is unmounted under an
     access scope. *Agreed: do regardless.*
  Process: record the 3-layer model + the point-2 choice in **ADR-0042 / design §8** before
  implementing (documentation-first). Likely reshapes **step 5** (the managed rule carries the
  awareness) and adds a robustness sub-task.
- **▶ Steps 5–7 — PENDING.** Managed Level-C rule (5; must carry the read-project awareness note
  from the discussion above), migration 014 + `packs.md`-reappearance investigation (6), docs
  cutover (CLAUDE.md/cli.md/context-hierarchy enum+default+no-workspace.yml) (7). Steps 1–4 landed
  **directly on `feat/config-access/capability-model`** (committing on branch B; push from the Mac).
  > **Step-6 note (already scouted this session):** `<repo>/.cco/claude/` in *this* repo still
  > tracks stale generated files — `workspace.yml` + `scheduled_tasks.lock` are committed;
  > migration 014 removes them. The empty `packs.md` **reappears** because this self-dev session
  > runs the **pre-ADR-0042 image**: the old generator wrote `workspace.yml`/`packs.md` into
  > `/workspace/.claude/`, which is the bind-mount of `<repo>/.cco/claude/` (the committed tree) —
  > that is also how they got committed originally. Post-step-2 no write path remains (grep of
  > `lib/`/`bin/` is clean). `templates/project/base/.cco/.gitignore` does **not** exist yet —
  > step 6 creates it with the generated-file exclusions.

## Cross-cutting — CLI environment-awareness (read before touching any verb)

ADR-0042 makes the wrapped `cco` a **primary** channel and defaults normal sessions to
`read-project`, so the **whole** CLI surface is now dual-context (host **and** in-container
agent). Any verb touched in the remaining steps (config-editor `--project`/`--repo` in step 4;
`cco project save` classification when D lands; migration/cleanup verbs in step 6) MUST follow
the standing principle + checklist:
**[`docs/maintainers/cli/design/design-cli-environment-awareness.md`](../../cli/design/design-cli-environment-awareness.md)**
— classify host-only vs read(scope) vs write(scope), wire the shim, honor the resolver guard /
secret masking / host-path hygiene / scope-aware help, and test both contexts. A **full
CLI-surface audit against this principle is scheduled once B2 lands** (roadmap → broader
planned work).

---

## Prerequisite / branching

This sprint **stacks on workstream B** (capability model, branch
`feat/config-access/capability-model`, implementation complete, pending merge to `develop`
+ push from the Mac). Recommended: **merge B into `develop` first**, then branch
`feat/agent-cco-access` from `develop`. (If B is not yet merged, stack on its branch and
rebase after.) Step 5's managed rule references `cco project save` (workstream **D**,
not yet built) — write the rule to reference it; it becomes live when D lands.

## Four ratified decisions (2026-07-02) — build to these

1. Normal-project default `cco_access` = **`read-project`** (was `none`).
2. **Full symmetric read scoping**: `none · read-project · read-global · read-all ·
   edit-project · edit-global · edit-all`.
3. **config-editor UX**: bare = all projects' `<repo>/.cco` + `~/.cco` (no repos);
   `--project <name>` (repeatable) = that project's `.cco` **+ its repos**; `--repo <name>`
   = add one repo. Broad-by-default; repos are an explicit opt-in.
4. **`cco docs`** reachable at any read level in every session (no extra mount).

## Implementation order (dependency-first)

1. **✅ DONE (`0e6bc87`) — Read scoping + scope-aware help (foundational).** Extend `_ACCESS_CCO_VALUES` +
   `_start_resolve_access` (lib/cmd-start.sh) with `read-project/read-global/read-all`;
   gate the wrapped read verbs by scope in `_cco_operator_shim` (bin/cco). Change the
   **normal preset default** to `read-project`. Ensure `cco docs` passes at any read level.
   Make `usage()` (bin/cco) **scope-aware in container-operator mode**: list host-only verbs
   flagged `(host only — run on your host)` and mark verbs above the current access level
   unavailable (keyed on caller-context D8 + resolved `cco_access`). Tests: enum validation,
   scope gating, normal default, help annotation in operator mode.

2. **✅ DONE (`8183b4a`) — Level A — hook injection replaces workspace.yml (the net cut).**
   - **Host-side** (`cco start`): compute the injected context block — resources
     (repos/mounts/packs/llms) + optional descriptions (from `project.yml`), knowledge/llms
     index (paths + descriptions from each `pack.yml`), `path_map` (from the STATE index,
     gated by `show_host_paths`), and the access-scope declaration + "use `cco …` for
     detail" pointer. Pass it into the container as an **env var** (e.g. `CCO_SESSION_CONTEXT`)
     set in the generated `docker-compose.yml`. **No file** (INV-2).
   - **Hooks** (`config/hooks/session-context.sh`, `subagent-context.sh`): emit the env-var
     block as `additionalContext`, **merged** with the existing in-container discovery
     (repos via `/workspace/*/.git`, skills/agents/MCP). Drop `_ws_section` +
     `CCO_WORKSPACE_YML` + all `workspace.yml` reads.
   - **Retire**: `lib/workspace.sh` (generator), `_generate_workspace_yml` call in
     `_start_generate_metadata`, the `workspace.yml` compose `:ro` overlay, the dry-run
     summary line.
   - **init-workspace skill**: read `project.yml` / the injected context instead of
     `workspace.yml`; **drop Step 6** (workspace.yml write-back). Keep CLAUDE.md authoring.
   - Tests: injection parity (knowledge/llms/path_map present in context), no workspace.yml
     emitted anywhere, subagent parity.

3. **✅ DONE (`a098719`) — Descriptions in `project.yml` (additive).** Optional
   `repos[].description` (already rendered in step 2) + `extra_mounts[].description` (new
   `_session_mount_description`, target-keyed); template + `project-yaml.md` document both;
   **changelog #32**; +1 test. No migration (optional fields).

4. **✅ DONE (`9e4535f`) — config-editor UX redesign + read-project mount narrowing.** Reworked
   `_start_collect_config_editor_targets` (broad default / `--project` narrow+repos / `--repo`) +
   `_setup_internal_config_editor` (emits `repos:`) + the operator-bucket mount (read-project →
   referenced packs only). +7 tests. **NOTE:** built-in CLAUDE.md/config-safety + user guide
   `config-editor.md` + `cli.md` doc updates are folded into the **step-7 cutover** (and must also
   carry the read-project awareness from the OPEN DISCUSSION above). The `read-project`
   mount-narrowing "deferred/open" item below is now **CLOSED — narrowed** (maintainer decision).

5. **Level C — managed config-interaction rule.** New
   `defaults/managed/.claude/rules/cco-config-interaction.md`, **access-gated** (applies
   when `cco_access ≥ edit`): verify `git diff`/status before editing config, atomic config
   commits, use `cco config save` / **`cco project save`**, never write secrets into
   committed files, mutate internal XDG only via wrapped `cco`, show host-only verbs for the
   host. Ensure Level A declares the wrapped-`cco` availability + current scope. (Managed
   files are baked → requires `cco build`.)
   > **Note — `cco project save` is forthcoming (workstream D).** Write the rule as if it
   > exists (per the approved design); D's design session must verify the integration (verb
   > name is open, operator-shim classification, wrapped-`cco` reachability) — see the
   > roadmap **§D** "Integration with agent↔cco access" note. `cco config save` exists today.

6. **Migration + cleanup (project scope, id 014).** Remove committed generated files from
   `<repo>/.cco/claude/`: `workspace.yml`, `packs.md`, `scheduled_tasks.lock` (idempotent).
   Add generated-file exclusions to `templates/project/base/.cco/.gitignore` and propagate
   via the migration. **Investigate** the reappearing empty `packs.md` (confirm `cco init` /
   `cco sync` never write generated files into the committed tree). Tests: idempotency,
   files removed, gitignore present.

7. **Docs cutover + suite.** User docs to the new truth (cli.md access enum +
   `read-project`, project-yaml.md descriptions, config-editor guide, docker-and-networking
   note); retire remaining `workspace.yml` references; forward-annotations as needed. `./bin/test`
   green. Then merge → `develop` + push (from the Mac).

## Definition of done

- Read axis symmetric; normal default `read-project`; `cco docs` at any read level.
- Level A = injected context, **no `workspace.yml` file anywhere** (tree or CACHE); parity
  with the old injection verified.
- Descriptions single-sourced in `project.yml`, rendered into context; no round-trip.
- config-editor: broad default + `--project` repo-aware + `--repo`.
- Managed config-interaction rule active at edit levels.
- Migration 014 removes stale generated files + gitignore; empty-`packs.md` cause found.
- `lib/workspace.sh` and all `workspace.yml` plumbing retired; suite green; changelog #32.

## Invariants to honor (from design §5)

INV-1 Level A carries only session-fixed info (detail → wrapped `cco`). INV-2 no generated
artifact in committed trees. INV-3 descriptions single-source in `project.yml`. INV-4 host
paths only in the runtime `path_map`, gated by `show_host_paths`.

## Deferred / open (recorded)

- **~~`read-project` mount narrowing~~ — CLOSED 2026-07-02 (`9e4535f`): narrowed.** The maintainer
  chose to narrow now (step 4b): `read-project` mounts only the project's referenced personal-store
  packs (ro), hiding `~/.cco/templates` + other/unreferenced packs. DATA/STATE-index/CACHE kept
  (needed for `cco list`; carry no template/other-pack content). Surfaced a follow-on **OPEN
  DISCUSSION** (awareness + scope-aware read verbs + CLI robustness) — see Progress above.
- **Language rule** (`.claude/rules/language.md`) → move from template interpolation into Level
  A/C injection (design §9 deferral).
