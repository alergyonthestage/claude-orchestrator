#!/usr/bin/env bash
# tests/test_migrate.sh — first-run bootstrap + legacy-vault backup (Phase 2-1)
#
# Covers the J0 four-root bootstrap (ADR-0017 D3) and the raw-tar legacy-vault
# safety-net backup (ADR-0006 Decision 2 / ADR-0025 §2): the archive captures
# every profile's secrets (active working-tree + inactive shadows; F1/F9),
# includes .git, is atomic-staged (F44), 0600, and idempotent (F43).
# Per-project/global *populate* lands in later P2 commits.

# Build a realistic legacy vault under $CCO_USER_CONFIG_DIR: global config,
# a project, an ACTIVE secret in the working tree, and an INACTIVE profile's
# stash shadow secret. git-init makes it a "vault" (the backup trigger).
# Usage: _setup_legacy_vault "$tmpdir"
_setup_legacy_vault() {
    local tmpdir="$1"
    setup_cco_env "$tmpdir"
    local vault="$CCO_USER_CONFIG_DIR"
    mkdir -p "$vault/global/.claude" "$vault/projects/demo/.claude" \
             "$vault/.cco/profile-state/work"
    echo "global cfg" > "$vault/global/.claude/CLAUDE.md"
    echo "ACTIVE_SECRET=active123" > "$vault/global/secrets.env"
    printf 'name: demo\n' > "$vault/projects/demo/project.yml"
    echo "WORK_SECRET=work456" > "$vault/.cco/profile-state/work/secrets.env"
    git -C "$vault" init -q
    git -C "$vault" add -A 2>/dev/null || true
    git -C "$vault" commit -q -m "vault: seed" 2>/dev/null || true
}

# Path to the single backup archive (empty if none). Usage: _backup_archive
_backup_archive() {
    ls "$CCO_STATE_HOME"/backups/vault-*.tar.gz 2>/dev/null | head -1
}

# ── J0 four-root bootstrap (ADR-0017 D3) ─────────────────────────────

test_migrate_bootstrap_creates_four_roots() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    # Start from empty roots: remove what setup created so we prove J0 makes them.
    rm -rf "$HOME/.cco" "$CCO_DATA_HOME" "$CCO_STATE_HOME" "$CCO_CACHE_HOME"
    run_cco path list || true
    assert_dir_exists "$HOME/.cco" "J0 should create the CONFIG root ~/.cco"
    assert_dir_exists "$CCO_DATA_HOME" "J0 should create the DATA root"
    assert_dir_exists "$CCO_STATE_HOME" "J0 should create the STATE root"
    assert_dir_exists "$CCO_CACHE_HOME" "J0 should create the CACHE root"
}

test_migrate_bootstrap_git_inits_config_root() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    rm -rf "$HOME/.cco"
    run_cco path list || true
    assert_dir_exists "$HOME/.cco/.git" "~/.cco must be a git-versioned working tree (ADR-0008/0024 D4)"
}

test_migrate_bootstrap_idempotent_no_clobber() {
    # M6: re-running must not disturb an existing root's contents.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    mkdir -p "$HOME/.cco/global"
    echo "keep me" > "$HOME/.cco/global/marker"
    run_cco path list || true
    run_cco path list || true
    assert_file_contains "$HOME/.cco/global/marker" "keep me" "bootstrap must not clobber existing CONFIG content"
}

# ── Legacy-vault backup (ADR-0006 / ADR-0025) ────────────────────────

test_migrate_backup_created_on_any_command() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault "$tmpdir"
    run_cco path list || true
    local archive; archive=$(_backup_archive)
    [[ -n "$archive" ]] || fail "a legacy-vault backup should be archived to STATE on any command"
}

test_migrate_backup_captures_active_secret() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault "$tmpdir"
    run_cco path list || true
    local archive; archive=$(_backup_archive)
    [[ -n "$archive" ]] || fail "no backup archive"
    tar -xzOf "$archive" ./global/secrets.env 2>/dev/null | grep -q "active123" \
        || fail "backup must capture the active working-tree secret (F1/F9)"
}

test_migrate_backup_captures_shadow_profile_secret() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault "$tmpdir"
    run_cco path list || true
    local archive; archive=$(_backup_archive)
    [[ -n "$archive" ]] || fail "no backup archive"
    tar -xzOf "$archive" ./.cco/profile-state/work/secrets.env 2>/dev/null | grep -q "work456" \
        || fail "backup must capture inactive profiles' shadow secrets (F1/F9)"
}

