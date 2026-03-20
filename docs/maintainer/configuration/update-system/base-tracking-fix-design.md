# Update System — Base Tracking Fix Design

**Date**: 2026-03-18
**Status**: Implemented — extended by `ux-improvements-design.md` Phase 1
**Related**: `design.md` (update system design), `../../decisions/framework-improvements.md` (FI-7), `ux-improvements-design.md` (Phase 1 completes the sync-path fix)

---

## 1. Bug Discovery & Analysis

### 1.1 Symptoms

`cco update --diff` reports false positives for **every project** with customized
CLAUDE.md files. All projects show `BASE_MISSING` status and display diffs comparing
user-written content against the raw template with unresolved `{{PLACEHOLDER}}` markers.

```
ℹ Project 'cave-auth': opinionated updates available:
ℹ   1 file(s) with missing base (BASE_MISSING)
```

The diff output shows:

```diff
--- your version
+++ new default
-# Project: cave-auth
+# Project: {{PROJECT_NAME}}

 ## Overview
+{{DESCRIPTION}}
-Cave Auth è il sistema di autenticazione centralizzato...
```

This occurs for **all** projects created via `cco project create` from the base template.

### 1.2 Impact

- Users see spurious update notifications on every `cco update`
- `cco update --sync` would offer to replace customized CLAUDE.md with the raw template
- Trust in the update system is undermined — users learn to ignore notifications
- `cco project publish` warns about "unapplied framework defaults" (false alarm)

### 1.3 Root Causes (two co-occurring bugs)

**Bug 1 (primary) — CLAUDE.md missing from base**: CLAUDE.md was changed from
`untracked` to `tracked` in `PROJECT_FILE_POLICIES` on 2026-03-17 (commit
`ac81cc4`). All existing projects were created before this change, so their
`.cco/base/` never included CLAUDE.md. **No migration was added** to seed
`.cco/base/CLAUDE.md` for existing projects when the policy changed.

Evidence: every project's `.cco/base/` contains only `settings.json` (which was
always tracked), never `CLAUDE.md`:

```
cave-auth/.cco/base/       → settings.json only
caveresistance-server/.cco/base/ → settings.json only
claude-orchestrator/.cco/base/   → settings.json only
marius/.cco/base/                → settings.json only
testing/.cco/base/               → settings.json only
```

**Bug 2 (latent) — Base saved from raw template**: `cmd_project_create()`
(`lib/cmd-project-create.sh`) passes the raw template directory (with
`{{PLACEHOLDER}}`) to `_save_all_base_versions`. For projects created **after**
the policy change, the base would contain raw placeholders
(`# Project: {{PROJECT_NAME}}`), making the three-way merge incorrect. This bug
affects new project creation but hasn't been observed yet because all current
projects predate the policy change (Bug 1 masks Bug 2).

**Combined effect**: `base_hash` is empty (CLAUDE.md not in `.cco/base/`) →
`_collect_file_changes` falls into the `BASE_MISSING` branch → compares raw
template hash against installed hash → always different → false positive for
every project.

### 1.4 Affected Flows

**`cco project create`** (all templates with placeholders):

| Template | Placeholders in CLAUDE.md | Affected? |
|----------|--------------------------|-----------|
| `project/base` | `{{PROJECT_NAME}}`, `{{DESCRIPTION}}`, `cc-{{PROJECT_NAME}}` | **Yes** |
| `project/config-editor` | `{{PROJECT_NAME}}` (description hardcoded) | **Yes** |
| `internal/tutorial` | None (all hardcoded) | No |
| User templates | Depends on content | If they use `{{...}}` in tracked files |

**`cco project install`** (remote): Remote-installed projects fall back to
`templates/project/base/.claude` for opinionated file comparison. Same bug
applies: raw template with placeholders vs interpolated user content.

**`cco update --diff` / `cco update --sync`**: Both use `_collect_file_changes`
which reads the base. With missing/raw base, classification is wrong — should be
`USER_MODIFIED` or `NO_UPDATE`, reports `BASE_MISSING` instead. Three-way merge
is impossible without a correct base.

**`cco project publish`** (alignment check): `_collect_file_changes` is called
before publishing. False `BASE_MISSING` results trigger a warning that blocks
the publish flow.

### 1.5 Template and Placeholder Inventory

