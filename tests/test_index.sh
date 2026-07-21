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

# The public path API is now PROJECT-SCOPED (ADR-0051): _index_{get,set,remove}_path
# and _index_path_conflicts take a <project> first argument.

test_index_set_get_roundtrip() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path p repo1 /Users/me/dev/repo1
    local got; got=$(_index_get_path p repo1)
    [[ "$got" == "/Users/me/dev/repo1" ]] || fail "Roundtrip failed, got: $got"
}

# L7 (26-06-2026 migration review): a path containing a single quote must round-trip
# intact — the reader strips only the "..." storage delimiters, not path characters.
test_index_preserves_single_quote_in_path() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path p repoq "/Users/me/O'Brien/repo"
    local got; got=$(_index_get_path p repoq)
    [[ "$got" == "/Users/me/O'Brien/repo" ]] || fail "single quote was stripped, got: $got"
}

test_index_upsert_overwrites() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path p repo1 /a/first
    _index_set_path p repo1 /a/second
    local got; got=$(_index_get_path p repo1)
    [[ "$got" == "/a/second" ]] || fail "Upsert should overwrite, got: $got"
    # No duplicate line left behind.
    local n; n=$(_index_list_paths | grep -c '^repo1=')
    [[ "$n" -eq 1 ]] || fail "Expected exactly one repo1 entry, got: $n"
}

test_index_get_missing_empty() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    [[ -z "$(_index_get_path p nonexistent)" ]] || fail "Missing key should be empty"
}

test_index_remove_path() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path p repo1 /a/b
    _index_remove_path p repo1
    [[ -z "$(_index_get_path p repo1)" ]] || fail "Removed key should be empty"
}

test_index_multiple_paths_coexist() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path p repo1 /a/one
    _index_set_path p repo2 /a/two
    _index_set_path p shared-assets /a/assets
    [[ "$(_index_get_path p repo1)" == "/a/one" ]]        || fail "repo1 wrong"
    [[ "$(_index_get_path p repo2)" == "/a/two" ]]        || fail "repo2 wrong"
    [[ "$(_index_get_path p shared-assets)" == "/a/assets" ]] || fail "shared-assets wrong"
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

    _index_set_path projectA repo1 /a/one
    _index_set_project_repos projectA repo1 repo2
    # Both sections must remain independently readable.
    [[ "$(_index_get_path projectA repo1)" == "/a/one" ]]        || fail "path lost after project set"
    [[ "$(_index_get_project_repos projectA)" == "repo1 repo2" ]] || fail "project lost"
    _index_set_path projectA repo2 /a/two
    [[ "$(_index_get_project_repos projectA)" == "repo1 repo2" ]] || fail "project clobbered by path set"
}

test_index_path_conflicts() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path p repo1 /a/one
    _index_path_conflicts p repo1 /a/DIFFERENT || fail "Different path should conflict (AD5′)"
    if _index_path_conflicts p repo1 /a/one;  then fail "Same path must not conflict"; fi
    if _index_path_conflicts p brand-new /a/x; then fail "Unbound name must not conflict"; fi
    if _index_path_conflicts other repo1 /a/DIFFERENT; then fail "Cross-project same name is not a conflict"; fi
}

test_index_scaffold_has_version_and_sections() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path p repo1 /a/b
    local f; f=$(_index_file)
    grep -q '^version: 2$'       "$f" || fail "Missing v2 version header"
    grep -q '^projects:$'        "$f" || fail "Missing projects: section"
    grep -q '^project_paths:$'   "$f" || fail "Missing project_paths: section"
    grep -q '^unscoped:$'        "$f" || fail "Missing unscoped: section"
    # Atomic write leaves no mktemp ghosts behind.
    local ghosts; ghosts=$(find "$(dirname "$f")" -name 'index.??????' | wc -l | tr -d ' ')
    [[ "$ghosts" -eq 0 ]] || fail "Atomic write left $ghosts tempfile ghost(s)"
}

# ── Boundary normalization (S1: the index stores absolute paths only) ──

test_index_set_path_expands_tilde() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_set_path p r1 "~/dev/x"
    local got; got=$(_index_get_path p r1)
    [[ "$got" == "$HOME/dev/x" ]] || fail "tilde not expanded, got: $got"
}

test_index_set_path_expands_home_var() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_set_path p r2 '$HOME/dev/y'
    local got; got=$(_index_get_path p r2)
    [[ "$got" == "$HOME/dev/y" ]] || fail "\$HOME not expanded, got: $got"
}

