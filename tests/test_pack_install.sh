#!/usr/bin/env bash
# tests/test_pack_install.sh — cco pack install/update/export tests
#
# Uses bare git repos as mock remotes.

# ── Helper: create a mock Config Repo ─────────────────────────────────

# Create a bare git repo with packs and manifest.yml.
# Usage: _create_mock_config_repo <tmpdir> <packs...>
# Outputs: path to the bare repo (use as URL for cco pack install)
_create_mock_config_repo() {
    local tmpdir="$1"; shift
    local pack_names=("$@")
    local work_dir="$tmpdir/mock-work"
    local bare_dir="$tmpdir/mock-remote.git"

    # Create working copy
    mkdir -p "$work_dir/packs"

    # Create packs
    local manifest_packs=""
    for name in "${pack_names[@]}"; do
        mkdir -p "$work_dir/packs/$name"/{knowledge,agents,rules}
        cat > "$work_dir/packs/$name/pack.yml" <<YAML
name: $name
description: "Mock pack $name"
agents:
  - bot.md
rules:
  - style.md
YAML
        printf 'Mock agent for %s\n' "$name" > "$work_dir/packs/$name/agents/bot.md"
        printf 'Mock rules for %s\n' "$name" > "$work_dir/packs/$name/rules/style.md"
        manifest_packs+="  - name: $name
    description: \"Mock pack $name\"
"
    done

    # Create manifest.yml
    cat > "$work_dir/manifest.yml" <<YAML
name: "mock-config"
description: "Mock config repo for testing"

packs:
${manifest_packs}
templates: []
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

# Create a single-pack bare git repo (pack.yml at root).
_create_mock_single_pack_repo() {
    local tmpdir="$1"
    local name="$2"
    local work_dir="$tmpdir/mock-single-work"
    local bare_dir="$tmpdir/mock-single.git"

    mkdir -p "$work_dir"/{knowledge,agents,rules}
    cat > "$work_dir/pack.yml" <<YAML
name: $name
description: "Single pack $name"
agents:
  - helper.md
YAML
    printf 'Helper agent\n' > "$work_dir/agents/helper.md"

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

test_pack_install_from_multi_pack_repo() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local remote
    remote=$(_create_mock_config_repo "$tmpdir" "alpha" "beta")
    run_cco pack install "$remote"
    assert_dir_exists "$CCO_PACKS_DIR/alpha"
    assert_dir_exists "$CCO_PACKS_DIR/beta"
    assert_file_exists "$CCO_PACKS_DIR/alpha/pack.yml"
    assert_file_exists "$CCO_PACKS_DIR/beta/pack.yml"
}

test_pack_install_pick_specific_pack() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local remote
    remote=$(_create_mock_config_repo "$tmpdir" "alpha" "beta")
    run_cco pack install "$remote" --pick "alpha"
    assert_dir_exists "$CCO_PACKS_DIR/alpha"
    assert_dir_not_exists "$CCO_PACKS_DIR/beta"
}

test_pack_install_pick_nonexistent_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local remote
    remote=$(_create_mock_config_repo "$tmpdir" "alpha")
    if run_cco pack install "$remote" --pick "nonexistent" 2>/dev/null; then
        echo "ASSERTION FAILED: should fail for nonexistent pack"
        return 1
    fi
}

test_pack_install_creates_cco_source() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local remote
    remote=$(_create_mock_config_repo "$tmpdir" "tracked")
    run_cco pack install "$remote" --pick "tracked"
    assert_file_exists "$CCO_PACKS_DIR/tracked/.cco-source"
    assert_file_contains "$CCO_PACKS_DIR/tracked/.cco-source" "source:"
    assert_file_contains "$CCO_PACKS_DIR/tracked/.cco-source" "installed:"
}

test_pack_install_single_pack_repo() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local remote
    remote=$(_create_mock_single_pack_repo "$tmpdir" "solo-pack")
    run_cco pack install "$remote"
    assert_dir_exists "$CCO_PACKS_DIR/solo-pack"
    assert_file_exists "$CCO_PACKS_DIR/solo-pack/pack.yml"
    assert_file_exists "$CCO_PACKS_DIR/solo-pack/agents/helper.md"
}

