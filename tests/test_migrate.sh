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
    mkdir -p "$HOME/.cco"
    echo "keep me" > "$HOME/.cco/marker"
    run_cco path list || true
    run_cco path list || true
    assert_file_contains "$HOME/.cco/marker" "keep me" "bootstrap must not clobber existing CONFIG content"
}

# ── Pre-flatten self-heal (ADR-0028) ─────────────────────────────────

test_migrate_bootstrap_flattens_legacy_global_claude() {
    # A pre-flatten layout (~/.cco/global/.claude) must self-heal to the flat
    # ~/.cco/.claude on ANY command — before check_global / global-config readers
    # run. Regression: check_global looks at the flat dir, so without the bootstrap
    # flatten a pre-flatten user is locked out of `cco update` (the eager owner).
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    mkdir -p "$HOME/.cco/global/.claude/rules"
    echo "# legacy global" > "$HOME/.cco/global/.claude/CLAUDE.md"
    echo "# legacy rule"   > "$HOME/.cco/global/.claude/rules/workflow.md"

    run_cco path list || true

    assert_dir_exists    "$HOME/.cco/.claude" "bootstrap must flatten legacy global/.claude"
    assert_file_contains "$HOME/.cco/.claude/CLAUDE.md" "legacy global" "content must move to the flat home"
    assert_file_contains "$HOME/.cco/.claude/rules/workflow.md" "legacy rule"
    [[ ! -e "$HOME/.cco/global" ]] || fail "the legacy global/ wrapper must be removed after flatten"
}

test_migrate_bootstrap_flatten_noop_when_flat() {
    # Already-flat install: bootstrap flatten is a clean no-op (never clobbers).
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    mkdir -p "$HOME/.cco/.claude"
    echo "# flat" > "$HOME/.cco/.claude/CLAUDE.md"
    run_cco path list || true
    assert_file_contains "$HOME/.cco/.claude/CLAUDE.md" "flat" "an already-flat home must be untouched"
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

# H5 (26-06-2026 migration review): a legacy user (vault backup present, ~/.cco/.claude
# not yet populated) hitting check_global must be pointed at 'cco update', not 'cco init'.
test_check_global_points_legacy_user_to_update() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault "$tmpdir"
    run_cco path list || true   # first-run backup of the legacy vault → STATE
    run_cco new --repo "$tmpdir" || true
    assert_output_contains "cco update" \
        "check_global must point a legacy user (backup present) to 'cco update' (H5)"
    echo "${CCO_OUTPUT:-}" | grep -qF "Run 'cco init' first" \
        && fail "check_global must NOT tell a legacy user to run 'cco init' (H5)" || true
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
    # Legacy CENTRAL remotes registry: url + inline name.token=token in one file.
    mkdir -p "$vault/.cco"
    printf '# CCO Config Repo remotes\n# Format: name=url\nteam-remote=https://github.com/org/cco-sharing.git\nteam-remote.token=ghp_secrettoken123\n' \
        > "$vault/.cco/remotes"
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
    assert_file_exists "$HOME/.cco/.claude/CLAUDE.md" "global/.claude should be populated into ~/.cco"
    assert_file_exists "$HOME/.cco/setup.sh"      "setup.sh should be migrated to ~/.cco"
    assert_file_exists "$HOME/.cco/secrets.env"   "secrets.env should be migrated to ~/.cco"
    assert_dir_exists  "$HOME/.cco/templates/my-tmpl"  "templates should be migrated to ~/.cco"
    assert_dir_exists  "$HOME/.cco/packs/shared-pack"  "shared pack should be migrated to ~/.cco"
}

