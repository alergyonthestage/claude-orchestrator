#!/usr/bin/env bash
# tests/test_project_rename.sh — `cco project rename [<old>] <new>` (ADR-0031).
#
# A rename is a multi-store identity re-key: project.yml `name:` in every member
# repo, the STATE index `projects:` membership, the DATA tags, and the
# STATE/CACHE/DATA `projects/<name>/` dirs. Strict (D3): refuse unless every
# member resolves on this machine; validate <new> (charset/reserved/uniqueness)
# before any write. Mask-safe: `… || return 1`.

# Read project membership / tags through the real API (subshell-sourced, like the
# harness seeders) so the on-disk format matches production exactly.
_pr_members() {
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
      source "$REPO_ROOT/lib/paths.sh"; source "$REPO_ROOT/lib/index.sh"
      _index_get_project_repos "$1" )
}
_pr_tags() {
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
      source "$REPO_ROOT/lib/paths.sh"; source "$REPO_ROOT/lib/index.sh"
      source "$REPO_ROOT/lib/tags.sh"; _tags_get projects "$1" )
}
# Run bin/cco from a given cwd (for the cwd-first form); sets CCO_OUTPUT.
_pr_cco_in() {
    local dir="$1"; shift
    local rc=0
    CCO_OUTPUT=$(cd "$dir" && bash "$REPO_ROOT/bin/cco" "$@" 2>&1) || rc=$?
    return $rc
}

test_rename_rekeys_all_stores() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    create_project "$tmp" "proj-old" "$(minimal_project_yml proj-old)"
    run_cco tag add proj-old work
    # Seed the three identity dirs with a marker to prove they move.
    local s="$CCO_STATE_HOME/projects/proj-old" c="$CCO_CACHE_HOME/projects/proj-old" d="$CCO_DATA_HOME/projects/proj-old"
    mkdir -p "$s/session/memory" "$c/managed" "$d"
    echo marker > "$s/session/memory/keep.md"

    run_cco project rename proj-old proj-new -y || return 1

    # 1. project.yml name rewritten in the member repo
    assert_file_contains "$(host_cco_dir "$tmp" proj-old)/project.yml" "name: proj-new" || return 1
    # 2. index membership re-keyed (members preserved, old gone)
    [[ "$(_pr_members proj-new)" == "proj-old" ]] || fail "index: expected member 'proj-old' under proj-new, got '$(_pr_members proj-new)'" || return 1
    [[ -z "$(_pr_members proj-old)" ]] || fail "index: proj-old should be gone, got '$(_pr_members proj-old)'" || return 1
    # 3. tags carried over
    [[ "$(_pr_tags proj-new)" == "work" ]] || fail "tags: expected 'work' under proj-new, got '$(_pr_tags proj-new)'" || return 1
    [[ -z "$(_pr_tags proj-old)" ]] || fail "tags: proj-old should be gone, got '$(_pr_tags proj-old)'" || return 1
    # 4. identity dirs moved (old gone, new present with the marker)
    assert_dir_exists "$CCO_STATE_HOME/projects/proj-new" || return 1
    assert_dir_not_exists "$CCO_STATE_HOME/projects/proj-old" || return 1
    assert_file_contains "$CCO_STATE_HOME/projects/proj-new/session/memory/keep.md" "marker" || return 1
    assert_dir_not_exists "$CCO_CACHE_HOME/projects/proj-old" || return 1
    assert_dir_exists "$CCO_CACHE_HOME/projects/proj-new" || return 1
    assert_dir_not_exists "$CCO_DATA_HOME/projects/proj-old" || return 1
    assert_dir_exists "$CCO_DATA_HOME/projects/proj-new" || return 1
}

test_rename_cwd_first_one_arg() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    create_project "$tmp" "proj-old" "$(minimal_project_yml proj-old)"
    # One-arg form: rename the project hosting the cwd.
    _pr_cco_in "$tmp/repos/proj-old" project rename proj-renamed -y || return 1
    assert_file_contains "$(host_cco_dir "$tmp" proj-old)/project.yml" "name: proj-renamed" || return 1
    [[ "$(_pr_members proj-renamed)" == "proj-old" ]] || fail "expected member under proj-renamed, got '$(_pr_members proj-renamed)'" || return 1
    [[ -z "$(_pr_members proj-old)" ]] || fail "proj-old should be gone" || return 1
}

test_rename_rejects_existing_name() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    create_project "$tmp" "alpha" "$(minimal_project_yml alpha)"
    create_project "$tmp" "beta"  "$(minimal_project_yml beta)"
    run_cco project rename alpha beta -y && { echo "ASSERTION FAILED: rename onto an existing name should fail"; return 1; }
    assert_output_contains "already registered" || return 1
    # No write: alpha still present, beta's project.yml untouched.
    [[ "$(_pr_members alpha)" == "alpha" ]] || fail "alpha membership should be intact" || return 1
    assert_file_contains "$(host_cco_dir "$tmp" alpha)/project.yml" "name: alpha" || return 1
    assert_file_contains "$(host_cco_dir "$tmp" beta)/project.yml" "name: beta" || return 1
}

test_rename_rejects_unresolved_member() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    # Two-member project: m1 resolved (host repo), m2 unresolved (no index path).
    local host="$tmp/repos/m1"
    mkdir -p "$host/.cco/claude"
    printf '%s\n' "$(minimal_project_yml multi)" > "$host/.cco/project.yml"
    seed_index_path "m1" "$host"
    index_set_project_repos "multi" m1 m2
    run_cco project rename multi multi-new -y && { echo "ASSERTION FAILED: rename with an unresolved member should fail"; return 1; }
    assert_output_contains "not resolved" || return 1
    # No write: project still under the old name, project.yml untouched.
    [[ "$(_pr_members multi)" == "m1 m2" ]] || fail "membership should be intact, got '$(_pr_members multi)'" || return 1
    [[ -z "$(_pr_members multi-new)" ]] || fail "multi-new must not be created" || return 1
    assert_file_contains "$host/.cco/project.yml" "name: multi" || return 1
}

test_rename_rejects_invalid_name() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    create_project "$tmp" "proj-old" "$(minimal_project_yml proj-old)"
    run_cco project rename proj-old "bad:name" -y && { echo "ASSERTION FAILED: invalid <new> should be rejected"; return 1; }
    assert_output_contains "Invalid project name" || return 1
    [[ "$(_pr_members proj-old)" == "proj-old" ]] || fail "proj-old should be intact" || return 1
}

test_rename_rejects_unknown_project() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    run_cco project rename ghost newghost -y && { echo "ASSERTION FAILED: renaming an unknown project should fail"; return 1; }
    assert_output_contains "No project named 'ghost'" || return 1
}

test_rename_non_tty_without_yes_dies() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    create_project "$tmp" "proj-old" "$(minimal_project_yml proj-old)"
    # No -y, no TTY (test runs non-interactively) → must refuse, no write.
    run_cco project rename proj-old proj-new && { echo "ASSERTION FAILED: non-TTY rename without -y should die"; return 1; }
    assert_output_contains "re-run with -y" || return 1
    [[ "$(_pr_members proj-old)" == "proj-old" ]] || fail "proj-old should be intact" || return 1
    [[ -z "$(_pr_members proj-new)" ]] || fail "proj-new must not be created" || return 1
}
