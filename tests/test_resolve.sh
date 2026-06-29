#!/usr/bin/env bash
# tests/test_resolve.sh — cco resolve / cco path (P1 Commit 1)
#
# Index-backed resolution surface (design §3, ADR-0017 D2 / 0022 D3):
#   - cco resolve --scan <dir>  non-destructive merge-upsert (preserves
#     out-of-<dir> mappings + `cco path set` overrides; AD5 conflict keeps the
#     existing binding; no --prune)
#   - cco resolve [project]     cwd-first / by-name member resolution + membership
#   - cco path set | list       low-level index editor (relative -> absolute)
#
# Mask-safe: every assertion is guarded with `… || return 1` so a mid-test
# failure aborts the function (HITL-1, 2026-06-21 audit), in addition to the
# runner's ASSERTION-FAILED sentinel guard.
#
# Note on clone-from-url: the interactive clone affordance is the reused P0
# primitive `_prompt_for_path` (lib/local-paths.sh), which reads from /dev/tty
# and short-circuits on non-TTY — it is not exercisable under the headless
# runner. The url *threading* into the resolver is covered by the scan
# origin-url match test below.

# ── Fixtures ─────────────────────────────────────────────────────────

# Create a decentralized repo unit: <root>/<repodir>/.cco/project.yml
# Usage: _rsv_unit <root> <repodir> <project_yml_content>
_rsv_unit() {
    local root="$1" repodir="$2" content="$3"
    mkdir -p "$root/$repodir/.cco"
    printf '%s\n' "$content" > "$root/$repodir/.cco/project.yml"
}

# Run bin/cco with a specific working directory (for cwd-first resolution).
# Inherits the exported CCO_* env from setup_cco_env; sets CCO_OUTPUT and
# returns cco's exit code.
# Usage: _rsv_cco_in <dir> <args...>
_rsv_cco_in() {
    local dir="$1"; shift
    local rc=0
    CCO_OUTPUT=$(cd "$dir" && bash "$REPO_ROOT/bin/cco" "$@" 2>&1) || rc=$?
    return $rc
}

# Absolute path to the on-disk index (resolved via the real API so the location
# matches production exactly under the test's CCO_STATE_HOME).
_rsv_index_file() (
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/index.sh"
    _index_file
)

# A two-repo project manifest (machine-agnostic coordinates only).
_RSV_TWO_REPO_YML='name: demo
repos:
  - name: repo1
    url: https://example.com/repo1.git
  - name: repo2
    url: https://example.com/repo2.git'

# ── Tests ────────────────────────────────────────────────────────────

test_resolve_scan_binds_repos_by_basename() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"

    _rsv_unit "$tmp/dev" repo1 "$_RSV_TWO_REPO_YML"
    _rsv_unit "$tmp/dev" repo2 "$_RSV_TWO_REPO_YML"

    run_cco resolve --scan "$tmp/dev" || return 1
    assert_output_contains "2 unit(s) found" || return 1

    run_cco path list || return 1
    assert_output_contains "repo1" || return 1
    assert_output_contains "$tmp/dev/repo1" || return 1
    assert_output_contains "$tmp/dev/repo2" || return 1
}

test_resolve_scan_records_project_membership() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"

    _rsv_unit "$tmp/dev" repo1 "$_RSV_TWO_REPO_YML"
    _rsv_unit "$tmp/dev" repo2 "$_RSV_TWO_REPO_YML"

    run_cco resolve --scan "$tmp/dev" || return 1

    local idx; idx=$(_rsv_index_file)
    assert_file_contains "$idx" 'demo: "repo1 repo2"' || return 1
}

