# WIP Handoff — Unit A cutover (ADR-0051 per-project scoping)

> **Transient WIP handoff for the next session.** Delete this file once the cutover
> commit lands green. Canonical detail for resuming the uncommitted cutover in a
> fresh session. Companion to the design [`implementation-handoff.md`](implementation-handoff.md)
> (the durable build brief) and memory `naming-workstream`.

## 0. Where you are

- **Branch**: `feat/naming/resource-management`. **NEVER push** (Mac pushes + runs
  `cco build`). Self-dev: `lib/`/`bin/` edits are NOT live in-session; run `bin/test`
  only.
- **HEAD** = `9b3a38d` (Unit **A.1**, committed, green). The **A.3+cutover+A.2**
  work is entirely in the **UNCOMMITTED working tree** (25 dirty files; host-mounted
  `.git` → it persists across `/clear` + container exit). **Do NOT commit until the
  suite is delta-green vs the 1238/7 baseline.**
- **Suite now**: `1242/18`. Of the 18, **`test_paths_symlink_safe_tool_root` is a
  PRE-EXISTING env artifact** (`mkdir: cannot stat '~/.cache/cco': Permission denied`,
  unrelated) and **`test_project_show_referenced_by`** fails at the A.1 baseline too
  (verified via git-stash) — so **16 are genuine cutover-tail regressions to fix**,
  all test-fixture/expectation updates (no systemic breakage remains).

## 1. Sequencing (maintainer-approved)

The handoff proposed atomic sub-commits (A.1 schema / A.2 migration / A.3 rethread).
The index is an **atomic semantic unit** — you cannot change `_index_get_path`'s
signature (~25 callers) and keep delta-green half-way. So: **A.1 = pure addition
(committed `9b3a38d`)**; **A.3+cutover+A.2 = ONE coherent green commit** (the WIP);
then **A.4**; then **Unit B**. The maintainer explicitly approved the single cutover.

## 2. What the cutover already does (in the working tree)

### `lib/index.sh`
- **v2 schema**: `_index_ensure_file` scaffolds `version: 2` with sections
  `projects`, `project_paths` (nested `<proj>:` → `<name>: "<abs>"`), `llms`
  (reserved, unused), `unscoped`. `_index_version` reads the version.
- **Transparent migration (A.2)**: `_index_migrate_if_needed` (called from
  `_index_ensure_file`, i.e. on the first host-side WRITE) → `_index_migrate_v1_to_v2`,
  which re-homes each flat `paths: <name>` under every project listing it as a member
  (a shared repo → independent per-project bindings, same path), orphans → `unscoped:`.
  NO `migrations/` script, NO `cco update`. Reads tolerate a still-v1 index (flat).
- **Public API now PROJECT-SCOPED** (all dual-schema: v2 branch → v1 flat fallback):
  - `_index_get_path <proj> <name>` → pp_get, **else `unscoped:` fallback**, else v1 flat.
  - `_index_get_path_any <name>` → first match across all projects, then unscoped —
    for the cross-project by-name sites (`cco sync --from`, `cco start --from`,
    config-editor `--repo`) that have no project in hand.
  - `_index_set_path <proj> <name> <path>`, `_index_remove_path <proj> <name>`
    (empty `<proj>` → unscoped), `_index_set_unscoped <name> <path>`.
  - `_index_path_conflicts <proj> <name> <path>` (AD5′ chokepoint, delegates to
    `_index_pp_conflicts`).
  - `_index_name_for_path <proj> <path>` (project bindings + unscoped fallback).
  - `_index_list_paths` (flattened name=path + unscoped — for the sibling-dir hint).
  - `_index_rename_project` now **also re-homes the project_paths block**.
  - `_index_repos_get_projects` **removed** (name-based reverse lookup retired);
    callers use `_index_paths_get_bindings` (path-based, added in A.1).
  - `_project_iter_members` threads the project into `_index_get_path`.
- **A.1 primitives (already committed)**: `_index_pp_{get,set,remove,remove_project,
  dump_project,dump_all}`, `_index_pp_conflicts`, `_index_paths_get_bindings`.

