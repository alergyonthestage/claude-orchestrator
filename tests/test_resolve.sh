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

    # Pre-bind repo1 (scoped to demo, from within the demo repo) to a DIFFERENT
    # path than the one the scan will discover — a genuine AD5′ in-project clash.
    _rsv_unit "$tmp/dev" repo1 "$_RSV_TWO_REPO_YML"
    mkdir -p "$tmp/elsewhere"
    _rsv_cco_in "$tmp/dev/repo1" path set repo1 "$tmp/elsewhere" || return 1

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

    # From a neutral cwd (no project) → an unscoped pin.
    _rsv_cco_in "$tmp" path set ghost "$tmp/ghost-not-scanned" || return 1
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
    # Neutral cwd (no project) → an unscoped pin.
    _rsv_cco_in "$tmp" path set myrepo "$tmp/somedir" || return 1
    assert_output_contains "path set: myrepo" || return 1

    _rsv_cco_in "$tmp" path list || return 1
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
    # Pre-bind both members (scoped to demo, from within the demo repo) so
    # non-TTY resolution is a clean no-op success.
    _rsv_cco_in "$tmp/dev/repo1" path set repo1 "$tmp/dev/repo1" || return 1
    _rsv_cco_in "$tmp/dev/repo1" path set repo2 "$tmp/dev/repo2" || return 1

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
        _index_get_path demo mymount
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
    _rsv_cco_in "$tmp" path set good "$tmp/real" || return 1
    (
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/paths.sh"; source "$REPO_ROOT/lib/index.sh"
        # Seed malformed values directly into the unscoped bucket (bypass the
        # normalizing boundary) — the v2 index has no flat paths: section.
        _index_section_set unscoped legacy "@local"
        _index_section_set unscoped tildey "~/somewhere"
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

# ── pack heal + unified status render (ADR-0033) ─────────────────────
# cco resolve heals referenced-but-uninstalled packs from their sharing-repo url
# (P14: one heal verb for repos/mounts/llms/packs) and always renders a status
# row per referenced resource. Non-TTY warns + counts (never blocks); TTY routes
# to the interactive install; a pack present in a local layer is a clean skip.

_RSV_MIXED_YML='name: demo
repos:
  - name: myrepo
llms:
  - name: svelte
    url: https://svelte.dev/llms.txt
packs:
  - name: team-pack
    url: https://github.com/org/sharing.git'

test_resolve_pack_missing_warns_non_tty() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/myrepo"
    _rsv_unit "$tmp" myrepo "$_RSV_MIXED_YML"
    seed_index_path myrepo "$tmp/myrepo"
    local out
    out=$(
        export LLMS_DIR="$tmp/llms"; mkdir -p "$LLMS_DIR/svelte"     # llms installed → only pack unresolved
        export PACKS_DIR="$tmp/packs"; mkdir -p "$PACKS_DIR"
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/yaml.sh"; source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/index.sh"; source "$REPO_ROOT/lib/local-paths.sh"
        source "$REPO_ROOT/lib/packs.sh"; source "$REPO_ROOT/lib/cmd-resolve.sh"
        _cco_have_tty() { return 1; }                               # headless
        _resolve_unit "$tmp/myrepo" 2>&1
    )
    [[ "$out" == *"pack 'team-pack' not installed"* ]] \
        || fail "Expected non-TTY warn for missing pack, got: $out"
    [[ "$out" == *"cco pack install https://github.com/org/sharing.git --pick team-pack"* ]] \
        || fail "Expected an executable install hint, got: $out"
}

