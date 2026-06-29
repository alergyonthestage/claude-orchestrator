#!/usr/bin/env bash
# tests/test_pack_publish.sh — cco pack publish tests
#
# Uses bare git repos as mock remotes.

# ── Helpers ─────────────────────────────────────────────────────────

# Create an empty bare remote for publishing
_create_empty_bare_remote() {
    local tmpdir="$1"
    local bare_dir="$tmpdir/publish-remote.git"

    # Create a non-empty bare repo (git won't push to a truly empty one without
    # init). A sharing repo carries NO manifest.yml — seed only a marker file so
    # discovery stays structure-based (ADR-0012/0018 D3).
    local work_dir="$tmpdir/init-work"
    mkdir -p "$work_dir"
    git -C "$work_dir" init -q
    : > "$work_dir/.gitkeep"
    git -C "$work_dir" add -A
    git -C "$work_dir" commit -q -m "init"
    git init --bare -q "$bare_dir"
    git -C "$work_dir" remote add origin "$bare_dir"
    git -C "$work_dir" push -q origin main 2>/dev/null || \
        git -C "$work_dir" push -q origin master 2>/dev/null
    rm -rf "$work_dir"

    echo "$bare_dir"
}

# Create a local pack for publishing
_create_local_pack() {
    local name="$1"
    mkdir -p "$CCO_PACKS_DIR/$name"/{knowledge,agents,rules}
    cat > "$CCO_PACKS_DIR/$name/pack.yml" <<YAML
name: $name
description: "Test pack $name"
knowledge:
  files:
    - path: guide.md
      description: "Guide"
agents:
  - helper.md
YAML
    echo "# Knowledge for $name" > "$CCO_PACKS_DIR/$name/knowledge/guide.md"
    echo "# Agent for $name" > "$CCO_PACKS_DIR/$name/agents/helper.md"
}

# ── Tests ───────────────────────────────────────────────────────────

test_pack_publish_to_remote() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _create_local_pack "my-pack"

    local bare_dir
    bare_dir=$(_create_empty_bare_remote "$tmpdir")

    run_cco remote add target "$bare_dir"
    run_cco pack publish my-pack target
    assert_output_contains "Published"

    # Verify: clone the remote and check
    local verify_dir="$tmpdir/verify"
    git clone -q "$bare_dir" "$verify_dir"
    [[ -f "$verify_dir/packs/my-pack/pack.yml" ]] || {
        echo "ASSERTION FAILED: pack.yml not found in remote"
        return 1
    }
    [[ -f "$verify_dir/packs/my-pack/knowledge/guide.md" ]] || {
        echo "ASSERTION FAILED: knowledge file not in remote"
        return 1
    }
}

test_pack_publish_structure_based_on_remote() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _create_local_pack "my-pack"

    local bare_dir
    bare_dir=$(_create_empty_bare_remote "$tmpdir")

    run_cco remote add target "$bare_dir"
    run_cco pack publish my-pack target

    # The published pack is discovered by structure (packs/<name>/pack.yml) — the
    # sharing repo carries NO manifest.yml (ADR-0012/0018 D3).
    local verify_dir="$tmpdir/verify"
    git clone -q "$bare_dir" "$verify_dir"
    assert_file_exists "$verify_dir/packs/my-pack/pack.yml" || return 1
    assert_file_not_exists "$verify_dir/manifest.yml" || return 1
}

test_pack_publish_records_upstream_url() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _create_local_pack "my-pack"

    local bare_dir
    bare_dir=$(_create_empty_bare_remote "$tmpdir")

    run_cco remote add target "$bare_dir"
    run_cco pack publish my-pack target

    # The published upstream url is recorded in the DATA source (coordinate
    # only) so the default remote is re-derived on the next publish (F4) — no
    # stored publish_target (ADR-0022 D1).
    assert_file_exists "$(data_pack_source my-pack)" || return 1
    assert_file_contains "$(data_pack_source my-pack)" "url: $bare_dir" || return 1
    assert_file_not_contains "$(data_pack_source my-pack)" "publish_target" || return 1
}

