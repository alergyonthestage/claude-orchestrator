#!/usr/bin/env bash
# tests/test_project_install.sh — cco project install tests
#
# Uses bare git repos as mock remotes with templates.

# ── Helper: create a mock Config Repo with templates ─────────────────

# Create a bare git repo with templates and manifest.yml.
# Usage: _create_mock_template_repo <tmpdir> <template_names...>
# Outputs: path to the bare repo
_create_mock_template_repo() {
    local tmpdir="$1"; shift
    local template_names=("$@")
    local work_dir="$tmpdir/mock-tmpl-work"
    local bare_dir="$tmpdir/mock-tmpl-remote.git"

    # Create working copy
    mkdir -p "$work_dir/templates"

    # Create templates
    local manifest_templates=""
    for name in "${template_names[@]}"; do
        mkdir -p "$work_dir/templates/$name"/{.claude/rules,claude-state,memory}

        cat > "$work_dir/templates/$name/project.yml" <<YAML
name: {{PROJECT_NAME}}
description: "{{DESCRIPTION}}"
repos: []
docker:
  ports:
    - "3000:3000"
  env: {}
auth:
  method: oauth
YAML
        cat > "$work_dir/templates/$name/.claude/CLAUDE.md" <<YAML
# Project: {{PROJECT_NAME}}
## Overview
{{DESCRIPTION}}
YAML
        manifest_templates+="  - name: $name
    description: \"Template $name\"
"
    done

    # Create manifest.yml
    cat > "$work_dir/manifest.yml" <<YAML
name: "mock-config"
description: "Mock config repo for testing"

packs: []

templates:
${manifest_templates}
YAML

    # Create bare repo
    git init --bare -q "$bare_dir"
    git -C "$work_dir" init -q
    git -C "$work_dir" add -A
    git -C "$work_dir" commit -q -m "initial"
    git -C "$work_dir" remote add origin "$bare_dir"
    git -C "$work_dir" push -q origin main 2>/dev/null || \
        git -C "$work_dir" push -q origin master 2>/dev/null

    echo "$bare_dir"
}

# ── install tests ─────────────────────────────────────────────────────

test_project_install_from_single_template() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local remote
    remote=$(_create_mock_template_repo "$tmpdir" "web-app")
    run_cco project install "$remote" --var "DESCRIPTION=Test app"
    assert_dir_exists "$CCO_PROJECTS_DIR/web-app"
    assert_file_exists "$CCO_PROJECTS_DIR/web-app/project.yml"
}

test_project_install_pick_specific_template() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local remote
    remote=$(_create_mock_template_repo "$tmpdir" "frontend" "backend")
    run_cco project install "$remote" --pick "backend" --var "DESCRIPTION=API"
    assert_dir_exists "$CCO_PROJECTS_DIR/backend"
    assert_dir_not_exists "$CCO_PROJECTS_DIR/frontend"
}

test_project_install_requires_pick_for_multiple() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local remote
    remote=$(_create_mock_template_repo "$tmpdir" "alpha" "beta")
    if run_cco project install "$remote" 2>/dev/null; then
        echo "ASSERTION FAILED: should require --pick for multiple templates"
        return 1
    fi
}

test_project_install_pick_nonexistent_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local remote
    remote=$(_create_mock_template_repo "$tmpdir" "web-app")
    if run_cco project install "$remote" --pick "nonexistent" 2>/dev/null; then
        echo "ASSERTION FAILED: should fail for nonexistent template"
        return 1
    fi
}

test_project_install_as_renames_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local remote
    remote=$(_create_mock_template_repo "$tmpdir" "web-app")
    run_cco project install "$remote" --as "my-project" --var "DESCRIPTION=Custom"
    assert_dir_exists "$CCO_PROJECTS_DIR/my-project"
    assert_dir_not_exists "$CCO_PROJECTS_DIR/web-app"
}

test_project_install_resolves_project_name() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local remote
    remote=$(_create_mock_template_repo "$tmpdir" "web-app")
    run_cco project install "$remote" --as "my-app" --var "DESCRIPTION=My App"
    assert_file_contains "$CCO_PROJECTS_DIR/my-app/project.yml" "name: my-app"
}

