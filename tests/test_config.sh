#!/usr/bin/env bash
# tests/test_config.sh — `cco config save/push/pull` : version + sync ~/.cco
# (Domain A, design §6.1, ADR-0008/0017 D4; P3-2b). Allowlist double-barrier
# (whitelist .gitignore + explicit staging, never `git add -A`), 2-pass secret
# scan (*.example exempt), explicit manual commits, non-FF pull aborts.

# Seed ~/.cco with authored config + a real secret (gitignored) + a skeleton.
_seed_config_store() {
    mkdir -p "$HOME/.cco/.claude" "$HOME/.cco/packs/p1" "$HOME/.cco/templates/t1"
    echo "# global"         > "$HOME/.cco/.claude/CLAUDE.md"
    echo "name: p1"         > "$HOME/.cco/packs/p1/pack.yml"
    echo "name: t1"         > "$HOME/.cco/templates/t1/template.yml"
    echo "TOKEN=realvalue"  > "$HOME/.cco/secrets.env"
    echo "TOKEN="           > "$HOME/.cco/secrets.env.example"
}

test_config_save_commits_allowlist_only() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _seed_config_store
    run_cco config save -m "initial"
    assert_output_contains "saved ~/.cco"
    local files; files=$(git -C "$HOME/.cco" ls-files)
    echo "$files" | grep -qF ".claude/CLAUDE.md" || fail "global config not committed"
    echo "$files" | grep -qF "packs/p1/pack.yml"        || fail "pack not committed"
    echo "$files" | grep -qF "secrets.env.example"      || fail "skeleton not committed"
    # The real secret must NEVER be committed.
    if echo "$files" | grep -qx "secrets.env"; then
        fail "secrets.env must never be committed"
    fi
}

test_config_save_ignores_non_allowlisted() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _seed_config_store
    # A stray file outside the allowlist must not be staged (no `git add -A`).
    echo "junk" > "$HOME/.cco/scratch.txt"
    run_cco config save -m "initial"
    if git -C "$HOME/.cco" ls-files | grep -qF "scratch.txt"; then
        fail "non-allowlisted scratch.txt must not be committed (never git add -A)"
    fi
}

test_config_save_nothing_to_save() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _seed_config_store
    run_cco config save -m "initial"
    run_cco config save
    assert_output_contains "already up to date"
}

test_config_save_blocks_secret_content() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _seed_config_store
    run_cco config save -m "initial"
    # A leaked credential inside a tracked config file must block the save.
    echo "api_key=sk-ant-0123456789abcdef0123" >> "$HOME/.cco/.claude/CLAUDE.md"
    if run_cco config save -m "leak" 2>/dev/null; then
        fail "save must abort when a secret is staged"
    fi
    assert_output_contains "refusing to save"
}

test_config_save_example_exempt() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    mkdir -p "$HOME/.cco/.claude"
    echo "# global" > "$HOME/.cco/.claude/CLAUDE.md"
    # A secret-like value in a *.example skeleton is EXEMPT (FR-S3) — must commit.
    printf 'TOKEN=sk-ant-0123456789abcdef0123\n' > "$HOME/.cco/secrets.env.example"
    run_cco config save -m "with skeleton"
    assert_output_contains "saved ~/.cco"
    git -C "$HOME/.cco" ls-files | grep -qF "secrets.env.example" || fail "skeleton should be committed"
}

test_config_push_no_remote_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _seed_config_store
    run_cco config save -m "initial"
    if run_cco config push 2>/dev/null; then
        fail "push without a remote must fail"
    fi
    assert_output_contains "no remote configured"
}

test_config_push_advisory_warning() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _seed_config_store
    run_cco config save -m "initial"
    git init --bare -q "$tmpdir/remote.git"
    git -C "$HOME/.cco" remote add origin "$tmpdir/remote.git"
    run_cco config push
    assert_output_contains "PRIVATE remote"
    assert_output_contains "pushed ~/.cco"
}

test_config_pull_non_ff_aborts() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _seed_config_store
    run_cco config save -m "initial"
    git init --bare -q "$tmpdir/remote.git"
    git -C "$HOME/.cco" remote add origin "$tmpdir/remote.git"
    run_cco config push
    # Diverge: a different commit lands on the remote while local also moves on.
    local clone="$tmpdir/clone"
    git clone -q "$tmpdir/remote.git" "$clone"
    echo "remote change" >> "$clone/.claude/CLAUDE.md"
    git -C "$clone" add -A && git -C "$clone" commit -q -m "remote edit"
    git -C "$clone" push -q origin HEAD:master 2>/dev/null || git -C "$clone" push -q origin HEAD 2>/dev/null
    echo "local change" >> "$HOME/.cco/.claude/CLAUDE.md"
    run_cco config save -m "local edit"
    if run_cco config pull 2>/dev/null; then
        fail "non-fast-forward pull must abort"
    fi
    assert_output_contains "not a fast-forward"
}