test_resolve_pack_tty_invokes_heal() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/myrepo"
    _rsv_unit "$tmp" myrepo "$_RSV_MIXED_YML"
    seed_index_path myrepo "$tmp/myrepo"
    local out
    out=$(
        export LLMS_DIR="$tmp/llms"; mkdir -p "$LLMS_DIR/svelte"     # llms installed → skip
        export PACKS_DIR="$tmp/packs"; mkdir -p "$PACKS_DIR"
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/yaml.sh"; source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/index.sh"; source "$REPO_ROOT/lib/local-paths.sh"
        source "$REPO_ROOT/lib/packs.sh"; source "$REPO_ROOT/lib/cmd-resolve.sh"
        _cco_have_tty() { return 0; }                               # terminal reachable
        _resolve_pack_entry() { mkdir -p "$PACKS_DIR/$1"; return 0; }   # stub a successful install
        _resolve_unit "$tmp/myrepo" >/dev/null 2>&1
        [[ -d "$PACKS_DIR/team-pack" ]] && echo HEALED
    )
    [[ "$out" == *HEALED* ]] || fail "TTY resolve must route a missing pack to the heal path"
}

test_resolve_status_render_lists_all_kinds() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/myrepo"
    _rsv_unit "$tmp" myrepo "$_RSV_MIXED_YML"
    seed_index_path myrepo "$tmp/myrepo"
    local out
    out=$(
        export LLMS_DIR="$tmp/llms"; mkdir -p "$LLMS_DIR"            # svelte NOT installed
        export PACKS_DIR="$tmp/packs"; mkdir -p "$PACKS_DIR"          # team-pack NOT present
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/yaml.sh"; source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/index.sh"; source "$REPO_ROOT/lib/local-paths.sh"
        source "$REPO_ROOT/lib/packs.sh"; source "$REPO_ROOT/lib/cmd-resolve.sh"
        _resolve_render_status "$tmp/myrepo" 2>&1
    )
    [[ "$out" == *"Referenced resources:"* ]] || fail "status header missing: $out"
    [[ "$out" == *"myrepo"*"✓"* ]]            || fail "resolved repo must show ✓: $out"
    [[ "$out" == *"svelte"*"unresolved"* ]]   || fail "unresolved llms must show: $out"
    [[ "$out" == *"team-pack"*"unresolved"* ]] || fail "unresolved pack must show: $out"
}

# Regression (ADR-0033 / B): _resolve_unit must keep the unit locatable by-name
# after recording membership, even when the host repo (bearing .cco/project.yml)
# is NOT listed in the manifest repos:. Before the host-inclusion fix, a second
# resolve overwrote membership with the repos: names only, dropping the sole
# locatable member and breaking `cco start <name>` on the next run (the
# workspace.yml-idempotency regression).
test_resolve_membership_includes_host_repo() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/hostrepo" "$tmp/memberonly"
    _rsv_unit "$tmp" hostrepo 'name: demo
repos:
  - name: memberonly'
    seed_index_path hostrepo "$tmp/hostrepo"
    seed_index_path memberonly "$tmp/memberonly"
    local out
    out=$(
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/yaml.sh"; source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/index.sh"; source "$REPO_ROOT/lib/local-paths.sh"
        source "$REPO_ROOT/lib/packs.sh"; source "$REPO_ROOT/lib/cmd-resolve.sh"
        _cco_have_tty() { return 1; }
        _resolve_unit "$tmp/hostrepo" >/dev/null 2>&1   # first pass records membership
        _resolve_unit "$tmp/hostrepo" >/dev/null 2>&1   # second pass must not drop the host
        _resolve_unit_dir_for_project demo               # must still relocate the unit
    )
    [[ "$out" == "$tmp/hostrepo" ]] \
        || fail "by-name resolution must relocate the unit after repeated resolve, got: $out"
}

# ── A.4 add-time disambiguation (ADR-0051 D4) ────────────────────────────────
# When a repo/mount name already exists in OTHER projects, resolution surfaces the
# existing paths and lets the user REUSE one (same resource) or specify a fresh
# path (a homonym). A cross-project name match is a reuse-or-homonym choice, not a
# collision. url divergence (git origin ≠ the incoming coordinate) is flagged.

