#!/usr/bin/env bash
# tests/test_project_pack.sh — cco project add-pack / remove-pack tests

# ── Helper: create a project with a project.yml ─────────────────────

_setup_project_with_packs() {
    local tmpdir="$1" project_name="$2"
    shift 2
    local pack_list="$*"

    local project_dir="$CCO_PROJECTS_DIR/$project_name"
    mkdir -p "$project_dir/.claude"

    # Build packs section
    if [[ -z "$pack_list" ]]; then
        local packs_section="packs: []"
    else
        local packs_section="packs:"
        for p in $pack_list; do
            packs_section+=$'\n'"  - $p"
        done
    fi

    cat > "$project_dir/project.yml" <<YAML
name: $project_name
description: "Test project"
repos: []
docker:
  ports: []
  env: {}
auth:
  method: oauth

$packs_section
YAML
}

_setup_pack() {
    local name="$1"
    mkdir -p "$CCO_PACKS_DIR/$name"
    cat > "$CCO_PACKS_DIR/$name/pack.yml" <<YAML
name: $name
description: "Test pack $name"
YAML
}

# ── add-pack ────────────────────────────────────────────────────────

test_project_add_pack_to_empty_list() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _setup_project_with_packs "$tmpdir" "my-proj"
    _setup_pack "alpha"
    run_cco project add-pack my-proj alpha
    assert_file_contains "$CCO_PROJECTS_DIR/my-proj/project.yml" "  - alpha"
}

test_project_add_pack_to_existing_list() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _setup_project_with_packs "$tmpdir" "my-proj" "existing"
    _setup_pack "new-pack"
    run_cco project add-pack my-proj new-pack
    assert_file_contains "$CCO_PROJECTS_DIR/my-proj/project.yml" "  - existing"
    assert_file_contains "$CCO_PROJECTS_DIR/my-proj/project.yml" "  - new-pack"
}

test_project_add_pack_duplicate_warns() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _setup_project_with_packs "$tmpdir" "my-proj" "alpha"
    _setup_pack "alpha"
    run_cco project add-pack my-proj alpha
    assert_output_contains "already"
}

test_project_add_pack_nonexistent_pack_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _setup_project_with_packs "$tmpdir" "my-proj"
    if run_cco project add-pack my-proj ghost 2>/dev/null; then
        echo "ASSERTION FAILED: should fail for nonexistent pack"
        return 1
    fi
}

test_project_add_pack_nonexistent_project_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _setup_pack "alpha"
    if run_cco project add-pack ghost alpha 2>/dev/null; then
        echo "ASSERTION FAILED: should fail for nonexistent project"
        return 1
    fi
}

test_project_add_pack_missing_args_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco project add-pack 2>/dev/null; then
        echo "ASSERTION FAILED: should fail with missing args"
        return 1
    fi
}

# ── remove-pack ─────────────────────────────────────────────────────

test_project_remove_pack() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _setup_project_with_packs "$tmpdir" "my-proj" "alpha beta"
    run_cco project remove-pack my-proj alpha
    assert_file_not_contains "$CCO_PROJECTS_DIR/my-proj/project.yml" "  - alpha"
    assert_file_contains "$CCO_PROJECTS_DIR/my-proj/project.yml" "  - beta"
}

test_project_remove_pack_last_becomes_empty() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _setup_project_with_packs "$tmpdir" "my-proj" "only-one"
    run_cco project remove-pack my-proj only-one
    assert_file_not_contains "$CCO_PROJECTS_DIR/my-proj/project.yml" "  - only-one"
    assert_file_contains "$CCO_PROJECTS_DIR/my-proj/project.yml" "packs: []"
}

test_project_remove_pack_not_present_warns() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _setup_project_with_packs "$tmpdir" "my-proj" "alpha"
    run_cco project remove-pack my-proj ghost
    assert_output_contains "not in"
}

test_project_remove_pack_nonexistent_project_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco project remove-pack ghost alpha 2>/dev/null; then
        echo "ASSERTION FAILED: should fail for nonexistent project"
        return 1
    fi
}

# ── edge cases ──────────────────────────────────────────────────────

test_project_add_pack_to_commented_section() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local project_dir="$CCO_PROJECTS_DIR/my-proj"
    mkdir -p "$project_dir/.claude"
    cat > "$project_dir/project.yml" <<'YAML'
name: my-proj
repos: []
# packs:
#   - old-pack
YAML
    _setup_pack "new-pack"
    run_cco project add-pack my-proj new-pack
    assert_file_contains "$CCO_PROJECTS_DIR/my-proj/project.yml" "packs:"
    assert_file_contains "$CCO_PROJECTS_DIR/my-proj/project.yml" "  - new-pack"
}

test_project_add_pack_no_section_appends() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local project_dir="$CCO_PROJECTS_DIR/my-proj"
    mkdir -p "$project_dir/.claude"
    cat > "$project_dir/project.yml" <<'YAML'
name: my-proj
repos: []
YAML
    _setup_pack "added"
    run_cco project add-pack my-proj added
    assert_file_contains "$CCO_PROJECTS_DIR/my-proj/project.yml" "packs:"
    assert_file_contains "$CCO_PROJECTS_DIR/my-proj/project.yml" "  - added"
}

test_project_add_then_remove_roundtrip() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _setup_project_with_packs "$tmpdir" "my-proj"
    _setup_pack "roundtrip"
    run_cco project add-pack my-proj roundtrip
    assert_file_contains "$CCO_PROJECTS_DIR/my-proj/project.yml" "  - roundtrip"
    run_cco project remove-pack my-proj roundtrip
    assert_file_not_contains "$CCO_PROJECTS_DIR/my-proj/project.yml" "  - roundtrip"
    assert_file_contains "$CCO_PROJECTS_DIR/my-proj/project.yml" "packs: []"
}

# ── help ────────────────────────────────────────────────────────────

test_project_add_pack_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco project add-pack --help
    assert_output_contains "Add a knowledge pack"
}

test_project_remove_pack_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco project remove-pack --help
    assert_output_contains "Remove a knowledge pack"
}
