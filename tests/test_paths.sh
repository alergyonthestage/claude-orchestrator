#!/usr/bin/env bash
# tests/test_paths.sh — update-engine artifact path helpers (STATE-relocated, H6)
#
# After P2, the merge artifacts (meta/base) live in STATE keyed by identity:
# <state>/cco/{global,projects/<id>,packs/<name>}/update/{meta,base}, where the
# project <id> is the project.yml `name:` (ADR-0024 D1 / design §2.2).

# ── Project Meta — keyed by identity in STATE (H6) ───────────────────

test_paths_project_meta_new_path() {
    # <id> comes from the hosted .cco/project.yml `name:`, NOT the dir basename.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export CCO_STATE_HOME="$tmpdir/state" CCO_ALLOW_HOST_RESOLVE=1
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local proj="$tmpdir/repo-dir"
    mkdir -p "$proj/.cco"
    printf 'name: myproj\n' > "$proj/.cco/project.yml"

    local result; result=$(_cco_project_meta "$proj")
    [[ "$result" == "$tmpdir/state/projects/myproj/update/meta" ]] \
        || fail "Expected STATE meta keyed by project name, got: $result"
}

test_paths_project_meta_old_fallback() {
    # Legacy root-level project.yml (central layout) still yields the name.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export CCO_STATE_HOME="$tmpdir/state" CCO_ALLOW_HOST_RESOLVE=1
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local proj="$tmpdir/project"
    mkdir -p "$proj"
    printf 'name: rootproj\n' > "$proj/project.yml"

    local result; result=$(_cco_project_meta "$proj")
    [[ "$result" == "$tmpdir/state/projects/rootproj/update/meta" ]] \
        || fail "Expected STATE meta from legacy root project.yml name, got: $result"
}

test_paths_project_meta_default_new() {
    # No project.yml → fall back to the dir basename as the identity.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export CCO_STATE_HOME="$tmpdir/state" CCO_ALLOW_HOST_RESOLVE=1
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local proj="$tmpdir/project"
    mkdir -p "$proj"

    local result; result=$(_cco_project_meta "$proj")
    [[ "$result" == "$tmpdir/state/projects/project/update/meta" ]] \
        || fail "Expected STATE meta from dir-basename fallback, got: $result"
}

# ── Project Managed ──────────────────────────────────────────────────
# The _cco_project_managed / _cco_project_compose dual-read helpers were removed as
# dead code (M10 — no production callers; managed→CACHE, compose→STATE now). Their
# tests went with them.

# ── Remotes registry (M3 split: url->DATA, token->STATE) ─────────────

test_paths_remotes_file_in_data() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    local rf; rf=$( export HOME="$tmp/home" CCO_ALLOW_HOST_RESOLVE=1 CCO_DATA_HOME="$tmp/data"; _cco_remotes_file )
    [[ "$rf" == "$tmp/data/remotes" ]] || fail "Expected remotes in DATA, got: $rf"
}

test_paths_remotes_token_file_in_state() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    local tf; tf=$( export HOME="$tmp/home" CCO_ALLOW_HOST_RESOLVE=1 CCO_STATE_HOME="$tmp/state"; _cco_remotes_token_file )
    [[ "$tf" == "$tmp/state/remotes-token" ]] || fail "Expected remotes-token in STATE, got: $tf"
}

# ── Pack Source ──────────────────────────────────────────────────────

# Install-provenance `source` → DATA, identity-keyed (ADR-0022 D1). The helper
# resolves unconditionally to <data>/cco/packs/<name>/source — no in-tree
# fallback (the source no longer lives in the config/pack bucket).
test_paths_pack_source_data_keyed() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export USER_CONFIG_DIR="$tmpdir/uc"
    export CCO_DATA_HOME="$tmpdir/data" CCO_ALLOW_HOST_RESOLVE=1
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local pack="$tmpdir/packs/pack-a"
    mkdir -p "$pack"
    # Even with a stale in-tree .cco/source, the helper resolves to DATA.
    mkdir -p "$pack/.cco"; echo "url: git@example.com:pack.git" > "$pack/.cco/source"

    local result; result=$(_cco_pack_source "$pack")
    [[ "$result" == "$tmpdir/data/packs/pack-a/source" ]] \
        || fail "Expected DATA-keyed pack source, got: $result"
}

