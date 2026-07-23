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
    mkdir -p "$(state_shared)/packs/ghost-spack/update/base"
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
    assert_dir_exists "$(state_shared)/packs/ghost-spack"
    assert_dir_exists "$CCO_DATA_HOME/packs/ghost-dpack"
    assert_file_contains "$(cco_index_file)" "ghost-repo:"
}

test_config_validate_dry_run_no_change() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _cv_seed_orphans "$tmpdir"
    run_cco config validate --dry-run
    assert_output_contains "Found"
    assert_dir_exists "$(state_shared)/packs/ghost-spack"
}

test_config_validate_fix_prunes_with_yes() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _cv_seed_orphans "$tmpdir"

    run_cco config validate --fix -y
    assert_output_contains "Pruned"
    assert_output_contains "propagates to your other machines"   # DATA second-confirm warning

    # Machine-local orphans pruned.
    assert_dir_not_exists "$(state_shared)/packs/ghost-spack"
    assert_dir_not_exists "$CCO_CACHE_HOME/projects/ghost-cproj"
    assert_file_not_contains "$(cco_index_file)" "ghost-repo:"
    assert_file_not_contains "$(cco_index_file)" "ghost-proj:"
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

# M5 (26-06-2026 migration review): a half-migrated project (memory present but not
# yet index-registered) is detected as an orphan whose label warns it holds migrated
# memory, so the user does not blindly prune it.
test_config_validate_warns_on_orphan_with_memory() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    mkdir -p "$CCO_STATE_HOME/projects/halfmig/session/memory"
    echo "important note" > "$CCO_STATE_HOME/projects/halfmig/session/memory/note.md"
    run_cco config validate
    assert_output_contains "STATE project 'halfmig'"
    assert_output_contains "contains migrated memory"
}

test_config_validate_fix_dies_without_confirmation() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _cv_seed_orphans "$tmpdir"

    # --fix without -y, non-interactive stdin → ADR-0029 D2: DIE (non-zero exit),
    # preserve everything.
    local rc=0
    run_cco config validate --fix </dev/null || rc=$?
    [[ "$rc" -ne 0 ]] || fail "expected non-interactive --fix without -y to exit non-zero"
    assert_output_contains "re-run with -y"
    assert_dir_exists "$(state_shared)/packs/ghost-spack"
    assert_dir_exists "$CCO_DATA_HOME/packs/ghost-dpack"
}

# ── WS-5 — malformed index lane (ADR-0052 §5, FI-22) ─────────────────
# A non-absolute index value is MALFORMED, not an orphan: reported in its own lane
# and NEVER pruned (format repair is the user's call). A genuine (absolute, missing)
# orphan next to it must still be pruned by --fix.
_cv_unscoped_get() { ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"; source "$REPO_ROOT/lib/paths.sh"; source "$REPO_ROOT/lib/index.sh"; _index_section_get unscoped "$1" ); }
_cv_pp_get()       { ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"; source "$REPO_ROOT/lib/paths.sh"; source "$REPO_ROOT/lib/index.sh"; _index_pp_get "$1" "$2" ); }

test_config_validate_malformed_reported_never_pruned() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    # Hand-write the index: the API rejects non-absolute writes, so a malformed
    # value can only arrive via a stale spelling or a hand-edit. `weird` is
    # malformed (non-absolute); `goodmissing` is a genuine orphan (absolute, gone).
    cat > "$(cco_index_file)" <<IDX
version: 2
projects:
project_paths:
  app:
    weird: "relative/not-abs"
    goodmissing: "$tmpdir/does-not-exist"
llms:
unscoped:
IDX
    run_cco config validate
    assert_output_contains "malformed index record"
    assert_output_contains "weird"
    assert_output_contains "goodmissing"          # the orphan is reported too

    # --fix prunes the orphan, NEVER the malformed record.
    run_cco config validate --fix -y
    assert_file_not_contains "$(cco_index_file)" "goodmissing"
    assert_file_contains "$(cco_index_file)" "weird"
    [[ "$(_cv_pp_get app weird)" == "relative/not-abs" ]] || fail "malformed record must survive --fix, got: $(_cv_pp_get app weird)"

    # A re-validate still reports it (flag-on-read, never pruned).
    run_cco config validate
    assert_output_contains "malformed index record"
    assert_output_contains "weird"
}

# ── WS-4 — FI-23 residue re-home via config validate --fix (ADR-0052 §4) ──
# An extra_mount a project declares but the index parks in unscoped: is a mis-scoped
# residue (a pre-WS-4 migration). It is its OWN lane — a re-home MOVES the binding,
# it is not an orphan prune — and --fix re-homes it under the declaring project.
test_config_validate_fi23_residue_rehomed() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo="$tmpdir/repos/appx-repo"
    mkdir -p "$repo/.cco/claude" "$tmpdir/assets-dir"
    cat > "$repo/.cco/project.yml" <<'YML'
name: appx
repos:
  - name: app-repo
extra_mounts:
  - name: assets
    target: /workspace/assets
YML
    seed_index_path "app-repo" "$repo" "appx"
    index_set_project_repos "appx" "app-repo"
    seed_index_path "assets" "$tmpdir/assets-dir"     # parked unscoped (the residue)

    # Report: surfaced as a re-home, not an orphan; not pruned without --fix.
    run_cco config validate
    assert_output_contains "mis-scoped extra_mount"
    assert_output_contains "assets"
    assert_output_not_contains "orphaned internal"    # a re-home is not an orphan
    [[ "$(_cv_unscoped_get assets)" == "$tmpdir/assets-dir" ]] || fail "report mode must not move the binding"

    # --fix re-homes it under appx and clears unscoped.
    run_cco config validate --fix -y
    assert_output_contains "Re-homed"
    [[ "$(_cv_pp_get appx assets)" == "$tmpdir/assets-dir" ]] || fail "assets not re-homed under appx, got: $(_cv_pp_get appx assets)"
    [[ -z "$(_cv_unscoped_get assets)" ]] || fail "assets must be cleared from unscoped, got: $(_cv_unscoped_get assets)"

    # Idempotent: the residue is gone, so a re-validate no longer flags it.
    run_cco config validate
    assert_output_not_contains "mis-scoped extra_mount"
}