test_index_set_path_rejects_non_absolute() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    # @local and relative values must never reach the index (return 1, no entry).
    if _index_set_path p bad1 "@local";        then fail "@local should be rejected"; fi
    if _index_set_path p bad2 "relative/path"; then fail "relative path should be rejected"; fi
    [[ -z "$(_index_get_path p bad1)" ]] || fail "bad1 must not be in the index"
    [[ -z "$(_index_get_path p bad2)" ]] || fail "bad2 must not be in the index"
}

test_index_path_conflicts_ignores_spelling() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_set_path p r3 "$HOME/dev/z"
    # Same dir, tilde spelling → NOT a conflict (false AD5′ regression, finding #2).
    if _index_path_conflicts p r3 "~/dev/z"; then fail "same dir, two spellings must not conflict"; fi
    # A genuinely different dir → conflict.
    _index_path_conflicts p r3 "/other/place" || fail "different dir must conflict"
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
    _index_set_path proj a "$tmp/a"
    _index_set_path proj b "$tmp/missing"        # never created → unresolved
    _index_set_project_repos proj a b

    local out; out=$(_project_iter_members proj)
    printf '%s\n' "$out" | grep -qE "^a	$tmp/a	synced$" || fail "member a must be synced with its path; got: $out"
    printf '%s\n' "$out" | grep -qE "^b		unresolved$" || fail "member b must be unresolved with empty path; got: $out"
}

# ── Operator arm (RC-2 / 04-host-path-class.md §3.6, §6.5) ────────────
# In a session the STATE index holds a HOST path that never exists; the member is
# reachable only at the flat bind target <workdir>/<name>. _project_iter_members
# must probe the MOUNT (INV-F), so the rename verbs' project.yml rewrite and the
# pack-rename pre-scan stop being vacuous in-container.
_iter_operator_env() {
    # The operator predicate needs the flag AND three absolute bucket overrides
    # (_index_test_env unsets DATA/CACHE); STATE is already the seeded index dir.
    export CCO_CONTAINER_OPERATOR=1 CCO_IN_CONTAINER=1
    export CCO_DATA_HOME="${CCO_STATE_HOME%/*}/data" CCO_CACHE_HOME="${CCO_STATE_HOME%/*}/cache"
    # Operator mode skips _cco_ensure_dir (the buckets are mounts in production), so
    # pre-create them here or the index mktemp fails and every row reads empty.
    # STATE/shared is what `cco start` actually binds — the index lives there and
    # its writers need that directory to exist to place their mktemp sibling (v3 R1).
    mkdir -p "$CCO_STATE_HOME" "$CCO_STATE_HOME/shared" "$CCO_DATA_HOME" "$CCO_CACHE_HOME"
    export CCO_WORKDIR="$1"; mkdir -p "$CCO_WORKDIR"
}

test_iter_members_operator_uses_mount() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _member_status_env "$tmp/state"
    _iter_operator_env "$tmp/ws"
    # Index bound to an ABSENT host path; the member is mounted at <ws>/backend.
    _index_set_path shop backend /host/absent/backend
    _index_set_project_repos shop backend
    _mk_repo "$CCO_WORKDIR/backend" "shop"

    local out; out=$(_project_iter_members shop)
    printf '%s\n' "$out" | grep -qE "^backend	$CCO_WORKDIR/backend	synced$" \
        || fail "operator: member must be probed at its mount, synced; got: $out"
}

test_iter_members_operator_unbound_member_stays_unresolved() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _member_status_env "$tmp/state"
    _iter_operator_env "$tmp/ws"
    # Membership token with NO path binding, yet a tree exists at <ws>/ghost:
    # INV-F.1 must NOT synthesize a mount from the name alone (absent→present).
    _index_set_project_repos shop ghost
    _mk_repo "$CCO_WORKDIR/ghost" "shop"

    local out; out=$(_project_iter_members shop)
    printf '%s\n' "$out" | grep -qE "^ghost		unresolved$" \
        || fail "operator: an unbound member stays unresolved with empty path (INV-F.1); got: $out"
}

test_iter_members_host_unchanged() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _member_status_env "$tmp/state"
    unset CCO_CONTAINER_OPERATOR CCO_IN_CONTAINER
    _mk_repo "$tmp/a" "proj"
    _index_set_path proj a "$tmp/a"
    _index_set_path proj b "$tmp/missing"
    _index_set_project_repos proj a b
    # Host regression guard: the probe is the identity, so rows are byte-identical.
    local out; out=$(_project_iter_members proj)
    printf '%s\n' "$out" | grep -qE "^a	$tmp/a	synced$" || fail "host row a changed: $out"
    printf '%s\n' "$out" | grep -qE "^b		unresolved$" || fail "host row b changed: $out"
}