test_paths_template_source_data_keyed() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export USER_CONFIG_DIR="$tmpdir/uc"
    export CCO_DATA_HOME="$tmpdir/data" CCO_ALLOW_HOST_RESOLVE=1
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local tmpl="$tmpdir/templates/tmpl-a"
    mkdir -p "$tmpl"
    local result; result=$(_cco_template_source "$tmpl")
    [[ "$result" == "$tmpdir/data/templates/tmpl-a/source" ]] \
        || fail "Expected DATA-keyed template source, got: $result"
}

# ── Pack Install Tmp ─────────────────────────────────────────────────

test_paths_pack_install_tmp_new_path() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export USER_CONFIG_DIR="$tmpdir/uc"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local pack="$tmpdir/pack-a"
    mkdir -p "$pack/.cco/install-tmp"

    local result; result=$(_cco_pack_install_tmp "$pack")
    [[ "$result" == "$pack/.cco/install-tmp" ]] || fail "Expected new install-tmp path, got: $result"
}

test_paths_pack_install_tmp_old_fallback() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export USER_CONFIG_DIR="$tmpdir/uc"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local pack="$tmpdir/pack-a"
    mkdir -p "$pack/.cco-install-tmp"

    local result; result=$(_cco_pack_install_tmp "$pack")
    [[ "$result" == "$pack/.cco-install-tmp" ]] || fail "Expected old .cco-install-tmp fallback, got: $result"
}

test_paths_pack_install_tmp_default_new() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export USER_CONFIG_DIR="$tmpdir/uc"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local pack="$tmpdir/pack-a"
    mkdir -p "$pack"

    local result; result=$(_cco_pack_install_tmp "$pack")
    [[ "$result" == "$pack/.cco/install-tmp" ]] || fail "Expected new install-tmp default, got: $result"
}

# ── XDG 4-bucket resolver (T1: ADR-0007/0015) ────────────────────────
# Helper (not a test_* function, so the runner does not execute it as a test):
# portable file-mode reader (GNU stat vs BSD/macOS stat).
_paths_stat_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# Defaults: with no overrides, each bucket resolves under $HOME.
test_paths_xdg_defaults() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local config data state cache
    config=$( export HOME="$tmp/home" CCO_ALLOW_HOST_RESOLVE=1; _cco_config_dir )
    data=$(   export HOME="$tmp/home" CCO_ALLOW_HOST_RESOLVE=1; unset CCO_DATA_HOME XDG_DATA_HOME;   _cco_data_dir )
    state=$(  export HOME="$tmp/home" CCO_ALLOW_HOST_RESOLVE=1; unset CCO_STATE_HOME XDG_STATE_HOME; _cco_state_dir )
    cache=$(  export HOME="$tmp/home" CCO_ALLOW_HOST_RESOLVE=1; unset CCO_CACHE_HOME XDG_CACHE_HOME; _cco_cache_dir )

    [[ "$config" == "$tmp/home/.cco" ]]                || fail "CONFIG default: $config"
    [[ "$data"   == "$tmp/home/.local/share/cco" ]]    || fail "DATA default: $data"
    [[ "$state"  == "$tmp/home/.local/state/cco" ]]    || fail "STATE default: $state"
    [[ "$cache"  == "$tmp/home/.cache/cco" ]]          || fail "CACHE default: $cache"
}

