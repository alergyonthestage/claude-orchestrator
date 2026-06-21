#!/usr/bin/env bash
# lib/reminders.sh — non-blocking config reminder aggregator (ADR-0008).
#
# A single surface that emits advisory, NEVER-blocking reminders at
# config-sensitive commands (cco start, cco sync). It replaces the old vault's
# blocking clean-tree gate (downgraded to a reminder, ADR-0008) WITHOUT
# resurrecting any profile/vault-specific behavior. Three reminders:
#   (a) uncommitted changes in ~/.cco (the personal/global config store)
#   (b) uncommitted changes in an involved <repo>/.cco
#   (c) cross-repo divergence — a project's member repos carry different .cco/
#       synced sets (consumes the §4.6 sync-state fingerprint)
#
# Invariant H1 (resolution before notices): the aggregator is given the
# ALREADY-RESOLVED member repo roots; it never resolves and never runs against
# an empty/unresolved index. The caller (cco start / cco sync) resolves members
# first, then calls _emit_config_reminders with the resolved roots. Everything
# here is best-effort and returns 0 (P14: awareness, never a block).
#
# Provides: _emit_config_reminders(), _reminder_git_dirty(),
#   _reminder_cross_repo_divergence()
# Dependencies: colors.sh (warn), paths.sh (_cco_config_dir),
#   sync-meta.sh (_sync_fingerprint_compute)

# True (exit 0) iff <root> is a git repo with uncommitted changes. With an
# optional <subpath>, the check is scoped to that path (e.g. ".cco"). Returns 1
# when <root> is clean OR is not a git repo (best-effort, never errors).
# Usage: _reminder_git_dirty <root> [<subpath>]
_reminder_git_dirty() {
    local root="$1" sub="${2:-}" out
    git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 1
    if [[ -n "$sub" ]]; then
        out=$(git -C "$root" status --porcelain --no-renames -- "$sub" 2>/dev/null)
    else
        out=$(git -C "$root" status --porcelain --no-renames 2>/dev/null)
    fi
    [[ -n "$out" ]]
}

# Warn iff a project's member repos carry divergent .cco/ synced sets (Case C).
# Compares the current synced-set fingerprint (§4.6) across the given repo roots
# that actually have a .cco/; >= 2 distinct fingerprints => divergent.
# Usage: _reminder_cross_repo_divergence <repo_root>...
_reminder_cross_repo_divergence() {
    local r fp first="" have_first=false divergent=false count=0
    for r in "$@"; do
        [[ -d "$r/.cco" ]] || continue
        fp=$(_sync_fingerprint_compute "$r")
        count=$((count + 1))
        if ! $have_first; then
            first="$fp"; have_first=true
        elif [[ "$fp" != "$first" ]]; then
            divergent=true
        fi
    done
    if [[ $count -ge 2 ]] && $divergent; then
        warn "project repos have divergent .cco — run 'cco sync' to converge from a chosen source"
    fi
    return 0
}

# Emit all three non-blocking reminders for the given (already-resolved) member
# repo roots. Always returns 0.
# Usage: _emit_config_reminders <repo_root>...
_emit_config_reminders() {
    local -a roots=("$@")

    # (a) uncommitted ~/.cco (fires only once ~/.cco is a git tree; J0 git-inits
    #     it in P2 — until then this is silently a no-op).
    local cfg
    cfg=$(_cco_config_dir)
    if _reminder_git_dirty "$cfg"; then
        warn "~/.cco has uncommitted changes — commit them to version your global config"
    fi

    # (b) uncommitted involved <repo>/.cco
    local r
    for r in ${roots[@]+"${roots[@]}"}; do
        [[ -d "$r/.cco" ]] || continue
        if _reminder_git_dirty "$r" ".cco"; then
            warn "$(basename "$r"): .cco has uncommitted changes — commit it with your normal git flow"
        fi
    done

    # (c) cross-repo divergence
    _reminder_cross_repo_divergence ${roots[@]+"${roots[@]}"}

    return 0
}
