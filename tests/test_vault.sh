#!/usr/bin/env bash
# tests/test_vault.sh — cco vault command tests
#
# Verifies vault init, sync, diff, log, status, and secret detection.

# ── Helper: set up an initialized vault ───────────────────────────────

_setup_vault() {
    local tmpdir="$1"
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco vault init
}

# ── vault init ────────────────────────────────────────────────────────

test_vault_init_creates_git_repo() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco vault init
    assert_dir_exists "$CCO_USER_CONFIG_DIR/.git"
}

test_vault_init_creates_gitignore() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco vault init
    assert_file_exists "$CCO_USER_CONFIG_DIR/.gitignore"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.gitignore" "secrets.env"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.gitignore" "*.key"
    assert_file_contains "$CCO_USER_CONFIG_DIR/.gitignore" ".credentials.json"
}

test_vault_init_creates_initial_commit() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco vault init
    local count
    count=$(git -C "$CCO_USER_CONFIG_DIR" rev-list --count HEAD 2>/dev/null)
    assert_equals "1" "$count" "Expected 1 initial commit"
}

test_vault_init_idempotent() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco vault init
    # Second init should warn but not fail
    run_cco vault init
    assert_output_contains "already initialized"
}

test_vault_init_includes_manifest_yml() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"
    run_cco vault init
    # manifest.yml should be in the initial commit
    local files
    files=$(git -C "$CCO_USER_CONFIG_DIR" show --name-only --format="" HEAD)
    if ! echo "$files" | grep -qF "manifest.yml"; then
        echo "ASSERTION FAILED: manifest.yml should be in initial commit"
        echo "  Files: $files"
        return 1
    fi
}

# ── vault save (replaces vault sync) ─────────────────────────────────

test_vault_save_no_changes() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"
    run_cco vault save --yes
    assert_output_contains "up to date"
}

test_vault_save_commits_changes() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    # Make a change
    printf '# New rule\n' > "$CCO_GLOBAL_DIR/.claude/rules/test-rule.md"

    run_cco vault save "added test rule" --yes
    assert_output_contains "Saved"

    # Verify commit exists
    local log
    log=$(git -C "$CCO_USER_CONFIG_DIR" log --oneline -1)
    if ! echo "$log" | grep -qF "added test rule"; then
        echo "ASSERTION FAILED: commit message not found in log"
        echo "  Log: $log"
        return 1
    fi
}

test_vault_save_dry_run() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    # Make a change
    printf '# New rule\n' > "$CCO_GLOBAL_DIR/.claude/rules/test-rule.md"

    run_cco vault save --dry-run
    assert_output_contains "Dry run"

    # Should NOT be committed
    local status
    status=$(git -C "$CCO_USER_CONFIG_DIR" status --porcelain)
    if [[ -z "$status" ]]; then
        echo "ASSERTION FAILED: file should still be uncommitted after dry run"
        return 1
    fi
}

test_vault_save_categorizes_changes() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    # Make changes in different categories
    printf '# Global change\n' > "$CCO_GLOBAL_DIR/.claude/rules/test.md"
    mkdir -p "$CCO_PACKS_DIR/test-pack"
    printf 'name: test-pack\n' > "$CCO_PACKS_DIR/test-pack/pack.yml"

    run_cco vault save --dry-run
    assert_output_contains "global:"
    assert_output_contains "packs:"
}

test_vault_save_aborts_on_secret_files() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    # Create a secret file that bypasses gitignore
    # (simulate: user modified .gitignore to remove secret exclusions)
    sed -i 's/^secrets.env$/# secrets.env/' "$CCO_USER_CONFIG_DIR/.gitignore"
    sed -i 's/^\*\.env$/# *.env/' "$CCO_USER_CONFIG_DIR/.gitignore"
    printf 'API_KEY=secret123\n' > "$CCO_USER_CONFIG_DIR/secrets.env"

    if run_cco vault save --yes 2>/dev/null; then
        echo "ASSERTION FAILED: save should abort when secret files are detected"
        return 1
    fi
}

test_vault_save_default_message() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    printf '# Change\n' > "$CCO_GLOBAL_DIR/.claude/rules/test.md"

    run_cco vault save --yes
    local log
    log=$(git -C "$CCO_USER_CONFIG_DIR" log --oneline -1)
    if ! echo "$log" | grep -qF "vault: snapshot"; then
        echo "ASSERTION FAILED: default message should contain 'vault: snapshot'"
        echo "  Log: $log"
        return 1
    fi
}

# ── vault sync (deprecated alias) ───────────────────────────────────