test_migrate_backup_includes_git() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault "$tmpdir"
    run_cco path list || true
    local archive; archive=$(_backup_archive)
    [[ -n "$archive" ]] || fail "no backup archive"
    # Capture the listing first (a `tar -tzf | grep -q` pipeline 141s under
    # pipefail when grep early-exits and tar gets SIGPIPE).
    local entries; entries=$(tar -tzf "$archive" 2>/dev/null)
    grep -q "^\./\.git/" <<< "$entries" \
        || fail "backup must include .git for full-history rollback (ADR-0006)"
}

test_migrate_backup_excludes_old_in_vault_backups() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault "$tmpdir"
    mkdir -p "$CCO_USER_CONFIG_DIR/.cco/backups"
    echo "OLD" > "$CCO_USER_CONFIG_DIR/.cco/backups/old-vault.tar.gz"
    run_cco path list || true
    local archive; archive=$(_backup_archive)
    [[ -n "$archive" ]] || fail "no backup archive"
    tar -tzf "$archive" 2>/dev/null | grep -q "\.cco/backups" \
        && fail "the old in-vault .cco/backups/ must be excluded (no self-nesting)"
    return 0
}

test_migrate_backup_writes_marker() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault "$tmpdir"
    run_cco path list || true
    assert_file_exists "$CCO_STATE_HOME/migration-state" "the fast-path idempotency marker must be written (F43)"
}

test_migrate_backup_is_0600() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault "$tmpdir"
    run_cco path list || true
    local archive; archive=$(_backup_archive)
    [[ -n "$archive" ]] || fail "no backup archive"
    # Portable 0600 check: GNU `stat -c` first, BSD `stat -f` fallback (GNU's
    # `-f` means --file-system and would silently succeed with wrong output).
    local perms
    perms=$(stat -c '%a' "$archive" 2>/dev/null || stat -f '%Lp' "$archive" 2>/dev/null)
    [[ "$perms" == "600" ]] || fail "the backup archive must be 0600 (got $perms) — plaintext secrets at rest"
}

test_migrate_backup_atomic_no_leftover_tmp() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault "$tmpdir"
    run_cco path list || true
    local leftover
    leftover=$(ls "$CCO_STATE_HOME"/backups/.vault-*.tmp 2>/dev/null | head -1)
    [[ -z "$leftover" ]] || fail "no atomic-staging .tmp file should remain (F44): $leftover"
}

test_migrate_backup_idempotent_single_archive() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault "$tmpdir"
    run_cco path list || true
    run_cco path list || true
    run_cco path list || true
    local count
    count=$(ls "$CCO_STATE_HOME"/backups/vault-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
    [[ "$count" == "1" ]] || fail "exactly one archive expected across runs (F43), got $count"
}

