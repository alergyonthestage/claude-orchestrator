#!/usr/bin/env bash
# tests/test_yaml_parser.sh — YAML parser unit tests
#
# Design: the awk-based YAML parsers in bin/cco are tested indirectly by
# creating project.yml files with specific values and asserting that the
# generated docker-compose.yml (via --dry-run) correctly reflects the parsing.
#
# This catches regressions in: yml_get, yml_get_repos, yml_get_ports,
# yml_get_env, yml_get_extra_mounts, yml_get_packs, yml_get_pack_files.

# ── yml_get: top-level and nested key parsing ─────────────────────────

test_yaml_parser_top_level_name_used_in_container() {
    # yml_get reads top-level "name" → used as project_name in compose
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "PROJECT_NAME=test-proj"
}

test_yaml_parser_nested_auth_method_oauth() {
    # yml_get reads nested "auth.method: oauth" → no ANTHROPIC_API_KEY in compose
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: oauth
docker:
  ports: []
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_not_contains "$compose" "ANTHROPIC_API_KEY"
}

test_yaml_parser_nested_auth_method_api_key() {
    # yml_get reads nested "auth.method: api_key" → ANTHROPIC_API_KEY present
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: api_key
docker:
  ports: []
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "ANTHROPIC_API_KEY"
}

test_yaml_parser_missing_auth_defaults_to_oauth() {
    # yml_get returns empty for missing "auth.method" → code defaults to oauth
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
docker:
  ports: []
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    # Default oauth → no API key in compose
    assert_file_not_contains "$compose" "ANTHROPIC_API_KEY"
}

# ── yml_get_repos: repo list parsing ─────────────────────────────────

test_yaml_parser_single_repo_mounted() {
    # yml_get_repos: single repo → mounted at /workspace/<name>
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local fake_repo="$tmpdir/my-repo"
    mkdir -p "$fake_repo"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: oauth
docker:
  ports: []
  env: {}
repos:
  - path: $fake_repo
    name: my-repo
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "${fake_repo}:/workspace/my-repo"
}

test_yaml_parser_multiple_repos_all_mounted() {
    # yml_get_repos: multiple repos → all mounted
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local repo_a="$tmpdir/repo-a"
    local repo_b="$tmpdir/repo-b"
    mkdir -p "$repo_a" "$repo_b"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: oauth
docker:
  ports: []
  env: {}
repos:
  - path: $repo_a
    name: repo-a
  - path: $repo_b
    name: repo-b
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "${repo_a}:/workspace/repo-a"
    assert_file_contains "$compose" "${repo_b}:/workspace/repo-b"
}

test_yaml_parser_empty_repos_list_no_repo_mount() {
    # yml_get_repos: repos: [] → no repo mounts in compose
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "# Repositories"
    # No actual repo lines after the comment
    assert_file_not_contains "$compose" "/workspace/nonexistent"
}

test_yaml_parser_repos_do_not_bleed_into_docker_section() {
    # Parser stops at next top-level key: docker: ports are still parsed
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local fake_repo="$tmpdir/repo-a"
    mkdir -p "$fake_repo"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: oauth
repos:
  - path: $fake_repo
    name: repo-a
docker:
  ports:
    - "9999:9999"
  env: {}
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    # Repos parsed correctly
    assert_file_contains "$compose" "${fake_repo}:/workspace/repo-a"
    # Ports also parsed correctly (parser didn't bleed repos into docker section)
    assert_file_contains "$compose" '"9999:9999"'
}

# ── yml_get_ports: port list parsing ─────────────────────────────────

test_yaml_parser_single_port_in_compose() {
    # yml_get_ports: single port appears in compose
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: oauth
docker:
  ports:
    - "5000:5000"
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" '"5000:5000"'
}

test_yaml_parser_multiple_ports_all_in_compose() {
    # yml_get_ports: multiple ports all appear
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: oauth
docker:
  ports:
    - "3000:3000"
    - "8080:8080"
    - "5432:5432"
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" '"3000:3000"'
    assert_file_contains "$compose" '"8080:8080"'
    assert_file_contains "$compose" '"5432:5432"'
}

# ── yml_get_env: environment variable parsing ─────────────────────────

test_yaml_parser_single_env_var_in_compose() {
    # yml_get_env: single env var from docker.env in compose
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: oauth
docker:
  ports: []
  env:
    NODE_ENV: production
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "NODE_ENV=production"
}

