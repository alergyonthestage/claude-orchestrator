#!/usr/bin/env bash
# tests/test_update_check.sh — `cco update --check` (ADR-0022 D6). Read-only
# upstream-update discovery: DATA `source`-driven, install-presence-gated, the
# 3-state contract (not-installed-here / comparable / indeterminate), one
# greppable line per resource, exit 0 ALWAYS. Packs + templates only — projects
# ride their code-repo remote (P13 / cli.md §3.16).

# A single-pack bare sharing repo; echoes the bare path (use as the install url).
_uc_pack_repo() {
    local tmpdir="$1" name="$2"
    local work="$tmpdir/uc-work-$name" bare="$tmpdir/uc-$name.git"
    mkdir -p "$work/agents"
    printf 'name: %s\ndescription: "p"\nagents:\n  - h.md\n' "$name" > "$work/pack.yml"
    printf 'Helper\n' > "$work/agents/h.md"
    git init --bare -q "$bare"
    git -C "$work" init -q
    git -C "$work" add -A
    git -C "$work" commit -q -m initial
    git -C "$work" remote add origin "$bare"
    git -C "$work" push -q origin main 2>/dev/null || git -C "$work" push -q origin master 2>/dev/null
    echo "$bare"
}

# Push one more commit to <bare> so its HEAD advances past any installed commit.
_uc_advance() {
    local bare="$1" w; w=$(mktemp -d)
    git clone -q "$bare" "$w"
    echo "more" > "$w/NEW.md"
    git -C "$w" add -A
    git -C "$w" commit -q -m advance
    git -C "$w" push -q origin HEAD
    rm -rf "$w"
}

# Run cco capturing rc + CCO_OUTPUT (never let a non-zero abort the test).
_uc_cco() {
    local rc=0
    CCO_OUTPUT=$(bash "$REPO_ROOT/bin/cco" "$@" 2>&1) || rc=$?
    return $rc
}

# ── empty / no installs ──────────────────────────────────────────────────

test_update_check_no_installs() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local rc=0
    _uc_cco update --check || rc=$?
    assert_equals 0 "$rc"
    assert_output_contains "No installed packs/templates"
}

# ── comparable: up to date ───────────────────────────────────────────────

test_update_check_pack_up_to_date() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local bare; bare=$(_uc_pack_repo "$tmpdir" upd)
    _uc_cco pack install "$bare"
    local rc=0
    _uc_cco update --check --no-cache || rc=$?
    assert_equals 0 "$rc"
    assert_output_contains "pack.upd: up to date"
}

# ── comparable: update available ─────────────────────────────────────────

test_update_check_pack_update_available() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local bare; bare=$(_uc_pack_repo "$tmpdir" adv)
    _uc_cco pack install "$bare"
    _uc_advance "$bare"          # upstream moves past the installed commit
    local rc=0
    _uc_cco update --check --no-cache || rc=$?
    assert_equals 0 "$rc"
    assert_output_contains "pack.adv: update available"
    assert_output_contains "1 update(s)"
}

# ── url: local snapshot is skipped (no upstream) ─────────────────────────

test_update_check_skips_local_snapshot() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    # A pack whose DATA source is a local snapshot (internalized/imported).
    mkdir -p "$CCO_PACKS_DIR/snap" "$CCO_DATA_HOME/packs/snap" "$CCO_STATE_HOME/packs/snap/update/base"
    printf 'name: snap\n' > "$CCO_PACKS_DIR/snap/pack.yml"
    printf 'url: local\n' > "$CCO_DATA_HOME/packs/snap/source"
    local rc=0
    _uc_cco update --check || rc=$?
    assert_equals 0 "$rc"
    assert_output_not_contains "pack.snap"
    assert_output_contains "No installed packs/templates"
}

# ── not installed here: DATA source synced, no local install/base ────────

test_update_check_not_installed_here() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    # Simulate a freshly-synced 2nd PC: DATA source present, but no STATE base.
    mkdir -p "$CCO_DATA_HOME/packs/ghost"
    printf 'url: https://example.com/x.git\nref: main\n' > "$CCO_DATA_HOME/packs/ghost/source"
    local rc=0
    _uc_cco update --check || rc=$?
    assert_equals 0 "$rc"
    assert_output_contains "pack.ghost: not installed here"
    assert_output_contains "1 not-installed-here"
}

# ── --offline → comparable becomes indeterminate, still exit 0 ───────────

test_update_check_offline_is_indeterminate() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local bare; bare=$(_uc_pack_repo "$tmpdir" off)
    _uc_cco pack install "$bare"
    local rc=0
    _uc_cco update --check --offline || rc=$?
    assert_equals 0 "$rc"
    assert_output_contains "pack.off: indeterminate (offline)"
}

# ── templates are in scope (comparable via the P5-5a installed_commit) ────

test_update_check_template_comparable() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco template create tcheck --project
    local bare="$tmpdir/tbare.git"; git init --bare -q "$bare"
    run_cco remote add tr "$bare"
    run_cco template publish tcheck tr
    run_cco template remove tcheck
    run_cco template install "$bare" --pick tcheck
    local rc=0
    _uc_cco update --check --no-cache || rc=$?
    assert_equals 0 "$rc"
    assert_output_contains "template.tcheck: up to date"
}

# ── help ─────────────────────────────────────────────────────────────────

test_update_check_help_lists_check() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco update --help
    assert_output_contains "--check"
}