test_vault_sync_deprecated_alias() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    printf '# Change\n' > "$CCO_GLOBAL_DIR/.claude/rules/test.md"

    run_cco vault sync "via deprecated alias" --yes
    assert_output_contains "deprecated"
    assert_output_contains "Saved"
}

# ── vault diff ────────────────────────────────────────────────────────

test_vault_diff_no_changes() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"
    run_cco vault diff
    assert_output_contains "No uncommitted"
}

test_vault_diff_shows_categories() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    printf '# Change\n' > "$CCO_GLOBAL_DIR/.claude/rules/test.md"

    run_cco vault diff
    assert_output_contains "Global:"
}

# ── vault log ─────────────────────────────────────────────────────────

test_vault_log_shows_commits() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"
    run_cco vault log
    assert_output_contains "initial commit"
}

test_vault_log_limit() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    # Create extra commits
    printf '# A\n' > "$CCO_GLOBAL_DIR/.claude/rules/a.md"
    run_cco vault save "commit a" --yes
    printf '# B\n' > "$CCO_GLOBAL_DIR/.claude/rules/b.md"
    run_cco vault save "commit b" --yes

    run_cco vault log --limit 1
    # Should only show 1 commit
    local line_count
    line_count=$(echo "$CCO_OUTPUT" | grep -c . || true)
    assert_equals "1" "$line_count" "Expected 1 line with --limit 1"
}

# ── vault status ──────────────────────────────────────────────────────

test_vault_status_not_initialized() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco vault status
    assert_output_contains "not initialized"
}

test_vault_status_initialized() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"
    run_cco vault status
    assert_output_contains "initialized"
    assert_output_contains "Branch:"
    assert_output_contains "Commits:"
}

test_vault_status_shows_uncommitted_count() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    printf '# Change\n' > "$CCO_GLOBAL_DIR/.claude/rules/test.md"

    run_cco vault status
    assert_output_contains "uncommitted"
}

test_vault_status_clean() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"
    run_cco vault status
    assert_output_contains "clean"
}

# Regression: status and diff must agree after save with local paths.
# Before the fix, `cco vault status` counted raw git status lines without
# the @local normalization that `cco vault diff` applies. A project.yml
# with real paths in the working tree and @local in HEAD produced a
# virtual diff: status reported "1 uncommitted file(s)" while diff
# reported "No uncommitted changes".
test_vault_status_and_diff_agree_after_save_with_local_paths() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    # Plant a project with a real (non-@local) path. vault save will
    # extract @local, commit, and restore real paths in the working tree.
    local proj="$CCO_PROJECTS_DIR/myapp"
    mkdir -p "$proj/.cco" "$proj/.claude" "$proj/memory"
    cat > "$proj/project.yml" <<'YAML'
name: myapp
description: "Test"
auth:
  method: oauth
docker:
  ports: []
  env: {}
repos:
  - path: ~/Projects/myapp-api
    name: api
YAML

    run_cco vault save "add myapp" --yes

    # Working tree now has ~/Projects/myapp-api; HEAD has "@local".
    # Both commands must see this as clean (virtual-only diff).
    run_cco vault diff
    assert_output_contains "No uncommitted"

    run_cco vault status
    assert_output_contains "clean"
}

# ── vault not initialized errors ─────────────────────────────────────

test_vault_save_fails_without_init() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco vault save --yes 2>/dev/null; then
        echo "ASSERTION FAILED: save should fail without vault init"
        return 1
    fi
}

test_vault_diff_fails_without_init() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco vault diff 2>/dev/null; then
        echo "ASSERTION FAILED: diff should fail without vault init"
        return 1
    fi
}

test_vault_log_fails_without_init() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco vault log 2>/dev/null; then
        echo "ASSERTION FAILED: log should fail without vault init"
        return 1
    fi
}

# ── vault restore ─────────────────────────────────────────────────────

test_vault_restore_invalid_ref_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"
    if run_cco vault restore "nonexistent-ref" 2>/dev/null; then
        echo "ASSERTION FAILED: should fail for invalid ref"
        return 1
    fi
}

test_vault_restore_no_ref_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"
    if run_cco vault restore 2>/dev/null; then
        echo "ASSERTION FAILED: should fail without ref"
        return 1
    fi
}

test_vault_restore_no_diff_reports_nothing() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"
    # Restore to HEAD (no changes)
    run_cco vault restore HEAD
    assert_output_contains "nothing to restore"
}

