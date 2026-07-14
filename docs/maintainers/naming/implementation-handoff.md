# Implementation Handoff — Resource Naming Workstream (Units A + B)

> **For the next session.** Design is complete and committed; this is the build brief.
> **Unit A is DONE and committed (2026-07-14) — start at Unit B (§4).** Read the Unit B
> reference docs (§1) first, then implement test-first with atomic commits. Communicate in
> Italian; docs/code-comments in English (user rules).

## 0. Where you are — ▶ RESUME AT UNIT B (§4)

- **Branch**: `feat/naming/resource-management` (do NOT branch off; continue here). **Not
  pushed** — the user pushes from the Mac. Never push.
- **Repo**: `/workspace/claude-orchestrator` (self-dev of `cco`).
- **✅ Unit A COMPLETE (ADR-0051, per-project name scoping)** — all committed on this branch:
  A.1 `9b3a38d` (v2 nested `project_paths` primitives), A.2+A.3 `fbb36fe` (schema cutover +
  transparent v1→v2 migration + ~32 call-sites), landing `0c549f9`, A.4 `5b7a7ed` (add-time
  disambiguation prompt + url-divergence flag), A.5 `8ac2ee3` (changelog #42 BREAKING + cli.md +
  CLAUDE.md), roadmap DONE `ac0aa4f`. **The index is now v2 project-scoped — Unit B builds on it.**
- **Test suite**: **1259/7** (`bin/test`). The 7 failures are **pre-existing IN-CONTAINER env
  artifacts** (6 `test_as_list_*` operator-mode store-resolution + `test_paths_symlink`
  `~/.cache/cco` perm) — they fail at the A.1 baseline too and pass on the host/Mac. **Keep every
  Unit B commit delta-green against this 7-failure set** (verify with a baseline-vs-change diff, not
  an absolute count). The design's original "1238/7" baseline predates the in-container test_as_*
  artifacts; ignore it — compare to the live in-container 7.
