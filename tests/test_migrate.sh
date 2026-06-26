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

# Note: the legacy `cco vault` backup-skip test was removed with the vault (P3).

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

test_migrate_global_after_init_nondestructive() {
    # ADR-0026 hinge: a legacy user who ran `cco init` first (populating
    # ~/.cco/global from defaults) must STILL be migrated by `cco update`, not
    # silently skipped. The idempotency gate is the global-migrated marker flag,
    # not ~/.cco/global presence; the overwrite is non-destructive (backup + confirm).
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_global "$tmpdir"
    # Simulate `cco init` having seeded ~/.cco/global from defaults first.
    mkdir -p "$HOME/.cco/global/.claude"
    echo "# from cco init defaults" > "$HOME/.cco/global/.claude/CLAUDE.md"

    # `cco update` backs up the vault (dispatch), then migrates: no global-migrated
    # flag + backup + ~/.cco/global present → non-destructive overwrite (confirmed).
    CCO_ASSUME_YES=1 run_cco update || true

    # The vault content replaced the init-seeded defaults (migration ran).
    assert_file_contains "$HOME/.cco/global/.claude/CLAUDE.md" "global cfg" \
        "the legacy vault must overwrite the init-seeded defaults (non-destructive migration)"
    assert_file_not_contains "$HOME/.cco/global/.claude/CLAUDE.md" "from cco init defaults"
    # A restorable backup of the pre-migration ~/.cco was written.
    local had_backup=false f
    for f in "$CCO_STATE_HOME"/backups/cco-config-*.tar.gz; do [[ -e "$f" ]] && had_backup=true; done
    [[ "$had_backup" == true ]] || fail "a restorable ~/.cco backup must be written before overwrite"
    # The gate flag was recorded (a second update is then idempotent).
    assert_file_contains "$CCO_STATE_HOME/migration-state" "global-migrated"
}

# ── Lazy per-project migration: cco init --migrate (ADR-0006/0021) ──

# Build a legacy vault with project 'myapp' (sanitized repos + url + local-paths,
# an llms ref, a pack ref, project .claude + memory). Optionally a profile
# branch 'work' hosting 'work-app'. Leaves $tmpdir/clones/api as a fresh repo.
_setup_legacy_vault_project() {
    local tmpdir="$1"
    setup_cco_env "$tmpdir"
    local vault="$CCO_USER_CONFIG_DIR"
    mkdir -p "$vault/global/.claude" \
             "$vault/projects/myapp/.claude/rules" "$vault/projects/myapp/.cco" \
             "$vault/projects/myapp/memory" \
             "$vault/packs/team-pack/.cco" "$vault/llms/react/.cco"
    echo "# g" > "$vault/global/.claude/CLAUDE.md"
    cat > "$vault/projects/myapp/project.yml" <<'YML'
name: myapp
description: "My app"
repos:
  - path: "@local"
    name: api
    url: git@github.com:org/api.git
    ref: main
  - path: "@local"
    name: web
    url: git@github.com:org/web.git
llms:
  - react
packs:
  - team-pack
YML
    echo "# project claude" > "$vault/projects/myapp/.claude/CLAUDE.md"
    echo "remember this"    > "$vault/projects/myapp/memory/note.md"
    cat > "$vault/projects/myapp/.cco/local-paths.yml" <<'YML'
repos:
  api: "/home/dev/api"
  web: "/home/dev/web"
YML
    echo "source: https://github.com/org/cco-sharing.git" > "$vault/packs/team-pack/.cco/source"
    echo "name: team-pack" > "$vault/packs/team-pack/pack.yml"
    printf 'url: https://react.dev/llms-full.txt\nvariant: full\n' > "$vault/llms/react/.cco/source"
    git -C "$vault" init -q
    git -C "$vault" symbolic-ref HEAD refs/heads/main 2>/dev/null
    git -C "$vault" add -A 2>/dev/null
    git -C "$vault" commit -q -m "main" 2>/dev/null
    mkdir -p "$tmpdir/clones/api"
}

test_migrate_project_writes_final_yml() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_project "$tmpdir"
    ( cd "$tmpdir/clones/api" && CCO_ASSUME_YES=1 run_cco init --migrate myapp )
    local yml="$tmpdir/clones/api/.cco/project.yml"
    assert_file_exists "$yml" "the migrated project.yml should be written into <repo>/.cco/"
    assert_file_contains "$yml" "name: api"
    assert_file_contains "$yml" "url: git@github.com:org/api.git"
    assert_file_contains "$yml" "url: https://react.dev/llms-full.txt"
    assert_file_contains "$yml" "variant: full"
    # pack list→map with the url backfilled from the recorded source (read in place)
    assert_file_contains "$yml" "url: https://github.com/org/cco-sharing.git"
    # AD3/G8: no real path ever lands in the committed config.
    assert_file_not_contains "$yml" "/home/dev"
    assert_file_not_contains "$yml" "@local"
}

