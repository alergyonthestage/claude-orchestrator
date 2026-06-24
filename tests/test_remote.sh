#!/usr/bin/env bash
# tests/test_remote.sh — cco remote management tests

# ── cco remote add ──────────────────────────────────────────────────

test_remote_add_creates_entry() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme git@github.com:acme/config.git
    assert_file_exists "$CCO_DATA_HOME/remotes"
    assert_file_contains "$CCO_DATA_HOME/remotes" "acme=git@github.com:acme/config.git"
}

test_remote_add_multiple() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add alpha git@github.com:alpha/config.git
    run_cco remote add beta https://github.com/beta/config.git
    assert_file_contains "$CCO_DATA_HOME/remotes" "alpha="
    assert_file_contains "$CCO_DATA_HOME/remotes" "beta="
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
    assert_file_not_contains "$CCO_DATA_HOME/remotes" "acme="
}

test_remote_remove_preserves_others() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add alpha git@github.com:alpha/config.git
    run_cco remote add beta git@github.com:beta/config.git
    run_cco remote remove alpha
    assert_file_not_contains "$CCO_DATA_HOME/remotes" "alpha="
    assert_file_contains "$CCO_DATA_HOME/remotes" "beta="
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

# Note: the legacy vault-git mirror integration tests (transitional, P3) were
# removed with the vault — `cco remote` now writes only the DATA registry (M3).

# ── edge cases ─────────────────────────────────────────────────────

test_remote_add_name_with_numbers() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add team42 git@github.com:team/config.git
    assert_file_contains "$CCO_DATA_HOME/remotes" "team42="
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
    assert_file_not_contains "$CCO_DATA_HOME/remotes" "acme=git@github.com:acme/config.git"
    assert_file_contains "$CCO_DATA_HOME/remotes" "acme-team="
}

test_remote_add_without_vault_no_git_sync() {
    # Without vault init, adding a remote should NOT try git operations
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme git@github.com:acme/config.git
    assert_file_contains "$CCO_DATA_HOME/remotes" "acme="
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

# ── cco remote token management ───────────────────────────────────

test_remote_add_with_token() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme https://github.com/acme/config.git --token ghp_test123
    assert_file_contains "$CCO_DATA_HOME/remotes" "acme=https://github.com/acme/config.git"
    assert_file_contains "$CCO_STATE_HOME/remotes-token" "acme=ghp_test123"
    assert_output_contains "[token saved]"
}

# Portable file-mode reader (GNU stat vs BSD/macOS stat).
_remote_stat_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# HITL-2 (adherence audit 2026-06-21): the STATE remotes-token file holds a
# secret and must be 0600 — the M3 no-token-leak invariant (S8). cmd-remote.sh
# `chmod 600`s it; this guards that the mode actually lands.
test_remote_token_file_is_0600() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme https://github.com/acme/config.git --token ghp_test123
    local tf="$CCO_STATE_HOME/remotes-token"
    assert_file_exists "$tf"
    local mode; mode=$(_remote_stat_mode "$tf")
    [[ "$mode" == "600" ]] || fail "remotes-token must be mode 0600 (S8 no-token-leak), got: $mode"
}

test_remote_set_token() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme https://github.com/acme/config.git
    run_cco remote set-token acme ghp_test456
    assert_file_contains "$CCO_STATE_HOME/remotes-token" "acme=ghp_test456"
}

test_remote_set_token_overwrites_existing() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme https://github.com/acme/config.git --token ghp_old
    run_cco remote set-token acme ghp_new
    assert_file_contains "$CCO_STATE_HOME/remotes-token" "acme=ghp_new"
    assert_file_not_contains "$CCO_STATE_HOME/remotes-token" "acme=ghp_old"
}

test_remote_set_token_nonexistent_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco remote set-token ghost ghp_test 2>/dev/null; then
        echo "ASSERTION FAILED: should fail for nonexistent remote"
        return 1
    fi
}

test_remote_remove_token() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme https://github.com/acme/config.git --token ghp_test123
    run_cco remote remove-token acme
    assert_file_not_contains "$CCO_STATE_HOME/remotes-token" "acme="
    # URL should still be there
    assert_file_contains "$CCO_DATA_HOME/remotes" "acme=https://github.com/acme/config.git"
}

test_remote_remove_token_nonexistent_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme https://github.com/acme/config.git
    if run_cco remote remove-token acme 2>/dev/null; then
        echo "ASSERTION FAILED: should fail when no token exists"
        return 1
    fi
}

test_remote_remove_also_removes_token() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme https://github.com/acme/config.git --token ghp_test123
    run_cco remote remove acme
    assert_file_not_contains "$CCO_DATA_HOME/remotes" "acme="
    assert_file_not_contains "$CCO_STATE_HOME/remotes-token" "acme="
}

test_remote_list_shows_token_tag() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme https://github.com/acme/config.git --token ghp_test
    run_cco remote add team git@github.com:team/config.git
    run_cco remote list
    assert_output_contains "[token]"
}