test_resolve_scan_preserves_out_of_dir_and_overrides() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"   # seeds dummy-repo -> $CCO_DUMMY_REPO (outside $tmp/dev)

    mkdir -p "$tmp/external"
    run_cco path set manual-override "$tmp/external" || return 1

    _rsv_unit "$tmp/dev" repo1 "$_RSV_TWO_REPO_YML"
    _rsv_unit "$tmp/dev" repo2 "$_RSV_TWO_REPO_YML"
    run_cco resolve --scan "$tmp/dev" || return 1

    # Out-of-<dir> mappings and `cco path set` overrides survive the scan.
    run_cco path list || return 1
    assert_output_contains "dummy-repo" || return 1
    assert_output_contains "manual-override" || return 1
    assert_output_contains "repo1" || return 1
}

test_resolve_scan_ad5_keeps_existing_on_conflict() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"

    # Pre-bind repo1 to a DIFFERENT path than the one the scan will discover.
    mkdir -p "$tmp/elsewhere"
    run_cco path set repo1 "$tmp/elsewhere" || return 1

    _rsv_unit "$tmp/dev" repo1 "$_RSV_TWO_REPO_YML"
    run_cco resolve --scan "$tmp/dev" || return 1
    assert_output_contains "keeping existing" || return 1

    # The existing binding is kept; the discovered path is NOT written.
    local idx; idx=$(_rsv_index_file)
    assert_file_contains "$idx" "repo1: \"$tmp/elsewhere\"" || return 1
    assert_file_not_contains "$idx" "repo1: \"$tmp/dev/repo1\"" || return 1
}

test_resolve_scan_no_prune_keeps_stale_entries() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"

    run_cco path set ghost "$tmp/ghost-not-scanned" || return 1
    _rsv_unit "$tmp/dev" repo1 "$_RSV_TWO_REPO_YML"
    run_cco resolve --scan "$tmp/dev" || return 1

    # No --prune: an entry not under <dir> is never removed.
    run_cco path list || return 1
    assert_output_contains "ghost" || return 1
}

test_resolve_scan_matches_by_git_origin_url() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"

    # The clone dir basename does NOT match any coordinate name; only the git
    # origin url does — the scan must bind by origin, not basename.
    local clone="$tmp/clones/weirdname"
    mkdir -p "$clone"
    git -C "$clone" init -q || return 1
    git -C "$clone" remote add origin https://example.com/repo1.git || return 1
    _rsv_unit "$tmp/clones" weirdname 'name: demo
repos:
  - name: repo1
    url: https://example.com/repo1.git'

    run_cco resolve --scan "$tmp/clones" || return 1

    local idx; idx=$(_rsv_index_file)
    assert_file_contains "$idx" "repo1: \"$clone\"" || return 1
}

test_path_set_and_list_roundtrip() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"

    mkdir -p "$tmp/somedir"
    run_cco path set myrepo "$tmp/somedir" || return 1
    assert_output_contains "path set: myrepo" || return 1

    run_cco path list || return 1
    assert_output_contains "myrepo" || return 1
    assert_output_contains "$tmp/somedir" || return 1
}

test_path_set_resolves_relative_to_absolute() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"

    mkdir -p "$tmp/sub"
    # Run from $tmp so the relative `sub` resolves against that cwd.
    _rsv_cco_in "$tmp" path set rel sub || return 1

    local expected; expected="$(cd "$tmp" && pwd -P)/sub"
    local idx; idx=$(_rsv_index_file)
    assert_file_contains "$idx" "rel: \"$expected\"" || return 1
}

# ── cco path demoted (ADR-0029 D4) ────────────────────────────────────

test_resolve_help_documents_path_advanced() {
    # `cco path` is documented under `cco resolve --help` as an advanced override.
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    run_cco resolve --help
    assert_output_contains "Advanced"
    assert_output_contains "cco path list"
    assert_output_contains "cco path set"
}

test_usage_omits_internal_path_command() {
    # The internal index editor is no longer surfaced in the top-level usage.
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    run_cco help
    assert_output_contains "resolve"
    if echo "${CCO_OUTPUT:-}" | grep -qE "^  path "; then
        fail "usage() should no longer list the internal 'cco path' command"
    fi
    # …but the command itself still works (covered by test_path_set_and_list_roundtrip).
}