# Precedence: $CCO_*_HOME (the cco dir itself) ranks above $XDG_*_HOME/cco.
test_paths_xdg_cco_override_ranks_above_xdg() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local val
    val=$( export HOME="$tmp/home" CCO_ALLOW_HOST_RESOLVE=1 \
                  CCO_DATA_HOME="$tmp/cco-data" XDG_DATA_HOME="$tmp/xdg-data"; _cco_data_dir )
    [[ "$val" == "$tmp/cco-data" ]] || fail "Expected CCO override (no /cco suffix), got: $val"
}

# $XDG_*_HOME is used (with /cco appended) when no $CCO_*_HOME override.
test_paths_xdg_used_when_no_cco_override() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local val
    val=$( export HOME="$tmp/home" CCO_ALLOW_HOST_RESOLVE=1 XDG_CACHE_HOME="$tmp/xdg-cache"; \
           unset CCO_CACHE_HOME; _cco_cache_dir )
    [[ "$val" == "$tmp/xdg-cache/cco" ]] || fail "Expected XDG+/cco, got: $val"
}

# Unset/empty/non-absolute overrides are treated as absent → fall to default.
test_paths_xdg_empty_and_relative_treated_absent() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local val
    val=$( export HOME="$tmp/home" CCO_ALLOW_HOST_RESOLVE=1 \
                  CCO_DATA_HOME="" XDG_DATA_HOME="relative/path"; _cco_data_dir )
    [[ "$val" == "$tmp/home/.local/share/cco" ]] || fail "Expected default (empty+relative absent), got: $val"
}

# Created bucket dirs are mode 0700.
test_paths_xdg_resolver_creates_0700() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local val mode
    val=$( export HOME="$tmp/home" CCO_ALLOW_HOST_RESOLVE=1; unset CCO_STATE_HOME XDG_STATE_HOME; _cco_state_dir )
    [[ -d "$val" ]] || fail "Expected STATE dir created: $val"
    mode=$(_paths_stat_mode "$val")
    [[ "$mode" == "700" ]] || fail "Expected mode 700, got: $mode ($val)"
}

# H4 guard: in-container resolution aborts without the escape hatch.
test_paths_resolver_guard_blocks_in_container() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local out rc=0
    # Force the container condition deterministically via the explicit marker
    # (valid on host too, where /.dockerenv is absent).
    out=$( export CCO_IN_CONTAINER=1; unset CCO_ALLOW_HOST_RESOLVE; _cco_data_dir 2>&1 ) || rc=$?
    [[ $rc -ne 0 ]] || fail "Expected anti-in-container guard to abort, got rc=0 (out: $out)"
    [[ "$out" == *"anti-in-container"* ]] || fail "Expected guard message, got: $out"
}

# H4 escape hatch: CCO_ALLOW_HOST_RESOLVE=1 bypasses the guard (for tests/dev).
test_paths_resolver_guard_hatch_allows() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local val
    val=$( export CCO_IN_CONTAINER=1 CCO_ALLOW_HOST_RESOLVE=1 CCO_DATA_HOME="$tmp/d"; _cco_data_dir )
    [[ "$val" == "$tmp/d" ]] || fail "Expected hatch to bypass guard, got: $val"
}

# ── Container-operator mode (ADR-0036 D4) ────────────────────────────
# The deliberate in-container bypass: CCO_CONTAINER_OPERATOR=1 + all three
# CCO_*_HOME absolute → resolution against the mounted buckets is allowed.

test_paths_container_operator_requires_flag_and_buckets() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    # Flag alone (no bucket overrides) → not operator mode.
    ( export CCO_CONTAINER_OPERATOR=1; unset CCO_DATA_HOME CCO_STATE_HOME CCO_CACHE_HOME
      _cco_container_operator ) && fail "flag without buckets must not be operator mode"
    # Buckets without the flag → not operator mode.
    ( unset CCO_CONTAINER_OPERATOR
      export CCO_DATA_HOME=/d CCO_STATE_HOME=/s CCO_CACHE_HOME=/c
      _cco_container_operator ) && fail "buckets without flag must not be operator mode"
    # A relative (non-absolute) bucket → rejected.
    ( export CCO_CONTAINER_OPERATOR=1 CCO_DATA_HOME=rel CCO_STATE_HOME=/s CCO_CACHE_HOME=/c
      _cco_container_operator ) && fail "relative bucket must not be operator mode"
    # Flag + three absolute buckets → operator mode.
    ( export CCO_CONTAINER_OPERATOR=1 CCO_DATA_HOME=/d CCO_STATE_HOME=/s CCO_CACHE_HOME=/c
      _cco_container_operator ) || fail "flag + absolute buckets must be operator mode"
    return 0
}

