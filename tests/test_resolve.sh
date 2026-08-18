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

# ── A8 — the onboarding prompts (ADR-0059 D13/D14) ───────────────────────────
#
# ⚠ WHY THE BODY IS PATCHED, stated rather than implied. Both prompts end in
# `read -r reply < /dev/tty`, and a hermetic run has no controlling terminal — the
# same constraint design §6.2 records for the gate. The choice was: leave the read
# half untested, drive a pty (BSD `script` takes different arguments, and a pty
# test invites the capture-hang class), or run the REAL body with only the tty read
# replaced. This does the third. Everything else — the rendering, the case, the
# absolutization — is the shipped code, read out of lib/local-paths.sh at run time.
#
# The patch proves it applied: an unpatched body would block on /dev/tty forever
# rather than fail an assertion, so _p8_body refuses to return one.

_P8_REPLIES=""

# Pop the next queued reply into <varname> (one per patched read).
# ⚠ NOT a command substitution: `reply=$(_p8_reply)` pops in a SUBSHELL, so the
# queue never advances and every read replays the first answer.
_p8_reply() {
    local __v="$1" __r="${_P8_REPLIES%%$'\n'*}"
    _P8_REPLIES="${_P8_REPLIES#*$'\n'}"
    printf -v "$__v" '%s' "$__r"
}

# Echo <fn>'s body from lib/local-paths.sh, tty read → queue pop. rc 1 if the
# substitution found nothing to replace.
_p8_body() {
    local body src="${2:-$REPO_ROOT/lib/local-paths.sh}"
    body=$(awk -v want="^$1\\(\\)" '$0 ~ want { inside=1 } inside { print } inside && /^}/ { exit }' \
             "$src" | sed '1d;$d' \
           | sed 's#read -r reply < /dev/tty#_p8_reply reply#')
    [[ -n "$body" ]] || return 1
    case "$body" in *"/dev/tty"*) return 1 ;; esac
    printf '%s\n' "$body"
}

# Run <fn>'s patched body with the remaining arguments as its positionals.
_p8_run() {
    local _fn="$1"; shift
    local _body
    _body=$(_p8_body "$_fn") || { echo "HARNESS: the tty read was not patched out of $_fn" >&2; return 99; }
    eval "$_body"
}

# The harness's own oracle: it must REFUSE a body it failed to patch. Without
# this, a reworded read line would leave `< /dev/tty` in place and the suite would
# block forever instead of failing — the capture-hang class, one layer up.
test_p8_harness_refuses_a_body_it_could_not_patch() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    printf '%s\n' 'f() {' '    read -r reply </dev/tty' '}' > "$tmp/src.sh"   # no space: sed misses it
    local rc=0
    _p8_body f "$tmp/src.sh" >/dev/null || rc=$?
    [[ $rc -eq 1 ]] || { fail "_p8_body must refuse a body that still reads /dev/tty (rc=$rc)"; return 1; }

    printf '%s\n' 'f() {' '    read -r reply < /dev/tty' '}' > "$tmp/src.sh"  # the real spelling
    rc=0
    _p8_body f "$tmp/src.sh" >/dev/null || rc=$?
    [[ $rc -eq 0 ]] || { fail "_p8_body must accept the spelling it patches (rc=$rc)"; return 1; }
}

# ── D13 — the clone prompt offers its destination and accepts an override ────

# Source + stub: a TTY that is not there, and a git that clones nothing.
_p8_src() {
    _da_src
    _cco_have_tty() { return 0; }
    git() { [[ "$1" == "clone" ]] && { mkdir -p "$3"; return 0; }; command git "$@"; }
}

test_clone_prompt_renders_its_destination_and_enter_accepts_it() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"

    local out
    out=$(
        exec 2>"$tmp/err"
        _p8_src
        _P8_REPLIES=$'c\n\n'          # (c), then bare Enter
        _p8_run _prompt_for_path backend https://ex.com/b.git "$tmp/dev/backend" Repository
    )
    CCO_OUTPUT=$(cat "$tmp/err")
    assert_output_contains "Clone into [$tmp/dev/backend]" || return 1
    assert_equals "$tmp/dev/backend" "$out" "bare Enter must accept the destination the prompt offered"
}

