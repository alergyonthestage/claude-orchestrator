#!/usr/bin/env bash
# tests/test_forget.sh — `cco forget <project>` deregistration (ADR-0021 Dec.2/3).
# Removes id-keyed internal state (index/STATE/DATA/CACHE/tags) WITHOUT touching
# the repo or its committed .cco/; the index self-heals via cwd-first + scan.

# Seed a project's id-keyed internal state, as if installed/started/tagged.
_forget_seed_state() {
    local name="$1"
    mkdir -p "$CCO_STATE_HOME/projects/$name/update/base"
    printf 'schema_version: 1\n' > "$(state_project_meta "$name")"
    mkdir -p "$(dirname "$(data_project_source "$name")")"
    printf 'url: https://example.com/repo\n' > "$(data_project_source "$name")"
    mkdir -p "$(cache_project_managed "$name")"
    run_cco tag add "$name" work
}

test_forget_deregisters_internal_state() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "doomed" "$(minimal_project_yml doomed)"
    _forget_seed_state "doomed"

    run_cco forget doomed -y
    assert_output_contains "Forgot project 'doomed'"

    # Index entries gone (membership + path).
    assert_file_not_contains "$CCO_STATE_HOME/index" "doomed:"
    # STATE/DATA/CACHE dirs gone.
    assert_dir_not_exists "$CCO_STATE_HOME/projects/doomed"
    assert_dir_not_exists "$CCO_DATA_HOME/projects/doomed"
    assert_dir_not_exists "$CCO_CACHE_HOME/projects/doomed"
    # Tag binding gone.
    run_cco list --tag work
    if echo "${CCO_OUTPUT:-}" | grep -qF "doomed"; then
        fail "tag binding for doomed should be gone after forget"
    fi
}

test_forget_leaves_repo_untouched() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "keepme" "$(minimal_project_yml keepme)"
    local host; host="$(host_cco_dir "$tmpdir" keepme)"
    assert_file_exists "$host/project.yml"

    run_cco forget keepme -y

    # The repo and its committed config are never touched.
    assert_file_exists "$host/project.yml"
    assert_dir_exists "$host/claude"
}

test_forget_self_heals_on_resolve_scan() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    # A self-referencing single-repo project (the repo dir basename matches its
    # own coordinate name) so `resolve --scan` can re-bind it from project.yml.
    create_project "$tmpdir" "phoenix" "$(cat <<'YAML'
name: phoenix
repos:
  - name: phoenix
    url: https://example.com/phoenix.git
YAML
)"

    run_cco forget phoenix -y
    assert_file_not_contains "$CCO_STATE_HOME/index" "phoenix:"

    # The still-valid project.yml re-registers on the next scan (ADR-0021 Dec.3).
    run_cco resolve --scan "$tmpdir/repos"
    run_cco path list
    assert_output_contains "phoenix"
}

test_forget_shared_repo_guard() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    # proj-a owns "solo" alone and shares "shared" with proj-b. Under per-project
    # scoping (ADR-0051) each project carries its OWN binding for a shared repo, so
    # "shared" is seeded under both projects (same path); forget proj-a drops only
    # proj-a's block, leaving proj-b's "shared" binding intact.
    seed_index_path "solo"   "$tmpdir/repos/solo"   "proj-a"
    seed_index_path "shared" "$tmpdir/repos/shared" "proj-a"
    seed_index_path "shared" "$tmpdir/repos/shared" "proj-b"
    seed_index_path "proj-b" "$tmpdir/repos/proj-b" "proj-b"
    index_set_project_repos "proj-a" "solo" "shared"
    index_set_project_repos "proj-b" "proj-b" "shared"

    run_cco forget proj-a -y

    # solo (only proj-a) is dropped; shared (also proj-b) is kept.
    assert_file_not_contains "$CCO_STATE_HOME/index" 'solo:'
    assert_file_contains     "$CCO_STATE_HOME/index" 'shared:'
    # proj-a membership gone; proj-b intact.
    assert_file_not_contains "$CCO_STATE_HOME/index" 'proj-a:'
    assert_file_contains     "$CCO_STATE_HOME/index" 'proj-b:'
}

test_forget_not_tracked_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    if run_cco forget ghost -y 2>/dev/null; then
        fail "forget of an untracked project should fail"
    fi
    assert_output_contains "not tracked"
}

test_forget_non_tty_requires_confirmation() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "proj-x" "$(minimal_project_yml proj-x)"

    # No -y and non-interactive stdin → must refuse and preserve state.
    run_cco forget proj-x </dev/null || true
    assert_file_contains "$CCO_STATE_HOME/index" "proj-x:"
}

# ── --purge: ownership-guarded .cco/ deletion (ADR-0021 D2 fwd-annot) ────

test_forget_purge_deletes_owned_cco_with_backup() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "doomed" "$(minimal_project_yml doomed)"
    local host; host="$(host_cco_dir "$tmpdir" doomed)"   # …/repos/doomed/.cco
    assert_dir_exists "$host"

    run_cco forget doomed --purge -y
    assert_output_contains "Deleted"

    # Owned .cco/ is gone, a backup tar was written into STATE, index deregistered.
    assert_dir_not_exists "$host"
    local backups; backups=$(find "$CCO_STATE_HOME/backups" -name 'forget-doomed-*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')
    [[ "$backups" -ge 1 ]] || fail "expected a backup tar for the purged .cco/, found none"
    assert_file_not_contains "$CCO_STATE_HOME/index" "doomed:"
}

test_forget_purge_preserves_foreign_member() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    # Project alpha owns alpha-repo and references shared-repo, which HOSTS a
    # different project (beta) → foreign for alpha → must never be purged.
    create_project "$tmpdir" "alpha" "$(minimal_project_yml alpha)"
    local shared="$tmpdir/repos/shared-repo"
    mkdir -p "$shared/.cco/claude"
    printf 'name: beta\nrepos:\n  - name: shared-repo\n' > "$shared/.cco/project.yml"
    seed_index_path "shared-repo" "$shared"
    index_set_project_repos "alpha" "alpha" "shared-repo"

    run_cco forget alpha --purge -y

    # alpha's own .cco/ deleted; the foreign repo's .cco/ untouched.
    assert_dir_not_exists "$(host_cco_dir "$tmpdir" alpha)"
    assert_file_exists "$shared/.cco/project.yml"
}

test_forget_purge_non_tty_without_flag_skips_deletion() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "keepcfg" "$(minimal_project_yml keepcfg)"
    local host; host="$(host_cco_dir "$tmpdir" keepcfg)"

    # Non-interactive, base consent via -y but NO --purge → deregister but never
    # delete the committed .cco/ (the opt-in purge stage stays unattended-safe).
    run_cco forget keepcfg -y </dev/null
    assert_dir_exists "$host"
    assert_file_not_contains "$CCO_STATE_HOME/index" "keepcfg:"
    [[ ! -d "$CCO_STATE_HOME/backups" ]] || {
        local n; n=$(find "$CCO_STATE_HOME/backups" -name 'forget-keepcfg-*' 2>/dev/null | wc -l | tr -d ' ')
        [[ "$n" -eq 0 ]] || fail "no backup should be written when purge is skipped"
    }
}