test_yaml_parser_multiple_env_vars_in_compose() {
    # yml_get_env: multiple env vars all present
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: oauth
docker:
  ports: []
  env:
    NODE_ENV: production
    LOG_LEVEL: debug
    APP_PORT: "8080"
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "NODE_ENV=production"
    assert_file_contains "$compose" "LOG_LEVEL=debug"
    assert_file_contains "$compose" "APP_PORT=8080"
}

test_yaml_parser_empty_env_no_extra_vars() {
    # yml_get_env: docker.env: {} → no user env vars in compose
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    # System env vars present, but no user-defined ones
    assert_file_contains "$compose" "PROJECT_NAME=test-proj"
    assert_file_not_contains "$compose" "NODE_ENV"
}

# ── yml_get_extra_mounts: extra_mounts parsing ───────────────────────

test_yaml_parser_extra_mount_readonly_true() {
    # yml_get_extra_mounts: readonly:true → :ro suffix
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local docs_dir="$tmpdir/docs"
    mkdir -p "$docs_dir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: oauth
docker:
  ports: []
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
extra_mounts:
  - source: $docs_dir
    target: /workspace/docs
    readonly: true
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "${docs_dir}:/workspace/docs:ro"
}

test_yaml_parser_extra_mount_readonly_false() {
    # yml_get_extra_mounts: readonly:false → no :ro suffix
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local rw_dir="$tmpdir/rw-mount"
    mkdir -p "$rw_dir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: oauth
docker:
  ports: []
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
extra_mounts:
  - source: $rw_dir
    target: /workspace/rw
    readonly: false
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "${rw_dir}:/workspace/rw"
    assert_file_not_contains "$compose" "${rw_dir}:/workspace/rw:ro"
}

test_yaml_parser_multiple_extra_mounts() {
    # yml_get_extra_mounts: multiple mounts all present
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local dir_a="$tmpdir/dir-a"
    local dir_b="$tmpdir/dir-b"
    mkdir -p "$dir_a" "$dir_b"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: oauth
docker:
  ports: []
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
extra_mounts:
  - source: $dir_a
    target: /workspace/a
    readonly: true
  - source: $dir_b
    target: /workspace/b
    readonly: false
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "${dir_a}:/workspace/a:ro"
    assert_file_contains "$compose" "${dir_b}:/workspace/b"
}

# ── yml_get_packs: packs list parsing ────────────────────────────────

test_yaml_parser_pack_knowledge_mounted_readonly() {
    # yml_get_packs: knowledge dir is mounted read-only in compose (ADR-14)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local pack_src="$tmpdir/pack-source"
    mkdir -p "$pack_src"
    echo "knowledge content" > "$pack_src/doc.md"
    create_pack "$tmpdir" "my-pack" "$(cat <<YAML
name: my-pack
knowledge:
  source: $pack_src
  files:
    - doc.md
YAML
)"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: oauth
docker:
  ports: []
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
packs:
  - my-pack
YAML
)"
    run_cco start "test-proj" --dry-run
    # Knowledge dir should be mounted read-only in compose
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "${pack_src}:/workspace/.claude/packs/my-pack:ro"
    # Knowledge should NOT be copied to project directory
    assert_file_not_exists "$CCO_PROJECTS_DIR/test-proj/.claude/packs/my-pack/doc.md"
}

test_yaml_parser_no_packs_section_no_pack_mounts() {
    # yml_get_packs: no packs → no pack mount lines in compose
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_not_contains "$compose" "Pack resources"
}

# ── _parse_bool: boolean normalization (ADR-13) ─────────────────────
# These unit tests source yaml.sh directly for direct function access.

test_parse_bool_true_variants() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    # _parse_bool accepts YAML boolean variants for true
    assert_equals "true" "$(_parse_bool "true" "false")"
    assert_equals "true" "$(_parse_bool "True" "false")"
    assert_equals "true" "$(_parse_bool "TRUE" "false")"
    assert_equals "true" "$(_parse_bool "yes" "false")"
    assert_equals "true" "$(_parse_bool "Yes" "false")"
    assert_equals "true" "$(_parse_bool "YES" "false")"
    assert_equals "true" "$(_parse_bool "on" "false")"
    assert_equals "true" "$(_parse_bool "ON" "false")"
    assert_equals "true" "$(_parse_bool "1" "false")"
}