test_migrate_project_registers_index() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_project "$tmpdir"
    ( cd "$tmpdir/clones/api" && CCO_ASSUME_YES=1 run_cco init --migrate myapp )
    assert_file_contains "$CCO_STATE_HOME/index" 'api: "/home/dev/api"'
    assert_file_contains "$CCO_STATE_HOME/index" 'web: "/home/dev/web"'
    assert_file_contains "$CCO_STATE_HOME/index" "myapp:"
}

test_migrate_project_relocates_memory() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_project "$tmpdir"
    ( cd "$tmpdir/clones/api" && CCO_ASSUME_YES=1 run_cco init --migrate myapp )
    assert_file_exists "$CCO_STATE_HOME/projects/myapp/memory/note.md" \
        "memory should relocate to STATE (machine-local; ADR-0009)"
    # And NOT into the committed config.
    [[ ! -d "$tmpdir/clones/api/.cco/memory" ]] || fail "memory must not live in committed .cco/"
}

test_migrate_project_memory_non_clobber() {
    # Pre-existing newer STATE memory must not be overwritten (F11).
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_project "$tmpdir"
    mkdir -p "$CCO_STATE_HOME/projects/myapp/memory"
    echo "newer local note" > "$CCO_STATE_HOME/projects/myapp/memory/note.md"
    ( cd "$tmpdir/clones/api" && CCO_ASSUME_YES=1 run_cco init --migrate myapp )
    assert_file_contains "$CCO_STATE_HOME/projects/myapp/memory/note.md" "newer local note" \
        "migration must not clobber newer local memory (F11)"
}

test_migrate_project_name_uniqueness() {
    # F12: a name already bound in the index blocks a second migrate.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_project "$tmpdir"
    ( cd "$tmpdir/clones/api" && CCO_ASSUME_YES=1 run_cco init --migrate myapp )
    mkdir -p "$tmpdir/clones/api2"
    ( cd "$tmpdir/clones/api2" && CCO_ASSUME_YES=1 run_cco init --migrate myapp ) \
        && fail "a duplicate project name must be rejected (F12)" || true
}

test_migrate_project_backup_required() {
    # M8: no verified backup → refuse to read.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"   # no git-vault → no backup is ever taken
    mkdir -p "$tmpdir/repo"
    ( cd "$tmpdir/repo" && run_cco init --migrate myapp ) \
        && fail "migrate must fail without a verified backup (M8)" || true
}

test_migrate_project_unknown_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_project "$tmpdir"
    mkdir -p "$tmpdir/repo"
    ( cd "$tmpdir/repo" && run_cco init --migrate nonexistent ) \
        && fail "migrating an unknown project must fail" || true
    [[ ! -d "$tmpdir/repo/.cco" ]] || fail "a failed migrate must leave no partial .cco/ (F44)"
}

test_migrate_project_profile_tag() {
    # A project hosted on a non-default profile branch → tagged with its origin.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_project "$tmpdir"
    local vault="$CCO_USER_CONFIG_DIR"
    # Add a 'work' profile hosting 'work-app'.
    git -C "$vault" checkout -q -b work 2>/dev/null
    mkdir -p "$vault/projects/work-app/.cco"
    printf 'name: work-app\nrepos: []\n' > "$vault/projects/work-app/project.yml"
    printf 'profile: work\nsync:\n  projects:\n    - work-app\n  packs:\n    []\n' > "$vault/.vault-profile"
    git -C "$vault" add -A 2>/dev/null
    git -C "$vault" commit -q -m "work profile" 2>/dev/null
    git -C "$vault" checkout -q main 2>/dev/null
    mkdir -p "$tmpdir/clones/workrepo"
    ( cd "$tmpdir/clones/workrepo" && CCO_ASSUME_YES=1 run_cco init --migrate work-app )
    assert_file_contains "$CCO_DATA_HOME/tags.yml" "work-app: [work]" \
        "a profile-hosted project should be tagged with its origin profile (ADR-0010 §5)"
}

# BL1/BL2 (26-06-2026 migration review): a project living ONLY on a non-active
# profile branch must recover its gitignored secrets, memory, and local-paths from
# the vault's profile-state shadow — git archive serializes committed files only.
test_migrate_project_inactive_profile_gitignored_from_shadow() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local vault="$CCO_USER_CONFIG_DIR"
    mkdir -p "$vault/global/.claude"
    echo "# g" > "$vault/global/.claude/CLAUDE.md"
    git -C "$vault" init -q
    git -C "$vault" symbolic-ref HEAD refs/heads/main 2>/dev/null
    git -C "$vault" add -A 2>/dev/null
    git -C "$vault" commit -q -m "main" 2>/dev/null
    # 'work' profile hosting 'work-app' (committed only on this branch).
    git -C "$vault" checkout -q -b work 2>/dev/null
    mkdir -p "$vault/projects/work-app/.claude"
    cat > "$vault/projects/work-app/project.yml" <<'YML'
name: work-app
repos:
  - path: "@local"
    name: workrepo
    url: git@github.com:org/workrepo.git