test_migrate_global_relocates_remotes_split() {
    # GAP-1: the legacy central .cco/remotes (url + inline name.token=token) splits
    # into DATA remotes (de-tokenized, synced) + STATE remotes-token (0600,
    # never-sync). No token may ride the synced DATA file.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_global "$tmpdir"
    run_cco update || true
    local rf="$CCO_DATA_HOME/remotes" tf="$CCO_STATE_HOME/remotes-token"
    assert_file_exists "$rf" "the remotes url registry should be migrated to DATA"
    assert_file_contains "$rf" "team-remote=https://github.com/org/cco-sharing.git"
    # The token must NOT ride the synced DATA file (de-tokenize invariant, M3).
    assert_file_not_contains "$rf" "ghp_secrettoken123"
    assert_file_not_contains "$rf" ".token="
    # The token lives de-tokenized in the STATE token store.
    assert_file_exists "$tf" "the remotes token store should be in STATE"
    assert_file_contains "$tf" "team-remote=ghp_secrettoken123"
}

# H1 (26-06-2026 migration review): global/.claude is staged then atomic-renamed,
# so a partial copy never passes check_global and no staging dir is left behind.
test_migrate_global_atomic_no_stage_leftover() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_global "$tmpdir"
    run_cco update || true
    assert_dir_exists "$HOME/.cco/.claude" "global/.claude must be present after migration"
    [[ ! -e "$HOME/.cco/.claude.tmp" ]] \
        || fail "the atomic global/.claude staging dir must not be left behind (H1)"
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
    echo "# user edit" >> "$HOME/.cco/.claude/CLAUDE.md"
    run_cco update || true
    assert_file_contains "$HOME/.cco/.claude/CLAUDE.md" "user edit" \
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
    # ~/.cco/.claude came from setup_global_from_defaults, not the migration; no tags seeded.
    [[ ! -f "$CCO_DATA_HOME/tags.yml" ]] || fail "no profile→tag seed should occur without a legacy vault"
}

test_migrate_global_dry_run_skips() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_global "$tmpdir"
    run_cco update --dry-run || true
    [[ ! -d "$HOME/.cco/.claude" ]] || fail "--dry-run must not populate ~/.cco"
}

test_migrate_global_after_init_nondestructive() {
    # ADR-0026 hinge: a legacy user who ran `cco init` first (populating
    # ~/.cco/.claude from defaults) must STILL be migrated by `cco update`, not
    # silently skipped. The idempotency gate is the global-migrated marker flag,
    # not ~/.cco/.claude presence; the overwrite is non-destructive (backup + confirm).
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_global "$tmpdir"
    # Simulate `cco init` having seeded ~/.cco/.claude from defaults first.
    mkdir -p "$HOME/.cco/.claude"
    echo "# from cco init defaults" > "$HOME/.cco/.claude/CLAUDE.md"

    # `cco update` backs up the vault (dispatch), then migrates: no global-migrated
    # flag + backup + ~/.cco/.claude present → non-destructive overwrite (confirmed).
    CCO_ASSUME_YES=1 run_cco update || true

    # The vault content replaced the init-seeded defaults (migration ran).
    assert_file_contains "$HOME/.cco/.claude/CLAUDE.md" "global cfg" \
        "the legacy vault must overwrite the init-seeded defaults (non-destructive migration)"
    assert_file_not_contains "$HOME/.cco/.claude/CLAUDE.md" "from cco init defaults"
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
extra_mounts:
  - source: ~/extra-docs
    target: /workspace/extra-docs
    readonly: true
  - source: "@local"
    name: shared-data
    target: /workspace/shared-data
    readonly: false
llms:
  - react
packs:
  - team-pack

# ── Docker options ───────────────────────────────────────────────────
docker:
  image: custom-image:latest
  mount_socket: true
  network: cc-myapp-custom
  ports:
    - "5000:5000"
  env:
    FOO: bar
  containers:
    policy: allowlist
    allow:
      - "cc-myapp-*"
auth:
  method: api_key
github:
  enabled: true
  token_env: MY_GH_TOKEN
browser:
  enabled: true
  cdp_port: 9333

# ── A section the migration has never heard of ───────────────────────
customfoo:
  hello: world
YML
    echo "# project claude" > "$vault/projects/myapp/.claude/CLAUDE.md"
    echo "remember this"    > "$vault/projects/myapp/memory/note.md"
    cat > "$vault/projects/myapp/.cco/local-paths.yml" <<'YML'
repos:
  api: "/home/dev/api"
  web: "/home/dev/web"
extra_mounts:
  shared-data: "/home/dev/shared-data"
YML
    echo "source: https://github.com/org/cco-sharing.git" > "$vault/packs/team-pack/.cco/source"
    echo "name: team-pack" > "$vault/packs/team-pack/pack.yml"
    printf 'url: https://react.dev/llms-full.txt\nvariant: full\n' > "$vault/llms/react/.cco/source"
    # Portable session state + arbitrary gitignored secret files that MUST migrate
    # (no data loss): transcripts (GAP#2) and *.env/*.key/*.pem (GAP#1, legacy
    # _PORTABLE_FILE_PATTERNS). The shared fixture carries them so every migrate test
    # also proves the secret-scan does not refuse the gitignored-by-design files.
    mkdir -p "$vault/projects/myapp/.cco/claude-state"
    printf '{"type":"summary"}\n' > "$vault/projects/myapp/.cco/claude-state/session1.jsonl"
    printf 'API_KEY=legacy-secret\n' > "$vault/projects/myapp/api.env"
    printf 'PRIVATE-KEY-BYTES\n'      > "$vault/projects/myapp/id_rsa.key"
    printf 'CERT-BYTES\n'             > "$vault/projects/myapp/cert.pem"
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
    # M1: the sibling staging dir is consumed by the atomic rename — none left behind.
    local _leftover; _leftover=$(ls -d "$tmpdir/clones/api"/.cco-stage.* 2>/dev/null | head -1)
    [[ -z "$_leftover" ]] || fail "the sibling staging dir must not survive a successful migrate (M1): $_leftover"
}

