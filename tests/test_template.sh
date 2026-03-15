#!/usr/bin/env bash
# tests/test_template.sh — Tests for template management commands

# ── _resolve_template ────────────────────────────────────────────────

test_template_resolve_native_fallback() {
    # _resolve_template falls back to native when no user template
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    # Set globals needed by _resolve_template
    export TEMPLATES_DIR="$CCO_TEMPLATES_DIR"
    export NATIVE_TEMPLATES_DIR="$REPO_ROOT/templates"

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/cmd-template.sh"

    local result
    result=$(_resolve_template "project" "base")
    assert_equals "$REPO_ROOT/templates/project/base" "$result" \
        "Should resolve to native project/base template"
}

test_template_resolve_user_priority() {
    # User templates take priority over native
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    export TEMPLATES_DIR="$CCO_TEMPLATES_DIR"
    export NATIVE_TEMPLATES_DIR="$REPO_ROOT/templates"

    # Create a user template
    mkdir -p "$CCO_TEMPLATES_DIR/project/base"
    echo "user-version" > "$CCO_TEMPLATES_DIR/project/base/marker.txt"

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/cmd-template.sh"

    local result
    result=$(_resolve_template "project" "base")
    assert_equals "$CCO_TEMPLATES_DIR/project/base" "$result" \
        "Should resolve to user template when it exists"
}

test_template_resolve_not_found() {
    # Nonexistent template triggers error
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    export TEMPLATES_DIR="$CCO_TEMPLATES_DIR"
    export NATIVE_TEMPLATES_DIR="$REPO_ROOT/templates"

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/cmd-template.sh"

    local output
    output=$(_resolve_template "project" "nonexistent" 2>&1) && {
        echo "ASSERTION FAILED: expected _resolve_template to fail"
        return 1
    }
    # Should have error message
    echo "$output" | grep -q "not found" || {
        echo "ASSERTION FAILED: expected 'not found' in error"
        return 1
    }
}

test_template_resolve_pack_native() {
    # Pack template resolves correctly
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    export TEMPLATES_DIR="$CCO_TEMPLATES_DIR"
    export NATIVE_TEMPLATES_DIR="$REPO_ROOT/templates"

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/cmd-template.sh"

    local result
    result=$(_resolve_template "pack" "base")
    assert_equals "$REPO_ROOT/templates/pack/base" "$result" \
        "Should resolve to native pack/base template"
}

# ── cco template list ────────────────────────────────────────────────

test_template_list_shows_native() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco template list
    assert_output_contains "base"
    assert_output_contains "native"
}

test_template_list_filter_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco template list --project
    assert_output_contains "Project templates:"
    assert_output_contains "base"
}

test_template_list_filter_pack() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco template list --pack
    assert_output_contains "Pack templates:"
    assert_output_contains "base"
}

test_template_list_shows_user_templates() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    # Create a user template
    mkdir -p "$CCO_TEMPLATES_DIR/project/custom"
    run_cco template list --project
    assert_output_contains "custom"
    assert_output_contains "user"
}

# ── cco template show ────────────────────────────────────────────────

test_template_show_native() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco template show base
    assert_output_contains "Template: base"
    assert_output_contains "native"
}

test_template_show_not_found() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco template show nonexistent && {
        echo "ASSERTION FAILED: expected show nonexistent to fail"
        return 1
    }
    return 0
}

# ── cco template create ──────────────────────────────────────────────

test_template_create_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco template create my-tmpl --project
    assert_dir_exists "$CCO_TEMPLATES_DIR/project/my-tmpl"
    assert_file_exists "$CCO_TEMPLATES_DIR/project/my-tmpl/project.yml"
}

test_template_create_pack() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco template create my-pack-tmpl --pack
    assert_dir_exists "$CCO_TEMPLATES_DIR/pack/my-pack-tmpl"
    assert_file_exists "$CCO_TEMPLATES_DIR/pack/my-pack-tmpl/pack.yml"
}

test_template_create_duplicate_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco template create dup-test --project
    run_cco template create dup-test --project && {
        echo "ASSERTION FAILED: expected duplicate create to fail"
        return 1
    }
    return 0
}

test_template_create_invalid_name_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco template create "Bad_Name" --project && {
        echo "ASSERTION FAILED: expected invalid name to fail"
        return 1
    }
    return 0
}

test_template_create_requires_kind() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco template create my-test && {
        echo "ASSERTION FAILED: expected missing --project/--pack to fail"
        return 1
    }
    return 0
}

# ── cco template remove ──────────────────────────────────────────────

test_template_remove_user() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco template create removable --project
    assert_dir_exists "$CCO_TEMPLATES_DIR/project/removable"
    run_cco template remove removable
    assert_dir_not_exists "$CCO_TEMPLATES_DIR/project/removable"
}

