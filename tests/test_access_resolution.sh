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
    [[ "$cco_access" == "read-project" ]] || fail "default cco=read-project (ADR-0042), got: $cco_access"
    [[ "$show_host_paths" == "true" ]] || fail "default show_host_paths=true, got: $show_host_paths"
}

test_access_resolve_project_block() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src

    local project_yml="$tmp/project.yml"
    printf 'name: p\naccess:\n  claude: all\n  cco: read-global\n  show_host_paths: false\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths
    _start_resolve_access
    [[ "$claude_access" == "all" ]]      || fail "project claude=all, got: $claude_access"
    [[ "$cco_access" == "read-global" ]] || fail "project cco=read-global, got: $cco_access"
    [[ "$show_host_paths" == "false" ]]  || fail "project show_host_paths=false, got: $show_host_paths"
}

# ADR-0042 symmetric read scoping: the three read levels validate; bare `read`
# is accepted as a back-compat alias normalized to read-all.
test_access_read_scopes_and_legacy_alias() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"; printf 'name: p\n' > "$project_yml"
    local cli_claude_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths lvl
    for lvl in read-project read-global read-all; do
        local cli_cco_access="$lvl"
        _start_resolve_access
        [[ "$cco_access" == "$lvl" ]] || fail "read scope $lvl should validate, got: $cco_access"
    done
    # Legacy `read` → read-all.
    local cli_cco_access="read"
    _start_resolve_access
    [[ "$cco_access" == "read-all" ]] || fail "legacy 'read' should normalize to read-all, got: $cco_access"
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
    # Legacy `read` normalizes to read-all (ADR-0042) before it reaches the debug line.
    assert_output_contains "claude=all cco=read-all show_host_paths=false"
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

# ── Mount modes driven by the knobs (step 3) ─────────────────────────
# Assert the generated docker-compose reflects the resolved Axis-B/Axis-A modes.

_access_compose() { cat "$DRY_RUN_DIR/.cco/docker-compose.yml"; }

test_access_mount_defaults() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --dry-run --dump
    local c; c=$(_access_compose)
    # B2 project .claude rw (no :ro right after the target)
    echo "$c" | grep -qE '/workspace/\.claude"' || fail "B2 should be rw by default"
    # B3 global authoring ro
    echo "$c" | grep -qE '/home/claude/\.claude/CLAUDE\.md:ro"' || fail "B3 authoring ro by default"
    # A1 <repo>/.cco overlaid :ro (cco_access=none default)
    echo "$c" | grep -qE 'dummy-repo/\.cco:/workspace/dummy-repo/\.cco:ro"' || fail "A1 :ro overlay expected by default"
}

test_access_mount_claude_none_locks_b2_and_b1() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.claude"   # B1 native repo claude tree
    run_cco start "test-proj" --claude-access none --dry-run --dump
    local c; c=$(_access_compose)
    echo "$c" | grep -qE '/workspace/\.claude:ro"' || fail "B2 should be :ro under claude-access none"
    echo "$c" | grep -qE 'dummy-repo/\.claude:/workspace/dummy-repo/\.claude:ro"' || fail "B1 native .claude should be :ro overlaid under none"
}

test_access_mount_claude_all_unlocks_b3() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --claude-access all --dry-run --dump
    local c; c=$(_access_compose)
    # global authoring now rw (quote right after CLAUDE.md, no :ro)
    echo "$c" | grep -qE '/home/claude/\.claude/CLAUDE\.md"' || fail "B3 authoring should be rw under claude-access all"
    if echo "$c" | grep -qE '/home/claude/\.claude/CLAUDE\.md:ro"'; then fail "B3 CLAUDE.md must not be :ro under all"; fi
}

test_access_mount_cco_edit_project_unlocks_a1() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --cco-access edit-project --dry-run --dump
    local c; c=$(_access_compose)
    if echo "$c" | grep -qE 'dummy-repo/\.cco:/workspace/dummy-repo/\.cco:ro"'; then
        fail "A1 :ro overlay should be absent under cco-access edit-project"
    fi
}

# ── Container-operator buckets + secret masking (step 4, ADR-0036 D4) ─

# cco_access=none (explicit — no longer the default under ADR-0042) → no operator
# mode, no buckets.
test_operator_none_no_buckets() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --cco-access none --dry-run --dump
    local c; c=$(_access_compose)
    if echo "$c" | grep -q 'CCO_CONTAINER_OPERATOR'; then fail "no operator env expected under cco-access none"; fi
    if echo "$c" | grep -qE ':/home/claude/\.cco"'; then fail "no ~/.cco bucket mount expected under cco-access none"; fi
}

# Normal default is now read-project (ADR-0042) → operator env present, buckets ro.
test_operator_default_read_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --dry-run --dump
    local c; c=$(_access_compose)
    echo "$c" | grep -q 'CCO_CONTAINER_OPERATOR=1'      || fail "operator env expected by default (read-project)"
    echo "$c" | grep -q 'CCO_CCO_ACCESS=read-project'   || fail "CCO_CCO_ACCESS=read-project expected by default"
    echo "$c" | grep -qE ':/home/claude/\.cco:ro"'      || fail "~/.cco should be ro under read-project"
}

