#!/usr/bin/env bash
# tests/test_project_show.sh — cco project show and validate command tests
#
# Verifies project show and validate commands.

# ── show ──────────────────────────────────────────────────────────────

test_project_show_displays_name() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-proj" "$(cat <<YAML
name: my-proj
description: "A test project"
repos: []
YAML
)"
    run_cco project show "my-proj"
    assert_output_contains "my-proj"
}

test_project_show_lists_repos() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local repo_dir="$tmpdir/my-repo"
    mkdir -p "$repo_dir"
    create_project "$tmpdir" "my-proj" "$(cat <<YAML
name: my-proj
repos:
  - path: $repo_dir
    name: my-repo
YAML
)"
    run_cco project show "my-proj"
    assert_output_contains "my-repo"
}

test_project_show_lists_packs() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_pack "$tmpdir" "test-pack" "$(cat <<YAML
name: test-pack
YAML
)"
    create_project "$tmpdir" "my-proj" "$(cat <<YAML
name: my-proj
repos: []
packs:
  - test-pack
YAML
)"
    run_cco project show "my-proj"
    assert_output_contains "test-pack"
}

test_project_show_docker_config() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-proj" "$(cat <<YAML
name: my-proj
auth:
  method: api_key
docker:
  ports:
    - "3000:3000"
  env: {}
repos: []
YAML
)"
    run_cco project show "my-proj"
    assert_output_contains "api_key"
    assert_output_contains "3000:3000"
}

test_project_show_fails_if_not_found() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco project show "nonexistent" 2>/dev/null; then
        echo "ASSERTION FAILED: should have failed for missing project"
        return 1
    fi
}

# ── D5 observability: roles + referenced-by + repo-centric view ──────

test_project_show_referenced_by() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    mkdir -p "$tmpdir/shared"
    seed_index_path shared "$tmpdir/shared"
    index_set_project_repos projB shared
    create_project "$tmpdir" projA "name: projA
repos:
  - path: \"@local\"
    name: shared"
    run_cco project show projA
    assert_output_contains "also referenced by: projB"
}

test_project_show_member_role_host() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    # A member repo whose .cco/ hosts projA → role 'host'.
    local hostrepo="$tmpdir/hostrepo"; mkdir -p "$hostrepo/.cco"
    printf 'name: projA\n' > "$hostrepo/.cco/project.yml"
    seed_index_path mainrepo "$hostrepo"
    create_project "$tmpdir" projA "name: projA
repos:
  - path: \"@local\"
    name: mainrepo"
    run_cco project show projA
    assert_output_contains "[host]"
}

test_project_show_repo_centric_view() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo="$tmpdir/myrepo"; mkdir -p "$repo/.cco"
    cat > "$repo/.cco/project.yml" <<'YML'
name: myproj
repos:
  - name: api
    url: git@github.com:org/api.git
YML
    cd "$repo"
    run_cco project show
    assert_output_contains "hosts project: myproj"
    assert_output_contains "api"
}
