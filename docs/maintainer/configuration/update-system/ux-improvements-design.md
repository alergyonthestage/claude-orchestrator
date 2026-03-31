# Update System — UX Improvements Design

**Date**: 2026-03-20
**Status**: Approved
**Related**: `ux-improvements-analysis.md` (problem analysis), `base-tracking-fix-design.md` (prior fix)

---

## 1. Overview

Three improvements to the update system UX, addressing a critical bug and
two design issues discovered during real-world usage.

| Phase | Problem | Solution |
|-------|---------|----------|
| 1 | `_save_base_version` in sync saves raw template → perpetual false MERGE_AVAILABLE | Thread `project_dir` through sync; save interpolated base |
| 2 | `--diff` dumps all diffs at once, no scope filtering | Summary by default; scoped drill-down |
| 3 | 3-way merge fails on heavily customized files (post-init-workspace) | Divergence detection → `USER_RESTRUCTURED` with (N)ew-file default |

Phase 4 (AI-assisted merge) is designed here for completeness but implemented
in a separate cycle.

---

## 2. Phase 1: Interpolated Templates in Sync (Bug Fix)

### 2.1 Problem

The base-tracking-fix (2026-03-18) corrected base seeding in `cco project create`,
`cco project install`, and `_handle_policy_transitions`. But `_interactive_sync`
still uses the raw template (with `{{PLACEHOLDER}}`) for:

1. **Base saves** — `_save_base_version "$base_dir" "$rel_path" "$defaults_dir/$rel_path"`
   saves `{{PROJECT_NAME}}` as base. Next run: `base_hash != new_hash` → perpetual
   false `MERGE_AVAILABLE`.
2. **File copy** — `cp "$defaults_dir/$rel_path" "$installed_dir/$rel_path"` writes
   `{{PROJECT_NAME}}` and `{{DESCRIPTION}}` to user's project files, corrupting them.
3. **Diff display** — `diff -u ... "$defaults_dir/$rel_path"` shows `{{PLACEHOLDER}}`
   to the user instead of actual values.
4. **3-way merge** — `_merge_file ... "$defaults_dir/$rel_path"` uses the raw template
   as "new version", producing spurious conflicts on placeholder lines.

The analysis (§1.1) documented problem #2 directly: *"user chose (R)eplace, which
**overwrote their customized CLAUDE.md with the raw skeleton template**"*.

### 2.2 Solution

Add `project_dir` as 8th parameter to `_interactive_sync`. When non-empty
(project scope), **all operations** use interpolated template copies.

**Scope-aware helpers** in `update-sync.sh` (for base saves and hash computation):

- `_save_base_for_scope(base_dir, rel_path, source, project_dir)`: saves
  interpolated base for project scope, direct copy for global.
- `_hash_for_scope(source, project_dir)`: returns hash of interpolated
  template for project scope, direct hash for global.

**Per-iteration interpolation** (for cp, diff, and merge operations):

At the start of each loop iteration in `_interactive_sync`, an interpolated
temp file is created and used for all file-facing operations:

```bash
local _is_new_file="$defaults_dir/$rel_path"
local _is_tmp=""
if [[ -n "$project_dir" && -f "$defaults_dir/$rel_path" ]]; then
    _is_tmp=$(_interpolate_template_tmp "$defaults_dir/$rel_path" "$project_dir")
    _is_new_file="$_is_tmp"
fi
# ... use $_is_new_file for cp, diff, merge; cleanup at end of iteration
[[ -n "$_is_tmp" ]] && rm -f "$_is_tmp"
```

The same pattern is applied in `_resolve_with_merge` (`_rwm_new_file`) and
`_resolve_conflict_interactive` (`_rci_new_file`) in `update-merge.sh`.

This mirrors the existing pattern in `_show_file_diffs` (`update-discovery.sh`),
which already interpolates correctly for `--diff` display.

### 2.3 Call Chain Threading

```
_update_global()          → _interactive_sync(..., "")
_update_project()         → _interactive_sync(..., "$project_dir")
_update_single_project()  → _interactive_sync(..., "$project_dir")
  └ _interactive_sync     → _resolve_with_merge(..., "$project_dir")
    └ _resolve_with_merge → _resolve_conflict_interactive(..., "$project_dir")
```

### 2.4 Operations Fixed

| Operation | File | Fix |
|-----------|------|-----|
| Base saves | `update-sync.sh` | `_save_base_for_scope` helper (interpolates internally) |
| Manifest hashes | `update-sync.sh` | `_hash_for_scope` helper (interpolates internally) |
| `cp` to installed file | `update-sync.sh` | `cp "$_is_new_file"` (9 occurrences across NEW, UPDATE, BASE_MISSING, MERGE, USER_RESTRUCTURED, DELETED_UPDATED cases) |
| `diff` display | `update-sync.sh` | `diff -u ... "$_is_new_file"` (6 occurrences, all interactive "d" prompts) |
| 3-way merge "new" | `update-merge.sh` | `_merge_file ... "$_rwm_new_file"` in `_resolve_with_merge` |
| Conflict replace | `update-merge.sh` | `cp "$_rwm_new_file"` and `cp "$_rci_new_file"` |

### 2.5 Files Modified

| File | Change |
|------|--------|
| `lib/update-sync.sh` | Add `project_dir` param; add helpers; per-iteration interpolated temp; replace all raw template operations |
| `lib/update-merge.sh` | Thread `project_dir`; add interpolation in `_resolve_with_merge` and `_resolve_conflict_interactive`; fix cp and merge operations |
| `lib/update.sh` | Pass `""` or `"$project_dir"` at call sites (lines ~227, ~562) |
| `lib/cmd-project-update.sh` | Pass project dir at line ~183 |