test_resolve_cwd_first_resolves_and_records_membership() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"

    mkdir -p "$tmp/dev/repo1/.cco" "$tmp/dev/repo2"
    printf '%s\n' 'name: demo
repos:
  - name: repo1
  - name: repo2' > "$tmp/dev/repo1/.cco/project.yml"
    # Pre-bind both members so non-TTY resolution is a clean no-op success.
    run_cco path set repo1 "$tmp/dev/repo1" || return 1
    run_cco path set repo2 "$tmp/dev/repo2" || return 1

    _rsv_cco_in "$tmp/dev/repo1" resolve || return 1
    assert_output_contains "resolved" || return 1

    local idx; idx=$(_rsv_index_file)
    assert_file_contains "$idx" 'demo: "repo1 repo2"' || return 1
}

test_resolve_cwd_first_no_unit_errors() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"

    local rc=0
    _rsv_cco_in "$tmp" resolve || rc=$?
    [[ $rc -ne 0 ]] || { echo "ASSERTION FAILED: expected resolve to fail with no .cco/project.yml"; return 1; }
    assert_output_contains "No .cco/project.yml" || return 1
}

test_resolve_by_name_via_index() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"

    _rsv_unit "$tmp/dev" repo1 "$_RSV_TWO_REPO_YML"
    _rsv_unit "$tmp/dev" repo2 "$_RSV_TWO_REPO_YML"
    run_cco resolve --scan "$tmp/dev" || return 1

    # By-name: locate the unit via the index membership + a bound member's path.
    run_cco resolve demo || return 1
    assert_output_contains "demo" || return 1
}

test_resolve_unknown_project_errors() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"

    local rc=0
    run_cco resolve nonexistent-project || rc=$?
    [[ $rc -ne 0 ]] || { echo "ASSERTION FAILED: expected resolve to fail for unknown project"; return 1; }
    assert_output_contains "not resolvable yet" || return 1
}

test_resolve_prompts_unresolved_mount_with_tty() {
    # A (TTY-guard fix): the interactivity gate must use /dev/tty reachability,
    # NOT `[[ -t 0 ]]` — which is always false inside the `while read < <(yml_…)`
    # resolve loop, so the old guard never prompted (the mount stayed unresolved
    # forever). With a terminal reachable, an unresolved local-only mount must
    # reach the prompt and bind into the index. Stub the TTY probe + the prompt
    # (the real prompt reads /dev/tty, unavailable headless) and assert the bind.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _rsv_unit "$tmpdir" myrepo 'name: demo
repos:
  - name: myrepo
extra_mounts:
  - name: mymount
    target: /workspace/mymount'
    seed_index_path myrepo "$tmpdir/myrepo"     # repo already resolved (exists)

    (
        source "$REPO_ROOT/lib/colors.sh"
        source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/yaml.sh"
        source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/index.sh"
        source "$REPO_ROOT/lib/local-paths.sh"
        source "$REPO_ROOT/lib/cmd-resolve.sh"
        _cco_have_tty()    { return 0; }                    # stub: terminal reachable
        _prompt_for_path() { printf '%s\n' "/resolved/$1"; return 0; }  # stub: user picks a path
        _resolve_unit "$tmpdir/myrepo" >/dev/null 2>&1
    )

    local got
    got=$(
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/paths.sh"; source "$REPO_ROOT/lib/index.sh"
        _index_get_path mymount
    )
    [[ "$got" == "/resolved/mymount" ]] \
        || { echo "ASSERTION FAILED: resolve must prompt + bind an unresolved mount on a TTY (got: '$got')"; return 1; }
}

# ── llms heal (ADR-0032 D5) ──────────────────────────────────────────
# cco resolve heals referenced-but-uninstalled llms (P14: one heal verb for
# repos/mounts/llms). Non-TTY warns + counts (never blocks); TTY routes to the
# interactive install; an installed llms is a clean skip.