test_vault_restore_non_interactive_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    # Create a second commit
    printf '# Change\n' > "$CCO_GLOBAL_DIR/.claude/rules/test.md"
    run_cco vault save "add test" --yes

    # Pipe stdin (non-tty) — should refuse
    if echo "" | run_cco vault restore HEAD~1 2>/dev/null; then
        echo "ASSERTION FAILED: should fail in non-interactive mode"
        return 1
    fi
}

# ── vault remote ──────────────────────────────────────────────────────

test_vault_remote_add() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"
    run_cco vault remote add origin "https://github.com/test/repo.git"
    assert_output_contains "Added remote"

    # Verify remote was added
    local remotes
    remotes=$(git -C "$CCO_USER_CONFIG_DIR" remote -v)
    if ! echo "$remotes" | grep -q "origin"; then
        echo "ASSERTION FAILED: remote 'origin' not found"
        return 1
    fi
}

test_vault_remote_remove() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"
    run_cco vault remote add test-remote "https://example.com/repo.git"
    run_cco vault remote remove test-remote
    assert_output_contains "Removed remote"
}

test_vault_remote_no_args_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"
    if run_cco vault remote 2>/dev/null; then
        echo "ASSERTION FAILED: should fail without subcommand"
        return 1
    fi
}

test_vault_remote_add_missing_url_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"
    if run_cco vault remote add "myremote" 2>/dev/null; then
        echo "ASSERTION FAILED: should fail without URL"
        return 1
    fi
}

# ── vault push/pull ───────────────────────────────────────────────────

test_vault_push_no_remote_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"
    # No remote configured — push should fail
    if run_cco vault push 2>/dev/null; then
        echo "ASSERTION FAILED: push should fail without remote"
        return 1
    fi
}

test_vault_pull_no_remote_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"
    # No remote configured — pull should fail
    if run_cco vault pull 2>/dev/null; then
        echo "ASSERTION FAILED: pull should fail without remote"
        return 1
    fi
}

test_vault_push_to_bare_remote() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    # Create a bare repo as remote
    local bare="$tmpdir/remote.git"
    git init --bare -q "$bare"
    run_cco vault remote add origin "$bare"

    # Push
    run_cco vault push
    assert_output_contains "Pushed '"

    # Verify commit exists in bare repo
    local count
    count=$(git -C "$bare" rev-list --count HEAD 2>/dev/null)
    assert_equals "1" "$count" "Expected 1 commit in bare remote"
}

# ── vault status extended ─────────────────────────────────────────────

test_vault_status_shows_remote() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    local bare="$tmpdir/remote.git"
    git init --bare -q "$bare"
    run_cco vault remote add origin "$bare"

    run_cco vault status
    assert_output_contains "origin"
}

# ── vault help ────────────────────────────────────────────────────────

test_vault_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco vault --help
    assert_output_contains "vault"
    assert_output_contains "init"
    assert_output_contains "save"
    assert_output_contains "diff"
    assert_output_contains "status"
}

test_vault_restore_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco vault restore --help
    assert_output_contains "restore"
}

test_vault_remote_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco vault remote --help
    assert_output_contains "remote"
}

test_vault_push_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco vault push --help
    assert_output_contains "push"
}

test_vault_pull_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco vault pull --help
    assert_output_contains "pull"
}

# ── Scenario 19: vault save secret scan detects .cco/remotes ──────────

test_vault_save_aborts_on_cco_remotes() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    # Create .cco/remotes with token (should be gitignored, but simulate bypass)
    mkdir -p "$CCO_USER_CONFIG_DIR/.cco"
    printf 'acme=git@example.com:acme.git\nacme_token=secret-token-123\n' > "$CCO_USER_CONFIG_DIR/.cco/remotes"

    # Remove .cco/remotes from gitignore to simulate accidental inclusion
    sed -i 's|^\.cco/remotes$|# .cco/remotes|' "$CCO_USER_CONFIG_DIR/.gitignore"

    if run_cco vault save --yes 2>/dev/null; then
        echo "ASSERTION FAILED: save should abort when .cco/remotes is detected as secret"
        return 1
    fi
}

# ── Scenario 12: vault save tracks .cco/base/ ────────────────────────