test_clone_prompt_accepts_an_override() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"

    local out
    out=$(
        exec 2>/dev/null
        _p8_src
        _P8_REPLIES=$'c\n'"$tmp/elsewhere/backend"$'\n'
        _p8_run _prompt_for_path backend https://ex.com/b.git "$tmp/dev/backend" Repository
    )
    assert_equals "$tmp/elsewhere/backend" "$out" "the answer to 'Clone into' must be where the clone lands (D13)"
}

# The mount case is the one FI-69 was reported from: `suggested` is computed only
# for repos (local-paths.sh:489-494), so a mount is hard-wired to ~/Projects/<name>
# — a location unrelated to where the user keeps mounts, and (p) is no escape
# because it demands an existing path. The override is what stops that being a trap.
test_clone_prompt_lets_a_mount_escape_the_home_projects_fallback() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"

    local out
    out=$(
        exec 2>"$tmp/err"
        _p8_src
        _P8_REPLIES=$'c\n'"$tmp/mnt/assets"$'\n'
        _p8_run _prompt_for_path assets https://ex.com/a.git "" Mount    # no suggestion
    )
    CCO_OUTPUT=$(cat "$tmp/err")
    assert_output_contains "Clone into [$HOME/Projects/assets]" || return 1
    assert_equals "$tmp/mnt/assets" "$out" "a mount must be able to clone somewhere other than ~/Projects" || return 1
}

# M7: the override is absolutized like (p)'s answer — a relative path stored in the
# index resolves wrong from any other cwd.
test_clone_prompt_absolutizes_a_relative_override() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/cwd"

    local out
    out=$(
        exec 2>/dev/null
        cd "$tmp/cwd" || exit 1
        _p8_src
        _P8_REPLIES=$'c\nsub/backend\n'
        _p8_run _prompt_for_path backend https://ex.com/b.git "$tmp/dev/backend" Repository
    )
    assert_equals "$(cd "$tmp/cwd" && pwd -P)/sub/backend" "$out" "a relative override must be absolutized (M7)" || return 1
}

# ── T13 / D14 — the reuse prompt accepts the token it printed ────────────────
#
# FI-70 in one line: the prompt printed `[1-1]` and the parser rejected `1-1`. The
# test therefore does what the user did — READS the token off the rendered line and
# types it back. Asserting the parser alone would have passed throughout the defect.

# Echo the token the choice line offers for reuse, as rendered.
_p8_printed_token() {
    printf '%s\n' "$1" | sed -n 's/^ *\[\([^]]*\)\].*reuse that path.*/\1/p'
}

test_reuse_prompt_accepts_the_single_candidate_token_it_printed() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/be-a"
    seed_index_path backend "$tmp/be-a" proj-a

    # Pass 1 — read the token off the rendered line ([d] leaves without side effects).
    ( exec 2>"$tmp/err"; _p8_src; _P8_REPLIES=$'d\n'; _p8_run _resolve_disambiguate backend extra_mounts "" proj-c ) >/dev/null
    local rendered; rendered=$(cat "$tmp/err")
    local tok; tok=$(_p8_printed_token "$rendered")
    [[ -n "$tok" ]] || { fail "the choice line offered no reuse token at all: $rendered"; return 1; }

    # Pass 2 — type it back, verbatim.
    local out rc=0
    out=$( exec 2>/dev/null; _p8_src; _P8_REPLIES="$tok"$'\n'; _p8_run _resolve_disambiguate backend extra_mounts "" proj-c ) || rc=$?
    assert_equals "0" "$rc" "the token the prompt printed ('$tok') must be accepted when typed back" || return 1
    assert_equals "$tmp/be-a" "$out" "accepting '$tok' must reuse that candidate's path" || return 1
}

