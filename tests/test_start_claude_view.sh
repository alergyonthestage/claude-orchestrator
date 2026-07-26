#!/usr/bin/env bash
# tests/test_start_claude_view.sh — framework-owned mountpoints (ADR-0054, INV-MP)
#
# Focus: the composed /workspace/.claude parent that replaces ADR-0005 F3's
# dropped "parent stays rw" precondition.
#
# The regression it pins (FI-31): pack/llms children are bound at
# /workspace/.claude/{packs,llms,rules,agents,skills}/…, but under the ADR-0049
# default the parent is the committed tree mounted :ro — runc must create the
# mountpoint THROUGH that read-only bind and fails with EROFS, so `cco start`
# dies before the session exists. The compose YAML was correct throughout, which
# is why the dry-run suite stayed green; these tests assert both halves — the
# emitted parent AND the host-side mountpoints the dry run cannot see.

_cv_test_env() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/cmd-start.sh"
}

# A committed tree with one file per shape + the injected lines a pack would emit.
# Sets: CV_SRC (committed tree), CV_VIEW (the CACHE view), CV_PACK (pack root).
_cv_fixture() {
    local root="$1"
    CV_SRC="$root/claude"; CV_VIEW="$root/view"; CV_PACK="$root/pack"
    mkdir -p "$CV_SRC/rules" "$CV_SRC/agents" "$CV_SRC/skills" "$CV_VIEW"
    mkdir -p "$CV_PACK/rules" "$CV_PACK/skills/deploy" "$CV_PACK/knowledge"
    echo "# project" > "$CV_SRC/CLAUDE.md"
    echo "# mine"    > "$CV_SRC/rules/mine.md"
    echo "# packrule" > "$CV_PACK/rules/testing.md"
    echo "# skill"    > "$CV_PACK/skills/deploy/SKILL.md"
    echo "# know"     > "$CV_PACK/knowledge/doc.md"
    CV_INJECTED=$(printf '%s\n%s\n%s\n' \
        "      \"# Pack resources\"" \
        "      - \"$CV_PACK/rules/testing.md:/workspace/.claude/rules/testing.md:ro\"" \
        "      - \"$CV_PACK/skills/deploy:/workspace/.claude/skills/deploy:ro\"")
}

# THE regression: with an injected child the parent must be the framework-owned
# view, never the committed tree — that is what makes the mountpoint creatable.
test_claude_view_parent_is_the_view_not_the_committed_tree() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _cv_test_env; _cv_fixture "$tmpdir"

    local out; out=$(_emit_claude_view "$CV_VIEW" "$CV_SRC" "ro" "$CV_INJECTED" "false")

    echo "$out" | grep -q "\"$CV_VIEW:/workspace/.claude:ro\"" \
        || fail "the view must be the /workspace/.claude parent, got:"$'\n'"$out"
    echo "$out" | grep -q "\"$CV_SRC:/workspace/.claude:" \
        && fail "the committed tree must NOT be the parent while composing"
    return 0
}

# The mountpoints themselves — the half a dry-run assertion can never see.
# Shape follows the source: a skill dir needs a dir, a rule file needs a file.
test_claude_view_materializes_mountpoints() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _cv_test_env; _cv_fixture "$tmpdir"

    _emit_claude_view "$CV_VIEW" "$CV_SRC" "ro" "$CV_INJECTED" "false" >/dev/null

    [[ -d "$CV_VIEW/skills/deploy" ]] \
        || fail "skill mountpoint missing — runc would EROFS on the :ro parent"
    [[ -f "$CV_VIEW/rules/testing.md" ]] \
        || fail "rule mountpoint missing (must be a FILE for a file bind)"
    [[ ! -s "$CV_VIEW/rules/testing.md" ]] \
        || fail "a mountpoint stub must stay empty — it carries no content"
}

# The committed tree is bound back in, so nothing the project authored is lost.
test_claude_view_binds_committed_entries_back() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _cv_test_env; _cv_fixture "$tmpdir"

    local out; out=$(_emit_claude_view "$CV_VIEW" "$CV_SRC" "ro" "$CV_INJECTED" "false")

    echo "$out" | grep -q "\"$CV_SRC/CLAUDE.md:/workspace/.claude/CLAUDE.md:ro\"" \
        || fail "committed CLAUDE.md must still reach the session, got:"$'\n'"$out"
    # rules/ received an injection, so it is owned by the view and its committed
    # files are bound one by one (a whole-dir bind would re-create the EROFS trap).
    echo "$out" | grep -q "\"$CV_SRC/rules/mine.md:/workspace/.claude/rules/mine.md:ro\"" \
        || fail "an injected namespace must be bound per file, got:"$'\n'"$out"
    echo "$out" | grep -q "\"$CV_SRC/rules:/workspace/.claude/rules:" \
        && fail "an injected namespace must NOT be bound as a whole directory"
    return 0
}