# Operator mode bypasses the anti-in-container guard (distinct from the hatch):
# a resolve inside a container succeeds against the mounted DATA bucket.
test_paths_container_operator_bypasses_guard() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local val rc=0
    val=$( export CCO_IN_CONTAINER=1 CCO_CONTAINER_OPERATOR=1 \
                  CCO_DATA_HOME="$tmp/d" CCO_STATE_HOME="$tmp/s" CCO_CACHE_HOME="$tmp/c"
           unset CCO_ALLOW_HOST_RESOLVE; _cco_data_dir ) || rc=$?
    [[ $rc -eq 0 && "$val" == "$tmp/d" ]] \
        || fail "Expected operator mode to bypass guard, got rc=$rc val=$val"
}

# Without the operator flag, an in-container resolve still dies even if the
# CCO_*_HOME overrides happen to be set (ADR-0007 invariant intact).
test_paths_container_operator_flag_required_for_bypass() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local out rc=0
    out=$( export CCO_IN_CONTAINER=1 CCO_DATA_HOME="$tmp/d" \
                  CCO_STATE_HOME="$tmp/s" CCO_CACHE_HOME="$tmp/c"
           unset CCO_ALLOW_HOST_RESOLVE CCO_CONTAINER_OPERATOR; _cco_data_dir 2>&1 ) || rc=$?
    [[ $rc -ne 0 && "$out" == *"anti-in-container"* ]] \
        || fail "Expected guard to fire without operator flag, got rc=$rc out=$out"
}

# ── D8 (ADR-0036): canonical caller-context signal ──────────────────
# _cco_caller_context maps the _cco_in_container predicate onto the two
# framework-wide contexts `host` | `container-agent`. The guard (above) is
# re-expressed on it, so the signal must be correct for both branches.

# Container branch, via the explicit marker (valid on host too, and inside the
# self-dev container where /.dockerenv is already present).
test_paths_caller_context_container_marker() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local ctx; ctx=$( export CCO_IN_CONTAINER=1; _cco_caller_context )
    [[ "$ctx" == "container-agent" ]] \
        || fail "Expected 'container-agent' under CCO_IN_CONTAINER=1, got: $ctx"
}

# Host branch. /.dockerenv cannot be removed inside the self-dev container, so
# force the predicate hermetically by shadowing _cco_in_container in the subshell
# — this asserts the label mapping independent of the real environment.
test_paths_caller_context_host() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local ctx; ctx=$( _cco_in_container() { return 1; }; _cco_caller_context )
    [[ "$ctx" == "host" ]] \
        || fail "Expected 'host' when not in a container, got: $ctx"
}

# The guard is re-expressed on the signal: forcing the host context via the
# shadowed predicate must let a resolve through even without the hatch.
test_paths_caller_context_drives_guard() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local val rc=0
    val=$( _cco_in_container() { return 1; }
           unset CCO_ALLOW_HOST_RESOLVE CCO_IN_CONTAINER
           export CCO_DATA_HOME="$tmp/d"; _cco_data_dir ) || rc=$?
    [[ $rc -eq 0 && "$val" == "$tmp/d" ]] \
        || fail "Expected guard to pass in host context, got rc=$rc val=$val"
}

