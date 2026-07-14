#!/usr/bin/env bash
# tests/test_index.sh — machine-local STATE index (T2: ADR-0016 D4 / 0022 D2)
#
# The index subsumes @local + per-repo local-paths.yml: logical name → absolute
# path (paths:) and project → member repos (projects:), in <state>/cco/index.

# Each test runs in its own subshell (bin/test) so these exports do not leak.
_index_test_env() {
    export CCO_ALLOW_HOST_RESOLVE=1
    export CCO_STATE_HOME="$1"
    unset XDG_STATE_HOME CCO_DATA_HOME CCO_CACHE_HOME
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/index.sh"
}

test_index_set_get_roundtrip() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path repo1 /Users/me/dev/repo1
    local got; got=$(_index_get_path repo1)
    [[ "$got" == "/Users/me/dev/repo1" ]] || fail "Roundtrip failed, got: $got"
}

# L7 (26-06-2026 migration review): a path containing a single quote must round-trip
# intact — the reader strips only the "..." storage delimiters, not path characters.
test_index_preserves_single_quote_in_path() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path repoq "/Users/me/O'Brien/repo"
    local got; got=$(_index_get_path repoq)
    [[ "$got" == "/Users/me/O'Brien/repo" ]] || fail "single quote was stripped, got: $got"
}

test_index_upsert_overwrites() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path repo1 /a/first
    _index_set_path repo1 /a/second
    local got; got=$(_index_get_path repo1)
    [[ "$got" == "/a/second" ]] || fail "Upsert should overwrite, got: $got"
    # No duplicate line left behind.
    local n; n=$(_index_list_paths | grep -c '^repo1=')
    [[ "$n" -eq 1 ]] || fail "Expected exactly one repo1 entry, got: $n"
}

test_index_get_missing_empty() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    [[ -z "$(_index_get_path nonexistent)" ]] || fail "Missing key should be empty"
}

test_index_remove_path() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path repo1 /a/b
    _index_remove_path repo1
    [[ -z "$(_index_get_path repo1)" ]] || fail "Removed key should be empty"
}

test_index_multiple_paths_coexist() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path repo1 /a/one
    _index_set_path repo2 /a/two
    _index_set_path shared-assets /a/assets
    [[ "$(_index_get_path repo1)" == "/a/one" ]]        || fail "repo1 wrong"
    [[ "$(_index_get_path repo2)" == "/a/two" ]]        || fail "repo2 wrong"
    [[ "$(_index_get_path shared-assets)" == "/a/assets" ]] || fail "shared-assets wrong"
    local n; n=$(_index_list_paths | wc -l | tr -d ' ')
    [[ "$n" -eq 3 ]] || fail "Expected 3 entries, got: $n"
}

test_index_project_repos_roundtrip() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_project_repos projectA repo1 repo2 repo3
    local got; got=$(_index_get_project_repos projectA)
    [[ "$got" == "repo1 repo2 repo3" ]] || fail "Project repos roundtrip, got: $got"
}

test_index_paths_and_projects_coexist() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path repo1 /a/one
    _index_set_project_repos projectA repo1 repo2
    # Both sections must remain independently readable.
    [[ "$(_index_get_path repo1)" == "/a/one" ]]              || fail "path lost after project set"
    [[ "$(_index_get_project_repos projectA)" == "repo1 repo2" ]] || fail "project lost"
    _index_set_path repo2 /a/two
    [[ "$(_index_get_project_repos projectA)" == "repo1 repo2" ]] || fail "project clobbered by path set"
}

test_index_path_conflicts() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path repo1 /a/one
    _index_path_conflicts repo1 /a/DIFFERENT || fail "Different path should conflict (AD5)"
    if _index_path_conflicts repo1 /a/one; then fail "Same path must not conflict"; fi
    if _index_path_conflicts brand-new /a/x;  then fail "Unbound name must not conflict"; fi
}

test_index_scaffold_has_version_and_sections() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path repo1 /a/b
    local f; f=$(_index_file)
    grep -q '^version: 1$' "$f"  || fail "Missing version header"
    grep -q '^paths:$' "$f"      || fail "Missing paths: section"
    grep -q '^projects:$' "$f"   || fail "Missing projects: section"
    # Atomic write leaves no mktemp ghosts behind.
    local ghosts; ghosts=$(find "$(dirname "$f")" -name 'index.??????' | wc -l | tr -d ' ')
    [[ "$ghosts" -eq 0 ]] || fail "Atomic write left $ghosts tempfile ghost(s)"
}

# ── Reverse lookup: repo → referencing projects (ADR-0024 D5) ────────