_da_src() {
    source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/yaml.sh";   source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/index.sh";  source "$REPO_ROOT/lib/local-paths.sh"
    source "$REPO_ROOT/lib/cmd-resolve.sh"
}

test_resolve_disambiguate_lists_other_project_bindings() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/be-a" "$tmp/be-b"
    seed_index_path backend "$tmp/be-a" proj-a
    seed_index_path backend "$tmp/be-b" proj-b

    CCO_OUTPUT=$( _da_src; _resolve_reuse_menu backend extra_mounts "" proj-c )
    assert_output_contains "$tmp/be-a" || return 1
    assert_output_contains "$tmp/be-b" || return 1
    assert_output_contains "already bound in other projects" || return 1
}

test_resolve_disambiguate_excludes_self_project() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/be-a" "$tmp/be-b"
    seed_index_path backend "$tmp/be-a" proj-a
    seed_index_path backend "$tmp/be-b" proj-b

    CCO_OUTPUT=$( _da_src; _resolve_name_reuse_candidates backend proj-a )
    assert_output_contains "$tmp/be-b" || return 1
    if printf '%s' "$CCO_OUTPUT" | grep -qF "$tmp/be-a"; then
        fail "reuse candidates must exclude the querying project's own binding"
    fi
}

test_resolve_disambiguate_flags_url_divergence() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/be-a"
    seed_index_path backend "$tmp/be-a" proj-a
    git -C "$tmp/be-a" init -q
    git -C "$tmp/be-a" remote add origin https://example.com/OTHER.git

    CCO_OUTPUT=$( _da_src; _resolve_reuse_menu backend repos https://example.com/backend.git proj-c )
    assert_output_contains "probably a different resource" || return 1
    assert_output_contains "OTHER.git" || return 1
}

test_resolve_disambiguate_no_candidates_returns_1() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local rc=0
    ( _da_src; _resolve_reuse_menu loner repos "" proj-c ) >/dev/null || rc=$?
    [[ $rc -eq 1 ]] || fail "a name bound in no other project must yield no menu (rc=1, got $rc)"
}

test_resolve_reuse_binds_the_chosen_path() {
    # Integration: on a TTY, _resolve_entry_index offers reuse first; when the user
    # picks an existing other-project path it is bound into THIS project's scope
    # (the explicit (V) convenience) without touching project.yml.
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/shared"
    seed_index_path backend "$tmp/shared" proj-a
    _rsv_unit "$tmp" hostrepo 'name: demo
repos:
  - name: hostrepo
extra_mounts:
  - name: backend
    target: /workspace/backend'
    seed_index_path hostrepo "$tmp/hostrepo" demo

    (
        _da_src
        _cco_have_tty()        { return 0; }
        # Stub the interactive picker: user reuses proj-a's existing path.
        _resolve_disambiguate() { printf '%s\n' "$tmp/shared"; return 0; }
        _resolve_unit "$tmp/hostrepo" >/dev/null 2>&1
    )

    local got
    got=$( _da_src; _index_get_path demo backend )
    [[ "$got" == "$tmp/shared" ]] \
        || fail "reuse must bind demo/backend to the chosen path, got: '$got'"
}

test_resolve_homonym_mounts_coexist() {
    # ADR-0051 D4 case 2: two projects with a generic 'assets' mount at DIFFERENT
    # paths coexist — each keeps its own scoped binding, never merged.
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/a-assets" "$tmp/b-assets"
    seed_index_path assets "$tmp/a-assets" proj-a
    seed_index_path assets "$tmp/b-assets" proj-b

    local pa pb
    pa=$( _da_src; _index_get_path proj-a assets )
    pb=$( _da_src; _index_get_path proj-b assets )
    [[ "$pa" == "$tmp/a-assets" ]] || fail "proj-a/assets must stay its own path, got: '$pa'"
    [[ "$pb" == "$tmp/b-assets" ]] || fail "proj-b/assets must stay its own path, got: '$pb'"
}