# ── L5: symlink-safe tool root ───────────────────────────────────────
# A PATH symlink to bin/cco must still locate the tool root (lib/).
test_paths_symlink_safe_tool_root() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    mkdir -p "$tmp/bin"
    ln -s "$REPO_ROOT/bin/cco" "$tmp/bin/cco"

    local out rc=0
    out=$( CCO_ALLOW_HOST_RESOLVE=1 bash "$tmp/bin/cco" help 2>&1 ) || rc=$?
    [[ $rc -eq 0 ]] || fail "Symlinked cco help failed (rc=$rc): $out"
    [[ "$out" == *"Usage:"* ]] || fail "Symlinked cco did not locate libs (no Usage): $out"
}

# ── Claude Code native install (ADR-0039) ───────────────────────────
# The binary lives in a re-fetchable CACHE dir, bind-mounted into the container;
# the channel/version preference is a CONFIG knob defaulting to `latest`.

test_paths_claude_install_dir_in_cache() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export CCO_CACHE_HOME="$tmpdir/cache" CCO_ALLOW_HOST_RESOLVE=1
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local result; result=$(_cco_claude_install_dir)
    [[ "$result" == "$tmpdir/cache/claude-install" ]] \
        || fail "Expected claude-install under CACHE, got: $result"
}

test_paths_claude_version_pref_defaults_latest() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export HOME="$tmpdir/home" CCO_ALLOW_HOST_RESOLVE=1
    mkdir -p "$HOME"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    local result; result=$(_cco_claude_version_pref)
    [[ "$result" == "latest" ]] \
        || fail "Expected default 'latest' with no knob, got: $result"
}

test_paths_claude_version_pref_reads_knob() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    export HOME="$tmpdir/home" CCO_ALLOW_HOST_RESOLVE=1
    mkdir -p "$HOME"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"

    # Comment + blank lines are ignored; first real value wins, whitespace trimmed.
    printf '# pinned channel\n\n  stable  \n' > "$(_cco_claude_version_file)"
    local result; result=$(_cco_claude_version_pref)
    [[ "$result" == "stable" ]] \
        || fail "Expected 'stable' from knob, got: $result"
}

# ── Container-operator LANE self-test (RC-17) ─────────────────────────
# The lane's own guard against being vacuous. Every other lane test is evidence
# only if these three properties hold, and each of them has already failed once
# in practice, so none of them is theoretical.

test_operator_lane_predicate_is_real() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" read-project

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/access-scope.sh"

    # 1. The REAL predicate engages — the lane declares an operator session, it
    #    does not stub `_cco_container_operator` (a stub cannot regress-test the
    #    predicate and cannot reach the dispatcher).
    _cco_container_operator || fail "lane must satisfy the real _cco_container_operator predicate" || return 1
    local ctx; ctx=$(_env_context)
    assert_equals operator "$ctx" "lane session must report the operator execution context" || return 1

    # 2. The lane CREATES its buckets, and that mkdir is load-bearing rather than
    #    decorative. Wipe them first so the fixture matches production, where the
    #    buckets are MOUNTS made host-side by `cco start` and the resolvers
    #    therefore skip _cco_ensure_dir under operator mode. Without
    #    setup_operator_session's own mkdir the index seed dies with
    #    `mktemp: … No such file or directory` and reads back EMPTY — which would
    #    silently make every lane test vacuous rather than failing it.
    rm -rf "$CCO_STATE_HOME" "$CCO_DATA_HOME" "$CCO_CACHE_HOME"
    setup_operator_session "$tmp" read-project
    assert_dir_exists "$CCO_STATE_HOME" || return 1
    seed_index_path lane-probe /Users/cco-e2e/code/lane-probe lane-proj
    assert_index_path lane-proj lane-probe /Users/cco-e2e/code/lane-probe || return 1

    # 3. The sanitiser fired. Run inside a live cco session, an inherited
    #    PROJECT_NAME steers every _env_is_current_project decision (and with it
    #    the read-project scoping of `project validate`), and an inherited
    #    CCO_ACCESS_TRIPLE overrides the level the test asked for. A helper that
    #    relies on bin/test's global unset is wrong from any other calling context.
    assert_empty "${PROJECT_NAME:-}" "setup_operator_session with no project must UNSET PROJECT_NAME" || return 1
    assert_empty "${CCO_ACCESS_TRIPLE:-}" "setup_operator_session must leave CCO_ACCESS_TRIPLE unset" || return 1
    return 0
}