test_parse_bool_false_variants() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    # _parse_bool accepts YAML boolean variants for false
    assert_equals "false" "$(_parse_bool "false" "true")"
    assert_equals "false" "$(_parse_bool "False" "true")"
    assert_equals "false" "$(_parse_bool "FALSE" "true")"
    assert_equals "false" "$(_parse_bool "no" "true")"
    assert_equals "false" "$(_parse_bool "No" "true")"
    assert_equals "false" "$(_parse_bool "NO" "true")"
    assert_equals "false" "$(_parse_bool "off" "true")"
    assert_equals "false" "$(_parse_bool "OFF" "true")"
    assert_equals "false" "$(_parse_bool "0" "true")"
}

test_parse_bool_trims_whitespace() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    # _parse_bool handles trailing/leading whitespace (the original bug)
    assert_equals "true" "$(_parse_bool "true   " "false")"
    assert_equals "true" "$(_parse_bool "  true" "false")"
    assert_equals "true" "$(_parse_bool "  true   " "false")"
    assert_equals "false" "$(_parse_bool "  false  " "true")"
}

test_parse_bool_empty_uses_safe_default() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    # _parse_bool returns safe_default when value is empty
    assert_equals "true" "$(_parse_bool "" "true")"
    assert_equals "false" "$(_parse_bool "" "false")"
    # Whitespace-only treated as empty
    assert_equals "true" "$(_parse_bool "   " "true")"
}

test_parse_bool_invalid_uses_safe_default() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    # _parse_bool warns and returns safe_default for invalid values
    local result
    result=$(_parse_bool "invalid" "true" 2>/dev/null)
    assert_equals "true" "$result"
    result=$(_parse_bool "maybe" "false" 2>/dev/null)
    assert_equals "false" "$result"
}

# ── extra_mounts: secure-by-default readonly (ADR-13) ────────────────

test_yaml_parser_extra_mount_readonly_omitted_defaults_to_ro() {
    # ADR-13: readonly field omitted → mount as read-only (secure default)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local docs_dir="$tmpdir/docs"
    mkdir -p "$docs_dir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
docker:
  ports: []
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
extra_mounts:
  - source: $docs_dir
    target: /workspace/docs
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "${docs_dir}:/workspace/docs:ro"
}

test_yaml_parser_extra_mount_readonly_with_trailing_spaces() {
    # ADR-13: "true   " (trailing spaces) → still :ro
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local docs_dir="$tmpdir/docs"
    mkdir -p "$docs_dir"
    # Use printf to preserve trailing spaces exactly
    create_project "$tmpdir" "test-proj" "$(printf 'name: test-proj
docker:
  ports: []
  env: {}
repos:
  - path: %s
    name: dummy-repo
extra_mounts:
  - source: %s
    target: /workspace/docs
    readonly: true
' "$CCO_DUMMY_REPO" "$docs_dir")"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "${docs_dir}:/workspace/docs:ro"
}

test_yaml_parser_extra_mount_readonly_yes_variant() {
    # ADR-13: "yes" → treated as true → :ro
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local docs_dir="$tmpdir/docs"
    mkdir -p "$docs_dir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
docker:
  ports: []
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
extra_mounts:
  - source: $docs_dir
    target: /workspace/docs
    readonly: yes
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "${docs_dir}:/workspace/docs:ro"
}

test_yaml_parser_extra_mount_readonly_false_explicit_rw() {
    # ADR-13: explicit "false" → no :ro suffix (read-write)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local rw_dir="$tmpdir/rw-mount"
    mkdir -p "$rw_dir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
docker:
  ports: []
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
extra_mounts:
  - source: $rw_dir
    target: /workspace/rw
    readonly: false
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "${rw_dir}:/workspace/rw"
    assert_file_not_contains "$compose" "${rw_dir}:/workspace/rw:ro"
}

# ── Project name validation (ADR-13) ────────────────────────────────

test_yaml_parser_invalid_project_name_rejected() {
    # ADR-13: project name with spaces → error
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: "my invalid project"
docker:
  ports: []
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    if run_cco start "test-proj" --dry-run 2>/dev/null; then
        fail "Expected error for invalid project name with spaces"
    fi
    assert_output_contains "Invalid project name"
}

# ── Browser CDP port validation (ADR-13) ─────────────────────────────

