#!/usr/bin/env bash
# tests/test_index_reconcile.sh — non-destructive legacy-location reconcile
# (ADR-0052 §2, WS-2; closes N1 + N2).
#
# _index_reconcile_legacy_location merges a legacy index at <state>/cco/index (the
# pre-017 location) into the v2 file at <state>/cco/shared/index, NEVER clobbering.
# Cases: legacy absent → no-op; legacy-only → relocate; both present → per-key
# MERGE (adopt-missing / skip-agree / conflict → keep both non-interactively).
# The S1 lesson applies to BOTH files: an existing-but-unreadable one dies honestly
# rather than being mistaken for empty and lost.

# Each test runs in its own bin/test subshell, so these exports do not leak.
_rec_env() {
    export CCO_ALLOW_HOST_RESOLVE=1
    export CCO_STATE_HOME="$1"
    unset XDG_STATE_HOME CCO_DATA_HOME CCO_CACHE_HOME CCO_CONTAINER_OPERATOR
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/index.sh"
}

_rec_legacy_file() { printf '%s' "$CCO_STATE_HOME/index"; }
_rec_new_file()    { printf '%s' "$CCO_STATE_HOME/shared/index"; }

_rec_write_legacy_v1() {  # $1=name $2=path $3=project (membership)
    local f; f=$(_rec_legacy_file); mkdir -p "$(dirname "$f")"
    cat > "$f" <<IDX
version: 1
paths:
  $1: "$2"
projects:
  $3: "$1"
IDX
}

_rec_write_new_v2() {  # $1=project $2=name $3=path
    local f; f=$(_rec_new_file); mkdir -p "$(dirname "$f")"
    cat > "$f" <<IDX
version: 2
projects:
  $1: "$2"
project_paths:
  $1:
    $2: "$3"
llms:
unscoped:
IDX
}

# ── legacy-only → relocate (the benign mv case) ──────────────────────
test_reconcile_legacy_only_relocates() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _rec_env "$tmp/state"
    _rec_write_legacy_v1 repo /abs/repo app

    _index_reconcile_legacy_location false || fail "reconcile returned non-zero"

    [[ -f "$(_rec_new_file)" ]] || fail "the new index must exist after a relocate"
    [[ -e "$(_rec_legacy_file)" ]] && fail "the legacy index must be gone after a relocate"
    # Content survived: the relocated file still resolves the binding (v1 read).
    [[ "$(_index_get_path app repo)" == "/abs/repo" ]] || fail "relocated binding lost, got: $(_index_get_path app repo)"
    # A defensive .bak was left.
    [[ -f "$(_rec_legacy_file).bak" ]] || fail "a defensive .bak of the legacy index must be written"
}

# ── both present, disjoint entries → union (N1: no data loss) ─────────
test_reconcile_both_disjoint_unions() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _rec_env "$tmp/state"
    _rec_write_legacy_v1 repoA /abs/repoA app     # legacy binds app/repoA
    _rec_write_new_v2 app repoB /abs/repoB        # new binds app/repoB

    _index_reconcile_legacy_location false || fail "reconcile returned non-zero"

    [[ "$(_index_pp_get app repoA)" == "/abs/repoA" ]] || fail "legacy-only binding not adopted, got: $(_index_pp_get app repoA)"
    [[ "$(_index_pp_get app repoB)" == "/abs/repoB" ]] || fail "existing binding lost, got: $(_index_pp_get app repoB)"
    [[ -e "$(_rec_legacy_file)" ]] && fail "legacy must be removed after a fully-resolved merge"
    return 0
}

# ── both present, same path → deduped (skip, no duplicate) ────────────
test_reconcile_both_same_path_dedupes() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _rec_env "$tmp/state"
    _rec_write_legacy_v1 repo /abs/repo app
    _rec_write_new_v2 app repo /abs/repo          # identical binding on both sides

    _index_reconcile_legacy_location false || fail "reconcile returned non-zero"

    [[ "$(_index_pp_get app repo)" == "/abs/repo" ]] || fail "agreed binding altered, got: $(_index_pp_get app repo)"
    local n; n=$(_index_pp_dump_project app | grep -c '^repo=')
    [[ "$n" -eq 1 ]] || fail "expected exactly one repo binding after dedup, got: $n"
    [[ -e "$(_rec_legacy_file)" ]] && fail "legacy must be removed after an agreeing merge"
    return 0
}