# A namespace with no injection keeps its cheap whole-directory bind.
test_claude_view_untouched_namespace_binds_whole() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _cv_test_env; _cv_fixture "$tmpdir"
    echo "# a" > "$CV_SRC/agents/mine.md"

    local out; out=$(_emit_claude_view "$CV_VIEW" "$CV_SRC" "ro" "$CV_INJECTED" "false")

    echo "$out" | grep -q "\"$CV_SRC/agents:/workspace/.claude/agents:ro\"" \
        || fail "agents/ receives no injection — it must stay a whole-dir bind, got:"$'\n'"$out"
}

# ADR-0005 F2: a pack overlay wins over a committed file of the same path. Two
# binds on one target would be a duplicate compose mount, so the committed one
# is dropped — the precedence is unchanged, it is just explicit now.
test_claude_view_pack_wins_over_committed_file() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _cv_test_env; _cv_fixture "$tmpdir"
    echo "# committed" > "$CV_SRC/rules/testing.md"   # same name as the pack's

    local out n
    out=$(_emit_claude_view "$CV_VIEW" "$CV_SRC" "ro" "$CV_INJECTED" "false")
    n=$(echo "$out" | grep -c ":/workspace/.claude/rules/testing.md:" | tr -d ' ')

    # Positive half first, so the absence below cannot pass by the loop never running.
    echo "$out" | grep -q "\"$CV_SRC/rules/mine.md:/workspace/.claude/rules/mine.md:ro\"" \
        || fail "the namespace loop must still bind the non-colliding committed file, got:"$'\n'"$out"
    [[ "$n" == "0" ]] || fail "the committed file must not be re-bound (the pack line owns that target), got $n bind(s):"$'\n'"$out"
}

# Dry-run is a pure projection: it must never touch the host.
test_claude_view_dry_run_creates_nothing() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _cv_test_env; _cv_fixture "$tmpdir"

    local out; out=$(_emit_claude_view "$CV_VIEW" "$CV_SRC" "ro" "$CV_INJECTED" "true")

    # Positive half first: the projection must still be COMPLETE on dry-run —
    # otherwise "nothing was created" would also pass with nothing emitted.
    echo "$out" | grep -q "\"$CV_VIEW:/workspace/.claude:ro\"" \
        || fail "dry-run must still emit the composed parent, got:"$'\n'"$out"
    [[ -z "$(ls -A "$CV_VIEW" 2>/dev/null)" ]] \
        || fail "dry-run seeded the view: $(ls -A "$CV_VIEW")"
}

# D3: the parent follows the policy, it is never rw by fiat — a rw parent would
# let the agent create files that silently land in CACHE.
test_claude_view_parent_mode_follows_policy() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _cv_test_env; _cv_fixture "$tmpdir"

    local out; out=$(_emit_claude_view "$CV_VIEW" "$CV_SRC" "" "$CV_INJECTED" "false")

    echo "$out" | grep -q "\"$CV_VIEW:/workspace/.claude\"" \
        || fail "Cp=rw must bind the parent rw (no :ro suffix), got:"$'\n'"$out"
}

# ── Full flow (dry-run compose) ──────────────────────────────────────

# End-to-end shape of the FI-31 fix: a pack shipping a skill, at the DEFAULT
# access level, must produce a composed parent + the skill child — and must not
# write a single byte into the committed tree.
test_claude_view_compose_uses_view_when_pack_ships_skills() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_pack "$tmpdir" "s-pack" "$(printf 'name: s-pack\nskills:\n  - deploy\n')"
    mkdir -p "$CCO_PACKS_DIR/s-pack/skills/deploy"
    echo "# deploy" > "$CCO_PACKS_DIR/s-pack/skills/deploy/SKILL.md"
    create_project "$tmpdir" "test-proj" "$(printf 'name: test-proj\nrepos:\n  - name: dummy-repo\npacks:\n  - s-pack\n')"

    run_cco start "test-proj" --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"

    assert_file_contains "$compose" "claude-view:/workspace/.claude:ro" || return 1
    assert_file_contains "$compose" "/workspace/.claude/skills/deploy:ro" || return 1
    # The committed tree must stay pristine — no mountpoint residue (ADR-0005 F1).
    assert_file_not_exists "$(host_cco_dir "$tmpdir" test-proj)/claude/skills/deploy"
}

# No injection → no composition. The majority path stays exactly as it was.
test_claude_view_absent_without_injected_children() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(printf 'name: test-proj\nrepos:\n  - name: dummy-repo\n')"

    run_cco start "test-proj" --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"

    grep -q "claude-view:/workspace/.claude" "$compose" \
        && fail "a project with no packs/llms must keep the plain whole-tree bind"
    assert_file_contains "$compose" "/claude:/workspace/.claude:ro"
}