test_reuse_prompt_renders_literal_tokens_never_a_range() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/be-a" "$tmp/be-b"
    seed_index_path backend "$tmp/be-a" proj-a
    seed_index_path backend "$tmp/be-b" proj-b

    ( exec 2>"$tmp/err"; _p8_src; _P8_REPLIES=$'d\n'; _p8_run _resolve_disambiguate backend extra_mounts "" proj-c ) >/dev/null
    CCO_OUTPUT=$(cat "$tmp/err")
    assert_output_contains "[1] [2] reuse that path" || return 1

    # And the LAST token is accepted too — a range that happened to read right at
    # the low end would still be wrong at the high one.
    local out rc=0
    out=$( exec 2>/dev/null; _p8_src; _P8_REPLIES=$'2\n'; _p8_run _resolve_disambiguate backend extra_mounts "" proj-c ) || rc=$?
    assert_equals "0" "$rc" "the last rendered token must be accepted" || return 1
    assert_equals "$tmp/be-b" "$out" "token [2] must reuse the second candidate" || return 1
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
# zero-row and the unreadable arms carry separate sentences and a fix to one does
# not imply the other.
#
# ⚠ ARM (1)'s CONTRACT CHANGED in S6, deliberately — this is not a test bent to
# fit the code. ADR-0056's ratified annotation "D6 — extended to a zero-row index
# in a session (S6)" removes the premise this arm was written on: there is no
# "genuinely empty index" in a session, because a session is LAUNCHED from the
# index. What the arm exists to guard — the R3 vocabulary rule — is unchanged and
# still asserted here; only the answer it guards moved from a benign rc=0 line to
# a refusal. The benign arm did not disappear: it is asserted on the HOST, in
# tests/test_index_session_axis.sh (…_stays_benign_on_the_host, and the verb-level
# …_verbs_stay_benign_on_the_host).
test_path_list_operator_never_emits_the_retired_resolve_hint() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" read-all

    # (1) the ZERO-ROW arm: a present, readable, non-zero index holding nothing.
    local idx; idx=$(_rsv_index_file)
    mkdir -p "$(dirname "$idx")"
    printf 'version: 2\nprojects:\nproject_paths:\nllms:\nunscoped:\n' > "$idx"
    local rc=0
    _rsv_cco_in "$tmp" path list || rc=$?
    assert_rc 1 "$rc" "path list on a zero-row index inside a session" || return 1
    [[ "$CCO_OUTPUT" != *"nothing is registered on this machine yet"* ]] \
        || { fail "a session is launched from the index — it may not be told nothing is registered on this machine: $CCO_OUTPUT"; return 1; }
    [[ "$CCO_OUTPUT" != *"cco resolve"* ]] \
        || { fail "in a session the empty-index remedy must not name host-only 'cco resolve': $CCO_OUTPUT"; return 1; }
    [[ "$CCO_OUTPUT" == *"host"* ]] \
        || { fail "the session remedy must point at the host: $CCO_OUTPUT"; return 1; }

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

# ── N3: q/Exit honours the exit (ADR-0052 §6) ────────────────────────
# A user Exit ([q]) at a heal prompt surfaces rc=2 from the per-entry healers.
# _resolve_unit must PROPAGATE it (return 2, not the old swallow-to-0), so
# `cco start` aborts before booting and `cco resolve[/--all]` stop cleanly.

_RSV_N3_YML='name: demo
repos:
  - name: repo1
    url: https://example.com/repo1.git'

# The heal loop reaches _resolve_entry_index only for an UNRESOLVED member; a stub
# returning 2 stands in for the user pressing [q] at the clone/path prompt.
test_resolve_unit_propagates_user_quit_rc2() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _rsv_unit "$tmp" myrepo "$_RSV_N3_YML"          # repo1 has no index binding → unresolved
    local rc=0
    (
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/yaml.sh"; source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/index.sh"; source "$REPO_ROOT/lib/local-paths.sh"
        source "$REPO_ROOT/lib/cmd-resolve.sh"
        _cco_have_tty()        { return 0; }
        _resolve_entry_index() { return 2; }         # user pressed [q]
        _resolve_unit "$tmp/myrepo"
    ) >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 2 ]] \
        || fail "a user Exit must propagate as rc=2 from _resolve_unit, got: $rc"
}

# The crux of N3 (per the 2026-07-22 incident): Exit at a SUBSEQUENT unresolved
# member, AFTER an earlier one was resolved (e.g. via [p]ath), must still abort —
# not just Exit at the very first prompt. The old `2) return 0` swallowed it, so the
# loop fell through to the membership write + success and the start booted. Here the
# first member resolves (rc=0) and the SECOND is quit (rc=2): rc=2 must propagate.
_RSV_N3_TWO_YML='name: demo
repos:
  - name: repoA
    url: https://example.com/a.git
  - name: repoB
    url: https://example.com/b.git'

