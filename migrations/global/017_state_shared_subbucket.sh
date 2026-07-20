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
# no-op. A missing source is fine (a fresh install has no index yet). If BOTH a legacy
# and a new path exist — a partially-applied run, or a downgrade/upgrade bounce — the
# NEW one wins and the legacy leftover is removed, because the new path is what every
# reader resolves to after this release.

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
    if [[ -f "$state/index" ]]; then
        if [[ -f "$shared/index" ]]; then
            # Both present: the new location is authoritative (see header).
            rm -f "$state/index" || return 1
        else
            mv "$state/index" "$shared/index" || return 1
        fi
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
