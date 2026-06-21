#!/usr/bin/env bash
# tests/test_sync.sh — cco sync (P1 Commit 4; design §4)
#
# Copy semantics, the 4 command forms, confirm, --check/--dry-run, the
# never-sync exclusions (secrets.env, repo-root .claude/), and fingerprint
# recording. Mask-safe: every assertion guarded with `… || return 1`.

# A 2-repo and a 3-repo project manifest (machine-agnostic; names only).
_SYT_YML2='name: demo
repos:
  - name: repo1
  - name: repo2'
_SYT_YML3='name: demo
repos:
  - name: repo1
  - name: repo2
  - name: repo3'

# Create a repo unit at <root>/<repodir>/.cco with the given CLAUDE.md content.
# Usage: _syt_unit <root> <repodir> <claude_content> <project_yml>
_syt_unit() {
    local root="$1" repodir="$2" claude="$3" yml="$4"
    mkdir -p "$root/$repodir/.cco/claude"
    printf '%s\n' "$yml" > "$root/$repodir/.cco/project.yml"
    printf '%s\n' "$claude" > "$root/$repodir/.cco/claude/CLAUDE.md"
}

# Run bin/cco with a given working directory (inherits exported CCO_*/HOME);
# sets CCO_OUTPUT, returns cco's exit code.
_syt_cco_in() {
    local dir="$1"; shift
    local rc=0
    CCO_OUTPUT=$(cd "$dir" && bash "$REPO_ROOT/bin/cco" "$@" 2>&1) || rc=$?
    return $rc
}

test_sync_copies_synced_set() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _syt_unit "$tmp/dev" repo1 "# repo1 NEW" "$_SYT_YML2"
    _syt_unit "$tmp/dev" repo2 "# repo2 old" "$_SYT_YML2"
    run_cco resolve --scan "$tmp/dev" || return 1

    _syt_cco_in "$tmp/dev/repo1" sync --auto-approve || return 1
    assert_file_contains "$tmp/dev/repo2/.cco/claude/CLAUDE.md" "# repo1 NEW" || return 1
}

test_sync_never_copies_secrets_env() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _syt_unit "$tmp/dev" repo1 "# r1" "$_SYT_YML2"
    _syt_unit "$tmp/dev" repo2 "# r2" "$_SYT_YML2"
    printf 'TOKEN=supersecret\n' > "$tmp/dev/repo1/.cco/secrets.env"          # NEVER synced
    printf 'TOKEN=\n'            > "$tmp/dev/repo1/.cco/secrets.env.example"   # synced (skeleton)
    run_cco resolve --scan "$tmp/dev" || return 1

    _syt_cco_in "$tmp/dev/repo1" sync --auto-approve || return 1
    assert_file_not_exists "$tmp/dev/repo2/.cco/secrets.env" || return 1
    assert_file_exists "$tmp/dev/repo2/.cco/secrets.env.example" || return 1
}

test_sync_never_copies_repo_root_claude() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _syt_unit "$tmp/dev" repo1 "# r1" "$_SYT_YML2"
    _syt_unit "$tmp/dev" repo2 "# r2" "$_SYT_YML2"
    mkdir -p "$tmp/dev/repo1/.claude"                                          # repo-root, NOT .cco
    printf '{}\n' > "$tmp/dev/repo1/.claude/settings.json"
    run_cco resolve --scan "$tmp/dev" || return 1

    _syt_cco_in "$tmp/dev/repo1" sync --auto-approve || return 1
    assert_dir_not_exists "$tmp/dev/repo2/.claude" || return 1
}

test_sync_no_diff_is_noop() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _syt_unit "$tmp/dev" repo1 "# identical" "$_SYT_YML2"
    _syt_unit "$tmp/dev" repo2 "# identical" "$_SYT_YML2"
    run_cco resolve --scan "$tmp/dev" || return 1

    _syt_cco_in "$tmp/dev/repo1" sync --auto-approve || return 1
    assert_output_contains "already in sync" || return 1
}

test_sync_check_exit_codes() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _syt_unit "$tmp/dev" repo1 "# r1 NEW" "$_SYT_YML2"
    _syt_unit "$tmp/dev" repo2 "# r2 old" "$_SYT_YML2"
    run_cco resolve --scan "$tmp/dev" || return 1

    local rc=0
    _syt_cco_in "$tmp/dev/repo1" sync --check || rc=$?
    [[ $rc -ne 0 ]] || { echo "ASSERTION FAILED: --check should exit non-zero when out of sync"; return 1; }
    assert_output_contains "out of sync" || return 1

    # Converge, then --check must be clean (exit 0).
    _syt_cco_in "$tmp/dev/repo1" sync --auto-approve || return 1
    rc=0
    _syt_cco_in "$tmp/dev/repo1" sync --check || rc=$?
    [[ $rc -eq 0 ]] || { echo "ASSERTION FAILED: --check should exit 0 when in sync (rc=$rc)"; return 1; }
}