# --cco-access read (legacy alias → read-all) → operator env + buckets, all ro;
# STATE is index-only. Exercises the alias flowing through resolution to compose.
test_operator_read_mounts_buckets_ro() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --cco-access read --dry-run --dump
    local c; c=$(_access_compose)
    echo "$c" | grep -q 'CCO_CONTAINER_OPERATOR=1'    || fail "operator env expected under read"
    echo "$c" | grep -q 'CCO_CCO_ACCESS=read-all'     || fail "legacy read should resolve to CCO_CCO_ACCESS=read-all"
    echo "$c" | grep -qE ':/home/claude/\.cco:ro"'    || fail "~/.cco should be ro under read"
    echo "$c" | grep -qE '/home/claude/\.local/state/cco/index:ro"' || fail "STATE index ro expected"
    # STATE is index-only: never the whole state dir, and never remotes-token.
    if echo "$c" | grep -qE ':/home/claude/\.local/state/cco"'; then fail "whole STATE dir must not be mounted"; fi
    if echo "$c" | grep -q 'remotes-token'; then fail "remotes-token must never be mounted"; fi
}

# --cco-access edit-global → A2 (~/.cco) + DATA rw.
test_operator_edit_global_rw_buckets() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --cco-access edit-global --dry-run --dump
    local c; c=$(_access_compose)
    echo "$c" | grep -qE ':/home/claude/\.cco"'                || fail "~/.cco should be rw under edit-global"
    echo "$c" | grep -qE ':/home/claude/\.local/share/cco"'    || fail "DATA should be rw under edit-global"
    # STATE stays index-only ro even under an edit level.
    echo "$c" | grep -qE '/home/claude/\.local/state/cco/index:ro"' || fail "STATE index stays ro"
}

# Real secret files masked out of the repo .cco (rw edit mount); *.example survives.
test_operator_secret_masking_repo() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    printf 'S=1\n' > "$CCO_DUMMY_REPO/.cco/secrets.env"
    printf 'S=\n'  > "$CCO_DUMMY_REPO/.cco/secrets.env.example"
    printf 'k\n'   > "$CCO_DUMMY_REPO/.cco/tls.key"
    run_cco start "test-proj" --cco-access edit-all --dry-run --dump
    local c; c=$(_access_compose)
    echo "$c" | grep -qE 'secret-mask:/workspace/dummy-repo/\.cco/secrets\.env:ro"' || fail "secrets.env should be masked"
    echo "$c" | grep -qE 'secret-mask:/workspace/dummy-repo/\.cco/tls\.key:ro"'     || fail "tls.key should be masked"
    if echo "$c" | grep -qE 'secret-mask:.*secrets\.env\.example'; then fail "*.example must NOT be masked"; fi
}

# Secret masking applies even to a normal session's :ro .cco overlay.
test_operator_secret_masking_normal_session() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    printf 'S=1\n' > "$CCO_DUMMY_REPO/.cco/secrets.env"
    run_cco start "test-proj" --dry-run --dump   # cco_access=read-project (normal default)
    local c; c=$(_access_compose)
    echo "$c" | grep -qE 'secret-mask:/workspace/dummy-repo/\.cco/secrets\.env:ro"' \
        || fail "secrets.env masked even in a normal session (capability matrix: filtered in every column)"
}

# Global secret (~/.cco/secrets.env) masked on the A2 mount.
test_operator_secret_masking_global_store() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    printf 'G=1\n' > "$HOME/.cco/secrets.env"
    run_cco start "test-proj" --cco-access edit-global --dry-run --dump
    local c; c=$(_access_compose)
    echo "$c" | grep -qE 'secret-mask:/home/claude/\.cco/secrets\.env:ro"' \
        || fail "~/.cco/secrets.env should be masked on the A2 mount"
}

# B3 axis stays separate: edit-global with claude_access!=all re-overlays
# ~/.cco/.claude :ro under the A2 path (global authoring is not unlocked by A2).
test_operator_b3_guard_ro_under_edit_global() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --cco-access edit-global --dry-run --dump
    local c; c=$(_access_compose)
    echo "$c" | grep -qE ':/home/claude/\.cco/\.claude:ro"' \
        || fail "~/.cco/.claude should be re-overlaid :ro under edit-global (B3 governed by claude_access)"
    # Under claude_access=all the guard overlay is absent (B3 is rw).
    run_cco start "test-proj" --cco-access edit-global --claude-access all --dry-run --dump
    c=$(_access_compose)
    if echo "$c" | grep -qE ':/home/claude/\.cco/\.claude:ro"'; then
        fail "B3 guard overlay should be absent under claude-access all"
    fi
}
