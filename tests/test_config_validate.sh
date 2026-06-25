#!/usr/bin/env bash
# tests/test_config_validate.sh — `cco config validate` orphan sanitization
# (ADR-0021 Dec.5). Detects id-keyed internal bookkeeping with no resolvable
# resource across the four buckets; --fix prunes preview-first + confirmed,
# STATE/CACHE under the main confirm and synced DATA under a second one. Never
# automatic; the read-only report exits 0 (reminder-style, ADR-0008/0019).

# Seed one orphan in each detected class (5 machine-local + 2 synced DATA).
_cv_seed_orphans() {
    local tmpdir="$1"
    # local: index path whose target dir is gone + a project with no resolvable member
    seed_index_path "ghost-repo" "$tmpdir/gone-repo"
    index_set_project_repos "ghost-proj" "ghost-repo"
    # local: STATE per-id dir for a pack that no longer exists in ~/.cco/packs
    mkdir -p "$CCO_STATE_HOME/packs/ghost-spack/update/base"
    # local: CACHE per-id dir for an untracked project
    mkdir -p "$CCO_CACHE_HOME/projects/ghost-cproj/managed"
    # local: STATE remote token with no DATA url registry entry
    mkdir -p "$CCO_STATE_HOME"
    printf 'ghost-remote=tok123\n' > "$CCO_STATE_HOME/remotes-token"
    # data: tags.yml binding for a pack that no longer exists
    mkdir -p "$CCO_DATA_HOME"
    printf 'packs:\n  ghost-tpack: [work]\n' > "$CCO_DATA_HOME/tags.yml"
    # data: install-provenance dir for a pack that no longer exists
    mkdir -p "$CCO_DATA_HOME/packs/ghost-dpack"
    printf 'url: https://example.com/x\n' > "$CCO_DATA_HOME/packs/ghost-dpack/source"
}

test_config_validate_clean_reports_nothing() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco config validate
    assert_output_contains "No orphaned internal state"
}

test_config_validate_detects_all_buckets_read_only() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _cv_seed_orphans "$tmpdir"

    run_cco config validate
    assert_output_contains "Found"
    assert_output_contains "ghost-repo"
    assert_output_contains "ghost-proj"
    assert_output_contains "STATE pack 'ghost-spack'"
    assert_output_contains "CACHE project 'ghost-cproj'"
    assert_output_contains "remote token 'ghost-remote'"
    assert_output_contains "DATA tag packs/ghost-tpack"
    assert_output_contains "DATA source pack 'ghost-dpack'"

    # Read-only: nothing is touched without --fix.
    assert_dir_exists "$CCO_STATE_HOME/packs/ghost-spack"
    assert_dir_exists "$CCO_DATA_HOME/packs/ghost-dpack"
    assert_file_contains "$CCO_STATE_HOME/index" "ghost-repo:"
}

test_config_validate_dry_run_no_change() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _cv_seed_orphans "$tmpdir"
    run_cco config validate --dry-run
    assert_output_contains "Found"
    assert_dir_exists "$CCO_STATE_HOME/packs/ghost-spack"
}

test_config_validate_fix_prunes_with_yes() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _cv_seed_orphans "$tmpdir"

    run_cco config validate --fix -y
    assert_output_contains "Pruned"
    assert_output_contains "propagates to your other machines"   # DATA second-confirm warning

    # Machine-local orphans pruned.
    assert_dir_not_exists "$CCO_STATE_HOME/packs/ghost-spack"
    assert_dir_not_exists "$CCO_CACHE_HOME/projects/ghost-cproj"
    assert_file_not_contains "$CCO_STATE_HOME/index" "ghost-repo:"
    assert_file_not_contains "$CCO_STATE_HOME/index" "ghost-proj:"
    if grep -q "^ghost-remote=" "$CCO_STATE_HOME/remotes-token" 2>/dev/null; then
        fail "orphan token should be pruned"
    fi
    # Synced DATA orphans pruned.
    assert_dir_not_exists "$CCO_DATA_HOME/packs/ghost-dpack"
    if grep -q "ghost-tpack" "$CCO_DATA_HOME/tags.yml" 2>/dev/null; then
        fail "orphan tag should be pruned"
    fi

    # Idempotent — a second run finds nothing.
    run_cco config validate
    assert_output_contains "No orphaned internal state"
}

test_config_validate_fix_skips_without_confirmation() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _cv_seed_orphans "$tmpdir"

    # --fix without -y, non-interactive stdin → refuse, preserve everything.
    run_cco config validate --fix </dev/null || true
    assert_output_contains "Non-interactive"
    assert_dir_exists "$CCO_STATE_HOME/packs/ghost-spack"
    assert_dir_exists "$CCO_DATA_HOME/packs/ghost-dpack"
}
