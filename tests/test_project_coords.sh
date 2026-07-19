#!/usr/bin/env bash
# tests/test_project_coords.sh — `cco project coords` cross-unit coordinate
# consistency (ADR-0016 D3, relocated by ADR-0023 D1; F45 on-demand/no-persist,
# F48 --sync never auto-elects → requires --from). --diff is read-only; --sync
# edits committed project.yml in place (preview + confirm/-y).

# Run `cco <args>` from <dir>, capturing rc + CCO_OUTPUT.
_pc_in() {
    local dir="$1"; shift
    local rc=0
    CCO_OUTPUT=$(cd "$dir" && bash "$REPO_ROOT/bin/cco" "$@" 2>&1) || rc=$?
    return $rc
}

# Two projects that reference the SAME logical repo id with DIVERGENT urls, plus
# a consistent llms id. create_project seeds the index (paths + projects).
_pc_two_divergent() {
    local tmpdir="$1"
    create_project "$tmpdir" "backend" "$(cat <<'YAML'
name: backend
repos:
  - name: shared-lib
    url: git@github.com:org/shared.git
    ref: main
llms:
  - name: react
    url: https://react.dev/llms-full.txt
YAML
)"
    create_project "$tmpdir" "frontend" "$(cat <<'YAML'
name: frontend
repos:
  - name: shared-lib
    url: https://github.com/org/shared-OLD.git
llms:
  - name: react
    url: https://react.dev/llms-full.txt
YAML
)"
}

# ── lookup / diff (read-only) ────────────────────────────────────────────

# No url-bearing resource anywhere → nothing to check for consistency. This is
# NOT an error; the message must say so and distinguish coords from validate
# (F3: validate = per-resource reachability; coords = cross-project consistency).
test_project_coords_empty_reports_nothing_to_check() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "solo" "$(cat <<'YAML'
name: solo
repos:
  - name: localrepo
YAML
)"
    local rc=0
    _pc_in "$tmpdir" project coords || rc=$?
    assert_equals 0 "$rc"
    assert_output_contains "No url coordinates to check"
    # framed as not-an-error, with the validate-vs-coords distinction spelled out
    assert_output_contains "cco project validate"
}

test_project_coords_table_lists_lookup() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _pc_two_divergent "$tmpdir"
    local rc=0
    _pc_in "$tmpdir" project coords || rc=$?
    assert_equals 0 "$rc"
    assert_output_contains "react: https://react.dev/llms-full.txt"
    assert_output_contains "shared-lib:"
    assert_output_contains "DIVERGENT"
}

test_project_coords_diff_shows_only_divergent() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _pc_two_divergent "$tmpdir"
    local rc=0
    _pc_in "$tmpdir" project coords --diff || rc=$?
    assert_equals 0 "$rc"
    assert_output_contains "shared-lib:"
    assert_output_contains "DIVERGENT"
    # react is consistent → absent from --diff
    assert_output_not_contains "react:"
}

test_project_coords_diff_consistent_reports_clean() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "a" "$(cat <<'YAML'
name: a
repos:
  - name: lib
    url: git@github.com:org/lib.git
YAML
)"
    create_project "$tmpdir" "b" "$(cat <<'YAML'
name: b
repos:
  - name: lib
    url: git@github.com:org/lib.git
YAML
)"
    local rc=0
    _pc_in "$tmpdir" project coords --diff || rc=$?
    assert_equals 0 "$rc"
    assert_output_contains "consistent across units"
}

# ── --sync (writes; F48 --from required) ─────────────────────────────────

test_project_coords_sync_requires_from() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _pc_two_divergent "$tmpdir"
    local rc=0
    _pc_in "$tmpdir" project coords --sync -y || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected --sync without --from to fail"
    assert_output_contains "requires --from"
}

test_project_coords_sync_unknown_from_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _pc_two_divergent "$tmpdir"
    local rc=0
    _pc_in "$tmpdir" project coords --sync --from ghost -y || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected unknown --from to fail"
    # The D-M2 vocabulary unification reworded this (was "not found"); the stable,
    # still-actionable remedy is naming 'cco resolve <name>'.
    assert_output_contains "cco resolve"
}

