#!/usr/bin/env bash
# tests/test_llms.sh — tests for llms.txt feature (lib/llms.sh + lib/cmd-llms.sh)
#
# Tests cover: name resolution, primary file resolution, name collection,
# mount generation, packs.md generation, validation, YAML appending,
# project validation integration, and name sanitization.

# Source llms modules for direct unit tests (run_cco tests don't need this)
source "$REPO_ROOT/lib/colors.sh"
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/paths.sh"
source "$REPO_ROOT/lib/yaml.sh"
source "$REPO_ROOT/lib/llms.sh"
source "$REPO_ROOT/lib/cmd-llms.sh"

# ── Helpers ─────────────────────────────────────────────────────────

# Set globals used by lib/llms.sh from CCO_ env vars (for direct unit tests).
_setup_llms_env() {
    local tmpdir="$1"
    setup_cco_env "$tmpdir"
    LLMS_DIR="$CCO_LLMS_DIR"
    PACKS_DIR="$CCO_PACKS_DIR"
    PROJECTS_DIR="$CCO_PROJECTS_DIR"
}

# Usage: create_llms_entry <tmpdir> <name> [variant_files...]
# Creates $LLMS_DIR/<name>/ with given files and a .cco/source metadata.
# variant_files default to "llms-full.txt" if none specified.
create_llms_entry() {
    local tmpdir="$1" name="$2"; shift 2
    local dir="$CCO_LLMS_DIR/$name"
    mkdir -p "$dir/.cco"
    if [[ $# -eq 0 ]]; then
        printf '# %s Documentation\nLine 2\nLine 3\n' "$name" > "$dir/llms-full.txt"
    else
        for f in "$@"; do
            printf '# %s Documentation\nLine 2\nLine 3\n' "$name" > "$dir/$f"
        done
    fi
    cat > "$dir/.cco/source" <<YAML
url: "https://example.com/$name/llms.txt"
variant: full
downloaded: "2026-03-20T10:00:00Z"
resolved_url: "https://example.com/$name/llms-full.txt"
etag: ""
YAML
}

# ── _llms_resolve_name_from_url ──────────────────────────────────────

test_resolve_name_from_path_url() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    local result
    result=$(_llms_resolve_name_from_url "https://svelte.dev/docs/svelte/llms.txt")
    assert_equals "svelte" "$result" "Should extract last path segment before llms filename"
}

test_resolve_name_from_domain_url() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    local result
    result=$(_llms_resolve_name_from_url "https://shadcn-svelte.com/llms.txt")
    assert_equals "shadcn-svelte" "$result" "Should extract domain name without TLD"
}

test_resolve_name_from_full_variant_url() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    local result
    result=$(_llms_resolve_name_from_url "https://example.com/docs/react/llms-full.txt")
    assert_equals "react" "$result" "Should handle llms-full.txt variant in URL"
}

# ── _llms_base_url ───────────────────────────────────────────────────

test_base_url_strips_filename() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    local result
    result=$(_llms_base_url "https://svelte.dev/docs/svelte/llms.txt")
    assert_equals "https://svelte.dev/docs/svelte" "$result"
}

test_base_url_strips_variant_filename() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    local result
    result=$(_llms_base_url "https://example.com/llms-full.txt")
    assert_equals "https://example.com" "$result"
}

# ── _llms_resolve_primary_file ───────────────────────────────────────

test_resolve_primary_prefers_full() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    create_llms_entry "$tmpdir" "test-fw" "llms-full.txt" "llms-medium.txt" "llms.txt"
    local result
    result=$(_llms_resolve_primary_file "$CCO_LLMS_DIR/test-fw" "")
    assert_equals "llms-full.txt" "$result" "Should prefer full variant"
}

test_resolve_primary_falls_to_medium() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    create_llms_entry "$tmpdir" "test-fw" "llms-medium.txt" "llms.txt"
    local result
    result=$(_llms_resolve_primary_file "$CCO_LLMS_DIR/test-fw" "")
    assert_equals "llms-medium.txt" "$result" "Should fall back to medium"
}

test_resolve_primary_falls_to_index() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    create_llms_entry "$tmpdir" "test-fw" "llms.txt"
    local result
    result=$(_llms_resolve_primary_file "$CCO_LLMS_DIR/test-fw" "")
    assert_equals "llms.txt" "$result" "Should fall back to index"
}

test_resolve_primary_explicit_variant() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    create_llms_entry "$tmpdir" "test-fw" "llms-full.txt" "llms-small.txt"
    local result
    result=$(_llms_resolve_primary_file "$CCO_LLMS_DIR/test-fw" "small")
    assert_equals "llms-small.txt" "$result" "Should use explicit variant"
}

test_resolve_primary_no_files_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    mkdir -p "$CCO_LLMS_DIR/empty-fw"
    _llms_resolve_primary_file "$CCO_LLMS_DIR/empty-fw" "" > /dev/null 2>&1 && \
        fail "Should return non-zero when no files found" || true
}

# ── _collect_llms_names ──────────────────────────────────────────────