test_migrate_project_preserves_all_config() {
    # Completeness (migration-completeness fix / ADR-0030): docker/auth/github/
    # browser pass through verbatim, an UNKNOWN section survives too, and
    # extra_mounts get a synthesized name with the host source in the index (not
    # the committed yml). These assertions FAIL on the pre-fix builder (which
    # emitted only name/description/repos/llms/packs).
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_project "$tmpdir"
    ( cd "$tmpdir/clones/api" && CCO_ASSUME_YES=1 run_cco init --migrate myapp )
    local yml="$tmpdir/clones/api/.cco/project.yml"

    # docker block (passthrough verbatim, incl. ports/env + a policy sub-block)
    assert_file_contains "$yml" "image: custom-image:latest"
    assert_file_contains "$yml" "mount_socket: true"
    assert_file_contains "$yml" "network: cc-myapp-custom"
    assert_file_contains "$yml" "5000:5000"
    assert_file_contains "$yml" "FOO: bar"
    assert_file_contains "$yml" "policy: allowlist"
    # auth / github / browser (passthrough)
    assert_file_contains "$yml" "method: api_key"
    assert_file_contains "$yml" "token_env: MY_GH_TOKEN"
    assert_file_contains "$yml" "cdp_port: 9333"
    # An unknown future section survives verbatim → passthrough-by-default, no allowlist.
    assert_file_contains "$yml" "customfoo:"
    assert_file_contains "$yml" "hello: world"

    # extra_mounts: name synthesized from the target basename; target + readonly kept.
    assert_file_contains "$yml" "name: extra-docs"
    assert_file_contains "$yml" "target: /workspace/extra-docs"
    assert_file_contains "$yml" "readonly: true"
    # AD3/G8: the legacy host `source:` is transformed away — never the committed yml.
    assert_file_not_contains "$yml" "source:"
    # The host source lands in the machine-local index, keyed by the synth name.
    assert_file_contains "$(cco_index_file)" "extra-docs:"
    # kind=mount: an extra_mount gets an index path but does NOT join project membership.
    if grep '^myapp:' "$(cco_index_file)" 2>/dev/null | grep -q 'extra-docs'; then
        fail "extra_mounts must not join project membership (kind=mount), only the index path"
    fi

    # B fix: a legacy `@local` mount source must resolve to the REAL path via
    # local-paths.yml — never `@local` (its leading `@` is a reserved YAML char
    # that breaks the generated docker-compose).
    assert_file_contains "$yml" "name: shared-data"
    assert_file_not_contains "$yml" "@local"
    assert_file_contains "$(cco_index_file)" 'shared-data: "/home/dev/shared-data"'
}