test_remote_list_hides_token_lines() {
    # .token= lines should NOT appear as separate remote entries
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme https://github.com/acme/config.git --token ghp_test
    run_cco remote list
    # Output should contain "acme" but not "acme.token"
    assert_output_contains "acme"
    assert_output_not_contains "acme.token"
}

# ── remote_get_token / remote_resolve_token_for_url ───────────────

test_remote_get_token_returns_token() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme https://github.com/acme/config.git --token ghp_abc
    local token
    token=$(
        export USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR"
        source "$REPO_ROOT/lib/colors.sh"
        source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/cmd-remote.sh"
        remote_get_token "acme"
    )
    [[ "$token" == "ghp_abc" ]] || {
        echo "ASSERTION FAILED: expected 'ghp_abc', got '$token'"
        return 1
    }
}

test_remote_get_token_returns_1_when_no_token() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme git@github.com:acme/config.git
    if ( export USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR"
         source "$REPO_ROOT/lib/colors.sh"
         source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/cmd-remote.sh"
         remote_get_token "acme" ) 2>/dev/null; then
        echo "ASSERTION FAILED: should return 1 when no token"
        return 1
    fi
}

test_remote_resolve_token_for_url() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme https://github.com/acme/config.git --token ghp_xyz
    local token
    token=$(
        export USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR"
        source "$REPO_ROOT/lib/colors.sh"
        source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/cmd-remote.sh"
        remote_resolve_token_for_url "https://github.com/acme/config.git"
    )
    [[ "$token" == "ghp_xyz" ]] || {
        echo "ASSERTION FAILED: expected 'ghp_xyz', got '$token'"
        return 1
    }
}

test_remote_resolve_token_for_url_no_match() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme https://github.com/acme/config.git
    if ( export USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR"
         source "$REPO_ROOT/lib/colors.sh"
         source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/cmd-remote.sh"
         remote_resolve_token_for_url "https://github.com/other/repo.git" ) 2>/dev/null; then
        echo "ASSERTION FAILED: should return 1 for unmatched URL"
        return 1
    fi
}

test_remote_token_prefix_independence() {
    # "acme" token should not be returned for "acme-team" and vice versa
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme https://github.com/acme/config.git --token ghp_acme
    run_cco remote add acme-team https://github.com/acme-team/config.git --token ghp_team
    local token_acme token_team
    token_acme=$(
        export USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR"
        source "$REPO_ROOT/lib/colors.sh"
        source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/cmd-remote.sh"
        remote_get_token "acme"
    )
    token_team=$(
        export USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR"
        source "$REPO_ROOT/lib/colors.sh"
        source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/cmd-remote.sh"
        remote_get_token "acme-team"
    )
    [[ "$token_acme" == "ghp_acme" ]] || {
        echo "ASSERTION FAILED: expected 'ghp_acme', got '$token_acme'"
        return 1
    }
    [[ "$token_team" == "ghp_team" ]] || {
        echo "ASSERTION FAILED: expected 'ghp_team', got '$token_team'"
        return 1
    }
}

test_remote_resolve_token_url_normalization() {
    # Trailing .git and / should not prevent token resolution
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco remote add acme https://github.com/acme/config.git --token ghp_norm
    local token
    # Query without .git suffix
    token=$(
        export USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR"
        source "$REPO_ROOT/lib/colors.sh"
        source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/cmd-remote.sh"
        remote_resolve_token_for_url "https://github.com/acme/config"
    )
    [[ "$token" == "ghp_norm" ]] || {
        echo "ASSERTION FAILED: expected 'ghp_norm' for URL without .git, got '$token'"
        return 1
    }
}

# Note: no backward-compat test for the old ~/.cco/.cco/remotes location —
# the M3 cutover moves the registry to DATA with no dual-read (breaking).

# ── help for new commands ─────────────────────────────────────────

test_remote_set_token_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco remote set-token --help
    assert_output_contains "token"
}

test_remote_remove_token_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco remote remove-token --help
    assert_output_contains "token"
}

# ── existing tests ────────────────────────────────────────────────

test_remote_remove_warns_affected_packs() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # A pack whose recorded upstream url resolves to the remote being removed
    # (F4: the publish target is re-derived from the pack url, not stored —
    # ADR-0022 D1).
    mkdir -p "$CCO_PACKS_DIR/my-pack"
    echo "name: my-pack" > "$CCO_PACKS_DIR/my-pack/pack.yml"
    mkdir -p "$(dirname "$(data_pack_source my-pack)")"
    printf 'url: git@github.com:acme/config.git\n' > "$(data_pack_source my-pack)"

    run_cco remote add acme "git@github.com:acme/config.git"
    run_cco remote remove acme
    assert_output_contains "publish to 'acme'" || return 1
    assert_output_contains "my-pack" || return 1
}
