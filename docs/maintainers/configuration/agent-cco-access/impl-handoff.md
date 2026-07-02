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
- **▶ Steps 3–7 — PENDING.** Descriptions in `project.yml` template+docs (3), config-editor UX (4),
  managed Level-C rule (5), migration 014 + `packs.md`-reappearance investigation (6), docs cutover
  (CLAUDE.md/cli.md/context-hierarchy enum+default+no-workspace.yml) + changelog #32 (7).

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

3. **Descriptions in `project.yml` (additive).** Add optional `repos[].description`,
   `extra_mounts[].description`; update `templates/project/base/project.yml` +
   `docs/users/configuration/reference/project-yaml.md`; the Level-A generator renders them.
   **changelog #32.** No migration (optional fields). Tests: descriptions flow into context.

4. **config-editor UX redesign.** Rework `_start_collect_config_editor_targets` +
   `_setup_internal_config_editor` + mount generation: bare = all resolvable `<repo>/.cco`
   + `~/.cco` (no repos); `--project` narrows + **mounts that project's repos**; `--repo`
   adds one. Update the preset + built-in CLAUDE.md/config-safety + user guide
   `docs/users/internal-projects/guides/config-editor.md` + `cli.md`. Tests: bare mounts all
   `.cco` no repos; `--project` mounts `.cco` + repos; `--repo` adds one; unresolved skipped.

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

## Deferred (recorded, not this sprint)

Language rule (`.claude/rules/language.md`) → move from template interpolation into Level
A/C injection (design §9 deferral).
