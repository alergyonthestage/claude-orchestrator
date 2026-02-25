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
    create_project "$tmpdir" "test-proj" "$(cat <<'YAML'
name: test-proj
auth:
  method: oauth
docker:
  ports: []
  env: {}
repos: []
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
    create_project "$tmpdir" "test-proj" "$(cat <<'YAML'
name: test-proj
auth:
  method: api_key
docker:
  ports: []
  env: {}
repos: []
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
    create_project "$tmpdir" "test-proj" "$(cat <<'YAML'
name: test-proj
docker:
  ports: []
  env: {}
repos: []
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
    create_project "$tmpdir" "test-proj" "$(cat <<'YAML'
name: test-proj
auth:
  method: oauth
docker:
  ports:
    - "5000:5000"
  env: {}
repos: []
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
    create_project "$tmpdir" "test-proj" "$(cat <<'YAML'
name: test-proj
auth:
  method: oauth
docker:
  ports:
    - "3000:3000"
    - "8080:8080"
    - "5432:5432"
  env: {}
repos: []
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
    create_project "$tmpdir" "test-proj" "$(cat <<'YAML'
name: test-proj
auth:
  method: oauth
docker:
  ports: []
  env:
    NODE_ENV: production
repos: []
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
    create_project "$tmpdir" "test-proj" "$(cat <<'YAML'
name: test-proj
auth:
  method: oauth
docker:
  ports: []
  env:
    NODE_ENV: production
    LOG_LEVEL: debug
    APP_PORT: "8080"
repos: []
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
repos: []
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
repos: []
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
repos: []
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

test_yaml_parser_pack_knowledge_copied_not_mounted() {
    # yml_get_packs: knowledge files are copied to .claude/packs/, not mounted as volumes
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
    create_project "$tmpdir" "test-proj" "$(cat <<'YAML'
name: test-proj
auth:
  method: oauth
docker:
  ports: []
  env: {}
repos: []
packs:
  - my-pack
YAML
)"
    run_cco start "test-proj" --dry-run
    # Knowledge files should be copied, not mounted
    local copied="$CCO_PROJECTS_DIR/test-proj/.claude/packs/my-pack/doc.md"
    [[ -f "$copied" ]] || fail "Knowledge file not copied to $copied"
    # Compose should NOT contain pack volume mounts
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_not_contains "$compose" "/.packs/"
}

test_yaml_parser_no_packs_section_no_pack_mounts() {
    # yml_get_packs: no packs → no /.packs/ mounts in compose
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run
    local compose="$CCO_PROJECTS_DIR/test-proj/docker-compose.yml"
    assert_file_not_contains "$compose" "/.packs/"
}