# ── Operator ENUMERATION arm (RC-3 §3.6, closes E6B-04) ───────────────
# RC-2 probed column 2 at the mount but kept the member NAMES coming from the STATE
# index — which reads EMPTY behind the ADR-0047 boundary, making every members loop
# VACUOUS in-container (the pack-rename pre-scan always passed, the rename fan-out
# reached nobody). The arm enumerates repos[] from the mounted project.yml when the
# project resolves there, so it stays non-empty even when the index is unreadable.
# _resolve_project_yml (operator layout) + yaml.sh are needed on TOP of the index env.
_iter_enum_env() {
    _member_status_env "$1"
    source "$REPO_ROOT/lib/access-scope.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    source "$REPO_ROOT/lib/cmd-resolve.sh"
}

# Index sealed (unreadable), project mounted: enumeration comes from project.yml, so
# the members loop is NON-EMPTY. Skipped as root (chmod 000 is bypassed).
# ⚠ FAILS pre-fix: names come from the sealed index → zero rows.
test_iter_members_operator_enumerates_when_index_sealed() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    _iter_enum_env "$tmp/state"
    _iter_operator_env "$tmp/ws"
    export PROJECT_NAME=shop
    # A mounted member that ALSO hosts shop's committed config, plus a declared but
    # UNMOUNTED member (in project.yml, no <ws>/api tree).
    mkdir -p "$CCO_WORKDIR/backend/.cco"
    printf 'name: shop\nrepos:\n  - name: backend\n  - name: api\n' \
        > "$CCO_WORKDIR/backend/.cco/project.yml"
    _index_set_path shop backend /host/absent/backend
    _index_set_project_repos shop backend api
    chmod 000 "$CCO_STATE_HOME"                    # the index is now unreadable

    local out; out=$(_project_iter_members shop)
    chmod 700 "$CCO_STATE_HOME"
    printf '%s\n' "$out" | grep -qE "^backend	$CCO_WORKDIR/backend	synced$" \
        || fail "sealed index: mounted member must enumerate from project.yml as synced; got: $out"
    printf '%s\n' "$out" | grep -qE "^api		unresolved$" \
        || fail "sealed index: an unmounted declared member must surface as unresolved; got: $out"
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

# The unscoped bucket is an escape-hatch resolved as a fallback by the scoped
# _index_get_path (a `cco path set` pin outside any project); a project's OWN
# binding wins over it. Usage of _index_set_unscoped mirrors `cco path set`.
test_pp_unscoped_fallback() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_set_unscoped shared-docs /global/docs
    # Any project resolving 'shared-docs' with no own binding falls back to it.
    [[ "$(_index_get_path app-a shared-docs)" == "/global/docs" ]] || fail "unscoped fallback missing"
    [[ "$(_index_get_path app-b shared-docs)" == "/global/docs" ]] || fail "unscoped fallback per project"
    # A project's OWN binding wins over the unscoped pin (no global default).
    _index_pp_set app-a shared-docs /a/docs
    [[ "$(_index_get_path app-a shared-docs)" == "/a/docs" ]]      || fail "own binding must win"
    [[ "$(_index_get_path app-b shared-docs)" == "/global/docs" ]] || fail "app-b still falls back"
}

# ── _index_rename_path (ADR-0050 B.2 — project-scoped name re-key) ────

test_index_rename_path_rekeys_binding_and_membership() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_project_repos p backend web
    _index_pp_set p backend /a/backend
    _index_pp_set p web     /a/web

    _index_rename_path p backend api

    [[ "$(_index_get_path p api)" == "/a/backend" ]] || fail "new name must carry the old path, got '$(_index_get_path p api)'"
    [[ -z "$(_index_get_path p backend)" ]]          || fail "old name must be gone"
    [[ "$(_index_get_path p web)" == "/a/web" ]]     || fail "sibling binding must be untouched"
    [[ "$(_index_get_project_repos p)" == "api web" ]] || fail "membership token must re-key, got '$(_index_get_project_repos p)'"
}

