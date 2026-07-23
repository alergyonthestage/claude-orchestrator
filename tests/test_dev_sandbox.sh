#!/usr/bin/env bash
# tests/test_dev_sandbox.sh — developer sandbox (ADR-0052 §7, WS-6)
#
# The sandbox toggle isolates a dev binary's INTERNAL buckets (STATE/DATA/CACHE) so
# §1's fail-loud version gate never bites a developer running two cco versions on one
# machine — shared XDG state is the root cause, not the reaction. Contract:
#   - engaged via CCO_DEV_SANDBOX=1 (or the `--dev-sandbox` flag bin/cco normalises
#     onto it) → the three internal buckets redirect to <root>/{state,data,cache};
#   - CONFIG (~/.cco) stays SHARED — the gate's inputs all live in STATE/DATA/CACHE;
#   - never clobbers an explicit CCO_*_HOME override; root overridable;
#   - host-only (a real session's operator buckets are the sacred mounts);
#   - OFF by default is a strict no-op (the regression guard for every other test);
#   - opt-in one-shot seed (CCO_DEV_SANDBOX_SEED=1) copies real STATE+DATA (not CACHE).
#
# Host mode is forced with CCO_IN_CONTAINER=0 (this suite runs inside cco's own
# self-dev container, where /.dockerenv exists) — mirrors test_version_gate.

# Minimal host env with the internal-bucket overrides DELIBERATELY UNSET, so the
# sandbox's redirect (and its no-op-when-off) is observable against the real
# $HOME-anchored defaults. Sources only what _cco_apply_dev_sandbox needs.
_ds_env() {
    export HOME="$1/home"; mkdir -p "$HOME"
    unset CCO_DATA_HOME CCO_STATE_HOME CCO_CACHE_HOME \
          XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME \
          CCO_CONTAINER_OPERATOR CCO_DEV_SANDBOX CCO_DEV_SANDBOX_SEED CCO_DEV_SANDBOX_ROOT \
          CCO_ALLOW_HOST_RESOLVE 2>/dev/null || true
    export CCO_IN_CONTAINER=0
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
}

# ── OFF by default = no behaviour change ─────────────────────────────

test_dev_sandbox_off_is_a_strict_noop() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local out
    out=$(
        _ds_env "$tmp"
        _cco_apply_dev_sandbox 2>/dev/null       # toggle unset
        echo "ACTIVE=$(_cco_dev_sandbox_active && echo yes || echo no)"
        echo "STATE=$(_cco_state_dir)"
        echo "HOME_SET=${CCO_STATE_HOME:-<unset>}"
    )
    [[ "$out" == *"ACTIVE=no"* ]] \
        || fail "off by default: _cco_dev_sandbox_active must be false, got: $out"
    [[ "$out" == *"HOME_SET=<unset>"* ]] \
        || fail "off by default: CCO_STATE_HOME must stay unset (no redirect), got: $out"
    [[ "$out" != *".cco-devsandbox"* ]] \
        || fail "off by default: no bucket may resolve under the sandbox root, got: $out"
}

# ── Engaged: the three internal buckets redirect ─────────────────────

test_dev_sandbox_active_redirects_internal_buckets() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local out
    out=$(
        _ds_env "$tmp"
        export CCO_DEV_SANDBOX=1
        _cco_apply_dev_sandbox 2>/dev/null
        echo "STATE=$(_cco_state_dir)"
        echo "DATA=$(_cco_data_dir)"
        echo "CACHE=$(_cco_cache_dir)"
    )
    [[ "$out" == *"STATE=$tmp/home/.cco-devsandbox/state"* ]] \
        || fail "STATE must redirect to the sandbox, got: $out"
    [[ "$out" == *"DATA=$tmp/home/.cco-devsandbox/data"* ]] \
        || fail "DATA must redirect to the sandbox, got: $out"
    [[ "$out" == *"CACHE=$tmp/home/.cco-devsandbox/cache"* ]] \
        || fail "CACHE must redirect to the sandbox, got: $out"
}

# CONFIG (~/.cco) is deliberately NOT sandboxed — the §7 call this cycle.
test_dev_sandbox_config_stays_shared() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local out
    out=$(
        _ds_env "$tmp"
        export CCO_DEV_SANDBOX=1
        _cco_apply_dev_sandbox 2>/dev/null
        echo "CONFIG=$(_cco_config_dir)"
    )
    [[ "$out" == *"CONFIG=$tmp/home/.cco"* && "$out" != *".cco-devsandbox"* ]] \
        || fail "CONFIG must stay ~/.cco (shared, not sandboxed), got: $out"
}

# ── Never clobber an explicit override ───────────────────────────────

test_dev_sandbox_does_not_clobber_explicit_override() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local out
    out=$(
        _ds_env "$tmp"
        export CCO_DEV_SANDBOX=1
        export CCO_STATE_HOME="$tmp/mystate"     # a caller/test/power-user override
        _cco_apply_dev_sandbox 2>/dev/null
        echo "STATE=$(_cco_state_dir)"
        echo "DATA=$(_cco_data_dir)"
    )
    [[ "$out" == *"STATE=$tmp/mystate"* ]] \
        || fail "an explicit CCO_STATE_HOME must survive the sandbox, got: $out"
    # The un-overridden buckets still redirect.
    [[ "$out" == *"DATA=$tmp/home/.cco-devsandbox/data"* ]] \
        || fail "un-overridden DATA must still redirect, got: $out"
}

# ── Root override ────────────────────────────────────────────────────

