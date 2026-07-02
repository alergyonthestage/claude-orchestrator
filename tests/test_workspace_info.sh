#!/usr/bin/env bash
# tests/test_workspace_info.sh — Level A injected session context (ADR-0042)
#
# The former workspace.yml file is retired: cco start computes the session
# context host-side and injects it as the CCO_SESSION_CONTEXT / CCO_SUBAGENT_CONTEXT
# env vars (base64) in the generated docker-compose.yml. The SessionStart /
# SubagentStart hooks decode and append it. These tests cover: the injected block
# content (resources, knowledge, llms, gated path_map), the guarantee that NO
# workspace.yml / packs.md file is emitted anywhere (INV-2), and the hook
# pass-through + in-container discovery merge.

# ── Injected context content (host-side builder, via dry-run) ─────────────

test_session_context_lists_resources_and_knowledge() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local pack_src="$CCO_PACKS_DIR/k-pack/knowledge"; mkdir -p "$pack_src"
    create_pack "$tmpdir" "k-pack" "$(printf 'name: k-pack\nknowledge:\n  source: %s\n  files:\n    - overview.md\n' "$pack_src")"
    echo "# Overview" > "$pack_src/overview.md"
    create_project "$tmpdir" "test-proj" "$(printf 'name: test-proj\nrepos:\n  - name: dummy-repo\n    description: The dummy repo\npacks:\n  - k-pack\n')"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --dry-run --dump
    local ctx; ctx=$(decode_session_context "$DRY_RUN_DIR/.cco/docker-compose.yml")
    echo "$ctx" | grep -q "<CcoSessionInfo>" || fail "injected context should be present"
    echo "$ctx" | grep -q -- "- repo: dummy-repo at /workspace/dummy-repo — The dummy repo" \
        || fail "repo with project.yml description should render 'repo: name at path — desc'"
    echo "$ctx" | grep -q -- "- pack: k-pack" || fail "pack should be listed"
    echo "$ctx" | grep -q "Read the relevant files BEFORE" || fail "knowledge preamble expected"
    echo "$ctx" | grep -q -- "- /workspace/.claude/packs/k-pack/overview.md" \
        || fail "knowledge path should be listed"
}

# Descriptions are single-sourced in project.yml (INV-3): a repo without a
# description renders path-only, no round-trip.
test_session_context_repo_without_description() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --dry-run --dump
    local ctx; ctx=$(decode_session_context "$DRY_RUN_DIR/.cco/docker-compose.yml")
    echo "$ctx" | grep -qE -- "- repo: dummy-repo at /workspace/dummy-repo$" \
        || fail "repo without description should render path only, got: $ctx"
}

# extra_mounts[].description (INV-3, project.yml single source) flows into the
# context keyed by the mount's effective target; an undescribed mount renders
# target-only.
test_session_context_extra_mount_description() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local specs="$tmpdir/specs" plain="$tmpdir/plain"
    mkdir -p "$specs" "$plain"
    seed_index_path "specs" "$specs"
    seed_index_path "plain" "$plain"
    create_project "$tmpdir" "test-proj" "$(printf 'name: test-proj\nrepos:\n  - name: dummy-repo\nextra_mounts:\n  - name: specs\n    target: /workspace/docs/api-specs\n    readonly: true\n    description: OpenAPI specs\n  - name: plain\n')"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --dry-run --dump
    local ctx; ctx=$(decode_session_context "$DRY_RUN_DIR/.cco/docker-compose.yml")
    echo "$ctx" | grep -q -- "- mount: /workspace/docs/api-specs (read-only) — OpenAPI specs" \
        || fail "extra_mount with description should render 'mount: target (read-only) — desc', got: $ctx"
    # The undescribed mount (default target /workspace/plain) renders target-only.
    echo "$ctx" | grep -qE -- "- mount: /workspace/plain( \(read-only\))?$" \
        || fail "extra_mount without description should render target only, got: $ctx"
}

# The wrapped-cco access declaration reflects the resolved scope (ADR-0042).
test_session_context_declares_wrapped_cco_scope() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --dry-run --dump   # normal default: read-project
    local ctx; ctx=$(decode_session_context "$DRY_RUN_DIR/.cco/docker-compose.yml")
    echo "$ctx" | grep -q "access scope: read-project" \
        || fail "context should declare the wrapped-cco access scope, got: $ctx"
    # ADR-0043 §5: at read-project the context carries the project-scoped-view
    # awareness (hidden ≠ absent).
    echo "$ctx" | grep -q "PROJECT-SCOPED view" \
        || fail "read-project context should carry the project-scoped-view awareness, got: $ctx"
    # With cco_access=none there is no wrapped cco → no declaration.
    run_cco start "test-proj" --cco-access none --dry-run --dump
    ctx=$(decode_session_context "$DRY_RUN_DIR/.cco/docker-compose.yml")
    if echo "$ctx" | grep -q "wrapped \`cco\`"; then
        fail "no wrapped-cco declaration should appear under cco-access none"
    fi
    # At read-global the whole store is visible → no project-scoped-view line.
    run_cco start "test-proj" --cco-access read-global --dry-run --dump
    ctx=$(decode_session_context "$DRY_RUN_DIR/.cco/docker-compose.yml")
    echo "$ctx" | grep -q "access scope: read-global" \
        || fail "context should declare read-global scope, got: $ctx"
    if echo "$ctx" | grep -q "PROJECT-SCOPED view"; then
        fail "read-global context must NOT carry the project-scoped-view awareness"
    fi
}

# ── path_map (show_host_paths knob) ──────────────────────────────────────