### Deliberate design decision — the `unscoped:` fallback
`_index_get_path`/`_index_name_for_path` fall back to the `unscoped:` bucket. This is
**NOT** the rejected "global-default layer among project bindings" (ADR-0051
Alternatives): `unscoped` is project-**less** (a `cco path set` pin made outside any
project). Per-project bindings **always win**; generic `assets` homonyms stay scoped
because `cco resolve` writes them per-project (never unscoped). The fallback is also
what lets ~100 legacy 2-arg test fixtures (which seed unscoped) keep resolving. Keep it.

### ~32 call-sites rethreaded (all done, verified)
`cmd-resolve` (unit/scan/render_status/path set+list), `local-paths`
(`_effective_repo_mounts`/`_effective_extra_mounts`/`_declared_unresolved_extra_mounts`/
`_resolve_entry_index`/`_project_effective_paths` — each derives `proj` from the
project.yml), `cmd-sync` (`--from`/target → `_any`, member loops scoped by `src_proj`),
`cmd-config` (`_cv_detect` idx_path record carries owning project in field **b**;
prune `_index_remove_path "$b" "$a"`), `cmd-forget` (shared-guard path-based; forget
removes the **whole** project_paths block via `_index_pp_remove_project`), `cmd-project-query`
(role + referenced-by path-based), `cmd-init` (uniqueness via membership+`_index_paths_get_bindings`
/ AD5′ `_index_path_conflicts`), `cmd-join`, `cmd-project-add`, `cmd-start` (594
config-editor `--repo` + 700 `--from` → `_any`), `migrate.sh` (1039–42 scoped),
`cmd-chrome` (65 → `_resolve_unit_dir_for_project`), `cmd-project-export-import`
(185 uniqueness / 214 scoped), `cmd-project-rename` (94 scoped).

### `cco path set` / `cco path list` (cmd-resolve)
- **set**: binds to the cwd's project if inside one, else the unscoped bucket; emits a
  name↔basename divergence hint (→ `cco repo rename`). ⚠ In tests, `run_cco` runs from
  the repo root (which IS a cco project) → use `_rsv_cco_in "<neutral-or-project-dir>"`
  to control which project is picked.
- **list**: iterates `_index_pp_dump_all` + unscoped; `[proj] name` label so homonyms
  stay distinct. **Unscoped rows are fed with the `__unscoped__` sentinel in the
  project column** — a genuinely empty leading TAB column is collapsed by `read`
  (TAB is IFS-whitespace), which corrupts parsing. Do NOT revert to an empty column.

### `migrations/global/016_normalize-index.sh`
Rewritten **v2-aware**: `_index_migrate_if_needed` (upgrade v1→v2) then normalize every
`project_paths` binding + the unscoped bucket (rewrite through the boundary; drop the
unrecoverable). Its test seeds a raw v1 index on disk and asserts the v2 result. This
crash had broken ALL `cco update` tests — now `test_update` is 92/0.

### Tests already updated GREEN
`test_index` (33/0), `test_local_paths` (7/0), `test_update` (92/0),
`test_operator_shim` seeds (scoped), `helpers.sh` `seed_index_path <name> <path>
[project]` (no project → unscoped bucket).

## 3. The 16 regressions to fix (fix approach per group)

Full list: `<scratchpad>/fails_wip.txt`; last full run `<scratchpad>/suite3.txt`.
Nearly all are **test-fixture seed / expectation** updates to the scoped model.

