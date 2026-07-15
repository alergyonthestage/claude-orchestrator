#!/usr/bin/env bash
# tests/test_start_local_settings.sh — functional-write floor seeding (ADR-0049 §5)
#
# Focus: _emit_local_settings_overlay()'s SEEDING side effects, which the
# dry-run compose tests (test_access_resolution.sh) cannot see — they assert the
# emitted YAML line, and seeding is skipped on dry-run by design.
#
# That blind spot shipped a broken `cco start`: the floor bound a rw STATE copy
# onto <tree>/.claude/settings.local.json but never created the MOUNTPOINT, so
# runc had to mknod it inside the :ro parent bind and the container failed to
# start ("read-only file system"). The compose YAML was correct throughout, so
# the suite stayed green. These tests pin the side effects instead.

_ls_test_env() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/cmd-start.sh"
}

# The regression: an absent mountpoint must be seeded, or Docker cannot bind the
# child over the :ro parent and the whole session fails to start.
test_local_settings_seeds_absent_mountpoint() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _ls_test_env
    mkdir -p "$tmpdir/claude"
    local mp="$tmpdir/claude/settings.local.json"
    local src="$tmpdir/state/local-settings/workspace.json"

    _emit_local_settings_overlay "$src" "$mp" "/workspace/.claude/settings.local.json" "false" >/dev/null

    [[ -f "$mp" ]]  || fail "mountpoint stub not seeded — Docker cannot mknod it inside the :ro parent"
    [[ -f "$src" ]] || fail "STATE source not seeded"
}

# The stub is inert but must still be valid JSON: it is what Claude Code would
# read on the HOST (outside any session), where no STATE bind shadows it.
test_local_settings_stub_is_valid_json() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _ls_test_env
    mkdir -p "$tmpdir/claude"
    local mp="$tmpdir/claude/settings.local.json"

    _emit_local_settings_overlay "$tmpdir/state/ls.json" "$mp" "/workspace/.claude/settings.local.json" "false" >/dev/null

    [[ "$(tr -d '[:space:]' < "$mp")" == "{}" ]] || fail "stub should be an empty JSON object, got: $(cat "$mp")"
}

# A tree that already carries real local prefs (a repo whose .claude/settings.local.json
# predates the overlay) must not have them shadowed by an empty {} on first start:
# STATE is seeded FROM the mountpoint.
test_local_settings_state_seeded_from_existing_mountpoint() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _ls_test_env
    mkdir -p "$tmpdir/claude"
    local mp="$tmpdir/claude/settings.local.json"
    local src="$tmpdir/state/local-settings/repo-x.json"
    printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$mp"

    _emit_local_settings_overlay "$src" "$mp" "/workspace/x/.claude/settings.local.json" "false" >/dev/null

    grep -q 'Bash(ls:\*)' "$src" || fail "existing local prefs must survive into STATE, got: $(cat "$src")"
    grep -q 'Bash(ls:\*)' "$mp" || fail "an existing mountpoint must never be overwritten"
}

# Once STATE exists it is the live copy: a later start must not clobber it from
# the (frozen) stub.
test_local_settings_existing_state_wins() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _ls_test_env
    mkdir -p "$tmpdir/claude" "$tmpdir/state/local-settings"
    local mp="$tmpdir/claude/settings.local.json"
    local src="$tmpdir/state/local-settings/workspace.json"
    printf '{}\n' > "$mp"
    printf '{"live":"state"}\n' > "$src"

    _emit_local_settings_overlay "$src" "$mp" "/workspace/.claude/settings.local.json" "false" >/dev/null

    grep -q '"live"' "$src" || fail "existing STATE must not be reseeded from the stub"
}

# Dry-run dumps a compose that is never executed — it must touch nothing.
test_local_settings_dry_run_seeds_nothing() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _ls_test_env
    mkdir -p "$tmpdir/claude"
    local mp="$tmpdir/claude/settings.local.json"
    local src="$tmpdir/state/local-settings/workspace.json"

    local out
    out=$(_emit_local_settings_overlay "$src" "$mp" "/workspace/.claude/settings.local.json" "true")

    [[ ! -e "$mp" ]]  || fail "dry-run must not seed the mountpoint"
    [[ ! -e "$src" ]] || fail "dry-run must not seed STATE"
    echo "$out" | grep -q 'settings\.local\.json' || fail "dry-run must still emit the compose line"
}

# The emitted bind stays rw (no :ro suffix) — the whole point of the floor.
test_local_settings_bind_is_rw() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _ls_test_env
    mkdir -p "$tmpdir/claude"

    local out
    out=$(_emit_local_settings_overlay "$tmpdir/state/ls.json" "$tmpdir/claude/settings.local.json" \
            "/workspace/.claude/settings.local.json" "false")

    echo "$out" | grep -qE ':/workspace/\.claude/settings\.local\.json"$' \
        || fail "bind must end at the target with no mode suffix (rw), got: $out"
}
