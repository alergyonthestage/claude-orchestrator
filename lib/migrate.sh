#!/usr/bin/env bash
# lib/migrate.sh — First-run bootstrap + legacy-vault migration safety net
#
# Provides: _cco_first_run() (dispatch-time orchestrator), _cco_bootstrap_roots()
#           (J0 four-root bootstrap — ADR-0017 D3), _cco_backup_legacy_vault()
#           (raw-tar legacy-vault archive → STATE — ADR-0006/0025),
#           _cco_have_backup(), _cco_host_side_ok()
# Dependencies: colors.sh (info/ok/warn/die), paths.sh (XDG resolvers,
#               _cco_in_container, _cco_ensure_dir)
# Globals: USER_CONFIG_DIR
#
# The decentralized-config cutover (design §9 Phase 2) replaces the central
# `user-config/` vault with `~/.cco` (CONFIG) + DATA/STATE/CACHE. This module
# owns the two first-run steps that must precede every other command:
#   1. bootstrap the four roots (so resolvers never race a missing dir), and
#   2. archive the legacy vault once, as a universal safety net (ADR-0025 §2),
#      before any decentralized command reads or migrates anything (M8).
# Both run host-side only (H4); the heavy per-project/global *populate* is owned
# by `cco init --migrate` (lazy) and `cco update` (eager global) respectively.

# ── Host-side guard ──────────────────────────────────────────────────
# True (0) when it is safe to resolve/create host paths. cco runs host-side
# only; inside a session container the anti-in-container guard (H4) forbids it,
# unless the test/dev hatch CCO_ALLOW_HOST_RESOLVE=1 is set. First-run work must
# silently no-op in that case rather than die — a hook that happens to invoke
# cco in-container should not be bricked by bootstrap.
_cco_host_side_ok() {
    [[ "${CCO_ALLOW_HOST_RESOLVE:-}" == "1" ]] && return 0
    _cco_in_container && return 1
    return 0
}

# ── J0 four-root bootstrap (ADR-0017 D3) ─────────────────────────────
# Create the four decentralized-config roots when missing, on ANY command.
# Per-root idempotent (M6): each XDG resolver mkdir -p's only its own root, so a
# single missing root is created without disturbing the others. ~/.cco is
# additionally a git-versioned working tree (ADR-0008/0024 D4) — only the remote
# is opt-in (Phase 3). Silent on the normal path.
_cco_bootstrap_roots() {
    _cco_host_side_ok || return 0
    local cfg
    cfg=$(_cco_config_dir)      # ~/.cco (resolver mkdir 0700)
    _cco_data_dir  >/dev/null   # DATA  root
    _cco_state_dir >/dev/null   # STATE root
    _cco_cache_dir >/dev/null   # CACHE root
    # ~/.cco is always git-versioned (the global populate adds the allowlist
    # .gitignore + first commit at `cco update`, Phase 2-3). An empty init here
    # is harmless and idempotent.
    if [[ -n "$cfg" && ! -d "$cfg/.git" ]]; then
        git -C "$cfg" init -q >/dev/null 2>&1 || true
    fi
}

# True (0) when STATE already holds a verified legacy-vault archive. The archive
# is written atomically only after an integrity check (see below), so its
# presence at the final name IS the authoritative "already backed up" signal
# (F43) — no need to re-verify on every command. Partial/corrupt writes live at
# .tmp names and never match.
_cco_have_backup() {
    local backups="$1" f
    [[ -d "$backups" ]] || return 1
    for f in "$backups"/vault-*.tar.gz; do
        [[ -e "$f" ]] && return 0
    done
    return 1
}