# ── both present, path conflict, non-interactive → keep both + warn ───
test_reconcile_conflict_noninteractive_keeps_both() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _rec_env "$tmp/state"
    _rec_write_legacy_v1 repo /abs/legacy app
    _rec_write_new_v2 app repo /abs/current       # SAME key, DIFFERENT path

    local out; out=$(_index_reconcile_legacy_location false 2>&1) || fail "reconcile must not fail on a conflict"

    # Current binding is untouched; legacy file is preserved for a later resolution.
    [[ "$(_index_pp_get app repo)" == "/abs/current" ]] || fail "conflict must not overwrite the current binding, got: $(_index_pp_get app repo)"
    [[ -f "$(_rec_legacy_file)" ]] || fail "an unresolved conflict must KEEP the legacy file (non-destructive)"
    printf '%s' "$out" | grep -qi "differ" || fail "a conflict must be surfaced with a warning, got: $out"
}

# ── idempotent: a second run after a clean merge is a no-op ───────────
test_reconcile_idempotent_second_run() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _rec_env "$tmp/state"
    _rec_write_legacy_v1 repoA /abs/repoA app
    _rec_write_new_v2 app repoB /abs/repoB

    _index_reconcile_legacy_location false || fail "first reconcile failed"
    local before; before=$(cat "$(_rec_new_file)")
    _index_reconcile_legacy_location false || fail "second reconcile failed"
    local after; after=$(cat "$(_rec_new_file)")
    [[ "$before" == "$after" ]] || fail "a second reconcile (legacy gone) must be a no-op"
}

# ── S1 lesson: an unreadable legacy dies honestly, legacy untouched ───
# chmod 000 is bypassed as root, so skip there (same convention as test_index.sh).
test_reconcile_unreadable_legacy_dies_honestly() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    _rec_env "$tmp/state"
    _rec_write_legacy_v1 repo /abs/repo app
    _rec_write_new_v2 app other /abs/other
    chmod 000 "$(_rec_legacy_file)"               # legacy exists but cannot be opened

    local rc=0
    ( _index_reconcile_legacy_location false ) >/dev/null 2>&1 || rc=$?
    chmod 700 "$(_rec_legacy_file)" 2>/dev/null || true
    [[ "$rc" -eq 1 ]] || fail "an unreadable legacy index must die (exit 1), got rc=$rc"
    # It must NOT have been deleted or merged-away — nothing was proven about it.
    [[ -f "$(_rec_legacy_file)" ]] || fail "an unreadable legacy must never be removed"
    [[ "$(_index_pp_get app other)" == "/abs/other" ]] || fail "the current index must be untouched on an honest die"
}

# ── a v2 legacy (develop-era, old location) is absorbed losslessly ────
test_reconcile_v2_legacy_absorbed() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _rec_env "$tmp/state"
    # Legacy at the OLD location but already v2 (a dev build wrote v2 before 017).
    local lf; lf=$(_rec_legacy_file); mkdir -p "$(dirname "$lf")"
    cat > "$lf" <<'IDX'
version: 2
projects:
  app: "repoA"
project_paths:
  app:
    repoA: "/abs/repoA"
llms:
unscoped:
  loose: "/abs/loose"
IDX
    _rec_write_new_v2 app repoB /abs/repoB

    _index_reconcile_legacy_location false || fail "reconcile returned non-zero"

    [[ "$(_index_pp_get app repoA)" == "/abs/repoA" ]] || fail "v2-legacy project binding not absorbed, got: $(_index_pp_get app repoA)"
    [[ "$(_index_pp_get app repoB)" == "/abs/repoB" ]] || fail "existing binding lost"
    [[ "$(_index_section_get unscoped loose)" == "/abs/loose" ]] || fail "v2-legacy unscoped orphan not absorbed"
    [[ -e "$(_rec_legacy_file)" ]] && fail "v2 legacy must be removed after a clean merge"
    return 0
}

# ── migration 017's index arm no longer destroys the legacy (N1) ─────
# The old arm did `rm -f "$state/index"` unconditionally when both existed. The
# corrected arm reconciles: a legacy-only binding must SURVIVE into the new file.
test_migration_017_index_arm_is_non_destructive() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _rec_env "$tmp/state"
    source "$REPO_ROOT/lib/update-meta.sh"
    source "$REPO_ROOT/lib/migrate.sh"
    _rec_write_legacy_v1 repoA /abs/repoA app     # legacy has a UNIQUE binding
    _rec_write_new_v2 app repoB /abs/repoB        # new lacks it

    source "$REPO_ROOT/migrations/global/017_state_shared_subbucket.sh"
    migrate "$tmp/home/.cco/.claude" || fail "migration 017 returned non-zero"

    # The legacy-only path must be preserved (the N1 fix), not rm -f'd.
    [[ "$(_index_pp_get app repoA)" == "/abs/repoA" ]] || fail "017 lost the legacy-only binding (N1), got: $(_index_pp_get app repoA)"
    [[ "$(_index_pp_get app repoB)" == "/abs/repoB" ]] || fail "017 clobbered the existing binding"
    [[ -e "$(_rec_legacy_file)" ]] && fail "017 must remove the legacy file after a clean merge"
    return 0
}