test_path_map_present_by_default() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump
    local ctx; ctx=$(decode_session_context "$DRY_RUN_DIR/.cco/docker-compose.yml")
    echo "$ctx" | grep -q "Host<->container path map" || fail "path map section expected by default"
    echo "$ctx" | grep -q -- "$CCO_DUMMY_REPO -> /workspace/dummy-repo" \
        || fail "path map should carry the labelled host->container pair, got: $ctx"
}

test_path_map_absent_when_off() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump --no-show-host-paths
    local ctx; ctx=$(decode_session_context "$DRY_RUN_DIR/.cco/docker-compose.yml")
    if echo "$ctx" | grep -q "Host<->container path map"; then
        echo "ASSERTION FAILED: path_map must be absent when show_host_paths=off"
        return 1
    fi
}

test_path_map_toggle_via_flag() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump --show-host-paths
    local ctx; ctx=$(decode_session_context "$DRY_RUN_DIR/.cco/docker-compose.yml")
    echo "$ctx" | grep -q "Host<->container path map" || fail "explicit --show-host-paths should re-enable path_map"
}

# ── No generated session-info file is ever emitted (INV-2) ────────────────

test_no_workspace_yml_or_packs_md_emitted() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local pack_src="$CCO_PACKS_DIR/k-pack/knowledge"; mkdir -p "$pack_src"
    create_pack "$tmpdir" "k-pack" "$(printf 'name: k-pack\nknowledge:\n  source: %s\n  files:\n    - overview.md\n' "$pack_src")"
    echo "# Overview" > "$pack_src/overview.md"
    create_project "$tmpdir" "test-proj" "$(printf 'name: test-proj\nrepos:\n  - name: dummy-repo\npacks:\n  - k-pack\n')"
    run_cco start "test-proj" --dry-run --dump
    assert_file_not_exists "$DRY_RUN_DIR/.claude/workspace.yml"
    assert_file_not_exists "$DRY_RUN_DIR/.claude/packs.md"
    # No workspace.yml :ro overlay in the generated compose either.
    if grep -q "workspace.yml" "$DRY_RUN_DIR/.cco/docker-compose.yml"; then
        echo "ASSERTION FAILED: compose must not mount a workspace.yml overlay"
        return 1
    fi
}

# ── Hook pass-through + in-container discovery merge ──────────────────────

# A fixture Level-A block, base64-encoded as cco start would inject it.
_ctx_fixture_b64() {
    printf '%s' '<CcoSessionInfo>
Project resources:
- repo: app at /workspace/app — The app
Knowledge files (project conventions). Read the relevant files BEFORE starting tasks.
- /workspace/.claude/packs/my-pack/overview.md — Read for overview
Official Framework Documentation (llms.txt). Consult these BEFORE writing code.
- /workspace/.claude/llms/react/llms-full.txt — React (1234 lines)
</CcoSessionInfo>' | base64 | tr -d '\n'
}

test_session_hook_injects_decoded_context() {
    local out ctx
    out=$(CCO_SESSION_CONTEXT="$(_ctx_fixture_b64)" bash "$REPO_ROOT/config/hooks/session-context.sh")
    ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext')
    echo "$ctx" | grep -q "<CcoSessionInfo>" || fail "hook should append the decoded session context"
    echo "$ctx" | grep -q "Read the relevant files BEFORE starting" \
        || fail "knowledge preamble from the injected block should appear"
    echo "$ctx" | grep -q "/workspace/.claude/packs/my-pack/overview.md — Read for overview" \
        || fail "knowledge entry with description should render"
    echo "$ctx" | grep -q "/workspace/.claude/llms/react/llms-full.txt — React (1234 lines)" \
        || fail "llms entry should render"
    # In-container discovery is still emitted (merged), not replaced.
    echo "$ctx" | grep -q "<SessionContext>" || fail "hook should keep its in-container discovery block"
}

test_session_hook_no_injection_when_env_absent() {
    local out ctx
    out=$(env -u CCO_SESSION_CONTEXT bash "$REPO_ROOT/config/hooks/session-context.sh")
    ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext')
    if echo "$ctx" | grep -q "<CcoSessionInfo>"; then
        echo "ASSERTION FAILED: no injected block should appear without CCO_SESSION_CONTEXT"
        return 1
    fi
    # The hook still emits its own discovery block (never crashes).
    echo "$ctx" | grep -q "<SessionContext>" || fail "hook should still emit its discovery block"
}

test_subagent_hook_injects_condensed_paths() {
    local sub_b64 out ctx
    sub_b64=$(printf '%s' '<CcoSubagentInfo>
Knowledge & framework docs (read the relevant ones before implementation tasks):
- /workspace/.claude/packs/my-pack/overview.md
- /workspace/.claude/llms/react/llms-full.txt
</CcoSubagentInfo>' | base64 | tr -d '\n')
    out=$(CCO_SUBAGENT_CONTEXT="$sub_b64" bash "$REPO_ROOT/config/hooks/subagent-context.sh")
    ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext')
    echo "$ctx" | grep -q "<CcoSubagentInfo>" || fail "subagent hook should append the condensed block"
    echo "$ctx" | grep -q "^- /workspace/.claude/packs/my-pack/overview.md$" \
        || fail "subagent hook should list knowledge paths"
    echo "$ctx" | grep -q "^- /workspace/.claude/llms/react/llms-full.txt$" \
        || fail "subagent hook should list llms paths"
    echo "$ctx" | grep -q "<SubagentContext>" || fail "subagent hook should keep its own context block"
}