_RSV_LLMS_YML='name: demo
repos:
  - name: myrepo
llms:
  - name: svelte
    url: https://svelte.dev/llms.txt'

test_resolve_llms_missing_warns_non_tty() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/myrepo"
    _rsv_unit "$tmp" myrepo "$_RSV_LLMS_YML"
    seed_index_path myrepo "$tmp/myrepo"
    local out
    out=$(
        export LLMS_DIR="$tmp/llms"; mkdir -p "$LLMS_DIR"
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/yaml.sh"; source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/index.sh"; source "$REPO_ROOT/lib/local-paths.sh"
        source "$REPO_ROOT/lib/cmd-resolve.sh"
        _cco_have_tty() { return 1; }                 # headless
        _resolve_unit "$tmp/myrepo" 2>&1
    )
    [[ "$out" == *"llms 'svelte' not installed"* ]] \
        || fail "Expected non-TTY warn for missing llms, got: $out"
    [[ "$out" == *"cco llms install https://svelte.dev/llms.txt --name svelte"* ]] \
        || fail "Expected an executable install hint, got: $out"
}

test_resolve_llms_installed_is_skipped() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/myrepo"
    _rsv_unit "$tmp" myrepo "$_RSV_LLMS_YML"
    seed_index_path myrepo "$tmp/myrepo"
    local out
    out=$(
        export LLMS_DIR="$tmp/llms"; mkdir -p "$LLMS_DIR/svelte"   # already installed
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/yaml.sh"; source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/index.sh"; source "$REPO_ROOT/lib/local-paths.sh"
        source "$REPO_ROOT/lib/cmd-resolve.sh"
        _cco_have_tty() { return 1; }
        _resolve_unit "$tmp/myrepo" 2>&1
    )
    [[ "$out" != *"svelte"* ]] || fail "An installed llms must not be flagged, got: $out"
}

test_resolve_llms_tty_invokes_heal() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/myrepo"
    _rsv_unit "$tmp" myrepo "$_RSV_LLMS_YML"
    seed_index_path myrepo "$tmp/myrepo"
    local out
    out=$(
        export LLMS_DIR="$tmp/llms"; mkdir -p "$LLMS_DIR"
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/yaml.sh"; source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/index.sh"; source "$REPO_ROOT/lib/local-paths.sh"
        source "$REPO_ROOT/lib/cmd-resolve.sh"
        _cco_have_tty() { return 0; }                              # terminal reachable
        _resolve_llms_entry() { mkdir -p "$LLMS_DIR/$1"; return 0; }  # stub a successful fetch
        _resolve_unit "$tmp/myrepo" >/dev/null 2>&1
        [[ -d "$LLMS_DIR/svelte" ]] && echo HEALED
    )
    [[ "$out" == *HEALED* ]] || fail "TTY resolve must route a missing llms to the heal path"
}

# S1 finding #4: `cco path list` must normalize values for display and flag any
# non-absolute entry as malformed instead of printing it as if it were valid.
# The boundary refuses dirty writes now, so seed a pre-fix entry directly via the
# low-level section setter.
test_path_list_normalizes_and_flags_malformed() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/real"
    run_cco path set good "$tmp/real" || return 1
    (
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/paths.sh"; source "$REPO_ROOT/lib/index.sh"
        _index_section_set paths legacy "@local"
        _index_section_set paths tildey "~/somewhere"
    ) || return 1

    run_cco path list || return 1
    assert_output_contains "good" || return 1
    assert_output_contains "$tmp/real" || return 1
    # tilde entry rendered absolute (HOME-expanded), never raw ~.
    assert_output_contains "$HOME/somewhere" || return 1
    # @local entry flagged, not printed as a valid path.
    assert_output_contains "malformed" || return 1
    assert_output_contains "1 malformed index entr" || return 1
}
