#!/usr/bin/env bash
# tests/test_pack_install.sh — cco pack install/update/export tests
#
# Uses bare git repos as mock remotes.

# ── Helper: create a mock Config Repo ─────────────────────────────────

# Create a bare git repo with packs and share.yml.
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
    local share_packs=""
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
        share_packs+="  - name: $name
    description: \"Mock pack $name\"
"
    done

    # Create share.yml
    cat > "$work_dir/share.yml" <<YAML
name: "mock-config"
description: "Mock config repo for testing"

packs:
${share_packs}
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

    # Create empty bare repo (no share.yml, no pack.yml)
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
        echo "ASSERTION FAILED: should reject repo without share.yml or pack.yml"
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

test_pack_install_updates_share_yml() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Create share.yml via init
    run_cco init --lang "English"

    local remote
    remote=$(_create_mock_config_repo "$tmpdir" "shared-pack")
    run_cco pack install "$remote" --pick "shared-pack"
    assert_file_contains "$CCO_USER_CONFIG_DIR/share.yml" "shared-pack"
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
