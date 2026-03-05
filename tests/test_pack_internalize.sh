#!/usr/bin/env bash
# tests/test_pack_internalize.sh — cco pack internalize tests

_setup_source_pack() {
    local tmpdir="$1" pack_name="$2" source_dir="$3"

    # Create external source directory with files
    mkdir -p "$source_dir"
    echo "# Guide" > "$source_dir/guide.md"
    echo "# API" > "$source_dir/api.md"

    # Create pack with source reference
    mkdir -p "$CCO_PACKS_DIR/$pack_name"/{knowledge,agents,rules}
    cat > "$CCO_PACKS_DIR/$pack_name/pack.yml" <<YAML
name: $pack_name
description: "Test pack"
knowledge:
  source: $source_dir
  files:
    - path: guide.md
      description: "Guide doc"
    - path: api.md
      description: "API doc"
YAML
}

test_pack_internalize_copies_files() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _setup_source_pack "$tmpdir" "my-pack" "$tmpdir/docs"
    run_cco pack internalize my-pack
    assert_file_exists "$CCO_PACKS_DIR/my-pack/knowledge/guide.md"
    assert_file_exists "$CCO_PACKS_DIR/my-pack/knowledge/api.md"
}

test_pack_internalize_removes_source_field() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _setup_source_pack "$tmpdir" "my-pack" "$tmpdir/docs"
    run_cco pack internalize my-pack
    assert_file_not_contains "$CCO_PACKS_DIR/my-pack/pack.yml" "source:"
}

test_pack_internalize_preserves_files_section() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _setup_source_pack "$tmpdir" "my-pack" "$tmpdir/docs"
    run_cco pack internalize my-pack
    assert_file_contains "$CCO_PACKS_DIR/my-pack/pack.yml" "files:"
    assert_file_contains "$CCO_PACKS_DIR/my-pack/pack.yml" "guide.md"
}

test_pack_internalize_reports_count() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _setup_source_pack "$tmpdir" "my-pack" "$tmpdir/docs"
    run_cco pack internalize my-pack
    assert_output_contains "2 file(s)"
}

test_pack_internalize_already_self_contained() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Pack without source: field
    mkdir -p "$CCO_PACKS_DIR/local-pack/knowledge"
    cat > "$CCO_PACKS_DIR/local-pack/pack.yml" <<YAML
name: local-pack
description: "Already local"
knowledge:
  files:
    - path: readme.md
YAML
    echo "# Readme" > "$CCO_PACKS_DIR/local-pack/knowledge/readme.md"

    run_cco pack internalize local-pack
    assert_output_contains "already self-contained"
}

test_pack_internalize_nonexistent_pack_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco pack internalize ghost 2>/dev/null; then
        echo "ASSERTION FAILED: should fail for nonexistent pack"
        return 1
    fi
}

test_pack_internalize_missing_source_dir_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    mkdir -p "$CCO_PACKS_DIR/bad-pack"
    cat > "$CCO_PACKS_DIR/bad-pack/pack.yml" <<YAML
name: bad-pack
knowledge:
  source: /nonexistent/path
  files:
    - path: doc.md
YAML

    if run_cco pack internalize bad-pack 2>/dev/null; then
        echo "ASSERTION FAILED: should fail for missing source dir"
        return 1
    fi
}

test_pack_internalize_warns_missing_file() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    local source_dir="$tmpdir/docs"
    mkdir -p "$source_dir"
    echo "# Exists" > "$source_dir/exists.md"

    mkdir -p "$CCO_PACKS_DIR/partial-pack/knowledge"
    cat > "$CCO_PACKS_DIR/partial-pack/pack.yml" <<YAML
name: partial-pack
knowledge:
  source: $source_dir
  files:
    - path: exists.md
    - path: missing.md
YAML

    run_cco pack internalize partial-pack
    assert_file_exists "$CCO_PACKS_DIR/partial-pack/knowledge/exists.md"
    assert_output_contains "1 file(s)"
}

test_pack_internalize_subdirectory_files() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    local source_dir="$tmpdir/docs"
    mkdir -p "$source_dir/guides"
    echo "# Nested" > "$source_dir/guides/setup.md"

    mkdir -p "$CCO_PACKS_DIR/nested-pack"
    cat > "$CCO_PACKS_DIR/nested-pack/pack.yml" <<YAML
name: nested-pack
knowledge:
  source: $source_dir
  files:
    - path: guides/setup.md
      description: "Setup guide"
YAML

    run_cco pack internalize nested-pack
    assert_file_exists "$CCO_PACKS_DIR/nested-pack/knowledge/guides/setup.md"
    assert_output_contains "1 file(s)"
}

test_pack_internalize_idempotent() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _setup_source_pack "$tmpdir" "my-pack" "$tmpdir/docs"
    run_cco pack internalize my-pack
    # Second run should be no-op (source: removed)
    run_cco pack internalize my-pack
    assert_output_contains "already self-contained"
}

test_pack_internalize_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco pack internalize --help
    assert_output_contains "self-contained"
}
