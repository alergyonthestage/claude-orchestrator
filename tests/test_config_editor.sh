#!/usr/bin/env bash
# tests/test_config_editor.sh — config-editor built-in (ADR-0027 D1).
#
# config-editor is a reserved-name built-in (the tutorial model): `cco start
# config-editor` materializes internal/config-editor/ at runtime and mounts the
# personal store ~/.cco rw (global mode); --project <name> also mounts that
# project's <repo>/.cco rw (project mode). Host paths are launcher-injected into
# a generated runtime project.yml, never committed (AD3/G8).

# ── Global mode ───────────────────────────────────────────────────────

test_config_editor_mounts_cco_config_rw() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco start config-editor --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    # ~/.cco mounted read-write at /workspace/cco-config.
    assert_file_contains "$compose" "$HOME/.cco:/workspace/cco-config" || return 1
    assert_file_not_contains "$compose" "$HOME/.cco:/workspace/cco-config:ro" || return 1
}

test_config_editor_mounts_docs_readonly() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco start config-editor --dry-run --dump
    assert_file_contains "$DRY_RUN_DIR/.cco/docker-compose.yml" ":/workspace/cco-docs:ro"
}

test_config_editor_project_name_in_compose() {
    # The generated runtime project.yml names the session config-editor.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco start config-editor --dry-run --dump
    assert_file_contains "$DRY_RUN_DIR/.cco/docker-compose.yml" "container_name: cc-config-editor"
}

test_config_editor_no_project_overlay_in_global_mode() {
    # Global mode mounts no <name>-config target.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco start config-editor --dry-run --dump
    assert_file_not_contains "$DRY_RUN_DIR/.cco/docker-compose.yml" "-config:/workspace/"
}

# ── Project mode ──────────────────────────────────────────────────────

test_config_editor_project_mode_mounts_target_cco() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "myproj" "$(minimal_project_yml myproj)"
    run_cco start config-editor --project myproj --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    # The target project's committed .cco mounted rw at /workspace/myproj-config.
    assert_file_contains "$compose" "$tmpdir/repos/myproj/.cco:/workspace/myproj-config" || return 1
    assert_file_not_contains "$compose" "$tmpdir/repos/myproj/.cco:/workspace/myproj-config:ro" || return 1
    # ~/.cco is still mounted (global store always available in config-editor).
    assert_file_contains "$compose" "$HOME/.cco:/workspace/cco-config" || return 1
}

test_config_editor_project_mode_unknown_target_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco start config-editor --project ghost --dry-run --dump || true
    assert_output_contains "not resolvable"
}

# ── Reserved name ─────────────────────────────────────────────────────

test_config_editor_name_reserved_for_init() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local repo="$tmpdir/somerepo"; mkdir -p "$repo"
    local prev; prev="$(pwd)"
    cd "$repo" || return 1
    run_cco init --name config-editor || true
    cd "$prev" || return 1
    assert_output_contains "reserved"
}