test_pack_publish_excludes_cco_source() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _create_local_pack "my-pack"
    mkdir -p "$CCO_PACKS_DIR/my-pack/.cco"
    echo "source: local" > "$CCO_PACKS_DIR/my-pack/.cco/source"

    local bare_dir
    bare_dir=$(_create_empty_bare_remote "$tmpdir")

    run_cco remote add target "$bare_dir"
    run_cco pack publish my-pack target

    local verify_dir="$tmpdir/verify"
    git clone -q "$bare_dir" "$verify_dir"
    [[ ! -f "$verify_dir/packs/my-pack/.cco/source" ]] || {
        echo "ASSERTION FAILED: .cco/source should NOT be in remote"
        return 1
    }
}

test_pack_publish_remembers_target() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _create_local_pack "my-pack"

    local bare_dir
    bare_dir=$(_create_empty_bare_remote "$tmpdir")

    run_cco remote add target "$bare_dir"
    run_cco pack publish my-pack target

    # Second publish without specifying remote — should use remembered target
    echo "# Updated" >> "$CCO_PACKS_DIR/my-pack/knowledge/guide.md"
    run_cco pack publish my-pack --force
    assert_output_contains "Published"
}

test_pack_publish_dry_run() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _create_local_pack "my-pack"

    local bare_dir
    bare_dir=$(_create_empty_bare_remote "$tmpdir")

    run_cco remote add target "$bare_dir"
    run_cco pack publish my-pack target --dry-run
    assert_output_contains "Dry run"
    assert_output_contains "my-pack"

    # Verify: nothing pushed
    local verify_dir="$tmpdir/verify"
    git clone -q "$bare_dir" "$verify_dir"
    [[ ! -d "$verify_dir/packs/my-pack" ]] || {
        echo "ASSERTION FAILED: dry run should not push"
        return 1
    }
}

test_pack_publish_force_overwrites() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _create_local_pack "my-pack"

    local bare_dir
    bare_dir=$(_create_empty_bare_remote "$tmpdir")

    run_cco remote add target "$bare_dir"
    run_cco pack publish my-pack target

    # Modify and publish again with --force
    echo "# V2" > "$CCO_PACKS_DIR/my-pack/knowledge/guide.md"
    run_cco pack publish my-pack target --force
    assert_output_contains "Published"

    # Verify updated content
    local verify_dir="$tmpdir/verify"
    git clone -q "$bare_dir" "$verify_dir"
    grep -q "V2" "$verify_dir/packs/my-pack/knowledge/guide.md" || {
        echo "ASSERTION FAILED: updated content not in remote"
        return 1
    }
}

# ── Sync-before-publish (ADR-0022 D5 / design §6.2) ──────────────────

test_pack_publish_records_state_base() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _create_local_pack "my-pack"

    local bare_dir
    bare_dir=$(_create_empty_bare_remote "$tmpdir")

    run_cco remote add target "$bare_dir"
    run_cco pack publish my-pack target

    # The published tree is recorded as the pack-scoped STATE base/ — the merge
    # ancestor for the next sync-before-publish (ADR-0022 D5).
    assert_file_exists "$(state_pack_base my-pack)/pack.yml" || return 1
    assert_file_exists "$(state_pack_base my-pack)/knowledge/guide.md" || return 1
}

test_pack_publish_preserves_remote_only_changes() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _create_local_pack "my-pack"

    local bare_dir
    bare_dir=$(_create_empty_bare_remote "$tmpdir")

    run_cco remote add target "$bare_dir"
    run_cco pack publish my-pack target            # first publish → base recorded

    # A co-maintainer adds a remote-only file directly on the sharing repo.
    local co="$tmpdir/comaint"
    git clone -q "$bare_dir" "$co"
    echo "# remote only" > "$co/packs/my-pack/knowledge/remote-only.md"
    git -C "$co" add -A
    git -C "$co" commit -q -m "co-maintainer adds a file"
    git -C "$co" push -q origin HEAD

    # We change a DIFFERENT local file and republish (no --force).
    echo "# local v2" > "$CCO_PACKS_DIR/my-pack/agents/helper.md"
    run_cco pack publish my-pack target
    assert_output_contains "Published"

    # The 3-way merge keeps BOTH: the co-maintainer's remote-only file survives
    # (never clobbered, P16) and our change lands.
    local verify="$tmpdir/verify"
    git clone -q "$bare_dir" "$verify"
    assert_file_contains "$verify/packs/my-pack/knowledge/remote-only.md" "remote only" || return 1
    assert_file_contains "$verify/packs/my-pack/agents/helper.md" "local v2" || return 1
}