test_migrate_project_registers_index() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_project "$tmpdir"
    ( cd "$tmpdir/clones/api" && CCO_ASSUME_YES=1 run_cco init --migrate myapp )
    assert_file_contains "$(cco_index_file)" 'api: "/home/dev/api"'
    assert_file_contains "$(cco_index_file)" 'web: "/home/dev/web"'
    assert_file_contains "$(cco_index_file)" "myapp:"
}

test_migrate_project_relocates_memory() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_project "$tmpdir"
    ( cd "$tmpdir/clones/api" && CCO_ASSUME_YES=1 run_cco init --migrate myapp )
    # H7: memory lands where cmd-start mounts it — projects/<id>/session/memory.
    assert_file_exists "$CCO_STATE_HOME/projects/myapp/session/memory/note.md" \
        "memory should relocate to STATE session/memory (machine-local; ADR-0009)"
    # And NOT into the committed config.
    [[ ! -d "$tmpdir/clones/api/.cco/memory" ]] || fail "memory must not live in committed .cco/"
}

test_migrate_project_memory_non_clobber() {
    # Pre-existing newer STATE memory must not be overwritten (F11).
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_project "$tmpdir"
    mkdir -p "$CCO_STATE_HOME/projects/myapp/session/memory"
    echo "newer local note" > "$CCO_STATE_HOME/projects/myapp/session/memory/note.md"
    ( cd "$tmpdir/clones/api" && CCO_ASSUME_YES=1 run_cco init --migrate myapp )
    assert_file_contains "$CCO_STATE_HOME/projects/myapp/session/memory/note.md" "newer local note" \
        "migration must not clobber newer local memory (F11)"
}

test_migrate_project_relocates_transcripts() {
    # GAP#2: session transcripts (/resume history) must migrate to STATE
    # session/claude-state — machine-local (ADR-0009: local migration ≠ cross-PC
    # sync). Destination == where cmd-start mounts them, so history reappears on
    # the next `cco start`.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_project "$tmpdir"
    ( cd "$tmpdir/clones/api" && CCO_ASSUME_YES=1 run_cco init --migrate myapp )
    assert_file_exists "$CCO_STATE_HOME/projects/myapp/session/claude-state/session1.jsonl" \
        "transcripts should relocate to STATE session/claude-state (GAP#2; ADR-0009)"
    # And NOT into the committed config.
    [[ ! -d "$tmpdir/clones/api/.cco/claude-state" ]] || fail "transcripts must not live in committed .cco/"
}

test_migrate_project_transcripts_non_clobber() {
    # Pre-existing newer STATE transcripts must not be overwritten on re-migrate (F11).
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_project "$tmpdir"
    mkdir -p "$CCO_STATE_HOME/projects/myapp/session/claude-state"
    echo "newer transcript" > "$CCO_STATE_HOME/projects/myapp/session/claude-state/session1.jsonl"
    ( cd "$tmpdir/clones/api" && CCO_ASSUME_YES=1 run_cco init --migrate myapp )
    assert_file_contains "$CCO_STATE_HOME/projects/myapp/session/claude-state/session1.jsonl" "newer transcript" \
        "migration must not clobber newer local transcripts (F11)"
}

