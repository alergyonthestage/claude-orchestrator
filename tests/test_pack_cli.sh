#!/usr/bin/env bash
# tests/test_pack_cli.sh — cco pack CLI command tests
#
# Verifies pack create, list, show, remove, and validate commands.

# ── create ────────────────────────────────────────────────────────────

test_pack_create_makes_directory() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco pack create "my-pack"
    assert_dir_exists "$CCO_PACKS_DIR/my-pack"
}

test_pack_create_makes_pack_yml() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco pack create "my-pack"
    assert_file_exists "$CCO_PACKS_DIR/my-pack/pack.yml"
    assert_file_contains "$CCO_PACKS_DIR/my-pack/pack.yml" "name: my-pack"
}

test_pack_create_makes_subdirectories() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco pack create "my-pack"
    assert_dir_exists "$CCO_PACKS_DIR/my-pack/knowledge"
    assert_dir_exists "$CCO_PACKS_DIR/my-pack/skills"
    assert_dir_exists "$CCO_PACKS_DIR/my-pack/agents"
    assert_dir_exists "$CCO_PACKS_DIR/my-pack/rules"
}

test_pack_create_rejects_uppercase() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco pack create "MyPack" 2>/dev/null; then
        echo "ASSERTION FAILED: should have rejected uppercase pack name"
        return 1
    fi
}

test_pack_create_rejects_uppercase_error_message() {
    # Error message should mention lowercase naming requirement
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco pack create "MyPack" || true
    assert_output_contains "lowercase"
}

test_pack_create_rejects_leading_hyphen() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco pack create "-bad-name" 2>/dev/null; then
        echo "ASSERTION FAILED: should have rejected name starting with hyphen"
        return 1
    fi
}

test_pack_create_fails_if_exists() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco pack create "my-pack"
    if run_cco pack create "my-pack" 2>/dev/null; then
        echo "ASSERTION FAILED: second create should have failed"
        return 1
    fi
}

test_pack_create_duplicate_error_message() {
    # Error message should mention pack already exists
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco pack create "my-pack"
    run_cco pack create "my-pack" || true
    assert_output_contains "already exists"
}

# ── list ──────────────────────────────────────────────────────────────

test_pack_list_shows_header() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco pack list
    assert_output_contains "NAME"
}

test_pack_list_shows_pack_names() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco pack create "alpha-pack"
    run_cco pack list
    assert_output_contains "alpha-pack"
}

test_pack_list_shows_resource_counts() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    # Create a pack with resources
    local pack_dir="$CCO_PACKS_DIR/counted-pack"
    mkdir -p "$pack_dir/agents" "$pack_dir/rules"
    echo "Agent" > "$pack_dir/agents/bot.md"
    echo "Rule" > "$pack_dir/rules/style.md"
    printf 'name: counted-pack\nagents:\n  - bot.md\nrules:\n  - style.md\n' > "$pack_dir/pack.yml"
    run_cco pack list
    assert_output_contains "counted-pack"
}

test_pack_list_header_only_when_empty() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    # Remove default packs dir content
    rm -rf "$CCO_PACKS_DIR"
    mkdir -p "$CCO_PACKS_DIR"
    run_cco pack list
    assert_output_contains "NAME"
    # Output should only be the header line
    local line_count
    line_count=$(echo "$CCO_OUTPUT" | wc -l | tr -d ' ')
    if [[ "$line_count" -gt 1 ]]; then
        echo "ASSERTION FAILED: expected only header line, got $line_count lines"
        echo "$CCO_OUTPUT"
        return 1
    fi
}

# ── show ──────────────────────────────────────────────────────────────

test_pack_show_displays_pack_info() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local pack_src="$tmpdir/pack-src"
    mkdir -p "$pack_src"
    create_pack "$tmpdir" "info-pack" "$(cat <<YAML
name: info-pack
knowledge:
  source: $pack_src
  files:
    - guide.md
YAML
)"
    run_cco pack show "info-pack"
    assert_output_contains "info-pack"
}

test_pack_show_lists_knowledge_files() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local pack_src="$tmpdir/pack-src"
    mkdir -p "$pack_src"
    create_pack "$tmpdir" "k-pack" "$(cat <<YAML
name: k-pack
knowledge:
  source: $pack_src
  files:
    - overview.md
    - guide.md
YAML
)"
    run_cco pack show "k-pack"
    assert_output_contains "overview.md"
    assert_output_contains "guide.md"
}

test_pack_show_lists_agents_and_rules() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local pack_dir="$CCO_PACKS_DIR/ar-pack"
    mkdir -p "$pack_dir/agents" "$pack_dir/rules"
    echo "Agent" > "$pack_dir/agents/bot.md"
    echo "Rule" > "$pack_dir/rules/style.md"
    printf 'name: ar-pack\nagents:\n  - bot.md\nrules:\n  - style.md\n' > "$pack_dir/pack.yml"
    run_cco pack show "ar-pack"
    assert_output_contains "bot.md"
    assert_output_contains "style.md"
}