test_vault_save_tracks_cco_base() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    # Create .cco/base/ with content (should be tracked, not gitignored)
    mkdir -p "$CCO_GLOBAL_DIR/.claude/.cco/base"
    echo "base settings" > "$CCO_GLOBAL_DIR/.claude/.cco/base/settings.json"

    # Also create .cco/meta (should be gitignored)
    mkdir -p "$CCO_GLOBAL_DIR/.claude/.cco"
    echo "schema_version: 9" > "$CCO_GLOBAL_DIR/.claude/.cco/meta"

    run_cco vault save --yes

    # .cco/base/ content should be committed
    local committed
    committed=$(git -C "$CCO_USER_CONFIG_DIR" show HEAD --name-only)
    if ! echo "$committed" | grep -qF ".cco/base/settings.json"; then
        echo "ASSERTION FAILED: .cco/base/ should be vault-tracked"
        echo "  Committed files: $committed"
        return 1
    fi

    # .cco/meta should NOT be committed (gitignored)
    if echo "$committed" | grep -qF ".cco/meta"; then
        echo "ASSERTION FAILED: .cco/meta should be gitignored"
        return 1
    fi
}

# ── Scenario 13: runtime invariants (#B15-B18) ───────────────────────

# #B15 — a vault .gitignore missing a canonical pattern is self-healed
# at the next vault operation.
test_vault_ensure_gitignore_heals_missing_pattern() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    # Simulate a pre-migration branch: strip the pre-save pattern from
    # .gitignore and commit the mutation.
    local gi="$CCO_USER_CONFIG_DIR/.gitignore"
    sed -i '/projects\/\*\/\.cco\/project\.yml\.pre-save/d' "$gi"
    git -C "$CCO_USER_CONFIG_DIR" add .gitignore
    git -C "$CCO_USER_CONFIG_DIR" commit -q -m "test: simulate stale gitignore"

    # Any vault op (here: status) should self-heal on its way in.
    run_cco vault status >/dev/null

    if ! grep -qxF 'projects/*/.cco/project.yml.pre-save' "$gi"; then
        echo "ASSERTION FAILED: _ensure_vault_gitignore did not heal the missing pattern"
        echo "  Current .gitignore:"
        sed 's/^/    /' "$gi"
        return 1
    fi
}

# #B15 — a commented-out pattern is respected (user bypass, test is the
# existing one at test_vault_save_aborts_on_cco_remotes). Here we also
# assert that _ensure_vault_gitignore does NOT re-add it.
test_vault_ensure_gitignore_respects_commented_pattern() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    local gi="$CCO_USER_CONFIG_DIR/.gitignore"
    sed -i 's|^\.cco/remotes$|# .cco/remotes|' "$gi"
    git -C "$CCO_USER_CONFIG_DIR" add .gitignore
    git -C "$CCO_USER_CONFIG_DIR" commit -q -m "test: user commented a pattern"

    run_cco vault status >/dev/null

    local occurrences
    occurrences=$(grep -cE '^[#[:space:]]*\.cco/remotes$' "$gi" || true)
    if [[ "$occurrences" -ne 1 ]]; then
        echo "ASSERTION FAILED: self-heal should not duplicate a commented pattern"
        echo "  Occurrences of .cco/remotes in .gitignore: $occurrences"
        sed 's/^/    /' "$gi"
        return 1
    fi
}

# #B16 — _clean_branch_ghost_projects removes project directories that
# contain only gitignored leftover (nothing tracked on HEAD). This is
# the exact post-switch scenario: git checkout removed the departing
# branch's tracked files, but gitignored content (claude-state, meta)
# kept the parent dir visible.
test_clean_branch_ghost_projects_removes_untracked_dirs() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    # A legit project with tracked content — must NOT be removed.
    local legit="$CCO_USER_CONFIG_DIR/projects/legitproj"
    mkdir -p "$legit"
    echo "name: legitproj" > "$legit/project.yml"
    git -C "$CCO_USER_CONFIG_DIR" add "projects/legitproj/project.yml"
    git -C "$CCO_USER_CONFIG_DIR" commit -q -m "test: add legitproj"
    mkdir -p "$legit/.cco/claude-state"
    echo "transcript" > "$legit/.cco/claude-state/session.jsonl"

    # Simulate leftover of a project NOT tracked on HEAD — gitignored
    # content only. The helper should wipe it.
    local ghost="$CCO_USER_CONFIG_DIR/projects/ghostproj"
    mkdir -p "$ghost/.cco/claude-state"
    echo "transcript" > "$ghost/.cco/claude-state/session.jsonl"
    echo "schema_version: 1" > "$ghost/.cco/meta"

    # Call the helper directly (same API the switch flow uses).
    ( export USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR"
      source "$REPO_ROOT/lib/colors.sh"
      source "$REPO_ROOT/lib/utils.sh"
      source "$REPO_ROOT/lib/yaml.sh"
      source "$REPO_ROOT/lib/cmd-vault.sh"
      _clean_branch_ghost_projects "$CCO_USER_CONFIG_DIR" )

    if [[ -d "$ghost" ]]; then
        echo "ASSERTION FAILED: ghost project directory was not cleaned"
        find "$ghost" | sed 's/^/    /'
        return 1
    fi
    if [[ ! -d "$legit" ]]; then
        echo "ASSERTION FAILED: legit (tracked) project directory was wrongly removed"
        return 1
    fi
    if [[ ! -f "$legit/.cco/claude-state/session.jsonl" ]]; then
        echo "ASSERTION FAILED: gitignored content of a tracked project was removed"
        return 1
    fi
}

