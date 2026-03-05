#!/usr/bin/env bash
# tests/test_remote.sh — cco remote management tests

# ── cco remote add ──────────────────────────────────────────────────

test_remote_add_creates_entry() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme git@github.com:acme/config.git
    assert_file_exists "$CCO_USER_CONFIG_DIR/.cco-remotes"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.cco-remotes" "acme=git@github.com:acme/config.git"
}

test_remote_add_multiple() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add alpha git@github.com:alpha/config.git
    run_cco remote add beta https://github.com/beta/config.git
    assert_file_contains "$CCO_USER_CONFIG_DIR/.cco-remotes" "alpha="
    assert_file_contains "$CCO_USER_CONFIG_DIR/.cco-remotes" "beta="
}

test_remote_add_duplicate_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme git@github.com:acme/config.git
    if run_cco remote add acme git@github.com:acme/other.git 2>/dev/null; then
        echo "ASSERTION FAILED: should reject duplicate remote name"
        return 1
    fi
}

test_remote_add_invalid_name_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco remote add "UPPER" git@github.com:a/b.git 2>/dev/null; then
        echo "ASSERTION FAILED: should reject uppercase name"
        return 1
    fi
}

test_remote_add_invalid_url_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco remote add acme "not-a-url" 2>/dev/null; then
        echo "ASSERTION FAILED: should reject invalid URL"
        return 1
    fi
}

test_remote_add_missing_args_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco remote add 2>/dev/null; then
        echo "ASSERTION FAILED: should fail with missing args"
        return 1
    fi
}

# ── cco remote remove ──────────────────────────────────────────────

test_remote_remove() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme git@github.com:acme/config.git
    run_cco remote remove acme
    assert_file_not_contains "$CCO_USER_CONFIG_DIR/.cco-remotes" "acme="
}

test_remote_remove_preserves_others() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add alpha git@github.com:alpha/config.git
    run_cco remote add beta git@github.com:beta/config.git
    run_cco remote remove alpha
    assert_file_not_contains "$CCO_USER_CONFIG_DIR/.cco-remotes" "alpha="
    assert_file_contains "$CCO_USER_CONFIG_DIR/.cco-remotes" "beta="
}

test_remote_remove_nonexistent_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco remote remove ghost 2>/dev/null; then
        echo "ASSERTION FAILED: should fail for nonexistent remote"
        return 1
    fi
}

# ── cco remote list ────────────────────────────────────────────────

test_remote_list_shows_entries() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme git@github.com:acme/config.git
    run_cco remote list
    assert_output_contains "acme"
    assert_output_contains "git@github.com:acme/config.git"
}

test_remote_list_empty() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote list
    assert_output_contains "No remotes"
}

# ── vault integration ──────────────────────────────────────────────

test_remote_add_syncs_with_vault() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco init --lang "English"
    run_cco vault init
    run_cco remote add acme git@github.com:acme/config.git
    # Should be in both .cco-remotes and git remotes
    assert_file_contains "$CCO_USER_CONFIG_DIR/.cco-remotes" "acme="
    local git_remotes
    git_remotes=$(git -C "$CCO_USER_CONFIG_DIR" remote 2>/dev/null)
    echo "$git_remotes" | grep -q "acme" || {
        echo "ASSERTION FAILED: expected 'acme' in git remotes"
        return 1
    }
}

test_remote_remove_syncs_with_vault() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco init --lang "English"
    run_cco vault init
    run_cco remote add acme git@github.com:acme/config.git
    run_cco remote remove acme
    local git_remotes
    git_remotes=$(git -C "$CCO_USER_CONFIG_DIR" remote 2>/dev/null)
    if echo "$git_remotes" | grep -q "acme"; then
        echo "ASSERTION FAILED: 'acme' should be removed from git remotes"
        return 1
    fi
}

test_vault_remote_delegates_to_cco_remote() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco init --lang "English"
    run_cco vault init
    run_cco vault remote add team git@github.com:team/config.git
    # Should appear in .cco-remotes (delegation worked)
    assert_file_contains "$CCO_USER_CONFIG_DIR/.cco-remotes" "team="
}

# ── edge cases ─────────────────────────────────────────────────────

test_remote_add_name_with_numbers() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add team42 git@github.com:team/config.git
    assert_file_contains "$CCO_USER_CONFIG_DIR/.cco-remotes" "team42="
}

test_remote_add_name_with_leading_hyphen_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco remote add "-bad" git@github.com:a/b.git 2>/dev/null; then
        echo "ASSERTION FAILED: should reject name starting with hyphen"
        return 1
    fi
}

test_remote_prefix_names_independent() {
    # "acme" and "acme-team" should not collide
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme git@github.com:acme/config.git
    run_cco remote add acme-team git@github.com:acme-team/config.git
    run_cco remote remove acme
    assert_file_not_contains "$CCO_USER_CONFIG_DIR/.cco-remotes" "acme=git@github.com:acme/config.git"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.cco-remotes" "acme-team="
}

test_remote_add_without_vault_no_git_sync() {
    # Without vault init, adding a remote should NOT try git operations
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme git@github.com:acme/config.git
    assert_file_contains "$CCO_USER_CONFIG_DIR/.cco-remotes" "acme="
    # No .git dir should exist
    [[ ! -d "$CCO_USER_CONFIG_DIR/.git" ]] || {
        echo "ASSERTION FAILED: vault should not have been initialized"
        return 1
    }
}

# ── help ───────────────────────────────────────────────────────────

test_remote_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco remote --help
    assert_output_contains "remote"
    assert_output_contains "add"
    assert_output_contains "remove"
}

test_remote_add_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco remote add --help
    assert_output_contains "Register"
}

test_remote_remove_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco remote remove --help
    assert_output_contains "Unregister"
}

test_remote_list_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco remote list --help
    assert_output_contains "registered"
}

test_remote_remove_warns_publish_target() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Create a pack with publish_target pointing to the remote
    mkdir -p "$CCO_PACKS_DIR/my-pack"
    echo "name: my-pack" > "$CCO_PACKS_DIR/my-pack/pack.yml"
    cat > "$CCO_PACKS_DIR/my-pack/.cco-source" <<'YAML'
source: local
publish_target: acme
YAML

    run_cco remote add acme "git@github.com:acme/config.git"
    run_cco remote remove acme
    assert_output_contains "publish_target"
    assert_output_contains "my-pack"
}