| Placeholder | Used in | Recoverable at update? |
|---|---|---|
| `{{PROJECT_NAME}}` | base CLAUDE.md, base project.yml, config-editor CLAUDE.md, config-editor project.yml | **Yes** — always = directory name |
| `{{DESCRIPTION}}` | base CLAUDE.md, base project.yml | **Partial** — stored in `project.yml`, but often stale |
| `{{CCO_REPO_ROOT}}` | config-editor project.yml, tutorial project.yml | **Yes** — runtime path |
| `{{CCO_USER_CONFIG_DIR}}` | config-editor project.yml, tutorial project.yml | **Yes** — runtime path |

**Key insight**: `{{DESCRIPTION}}` is user content, not framework structure. After
creation, users replace the entire Overview section with rich, project-specific
content. The original placeholder value becomes irrelevant and **cannot be
reliably re-interpolated** at update time.

### 1.6 Approaches Evaluated

**Path A — Fix base tracking**: Save interpolated base instead of raw template.
Add migration for existing projects. Correct by construction; covers all template
types uniformly. Requires migration for existing projects.

**Path B — Interpolate templates at update-time**: Resolve `{{PLACEHOLDER}}` in
the template before diffing. Low feasibility: `{{DESCRIPTION}}` is often
stale/wrong, custom templates may have arbitrary placeholders.

**Path C (chosen) — Path A + minimal safety net from Path B**: Fix base tracking
(Path A) plus a lightweight guard that interpolates `{{PROJECT_NAME}}` in the
template before hashing during `_collect_file_changes`. Correct base tracking +
defense in depth with ~5 lines of safety net code.

### 1.7 Affected Components