test_migrate_project_relocates_arbitrary_secret_files() {
    # GAP#1: legacy portable secret files (*.env/*.key/*.pem — _PORTABLE_FILE_PATTERNS)
    # must migrate into <repo>/.cco/ (gitignored-by-design, never silently dropped),
    # and the secret-scan must NOT refuse them (they are not committed).
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_project "$tmpdir"
    ( cd "$tmpdir/clones/api" && CCO_ASSUME_YES=1 run_cco init --migrate myapp )
    local cco="$tmpdir/clones/api/.cco"
    assert_file_exists "$cco/api.env"    "*.env secret file must migrate (GAP#1)"
    assert_file_exists "$cco/id_rsa.key" "*.key secret file must migrate (GAP#1)"
    assert_file_exists "$cco/cert.pem"   "*.pem secret file must migrate (GAP#1)"
    # Gitignored-by-design so they are never committed.
    assert_file_contains "$cco/.gitignore" "*.key"
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

# H3 (26-06-2026 migration review): F12 must be symmetric — a name registered by a
# prior migrate (in the projects: registry, not paths:) must also block a clean
# `cco init --name`, which previously checked only the paths: section.
test_init_rejects_name_taken_by_migrated_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_project "$tmpdir"
    ( cd "$tmpdir/clones/api" && CCO_ASSUME_YES=1 run_cco init --migrate myapp )
    mkdir -p "$tmpdir/other"
    ( cd "$tmpdir/other" && CCO_SKIP_BUILD=1 run_cco init --name myapp ) \
        && fail "clean init must reject a name already registered by a migrated project (H3)" || true
    [[ ! -d "$tmpdir/other/.cco" ]] || fail "the rejected init must leave no .cco/ in the new repo"
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

# M4 (26-06-2026 migration review): profile→tag is opt-in — without a TTY and
# without CCO_ASSUME_YES it must be SKIPPED, never seeded silently.
test_migrate_project_profile_tag_skipped_non_interactive() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_project "$tmpdir"
    local vault="$CCO_USER_CONFIG_DIR"
    git -C "$vault" checkout -q -b work 2>/dev/null
    mkdir -p "$vault/projects/work-app/.cco"
    printf 'name: work-app\nrepos: []\n' > "$vault/projects/work-app/project.yml"
    printf 'profile: work\nsync:\n  projects:\n    - work-app\n  packs:\n    []\n' > "$vault/.vault-profile"
    git -C "$vault" add -A 2>/dev/null
    git -C "$vault" commit -q -m "work profile" 2>/dev/null
    git -C "$vault" checkout -q main 2>/dev/null
    mkdir -p "$tmpdir/clones/workrepo"
    # No CCO_ASSUME_YES, no TTY → the opt-in tag must NOT be seeded.
    ( cd "$tmpdir/clones/workrepo" && run_cco init --migrate work-app )
    if [[ -f "$CCO_DATA_HOME/tags.yml" ]] && grep -q "work-app" "$CCO_DATA_HOME/tags.yml"; then
        fail "non-interactive migrate must not seed the profile tag without consent (M4)"
    fi
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
    mkdir -p "$sh/.cco" "$sh/.cco/claude-state" "$sh/memory"
    echo "WORKAPP_SECRET=xyz789" > "$sh/secrets.env"
    echo "remember work-app" > "$sh/memory/note.md"
    printf '{"type":"summary"}\n' > "$sh/.cco/claude-state/session1.jsonl"
    echo "WORKAPP_KEY=abc" > "$sh/extra.key"
    printf 'repos:\n  workrepo: "/home/dev/workrepo"\n' > "$sh/.cco/local-paths.yml"
    mkdir -p "$tmpdir/clones/workrepo"

    ( cd "$tmpdir/clones/workrepo" && CCO_ASSUME_YES=1 run_cco init --migrate work-app )

    # BL1 — secrets recovered from the shadow into the committed (gitignored) .cco/secrets.env
    assert_file_contains "$tmpdir/clones/workrepo/.cco/secrets.env" "WORKAPP_SECRET=xyz789" \
        "inactive-profile project secrets must be migrated from the profile-state shadow (BL1)"
    # BL2 — memory recovered from the shadow into STATE (session/memory; H7)
    assert_file_exists "$CCO_STATE_HOME/projects/work-app/session/memory/note.md" \
        "inactive-profile project memory must be migrated from the shadow (BL2)"
    # GAP#2 — transcripts recovered from the shadow into STATE (session/claude-state)
    assert_file_exists "$CCO_STATE_HOME/projects/work-app/session/claude-state/session1.jsonl" \
        "inactive-profile transcripts must be migrated from the shadow (GAP#2)"
    # GAP#1 — arbitrary secret file recovered from the shadow into <repo>/.cco/
    assert_file_exists "$tmpdir/clones/workrepo/.cco/extra.key" \
        "inactive-profile *.key secret file must be migrated from the shadow (GAP#1)"
    # local-paths from the shadow → index (repo path still registered)
    assert_file_contains "$(cco_index_file)" 'workrepo: "/home/dev/workrepo"' \
        "inactive-profile repo path (from shadow local-paths.yml) must register in the index"
    # machine-agnostic project.yml — no host path leaks even via the shadow
    assert_file_not_contains "$tmpdir/clones/workrepo/.cco/project.yml" "/home/dev"
}

