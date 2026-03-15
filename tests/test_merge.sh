#!/usr/bin/env bash
# tests/test_merge.sh — Tests for 3-way merge engine and .cco/base lifecycle

# ── _merge_file unit tests ───────────────────────────────────────────

test_merge_file_clean_merge() {
    # Non-overlapping changes → clean merge
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/update.sh"

    # Base version
    cat > "$tmpdir/base" <<'EOF'
line 1
line 2
line 3
EOF
    # User changed line 1
    cat > "$tmpdir/current" <<'EOF'
line 1 - user edit
line 2
line 3
EOF
    # Framework changed line 3
    cat > "$tmpdir/new" <<'EOF'
line 1
line 2
line 3 - framework update
EOF

    _merge_file "$tmpdir/current" "$tmpdir/base" "$tmpdir/new" "$tmpdir/output"
    local rc=$?
    assert_equals "0" "$rc" "Clean merge should return 0"
    assert_file_contains "$tmpdir/output" "line 1 - user edit"
    assert_file_contains "$tmpdir/output" "line 3 - framework update"
}

test_merge_file_conflict() {
    # Overlapping changes → conflict markers
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/update.sh"

    cat > "$tmpdir/base" <<'EOF'
line 1
shared line
line 3
EOF
    # User changed shared line
    cat > "$tmpdir/current" <<'EOF'
line 1
user version of shared line
line 3
EOF
    # Framework also changed shared line
    cat > "$tmpdir/new" <<'EOF'
line 1
framework version of shared line
line 3
EOF

    _merge_file "$tmpdir/current" "$tmpdir/base" "$tmpdir/new" "$tmpdir/output"
    local rc=$?
    assert_equals "1" "$rc" "Conflicting merge should return 1"
    assert_file_contains "$tmpdir/output" "<<<<<<<" "Should contain conflict markers"
}

test_merge_file_no_git_fallback() {
    # When git is not available, falls back to copying new file
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/update.sh"

    echo "base" > "$tmpdir/base"
    echo "current" > "$tmpdir/current"
    echo "new version" > "$tmpdir/new"

    # Override command -v to simulate missing git
    _merge_file_no_git() {
        local current="$1" base="$2" new="$3" output="$4"
        # Simulate: git not found
        cp "$new" "$output"
        return 2
    }

    _merge_file_no_git "$tmpdir/current" "$tmpdir/base" "$tmpdir/new" "$tmpdir/output"
    local rc=$?
    assert_equals "2" "$rc" "No-git fallback should return 2"
    assert_file_contains "$tmpdir/output" "new version"
}

# ── .cco/base lifecycle ──────────────────────────────────────────────

test_init_creates_cco_base() {
    # cco init should create .cco/base/ with base versions of all managed files
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    assert_dir_exists "$CCO_GLOBAL_DIR/.claude/.cco/base" \
        ".cco/base/ should be created during init"
    # Should have copies of tracked files
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/.cco/base/settings.json" \
        ".cco/base/ should contain settings.json"
}

test_update_refreshes_cco_base() {
    # After cco update, .cco/base/ should reflect the latest defaults
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Modify a tracked default file
    printf '\n# New framework line\n' >> "$REPO_ROOT/defaults/global/.claude/rules/workflow.md"

    run_cco update
    # .cco/base should be updated to match the new default
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/.cco/base/rules/workflow.md" "New framework line"

    # Restore
    cd "$REPO_ROOT" && git checkout -- defaults/global/.claude/rules/workflow.md
}

# ── 3-way merge integration ─────────────────────────────────────────

test_update_automerge_non_overlapping() {
    # When user and framework change different parts, auto-merge applies
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # User adds content at the END of a tracked file
    printf '\n# My custom addition\n' >> "$CCO_GLOBAL_DIR/.claude/rules/workflow.md"

    # Framework adds content at the BEGINNING of the same file
    local default_file="$REPO_ROOT/defaults/global/.claude/rules/workflow.md"
    local original
    original=$(cat "$default_file")
    printf '# Framework header\n\n%s' "$original" > "$default_file"

    run_cco update
    # Both changes should be present (auto-merged)
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" "My custom addition"
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" "Framework header"
    assert_output_contains "auto-merged"

    # Restore
    cd "$REPO_ROOT" && git checkout -- defaults/global/.claude/rules/workflow.md
}

# ── --no-backup flag ─────────────────────────────────────────────────

test_update_no_backup_skips_bak() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create conflict
    printf '\n# My custom rule\n' >> "$CCO_GLOBAL_DIR/.claude/rules/workflow.md"
    printf '\n# Framework update\n' >> "$REPO_ROOT/defaults/global/.claude/rules/workflow.md"

    run_cco update --force --no-backup
    # No .bak should be created
    assert_file_not_exists "$CCO_GLOBAL_DIR/.claude/rules/workflow.md.bak"
    # Framework update should be applied
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" "Framework update"

    # Restore
    cd "$REPO_ROOT" && git checkout -- defaults/global/.claude/rules/workflow.md
}