test_pack_show_used_by_projects() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_pack "$tmpdir" "shared-pack" "$(cat <<YAML
name: shared-pack
YAML
)"
    create_project "$tmpdir" "proj-a" "$(cat <<YAML
name: proj-a
packs:
  - shared-pack
repos: []
YAML
)"
    run_cco pack show "shared-pack"
    assert_output_contains "proj-a"
}

test_pack_show_none_when_no_projects() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_pack "$tmpdir" "lonely-pack" "$(cat <<YAML
name: lonely-pack
YAML
)"
    run_cco pack show "lonely-pack"
    assert_output_contains "(none)"
}

test_pack_show_fails_if_not_found() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco pack show "nonexistent" 2>/dev/null; then
        echo "ASSERTION FAILED: should have failed for missing pack"
        return 1
    fi
}

# ── remove ────────────────────────────────────────────────────────────

test_pack_remove_deletes_directory() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco pack create "doomed-pack"
    assert_dir_exists "$CCO_PACKS_DIR/doomed-pack"
    run_cco pack remove "doomed-pack"
    if [[ -d "$CCO_PACKS_DIR/doomed-pack" ]]; then
        echo "ASSERTION FAILED: pack directory should have been removed"
        return 1
    fi
}

test_pack_remove_fails_if_not_found() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco pack remove "nonexistent" 2>/dev/null; then
        echo "ASSERTION FAILED: should have failed for missing pack"
        return 1
    fi
}

test_pack_remove_persists_when_used_without_tty() {
    # Without tty and without --force, pack used by a project must NOT be removed
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_pack "$tmpdir" "used-pack" "$(cat <<YAML
name: used-pack
YAML
)"
    create_project "$tmpdir" "my-proj" "$(cat <<YAML
name: my-proj
packs:
  - used-pack
repos: []
YAML
)"
    # Without tty (stdin from /dev/null), should fail
    run_cco pack remove "used-pack" </dev/null || true
    assert_dir_exists "$CCO_PACKS_DIR/used-pack"
}

test_pack_remove_force_removes_despite_usage() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_pack "$tmpdir" "forced-pack" "$(cat <<YAML
name: forced-pack
YAML
)"
    create_project "$tmpdir" "my-proj" "$(cat <<YAML
name: my-proj
packs:
  - forced-pack
repos: []
YAML
)"
    run_cco pack remove "forced-pack" --force
    if [[ -d "$CCO_PACKS_DIR/forced-pack" ]]; then
        echo "ASSERTION FAILED: pack should have been removed with --force"
        return 1
    fi
}

# ── validate ──────────────────────────────────────────────────────────

test_pack_validate_ok_for_valid_pack() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local pack_dir="$CCO_PACKS_DIR/valid-pack"
    mkdir -p "$pack_dir/agents"
    echo "Agent" > "$pack_dir/agents/bot.md"
    printf 'name: valid-pack\nagents:\n  - bot.md\n' > "$pack_dir/pack.yml"
    run_cco pack validate "valid-pack"
    assert_output_contains "valid"
}

test_pack_validate_error_without_pack_yml() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    mkdir -p "$CCO_PACKS_DIR/no-yml"
    if run_cco pack validate "no-yml" 2>/dev/null; then
        echo "ASSERTION FAILED: should fail without pack.yml"
        return 1
    fi
}

test_pack_validate_error_for_bad_indentation() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local pack_dir="$CCO_PACKS_DIR/bad-indent"
    mkdir -p "$pack_dir"
    cat > "$pack_dir/pack.yml" <<'YAML'
  name: bad-indent
  rules:
    - style.md
YAML
    if run_cco pack validate "bad-indent" 2>/dev/null; then
        echo "ASSERTION FAILED: should fail for bad indentation"
        return 1
    fi
}

test_pack_validate_error_for_missing_referenced_file() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local pack_dir="$CCO_PACKS_DIR/missing-ref"
    mkdir -p "$pack_dir/agents"
    printf 'name: missing-ref\nagents:\n  - nonexistent.md\n' > "$pack_dir/pack.yml"
    if run_cco pack validate "missing-ref" 2>/dev/null; then
        echo "ASSERTION FAILED: should fail for missing referenced file"
        return 1
    fi
}

test_pack_validate_all_without_argument() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    # Create two valid packs
    local pack_a="$CCO_PACKS_DIR/pack-a"
    local pack_b="$CCO_PACKS_DIR/pack-b"
    mkdir -p "$pack_a" "$pack_b"
    printf 'name: pack-a\n' > "$pack_a/pack.yml"
    printf 'name: pack-b\n' > "$pack_b/pack.yml"
    run_cco pack validate
    assert_output_contains "pack-a"
    assert_output_contains "pack-b"
}

test_pack_validate_warns_name_mismatch() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local pack_dir="$CCO_PACKS_DIR/actual-name"
    mkdir -p "$pack_dir"
    printf 'name: wrong-name\n' > "$pack_dir/pack.yml"
    run_cco pack validate "actual-name"
    assert_output_contains "does not match"
}