# NOTE: `cco join` was repurposed to Journey E (ADR-0034) — adding the current
# repo as a MEMBER of an existing project. The former Journey-C form (register a
# cloned repo's own committed .cco/) was removed (covered by cwd-first `cco start`
# + `cco resolve --scan`). Its behavior is now exercised in tests/test_join.sh.

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

test_relocate_legacy_template_source_to_data() {
    # GAP-2: an installed template's legacy in-tree .cco/source must relocate to
    # DATA (coordinate) + STATE (provenance) — the template twin of the pack
    # relocation, so `cco template update` keeps finding its source.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/update-meta.sh"
    source "$REPO_ROOT/lib/migrate.sh"
    TEMPLATES_DIR="$CCO_TEMPLATES_DIR"

    mkdir -p "$CCO_TEMPLATES_DIR/legacy-tmpl/.cco"
    printf 'source: git@example.com:team/tmpls.git\npath: templates/legacy-tmpl\nref: main\ncommit: cafebabe\ninstalled: 2026-01-01\nupdated: 2026-01-02\n' \
        > "$CCO_TEMPLATES_DIR/legacy-tmpl/.cco/source"

    _relocate_legacy_template_sources

    local new_src; new_src=$(data_template_source legacy-tmpl)
    assert_file_exists "$new_src" || return 1
    assert_file_contains "$new_src" "url: git@example.com:team/tmpls.git" || return 1
    assert_file_contains "$new_src" "resource: templates/legacy-tmpl" || return 1
    assert_file_contains "$new_src" "ref: main" || return 1
    grep -q '^source:' "$new_src" && { echo "ASSERTION FAILED: legacy 'source:' key not renamed to 'url:'"; return 1; }
    assert_file_not_exists "$CCO_TEMPLATES_DIR/legacy-tmpl/.cco/source" || return 1
    assert_file_contains "$(state_shared)/templates/legacy-tmpl/update/meta" "installed_commit: cafebabe" || return 1

    # Idempotent: a second pass is a clean no-op.
    _relocate_legacy_template_sources || return 1
    assert_file_exists "$new_src" || return 1
}

# ── Pack llms url backfill (ADR-0032 D3) ─────────────────────────────
# _backfill_pack_llms_urls adopts a missing llms `url` from the global llms
# `.cco/source` so a migrated pack stays re-fetchable. Idempotent; leaves
# genuinely unrecoverable (never-installed) refs url-less for validate to flag.

# Source the libs + a global llms source dir for a given name/url/variant.
_setup_backfill_env() {
    local tmpdir="$1" name="$2" url="$3" variant="${4:-}"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    source "$REPO_ROOT/lib/migrate.sh"
    export LLMS_DIR="$tmpdir/llms"
    mkdir -p "$LLMS_DIR/$name/.cco"
    { printf 'url: %s\n' "$url"; [[ -n "$variant" ]] && printf 'variant: %s\n' "$variant"; } \
        > "$LLMS_DIR/$name/.cco/source"
}

