#!/usr/bin/env bash
# tests/test_readonly_framework.sh — the npm-install publish gate (ADR-0037 D5).
#
# When cco is installed via `npm i -g`, its framework tree lives in a root-owned,
# read-only global node_modules dir. cco MUST run without writing inside that tree:
# every mutable write goes to ~/.cco (CONFIG) or the XDG STATE/CACHE/DATA buckets,
# never under FRAMEWORK_ROOT/REPO_ROOT. These tests stage a read-only copy of the
# shipped framework and assert the internal-session flows (the one historical
# violation — tutorial/config-editor runtime scaffolding) succeed and touch nothing
# inside it. This is the gate the release CI runs before `npm publish`.

# Stage a read-only copy of the shipped framework trees (mirrors the package
# `files` allowlist closely enough for the paths cco resolves at start). Returns
# via stdout the staged root. The caller must restore writability before cleanup.
_stage_readonly_framework() {
    local dest="$1"
    mkdir -p "$dest"
    local d
    for d in bin lib config defaults templates internal migrations proxy docs; do
        [[ -e "$REPO_ROOT/$d" ]] && cp -r "$REPO_ROOT/$d" "$dest/$d"
    done
    cp "$REPO_ROOT/changelog.yml" "$dest/changelog.yml" 2>/dev/null || true
    cp "$REPO_ROOT/Dockerfile"    "$dest/Dockerfile"    2>/dev/null || true
    # Mark the whole tree read-only, as a root-owned npm global dir would be.
    chmod -R a-w "$dest"
}

# Assert that nothing under the read-only tree was written after the marker.
_assert_no_framework_writes() {
    local ro="$1" marker="$2"
    local changed
    changed=$(find "$ro" -newer "$marker" -type f 2>/dev/null)
    [[ -z "$changed" ]] || fail "writes landed inside read-only FRAMEWORK_ROOT:
$changed"
}

# ── tutorial: starts from a read-only framework ───────────────────────

test_readonly_framework_tutorial_start() {
    local tmpdir; tmpdir=$(mktemp -d)
    local ro="$tmpdir/fw"
    _stage_readonly_framework "$ro"
    trap "chmod -R u+w '$ro' 2>/dev/null; rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    local marker="$tmpdir/marker"; touch "$marker"; sleep 1

    # Invoke the READ-ONLY copy's cco so its REPO_ROOT/FRAMEWORK_ROOT resolve to
    # the 0555 tree. The XDG buckets (exported by setup_cco_env) live in $tmpdir.
    bash "$ro/bin/cco" start tutorial --dry-run >/dev/null 2>&1 \
        || fail "cco start tutorial failed from a read-only framework tree"

    _assert_no_framework_writes "$ro" "$marker"
    # The runtime scaffolding must have landed in machine-local STATE instead.
    assert_dir_exists "$CCO_STATE_HOME/internal/tutorial/.claude"
}

# ── config-editor: starts from a read-only framework ──────────────────

test_readonly_framework_config_editor_start() {
    local tmpdir; tmpdir=$(mktemp -d)
    local ro="$tmpdir/fw"
    _stage_readonly_framework "$ro"
    trap "chmod -R u+w '$ro' 2>/dev/null; rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    local marker="$tmpdir/marker"; touch "$marker"; sleep 1

    bash "$ro/bin/cco" start config-editor --dry-run >/dev/null 2>&1 \
        || fail "cco start config-editor failed from a read-only framework tree"

    _assert_no_framework_writes "$ro" "$marker"
    assert_dir_exists "$CCO_STATE_HOME/internal/config-editor/.claude"
}