| Component | File | Function | Issue |
|---|---|---|---|
| Project create | `lib/cmd-project-create.sh` | `cmd_project_create()` | Saves base from raw template |
| Project install | `lib/cmd-project-install.sh` | `cmd_project_install()` | Saves base from raw remote template |
| Migration 007 | `migrations/project/007_*.sh` | `migrate()` | Same raw-template bug (but guarded — won't re-run) |
| Change detection | `lib/update-discovery.sh` | `_collect_file_changes()` | Hashes raw template → false BASE_MISSING |

---

## 2. Design: Path A + Safety Net

### 2.1 Fix 1 — Save interpolated base on `cco project create`

**Change**: In `cmd_project_create()` (`lib/cmd-project-create.sh`), save base
from the **project directory** (which has already been interpolated) instead of
from the raw template directory.

```bash
# BEFORE (in cmd_project_create()):
_save_all_base_versions "$project_dir/.cco/base" "$defaults_dir" "project"

# AFTER:
_save_all_base_versions "$project_dir/.cco/base" "$project_dir/.claude" "project"
```

**Rationale**: At this point in `cmd_project_create()`, the project files have
already been interpolated. The `.claude/` directory in the project IS the
interpolated template. This is exactly what the base should be: "what the
framework gave the user at creation time".

**Impact on meta manifest**: The manifest generation in `cmd_project_create()`
already hashes from `$project_dir/.claude/$rel` (the interpolated copy). No
change needed there.

### 2.2 Fix 2 — Save interpolated base on `cco project install`

**Change**: In `cmd_project_install()` (`lib/cmd-project-install.sh`), save base
from the installed project directory rather than the remote template directory.

```bash
# BEFORE (in cmd_project_install()):
_save_all_base_versions "$project_base_dir" "$template_dir/.claude" "project"

# AFTER:
_save_all_base_versions "$project_base_dir" "$target_dir/.claude" "project"
```

**Rationale**: Remote templates may also contain placeholders (`{{PROJECT_NAME}}`
is substituted during install). The installed copy is the interpolated result.

**Note**: Remote templates from Config Repos go through the same `sed`
substitution flow in `cmd_project_install()`. After substitution, the target
directory contains the interpolated files.

### 2.3 ~~Fix 3 — Migration 011~~ → Handled by automatic policy transitions

**Original design**: A migration to seed `.cco/base/CLAUDE.md` for existing
projects. **Removed** — the automatic policy transition handler (§2.5) handles
this case without a dedicated migration:

1. `_handle_policy_transitions` runs before `_collect_file_changes` in **all**
   modes (including `--diff` and `--dry-run`)
2. On first run, it detects no saved `policies:` section in `.cco/meta`
   (bootstrap path)
3. For each `tracked` file without a base entry, it seeds the base via
   `_seed_base_from_interpolated_template`
4. It persists the current policies to `.cco/meta` directly

This eliminates the need for a one-off migration and establishes the pattern
that **policy transitions never require migrations** — they are self-healing.

**Why synthetic base works**: The base represents "what the framework gave the
user". For existing projects, the transition handler reconstructs this from the
current template + known values (`PROJECT_NAME` from directory, `DESCRIPTION`
from `project.yml`). The result:

- `base` = current template interpolated with project name + description
- `new` = same template (no framework change since base was seeded)
- `installed` = user's customized version

Three-way comparison: `base == new` → status is `USER_MODIFIED` (or `NO_UPDATE`
if user hasn't changed it). Correct — no false `BASE_MISSING`.

When the framework later updates the template, `new ≠ base` → correctly
detected as `UPDATE_AVAILABLE` or `MERGE_AVAILABLE`.

### 2.4 Safety Net — Interpolate `{{PROJECT_NAME}}` in change detection

A lightweight guard in `_collect_file_changes` that interpolates
`{{PROJECT_NAME}}` in the template file before hashing. This catches edge cases
where the base might be absent, corrupted, or the template still has residual
placeholders.

**Location**: `lib/update-discovery.sh`, inside `_collect_file_changes()`, before
computing `new_hash`.

```bash
# In _collect_file_changes(), before computing new_hash:
# Compute new_hash with placeholder interpolation for project scope
if [[ "$scope" == "project" ]]; then
    local project_name
    project_name=$(basename "$(dirname "$installed_dir")")
    local tmp_new
    tmp_new=$(mktemp)
    sed "s/{{PROJECT_NAME}}/$project_name/g" "$defaults_dir/$rel" > "$tmp_new"
    new_hash=$(_file_hash "$tmp_new")
    rm -f "$tmp_new"
else
    new_hash=$(_file_hash "$defaults_dir/$rel")
fi
```

**Why only `{{PROJECT_NAME}}`**: This is the only placeholder that is:
1. Always recoverable (= directory name)
2. Part of framework structure (section headers, network names)
3. Present in templates that could reach `_collect_file_changes`

`{{DESCRIPTION}}` is deliberately **not** interpolated here because:
- It's user content, not framework structure
- The value in `project.yml` is often stale
- With a correct base (Fix 1-3), the three-way merge handles it correctly

**Performance**: One `sed` + one `sha256sum` per tracked file per project.
Currently 2 tracked files × N projects. Negligible overhead.

### 2.5 Automatic Policy Transition Detection

To prevent this class of bug from recurring, the update engine should
automatically detect when a file's policy changes between the version that
was active when the project was last updated and the current code.

#### Problem

When a file changes from `untracked → tracked` (or any other policy
transition), existing projects need their `.cco/base/` updated. Today this
requires a hand-written migration — easy to forget, as Bug 1 demonstrated.

#### Design

**Persist active policies in `.cco/meta`**. When `_generate_project_cco_meta`
writes the meta file, include a `policies:` section alongside the existing
`manifest:` section:

```yaml
# .cco/meta (project scope)
schema_version: 11
created_at: 2026-03-13T18:22:31Z
updated_at: 2026-03-18T10:00:00Z

template: base

policies:
  CLAUDE.md: tracked
  settings.json: tracked
  rules/language.md: untracked

manifest:
  CLAUDE.md: 22cb3d1ed0550...
  settings.json: e4a7df7b8d52...
```

**Detect transitions in `_update_project`**. Before running
`_collect_file_changes`, compare saved policies against current
`PROJECT_FILE_POLICIES`. Handle each transition type:

```bash
_handle_policy_transitions() {
    local project_dir="$1"
    local meta_file="$2"
    local base_dir="$3"
    local defaults_dir="$4"

    local entry rel policy saved_policy
    for entry in "${PROJECT_FILE_POLICIES[@]}"; do
        rel="${entry%:*}"
        policy="${entry##*:}"
        rel="${rel#.claude/}"

        # Read saved policy from .cco/meta (empty if not present)
        saved_policy=$(yml_get "$meta_file" "policies.$rel" 2>/dev/null) || true

        # No saved policy = first run with policy tracking → treat as transition
        # from whatever the implicit default was
        if [[ -z "$saved_policy" ]]; then
            # For the initial rollout: if base file is missing and policy is
            # tracked, seed the base now (same as untracked→tracked transition)
            if [[ "$policy" == "tracked" && ! -f "$base_dir/$rel" ]]; then
                _seed_base_from_interpolated_template \
                    "$base_dir" "$rel" "$defaults_dir" "$project_dir"
            fi
            continue
        fi

        # Detect actual transition
        [[ "$saved_policy" == "$policy" ]] && continue

        case "${saved_policy}→${policy}" in
            "untracked→tracked")
                # File was user-owned, now framework wants to track it.
                # Seed base from interpolated template so 3-way merge works.
                _seed_base_from_interpolated_template \
                    "$base_dir" "$rel" "$defaults_dir" "$project_dir"
                ;;
            "tracked→untracked")
                # Framework no longer tracks this file. Remove base entry.
                rm -f "$base_dir/$rel"
                ;;
            "generated→tracked")
                # Was regenerated, now user-customizable with merge support.
                # Save current installed version as base.
                if [[ -f "$project_dir/.claude/$rel" ]]; then
                    _save_base_version "$base_dir" "$rel" \
                        "$project_dir/.claude/$rel"
                fi
                ;;
            "tracked→generated")
                # Now auto-regenerated. Remove base (no merge needed).
                rm -f "$base_dir/$rel"
                ;;
            *)
                # Other transitions (untracked↔generated, etc.)
                # No base action needed.
                ;;
        esac
    done
}
```

**`_seed_base_from_interpolated_template`** — shared helper for seeding base
from an interpolated template. Used by both the migration (2.3) and the
automatic transition handler:

```bash
_seed_base_from_interpolated_template() {
    local base_dir="$1"
    local rel="$2"
    local defaults_dir="$3"
    local project_dir="$4"

    local template_file="$defaults_dir/$rel"
    [[ -f "$template_file" ]] || return 0

    local project_name
    project_name=$(basename "$project_dir")

    mkdir -p "$(dirname "$base_dir/$rel")"
    cp "$template_file" "$base_dir/$rel"

    # Interpolate recoverable placeholders
    sed -i "s/{{PROJECT_NAME}}/$project_name/g" "$base_dir/$rel"

    # Interpolate DESCRIPTION from project.yml if available
    local description="TODO: Add project description"
    local project_yml="$project_dir/project.yml"
    if [[ -f "$project_yml" ]]; then
        local yml_desc
        yml_desc=$(grep '^description:' "$project_yml" \
            | sed 's/^description: *//; s/^"//; s/"$//')
        [[ -n "$yml_desc" ]] && description="$yml_desc"
    fi
    sed -i "s/{{DESCRIPTION}}/$description/g" "$base_dir/$rel"
}
```

**Save updated policies after each update**. When `_generate_project_cco_meta`
writes the meta file, include the current policies. This persists the snapshot
so the next run can detect future transitions.

#### What this automates vs what still needs manual migration

**Automatic (no migration needed):**

| Transition | Action | Rationale |
|---|---|---|
| `untracked → tracked` | Seed base from interpolated template | Framework now tracks; need base for 3-way merge |
| `tracked → untracked` | Remove base entry | Framework stops tracking; base is unnecessary |
| `generated → tracked` | Save installed version as base | Transition from auto-regen to user-owned merge |
| `tracked → generated` | Remove base | Transition from merge to auto-regen |

**Manual migration still required:**

| Change | Why automation can't handle it |
|---|---|
| **New file added to policy list** | File may not exist in user's project; may need scaffolding, not just base seeding |
| **File removed from policy list** | May need cleanup of orphaned base entries, or user notification |
| **File renamed/moved** (e.g., `rules/foo.md` → `rules/bar.md`) | Automation doesn't know the old→new mapping |
| **Template structural changes** (e.g., YAML schema migration) | Content-level transformation, not just policy |
| **`.cco/meta` schema changes** | Meta format itself changed |

#### Migration 011: Bootstrap policy tracking

The migration seeds both the missing CLAUDE.md base (Fix 3 from §2.3) AND
initializes the `policies:` section in `.cco/meta`, so that future transitions
are automatically detected. See §2.3 for the base seeding logic; additionally:

```bash
# In migration 011, after seeding CLAUDE.md base:

# Initialize policies section in .cco/meta for transition detection
local meta_file="$target_dir/.cco/meta"
if [[ -f "$meta_file" ]]; then
    # Record current policies so future changes are detected
    local entry rel policy
    for entry in "${PROJECT_FILE_POLICIES[@]}"; do
        rel="${entry%:*}"
        policy="${entry##*:}"
        rel="${rel#.claude/}"
        yml_set "$meta_file" "policies.$rel" "$policy"
    done
fi
```

---

## 3. Files to Modify

| File | Change | Type |
|---|---|---|
| `lib/cmd-project-create.sh` | Save base from `$project_dir/.claude` in `cmd_project_create()` | Bug fix |
| `lib/cmd-project-install.sh` | Save base from `$target_dir/.claude` in `cmd_project_install()` | Bug fix |
| `lib/update-hash-io.sh` | Add `_seed_base_from_interpolated_template()` helper | Helper |
| `lib/update-discovery.sh` | Add `_handle_policy_transitions()` with self-persisting policies | Policy automation |
| `lib/update-discovery.sh` | Interpolate `{{PROJECT_NAME}}` before hashing in `_collect_file_changes()` | Safety net |
| `lib/update-meta.sh` | Write `policies:` section in `_generate_cco_meta()` and `_generate_project_cco_meta()` | Policy persistence |
| `lib/update.sh` | Call `_handle_policy_transitions()` unconditionally before `_collect_file_changes()` | Integration |
| `.claude/rules/update-system.md` | Document policy change rules | Rule update |

**No migration needed**: `_handle_policy_transitions` is self-bootstrapping.

---

## 4. Edge Cases

### 4.1 Non-base templates (config-editor)

Config-editor's CLAUDE.md has `{{PROJECT_NAME}}` but hardcoded description.
Fix 1 handles it: base is saved from the interpolated project directory
regardless of template type.

The safety net also works: `{{PROJECT_NAME}}` is the only placeholder in
config-editor's CLAUDE.md.

### 4.2 Tutorial (internal)

Tutorial CLAUDE.md has no placeholders. All content is hardcoded.
No impact from any of the fixes.

### 4.3 Remote-installed projects

Fix 2 saves base from the installed (interpolated) copy. The safety net also
applies at update-time when comparing against the base template fallback.

### 4.4 User-created templates

User templates may use `{{PROJECT_NAME}}` and `{{DESCRIPTION}}` (or not).
Fix 1 covers them: base is always saved from the interpolated project directory.
The safety net handles `{{PROJECT_NAME}}` if the user template uses it.

### 4.5 Projects where user didn't customize CLAUDE.md

If the user left the CLAUDE.md as-is after creation (e.g., `testing` project
with `TODO: Add project description`), the migration creates a base that matches
the installed file → status = `NO_UPDATE`. Correct.

### 4.6 Projects where agent heavily customized CLAUDE.md

If `/init-workspace` or manual editing replaced the entire content (e.g.,
`cave-auth`), the migration creates a base from the template, and the installed
file diverges heavily → status = `USER_MODIFIED`. When the framework later
updates the template → `MERGE_AVAILABLE` with three-way merge support. Correct.

### 4.7 `_show_file_diffs` for BASE_MISSING (display improvement)

Currently, when `--diff` shows diffs for `BASE_MISSING` files, it compares the
raw template against the user's file. After the migration runs, there should be
no more `BASE_MISSING` for CLAUDE.md. However, if other files become tracked in
the future, the same issue could recur.

**Recommendation**: When displaying diffs for `BASE_MISSING` in project scope,
apply the same `{{PROJECT_NAME}}` interpolation to the displayed diff. This
prevents confusing placeholder diffs even before a migration runs.

### 4.8 Policy transition: first run after migration 011

On the first `cco update` after migration 011, `_handle_policy_transitions`
reads `.cco/meta` and finds the newly-written `policies:` section. All policies
match the current code → no transitions detected. Correct.

### 4.9 Policy transition: .cco/meta without `policies:` section (pre-011 projects)

If a project's `.cco/meta` was written before migration 011 (no `policies:`
section), `yml_get` returns empty for all policy lookups. The handler treats
this as "first run with policy tracking" and seeds any missing bases. This is
the bootstrap path — equivalent to what migration 011 does, providing a
redundant safety layer.

### 4.10 Global scope policy transitions

The same mechanism applies to global scope. `_generate_cco_meta` should also
write a `policies:` section for `GLOBAL_FILE_POLICIES`. The transition handler
should work for both scopes by parameterizing the policy array.

### 4.11 Future: adding a new file to policy list

If a developer adds a new entry like `.claude/rules/security.md:tracked` to
`PROJECT_FILE_POLICIES`, the automatic system:
- Detects no saved policy for `rules/security.md` (empty)
- Checks if policy is `tracked` and base is missing → seeds from template
- This works **only if** the template already contains the file

If the file doesn't exist in the template OR needs to be scaffolded from
scratch in user projects → manual migration is still needed.

---

## 5. Testing Strategy

### Unit tests — base tracking fixes

1. **New project base contains interpolated CLAUDE.md**: Create project, verify
   `.cco/base/CLAUDE.md` has `# Project: test-project` (not `{{PROJECT_NAME}}`)
2. **Installed project base contains interpolated CLAUDE.md**: Install from mock
   remote, verify base is interpolated
3. **Safety net prevents false positive**: Mock a scenario where base is missing
   and template has `{{PROJECT_NAME}}`, verify no `BASE_MISSING` if the only
   difference is the project name substitution

### Unit tests — policy transitions

6. **`untracked → tracked` seeds base**: Create project with CLAUDE.md as
   untracked, change policy to tracked, run update. Verify base is seeded
   from interpolated template.
7. **`tracked → untracked` removes base**: Create project with tracked file,
   change to untracked, run update. Verify base entry is removed.
8. **`generated → tracked` saves installed as base**: Simulate transition,
   verify current installed file becomes the base.
9. **`tracked → generated` removes base**: Simulate, verify base removed.
10. **No saved policies (bootstrap)**: Project with no `policies:` in meta.
    Verify missing bases are seeded for tracked files.
11. **Same policy = no action**: Verify no base changes when policies match.
12. **Policies section written to meta after update**: Verify `.cco/meta`
    contains `policies:` section after `cco update` runs.

### Integration tests

13. **`cco update --diff` shows no false positives**: After migration, verify
    customized projects show `USER_MODIFIED` (not `BASE_MISSING`)
14. **`cco update --diff` detects real template changes**: Modify the base
    template, verify `UPDATE_AVAILABLE` or `MERGE_AVAILABLE` is detected
15. **`cco project publish` alignment check**: Verify no false warnings after fix
16. **Policy change without migration**: Change a file's policy in code, run
    `cco update` on existing project. Verify the transition is handled
    automatically without a dedicated migration.

---

## 6. Rollout

1. Fixes 1-2 (`cmd-project-create.sh`, `cmd-project-install.sh`) affect only **new** projects/installs
2. `_handle_policy_transitions` self-heals **existing** projects on any
   `cco update` variant (including `--diff` and `--dry-run`)
3. Safety net provides defense-in-depth for any residual edge cases
4. Policy transition handler provides future-proofing for all policy changes
5. Changelog entry: not needed (bug fix, not new feature)
6. **No breaking changes**: Only `.cco/base/` and `.cco/meta` are modified
   (framework metadata). No user files are touched.
7. **No migration needed**: The transition handler is self-bootstrapping

### Execution order within `_update_project`

```
1. Run pending migrations (if any)
2. _handle_policy_transitions()   ← NEW: detect & handle policy changes, persist to meta
3. _collect_file_changes()        ← existing: now has correct base + safety net
4. _show_file_diffs / _interactive_sync  ← existing: display/apply
5. _generate_project_cco_meta()   ← updated: writes policies: section (redundant with #2 but consistent)
6. _save_all_base_versions()      ← existing: after sync applied
```

---

## 7. Cleanup

After this fix is implemented:

- ~~Remove `docs/maintainer/placeholder-interpolation-path-b-analysis.md`~~
  Already removed
- ~~Merge bug analysis into this document~~
  Done — analysis content integrated into §1 (2026-03-19)
- Consider whether `BASE_MISSING` status should trigger the safety net
  interpolation automatically in `_show_file_diffs` (display-level improvement)
- Update `docs/maintainer/configuration/update-system/design.md` to document
  policy transitions as a first-class update system concept
- Update `docs/maintainer/configuration/update-system/analysis.md` to include
  policy transitions in the resource taxonomy
