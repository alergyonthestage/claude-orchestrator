#!/usr/bin/env bash
# tests/test_access_resolution.sh — session capability-model knob resolution
# (ADR-0036 D2/D3, implementation step 2).
#
# Covers the three orthogonal knobs (claude_access / cco_access / show_host_paths),
# their precedence CLI > project.yml `access:` > global ~/.cco/access.yml > built-in
# preset default (repo / none / on), enum validation, and the deprecated
# --enable-config-edit → --cco-access edit-project alias. Resolution is host-side
# and side-effect-free; no Docker daemon required.

# Source the minimal chain cmd-start.sh's access helpers depend on.
_access_src() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/cmd-start.sh"
}

# ── Pure helpers ─────────────────────────────────────────────────────

test_access_is_member() {
    _access_src
    _access_is_member "none repo all" "repo" || fail "'repo' should be a member"
    _access_is_member "$_ACCESS_CCO_VALUES" "edit-global" || fail "'edit-global' should be a member"
    if _access_is_member "none repo all" "bogus"; then fail "'bogus' should not be a member"; fi
    return 0
}

test_access_norm_bool() {
    _access_src
    [[ "$(_access_norm_bool on)"    == "true"  ]] || fail "on→true"
    [[ "$(_access_norm_bool OFF)"   == "false" ]] || fail "OFF→false"
    [[ "$(_access_norm_bool true)"  == "true"  ]] || fail "true→true"
    [[ "$(_access_norm_bool 0)"     == "false" ]] || fail "0→false"
    [[ -z "$(_access_norm_bool '')" ]] || fail "empty token stays empty"
    if ( _access_norm_bool nonsense ) >/dev/null 2>&1; then fail "invalid bool should return non-zero"; fi
    return 0
}

test_access_pick_precedence() {
    _access_src
    [[ "$(_access_pick cli proj glob def)" == "cli"  ]] || fail "cli should win"
    [[ "$(_access_pick '' proj glob def)"  == "proj" ]] || fail "project next"
    [[ "$(_access_pick '' '' glob def)"    == "glob" ]] || fail "global next"
    [[ "$(_access_pick '' '' '' def)"      == "def"  ]] || fail "default last"
    return 0
}

# ── _start_resolve_access precedence (direct call) ───────────────────
# Declares the cmd_start locals the function reads/writes, then invokes it.

_access_setup_home() {
    local tmp="$1"
    export HOME="$tmp/home" CCO_ALLOW_HOST_RESOLVE=1
    unset CCO_CONFIG_HOME XDG_CONFIG_HOME
    mkdir -p "$HOME/.cco"
}

test_access_resolve_defaults() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src

    local project_yml="$tmp/project.yml"; printf 'name: p\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths
    _start_resolve_access
    [[ "$claude_access" == "repo" ]]  || fail "default claude=repo, got: $claude_access"
    [[ "$cco_access" == "none" ]]     || fail "default cco=none, got: $cco_access"
    [[ "$show_host_paths" == "true" ]] || fail "default show_host_paths=true, got: $show_host_paths"
}

test_access_resolve_project_block() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src

    local project_yml="$tmp/project.yml"
    printf 'name: p\naccess:\n  claude: all\n  cco: read\n  show_host_paths: false\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths
    _start_resolve_access
    [[ "$claude_access" == "all" ]]     || fail "project claude=all, got: $claude_access"
    [[ "$cco_access" == "read" ]]       || fail "project cco=read, got: $cco_access"
    [[ "$show_host_paths" == "false" ]] || fail "project show_host_paths=false, got: $show_host_paths"
}

test_access_resolve_global_default() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src

    printf 'claude: none\ncco: edit-global\nshow_host_paths: false\n' > "$HOME/.cco/access.yml"
    local project_yml="$tmp/project.yml"; printf 'name: p\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths
    _start_resolve_access
    [[ "$claude_access" == "none" ]]        || fail "global claude=none, got: $claude_access"
    [[ "$cco_access" == "edit-global" ]]    || fail "global cco=edit-global, got: $cco_access"
    [[ "$show_host_paths" == "false" ]]     || fail "global show_host_paths=false, got: $show_host_paths"
}

test_access_resolve_project_over_global() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src

    printf 'claude: none\ncco: none\n' > "$HOME/.cco/access.yml"
    local project_yml="$tmp/project.yml"
    printf 'name: p\naccess:\n  claude: all\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths
    _start_resolve_access
    [[ "$claude_access" == "all" ]] || fail "project should override global claude, got: $claude_access"
    # cco not set at project level → falls through to global 'none'
    [[ "$cco_access" == "none" ]]   || fail "cco should fall through to global none, got: $cco_access"
}

test_access_resolve_cli_over_project() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src

    local project_yml="$tmp/project.yml"
    printf 'name: p\naccess:\n  claude: all\n  cco: edit-all\n' > "$project_yml"
    local cli_claude_access="repo" cli_cco_access="" cli_show_host_paths="false"
    local claude_access cco_access show_host_paths
    _start_resolve_access
    [[ "$claude_access" == "repo" ]]    || fail "CLI should override project claude, got: $claude_access"
    [[ "$cco_access" == "edit-all" ]]   || fail "cco (no CLI) keeps project value, got: $cco_access"
    [[ "$show_host_paths" == "false" ]] || fail "CLI --no-show-host-paths wins, got: $show_host_paths"
}

test_access_resolve_invalid_project_value_dies() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src

    local project_yml="$tmp/project.yml"
    printf 'name: p\naccess:\n  cco: bogus\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths
    local out rc=0
    out=$( _start_resolve_access 2>&1 ) || rc=$?
    [[ $rc -ne 0 ]] || fail "invalid cco_access should abort, got rc=0"
    [[ "$out" == *"Invalid cco_access"* ]] || fail "expected validation message, got: $out"
}

# ── Full-flow integration (dry-run) ──────────────────────────────────

test_access_alias_enable_config_edit_maps_to_edit_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    export CCO_DEBUG=1
    run_cco start "test-proj" --enable-config-edit --dry-run
    unset CCO_DEBUG
    assert_output_contains "cco=edit-project"
}

test_access_cli_flag_reaches_resolution() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    export CCO_DEBUG=1
    run_cco start "test-proj" --claude-access all --cco-access read --no-show-host-paths --dry-run
    unset CCO_DEBUG
    assert_output_contains "claude=all cco=read show_host_paths=false"
}

test_access_invalid_cli_value_dies() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    local rc=0
    run_cco start "test-proj" --cco-access bogus --dry-run || rc=$?
    [[ $rc -ne 0 ]] || fail "invalid --cco-access should abort, got rc=0"
    assert_output_contains "Invalid cco_access"
}