test_resolve_unit_propagates_quit_at_subsequent_member() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _rsv_unit "$tmp" myrepo "$_RSV_N3_TWO_YML"       # repoA + repoB both unresolved
    local rc=0
    (
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/yaml.sh"; source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/index.sh"; source "$REPO_ROOT/lib/local-paths.sh"
        source "$REPO_ROOT/lib/cmd-resolve.sh"
        _cco_have_tty() { return 0; }
        # 1st member → resolved ([p]ath, rc=0); 2nd member → Exit ([q], rc=2).
        _N3_ROUND=0
        _resolve_entry_index() {
            _N3_ROUND=$((_N3_ROUND + 1))
            [[ $_N3_ROUND -ge 2 ]] && return 2 || return 0
        }
        _resolve_unit "$tmp/myrepo"
    ) >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 2 ]] \
        || fail "Exit at a SUBSEQUENT member (after an earlier resolve) must propagate rc=2, got: $rc"
}

# A SKIP (rc=1) is not an abort — _resolve_unit stays best-effort (counts the
# unresolved member, returns 0). This guards against over-propagating.
test_resolve_unit_skip_is_not_an_abort() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _rsv_unit "$tmp" myrepo "$_RSV_N3_YML"
    local rc=0
    (
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/yaml.sh"; source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/index.sh"; source "$REPO_ROOT/lib/local-paths.sh"
        source "$REPO_ROOT/lib/cmd-resolve.sh"
        _cco_have_tty()        { return 0; }
        _resolve_entry_index() { return 1; }         # user chose [s]kip
        _resolve_unit "$tmp/myrepo"
    ) >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 0 ]] \
        || fail "a skip must NOT abort — _resolve_unit should return 0, got: $rc"
}

# cmd_resolve maps rc=2 to a clean exit (0) and skips the post-heal status render.
test_cmd_resolve_honours_user_quit() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _rsv_unit "$tmp" myrepo "$_RSV_N3_YML"
    local out rc=0
    out=$(
        {
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/yaml.sh"; source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/index.sh"; source "$REPO_ROOT/lib/local-paths.sh"
        source "$REPO_ROOT/lib/cmd-resolve.sh"
        _resolve_find_unit_dir()   { printf '%s\n' "$tmp/myrepo"; }
        _resolve_unit()            { return 2; }             # user Exit
        _resolve_render_status()   { echo "STATUS-RENDERED"; }
        cmd_resolve
        } 2>&1
    ) || rc=$?
    [[ $rc -eq 0 ]] \
        || fail "cco resolve must exit cleanly (0) on a user Exit, got: $rc"
    [[ "$out" == *"stopped at your request"* ]] \
        || fail "cco resolve must acknowledge the Exit, got: $out"
    [[ "$out" != *"STATUS-RENDERED"* ]] \
        || fail "cco resolve must NOT render the status after an Exit, got: $out"
}

# _start_resolve_paths turns a resolve Exit into a start ABORT (return 2), which
# cmd_start maps to a clean no-boot exit. Here we assert the propagation.
test_start_resolve_paths_aborts_on_user_quit() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/myrepo/.cco"
    local rc=0
    (
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/yaml.sh"; source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/access-scope.sh"; source "$REPO_ROOT/lib/cmd-start.sh"
        is_internal=false
        project_dir="$tmp/myrepo/.cco"
        _resolve_unit() { return 2; }                # user Exit at a mount prompt
        _start_resolve_paths
    ) >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 2 ]] \
        || fail "_start_resolve_paths must propagate a user Exit as rc=2 (start abort), got: $rc"
}

# FI-27 / ADR-0053: _resolve_to_abs canonicalizes its output (symlink + /.), so the
# value it feeds to BOTH the pre-write AD5' conflict check and the write is the same
# canonical spelling the writer would store.
test_resolve_to_abs_canonicalizes_path() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    mkdir -p "$tmpdir/real"
    ln -sfn "$tmpdir/real" "$tmpdir/link"
    local phys; phys=$(cd "$tmpdir/real" && pwd -P)
    local got
    got=$(
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/paths.sh"; source "$REPO_ROOT/lib/index.sh"
        source "$REPO_ROOT/lib/cmd-resolve.sh"
        _resolve_to_abs "$tmpdir/link"
    )
    [[ "$got" == "$phys" ]] || fail "_resolve_to_abs must resolve the symlink (got '$got', want '$phys')"
    got=$(
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/paths.sh"; source "$REPO_ROOT/lib/index.sh"
        source "$REPO_ROOT/lib/cmd-resolve.sh"
        _resolve_to_abs "$tmpdir/real/."
    )
    [[ "$got" == "$phys" ]] || fail "_resolve_to_abs must collapse a trailing /. (got '$got', want '$phys')"
}