test_project_install_resolves_description() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local remote
    remote=$(_create_mock_template_repo "$tmpdir" "web-app")
    run_cco project install "$remote" --var "DESCRIPTION=A cool project"
    assert_file_contains "$CCO_PROJECTS_DIR/web-app/project.yml" "A cool project"
}

test_project_install_resolves_claude_md() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local remote
    remote=$(_create_mock_template_repo "$tmpdir" "web-app")
    run_cco project install "$remote" --as "my-app" --var "DESCRIPTION=Cool"
    assert_file_contains "$CCO_PROJECTS_DIR/my-app/.claude/CLAUDE.md" "my-app"
    assert_file_contains "$CCO_PROJECTS_DIR/my-app/.claude/CLAUDE.md" "Cool"
}

test_project_install_no_placeholders_remain() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local remote
    remote=$(_create_mock_template_repo "$tmpdir" "web-app")
    run_cco project install "$remote" --var "DESCRIPTION=Done"
    assert_no_placeholders "$CCO_PROJECTS_DIR/web-app/project.yml"
    assert_no_placeholders "$CCO_PROJECTS_DIR/web-app/.claude/CLAUDE.md"
}

test_project_install_conflict_fails_without_force() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local remote
    remote=$(_create_mock_template_repo "$tmpdir" "web-app")
    run_cco project install "$remote" --var "DESCRIPTION=First"
    if run_cco project install "$remote" --var "DESCRIPTION=Second" 2>/dev/null; then
        echo "ASSERTION FAILED: should fail when project exists"
        return 1
    fi
}

test_project_install_force_overwrites() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local remote
    remote=$(_create_mock_template_repo "$tmpdir" "web-app")
    run_cco project install "$remote" --var "DESCRIPTION=First"
    run_cco project install "$remote" --force --var "DESCRIPTION=Second"
    assert_file_contains "$CCO_PROJECTS_DIR/web-app/project.yml" "Second"
}

test_project_install_creates_claude_state() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local remote
    remote=$(_create_mock_template_repo "$tmpdir" "web-app")
    run_cco project install "$remote" --var "DESCRIPTION=App"
    assert_dir_exists "$CCO_PROJECTS_DIR/web-app/claude-state"
    assert_dir_exists "$CCO_PROJECTS_DIR/web-app/memory"
}

test_project_install_rejects_invalid_name() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local remote
    remote=$(_create_mock_template_repo "$tmpdir" "web-app")
    if run_cco project install "$remote" --as "Invalid Name" 2>/dev/null; then
        echo "ASSERTION FAILED: should reject invalid project name"
        return 1
    fi
}

test_project_install_rejects_no_templates() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Create repo with no templates in manifest.yml
    local work_dir="$tmpdir/no-tmpl-work"
    local bare_dir="$tmpdir/no-tmpl.git"
    mkdir -p "$work_dir"
    cat > "$work_dir/manifest.yml" <<YAML
name: "empty"
packs: []
templates: []
YAML
    git init --bare -q "$bare_dir"
    git -C "$work_dir" init -q
    git -C "$work_dir" add -A
    git -C "$work_dir" commit -q -m "initial"
    git -C "$work_dir" remote add origin "$bare_dir"
    git -C "$work_dir" push -q origin main 2>/dev/null || \
        git -C "$work_dir" push -q origin master 2>/dev/null

    if run_cco project install "$bare_dir" 2>/dev/null; then
        echo "ASSERTION FAILED: should fail when no templates"
        return 1
    fi
}

test_project_install_default_description() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local remote
    remote=$(_create_mock_template_repo "$tmpdir" "web-app")
    # No --var DESCRIPTION — should use default "TODO: Add project description"
    run_cco project install "$remote"
    assert_file_contains "$CCO_PROJECTS_DIR/web-app/project.yml" "TODO: Add project description"
}

# ── help tests ────────────────────────────────────────────────────────

test_project_install_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco project install --help
    assert_output_contains "install"
    assert_output_contains "--pick"
    assert_output_contains "--as"
    assert_output_contains "--var"
}
