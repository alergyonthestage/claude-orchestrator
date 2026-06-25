#!/usr/bin/env bash
# tests/test_merge.sh — Tests for 3-way merge engine and .cco/base lifecycle

# ── _merge_file unit tests ───────────────────────────────────────────

test_merge_file_clean_merge() {
    # Non-overlapping changes → clean merge
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/update-hash-io.sh"
    source "$REPO_ROOT/lib/update-merge.sh"
    source "$REPO_ROOT/lib/update-meta.sh"
    source "$REPO_ROOT/lib/update-discovery.sh"
    source "$REPO_ROOT/lib/update-sync.sh"
    source "$REPO_ROOT/lib/update-changelog.sh"
    source "$REPO_ROOT/lib/update-remote.sh"
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
    source "$REPO_ROOT/lib/update-hash-io.sh"
    source "$REPO_ROOT/lib/update-merge.sh"
    source "$REPO_ROOT/lib/update-meta.sh"
    source "$REPO_ROOT/lib/update-discovery.sh"
    source "$REPO_ROOT/lib/update-sync.sh"
    source "$REPO_ROOT/lib/update-changelog.sh"
    source "$REPO_ROOT/lib/update-remote.sh"
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
    source "$REPO_ROOT/lib/update-hash-io.sh"
    source "$REPO_ROOT/lib/update-merge.sh"
    source "$REPO_ROOT/lib/update-meta.sh"
    source "$REPO_ROOT/lib/update-discovery.sh"
    source "$REPO_ROOT/lib/update-sync.sh"
    source "$REPO_ROOT/lib/update-changelog.sh"
    source "$REPO_ROOT/lib/update-remote.sh"
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
    init_global "$tmpdir" --lang "English"

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
    init_global "$tmpdir" --lang "English"

    # Modify a default file in the framework sandbox (tracked tree untouched)
    sandbox_framework
    printf '\n# New framework line\n' >> "$CCO_FRAMEWORK_ROOT/defaults/global/.claude/rules/workflow.md"

    # Applying (here: --keep, non-interactive) refreshes the base; plain
    # `cco update` only DISCOVERS (opinionated split). Base lives in STATE (H6).
    run_cco update --keep
    assert_file_contains "$(state_global_base)/rules/workflow.md" "New framework line"
}

# ── 3-way merge integration ─────────────────────────────────────────

test_update_automerge_non_overlapping() {
    # When user and framework change different parts, the 3-way merge that
    # `cco update --sync` runs (`_resolve_with_merge`) auto-applies both. Driven
    # directly here: end-to-end `cco update` auto-merge needs a TTY (non-TTY
    # --sync skips by design), so we exercise the exact function it calls. The
    # base lives in STATE now (H6) but is passed in as an argument — relocation
    # is transparent to the merge engine.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/update-hash-io.sh"
    source "$REPO_ROOT/lib/update-merge.sh"

    mkdir -p "$tmpdir/base/rules" "$tmpdir/installed/rules" "$tmpdir/defaults/rules"
    printf 'line A\nline B\nline C\n' > "$tmpdir/base/rules/workflow.md"
    # User adds at the END
    printf 'line A\nline B\nline C\n# My custom addition\n' > "$tmpdir/installed/rules/workflow.md"
    # Framework adds at the BEGINNING
    printf '# Framework header\nline A\nline B\nline C\n' > "$tmpdir/defaults/rules/workflow.md"

    local out
    out=$(_resolve_with_merge "rules/workflow.md" "$tmpdir/defaults" "$tmpdir/installed" "$tmpdir/base" "true" "" 2>&1)
    assert_file_contains "$tmpdir/installed/rules/workflow.md" "My custom addition"
    assert_file_contains "$tmpdir/installed/rules/workflow.md" "Framework header"
    printf '%s\n' "$out" | grep -q "auto-merged" || fail "expected auto-merged output, got: $out"
}

# ── --no-backup flag ─────────────────────────────────────────────────

test_update_no_backup_skips_bak() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"

    # Create conflict — user edit hits the sandbox installed tree ($tmpdir);
    # the framework change hits the framework sandbox (no tracked-file mutation).
    printf '\n# My custom rule\n' >> "$CCO_GLOBAL_DIR/.claude/rules/workflow.md"
    sandbox_framework
    printf '\n# Framework update\n' >> "$CCO_FRAMEWORK_ROOT/defaults/global/.claude/rules/workflow.md"

    run_cco update --force --no-backup
    # No .bak should be created
    assert_file_not_exists "$CCO_GLOBAL_DIR/.claude/rules/workflow.md.bak"
    # Framework update should be applied
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/rules/workflow.md" "Framework update"
}