YML
    echo "# work-app" > "$vault/projects/work-app/.claude/CLAUDE.md"
    printf 'profile: work\nsync:\n  projects:\n    - work-app\n  packs:\n    []\n' > "$vault/.vault-profile"
    git -C "$vault" add -A 2>/dev/null
    git -C "$vault" commit -q -m "work profile" 2>/dev/null
    git -C "$vault" checkout -q main 2>/dev/null
    # The inactive profile's gitignored files live in the on-disk profile-state
    # shadow (untracked → captured by the raw-tar backup, not by git archive).
    local sh="$vault/.cco/profile-state/work/projects/work-app"
    mkdir -p "$sh/.cco" "$sh/memory"
    echo "WORKAPP_SECRET=xyz789" > "$sh/secrets.env"
    echo "remember work-app" > "$sh/memory/note.md"
    printf 'repos:\n  workrepo: "/home/dev/workrepo"\n' > "$sh/.cco/local-paths.yml"
    mkdir -p "$tmpdir/clones/workrepo"

    ( cd "$tmpdir/clones/workrepo" && CCO_ASSUME_YES=1 run_cco init --migrate work-app )

    # BL1 — secrets recovered from the shadow into the committed (gitignored) .cco/secrets.env
    assert_file_contains "$tmpdir/clones/workrepo/.cco/secrets.env" "WORKAPP_SECRET=xyz789" \
        "inactive-profile project secrets must be migrated from the profile-state shadow (BL1)"
    # BL2 — memory recovered from the shadow into STATE
    assert_file_exists "$CCO_STATE_HOME/projects/work-app/memory/note.md" \
        "inactive-profile project memory must be migrated from the shadow (BL2)"
    # local-paths from the shadow → index (repo path still registered)
    assert_file_contains "$CCO_STATE_HOME/index" 'workrepo: "/home/dev/workrepo"' \
        "inactive-profile repo path (from shadow local-paths.yml) must register in the index"
    # machine-agnostic project.yml — no host path leaks even via the shadow
    assert_file_not_contains "$tmpdir/clones/workrepo/.cco/project.yml" "/home/dev"
}

test_join_registers_index() {
    # cco join in a cloned repo registers project membership for this machine.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo="$tmpdir/cloned"
    mkdir -p "$repo/.cco"
    cat > "$repo/.cco/project.yml" <<'YML'
name: joined
repos:
  - name: api
    url: git@github.com:org/api.git
  - name: web
    url: git@github.com:org/web.git
YML
    ( cd "$repo" && run_cco join )
    assert_file_contains "$CCO_STATE_HOME/index" "joined:"
}

# ── P4 source→DATA relocation (ADR-0022 D1) ──────────────────────────

test_relocate_legacy_pack_source_to_data() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update-meta.sh"
    source "$REPO_ROOT/lib/migrate.sh"
    PACKS_DIR="$CCO_PACKS_DIR"

    # A pack carrying a LEGACY in-tree .cco/source (old keys).
    mkdir -p "$CCO_PACKS_DIR/legacy-pack/.cco"
    printf 'source: git@example.com:team/cfg.git\npath: packs/legacy-pack\nref: main\ncommit: deadbeef\ninstalled: 2026-01-01\nupdated: 2026-01-02\n' \
        > "$CCO_PACKS_DIR/legacy-pack/.cco/source"

    _relocate_legacy_pack_sources

    # Coordinate (renamed keys) → DATA; bookkeeping → STATE meta; legacy gone.
    local new_src; new_src=$(data_pack_source legacy-pack)
    assert_file_exists "$new_src" || return 1
    assert_file_contains "$new_src" "url: git@example.com:team/cfg.git" || return 1
    assert_file_contains "$new_src" "resource: packs/legacy-pack" || return 1
    assert_file_contains "$new_src" "ref: main" || return 1
    # The legacy `source:` key is renamed (anchored: avoid matching `resource:`).
    grep -q '^source:' "$new_src" && { echo "ASSERTION FAILED: legacy 'source:' key not renamed to 'url:'"; return 1; }
    assert_file_not_exists "$CCO_PACKS_DIR/legacy-pack/.cco/source" || return 1
    assert_file_contains "$(state_pack_meta legacy-pack)" "installed_commit: deadbeef" || return 1

    # Idempotent: a second pass is a clean no-op.
    _relocate_legacy_pack_sources || return 1
    assert_file_exists "$new_src" || return 1
}

test_relocate_legacy_pack_source_bare_url() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update-meta.sh"
    source "$REPO_ROOT/lib/migrate.sh"
    PACKS_DIR="$CCO_PACKS_DIR"

    # Pre-FI-7 bare-url first line (no `source:` key).
    mkdir -p "$CCO_PACKS_DIR/bare-pack/.cco"
    printf 'https://github.com/team/cfg.git\n' > "$CCO_PACKS_DIR/bare-pack/.cco/source"

    _relocate_legacy_pack_sources

    assert_file_contains "$(data_pack_source bare-pack)" "url: https://github.com/team/cfg.git" || return 1
    assert_file_not_exists "$CCO_PACKS_DIR/bare-pack/.cco/source" || return 1
}