test_pack_publish_aborts_on_conflict() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _create_local_pack "my-pack"

    local bare_dir
    bare_dir=$(_create_empty_bare_remote "$tmpdir")

    run_cco remote add target "$bare_dir"
    run_cco pack publish my-pack target            # base recorded

    # Co-maintainer changes guide.md on the remote …
    local co="$tmpdir/comaint"
    git clone -q "$bare_dir" "$co"
    echo "# remote change" > "$co/packs/my-pack/knowledge/guide.md"
    git -C "$co" add -A
    git -C "$co" commit -q -m "co-maintainer edits guide"
    git -C "$co" push -q origin HEAD

    # … we change the SAME file differently → real conflict, publish must abort.
    echo "# local change" > "$CCO_PACKS_DIR/my-pack/knowledge/guide.md"
    if run_cco pack publish my-pack target 2>/dev/null; then
        echo "ASSERTION FAILED: publish should abort on conflict"
        return 1
    fi
    assert_output_contains "cco pack update" || return 1

    # The remote still carries the co-maintainer's version (never clobbered).
    local verify="$tmpdir/verify"
    git clone -q "$bare_dir" "$verify"
    assert_file_contains "$verify/packs/my-pack/knowledge/guide.md" "remote change" || return 1
}

test_pack_publish_force_overwrites_conflict() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _create_local_pack "my-pack"

    local bare_dir
    bare_dir=$(_create_empty_bare_remote "$tmpdir")

    run_cco remote add target "$bare_dir"
    run_cco pack publish my-pack target

    local co="$tmpdir/comaint"
    git clone -q "$bare_dir" "$co"
    echo "# remote change" > "$co/packs/my-pack/knowledge/guide.md"
    git -C "$co" add -A
    git -C "$co" commit -q -m "co-maintainer edits guide"
    git -C "$co" push -q origin HEAD

    echo "# local change" > "$CCO_PACKS_DIR/my-pack/knowledge/guide.md"
    # --force is the explicit escape hatch: overwrite the remote with our version.
    run_cco pack publish my-pack target --force
    assert_output_contains "Published"

    local verify="$tmpdir/verify"
    git clone -q "$bare_dir" "$verify"
    assert_file_contains "$verify/packs/my-pack/knowledge/guide.md" "local change" || return 1
}

test_pack_publish_internalizes_source_pack() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Create a source-referencing pack
    local source_dir="$tmpdir/external-docs"
    mkdir -p "$source_dir"
    echo "# External doc" > "$source_dir/external.md"

    mkdir -p "$CCO_PACKS_DIR/src-pack"/{knowledge,agents}
    cat > "$CCO_PACKS_DIR/src-pack/pack.yml" <<YAML
name: src-pack
knowledge:
  source: $source_dir
  files:
    - path: external.md
      description: "External doc"
YAML

    local bare_dir
    bare_dir=$(_create_empty_bare_remote "$tmpdir")

    run_cco remote add target "$bare_dir"
    run_cco pack publish src-pack target

    # Verify: remote has internalized files, no source: field
    local verify_dir="$tmpdir/verify"
    git clone -q "$bare_dir" "$verify_dir"
    [[ -f "$verify_dir/packs/src-pack/knowledge/external.md" ]] || {
        echo "ASSERTION FAILED: internalized file not in remote"
        return 1
    }
    ! grep -q "source:" "$verify_dir/packs/src-pack/pack.yml" || {
        echo "ASSERTION FAILED: source: should be removed from published pack.yml"
        return 1
    }

    # Local pack should still have source: (unchanged)
    grep -q "source:" "$CCO_PACKS_DIR/src-pack/pack.yml" || {
        echo "ASSERTION FAILED: local pack.yml should retain source:"
        return 1
    }
}

test_pack_publish_nonexistent_pack_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco pack publish ghost target 2>/dev/null; then
        echo "ASSERTION FAILED: should fail for nonexistent pack"
        return 1
    fi
}

test_pack_publish_no_remote_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _create_local_pack "my-pack"
    if run_cco pack publish my-pack 2>/dev/null; then
        echo "ASSERTION FAILED: should fail without remote"
        return 1
    fi
}

test_pack_publish_direct_url() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _create_local_pack "my-pack"

    local bare_dir
    bare_dir=$(_create_empty_bare_remote "$tmpdir")

    # Use URL directly instead of registered remote
    run_cco pack publish my-pack "$bare_dir"
    assert_output_contains "Published"
}

test_pack_publish_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco pack publish --help
    assert_output_contains "Publish a pack"
}