test_pack_install_rejects_invalid_repo() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Create empty bare repo (no manifest.yml, no pack.yml)
    local bare_dir="$tmpdir/empty.git"
    local work_dir="$tmpdir/empty-work"
    mkdir -p "$work_dir"
    printf 'hello\n' > "$work_dir/README.md"
    git init --bare -q "$bare_dir"
    git -C "$work_dir" init -q
    git -C "$work_dir" add -A
    git -C "$work_dir" commit -q -m "initial"
    git -C "$work_dir" remote add origin "$bare_dir"
    git -C "$work_dir" push -q origin main 2>/dev/null || \
        git -C "$work_dir" push -q origin master 2>/dev/null

    if run_cco pack install "$bare_dir" 2>/dev/null; then
        echo "ASSERTION FAILED: should reject repo without manifest.yml or pack.yml"
        return 1
    fi
}

test_pack_install_conflict_fails_without_force() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Create local pack
    run_cco pack create "conflict-pack"

    # Try to install remote pack with same name
    local remote
    remote=$(_create_mock_config_repo "$tmpdir" "conflict-pack")
    if run_cco pack install "$remote" --pick "conflict-pack" 2>/dev/null; then
        echo "ASSERTION FAILED: should fail when local pack exists"
        return 1
    fi
}

test_pack_install_force_overwrites() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Create local pack
    run_cco pack create "overwrite-pack"
    # Verify it has no agents (local scaffold)
    assert_file_not_exists "$CCO_PACKS_DIR/overwrite-pack/agents/bot.md"

    # Install remote pack with --force
    local remote
    remote=$(_create_mock_config_repo "$tmpdir" "overwrite-pack")
    run_cco pack install "$remote" --pick "overwrite-pack" --force
    # Should now have the remote agent
    assert_file_exists "$CCO_PACKS_DIR/overwrite-pack/agents/bot.md"
}

test_pack_install_updates_manifest_yml() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Create manifest.yml via init
    run_cco init --lang "English"

    local remote
    remote=$(_create_mock_config_repo "$tmpdir" "shared-pack")
    run_cco pack install "$remote" --pick "shared-pack"
    assert_file_contains "$CCO_USER_CONFIG_DIR/manifest.yml" "shared-pack"
}

# ── update tests ──────────────────────────────────────────────────────

test_pack_update_from_source() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Install a pack
    local remote
    remote=$(_create_mock_config_repo "$tmpdir" "updatable")
    run_cco pack install "$remote" --pick "updatable"
    assert_file_exists "$CCO_PACKS_DIR/updatable/.cco-source"

    # Modify the remote (add new file)
    local work_dir="$tmpdir/mock-work"
    printf 'New content\n' > "$work_dir/packs/updatable/agents/new-agent.md"
    git -C "$work_dir" add -A
    git -C "$work_dir" commit -q -m "add new agent"
    git -C "$work_dir" push -q origin main 2>/dev/null || \
        git -C "$work_dir" push -q origin master 2>/dev/null

    # Fix .cco-source to use the same bare repo path (the update reads source from it)
    # The install recorded the bare path; re-cloning should pick up new commits
    run_cco pack update "updatable"
    assert_file_exists "$CCO_PACKS_DIR/updatable/agents/new-agent.md"
}

test_pack_update_local_pack_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco pack create "local-only"
    if run_cco pack update "local-only" 2>/dev/null; then
        echo "ASSERTION FAILED: should fail for local pack"
        return 1
    fi
}

test_pack_update_nonexistent_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco pack update "ghost-pack" 2>/dev/null; then
        echo "ASSERTION FAILED: should fail for nonexistent pack"
        return 1
    fi
}

# ── export tests ──────────────────────────────────────────────────────

test_pack_export_creates_archive() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco pack create "exportable"

    # Export (runs in current dir)
    cd "$tmpdir"
    run_cco pack export "exportable"
    assert_file_exists "$tmpdir/exportable.tar.gz"
}

test_pack_export_excludes_cco_source() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Install a remote pack (has .cco-source)
    local remote
    remote=$(_create_mock_config_repo "$tmpdir" "source-pack")
    run_cco pack install "$remote" --pick "source-pack"
    assert_file_exists "$CCO_PACKS_DIR/source-pack/.cco-source"

    # Export
    cd "$tmpdir"
    run_cco pack export "source-pack"
    assert_file_exists "$tmpdir/source-pack.tar.gz"

    # Verify .cco-source is NOT in the archive
    if tar tzf "$tmpdir/source-pack.tar.gz" | grep -q '.cco-source'; then
        echo "ASSERTION FAILED: .cco-source should be excluded from export"
        return 1
    fi
}