| Test(s) | Cause | Fix |
|---|---|---|
| `test_forget_*` ×5 (shared_repo_guard, deregisters_internal_state, self_heals_on_resolve_scan, purge_deletes_owned_cco_with_backup, purge_non_tty_without_flag_skips) | fixtures seed members via `seed_index_path "solo" …` → **unscoped**, but forget now removes the project_paths **block** (`_index_pp_remove_project`), leaving unscoped entries; also preview text changed ("KEEPING shared" → informational note). e.g. `test_forget_shared_repo_guard` asserts index NOT contains `solo:` but solo is unscoped. | Seed members **scoped** to their project: `seed_index_path solo "$path" <project>` (3rd arg). Then forget's block-removal clears them. Update any preview-text assertions to the new "…stay referenced by other projects…" wording. |
| `test_as_*` ×6 (list_compact_scoped/global/full, list_pack_degrades, list_llms_scoped, llms_show_used_by) | fixtures seed the index with the **old 2-arg** `_index_set_path` (unbound-var under `set -u` → index empty → `cco list` shows nothing; test saw alpha/p1/svelte missing). | In `tests/test_access_scope.sh` (and its `_as_*` setup helper): switch index seeds to the 3-arg scoped form (or `seed_index_path` with the project). Grep the file for `_index_set_path ` / direct index writes. |
| `test_config_validate_fix_prunes_with_yes` | `ghost-repo` seeded unscoped; `_cv_detect` emits an `idx_path` record for it with project field **b=""**; verify the unscoped detect+prune (`_index_remove_path "" ghost-repo`) actually fires and removes it. Assertion: index NOT contains `ghost-repo:` + "No orphaned internal state". | Debug `_cv_detect`'s unscoped loop + `_cv_prune_record idx_path` with empty project. Likely a small bug in the unscoped branch or the record's b-field plumbing. |
| `test_chrome_resolve_port_fallback_yml` | expected port 9300, got 9222 — `cmd-chrome` now resolves the project's repo dir via `_resolve_unit_dir_for_project`, which returns a **different** member's dir than before, so a different `project.yml` port is read. | Check the fixture's membership + which repo hosts the port-bearing `project.yml`; ensure the resolver returns the host repo (the one with `.cco/project.yml`). May need the fixture to seed membership so the host resolves first. |
| `test_resolve_scan_no_prune_keeps_stale_entries`, `test_resolve_cwd_first_resolves_and_records_membership` | 2 leftover in test_resolve — `cco path set` is now cwd-scoped. | Already partially fixed; run from the project dir via `_rsv_cco_in "$tmp/dev/<repo>"`, or expect the unscoped bucket. Re-run and adjust. |
| `test_sync_skips_target_hosting_different_project` | member seed uses old API / needs scoping. | Seed scoped; verify the D2 clobber-guard path. |
| `test_project_show_referenced_by` | **PRE-EXISTING** (fails at A.1 baseline). | Confirm it's the same pre-existing failure, not a new regression; likely leave as-is (baseline). |
| `test_paths_symlink_safe_tool_root` | **PRE-EXISTING env** (`~/.cache/cco` Permission denied). | Not ours — ignore. |

**Method**: fix a group, run `./bin/test --file <file>`, iterate. When all green
vs 1238/7 (i.e. only the true pre-existing artifacts remain), commit the cutover.

## 4. Commit message for the cutover (when green)

`feat(index): per-project name scoping cutover + transparent v1→v2 migration (ADR-0051 A.2/A.3)`
— body: v2 scoped schema, project-scoped path API + unscoped fallback + `_any`,
transparent migration, ~32 call-sites, migration 016 v2-aware, `_index_repos_get_projects`
retired. End with `Co-Authored-By: Claude <noreply@anthropic.com>`.

## 5. After the cutover is green — remaining Unit A + B

- **A.4 add-time disambiguation** (ADR-0051 D4): in init/join/resolve/import, when a
  name already exists in OTHER projects, surface the existing binding(s) and prompt
  **reuse-path vs new-path**; derive the existing binding's url via
  `git -C <path> remote get-url origin` and warn on divergence. Stop the cross-project
  refusal (now a non-collision). Tests: import-homonym (divergent url) + two generic
  `assets` mounts at different paths coexisting.
- **A.5 docs**: `changelog.yml` **BREAKING** entry (index v2 model), `docs/users/reference/cli.md`
  (index/resolve/path model), root `CLAUDE.md` if the index description changed. Also
  **clean up `lib/index.sh:38`** header comment (still lists the removed
  `_index_repos_get_projects`).
- **Unit B** (rename verbs, ADR-0050): follow [`design/design-resource-rename.md`](design/design-resource-rename.md)
  §8 steps — `lib/rename.sh`, `_index_rename_path <proj> <old> <new>`,
  `cco repo|extra-mount|pack|template|remote rename`, operator gating, quote-strip +
  divergence hint, docs+changelog. Only after Unit A is green.

## 6. Cross-cutting rules
Test-first; atomic delta-green commits; NEVER push (Mac pushes + `cco build`); don't
implement top-level `cco rename` or a global-default index layer (both rejected).