# ── Legacy-vault backup (ADR-0006 Decision 2 / ADR-0025 §2) ──────────
# On first run with a legacy vault present, archive the WHOLE vault as a raw tar
# — including .git and the .cco/profile-state/<branch>/ stash shadows — so the
# single archive captures every profile's committed config (via .git) AND every
# profile's gitignored secrets (active in the working tree, inactive in their
# shadows; F1/F9). The profile->tag flatten happens at READ time inside the
# migrate reader, not here. The archive lands in STATE (machine-local, never
# synced, 0600), NOT in ~/.cco (authored-config-only; fixes inventory C1).
#
# Idempotent (F43): a verified archive is the authoritative signal;
# <state>/cco/migration-state is the fast-path marker. Atomic-staged (F44):
# build under a .tmp sibling, verify integrity, then atomic mv into place.
# Universal net — best-effort: a failure warns and lets the command proceed; the
# hard "backup verified before read" guarantee (M8) is re-checked inside
# `cco init --migrate` (Phase 2-4).
_cco_backup_legacy_vault() {
    _cco_host_side_ok || return 0

    local vault="$USER_CONFIG_DIR"
    # A "legacy vault" is a git-versioned user-config store (`cco vault init`).
    # No .git ⇒ nothing from the old layout to preserve; the fresh roots (J0)
    # are all a clean install needs.
    [[ -d "$vault/.git" ]] || return 0

    # _cco_state_dir IS the cco-namespaced state root (existing code does
    # $(_cco_state_dir)/index, /sync-meta, /projects/<id>): design <state>/cco/X
    # == $(_cco_state_dir)/X.
    local state backups marker
    state=$(_cco_state_dir)
    backups="$state/backups"
    marker="$state/migration-state"

    # Fast path: marker present and a verified archive exists.
    if [[ -f "$marker" ]] && _cco_have_backup "$backups"; then
        return 0
    fi
    # Authoritative guard (F43), decoupled from the marker: a wiped/relocated
    # marker must never trigger a destructive re-archive when a good archive
    # already exists — heal the marker and stop.
    if _cco_have_backup "$backups"; then
        : > "$marker" 2>/dev/null || true
        return 0
    fi

    _cco_ensure_dir "$backups"
    local date_tag final tmp
    date_tag=$(date -u +%Y%m%d-%H%M%S)
    final="$backups/vault-$date_tag.tar.gz"
    tmp="$backups/.vault-$date_tag.tar.gz.tmp"

    info "Legacy vault detected — archiving before migration…"
    # Raw tar of the whole vault as-is; exclude only the old in-vault backups dir
    # (avoid self-nesting). --exclude before the file args for GNU+BSD tar.
    if ! tar --exclude='./.cco/backups' -czf "$tmp" -C "$vault" . 2>/dev/null; then
        rm -f "$tmp"
        warn "Could not archive the legacy vault at $vault — leaving it untouched; retry on the next command."
        return 1
    fi
    # Verify archive integrity BEFORE exposing it (M8 ordering) …
    if ! tar -tzf "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        warn "Legacy-vault backup failed its integrity check — discarded; retry on the next command."
        return 1
    fi
    chmod 0600 "$tmp" 2>/dev/null || true
    # … then atomically move into place (F44) and record the fast-path marker.
    mv -f "$tmp" "$final"
    : > "$marker" 2>/dev/null || true

    ok "Legacy vault archived: $final"
    info "Your user-config/ is preserved as-is — nothing was moved or deleted."
    info "To migrate to the decentralized layout:"
    echo "    cco update                    # migrate global config, packs & templates" >&2
    echo "    cco init --migrate <project>  # migrate each project (run inside its repo)" >&2
    return 0
}

# ── Dispatch-time orchestrator ───────────────────────────────────────
# Run before every command (bin/cco). Bootstrap is universal; the backup net is
# skipped for pure-legacy `vault` operations (they act on the old vault under
# the old expectation — they neither engage the decentralized layer nor migrate,
# so they need no net) and for `help`. Ordering (M8): roots BEFORE the backup,
# which needs the STATE root.
_cco_first_run() {
    local cmd="$1"
    _cco_bootstrap_roots
    case "$cmd" in
        vault|help) : ;;
        *) _cco_backup_legacy_vault || true ;;
    esac
}