test_index_rename_path_is_project_scoped() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    # Homonym in another project (same name, DIFFERENT path) — a different resource.
    _index_set_project_repos app-a backend
    _index_set_project_repos app-b backend
    _index_pp_set app-a backend /a/backend
    _index_pp_set app-b backend /b/backend      # must stay put

    _index_rename_path app-a backend api

    [[ "$(_index_get_path app-a api)" == "/a/backend" ]]     || fail "app-a re-keyed"
    [[ -z "$(_index_get_path app-a backend)" ]]              || fail "app-a old gone"
    [[ "$(_index_get_path app-b backend)" == "/b/backend" ]] || fail "app-b homonym must be untouched"
    [[ "$(_index_get_project_repos app-b)" == "backend" ]]   || fail "app-b membership must be untouched"
}

test_index_rename_path_leaves_same_path_alias_alone() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    # Another project labels the SAME path differently — a per-project alias.
    _index_set_project_repos app-a backend
    _index_set_project_repos app-b common
    _index_pp_set app-a backend /shared/tree
    _index_pp_set app-b common  /shared/tree

    _index_rename_path app-a backend api

    [[ "$(_index_get_path app-a api)" == "/shared/tree" ]]    || fail "app-a re-keyed"
    [[ "$(_index_get_path app-b common)" == "/shared/tree" ]] || fail "app-b's own label for the same path must be untouched"
}

# ── Read-path honesty: empty ≠ unreadable (v3 R3 / S4) ────────────────
#
# _index_read_state is the read-side sibling of _index_mktemp. S2 made a failed
# index WRITE loud; these pin the mirror-image defect on the read side: every
# reader opens the index behind a bare `[[ -f ]] || return 0` and feeds a process
# substitution, so its status is discarded and "the read failed" was reported as
# "the index is empty" at rc=0 (v3 V2-F01/F02).
#
# The discriminating case is `truncated`: a legitimately empty index is NEVER 0
# bytes, because _index_ensure_file always writes a header, a version line and
# the four section keys. A classifier that only tested `-s` as "no content" would
# pass the ok/absent arms and still mis-report exactly the state that ships.

test_index_read_state_absent_is_benign() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    [[ "$(_index_read_state)" == "absent" ]] \
        || fail "no index file yet must classify as absent, got: $(_index_read_state)"
    # Benign: a machine with nothing registered is not an error. If this ever
    # dies, every first-run `cco list` starts failing.
    ( _index_assert_readable ) || fail "an absent index must not be an error"
}

test_index_read_state_ok_on_a_real_index() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path p repo1 /Users/me/dev/repo1
    [[ "$(_index_read_state)" == "ok" ]] \
        || fail "a written index must classify as ok, got: $(_index_read_state)"
    ( _index_assert_readable ) || fail "a healthy index must not be an error"
}

test_index_read_state_detects_a_truncated_index() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    # A scaffolded index is non-empty even with zero bindings — that is what makes
    # 0 bytes diagnostic of an interrupted write rather than of "nothing here".
    _index_set_path p repo1 /Users/me/dev/repo1
    [[ -s "$(_index_file)" ]] || fail "precondition: a real index is never 0 bytes"

    : > "$(_index_file)"
    [[ "$(_index_read_state)" == "truncated" ]] \
        || fail "a 0-byte index must classify as truncated, got: $(_index_read_state)"

    local rc=0; ( _index_assert_readable ) 2>/dev/null || rc=$?
    [[ "$rc" -eq 1 ]] || fail "a truncated index must be an error (exit 1), got rc=$rc"
}

test_index_read_state_detects_an_unreadable_index() {
    [[ "$(id -u)" -eq 0 ]] && return 0   # root ignores the mode bits
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    _index_set_path p repo1 /Users/me/dev/repo1
    chmod 000 "$(_index_file)"
    local st; st=$(_index_read_state)
    local rc=0; ( _index_assert_readable ) 2>/dev/null || rc=$?
    chmod 644 "$(_index_file)"

    # Probed by OPENING, not with `test -r`: access(2) answers for the REAL uid,
    # which is a false answer under elevation (the rename.sh:174 trap).
    [[ "$st" == "unreadable" ]] \
        || fail "a mode-000 index must classify as unreadable, got: $st"
    [[ "$rc" -eq 1 ]] || fail "an unreadable index must be an error (exit 1), got rc=$rc"
}