test_index_repos_get_projects_reverse() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    index_set_project_repos projA shared apionly
    index_set_project_repos projB shared
    local out
    out=$(
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/paths.sh"; source "$REPO_ROOT/lib/index.sh"
        _index_repos_get_projects shared
    )
    printf '%s\n' "$out" | grep -qx projA || fail "projA should reference 'shared'"
    printf '%s\n' "$out" | grep -qx projB || fail "projB should reference 'shared'"
    # A repo referenced by only one project is not over-reported.
    local out2
    out2=$(
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/paths.sh"; source "$REPO_ROOT/lib/index.sh"
        _index_repos_get_projects apionly
    )
    printf '%s\n' "$out2" | grep -qx projA || fail "projA should reference 'apionly'"
    printf '%s\n' "$out2" | grep -qx projB && fail "projB must not reference 'apionly'" || true
}

# ── Boundary normalization (S1: the index stores absolute paths only) ──

test_index_set_path_expands_tilde() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_set_path r1 "~/dev/x"
    local got; got=$(_index_get_path r1)
    [[ "$got" == "$HOME/dev/x" ]] || fail "tilde not expanded, got: $got"
}

test_index_set_path_expands_home_var() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_set_path r2 '$HOME/dev/y'
    local got; got=$(_index_get_path r2)
    [[ "$got" == "$HOME/dev/y" ]] || fail "\$HOME not expanded, got: $got"
}

test_index_set_path_rejects_non_absolute() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    # @local and relative values must never reach the index (return 1, no entry).
    if _index_set_path bad1 "@local";        then fail "@local should be rejected"; fi
    if _index_set_path bad2 "relative/path"; then fail "relative path should be rejected"; fi
    [[ -z "$(_index_get_path bad1)" ]] || fail "bad1 must not be in the index"
    [[ -z "$(_index_get_path bad2)" ]] || fail "bad2 must not be in the index"
}

test_index_path_conflicts_ignores_spelling() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_set_path r3 "$HOME/dev/z"
    # Same dir, tilde spelling → NOT a conflict (false AD5 regression, finding #2).
    if _index_path_conflicts r3 "~/dev/z"; then fail "same dir, two spellings must not conflict"; fi
    # A genuinely different dir → conflict.
    _index_path_conflicts r3 "/other/place" || fail "different dir must conflict"
}

# ── _project_member_status: the shared sync-state classifier (ADR-0024 D5) ──
# Extends _index_test_env with sync-meta (the divergence signal) and a tiny
# repo-with-.cco factory, so the 5-way taxonomy can be exercised directly.
_member_status_env() {
    _index_test_env "$1"
    source "$REPO_ROOT/lib/sync-meta.sh"
}
# Create <root> with a committed .cco/project.yml whose `name:` == <hosted>.
_mk_repo() {
    local root="$1" hosted="$2"
    mkdir -p "$root/.cco"
    printf 'name: %s\nrepos:\n  - name: %s\n' "$hosted" "$(basename "$root")" > "$root/.cco/project.yml"
}

test_member_status_unresolved_and_code_only() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _member_status_env "$tmp/state"
    # No path on disk → unresolved.
    [[ "$(_project_member_status proj "")" == "unresolved" ]] || fail "empty path must be unresolved"
    [[ "$(_project_member_status proj "$tmp/gone")" == "unresolved" ]] || fail "missing dir must be unresolved"
    # Resolved dir without .cco/project.yml → code-only.
    mkdir -p "$tmp/code"
    [[ "$(_project_member_status proj "$tmp/code")" == "code-only" ]] || fail "no .cco must be code-only"
}

test_member_status_foreign_synced_divergent() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _member_status_env "$tmp/state"

    # Hosts a DIFFERENT project → foreign (the ADR-0024 D2 discriminator).
    _mk_repo "$tmp/other" "other-proj"
    [[ "$(_project_member_status proj "$tmp/other")" == "foreign" ]] || fail "name != project must be foreign"

    # Owns the project, no stored fingerprint → pristine → synced (not divergent).
    _mk_repo "$tmp/owned" "proj"
    [[ "$(_project_member_status proj "$tmp/owned")" == "synced" ]] || fail "pristine owned member must be synced"

    # Record a sync, then edit the synced set → divergent (same name, drifted).
    _sync_record "$tmp/owned"
    [[ "$(_project_member_status proj "$tmp/owned")" == "synced" ]] || fail "just-synced member must be synced"
    printf '\n# local edit\n' >> "$tmp/owned/.cco/project.yml"
    [[ "$(_project_member_status proj "$tmp/owned")" == "divergent" ]] || fail "edited-since-sync owned member must be divergent"
}