test_collect_from_project_only() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    local proj_yml="$tmpdir/project.yml"
    printf 'name: test\nllms:\n  - svelte\n  - react\n' > "$proj_yml"
    local result
    result=$(_collect_llms_names "$proj_yml" "")
    [[ $(echo "$result" | wc -l | tr -d ' ') -eq 2 ]] || \
        fail "Expected 2 entries, got: $result"
    echo "$result" | grep -q "^svelte" || fail "Missing svelte entry"
    echo "$result" | grep -q "^react" || fail "Missing react entry"
}

test_collect_project_overrides_pack() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    create_pack "$tmpdir" "my-pack" "$(printf 'name: my-pack\nllms:\n  - name: svelte\n    description: Pack desc\n')"
    local proj_yml="$tmpdir/project.yml"
    printf 'name: test\nllms:\n  - name: svelte\n    description: Project desc\n' > "$proj_yml"
    local result
    result=$(_collect_llms_names "$proj_yml" "my-pack")
    [[ $(echo "$result" | wc -l | tr -d ' ') -eq 1 ]] || \
        fail "Expected 1 deduplicated entry, got: $result"
    echo "$result" | grep -q "Project desc" || fail "Project description should override pack"
}

test_collect_pack_entries_when_no_project_llms() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    create_pack "$tmpdir" "my-pack" "$(printf 'name: my-pack\nllms:\n  - svelte\n')"
    local proj_yml="$tmpdir/project.yml"
    printf 'name: test\n' > "$proj_yml"
    local result
    result=$(_collect_llms_names "$proj_yml" "my-pack")
    echo "$result" | grep -q "^svelte" || fail "Should include pack-level entry"
}

# ── _generate_llms_mounts ───────────────────────────────────────────

test_generate_mounts_with_valid_entry() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    create_llms_entry "$tmpdir" "svelte"
    local proj_yml="$tmpdir/project.yml"
    printf 'name: test\nllms:\n  - svelte\n' > "$proj_yml"
    local result
    result=$(_generate_llms_mounts "$proj_yml" "")
    echo "$result" | grep -q ":ro" || fail "Should contain :ro mount"
    echo "$result" | grep -q "/workspace/.claude/llms/svelte" || fail "Should mount to correct path"
}

test_generate_mounts_missing_dir_warns() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    local proj_yml="$tmpdir/project.yml"
    printf 'name: test\nllms:\n  - nonexistent\n' > "$proj_yml"
    local result
    result=$(_generate_llms_mounts "$proj_yml" "" 2>&1)
    echo "$result" | grep -q "not found" || fail "Should warn about missing directory"
}

test_generate_mounts_empty_when_no_llms() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    local proj_yml="$tmpdir/project.yml"
    printf 'name: test\n' > "$proj_yml"
    local result
    result=$(_generate_llms_mounts "$proj_yml" "")
    assert_empty "$result" "Should return empty when no llms configured"
}

# ── _generate_llms_packs_md ─────────────────────────────────────────

test_packs_md_includes_header_and_entry() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    create_llms_entry "$tmpdir" "svelte" "llms-full.txt"
    local proj_yml="$tmpdir/project.yml"
    printf 'name: test\nllms:\n  - svelte\n' > "$proj_yml"
    local result
    result=$(_generate_llms_packs_md "$proj_yml" "")
    echo "$result" | grep -q "Official Framework Documentation" || fail "Should include section header"
    echo "$result" | grep -q "/workspace/.claude/llms/svelte" || fail "Should include file path"
}

test_packs_md_empty_when_dirs_missing() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    local proj_yml="$tmpdir/project.yml"
    printf 'name: test\nllms:\n  - nonexistent\n' > "$proj_yml"
    local result
    result=$(_generate_llms_packs_md "$proj_yml" "")
    assert_empty "$result" "Should return empty when all dirs missing (no orphaned header)"
}

test_packs_md_count_via_grep() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    create_llms_entry "$tmpdir" "svelte" "llms-full.txt"
    create_llms_entry "$tmpdir" "react" "llms-full.txt"
    local proj_yml="$tmpdir/project.yml"
    printf 'name: test\nllms:\n  - svelte\n  - react\n' > "$proj_yml"
    local result
    result=$(_generate_llms_packs_md "$proj_yml" "")
    local count
    count=$(echo "$result" | grep -c '^- ' || echo 0)
    assert_equals "2" "$count" "Should have 2 entry lines"
}

test_packs_md_index_type_hint() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    create_llms_entry "$tmpdir" "svelte" "llms.txt"
    local proj_yml="$tmpdir/project.yml"
    printf 'name: test\nllms:\n  - svelte\n' > "$proj_yml"
    local result
    result=$(_generate_llms_packs_md "$proj_yml" "")
    echo "$result" | grep -q "WebFetch" || fail "Index files should have WebFetch type hint"
}

# ── _validate_llms_refs ──────────────────────────────────────────────

test_validate_refs_all_present() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    create_llms_entry "$tmpdir" "svelte"
    local yml="$tmpdir/test.yml"
    printf 'llms:\n  - svelte\n' > "$yml"
    _validate_llms_refs "$yml" "Test" || fail "Should pass when all refs present"
}