# ── cco path set — quote hygiene (ADR-0050 D8 / B.5) ─────────────────
# A path pasted with surrounding shell quotes must absolutize to the literal
# directory, not a bogus quoted string (analysis §9.2).

test_path_set_strips_surrounding_single_quotes() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local d="$tmp/pasted/repo"; mkdir -p "$d"
    run_cco path set myrepo "'$d'" || fail "path set failed: $CCO_OUTPUT" || return 1
    assert_output_contains "-> $d" || return 1
    assert_output_not_contains "'$d'" || return 1
}

test_path_set_strips_surrounding_double_quotes() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local d="$tmp/pasted/repo2"; mkdir -p "$d"
    run_cco path set myrepo "\"$d\"" || fail "path set failed: $CCO_OUTPUT" || return 1
    assert_output_contains "-> $d" || return 1
}

# ── Read-path honesty: empty ≠ unreadable (v3 R3 / S4) ────────────────
#
# T-R3, the behavioural guard for the read half of the R1 symptom set. The verb
# reads the index through `done < <(_index_pp_dump_all; …)`, and a process
# substitution DISCARDS its status — so a permission-denied, truncated or
# stranded index fell through to the count==0 branch and was announced as an
# empty index at rc=0 (v3 V2-F02). The user is told the opposite of the truth on
# the one question they asked.
#
# Assertions (b) and (c) are what make this a guard rather than a smoke test: a
# fix that returned non-zero while still printing "the path index is empty", or
# that went quiet without naming a cause, still fails here.
# ⚠ FAILS on pre-fix code: rc=0 with "the path index is empty".
test_path_list_unreadable_index_fails_loud() {
    [[ "$(id -u)" -eq 0 ]] && return 0   # root ignores the mode bits
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"

    _rsv_unit "$tmp/dev" repo1 "$_RSV_TWO_REPO_YML"
    run_cco resolve --scan "$tmp/dev" || return 1

    local idx; idx=$(_rsv_index_file)
    chmod 000 "$idx"
    local rc=0
    _rsv_cco_in "$tmp" path list || rc=$?
    chmod 644 "$idx"

    # (a) an ERROR (exit 1, D8 — a broken dependency, not a policy refusal), and
    #     above all never rc=0
    assert_rc 1 "$rc" "path list on an unreadable index" || return 1
    # (b) it must NOT claim the index is empty — the false-success class itself
    [[ "$CCO_OUTPUT" != *"index is empty"* ]] \
        || { fail "an unreadable index must not be reported as an empty one: $CCO_OUTPUT"; return 1; }
    # (c) the message names the real cause, so the user can act on it
    [[ "$CCO_OUTPUT" == *"cannot be read"* ]] \
        || { fail "the failure must name the real cause: $CCO_OUTPUT"; return 1; }
    return 0
}

# The vocabulary half of R3, at the verb. In a session `cco resolve` is HOST-ONLY
# (bin/cco's operator gate refuses it), so pointing the agent at it is advice the
# shim rejects — the string RC-2 retired, still live on this path because cycle 1
# never audited it. Asserted on BOTH surfaces the stage touches, since the
# failure and the honest-empty arms carry separate sentences and a fix to one
# does not imply the other.
test_path_list_operator_never_emits_the_retired_resolve_hint() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" read-all

    # (1) the honest-EMPTY arm: a readable index holding nothing.
    local idx; idx=$(_rsv_index_file)
    mkdir -p "$(dirname "$idx")"
    printf 'version: 2\nprojects:\nproject_paths:\nllms:\nunscoped:\n' > "$idx"
    local rc=0
    _rsv_cco_in "$tmp" path list || rc=$?
    assert_rc 0 "$rc" "path list on a genuinely empty index" || return 1
    [[ "$CCO_OUTPUT" == *"empty"* ]] \
        || { fail "an empty index must still be announced as empty: $CCO_OUTPUT"; return 1; }
    [[ "$CCO_OUTPUT" != *"cco resolve"* ]] \
        || { fail "in a session the empty-index remedy must not name host-only 'cco resolve': $CCO_OUTPUT"; return 1; }

    # (2) the FAILURE arm: same rule, different sentence.
    chmod 000 "$idx"
    rc=0
    _rsv_cco_in "$tmp" path list || rc=$?
    chmod 644 "$idx"
    assert_rc 1 "$rc" "path list on an unreadable index (operator)" || return 1
    [[ "$CCO_OUTPUT" != *"cco resolve"* ]] \
        || { fail "in a session the failure remedy must not name host-only 'cco resolve': $CCO_OUTPUT"; return 1; }
    [[ "$CCO_OUTPUT" == *"host"* ]] \
        || { fail "the session remedy must point at the host: $CCO_OUTPUT"; return 1; }
    return 0
}