# The ADR-0047 boundary seam (D-M8/Q-14). It models the boundary's ERRNO, not its
# mechanism: `chmod 000` on a bucket makes the store unreadable for a normal uid,
# which is the EACCES a non-elevated agent gets from the cco-svc-owned 0700 root.
# It does NOT model the setuid trampoline (pinned off by CCO_STORE_ELEVATED=1).
# `lane_seal_boundary` fails loudly under uid 0 rather than skipping, because root
# bypasses mode bits and a silent skip would be a brand-new false green.
test_operator_lane_boundary_seam_denies_store_read() {
    local tmp; tmp=$(mktemp -d)
    # Unseal before rm -rf: a 000 dir cannot be traversed to delete its contents.
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" read-project

    seed_index_path sealed /Users/cco-e2e/code/sealed sealed-proj
    local idx="$(cco_index_file)"
    assert_file_exists "$idx" "the lane must produce a real on-disk index to seal" || return 1

    lane_seal_boundary "$CCO_STATE_HOME" || return 1
    local out rc=0
    # LC_ALL=C: assert on the errno's C-locale words — under a non-C locale cat
    # localizes "Permission denied" and the substring match would break.
    out=$(LC_ALL=C cat "$idx" 2>&1) || rc=$?
    lane_unseal_boundary "$CCO_STATE_HOME"

    # A positive outcome assertion: the exact rc AND the errno's own words.
    assert_rc 1 "$rc" "reading the index under the sealed boundary" || return 1
    [[ "$out" == *"Permission denied"* ]] \
        || fail "sealed boundary must produce EACCES, got: $out" || return 1
    # And the seam is reversible — the fixture is not one-way.
    assert_index_path sealed-proj sealed /Users/cco-e2e/code/sealed || return 1
    return 0
}

# The gate probe's self-containment claim, made checkable.
#
# _lane_operator_exports reads OP_TRIPLE / OP_TARGETS / OP_SHP from its CALLER —
# deliberately, for the lane runners (the _op_seed precedent). assert_gate_allows
# documents itself as inheriting nothing, and a comment that disagrees with the
# behaviour is worse than no comment: the comment is what the next author trusts.
#
# The leak is observable through OP_TRIPLE, because CCO_ACCESS_TRIPLE overrides the
# preset the <level> argument selects. With the leak, `assert_gate_allows
# edit-project repo rename` is silently answered at (ro,ro,ro) and refuses
# "needs Pc=rw" — the probe reporting on a level nobody asked about. OP_TARGETS and
# OP_SHP ride the same path and are cleared with it.
test_operator_lane_gate_probe_ignores_caller_op_vars() {
    OP_TRIPLE='ro,ro,ro'
    OP_TARGETS='some-other-project'
    OP_SHP='false'
    assert_gate_allows edit-project repo rename || return 1
    return 0
}

# ── INV-F probe/display pair (RC-2 / 04-host-path-class.md §3.1, §6.1) ─
# The mechanism helpers are pure path arithmetic: they take what the caller has
# and reason about it, so operator mode is engaged with its REAL preconditions
# (flag + three absolute buckets + CCO_WORKDIR), never a stub of the predicate.
_paths_operator_env() {
    export CCO_CONTAINER_OPERATOR=1 CCO_IN_CONTAINER=1 \
           CCO_DATA_HOME=/d CCO_STATE_HOME=/s CCO_CACHE_HOME=/c \
           CCO_WORKDIR=/ws
}