test_sync_dry_run_does_not_copy() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _syt_unit "$tmp/dev" repo1 "# r1 NEW" "$_SYT_YML2"
    _syt_unit "$tmp/dev" repo2 "# r2 OLD-KEPT" "$_SYT_YML2"
    run_cco resolve --scan "$tmp/dev" || return 1

    _syt_cco_in "$tmp/dev/repo1" sync --dry-run || return 1
    assert_file_contains "$tmp/dev/repo2/.cco/claude/CLAUDE.md" "# r2 OLD-KEPT" || return 1
}

test_sync_form_positional_target_only() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _syt_unit "$tmp/dev" repo1 "# r1 NEW" "$_SYT_YML3"
    _syt_unit "$tmp/dev" repo2 "# r2 old" "$_SYT_YML3"
    _syt_unit "$tmp/dev" repo3 "# r3 old" "$_SYT_YML3"
    run_cco resolve --scan "$tmp/dev" || return 1

    _syt_cco_in "$tmp/dev/repo1" sync repo2 --auto-approve || return 1
    assert_file_contains "$tmp/dev/repo2/.cco/claude/CLAUDE.md" "# r1 NEW" || return 1
    assert_file_contains "$tmp/dev/repo3/.cco/claude/CLAUDE.md" "# r3 old" || return 1   # untouched
}

test_sync_form_from_source() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _syt_unit "$tmp/dev" repo1 "# r1 NEW" "$_SYT_YML2"
    _syt_unit "$tmp/dev" repo2 "# r2 old" "$_SYT_YML2"
    run_cco resolve --scan "$tmp/dev" || return 1

    # Run from a neutral cwd; --from selects the source explicitly.
    _syt_cco_in "$tmp" sync --from repo1 --auto-approve || return 1
    assert_file_contains "$tmp/dev/repo2/.cco/claude/CLAUDE.md" "# r1 NEW" || return 1
}

test_sync_form_target_and_from() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _syt_unit "$tmp/dev" repo1 "# r1 NEW" "$_SYT_YML3"
    _syt_unit "$tmp/dev" repo2 "# r2 old" "$_SYT_YML3"
    _syt_unit "$tmp/dev" repo3 "# r3 old" "$_SYT_YML3"
    run_cco resolve --scan "$tmp/dev" || return 1

    _syt_cco_in "$tmp" sync repo3 --from repo1 --auto-approve || return 1
    assert_file_contains "$tmp/dev/repo3/.cco/claude/CLAUDE.md" "# r1 NEW" || return 1
    assert_file_contains "$tmp/dev/repo2/.cco/claude/CLAUDE.md" "# r2 old" || return 1   # untouched
}

test_sync_confirm_required_noninteractive() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _syt_unit "$tmp/dev" repo1 "# r1 NEW" "$_SYT_YML2"
    _syt_unit "$tmp/dev" repo2 "# r2 KEEP" "$_SYT_YML2"
    run_cco resolve --scan "$tmp/dev" || return 1

    # No --auto-approve in a non-TTY context must refuse (never silently copy).
    local rc=0
    _syt_cco_in "$tmp/dev/repo1" sync < /dev/null || rc=$?
    [[ $rc -ne 0 ]] || { echo "ASSERTION FAILED: sync should refuse without --auto-approve in non-TTY"; return 1; }
    assert_output_contains "auto-approve" || return 1
    assert_file_contains "$tmp/dev/repo2/.cco/claude/CLAUDE.md" "# r2 KEEP" || return 1   # not modified
}

test_sync_records_fingerprint_on_both_sides() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _syt_unit "$tmp/dev" repo1 "# r1 NEW" "$_SYT_YML2"
    _syt_unit "$tmp/dev" repo2 "# r2 old" "$_SYT_YML2"
    run_cco resolve --scan "$tmp/dev" || return 1

    _syt_cco_in "$tmp/dev/repo1" sync --auto-approve || return 1
    local sm="$CCO_STATE_HOME/sync-meta"
    assert_file_exists "$sm" || return 1
    assert_file_contains "$sm" "$tmp/dev/repo1" || return 1   # source side
    assert_file_contains "$sm" "$tmp/dev/repo2" || return 1   # target side
}

test_sync_unresolved_target_is_skipped_with_warning() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    # project.yml lists repo3, but only repo1/repo2 exist + are scanned.
    _syt_unit "$tmp/dev" repo1 "# r1 NEW" "$_SYT_YML3"
    _syt_unit "$tmp/dev" repo2 "# r2 old" "$_SYT_YML3"
    run_cco resolve --scan "$tmp/dev" || return 1

    _syt_cco_in "$tmp/dev/repo1" sync --auto-approve || return 1
    assert_output_contains "repo3" || return 1
    assert_output_contains "unresolved" || return 1
    assert_file_contains "$tmp/dev/repo2/.cco/claude/CLAUDE.md" "# r1 NEW" || return 1   # repo2 still synced
}