test_backfill_pack_llms_recovers_url_from_global_source() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_backfill_env "$tmpdir" "svelte" "https://svelte.dev/llms.txt" "full"
    local yml="$tmpdir/pack.yml"
    printf 'name: p\nllms:\n  - svelte\n' > "$yml"
    _backfill_one_pack_llms "$yml"
    local got; got=$(yml_get_llms "$yml" | sed 's/\t/|/g')
    [[ "$got" == "svelte||full|https://svelte.dev/llms.txt" ]] \
        || fail "Expected url+variant backfilled, got: $got"
}

test_backfill_pack_llms_skips_unrecoverable() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_backfill_env "$tmpdir" "svelte" "https://svelte.dev/llms.txt" "full"
    local yml="$tmpdir/pack.yml"
    # 'mystery' has no global source → must stay untouched.
    printf 'name: p\nllms:\n  - mystery\n' > "$yml"
    local before; before=$(cat "$yml")
    _backfill_one_pack_llms "$yml"
    [[ "$(cat "$yml")" == "$before" ]] || fail "Unrecoverable ref should be left untouched"
}

test_backfill_pack_llms_idempotent_and_preserves_existing() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_backfill_env "$tmpdir" "svelte" "https://svelte.dev/llms.txt" "full"
    local yml="$tmpdir/pack.yml"
    # An entry that already has a (custom) url must not be overwritten.
    printf 'name: p\nllms:\n  - svelte\n  - name: tailwind\n    url: https://custom/t.txt\n' > "$yml"
    _backfill_one_pack_llms "$yml"
    local first; first=$(cat "$yml")
    _backfill_one_pack_llms "$yml"
    [[ "$(cat "$yml")" == "$first" ]] || fail "Second pass must be a no-op (idempotent)"
    local got; got=$(yml_get_llms "$yml" | sed 's/\t/|/g' | tr '\n' ';')
    [[ "$got" == "svelte||full|https://svelte.dev/llms.txt;tailwind|||https://custom/t.txt;" ]] \
        || fail "Existing url must be preserved, recoverable backfilled, got: $got"
}

# S1 finding #1: a repo recovered as ~/… or $HOME/… and an @local mount must land
# in the index as ABSOLUTE paths — never a tilde / $HOME / @local (which poison
# by-name resolve, produce false AD5 conflicts, and break the generated compose).
# Pre-fix the repos branch wrote the recovered value raw; only mounts normalized.
test_migrate_normalizes_tilde_and_atlocal_into_index() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_legacy_vault_project "$tmpdir"
    local vault="$CCO_USER_CONFIG_DIR"
    # Recover api via a tilde spelling, web via a $HOME spelling, the @local mount
    # via a tilde spelling — every one must normalize to an absolute path.
    cat > "$vault/projects/myapp/.cco/local-paths.yml" <<'YML'
repos:
  api: "~/dev/api"
  web: "$HOME/dev/web"
extra_mounts:
  shared-data: "~/dev/shared-data"
YML
    git -C "$vault" add -A 2>/dev/null
    git -C "$vault" commit -q -m "tilde paths" 2>/dev/null
    ( cd "$tmpdir/clones/api" && CCO_ASSUME_YES=1 run_cco init --migrate myapp )
    local idx="$(cco_index_file)"
    assert_file_contains "$idx" "api: \"$HOME/dev/api\""
    assert_file_contains "$idx" "web: \"$HOME/dev/web\""
    assert_file_contains "$idx" "shared-data: \"$HOME/dev/shared-data\""
    # No raw tilde / literal $HOME / @local ever stored in the index.
    assert_file_not_contains "$idx" '@local'
    grep -q '~'      "$idx" && fail "index must not store a tilde path" || true
    grep -qF '$HOME' "$idx" && fail "index must not store a literal \$HOME" || true
}
