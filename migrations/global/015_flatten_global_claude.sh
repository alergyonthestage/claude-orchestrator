#!/usr/bin/env bash
# Migration 015: flatten the global config home (ADR-0028).
#
# Moves the global Claude config from the vault-era nested location
# ~/.cco/global/.claude to the flat ~/.cco/.claude. ~/.cco is already the global
# config scope, so the `global/` wrapper is redundant; this drops it. Only the
# user-store destination changes — the shipped source `defaults/global/.claude/`
# is unaffected.
#
# Idempotent: no-op when already flat (or when there is nothing to move). Safe to
# run multiple times. Never clobbers a populated ~/.cco/.claude.

MIGRATION_ID=15
MIGRATION_DESC="Flatten global config home: ~/.cco/global/.claude -> ~/.cco/.claude"

# $1 = the (new) flat global .claude dir, ~/.cco/.claude. Its parent is the config
# home (~/.cco); the legacy path is derived from it, with no resolver dependency.
migrate() {
    local new_dir="$1"
    local cfg legacy_dir legacy_wrap
    cfg="$(dirname "$new_dir")"          # ~/.cco
    legacy_wrap="$cfg/global"            # ~/.cco/global
    legacy_dir="$legacy_wrap/.claude"    # ~/.cco/global/.claude

    # Already flat. If a stale legacy copy also lingers (half-migrated dev state),
    # the flat dir is authoritative — drop the redundant legacy tree + empty
    # wrapper, but never touch the populated flat dir.
    if [[ -d "$new_dir" ]]; then
        if [[ -d "$legacy_dir" ]]; then
            rm -rf "$legacy_dir" 2>/dev/null || true
        fi
        rmdir "$legacy_wrap" 2>/dev/null || true
        return 0
    fi

    # No legacy global config present → fresh / already-flat install, nothing to do.
    [[ -d "$legacy_dir" ]] || return 0

    info "Flattening global config: ~/.cco/global/.claude -> ~/.cco/.claude"

    # Same-filesystem rename (both under ~/.cco) — atomic and cheap.
    if mv "$legacy_dir" "$new_dir" 2>/dev/null; then
        rmdir "$legacy_wrap" 2>/dev/null || true
        return 0
    fi

    # Fallback (e.g. rename across a bind boundary): stage a same-dir sibling copy,
    # then swap and remove the legacy tree. Never leaves a partial flat dir.
    rm -rf "$new_dir.tmp" 2>/dev/null || true
    if cp -r "$legacy_dir" "$new_dir.tmp" 2>/dev/null; then
        mv "$new_dir.tmp" "$new_dir"
        rm -rf "$legacy_dir" 2>/dev/null || true
        rmdir "$legacy_wrap" 2>/dev/null || true
        return 0
    fi

    rm -rf "$new_dir.tmp" 2>/dev/null || true
    warn "Could not flatten ~/.cco/global/.claude — left in place; retry on the next 'cco update'."
    return 1
}