test_probe_path_empty_binding_is_empty() {
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/paths.sh"
      _paths_operator_env
      # INV-F.1: an empty index path must never be synthesized to <ws>/<name>.
      [[ -z "$(_cco_member_probe_path my-repo "")" ]] \
          || fail "operator probe of an empty binding must be empty (INV-F.1)"
    ) || return 1
}

test_probe_path_honours_declared_target() {
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/paths.sh"
      _paths_operator_env
      # INV-F.2: an explicit declared target wins over the <ws>/<name> default.
      [[ "$(_cco_member_probe_path assets /host/a /ws/docs/assets)" == "/ws/docs/assets" ]] \
          || fail "operator probe must honour the declared target (INV-F.2)"
    ) || return 1
}

test_probe_path_host_ignores_target() {
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/paths.sh"
      unset CCO_CONTAINER_OPERATOR CCO_IN_CONTAINER
      # INV-A: on the host the index path is returned unchanged, target ignored.
      [[ "$(_cco_member_probe_path assets /host/a /ws/docs/assets)" == "/host/a" ]] \
          || fail "host probe must ignore the declared target (INV-A)"
    ) || return 1
}

test_probe_path_default_target_unchanged() {
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/paths.sh"
      _paths_operator_env
      # Regression guard for the three shipped 2-arg call sites.
      [[ "$(_cco_member_probe_path my-repo /host/a)" == "/ws/my-repo" ]] \
          || fail "operator 2-arg probe must be <ws>/<name>"
    ) || return 1
}

test_display_path_operator_hides_host_path() {
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/paths.sh"
      _paths_operator_env; export CCO_SHOW_HOST_PATHS=false
      [[ "$(_cco_display_path my-repo /Users/a/my-repo)" == "/ws/my-repo" ]] \
          || fail "operator display with show_host_paths off must render the mount"
    ) || return 1
}

test_display_path_empty_stays_empty() {
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/paths.sh"
      _paths_operator_env; export CCO_SHOW_HOST_PATHS=false
      # The property cmd-project-query.sh:111 relies on for its (unresolved) rendering.
      [[ -z "$(_cco_display_path my-repo "")" ]] \
          || fail "display of an empty binding must stay empty (INV-F.1)"
    ) || return 1
}

test_display_path_operator_shows_when_permitted() {
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/paths.sh"
      _paths_operator_env; export CCO_SHOW_HOST_PATHS=true
      [[ "$(_cco_display_path my-repo /Users/a/my-repo)" == "/Users/a/my-repo" ]] \
          || fail "operator display with show_host_paths on must render the host path"
    ) || return 1
}

test_display_path_host_is_identity() {
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/paths.sh"
      unset CCO_CONTAINER_OPERATOR CCO_IN_CONTAINER; export CCO_SHOW_HOST_PATHS=false
      # INV-A: the host is never scoped, even with show_host_paths off.
      [[ "$(_cco_display_path my-repo /Users/a/my-repo)" == "/Users/a/my-repo" ]] \
          || fail "host display must be identity (INV-A)"
    ) || return 1
}

test_member_name_from_mount_immediate_child() {
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/paths.sh"
      _paths_operator_env
      [[ "$(_cco_member_name_from_mount /ws/backend)" == "backend" ]] \
          || fail "the WORKDIR's immediate child resolves to its member name"
    ) || return 1
}

test_member_name_from_mount_rejects_nested() {
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/paths.sh"
      _paths_operator_env
      _cco_member_name_from_mount /ws/backend/sub \
          && fail "a nested path is not a mount root" || true
    ) || return 1
}

test_member_name_from_mount_host_refuses() {
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/paths.sh"
      unset CCO_CONTAINER_OPERATOR CCO_IN_CONTAINER; export CCO_WORKDIR=/ws
      _cco_member_name_from_mount /ws/backend \
          && fail "reverse mount lookup is operator-only" || true
    ) || return 1
}