test_validate_refs_missing_entry() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    local yml="$tmpdir/test.yml"
    printf 'llms:\n  - nonexistent\n' > "$yml"
    local result
    result=$(_validate_llms_refs "$yml" "Test" 2>&1) && \
        fail "Should fail when ref is missing" || true
}

test_validate_refs_empty_dir() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    mkdir -p "$CCO_LLMS_DIR/empty-fw"
    local yml="$tmpdir/test.yml"
    printf 'llms:\n  - empty-fw\n' > "$yml"
    local result
    result=$(_validate_llms_refs "$yml" "Test" 2>&1) && \
        fail "Should fail when dir has no llms files" || true
}

test_validate_refs_no_llms_key_passes() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    local yml="$tmpdir/test.yml"
    printf 'name: test\npacks:\n  - foo\n' > "$yml"
    _validate_llms_refs "$yml" "Test" || fail "Should pass when no llms key"
}

# ── _llms_append_to_yaml_list ────────────────────────────────────────

test_append_to_existing_key() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    local file="$tmpdir/test.yml"
    printf 'name: test\nllms:\n  - existing\n' > "$file"
    _llms_append_to_yaml_list "$file" "llms" "new-entry"
    assert_file_contains "$file" "- new-entry"
    assert_file_contains "$file" "- existing"
}

test_append_creates_new_key() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_llms_env "$tmpdir"
    local file="$tmpdir/test.yml"
    printf 'name: test\n' > "$file"
    _llms_append_to_yaml_list "$file" "llms" "svelte"
    assert_file_contains "$file" "llms:"
    assert_file_contains "$file" "- svelte"
}

# ── Name validation (security) ───────────────────────────────────────

test_install_rejects_path_traversal_name() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local result exit_code=0
    result=$(run_cco llms install "https://example.com/llms.txt" --name "../../../tmp/evil" 2>&1) || exit_code=$?
    [[ $exit_code -ne 0 ]] || echo "$CCO_OUTPUT" | grep -qi "invalid" || \
        fail "Should reject path traversal name"
}

test_install_rejects_slash_in_name() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local exit_code=0
    run_cco llms install "https://example.com/llms.txt" --name "foo/bar" || exit_code=$?
    [[ $exit_code -ne 0 ]] || fail "Should reject name with slash"
}

test_install_accepts_valid_name() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local exit_code=0
    run_cco llms install "https://example.com/llms.txt" --name "valid-name_1" || exit_code=$?
    echo "$CCO_OUTPUT" | grep -qi "invalid" && \
        fail "Should accept valid name (error should be network-related, not name validation)" || true
}

# ── Project validate includes llms ───────────────────────────────────

test_project_validate_catches_missing_llms() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(printf 'name: test-proj\nllms:\n  - nonexistent\nrepos:\n  - path: %s\n    name: dummy\n' "$CCO_DUMMY_REPO")"
    git -C "$CCO_DUMMY_REPO" init -q 2>/dev/null || true
    local exit_code=0
    run_cco project validate "test-proj" || exit_code=$?
    [[ $exit_code -ne 0 ]] || fail "Project validate should catch missing llms refs"
}

test_project_validate_passes_with_valid_llms() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_llms_entry "$tmpdir" "svelte"
    create_project "$tmpdir" "test-proj" "$(printf 'name: test-proj\nllms:\n  - svelte\nrepos:\n  - path: %s\n    name: dummy\n' "$CCO_DUMMY_REPO")"
    git -C "$CCO_DUMMY_REPO" init -q 2>/dev/null || true
    run_cco project validate "test-proj" || fail "Project validate should pass with valid llms"
}

# ── Start dry-run with llms ──────────────────────────────────────────

test_dry_run_includes_llms_mounts() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_llms_entry "$tmpdir" "svelte"
    create_project "$tmpdir" "test-proj" "$(printf 'name: test-proj\nllms:\n  - svelte\nrepos:\n  - path: %s\n    name: dummy\n' "$CCO_DUMMY_REPO")"
    git -C "$CCO_DUMMY_REPO" init -q 2>/dev/null || true
    run_cco start "test-proj" --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_exists "$compose"
    assert_file_contains "$compose" "/workspace/.claude/llms/svelte:ro"
}

test_dry_run_includes_llms_in_packs_md() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_llms_entry "$tmpdir" "svelte" "llms-full.txt"
    create_project "$tmpdir" "test-proj" "$(printf 'name: test-proj\nllms:\n  - svelte\nrepos:\n  - path: %s\n    name: dummy\n' "$CCO_DUMMY_REPO")"
    git -C "$CCO_DUMMY_REPO" init -q 2>/dev/null || true
    run_cco start "test-proj" --dry-run --dump
    local packs_md="$DRY_RUN_DIR/.claude/packs.md"
    assert_file_exists "$packs_md"
    assert_file_contains "$packs_md" "Official Framework Documentation"
    assert_file_contains "$packs_md" "/workspace/.claude/llms/svelte"
}