# The vocabulary half of R3. `cco resolve` is HOST-ONLY in a session (bin/cco's
# operator gate refuses it), so an in-container remedy naming it is advice the
# shim will reject — the exact string RC-2 retired, re-emitted from a path cycle
# 1 never audited. On the HOST the same string is the correct remedy, so this is
# a context rule, not a ban: both arms are asserted, or a "fix" that simply
# deleted the phrase everywhere would pass.
test_index_empty_sentence_never_says_cco_resolve_in_a_session() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"

    local host_msg; host_msg=$(_index_empty_sentence)
    [[ "$host_msg" == *"cco resolve"* ]] \
        || fail "on the host 'cco resolve --scan' IS the remedy; got: $host_msg"

    # A REAL operator context, not a stubbed predicate: _cco_container_operator
    # needs the explicit flag AND all three absolute bucket paths (a stub could
    # not regress-test the predicate — tests/helpers.sh, lane note (a)).
    local sess_msg
    sess_msg=$(CCO_IN_CONTAINER=1 CCO_CONTAINER_OPERATOR=1 \
        CCO_DATA_HOME="$tmp/data" CCO_STATE_HOME="$tmp/state" CCO_CACHE_HOME="$tmp/cache" \
        _index_empty_sentence)
    [[ "$sess_msg" != *"cco resolve"* ]] \
        || fail "in a session the remedy must not name the host-only 'cco resolve': $sess_msg"
    [[ "$sess_msg" == *"host"* ]] \
        || fail "the session remedy must point at the host: $sess_msg"
}

# The `stale` arm — V2-F03's detector. This is the state that produced v3's
# 🔴 V2-F01: the index was bind-mounted as a FILE, the host replaced it with
# mktemp+mv, and the container went on reading the old inode — which rename(2)
# had left with NO directory entry (nlink 0) — reporting 0 rows at rc=0 forever.
# S1 removed the cause by binding a DIRECTORY; this arm is the detector for the
# day a file-shaped bind returns somewhere else.
#
# nlink 0 cannot be synthesized without a mount, so `stat` is mocked on PATH (the
# tests/mocks.sh convention). Everything below the syscall is the real code path:
# _index_link_count really runs, _index_read_state really classifies, and the
# shared sentence really renders. The kernel side is covered out-of-session by
# the V2 re-run (plan §10).
test_index_read_state_detects_a_stale_deleted_inode() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_set_path p repo1 /Users/me/dev/repo1

    # Healthy first — a detector that fires on a LIVE index is worse than none.
    [[ "$(_index_read_state)" == "ok" ]] \
        || fail "precondition: a live index must classify ok, got: $(_index_read_state)"

    mkdir -p "$tmp/mockbin"
    cat > "$tmp/mockbin/stat" <<'MOCK'
#!/usr/bin/env bash
# Mock: an inode whose last directory entry was removed by rename(2).
echo 0
MOCK
    chmod +x "$tmp/mockbin/stat"

    local st; st=$(PATH="$tmp/mockbin:$PATH" _index_read_state)
    [[ "$st" == "stale" ]] || fail "nlink 0 must classify as stale, got: $st"

    local rc=0; ( PATH="$tmp/mockbin:$PATH" _index_assert_readable ) 2>/dev/null || rc=$?
    [[ "$rc" -eq 1 ]] || fail "a stale index must be an error (exit 1), got rc=$rc"

    # It must say WHAT is wrong — "replaced while this session was running" is the
    # one phrasing that tells a user their view is dead rather than empty.
    local msg; msg=$(_index_unreadable_sentence stale "$(_index_file)")
    [[ "$msg" == *"replaced"* ]] || fail "the stale sentence must name the cause: $msg"
    # It must not CLAIM emptiness — that is the false-success string itself. (The
    # sentence does contain the word, in the "this is NOT an empty index"
    # disclaimer, so the assertion is on the claim, not on the token.)
    [[ "$msg" != *"index is empty"* ]] \
        || fail "a stale index must never be reported as an empty one: $msg"
}

# The liveness arm must FAIL SAFE where stat answers neither dialect: no link
# count means no evidence, and no evidence must never be read as failure.
test_index_read_state_stale_arm_fails_safe_without_stat() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _index_test_env "$tmp/state"
    _index_set_path p repo1 /Users/me/dev/repo1

    mkdir -p "$tmp/mockbin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/mockbin/stat"
    chmod +x "$tmp/mockbin/stat"

    local st; st=$(PATH="$tmp/mockbin:$PATH" _index_read_state)
    [[ "$st" == "ok" ]] \
        || fail "an unanswerable link count must not invent a failure, got: $st"
}