test_pack_export_nonexistent_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco pack export "nonexistent" 2>/dev/null; then
        echo "ASSERTION FAILED: should fail for nonexistent pack"
        return 1
    fi
}

# ── same-source auto-update ────────────────────────────────────────────

test_pack_install_same_source_auto_updates() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local remote
    remote=$(_create_mock_config_repo "$tmpdir" "auto-pack")
    run_cco pack install "$remote" --pick "auto-pack"
    assert_file_exists "$CCO_PACKS_DIR/auto-pack/agents/bot.md"

    # Modify the remote
    printf 'V2 content\n' > "$tmpdir/mock-work/packs/auto-pack/agents/bot.md"
    git -C "$tmpdir/mock-work" add -A
    git -C "$tmpdir/mock-work" commit -q -m "v2"
    git -C "$tmpdir/mock-work" push -q origin main 2>/dev/null || \
        git -C "$tmpdir/mock-work" push -q origin master 2>/dev/null

    # Re-install same source — should auto-update without --force
    run_cco pack install "$remote" --pick "auto-pack"
    assert_output_contains "updating"
    assert_file_contains "$CCO_PACKS_DIR/auto-pack/agents/bot.md" "V2"
}

# ── update --all ─────────────────────────────────────────────────────

test_pack_update_all_skips_local() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Create a local pack (no .cco-source)
    run_cco pack create "local-only"

    # Create a remote pack
    local remote
    remote=$(_create_mock_config_repo "$tmpdir" "remote-pack")
    run_cco pack install "$remote" --pick "remote-pack"

    # Update all — should update remote-pack, skip local-only
    run_cco pack update --all
    assert_output_contains "Updated 1 pack"
}

test_pack_update_all_no_remote_packs() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Only local packs
    run_cco pack create "local-a"
    run_cco pack create "local-b"

    run_cco pack update --all
    assert_output_contains "No packs with remote sources"
}

# ── cleanup with custom TMPDIR ────────────────────────────────────────

test_pack_install_cleanup_custom_tmpdir() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Set a custom TMPDIR
    local custom_tmp="$tmpdir/custom-tmp"
    mkdir -p "$custom_tmp"
    local remote
    remote=$(_create_mock_config_repo "$tmpdir" "cleanup-test")

    TMPDIR="$custom_tmp" run_cco pack install "$remote" --pick "cleanup-test"
    assert_dir_exists "$CCO_PACKS_DIR/cleanup-test"

    # Temp clones should be cleaned up
    local remaining
    remaining=$(find "$custom_tmp" -maxdepth 1 -name 'cco-*' -type d 2>/dev/null | wc -l)
    assert_equals "0" "$remaining" "Temp clone dirs should be cleaned up"
}

# ── cco-source local pack marker ──────────────────────────────────────

test_pack_create_no_cco_source() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco pack create "manual-pack"
    # Local packs should NOT have .cco-source
    assert_file_not_exists "$CCO_PACKS_DIR/manual-pack/.cco-source"
}

# ── install missing url ──────────────────────────────────────────────

test_pack_install_no_url_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    if run_cco pack install 2>/dev/null; then
        echo "ASSERTION FAILED: should fail without URL"
        return 1
    fi
}

test_pack_export_content_matches() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco pack create "export-test"
    printf 'custom rule\n' > "$CCO_PACKS_DIR/export-test/rules/my-rule.md"

    cd "$tmpdir"
    run_cco pack export "export-test"
    assert_file_exists "$tmpdir/export-test.tar.gz"

    # Verify archive contents
    if ! tar tzf "$tmpdir/export-test.tar.gz" | grep -q "my-rule.md"; then
        echo "ASSERTION FAILED: archive should contain my-rule.md"
        return 1
    fi
}

# ── help tests ────────────────────────────────────────────────────────

test_pack_install_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco pack install --help
    assert_output_contains "install"
    assert_output_contains "--pick"
}

test_pack_update_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco pack update --help
    assert_output_contains "update"
    assert_output_contains "--all"
}

test_pack_export_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco pack export --help
    assert_output_contains "export"
}
