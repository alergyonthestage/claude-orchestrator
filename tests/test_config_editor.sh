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

# H4 (26-06-2026 migration review): the config-editor's internal mount names go
# through the in-process session override, not the persistent user-facing index.
test_config_editor_does_not_pollute_index() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco start config-editor --dry-run --dump
    local index="$CCO_STATE_HOME/index"
    if [[ -f "$index" ]]; then
        grep -qE '^[[:space:]]*cco-config:' "$index" \
            && fail "config-editor must not write 'cco-config' into the persistent index (H4)" || true
        grep -qE '^[[:space:]]*cco-docs:' "$index" \
            && fail "config-editor must not write 'cco-docs' into the persistent index (H4)" || true
    fi
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

# ── Preset + wrapped-cco (ADR-0036 step 5) ────────────────────────────

# config-editor resolves to the edit-all/all preset and gets the operator env
# + the ~/.cco operator bucket mount (wrapped-cco).
test_config_editor_preset_emits_operator() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco start config-editor --dry-run
    assert_output_contains "claude=all cco=edit-all"
    run_cco start config-editor --dry-run --dump
    assert_file_contains "$DRY_RUN_DIR/.cco/docker-compose.yml" "CCO_CONTAINER_OPERATOR=1" || return 1
    assert_file_contains "$DRY_RUN_DIR/.cco/docker-compose.yml" "CCO_CCO_ACCESS=edit-all" || return 1
    # ~/.cco also mounted at the operator path for in-container cco resolution.
    assert_file_contains "$DRY_RUN_DIR/.cco/docker-compose.yml" "$HOME/.cco:/home/claude/.cco" || return 1
}

# A global ~/.cco/access.yml must NOT neuter the config-editor preset.
test_config_editor_global_access_does_not_override_preset() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    printf 'cco: none\nclaude: none\n' > "$HOME/.cco/access.yml"
    run_cco start config-editor --dry-run
    assert_output_contains "claude=all cco=edit-all"
}

# An explicit CLI flag CAN narrow the preset.
test_config_editor_cli_narrows_preset() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco start config-editor --cco-access edit-project --dry-run
    assert_output_contains "cco=edit-project"
}

# Real secrets masked on the personal store + target config mounts.
test_config_editor_masks_secrets_on_config_mounts() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    printf 'G=1\n' > "$HOME/.cco/secrets.env"
    create_project "$tmpdir" "myproj" "$(minimal_project_yml myproj)"
    printf 'S=1\n' > "$tmpdir/repos/myproj/.cco/secrets.env"
    run_cco start config-editor --project myproj --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_contains "$compose" "secret-mask:/workspace/cco-config/secrets.env:ro" || return 1
    assert_file_contains "$compose" "secret-mask:/workspace/myproj-config/secrets.env:ro" || return 1
}

# ── --all / repeatable --project scope (ADR-0036 D-α) ─────────────────

test_config_editor_all_mounts_every_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "proj-a" "$(minimal_project_yml proj-a)"
    create_project "$tmpdir" "proj-b" "$(minimal_project_yml proj-b)"
    run_cco start config-editor --all --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_contains "$compose" ":/workspace/proj-a-config" || return 1
    assert_file_contains "$compose" ":/workspace/proj-b-config" || return 1
}

test_config_editor_repeatable_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "proj-a" "$(minimal_project_yml proj-a)"
    create_project "$tmpdir" "proj-b" "$(minimal_project_yml proj-b)"
    create_project "$tmpdir" "proj-c" "$(minimal_project_yml proj-c)"
    run_cco start config-editor --project proj-a --project proj-c --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_contains "$compose" ":/workspace/proj-a-config" || return 1
    assert_file_contains "$compose" ":/workspace/proj-c-config" || return 1
    assert_file_not_contains "$compose" ":/workspace/proj-b-config" || return 1
}

# Only <repo>/.cco is mounted, never a full code repo.
test_config_editor_all_mounts_only_cco() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "proj-a" "$(minimal_project_yml proj-a)"
    run_cco start config-editor --all --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    # target mounts always end in /.cco (source) → /workspace/<name>-config.
    assert_file_contains "$compose" "/.cco:/workspace/proj-a-config" || return 1
}