# #B16b — _clean_branch_ghost_projects prunes orphan shadow dirs in
# .cco/profile-state/<name>/ when <name> is not a local git branch.
test_clean_branch_ghost_projects_prunes_orphan_shadows() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _setup_vault "$tmpdir"

    # Use whatever branch git initialized (main or master depending on config)
    local default_branch
    default_branch=$(git -C "$CCO_USER_CONFIG_DIR" rev-parse --abbrev-ref HEAD)
    local live="$CCO_USER_CONFIG_DIR/.cco/profile-state/$default_branch"
    mkdir -p "$live/projects/foo"
    echo "x" > "$live/projects/foo/secrets.env"

    local orphan="$CCO_USER_CONFIG_DIR/.cco/profile-state/deadbranch"
    mkdir -p "$orphan/projects/bar"
    echo "x" > "$orphan/projects/bar/.env"

    ( export USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR"
      source "$REPO_ROOT/lib/colors.sh"
      source "$REPO_ROOT/lib/utils.sh"
      source "$REPO_ROOT/lib/yaml.sh"
      source "$REPO_ROOT/lib/cmd-vault.sh"
      _clean_branch_ghost_projects "$CCO_USER_CONFIG_DIR" )

    if [[ ! -d "$live" ]]; then
        echo "ASSERTION FAILED: shadow for existing branch was wrongly pruned"
        return 1
    fi
    if [[ -d "$orphan" ]]; then
        echo "ASSERTION FAILED: orphan shadow (deadbranch) was not pruned"
        return 1
    fi
}

# #B17 — cco start must refuse to launch if any repo / mount remains
# @local after resolution (no silent skip that would yield empty mounts).
test_start_asserts_resolved_paths() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create a project whose repo is @local with no local-paths.yml entry.
    mkdir -p "$CCO_USER_CONFIG_DIR/projects/broken"
    cat > "$CCO_USER_CONFIG_DIR/projects/broken/project.yml" <<'YAML'
name: broken
repos:
  - path: "@local"
    name: broken
YAML

    # Non-TTY start: must die, not silently succeed.
    if run_cco start broken --dry-run 2>/dev/null; then
        echo "ASSERTION FAILED: start should have failed on unresolved @local"
        return 1
    fi
}

# #B18 — _path_exists / _resolve_entry accept file mounts (not only dirs).
test_resolve_entry_accepts_file_mount() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco init --lang "English"

    # Create a project with a file extra_mount already mapped via
    # local-paths.yml.
    local proj="$CCO_USER_CONFIG_DIR/projects/filemount"
    mkdir -p "$proj/.cco"
    cat > "$proj/project.yml" <<'YAML'
name: filemount
repos:
  - path: "@local"
    name: filemount
extra_mounts:
  - source: "@local"
    target: /workspace/doc.md
    readonly: true
YAML
    local sample_file="$tmpdir/doc.md"
    echo "sample" > "$sample_file"
    local repo_dir="$tmpdir/repo"
    mkdir -p "$repo_dir"
    cat > "$proj/.cco/local-paths.yml" <<YAML
repos:
  filemount: "$repo_dir"
extra_mounts:
  /workspace/doc.md: "$sample_file"
YAML

    # _project_effective_paths must resolve both entries to "exists".
    local out
    out=$(source "$REPO_ROOT/lib/colors.sh"
          source "$REPO_ROOT/lib/utils.sh"
          source "$REPO_ROOT/lib/yaml.sh"
          source "$REPO_ROOT/lib/local-paths.sh"
          _project_effective_paths "$proj")
    if ! grep -qE $'^mounts\t/workspace/doc\\.md\t'"$sample_file"$'\texists$' <<< "$out"; then
        echo "ASSERTION FAILED: file mount was not reported as exists"
        echo "  _project_effective_paths output:"
        echo "$out" | sed 's/^/    /'
        return 1
    fi
}