test_migrate_backup_survives_wiped_marker() {
    # F43 authoritative signal: a wiped marker must NOT trigger a re-archive when
    # a verified archive already exists.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault "$tmpdir"
    run_cco path list || true
    rm -f "$CCO_STATE_HOME/migration-state"
    run_cco path list || true
    local count
    count=$(ls "$CCO_STATE_HOME"/backups/vault-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
    [[ "$count" == "1" ]] || fail "a wiped marker must not cause a destructive re-archive (F43), got $count"
    assert_file_exists "$CCO_STATE_HOME/migration-state" "the marker should be healed from the authoritative archive"
}

test_migrate_backup_skipped_without_vault() {
    # A clean install (no .git vault) must not produce a backup.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco path list || true
    local archive; archive=$(_backup_archive)
    [[ -z "$archive" ]] || fail "no backup should be made without a legacy vault: $archive"
}

test_migrate_backup_skipped_on_vault_command() {
    # Pure-legacy `cco vault` ops act on the old vault under the old expectation;
    # they are outside the decentralized safety net, so they do not trigger it.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault "$tmpdir"
    run_cco vault status || true
    local archive; archive=$(_backup_archive)
    [[ -z "$archive" ]] || fail "a vault command must not trigger the backup net: $archive"
}

# ── Eager global migration via `cco update` (ADR-0025 §1) ────────────

# Build a legacy vault with global config + a shared pack + a profile-exclusive
# pack ('work-pack' on the 'work' profile branch only) + a template + setup +
# secrets + legacy languages. git default branch pinned to 'main'.
_setup_legacy_vault_global() {
    local tmpdir="$1"
    setup_cco_env "$tmpdir"
    local vault="$CCO_USER_CONFIG_DIR"
    mkdir -p "$vault/global/.claude/.cco" "$vault/packs/shared-pack" \
             "$vault/packs/work-pack" "$vault/templates/my-tmpl"
    echo "# global cfg" > "$vault/global/.claude/CLAUDE.md"
    printf 'schema_version: 5\nlanguages:\n  communication: Italian\n  documentation: Italian\n  code_comments: English\n' \
        > "$vault/global/.claude/.cco/meta"
    echo "apt-get x" > "$vault/global/setup.sh"
    echo "SECRET=1"  > "$vault/global/secrets.env"
    echo "name: shared-pack" > "$vault/packs/shared-pack/pack.yml"
    echo "name: work-pack"   > "$vault/packs/work-pack/pack.yml"
    echo "name: my-tmpl"     > "$vault/templates/my-tmpl/template.yml"
    git -C "$vault" init -q
    git -C "$vault" symbolic-ref HEAD refs/heads/main 2>/dev/null
    git -C "$vault" add -A 2>/dev/null
    git -C "$vault" commit -q -m "main: shared" 2>/dev/null
    # 'work' profile: work-pack is exclusive (recorded in .vault-profile)
    git -C "$vault" checkout -q -b work 2>/dev/null
    printf 'profile: work\nresources:\n  packs:\n    - work-pack\n' > "$vault/.vault-profile"
    git -C "$vault" add -A 2>/dev/null
    git -C "$vault" commit -q -m "work profile" 2>/dev/null
    git -C "$vault" checkout -q main 2>/dev/null
    git -C "$vault" rm -rq packs/work-pack 2>/dev/null
    rm -rf "$vault/packs/work-pack"
    git -C "$vault" commit -q -m "main without work-pack" 2>/dev/null
}

test_migrate_global_populates_cco() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_global "$tmpdir"
    run_cco update || true
    assert_file_exists "$HOME/.cco/global/.claude/CLAUDE.md" "global/.claude should be populated into ~/.cco"
    assert_file_exists "$HOME/.cco/setup.sh"      "setup.sh should be migrated to ~/.cco"
    assert_file_exists "$HOME/.cco/secrets.env"   "secrets.env should be migrated to ~/.cco"
    assert_dir_exists  "$HOME/.cco/templates/my-tmpl"  "templates should be migrated to ~/.cco"
    assert_dir_exists  "$HOME/.cco/packs/shared-pack"  "shared pack should be migrated to ~/.cco"
}

test_migrate_global_languages_decomposed() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_global "$tmpdir"
    run_cco update || true
    assert_file_contains "$(cco_languages_file)" "communication: Italian" \
        "languages should be decomposed from the legacy meta into ~/.cco/languages"
}

test_migrate_global_profile_exclusive_pack_tagged() {
    # work-pack lives only on the 'work' branch → populated from the branch + tagged.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_global "$tmpdir"
    run_cco update || true
    assert_dir_exists "$HOME/.cco/packs/work-pack" "profile-exclusive pack should be populated from its branch"
    assert_file_contains "$CCO_DATA_HOME/tags.yml" "work-pack: [work]" \
        "profile-exclusive pack should be tagged with its origin profile (ADR-0010 §5)"
}

test_migrate_global_idempotent() {
    # A second `cco update` must not re-migrate or clobber edited ~/.cco config.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_global "$tmpdir"
    run_cco update || true
    echo "# user edit" >> "$HOME/.cco/global/.claude/CLAUDE.md"
    run_cco update || true
    assert_file_contains "$HOME/.cco/global/.claude/CLAUDE.md" "user edit" \
        "re-running migration must not clobber user-edited ~/.cco config"
}

test_migrate_global_offer_to_remove() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_global "$tmpdir"
    run_cco update || true
    assert_output_contains "Migration complete"
    assert_output_contains "never delete it for you"
    # The legacy vault must remain intact (default keep).
    assert_dir_exists "$CCO_USER_CONFIG_DIR/.git" "the legacy vault must be preserved (default keep)"
}

test_migrate_global_skipped_without_legacy_vault() {
    # A fresh install (no legacy vault → no backup) must not run the migration.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco update || true
    # ~/.cco/global came from setup_global_from_defaults, not the migration; no tags seeded.
    [[ ! -f "$CCO_DATA_HOME/tags.yml" ]] || fail "no profile→tag seed should occur without a legacy vault"
}

test_migrate_global_dry_run_skips() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_global "$tmpdir"
    run_cco update --dry-run || true
    [[ ! -d "$HOME/.cco/global/.claude" ]] || fail "--dry-run must not populate ~/.cco"
}
