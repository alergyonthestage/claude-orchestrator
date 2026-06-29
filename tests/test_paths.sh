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
