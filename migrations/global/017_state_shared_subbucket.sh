#!/usr/bin/env bash
# Migration 017: move the container-shareable STATE members into <state>/cco/shared/.
#
# Why (v3 root cause R1). The STATE bucket used to cross the ADR-0047 boundary as
# individual FILE binds (`index`, `running`). A file bind gives the container no
# writable PARENT, and every index writer replaces the file atomically via a sibling
# temp (`mktemp "$f.XXXXXX"` + `mv`) — so in-container index writes failed EACCES
# while the verb still reported success, `mv` onto the bound file would have been
# EBUSY anyway, and a host-side rename() stranded the session on a //deleted inode.
# The same gap killed the pack/template sidecar store ops, which need to create
# under <state>/cco/{packs,templates}/.
#
# The fix binds ONE directory instead. It cannot be <state>/cco itself: the 0600
# `remotes-token`, the per-project session transcripts and memory live there and must
# never reach a container. So the shareable members move under an explicit allow-list
# sub-bucket, `shared/`, and that is what `cco start` binds. Anything left outside it
# stays off the container by construction (fail-safe for whatever is added later).
#
# Moves:
#   <state>/cco/index                     → <state>/cco/shared/index
#   <state>/cco/packs/<name>/update/*     → <state>/cco/shared/packs/<name>/update/*
#   <state>/cco/templates/<name>/update/* → <state>/cco/shared/templates/<name>/update/*
#
# Left in place (deliberately NOT shareable): remotes-token, projects/, running/,
# global/, internal/, sync-meta, backups.
#
# Idempotent: a machine already migrated has no legacy sources, so every branch is a
# no-op. A missing source is fine (a fresh install has no index yet).
#
# The index arm is NON-DESTRUCTIVE (ADR-0052 §2): when both a legacy and a new index
# exist — the 0.5.2→release upgrade where `cco start`/`cco resolve` ran before
# `cco update` created an empty shared/index (N1) — it MERGES rather than deleting
# the legacy, so no registered path is lost. See _index_reconcile_legacy_location.
# The pack/template sidecar arms keep "new wins" per ENTRY: those are re-fetchable
# update metadata (installed_commit + base), not machine-local identity, so a stale
# leftover is safely superseded by the current install.

MIGRATION_ID=17
MIGRATION_DESC="Move index + pack/template sidecars into STATE/shared (container-shareable bucket)"

# $1 = the global .claude dir (unused; STATE is resolved via paths.sh).
migrate() {
    local state shared
    state=$(_cco_state_dir)   || return 1
    shared=$(_cco_state_shared_dir) || return 1
    [[ -d "$state" ]] || return 0

    mkdir -p "$shared" || return 1

    # ── the index (a file) ───────────────────────────────────────────
    # Non-destructive reconcile (ADR-0052 §2, closes N1). The legacy is v1-schema
    # AND old-location, so a correct move must relocate + v1→v2 re-home + MERGE
    # atomically — never the old `rm -f "$state/index"` "new wins" that lost paths
    # when the hot path had already created an empty shared/index (N1). Interactive:
    # this is the explicit `cco update` path, so a genuine path conflict prompts on
    # a TTY (else keeps both files). Absent legacy / legacy-only / both-present are
    # all handled inside the reconcile.
    if [[ -f "$state/index" ]]; then
        _index_reconcile_legacy_location true || return 1
    fi

    # ── the pack / template sidecar trees (directories, keyed by name) ──
    local kind src dst entry name
    for kind in packs templates; do
        src="$state/$kind"
        [[ -d "$src" ]] || continue
        dst="$shared/$kind"
        mkdir -p "$dst" || return 1
        # Move per ENTRY, not the whole tree, so a partially-applied run converges
        # instead of failing on a non-empty destination.
        for entry in "$src"/*; do
            [[ -e "$entry" ]] || continue          # unmatched glob
            name=$(basename "$entry")
            if [[ -e "$dst/$name" ]]; then
                rm -rf "$entry" || return 1        # new wins
            else
                mv "$entry" "$dst/$name" || return 1
            fi
        done
        # Only remove the legacy parent once it is genuinely empty — never -rf it,
        # so an unexpected leftover is preserved rather than silently destroyed.
        rmdir "$src" 2>/dev/null || true
    done

    return 0
}
