#!/usr/bin/env bash
# tests/test_decentralized_cutover.sh — the P3 legacy-cutover invariants on the
# decentralized runtime (vault removed): memory is machine-local STATE (no
# auto-commit, ADR-0009), a project's committed config is path-free / truthful
# (AD3/G8, no @local sanitize at start), and multiple projects coexist without
# cross-contamination (ADR-0024).

# ── Memory is STATE (ADR-0009) ────────────────────────────────────────

test_memory_is_state_not_committed() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    # Auto-memory is mounted from the machine-local STATE session dir, never from
    # the committed config tree.
    assert_file_contains "$compose" "/session/memory:/home/claude/.claude/projects/-workspace/memory"
    # The committed <repo>/.cco/ must NOT carry a memory/ dir (it is STATE, evicted).
    if [[ -d "$(host_cco_dir "$tmpdir" test-proj)/memory" ]]; then
        fail "memory/ must not live in the committed <repo>/.cco/ (it is machine-local STATE)"
    fi
}

test_no_vault_memory_autocommit_machinery() {
    # D33/D32 (vault memory auto-commit + .gitkeep) are removed with the vault.
    if grep -rqE "_auto_resolve_framework_changes|_restore_missing_gitkeep" "$REPO_ROOT/lib/" 2>/dev/null; then
        fail "vault memory auto-commit machinery (D33/D32) must be gone"
    fi
    # And the vault command itself is gone.
    if [[ -f "$REPO_ROOT/lib/cmd-vault.sh" ]]; then
        fail "lib/cmd-vault.sh must be deleted (P3 legacy cutover)"
    fi
}

test_vault_command_removed() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    if run_cco vault status 2>/dev/null; then
        fail "'cco vault' must no longer be a recognized command"
    fi
}

# ── Truthful diff: committed config is path-free (AD3/G8) ──────────────

test_start_does_not_write_real_path_into_committed_yml() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    local yml; yml="$(host_cco_dir "$tmpdir" test-proj)/project.yml"
    local before; before=$(cat "$yml")
    run_cco start "test-proj" --dry-run --dump
    local after; after=$(cat "$yml")
    # `cco start` resolves member paths into the STATE index, NEVER into the
    # committed project.yml — so the committed config stays byte-identical and
    # machine-agnostic (no @local sanitize needed).
    [[ "$before" == "$after" ]] || fail "cco start must not rewrite the committed project.yml"
    # And the committed project.yml carries no absolute machine path.
    if grep -qE "$tmpdir|/home/|/Users/" "$yml"; then
        fail "committed project.yml must be path-free (AD3/G8)"
    fi
}

# ── Multi-project coexistence (ADR-0024) ──────────────────────────────

test_two_projects_coexist_distinct_compose() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "proj-a" "$(minimal_project_yml proj-a)"
    create_project "$tmpdir" "proj-b" "$(minimal_project_yml proj-b)"

    run_cco start "proj-a" --dry-run --dump
    local ca="$DRY_RUN_DIR/.cco/docker-compose.yml"
    local compose_a; compose_a=$(cat "$ca")

    run_cco start "proj-b" --dry-run --dump
    local cb="$DRY_RUN_DIR/.cco/docker-compose.yml"
    local compose_b; compose_b=$(cat "$cb")

    echo "$compose_a" | grep -q "container_name: cc-proj-a" || fail "proj-a container name wrong"
    echo "$compose_b" | grep -q "container_name: cc-proj-b" || fail "proj-b container name wrong"
    # Per-project STATE is keyed by id — no cross-leak.
    echo "$compose_a" | grep -q "projects/proj-a/session" || fail "proj-a STATE path missing"
    if echo "$compose_a" | grep -q "projects/proj-b/session"; then
        fail "proj-a must not reference proj-b's STATE (no cross-leak)"
    fi
}

test_two_projects_independent_tags() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "proj-a" "$(minimal_project_yml proj-a)"
    create_project "$tmpdir" "proj-b" "$(minimal_project_yml proj-b)"
    run_cco tag add proj-a alpha
    run_cco tag add proj-b beta
    run_cco list --tag alpha
    assert_output_contains "proj-a"
    if echo "${CCO_OUTPUT:-}" | grep -qF "proj-b"; then
        fail "tag 'alpha' must not match proj-b"
    fi
}