test_iter_members_emits_name_path_status() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _member_status_env "$tmp/state"
    _mk_repo "$tmp/a" "proj"
    _index_set_path a "$tmp/a"
    _index_set_path b "$tmp/missing"        # never created → unresolved
    _index_set_project_repos proj a b

    local out; out=$(_project_iter_members proj)
    printf '%s\n' "$out" | grep -qE "^a	$tmp/a	synced$" || fail "member a must be synced with its path; got: $out"
    printf '%s\n' "$out" | grep -qE "^b		unresolved$" || fail "member b must be unresolved with empty path; got: $out"
}

# ══════════════════════════════════════════════════════════════════════
# Per-project name scoping (ADR-0051) — v2 nested project_paths schema
# ══════════════════════════════════════════════════════════════════════
# The identity of a repo/extra_mount is its PATH; the name is a per-project
# label. The index binds (project, name) → path in a nested `project_paths:`
# section. These A.1 tests exercise the new primitives in isolation — they do
# NOT touch the legacy flat paths: API (still used by callers until the cutover).

test_pp_set_get_roundtrip() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_pp_set app-a backend /abs/backend
    _index_pp_set app-a web     /abs/web
    [[ "$(_index_pp_get app-a backend)" == "/abs/backend" ]] || fail "pp backend roundtrip"
    [[ "$(_index_pp_get app-a web)"     == "/abs/web" ]]     || fail "pp web roundtrip"
    [[ -z "$(_index_pp_get app-a nope)" ]]                   || fail "missing inner must be empty"
    [[ -z "$(_index_pp_get nope backend)" ]]                 || fail "missing project must be empty"
}

# AD5′: same name in different projects may bind DIFFERENT paths (homonyms).
test_pp_same_name_different_projects() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_pp_set app-a backend /a/backend
    _index_pp_set app-b backend /b/backend      # same name, different project + path
    [[ "$(_index_pp_get app-a backend)" == "/a/backend" ]] || fail "app-a backend"
    [[ "$(_index_pp_get app-b backend)" == "/b/backend" ]] || fail "app-b backend (homonym must coexist)"
}

# AD5′: same path may carry different names across projects (aliases).
test_pp_same_path_different_names() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_pp_set app-a shared /abs/shared
    _index_pp_set app-b common /abs/shared      # same path, different label
    [[ "$(_index_pp_get app-a shared)" == "/abs/shared" ]] || fail "app-a shared"
    [[ "$(_index_pp_get app-b common)" == "/abs/shared" ]] || fail "app-b common alias"
}

test_pp_upsert_overwrites() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_pp_set app-a backend /a/first
    _index_pp_set app-a backend /a/second
    [[ "$(_index_pp_get app-a backend)" == "/a/second" ]] || fail "upsert should overwrite"
    local n; n=$(_index_pp_dump_project app-a | grep -c '^backend=')
    [[ "$n" -eq 1 ]] || fail "expected exactly one backend entry, got: $n"
}

test_pp_remove_prunes_empty_block() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_pp_set app-a backend /a/backend
    _index_pp_remove app-a backend
    [[ -z "$(_index_pp_get app-a backend)" ]] || fail "removed inner must be empty"
    # The now-empty project block must be pruned (no dangling "  app-a:" header).
    local f; f=$(_index_file)
    grep -qE '^  app-a:$' "$f" && fail "empty project block must be pruned" || true
}

test_pp_remove_keeps_sibling() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_pp_set app-a backend /a/backend
    _index_pp_set app-a web     /a/web
    _index_pp_set app-b backend /b/backend
    _index_pp_remove app-a backend
    [[ -z "$(_index_pp_get app-a backend)" ]]            || fail "app-a backend removed"
    [[ "$(_index_pp_get app-a web)"     == "/a/web" ]]   || fail "app-a web must survive"
    [[ "$(_index_pp_get app-b backend)" == "/b/backend" ]] || fail "app-b backend must survive (other project)"
}

test_pp_remove_project() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_pp_set app-a backend /a/backend
    _index_pp_set app-a web     /a/web
    _index_pp_set app-b backend /b/backend
    _index_pp_remove_project app-a
    [[ -z "$(_index_pp_get app-a backend)" ]] || fail "app-a backend gone"
    [[ -z "$(_index_pp_get app-a web)" ]]     || fail "app-a web gone"
    [[ "$(_index_pp_get app-b backend)" == "/b/backend" ]] || fail "app-b must be untouched"
}

