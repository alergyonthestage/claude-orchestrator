#!/usr/bin/env bash
# tests/test_start_decentralized.sh — decentralized `cco start` read-path + D-start
# source-selection (design §4.4, ADR-0017 D2 / 0024 D3; P3-1a/P3-1b).
#
# cco start reads <repo>/.cco/ resolved three ways (cwd-first / by-name via the
# STATE index / --from), prints a source-transparency line, and treats an
# unresolved member as a conscious skip (exclude from mounts + ⚠ badge, never a
# silent empty mount, never a hard block — P14).

# ── Source transparency ───────────────────────────────────────────────

test_start_by_name_prints_source_transparency() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump
    assert_output_contains "started test-proj from test-proj"
    assert_output_contains "[source: name]"
}

test_start_from_repo_selects_source() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    # --from names the host repo explicitly (mirrors `cco sync --from`).
    run_cco start "test-proj" --from "test-proj" --dry-run --dump
    assert_output_contains "[source: --from]"
}

test_start_from_unknown_repo_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    if run_cco start "test-proj" --from "ghost-repo" --dry-run 2>/dev/null; then
        fail "Expected --from on an unresolved repo to fail"
    fi
    assert_output_contains "unresolved"
}

# ── cwd-first resolution (no project name) ────────────────────────────

test_start_cwd_first_resolves_hosted_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    # From inside the host repo, `cco start` (no name) resolves the hosted project.
    local host; host="$(dirname "$(host_cco_dir "$tmpdir" test-proj)")"
    local prev; prev="$(pwd)"
    cd "$host" || return 1
    run_cco start --dry-run --dump
    cd "$prev" || return 1
    assert_output_contains "started test-proj from test-proj"
    assert_output_contains "[source: cwd]"
}

test_start_no_name_outside_repo_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    # A directory with no .cco/project.yml in it or any parent.
    local empty="$tmpdir/empty"; mkdir -p "$empty"
    local prev; prev="$(pwd)"
    cd "$empty" || return 1
    local rc=0
    run_cco start --dry-run 2>/dev/null || rc=$?
    cd "$prev" || return 1
    [[ $rc -ne 0 ]] || fail "Expected cco start with no name outside a repo to fail"
    assert_output_contains "No .cco/project.yml"
}

# ── Conscious-skip: unresolved member excluded + ⚠ badge (never silent) ─

test_start_unresolved_member_excluded_and_badged() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    # Two members: dummy-repo (seeded, resolves) + ghost-repo (never seeded).
    create_project "$tmpdir" "test-proj" "$(printf 'name: test-proj\nrepos:\n  - name: dummy-repo\n  - name: ghost-repo\n')"
    run_cco start "test-proj" --dry-run --dump
    # Non-TTY unresolved member -> warned + excluded, never a hard block.
    assert_output_contains "ghost-repo"
    assert_output_contains "1 reference(s) unresolved"
    # The resolved member is mounted; the unresolved one is NOT (no empty mount).
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_contains "$compose" ":/workspace/dummy-repo"
    if grep -qE ":/workspace/ghost-repo" "$compose"; then
        fail "Unresolved member ghost-repo must not be mounted"
    fi
    if grep -qE "^\s*- \"?:/workspace/" "$compose"; then
        fail "No silent empty mount (#B17) may be emitted"
    fi
}

test_start_all_resolved_no_badge() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump
    if echo "${CCO_OUTPUT:-}" | grep -qF "reference(s) unresolved"; then
        fail "No ⚠ badge expected when every member resolves"
    fi
}