test_template_remove_native_fails() {
    # Native templates can't be removed (they're not in user templates dir)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco template remove base && {
        echo "ASSERTION FAILED: expected removing native template to fail"
        return 1
    }
    return 0
}

# ── project create --template ────────────────────────────────────────

test_project_create_with_template() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create a user template with a marker
    mkdir -p "$CCO_TEMPLATES_DIR/project/custom/.claude"
    cat > "$CCO_TEMPLATES_DIR/project/custom/project.yml" <<'YAML'
name: {{PROJECT_NAME}}
description: Custom template project
repos: []
YAML
    cat > "$CCO_TEMPLATES_DIR/project/custom/.claude/CLAUDE.md" <<'MD'
# {{PROJECT_NAME}} - Custom
MD

    run_cco project create my-proj --template custom
    assert_dir_exists "$CCO_PROJECTS_DIR/my-proj"
    assert_file_contains "$CCO_PROJECTS_DIR/my-proj/project.yml" "Custom template project"
    assert_file_contains "$CCO_PROJECTS_DIR/my-proj/project.yml" "name: my-proj"
}

# ── pack create --template ───────────────────────────────────────────

test_pack_create_with_default_template() {
    # Default pack create uses templates/pack/base
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco pack create my-test-pack
    assert_dir_exists "$CCO_PACKS_DIR/my-test-pack"
    assert_file_exists "$CCO_PACKS_DIR/my-test-pack/pack.yml"
    # Name should be substituted
    assert_file_contains "$CCO_PACKS_DIR/my-test-pack/pack.yml" "name: my-test-pack"
    # Placeholder should be gone
    assert_file_not_contains "$CCO_PACKS_DIR/my-test-pack/pack.yml" "{{PACK_NAME}}"
}

test_pack_create_with_named_template() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create a custom pack template
    mkdir -p "$CCO_TEMPLATES_DIR/pack/special/knowledge"
    cat > "$CCO_TEMPLATES_DIR/pack/special/pack.yml" <<'YAML'
name: {{PACK_NAME}}
# Special template
YAML

    run_cco pack create my-special --template special
    assert_dir_exists "$CCO_PACKS_DIR/my-special"
    assert_file_contains "$CCO_PACKS_DIR/my-special/pack.yml" "name: my-special"
    assert_file_contains "$CCO_PACKS_DIR/my-special/pack.yml" "Special template"
}

# ── cco template --help ──────────────────────────────────────────────

test_template_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco template --help
    assert_output_contains "list"
    assert_output_contains "show"
    assert_output_contains "create"
    assert_output_contains "remove"
}

# ── Scenario 15: template create --project strips .cco/ ──────────────

test_template_create_from_project_strips_cco() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create a project with .cco/ runtime state
    local project_dir="$CCO_PROJECTS_DIR/src-proj"
    mkdir -p "$project_dir/.claude" "$project_dir/.cco/managed" "$project_dir/.cco/claude-state"
    cat > "$project_dir/project.yml" <<'YAML'
name: src-proj
repos: []
YAML
    echo "schema_version: 9" > "$project_dir/.cco/meta"
    echo "generated" > "$project_dir/.cco/docker-compose.yml"
    echo "{}" > "$project_dir/.cco/managed/browser.json"
    echo "session" > "$project_dir/.cco/claude-state/session.jsonl"
    mkdir -p "$project_dir/.cco/base"
    echo "base" > "$project_dir/.cco/base/settings.json"
    echo "SECRET=pass" > "$project_dir/secrets.env"
    mkdir -p "$project_dir/.tmp"
    echo "dump" > "$project_dir/.tmp/output"

    run_cco template create my-tmpl --project --from src-proj

    local tmpl_dir="$CCO_TEMPLATES_DIR/project/my-tmpl"
    assert_dir_exists "$tmpl_dir"
    assert_file_exists "$tmpl_dir/project.yml"
    # .cco/ should be completely stripped
    [[ ! -d "$tmpl_dir/.cco" ]] || {
        echo "ASSERTION FAILED: .cco/ should be stripped from template"
        return 1
    }
    # .tmp/ should be stripped
    [[ ! -d "$tmpl_dir/.tmp" ]] || {
        echo "ASSERTION FAILED: .tmp/ should be stripped from template"
        return 1
    }
    # secrets.env should exist but be empty
    if [[ -f "$tmpl_dir/secrets.env" ]]; then
        local size
        size=$(wc -c < "$tmpl_dir/secrets.env")
        [[ "$size" -eq 0 ]] || {
            echo "ASSERTION FAILED: secrets.env should be emptied, not removed"
            return 1
        }
    fi
}