- **Self-dev caveat** (project CLAUDE.md): edits to `lib/`/`bin/` are **NOT live in this
  session**. You can run the test suite, but live dogfood needs `cco build && cco start` from the
  Mac (user's job). Do not try to `cco build` inside the container.
- **Pre-merge (Mac, after Unit B):** `cco build` + push both branches; merge→develop is gated on
  the e2e v2 acceptance run (see the hardening-v2 workstream), not on this branch alone.

## 1. Read these first (canonical design)

| Doc | What it gives you |
|---|---|
| [`decisions/0051-per-project-name-scoping.md`](decisions/0051-per-project-name-scoping.md) | **Unit A** decisions: path-is-identity, scoped index, chokepoint, add-time prompt, url signal, path-based reverse lookup, transparent migration (D6) |
| [`decisions/0050-resource-rename-model.md`](decisions/0050-resource-rename-model.md) | **Unit B** decisions: per-kind rename verbs, project-scoped path-anchored repo/extra_mount rename, operator gating, quote fix |
| [`design/design-resource-rename.md`](design/design-resource-rename.md) | Unit B CLI signatures, `lib/rename.sh` API, per-kind flow, test matrix, steps |
| [`analysis/resource-name-storage-map.md`](analysis/resource-name-storage-map.md) | The re-key surface (§3), **path-identity principle (§12)**, **scoping + index-consumer blast-radius (§13/§13.1)** |
| ADR-0031 (`configuration/decentralized-config/decisions/0031-project-rename-identity-rekey.md`) | The existing project-rename pattern both units generalize (strict-resolve, preview/confirm, git-delegated cross-repo edits) |

Load-bearing principle to keep in mind throughout: **for repo/extra_mount, the resource identity
is the host PATH; the name is a per-project label. Classify resource-sameness by PATH, never by
name** (analysis §12).

## 2. Sequencing (do NOT reorder)

**Unit A (per-project scoping) — ✅ DONE.** Its breaking index-v2 model is committed and green.
**▶ Now do Unit B (rename verbs, §4)**, which builds on Unit A's project-scoped index. Note the
index already has `_index_rename_project` (whole-project identity re-key, re-homes the `project_paths`
block); B.2's `_index_rename_path <project> <old> <new>` (rename a single NAME within one project) is
still to be written — it re-keys one `project_paths[project]` entry + the `projects:<project>` token.
Unit A §3 below is retained as reference for what Unit B builds on.

---

## 3. Unit A — per-project name scoping (ADR-0051)

Goal: repo/extra_mount names become scoped to their project. Index moves from global-flat
`paths: <name> → path` to `project_paths[project][name] → path`. Identity = path.

### A.1 Index schema + core primitives (`lib/index.sh`) — test-first

- New on-disk schema (ADR-0051 D2), `version: 2`:
  ```yaml
  version: 2
  projects: { <project>: "<name> <name> ..." }     # membership (names) — unchanged keys
  project_paths: { <project>: { <name>: <abs-path> } }   # NEW (replaces global paths:)
  llms: { <name>: <path> }                          # llms stay GLOBAL (out of scope)
  unscoped: { <name>: <path> }                      # orphan `cco path set` names (kept)
  ```
- **`_index_path_conflicts <project> <name> <path>`** — the single chokepoint (ADR-0051 D3).
  Conflict iff the **same project** already binds `name` to a **different** path. New invariant
  **AD5′**: within a project, one name→one path; same name may differ across projects; same path
  may carry different names across projects.
- Rethread the API to carry project context: `_index_get_path`, `_index_set_path`,
  `_index_remove_path` gain a `<project>` arg (or a scoped variant). Keep an explicitly-global
  accessor for **llms** (stays global) and for the transitional v1 fallback (A.2).
- **`_index_paths_get_bindings <path>`** (ADR-0051 D5) — path-based reverse lookup returning the
  `(project, name)` bindings resolving to `<path>`. **Replaces** `_index_repos_get_projects`.
- Unit-test the schema read/write, AD5′, and the reverse lookup before touching callers.

### A.2 Transparent in-index migration (ADR-0051 D6) — NO `migrations/` script, NO `cco update`

- Version-gated in-place self-upgrade inside `lib/index.sh`, run on the **first host-side index
  write** after the code is live. Idempotent (no-op once `version: 2`).
- Deterministic + lossless: names are globally unique today → each global `paths: <name>`
  re-homes under every project listing `<name>` as a member. Orphans → `unscoped:` (keep).
- **No hard cutover**: the resolver must read a still-`version: 1` index as global-flat
  (transitional fallback) so read-only/in-container sessions (can't write the index under the
  ADR-0047 privilege boundary) keep working until the next host-side write upgrades it.
- Backstop: `cco resolve --scan` rebuilds the scoped index. Add a `changelog.yml` **breaking**
  entry (notification only).
- Test: idempotency, losslessness (v1 fixture → v2 equals a `--scan` rebuild), orphan handling,
  and the both-schemas-readable transitional behavior.

### A.3 Rethread the ~32 index call-sites (analysis §13.1)

Thread project context through every consumer. Reference inventory (from the blast-radius audit):
- `_index_get_path` ~25 sites: ~17 need project context (`cmd-resolve.sh:70/217/240/423/434/667`,
  `cmd-sync.sh:178/200/214/233`, `cmd-start.sh:700`, `cmd-project-query.sh:75/98`,
  `cmd-project-rename.sh:94`, `local-paths.sh:191/236/268/283`, `cmd-init.sh:309`,
  `cmd-join.sh:170`, `cmd-project-add.sh:208`); **2 stay global** (`cmd-start.sh:594` llms — keep
  global); 3 misuse it on *project* names (`cmd-chrome.sh:65`, `cmd-init.sh:287`,
  `cmd-project-export-import.sh:185`) — clean up, project identity stays global.
- `_index_set_path` ~10 sites (init:393, join:170, project-add:208, resolve:542/667,
  local-paths:305, migrate:1042 — thread project; export-import:214 misuses project name).
- `_index_path_conflicts` 2 sites (resolve:537, migrate:1039) → pass the triple.
- `_index_repos_get_projects` 3 sites → switch to `_index_paths_get_bindings`:
  `cmd-forget.sh:44` (shared-resource guard is a **path** property), `cmd-project-query.sh:206`
  (referenced-by: other projects mounting this **path**, optionally show each alias),
  `cmd-resolve.sh:700`.
- `_index_list_paths` 3 sites (config:230, resolve:721, local-paths:296) → add a scope arg;
  decide per-caller whether it lists all projects or the current one.
- `_index_remove_path` 2 sites (config:282, forget:195) → thread project.
- **Unchanged**: `_index_*_project`, `_project_iter_members`, `_index_rename_project`
  (project keys stay globally unique) — but `_project_iter_members`' internal `_index_get_path`
  becomes project-scoped.

### A.4 Add-time disambiguation (ADR-0051 D4)

- In `init`/`join`/`resolve`/`import`, when binding `(project, name, path)` and `name` already
  exists in **other** projects, surface the existing binding(s) and prompt: **reuse an existing
  path** (same resource — this is the preserved (V) convenience, now explicit) **or specify a
  different path** (homonym).
- **URL divergence warning**: before offering reuse, derive the existing binding's url via
  `git -C <existing-path> remote get-url origin` and compare to the incoming `project.yml`
  coordinate `url`; if divergent → warn "probably a different resource". No url stored in the
  index. extra_mounts (no git remote) → prompt without the url signal.
- init/join stop refusing on a cross-project name match (now a non-collision); refuse only on a
  same-project same-name-different-path clash (AD5′ violation).
- Tests: the two motivating cases — (1) import a project whose `backend` collides with a
  different-url `backend` on the machine → warn + prompt; (2) two projects with a generic `assets`
  extra_mount at different paths → both coexist.

### A.5 Unit A done criteria

Suite delta-green vs 1238/7 (multi-project index tests updated to the scoped schema); the two
collision cases pass; migration tests pass; `changelog.yml` breaking entry added; docs touched:
`docs/users/reference/cli.md` (index/resolve model), root `CLAUDE.md` if the index description
changed. Commit atomically per sub-step (A.1 schema, A.2 migration, A.3 rethread — possibly split,
A.4 prompt).

---

## 4. Unit B — resource rename verbs (ADR-0050, built on Unit A)

Only after Unit A is green. Follow [`design/design-resource-rename.md`](design/design-resource-rename.md) §8 steps.

### B.1 Shared module `lib/rename.sh`
- `_yaml_rename_list_ref <file> <section> <old> <new>` (generalize `_llms_rename_in_yaml` to
  `repos`/`extra_mounts`/`packs`/`llms`; scalar **and** mapping forms; section-scoped). Test first.
- `_rename_validate <kind> <new>`, `_rename_preview_confirm`,
  `_rename_fanout_projectyml` (pack, cross-project), `_rename_projectyml_current`
  (repo/extra_mount, current project only, **path-matched**).

### B.2 Index primitive
- `_index_rename_path <project> <old> <new>` — **project-scoped** (re-key `project_paths[project]`
  + `projects:<project>` token; never other projects).

### B.3 Verbs (per-kind, thin wrappers)
- `cco repo rename [<old>] <new>` (`lib/cmd-repo.sh`, wire `repo)` in `bin/cco`): **project-scoped
  + path-anchored** — resolve current project + the member whose **path** matches `<old>`; re-key
  the current project's binding + `project.yml`; **no cross-project fan-out**; note if `<old>`
  also names a project (left untouched). Optional dir-move (basename-gated, default No,
  `--move-dir`; see ADR-0050 D4 / design §5).
- `cco extra-mount rename <old> <new>` (same, current project's `extra_mounts`).
- `cco pack rename <old> <new>` (`lib/cmd-pack.sh`): `mv ~/.cco/packs`, `pack.yml name:`, move
  DATA/STATE sidecars, `_tags_rename packs`, **cross-project `packs[]` fan-out** (pack names stay
  global — unaffected by Unit A).
- `cco template rename <old> <new>` (`lib/cmd-template.sh`): dir `mv` + sidecars + `_tags_rename`.
- `cco remote rename <old> <new>` (`lib/cmd-remote.sh`): re-key `DATA/remotes` + `STATE/remotes-token`.
- Align `_llms_rename` onto `_yaml_rename_list_ref` + add `_tags_rename llms`.

### B.4 Operator-shim gating (`bin/cco`, ADR-0050 D7)
- repo/extra-mount rename → **current-project** tree → allowed at `edit-project`.
- pack/template/remote rename → **global store** → require `edit-global`.
- Test: `edit-project` session refused `pack rename`, allowed `repo rename` (own project).

### B.5 Bundled UX fixes (ADR-0050 D8)
- **Quote strip**: in `_resolve_to_abs` (`lib/cmd-resolve.sh:36`) + interactive reads
  (`lib/local-paths.sh:141-147`), strip **one** pair of matched surrounding quotes (`'…'`/`"…"`)
  before absolutizing. Not full shell dequoting.
- **Divergence hint**: `cco path set`/`resolve` — after updating a path, if the (project-scoped)
  index name ≠ the directory basename, hint `cco repo rename`.

### B.6 Unit B done criteria
Test matrix in design §9: every store updated, **no stale refs**, kind-scoped isolation,
**project-scoped isolation** (repo rename in A leaves B's same-name-different-path binding and B's
same-path label untouched), pack ref fan-out across M projects, dir-move behavior, operator
gating, quote input, negatives. Additive `changelog.yml` entries; **no migration**. Docs:
`cli.md`, root `CLAUDE.md` Build & Run list, `cco *-rename --help`.

---

## 5. Cross-cutting rules (both units)

- **Test-first / TDD** (user workflow rule): write/adjust tests alongside each step; when a test
  fails, question the implementation, not the test.
- **Atomic commits**, conventional messages, delta-green each. End messages with
  `Co-Authored-By: Claude <noreply@anthropic.com>`.
- **Update-system discipline** (`.claude/rules/update-system.md`): Unit A = breaking → but
  migrated transparently in-index (NOT a `migrations/` script — see A.2) + breaking changelog
  entry; Unit B = additive → changelog entries, no migration.
- **Never push**; the user pushes from the Mac + runs `cco build`.
- **Roadmap**: update `docs/maintainers/roadmap.md` (naming Unit A/B rows) as each unit lands.
- **Don't** implement a top-level `cco rename` (rejected, ADR-0050 D1). **Don't** add a global-
  default layer to the index (rejected, ADR-0051 Alternatives). **Don't** touch llms global scope
  or project identity.

## 6. Suggested first action in the new session (Unit B)

`git log --oneline -8` (expect the Unit A commits `9b3a38d`…`ac0aa4f` on
`feat/naming/resource-management`) + read the Unit B reference docs (§1: ADR-0050 +
`design/design-resource-rename.md` §8 + analysis §3/§12/§13). Confirm the suite with `bin/test`:
expect **1259/7** — the 7 are the pre-existing in-container env artifacts (compare the FAIL set to
that baseline, not an absolute count). Then start **B.1** (`lib/rename.sh` shared module, test-first:
`_yaml_rename_list_ref` generalized from `_llms_rename_in_yaml`), then B.2 (`_index_rename_path`),
then the per-kind verbs (B.3), gating (B.4), UX fixes (B.5), docs (B.6). Pause for the user's
go-ahead if any design ambiguity surfaces (workflow rule: pause & discuss).