test_dev_sandbox_root_override() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local out
    out=$(
        _ds_env "$tmp"
        export CCO_DEV_SANDBOX=1
        export CCO_DEV_SANDBOX_ROOT="$tmp/altroot"
        _cco_apply_dev_sandbox 2>/dev/null
        echo "STATE=$(_cco_state_dir)"
    )
    [[ "$out" == *"STATE=$tmp/altroot/state"* ]] \
        || fail "CCO_DEV_SANDBOX_ROOT must relocate the sandbox buckets, got: $out"
}

# ── Host-only ────────────────────────────────────────────────────────

test_dev_sandbox_is_host_only_noop_in_container() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local out
    out=$(
        _ds_env "$tmp"
        export CCO_DEV_SANDBOX=1
        export CCO_IN_CONTAINER=1                 # in-container → sandbox must no-op
        _cco_apply_dev_sandbox 2>/dev/null
        echo "HOME_SET=${CCO_STATE_HOME:-<unset>}"
    )
    [[ "$out" == *"HOME_SET=<unset>"* ]] \
        || fail "in-container: the sandbox must not redirect any bucket, got: $out"
}

# ── Opt-in one-shot seed ─────────────────────────────────────────────

test_dev_sandbox_seed_copies_state_and_data_not_cache() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    # Pre-populate the REAL buckets with marker files.
    mkdir -p "$tmp/home/.local/state/cco" "$tmp/home/.local/share/cco" "$tmp/home/.cache/cco"
    echo "idx" > "$tmp/home/.local/state/cco/index"
    echo "reg" > "$tmp/home/.local/share/cco/remotes"
    echo "big" > "$tmp/home/.cache/cco/should-not-copy"
    local root="$tmp/home/.cco-devsandbox"
    (
        _ds_env "$tmp"
        export CCO_DEV_SANDBOX=1 CCO_DEV_SANDBOX_SEED=1
        _cco_apply_dev_sandbox 2>/dev/null
    )
    assert_file_exists "$root/state/index"  "seed must copy real STATE into the sandbox" || return 1
    assert_file_exists "$root/data/remotes" "seed must copy real DATA into the sandbox"  || return 1
    assert_dir_not_exists "$root/cache" "seed must NOT copy CACHE (re-fetchable/large)" || return 1
}

# Seed is one-shot: an existing sandbox STATE is never overwritten.
test_dev_sandbox_seed_is_one_shot() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    mkdir -p "$tmp/home/.local/state/cco"
    echo "real" > "$tmp/home/.local/state/cco/index"
    local root="$tmp/home/.cco-devsandbox"
    mkdir -p "$root/state"; echo "preexisting" > "$root/state/index"   # sandbox already in use
    (
        _ds_env "$tmp"
        export CCO_DEV_SANDBOX=1 CCO_DEV_SANDBOX_SEED=1
        _cco_apply_dev_sandbox 2>/dev/null
    )
    [[ "$(cat "$root/state/index")" == "preexisting" ]] \
        || fail "seed must be one-shot — an in-use sandbox STATE must not be overwritten"
}

# ── The `--dev-sandbox` flag + whoami indicator (full binary) ────────

test_dev_sandbox_flag_and_whoami_indicator() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local sbhome="$tmp/home"; mkdir -p "$sbhome"
    local out
    # Clean host env: strip the ambient operator envelope this self-dev container
    # carries, force host mode, and let the flag drive the toggle.
    out=$(env -u CCO_CONTAINER_OPERATOR -u CCO_DATA_HOME -u CCO_STATE_HOME -u CCO_CACHE_HOME \
              -u CCO_CCO_ACCESS -u CCO_CLAUDE_ACCESS -u CCO_SHOW_HOST_PATHS -u CCO_CONFIG_TARGETS \
              -u PROJECT_NAME -u CCO_SESSION_CONTEXT -u XDG_STATE_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME \
              CCO_IN_CONTAINER=0 HOME="$sbhome" CCO_SKIP_BUILD=1 \
              bash "$REPO_ROOT/bin/cco" whoami --dev-sandbox 2>&1)
    [[ "$out" == *"Developer sandbox"* ]] \
        || fail "cco whoami --dev-sandbox must report the sandbox, got: $out"
    [[ "$out" == *".cco-devsandbox/state"* ]] \
        || fail "whoami must show the redirected STATE bucket, got: $out"
    [[ -d "$sbhome/.cco-devsandbox/state" ]] \
        || fail "the --dev-sandbox flag must redirect + create the sandbox STATE bucket"
    # And OFF: no mention, no sandbox dir.
    rm -rf "$sbhome"; mkdir -p "$sbhome"
    out=$(env -u CCO_CONTAINER_OPERATOR -u CCO_DATA_HOME -u CCO_STATE_HOME -u CCO_CACHE_HOME \
              -u CCO_CCO_ACCESS -u CCO_CLAUDE_ACCESS -u CCO_SHOW_HOST_PATHS -u CCO_CONFIG_TARGETS \
              -u PROJECT_NAME -u CCO_SESSION_CONTEXT -u XDG_STATE_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME \
              CCO_IN_CONTAINER=0 HOME="$sbhome" CCO_SKIP_BUILD=1 \
              bash "$REPO_ROOT/bin/cco" whoami 2>&1)
    [[ "$out" != *"Developer sandbox"* ]] \
        || fail "cco whoami (no toggle) must NOT mention the sandbox, got: $out"
    [[ ! -d "$sbhome/.cco-devsandbox" ]] \
        || fail "cco whoami (no toggle) must not create a sandbox root"
}