test_yaml_parser_invalid_cdp_port_rejected() {
    # ADR-13: non-numeric cdp_port → error
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
docker:
  ports: []
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
browser:
  enabled: true
  cdp_port: abc
YAML
)"
    if run_cco start "test-proj" --dry-run 2>/dev/null; then
        fail "Expected error for non-numeric cdp_port"
    fi
    assert_output_contains "Invalid browser.cdp_port"
}

# ── Auth method validation (ADR-13) ──────────────────────────────────

test_yaml_parser_invalid_auth_method_defaults_to_oauth() {
    # ADR-13: invalid auth.method → warns, defaults to oauth
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
auth:
  method: invalid_method
docker:
  ports: []
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    # Invalid method → defaults to oauth → no API key in compose
    assert_file_not_contains "$compose" "ANTHROPIC_API_KEY"
}

# ── Inline comment stripping ─────────────────────────────────────────
# These tests verify that YAML inline comments (# ...) are stripped
# from all parsed values across all yml_get_* functions.

test_yaml_parser_repo_path_with_inline_comment() {
    # yml_get_repos: inline comment on path line is stripped
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local fake_repo="$tmpdir/my-repo"
    mkdir -p "$fake_repo"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
docker:
  ports: []
  env: {}
repos:
  - path: $fake_repo # This is a comment
    name: my-repo
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "${fake_repo}:/workspace/my-repo"
    assert_file_not_contains "$compose" "# This is a comment"
}

test_yaml_parser_repo_name_with_inline_comment() {
    # yml_get_repos: inline comment on name line is stripped
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local fake_repo="$tmpdir/my-repo"
    mkdir -p "$fake_repo"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
docker:
  ports: []
  env: {}
repos:
  - path: $fake_repo
    name: my-repo # main repository
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "${fake_repo}:/workspace/my-repo"
    assert_file_not_contains "$compose" "# main repository"
}

test_yaml_parser_port_with_inline_comment() {
    # yml_get_ports: inline comment on port line is stripped
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
docker:
  ports:
    - "3000:3000" # web server
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" '"3000:3000"'
    assert_file_not_contains "$compose" "# web server"
}

test_yaml_parser_env_var_with_inline_comment() {
    # yml_get_env: inline comment on env var line is stripped
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
docker:
  ports: []
  env:
    NODE_ENV: production # deploy target
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "NODE_ENV=production"
    assert_file_not_contains "$compose" "# deploy target"
}

test_yaml_parser_extra_mount_with_inline_comments() {
    # yml_get_extra_mounts: inline comments on source/target/readonly stripped
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local docs_dir="$tmpdir/docs"
    mkdir -p "$docs_dir"
    create_project "$tmpdir" "test-proj" "$(cat <<YAML
name: test-proj
docker:
  ports: []
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
extra_mounts:
  - source: $docs_dir # shared docs
    target: /workspace/docs # mount point
    readonly: true # keep safe
YAML
)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_contains "$compose" "${docs_dir}:/workspace/docs:ro"
    assert_file_not_contains "$compose" "# shared docs"
}

test_yaml_parser_pack_name_with_inline_comment() {
    # yml_get_packs: inline comment on pack name is stripped
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    local tmpfile; tmpfile=$(mktemp); trap "rm -f '$tmpfile'" EXIT
    cat > "$tmpfile" <<'YAML'
packs:
  - my-pack # core knowledge pack
  - other-pack
YAML
    local result
    result=$(yml_get_packs "$tmpfile")
    assert_equals "my-pack
other-pack" "$result"
}

# ── yml_get_deep: 3-level nested key parsing ─────────────────────────

test_yaml_parser_deep_3level_value() {
    # yml_get_deep reads 3-level "docker.containers.policy"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    local tmpfile; tmpfile=$(mktemp); trap "rm -f '$tmpfile'" EXIT
    cat > "$tmpfile" <<'YAML'
docker:
  containers:
    policy: allowlist
    create: true
  mounts:
    policy: none
YAML
    local result
    result=$(yml_get_deep "$tmpfile" "docker.containers.policy")
    assert_equals "allowlist" "$result"
    result=$(yml_get_deep "$tmpfile" "docker.containers.create")
    assert_equals "true" "$result"
    result=$(yml_get_deep "$tmpfile" "docker.mounts.policy")
    assert_equals "none" "$result"
}