test_pp_rejects_non_absolute() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    if _index_pp_set app-a bad "@local";        then fail "@local must be rejected"; fi
    if _index_pp_set app-a bad2 "relative/path"; then fail "relative must be rejected"; fi
    [[ -z "$(_index_pp_get app-a bad)" ]]  || fail "bad must not be indexed"
    [[ -z "$(_index_pp_get app-a bad2)" ]] || fail "bad2 must not be indexed"
}

test_pp_expands_tilde_and_home() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_pp_set app-a r1 "~/dev/x"
    _index_pp_set app-a r2 '$HOME/dev/y'
    [[ "$(_index_pp_get app-a r1)" == "$HOME/dev/x" ]] || fail "tilde not expanded"
    [[ "$(_index_pp_get app-a r2)" == "$HOME/dev/y" ]] || fail "\$HOME not expanded"
}

test_pp_preserves_single_quote_in_path() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_pp_set app-a repoq "/Users/me/O'Brien/repo"
    [[ "$(_index_pp_get app-a repoq)" == "/Users/me/O'Brien/repo" ]] || fail "single quote stripped"
}

# AD5′ chokepoint: conflict iff the SAME project already binds name to a
# DIFFERENT path. Cross-project same-name is NOT a conflict.
test_pp_conflicts_ad5prime() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_pp_set app-a backend /a/backend
    _index_pp_conflicts app-a backend /a/DIFFERENT || fail "same project, different path must conflict"
    if _index_pp_conflicts app-a backend /a/backend; then fail "same path must not conflict"; fi
    if _index_pp_conflicts app-b backend /b/backend; then fail "cross-project same name is NOT a conflict"; fi
    if _index_pp_conflicts app-a brand-new /a/x;      then fail "unbound name must not conflict"; fi
}

test_pp_conflicts_ignores_spelling() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_pp_set app-a r "$HOME/dev/z"
    if _index_pp_conflicts app-a r "~/dev/z"; then fail "same dir, two spellings must not conflict"; fi
    _index_pp_conflicts app-a r "/other" || fail "different dir must conflict"
}

test_pp_dump_all() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_pp_set app-a backend /a/backend
    _index_pp_set app-a web     /a/web
    _index_pp_set app-b backend /b/backend
    local out; out=$(_index_pp_dump_all)
    printf '%s\n' "$out" | grep -qxF "app-a	backend	/a/backend" || fail "dump_all missing app-a backend; got: $out"
    printf '%s\n' "$out" | grep -qxF "app-a	web	/a/web"         || fail "dump_all missing app-a web"
    printf '%s\n' "$out" | grep -qxF "app-b	backend	/b/backend" || fail "dump_all missing app-b backend"
    local n; n=$(printf '%s\n' "$out" | grep -c .)
    [[ "$n" -eq 3 ]] || fail "dump_all expected 3 lines, got: $n"
}

# Path-based reverse lookup (ADR-0051 D5) — replaces name-based reverse lookup.
# "which (project, name) bindings resolve to <path>" — sharing is a PATH property.
test_paths_get_bindings_reverse() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_pp_set app-a shared /abs/shared
    _index_pp_set app-b common /abs/shared      # SAME path, different label
    _index_pp_set app-c other  /abs/other
    local out; out=$(_index_paths_get_bindings /abs/shared)
    printf '%s\n' "$out" | grep -qxF "app-a	shared" || fail "binding app-a/shared missing; got: $out"
    printf '%s\n' "$out" | grep -qxF "app-b	common" || fail "binding app-b/common missing (same path)"
    printf '%s\n' "$out" | grep -qF  "app-c" && fail "app-c (different path) must not appear" || true
}

# Reverse lookup normalizes spellings before comparing (§12 path identity).
test_paths_get_bindings_ignores_spelling() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_pp_set app-a home "$HOME/dev/z"
    local out; out=$(_index_paths_get_bindings "~/dev/z")
    printf '%s\n' "$out" | grep -qxF "app-a	home" || fail "spelling-insensitive reverse lookup; got: $out"
}

# The new nested section must not disturb the legacy flat paths:/projects:
# sections during the transition (both coexist until the cutover).
test_pp_coexists_with_flat_sections() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_set_path legacy /a/legacy
    _index_set_project_repos app-a legacy
    _index_pp_set app-a backend /a/backend
    [[ "$(_index_get_path legacy)" == "/a/legacy" ]]              || fail "flat path lost after pp_set"
    [[ "$(_index_get_project_repos app-a)" == "legacy" ]]        || fail "flat project lost after pp_set"
    [[ "$(_index_pp_get app-a backend)" == "/a/backend" ]]       || fail "pp entry lost"
}