# ── S2b item 3: `cco path set` is the repair command — it must not lie ─────────
# The index write IS this verb; nothing else lands. Called bare, a failed write made
# it a complete no-op that printed "✓ path set". It matters more than its size
# suggests: several other S2b failure messages point the user HERE to repair a
# missing binding, so a silent no-op would strand them in a loop.
# ⚠ FAILS on pre-fix: rc=0 and the ✓ prints over an unwritten index.
test_path_set_unwritable_index_fails_loud() {
    [[ "$(id -u)" -eq 0 ]] && return 0   # root ignores the mode bits
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/somewhere" "$(state_shared)"

    chmod 555 "$(state_shared)"
    local out rc=0
    out=$(CCO_USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR" CCO_PACKS_DIR="$CCO_PACKS_DIR" \
          CCO_TEMPLATES_DIR="$CCO_TEMPLATES_DIR" CCO_LLMS_DIR="$CCO_LLMS_DIR" \
          bash "$REPO_ROOT/bin/cco" path set thing "$tmp/somewhere" 2>&1) || rc=$?
    chmod 755 "$(state_shared)"

    [[ "$rc" -ne 0 ]] \
        || { fail "an unwritable index must fail loud; got rc=0: $out"; return 1; }
    [[ "$out" != *"path set:"* ]] \
        || { fail "no '✓ path set' over a binding that was never written: $out"; return 1; }
    return 0
}

# A partial `--scan` must not exit 0: the summary line ("N binding(s) upserted") is
# the number the user reads to decide the sweep worked, and a swallowed failure both
# deflates it and hides that the index is now incomplete. The scan still sweeps every
# unit — it counts failures rather than abandoning the rest on the first one.
# ⚠ FAILS on pre-fix: rc=0 with a clean-looking summary.
test_resolve_scan_partial_failure_is_not_success() {
    [[ "$(id -u)" -eq 0 ]] && return 0   # root ignores the mode bits
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/dev/alpha/.cco" "$(state_shared)"
    printf 'name: alpha\nrepos:\n  - name: alpha\n' > "$tmp/dev/alpha/.cco/project.yml"

    chmod 555 "$(state_shared)"
    local out rc=0
    out=$(CCO_USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR" CCO_PACKS_DIR="$CCO_PACKS_DIR" \
          CCO_TEMPLATES_DIR="$CCO_TEMPLATES_DIR" CCO_LLMS_DIR="$CCO_LLMS_DIR" \
          bash "$REPO_ROOT/bin/cco" resolve --scan "$tmp/dev" 2>&1) || rc=$?
    chmod 755 "$(state_shared)"

    [[ "$rc" -ne 0 ]] \
        || { fail "a scan whose index writes failed must not exit 0: $out"; return 1; }
    [[ "$out" == *"incomplete"* ]] \
        || { fail "the summary must say the sweep is incomplete: $out"; return 1; }
    return 0
}