test_yaml_parser_deep_3level_missing() {
    # yml_get_deep returns empty for missing 3-level keys
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    local tmpfile; tmpfile=$(mktemp); trap "rm -f '$tmpfile'" EXIT
    cat > "$tmpfile" <<'YAML'
docker:
  ports: []
YAML
    local result
    result=$(yml_get_deep "$tmpfile" "docker.containers.policy")
    assert_equals "" "$result"
}

# ── yml_get_deep_list: 3-level nested list parsing ───────────────────

test_yaml_parser_deep_list() {
    # yml_get_deep_list reads 3-level list "docker.security.drop_capabilities"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    local tmpfile; tmpfile=$(mktemp); trap "rm -f '$tmpfile'" EXIT
    cat > "$tmpfile" <<'YAML'
docker:
  security:
    drop_capabilities:
      - SYS_ADMIN
      - NET_ADMIN
      - NET_RAW
YAML
    local result
    result=$(yml_get_deep_list "$tmpfile" "docker.security.drop_capabilities")
    assert_equals "SYS_ADMIN
NET_ADMIN
NET_RAW" "$result"
}

# ── yml_get_deep_map: 3-level nested map parsing ────────────────────

test_yaml_parser_deep_map() {
    # yml_get_deep_map reads 3-level map "docker.containers.required_labels"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    local tmpfile; tmpfile=$(mktemp); trap "rm -f '$tmpfile'" EXIT
    cat > "$tmpfile" <<'YAML'
docker:
  containers:
    required_labels:
      cco.project: myapp
      cco.env: dev
YAML
    local result
    result=$(yml_get_deep_map "$tmpfile" "docker.containers.required_labels")
    # Output should contain both key:value pairs
    echo "$result" | grep -q "cco.project:myapp" || fail "missing cco.project label"
    echo "$result" | grep -q "cco.env:dev" || fail "missing cco.env label"
}

# ── yml_get_deep4: 4-level nested key parsing ────────────────────────

test_yaml_parser_deep4_value() {
    # yml_get_deep4 reads 4-level "docker.security.resources.memory"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    local tmpfile; tmpfile=$(mktemp); trap "rm -f '$tmpfile'" EXIT
    cat > "$tmpfile" <<'YAML'
docker:
  security:
    resources:
      memory: 2g
      cpus: 0.5
      max_containers: 5
YAML
    local result
    result=$(yml_get_deep4 "$tmpfile" "docker.security.resources.memory")
    assert_equals "2g" "$result"
    result=$(yml_get_deep4 "$tmpfile" "docker.security.resources.cpus")
    assert_equals "0.5" "$result"
    result=$(yml_get_deep4 "$tmpfile" "docker.security.resources.max_containers")
    assert_equals "5" "$result"
}

test_yaml_parser_deep4_missing() {
    # yml_get_deep4 returns empty for missing 4-level keys
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    local tmpfile; tmpfile=$(mktemp); trap "rm -f '$tmpfile'" EXIT
    cat > "$tmpfile" <<'YAML'
docker:
  security:
    no_privileged: true
YAML
    local result
    result=$(yml_get_deep4 "$tmpfile" "docker.security.resources.memory")
    assert_equals "" "$result"
}

# ── yml_validate_enum: enum validation with fallback ─────────────────

test_yaml_parser_validate_enum_valid() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    local result
    result=$(yml_validate_enum "allowlist" "project_only" "project_only|allowlist|denylist|unrestricted")
    assert_equals "allowlist" "$result"
}

test_yaml_parser_validate_enum_default_on_empty() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    local result
    result=$(yml_validate_enum "" "project_only" "project_only|allowlist|denylist|unrestricted")
    assert_equals "project_only" "$result"
}

test_yaml_parser_validate_enum_fallback_on_invalid() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    local result
    result=$(yml_validate_enum "bogus_value" "project_only" "project_only|allowlist|denylist|unrestricted" 2>/dev/null)
    assert_equals "project_only" "$result"
}

# ── yml_get_list: inline comment stripping ───────────────────────────

test_yaml_parser_list_with_inline_comment() {
    # yml_get_list: inline comments on list items are stripped
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    local tmpfile; tmpfile=$(mktemp); trap "rm -f '$tmpfile'" EXIT
    cat > "$tmpfile" <<'YAML'
browser:
  mcp_args:
    - --headless # run without display
    - --no-sandbox
YAML
    local result
    result=$(yml_get_list "$tmpfile" "browser.mcp_args")
    assert_equals "--headless
--no-sandbox" "$result"
}