---

## 3. Phase 2: `--diff` Summary + Scope Filtering

### 3.1 Problem

`cco update --diff` dumps all diffs for all scopes consecutively. With multiple
projects and files, output is hundreds of lines with no navigation.

### 3.2 Solution

Change `--diff` default behavior:

| Command | Behavior |
|---------|----------|
| `cco update --diff` | Summary: file names + status per scope, no diff content |
| `cco update --diff <project>` | Full diffs for one project |
| `cco update --diff global` | Full diffs for global scope |
| `cco update --diff --all` | Full diffs for everything (old behavior) |

### 3.3 Summary Output Format

```
$ cco update --diff
Global: up to date

Project 'claude-orchestrator':
  CLAUDE.md — both modified (merge needed)

Project 'devops-toolkit':
  CLAUDE.md — framework updated (safe to apply)

2 file(s) with changes. Use 'cco update --diff <scope>' for details.
```

### 3.4 Implementation

New function `_show_file_diffs_summary()` in `update-discovery.sh`: iterates
change entries and prints file name + human-readable status (no diff content).

Argument parsing in `cmd-update.sh` extended with `--all` flag.

Routing in `_update_global` / `_update_project`: receive `diff_mode` parameter
("summary" | "full") and call appropriate display function.

### 3.5 Files Modified

| File | Change |
|------|--------|
| `lib/cmd-update.sh` | Parse `--all` flag; set `diff_mode` |
| `lib/update-discovery.sh` | Add `_show_file_diffs_summary()` |
| `lib/update.sh` | Thread `diff_mode` to display calls |

---

## 4. Phase 3: Divergence Detection (USER_RESTRUCTURED)

### 4.1 Problem

After `/init-workspace`, CLAUDE.md grows from a 17-line skeleton to 100+
lines of project-specific content. 3-way merge between skeleton base and
rich document always produces conflicts on every section.

### 4.2 Solution

Detect divergence in `_collect_file_changes`. When both sides changed
(`MERGE_AVAILABLE` candidate) AND installed file is >3x the base line count,
classify as `USER_RESTRUCTURED`.

### 4.3 New Status: USER_RESTRUCTURED

| Status | Meaning | Default Action |
|--------|---------|----------------|
| `MERGE_AVAILABLE` | Both changed, similar structure | (M)erge 3-way |
| `USER_RESTRUCTURED` | Both changed, heavily diverged | (N)ew-file |

### 4.4 Sync UX for USER_RESTRUCTURED

```
ℹ Project 'myapp': CLAUDE.md (heavily customized — text merge unlikely to help)
  (N)ew-file (.new)  (K)eep yours  (R)eplace + .bak  (S)kip  (D)iff
  Tip: saves framework version as .new for manual review
  Choice [N/k/r/s/d]:
```

No (M)erge option offered. (N) is the default — saves the framework version
as `.new` alongside the user's file for manual review.

### 4.5 Base Update Behavior

Regardless of user choice, the base is updated to the current interpolated
template. On next `cco update`:
- Template unchanged → `USER_MODIFIED` (silent)
- Template changed → `USER_RESTRUCTURED` again with new delta

### 4.6 Files Modified

| File | Change |
|------|--------|
| `lib/update-discovery.sh` | Divergence check in `_collect_file_changes`; handle in `_show_discovery_summary`, `_show_file_diffs`, `_show_file_diffs_summary` |
| `lib/update-sync.sh` | `USER_RESTRUCTURED` case with (N) default |

---

## 5. Phase 4: AI-Assisted Merge (Design Only)

Documented for completeness. Implemented in a separate cycle.

### 5.1 Concept

Add (I) AI-merge option for `.md` files in `MERGE_AVAILABLE` sync.
Claude understands document semantics and can intelligently combine
user content with framework updates.

### 5.2 Execution

Fallback chain:
1. `claude` on host PATH → direct execution
2. cco Docker image → `docker run --rm` with merge prompt
3. Neither → option hidden from menu

### 5.3 Scope

- New `lib/ai-merge.sh` module
- Only for `MERGE_AVAILABLE` (not `USER_RESTRUCTURED`)
- User reviews result before acceptance
- Only `.md` files (not JSON/YAML)

---

## 6. Verification

### Tests

| # | Phase | Test |
|---|-------|------|
| 1 | P1 | Sync saves interpolated base (no `{{PROJECT_NAME}}` in `.cco/base/`) |
| 2 | P1 | No false positive after sync (`NO_UPDATE` or `USER_MODIFIED`) |
| 3 | P1 | Global scope unaffected (direct base save) |
| 4 | P1 | Manifest hash matches interpolated template hash |
| 5a | P1 | Replace/Apply installs interpolated file (no `{{PLACEHOLDER}}` in installed) |
| 5b | P1 | Diff display shows interpolated values (no `{{PLACEHOLDER}}`) |
| 5c | P1 | 3-way merge uses interpolated "new" version |
| 5d | P1 | New-file (.new) contains interpolated content |
| 5 | P2 | `--diff` without scope shows summary (no diff content) |
| 6 | P2 | `--diff <project>` shows scoped diffs |
| 7 | P2 | `--diff --all` shows all diffs (backward compat) |
| 8 | P3 | File >3x base → `USER_RESTRUCTURED` |
| 9 | P3 | File similar size → `MERGE_AVAILABLE` |
| 10 | P3 | `USER_RESTRUCTURED` sync defaults to (N) |
