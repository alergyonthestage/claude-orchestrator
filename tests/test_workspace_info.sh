#!/usr/bin/env bash
# tests/test_workspace_info.sh — R1 unified session-info surface (ADR-0041)
#
# Covers the additions that fold packs.md into workspace.yml: the gated
# `path_map` section (governed by show_host_paths), the SessionStart /
# SubagentStart hook rendering of the knowledge + llms sections, and the
# guarantee that no packs.md is ever emitted (net cut — R1-D4).

# ── path_map (show_host_paths knob) ──────────────────────────────────────

test_path_map_present_by_default() {
    # show_host_paths defaults to on → path_map is emitted with labelled pairs
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump
    local ws="$DRY_RUN_DIR/.claude/workspace.yml"
    assert_file_contains "$ws" "path_map:"
    assert_file_contains "$ws" "host: $CCO_DUMMY_REPO"
    assert_file_contains "$ws" "target: /workspace/dummy-repo"
    assert_file_contains "$ws" "readonly: false"
}

test_path_map_absent_when_off() {
    # --no-show-host-paths → no path_map section (security-conscious setups)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump --no-show-host-paths
    local ws="$DRY_RUN_DIR/.claude/workspace.yml"
    if grep -q '^path_map:' "$ws"; then
        echo "ASSERTION FAILED: path_map must be absent when show_host_paths=off"
        return 1
    fi
}

test_path_map_toggle_via_flag() {
    # Explicit --show-host-paths re-enables it
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump --show-host-paths
    assert_file_contains "$DRY_RUN_DIR/.claude/workspace.yml" "path_map:"
}

# ── No packs.md is ever emitted (net cut — R1-D4) ────────────────────────

test_no_packs_md_ever_emitted() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local pack_src="$CCO_PACKS_DIR/k-pack/knowledge"
    mkdir -p "$pack_src"
    create_pack "$tmpdir" "k-pack" "$(printf 'name: k-pack\nknowledge:\n  source: %s\n  files:\n    - overview.md\n' "$pack_src")"
    echo "# Overview" > "$pack_src/overview.md"
    create_project "$tmpdir" "test-proj" "$(printf 'name: test-proj\nrepos:\n  - name: dummy-repo\npacks:\n  - k-pack\n')"
    run_cco start "test-proj" --dry-run --dump
    assert_file_not_exists "$DRY_RUN_DIR/.claude/packs.md"
}

# ── Hook rendering (session-context.sh / subagent-context.sh) ─────────────

# Write a fixture workspace.yml and return its path.
_ws_fixture() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/workspace.yml" <<'YAML'
project: demo
repos:
  - name: app
    path: /workspace/app
    description: "The app"
packs:
  - my-pack
knowledge:
  - path: /workspace/.claude/packs/my-pack/overview.md
    description: "Read for overview"
  - path: /workspace/.claude/packs/my-pack/notes.md
    description: ""
llms:
  - path: /workspace/.claude/llms/react/llms-full.txt
    description: "React (1234 lines)"
path_map:
  - host: /Users/me/app
    target: /workspace/app
    readonly: false
YAML
    echo "$dir/workspace.yml"
}

test_session_hook_renders_knowledge_and_llms() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local ws; ws=$(_ws_fixture "$tmpdir")
    local out
    out=$(CCO_WORKSPACE_YML="$ws" bash "$REPO_ROOT/config/hooks/session-context.sh")
    local ctx
    ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext')
    echo "$ctx" | grep -q "Read the relevant files BEFORE starting" \
        || fail "knowledge preamble should be rendered by the hook"
    echo "$ctx" | grep -q "/workspace/.claude/packs/my-pack/overview.md — Read for overview" \
        || fail "knowledge entry with description should render 'path — desc'"
    echo "$ctx" | grep -q "^- /workspace/.claude/packs/my-pack/notes.md$" \
        || fail "knowledge entry without description should render path only"
    echo "$ctx" | grep -q "Official Framework Documentation" \
        || fail "llms preamble should be rendered by the hook"
    echo "$ctx" | grep -q "/workspace/.claude/llms/react/llms-full.txt — React (1234 lines)" \
        || fail "llms entry should render 'path — desc'"
}

test_session_hook_no_knowledge_when_section_absent() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    mkdir -p "$tmpdir/wsonly"
    printf 'project: demo\nrepos:\n  - name: app\n    path: /workspace/app\n' \
        > "$tmpdir/wsonly/workspace.yml"
    local out ctx
    out=$(CCO_WORKSPACE_YML="$tmpdir/wsonly/workspace.yml" bash "$REPO_ROOT/config/hooks/session-context.sh")
    ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext')
    if echo "$ctx" | grep -q "Read the relevant files BEFORE starting"; then
        echo "ASSERTION FAILED: no knowledge preamble should render without a knowledge section"
        return 1
    fi
}

test_subagent_hook_lists_knowledge_and_llms_paths() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local ws; ws=$(_ws_fixture "$tmpdir")
    local out ctx
    out=$(CCO_WORKSPACE_YML="$ws" bash "$REPO_ROOT/config/hooks/subagent-context.sh")
    ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext')
    echo "$ctx" | grep -q "Knowledge packs (read before implementation tasks):" \
        || fail "subagent hook should render the knowledge header"
    echo "$ctx" | grep -q "^- /workspace/.claude/packs/my-pack/overview.md$" \
        || fail "subagent hook should list knowledge paths (no descriptions)"
    echo "$ctx" | grep -q "^- /workspace/.claude/llms/react/llms-full.txt$" \
        || fail "subagent hook should list llms paths"
    # Descriptions must NOT appear in the condensed subagent context
    if echo "$ctx" | grep -q "Read for overview"; then
        echo "ASSERTION FAILED: subagent context must not carry descriptions"
        return 1
    fi
}