test_project_coords_sync_applies_from_authoritative() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _pc_two_divergent "$tmpdir"
    local rc=0
    _pc_in "$tmpdir" project coords --sync --from backend -y || rc=$?
    assert_equals 0 "$rc"
    assert_output_contains "Synced"
    # frontend's shared-lib url now matches backend's; structure intact.
    local fy; fy="$(host_cco_dir "$tmpdir" frontend)/project.yml"
    assert_file_contains "$fy" "url: git@github.com:org/shared.git"
    assert_file_not_contains "$fy" "shared-OLD"
    assert_file_contains "$fy" "name: react"
    # backend (the source) is untouched.
    assert_file_contains "$(host_cco_dir "$tmpdir" backend)/project.yml" "url: git@github.com:org/shared.git"
    # idempotent: a second diff is clean.
    _pc_in "$tmpdir" project coords --diff
    assert_output_contains "consistent across units"
}

test_project_coords_sync_consistent_noop() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "a" "$(cat <<'YAML'
name: a
repos:
  - name: lib
    url: git@github.com:org/lib.git
YAML
)"
    create_project "$tmpdir" "b" "$(cat <<'YAML'
name: b
repos:
  - name: lib
    url: git@github.com:org/lib.git
YAML
)"
    local rc=0
    _pc_in "$tmpdir" project coords --sync --from a -y || rc=$?
    assert_equals 0 "$rc"
    assert_output_contains "already consistent"
}

test_project_coords_sync_non_interactive_without_yes_aborts() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _pc_two_divergent "$tmpdir"
    # No -y, piped stdin (non-TTY) → ADR-0029 D2: DIE (non-zero exit), edit nothing.
    local rc=0
    CCO_OUTPUT=$(cd "$tmpdir" && bash "$REPO_ROOT/bin/cco" project coords --sync --from backend </dev/null 2>&1) || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected non-interactive --sync without -y to exit non-zero"
    echo "$CCO_OUTPUT" | grep -qF "re-run with -y" || fail "expected the ADR-0029 D2 die message"
    assert_file_contains "$(host_cco_dir "$tmpdir" frontend)/project.yml" "shared-OLD"
}

# ── writer edge cases (direct, lock the YAML in-place setter) ─────────────

test_coords_set_url_replaces_inserts_and_expands() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/cmd-project-coords.sh"

    # replace an existing url, leaving sibling sub-keys intact
    local f="$tmpdir/r.yml"
    printf 'name: t\nrepos:\n  - name: backend\n    ref: main\n    url: https://old/x\n' > "$f"
    _coords_set_url "$f" repos backend "git@new/x.git"
    assert_file_contains "$f" "url: git@new/x.git"
    assert_file_contains "$f" "ref: main"
    assert_file_not_contains "$f" "https://old/x"

    # insert a url when the entry has none
    local g="$tmpdir/i.yml"
    printf 'name: t\nrepos:\n  - name: backend\n    ref: main\n' > "$g"
    _coords_set_url "$g" repos backend "git@new/x.git"
    assert_file_contains "$g" "url: git@new/x.git"

    # expand a bare-string entry into the coordinate form, untouched siblings
    local h="$tmpdir/b.yml"
    printf 'name: t\nrepos:\n  - shared-lib\n  - other\n    url: git@x/other.git\n' > "$h"
    _coords_set_url "$h" repos shared-lib "git@new/shared.git"
    assert_file_contains "$h" "- name: shared-lib"
    assert_file_contains "$h" "url: git@new/shared.git"
    assert_file_contains "$h" "- other"
    assert_file_contains "$h" "url: git@x/other.git"
}

# ── help ─────────────────────────────────────────────────────────────────

test_project_coords_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local rc=0
    _pc_in "$tmpdir" project coords --help || rc=$?
    assert_equals 0 "$rc"
    assert_output_contains "coordinate consistency"
    assert_output_contains "--from"
}
