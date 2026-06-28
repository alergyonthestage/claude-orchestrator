#!/usr/bin/env bash
# scripts/cco-decentralized-state.sh
#
# ⚠️  TESTING / DOGFOODING UTILITY — NOT a shipped cco command, NOT for end users.
#
# Purpose
#   Reset a *host* machine to a pristine "legacy user" state for re-running the
#   decentralized-config e2e validation (docs/maintainers/configuration/
#   decentralized-config/e2e-validation-checklist.md) from scratch. It removes
#   the four NEW decentralized-config roots so the next cco command re-bootstraps
#   them and re-creates the J0 legacy-vault backup — exactly the "first command"
#   state the checklist Phase 0 needs.
#
#   Every removal is preceded by a verified, restorable snapshot, so the reset
#   is reversible with this same script (`restore`).
#
# What it TOUCHES (resolved exactly like cco — honours CCO_*_HOME / XDG_*):
#   CONFIG  $HOME/.cco                                  (personal store)
#   DATA    $CCO_DATA_HOME  | $XDG_DATA_HOME/cco  | $HOME/.local/share/cco
#   STATE   $CCO_STATE_HOME | $XDG_STATE_HOME/cco | $HOME/.local/state/cco   (holds the backup + marker)
#   CACHE   $CCO_CACHE_HOME | $XDG_CACHE_HOME/cco | $HOME/.cache/cco
#
# What it NEVER touches (by design):
#   • The legacy vault  ${CCO_USER_CONFIG_DIR:-<repo>/user-config}  — the source
#     of truth. The legacy world (main/develop) lives entirely here; this script
#     refuses to remove it or anything under/over it.
#   • Per-repo  <repo>/.cco/  directories (they are git-managed; clean them by
#     hand per repo).
#
# Safety model
#   1. Snapshot FIRST, verify each archive, and only THEN remove — a snapshot
#      failure aborts the whole reset with nothing removed.
#   2. Hard guardrails: never "/", "$HOME" (or an ancestor), the vault, or a path
#      over/under the vault; the backup dir may not live inside a removed root. A
#      default-layout root must be a cco-namespaced leaf ("cco"/".cco");
#      CCO_*_HOME / XDG_* overrides are trusted (that is how the e2e sandbox
#      redirects the roots into /tmp).
#   3. Snapshots contain secrets (secrets.env + the vault tar) → archive mode
#      0600, snapshot dir 0700.
#   4. Destructive actions confirm on a TTY; -y/--yes skips it; without a TTY and
#      without -y the script DIES rather than act unattended (ADR-0029 parity).
#
# Usage
#   scripts/cco-decentralized-state.sh [reset] [options]   # snapshot + remove the 4 roots
#   scripts/cco-decentralized-state.sh backup [options]    # snapshot the 4 roots, remove NOTHING
#   scripts/cco-decentralized-state.sh restore [SNAPSHOT]  # restore latest (or named) snapshot
#   scripts/cco-decentralized-state.sh list                # list available snapshots
#   scripts/cco-decentralized-state.sh paths               # show resolved roots (read-only)
#
# Options
#   -b, --backup-dir DIR   Snapshot store (default: $CCO_RESET_BACKUP_DIR or ~/.cco-reset-backups)
#   -y, --yes              Skip the confirmation prompt (required when non-interactive)
#   -n, --dry-run          Show what would happen; change nothing
#   -f, --force            (restore) Overwrite roots that currently exist
#   -h, --help             This help
#
# Examples
#   # Take an explicit safety snapshot without removing anything:
#   scripts/cco-decentralized-state.sh backup -b ~/cco-e2e-snapshots
#   # Reset, keeping the safety snapshot under a chosen dir:
#   scripts/cco-decentralized-state.sh reset -b ~/cco-e2e-snapshots
#   # …run the e2e checklist… then undo:
#   scripts/cco-decentralized-state.sh restore --force

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Colors (only on a TTY) ────────────────────────────────────────────
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

info() { printf "${CYAN}•${RESET} %s\n" "$*" >&2; }
ok()   { printf "${GREEN}✓${RESET} %s\n" "$*" >&2; }
warn() { printf "${YELLOW}!${RESET} %s\n" "$*" >&2; }
die()  { printf "${RED}✗ %s${RESET}\n" "$*" >&2; exit 1; }

# ── Defaults / flags ──────────────────────────────────────────────────
BACKUP_DIR="${CCO_RESET_BACKUP_DIR:-$HOME/.cco-reset-backups}"
ASSUME_YES=false
DRY_RUN=false
FORCE=false

# Resolved roots (filled by _resolve). *_SRC = "default" | "override" records
# whether the path came from a CCO_*_HOME / XDG_* override (trusted, explicit) or
# the built-in default layout — the removal guard treats the two differently.
CONFIG_DIR=""; DATA_DIR=""; STATE_DIR=""; CACHE_DIR=""; VAULT_DIR=""
DATA_SRC="default"; STATE_SRC="default"; CACHE_SRC="default"

# ── Path resolution (mirrors lib/paths.sh) ────────────────────────────
# First absolute (leading-slash) candidate wins — identical to cco's _cco_first_abs.
_first_abs() {
    local c
    for c in "$@"; do
        [[ -n "$c" && "$c" == /* ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

# True (0) if either env var is set to an absolute path (i.e. an override wins).
_overridden() {
    [[ -n "${1:-}" && "${1}" == /* ]] && return 0
    [[ -n "${2:-}" && "${2}" == /* ]] && return 0
    return 1
}

_resolve() {
    # CONFIG is deliberately $HOME/.cco in cco (no XDG, no override).
    CONFIG_DIR="$HOME/.cco"
    DATA_DIR="$(_first_abs "${CCO_DATA_HOME:-}"  "${XDG_DATA_HOME:+${XDG_DATA_HOME%/}/cco}"  "$HOME/.local/share/cco")"
    STATE_DIR="$(_first_abs "${CCO_STATE_HOME:-}" "${XDG_STATE_HOME:+${XDG_STATE_HOME%/}/cco}" "$HOME/.local/state/cco")"
    CACHE_DIR="$(_first_abs "${CCO_CACHE_HOME:-}" "${XDG_CACHE_HOME:+${XDG_CACHE_HOME%/}/cco}" "$HOME/.cache/cco")"
    _overridden "${CCO_DATA_HOME:-}"  "${XDG_DATA_HOME:-}"  && DATA_SRC="override"  || DATA_SRC="default"
    _overridden "${CCO_STATE_HOME:-}" "${XDG_STATE_HOME:-}" && STATE_SRC="override" || STATE_SRC="default"
    _overridden "${CCO_CACHE_HOME:-}" "${XDG_CACHE_HOME:-}" && CACHE_SRC="override" || CACHE_SRC="default"
    # Legacy vault pointer — default matches bin/cco ($REPO_ROOT/user-config).
    VAULT_DIR="${CCO_USER_CONFIG_DIR:-$REPO_ROOT/user-config}"
}

# Emit the four removable roots as "label<TAB>path<TAB>src" lines.
_roots_tsv() {
    printf 'config\t%s\tdefault\n' "$CONFIG_DIR"
    printf 'data\t%s\t%s\n'   "$DATA_DIR"  "$DATA_SRC"
    printf 'state\t%s\t%s\n'  "$STATE_DIR" "$STATE_SRC"
    printf 'cache\t%s\t%s\n'  "$CACHE_DIR" "$CACHE_SRC"
}

# True (0) if $1 equals $2 or is nested under it (trailing-slash normalized).
_within() {
    local a="${1%/}/" b="${2%/}/"
    [[ "$a" == "$b" || "$a" == "$b"* ]]
}

# Refuse to remove anything dangerous. $1 = path, $2 = src (default|override).
# Universal guards always apply; the cco-namespaced-leaf check applies only to the
# built-in default layout — an explicit CCO_*_HOME / XDG_* override is trusted
# (that is how the e2e sandbox redirects the roots into /tmp/cco-dogfood/…).
_assert_removable() {
    local p="$1" src="${2:-default}"
    [[ -n "$p" ]]    || die "Internal error: empty path in removal set."
    [[ "$p" == /* ]] || die "Refusing to remove a non-absolute path: '$p'"
    [[ "$p" == "/" ]] && die "Refusing to remove '/'."
    # p must not be $HOME or an ancestor of it (catches '/', '$HOME', '/Users', …).
    if _within "$HOME" "$p"; then
        die "Refusing: '$p' is your HOME or an ancestor of it."
    fi
    # Never the vault, nor a path over/under it.
    if _within "$p" "$VAULT_DIR" || _within "$VAULT_DIR" "$p"; then
        die "Refusing: '$p' overlaps the legacy vault '$VAULT_DIR' (the source of truth)."
    fi
    # The snapshot store must never sit inside a root we delete.
    if _within "$BACKUP_DIR" "$p"; then
        die "Refusing: the backup dir '$BACKUP_DIR' is inside '$p' — choose --backup-dir outside the cco roots."
    fi
    # Default layout sanity: the path must be a cco bucket leaf. (Overrides are
    # explicit user intent and skip this — the universal guards above still hold.)
    if [[ "$src" != "override" ]]; then
        local base; base="$(basename "$p")"
        [[ "$base" == "cco" || "$base" == ".cco" ]] \
            || die "Refusing a non-cco-namespaced default path: '$p' (basename must be 'cco' or '.cco')."
    fi
}

_confirm() {
    local prompt="$1"
    $ASSUME_YES && return 0
    if [[ ! -t 0 || ! -t 1 ]]; then
        die "Refusing a destructive action without a TTY. Re-run with -y/--yes to proceed non-interactively."
    fi
    local ans=""
    read -rp "$(printf "${BOLD}%s [y/N]: ${RESET}" "$prompt")" ans
    ans="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')"
    [[ "$ans" == "y" || "$ans" == "yes" ]]
}

_dir_size() { [[ -d "$1" ]] && du -sh "$1" 2>/dev/null | cut -f1 || printf '—'; }

_container_note() {
    [[ -f /.dockerenv || "${CCO_IN_CONTAINER:-}" == "1" ]] && \
        warn "Looks like a container. cco is host-side; run this on the host you validate (e.g. your Mac) unless this is a deliberate sandbox."
    return 0
}

# ── paths (read-only diagnostic) ──────────────────────────────────────
cmd_paths() {
    _resolve
    printf "${BOLD}Decentralized-config roots (resolved like cco):${RESET}\n" >&2
    local label path src
    while IFS=$'\t' read -r label path src; do
        local tag=""; [[ "$src" == "override" ]] && tag=" ${YELLOW}[override]${RESET}"
        if [[ -d "$path" ]]; then
            printf "  ${CYAN}%-7s${RESET} %s  ${CYAN}(%s)${RESET}%b\n" "$label" "$path" "$(_dir_size "$path")" "$tag" >&2
        else
            printf "  ${CYAN}%-7s${RESET} %s  ${YELLOW}(absent)${RESET}%b\n" "$label" "$path" "$tag" >&2
        fi
    done < <(_roots_tsv)
    printf "  ${GREEN}%-7s${RESET} %s  ${GREEN}(PRESERVED — never touched)${RESET}\n" "vault" "$VAULT_DIR" >&2
    printf "\n  snapshot store: %s\n" "$BACKUP_DIR" >&2
}

# ── snapshot core (shared by `backup` and `reset`) ────────────────────
# Print each PRESENT root as a plan line (no header — callers add their own).
_print_present_roots() {
    local label path src tag
    while IFS=$'\t' read -r label path src; do
        [[ -d "$path" ]] || continue
        tag=""; [[ "$src" == "override" ]] && tag=" ${YELLOW}[override]${RESET}"
        printf "  ${CYAN}%-7s${RESET} %s  ${CYAN}(%s)${RESET}%b\n" \
            "$label" "$path" "$(_dir_size "$path")" "$tag" >&2
    done < <(_roots_tsv)
}

# Snapshot every present root into a fresh, verified snapshot dir + manifest.
# Removes NOTHING. On success sets the global SNAP_RESULT to the snapshot path.
# MUST run in the main shell (never `$(_snapshot_roots)`): a die() inside has to
# abort the whole script, so `reset` can never reach removal without a verified
# snapshot. Returns 0 (SNAP_RESULT set) · 2 (no roots present) · 3 (dry-run).
SNAP_RESULT=""
_snapshot_roots() {
    SNAP_RESULT=""
    local label path src present_labels=() present_paths=()
    while IFS=$'\t' read -r label path src; do
        [[ -d "$path" ]] && { present_labels+=("$label"); present_paths+=("$path"); }
    done < <(_roots_tsv)
    [[ ${#present_paths[@]} -gt 0 ]] \
        || { info "No decentralized-config roots present — nothing to snapshot."; return 2; }

    local stamp snap
    stamp="$(date -u +%Y%m%d-%H%M%S)"
    snap="$BACKUP_DIR/cco-reset-$stamp"
    info "Snapshot → $snap"
    if $DRY_RUN; then warn "DRY RUN — nothing was snapshotted."; return 3; fi

    ( umask 077; mkdir -p "$snap" ) || die "Could not create snapshot dir: $snap"
    local manifest="$snap/manifest.tsv"; : > "$manifest"

    # Archive + integrity-check EVERY present root before the caller removes any.
    local i
    for i in "${!present_paths[@]}"; do
        label="${present_labels[$i]}"; path="${present_paths[$i]}"
        info "  archiving $label …"
        if ! tar -czf "$snap/$label.tar.gz" -C "$(dirname "$path")" "$(basename "$path")" 2>/dev/null; then
            die "Snapshot of '$path' failed. Snapshot dir: $snap"
        fi
        tar -tzf "$snap/$label.tar.gz" >/dev/null 2>&1 \
            || die "Snapshot of '$path' failed its integrity check."
        chmod 0600 "$snap/$label.tar.gz" 2>/dev/null || true
        printf '%s\t%s\t%s\tpresent\n' "$label" "$path" "$label.tar.gz" >> "$manifest"
    done
    # Record the absent roots too (so restore knows their canonical location).
    while IFS=$'\t' read -r label path src; do
        [[ -d "$path" ]] && continue
        printf '%s\t%s\t-\tabsent\n' "$label" "$path" >> "$manifest"
    done < <(_roots_tsv)

    cat > "$snap/README.txt" <<EOF
cco decentralized-config snapshot — $stamp (UTC)

Restore everything to its original location with:
    scripts/cco-decentralized-state.sh restore "$snap" --force

manifest.tsv columns: label <TAB> original_path <TAB> archive <TAB> status
Archives contain plaintext secrets (secrets.env, the vault backup) — keep 0600.
EOF
    chmod 0600 "$snap/README.txt" "$manifest" 2>/dev/null || true
    SNAP_RESULT="$snap"
    return 0
}

# ── backup (snapshot only — non-destructive) ──────────────────────────
cmd_backup() {
    _resolve
    _container_note
    info "Legacy vault (PRESERVED): $VAULT_DIR"
    printf "${BOLD}Roots to snapshot (nothing will be removed):${RESET}\n" >&2
    _print_present_roots
    if _snapshot_roots; then
        ok "Backup complete. Snapshot: $SNAP_RESULT"
        info "Restore later with: $(basename "$0") restore \"$SNAP_RESULT\" --force"
    fi
}

# ── reset (snapshot + remove) ─────────────────────────────────────────
cmd_reset() {
    _resolve
    _container_note

    # Partition into present (for removal) / absent.
    local label path src present_labels=() present_paths=() present_srcs=() any=false
    while IFS=$'\t' read -r label path src; do
        if [[ -d "$path" ]]; then
            present_labels+=("$label"); present_paths+=("$path"); present_srcs+=("$src"); any=true
        fi
    done < <(_roots_tsv)

    info "Legacy vault (PRESERVED): $VAULT_DIR"
    if ! $any; then
        ok "No decentralized-config roots present — already in a pristine legacy state."
        return 0
    fi

    printf "${BOLD}Will snapshot, then REMOVE:${RESET}\n" >&2
    _print_present_roots

    if $DRY_RUN; then
        info "A snapshot would be written under: $BACKUP_DIR"
        warn "DRY RUN — nothing was snapshotted or removed."
        return 0
    fi

    _confirm "Snapshot ${#present_paths[@]} root(s) and then remove them?" \
        || { info "Aborted — nothing changed."; return 0; }

    # Pre-flight: every target must pass the guardrails BEFORE we snapshot.
    local i
    for i in "${!present_paths[@]}"; do _assert_removable "${present_paths[$i]}" "${present_srcs[$i]}"; done

    # Snapshot (sets SNAP_RESULT; dies on any failure, so removal below is only
    # ever reached with a verified archive). Not in a subshell — die must abort.
    _snapshot_roots || die "Snapshot step did not complete — nothing was removed."

    # Only now remove (all snapshots verified).
    for i in "${!present_paths[@]}"; do
        path="${present_paths[$i]}"
        _assert_removable "$path" "${present_srcs[$i]}"   # belt-and-suspenders, immediately before rm
        rm -rf "$path"
        ok "removed ${present_labels[$i]}: $path"
    done

    ok "Reset complete. Snapshot kept at: $SNAP_RESULT"
    info "Next cco command will re-bootstrap the roots and re-create the J0 vault backup."
}

# ── restore ───────────────────────────────────────────────────────────
_latest_snapshot() {
    local d last=""
    for d in "$BACKUP_DIR"/cco-reset-*/; do
        [[ -d "$d" && -f "$d/manifest.tsv" ]] && last="${d%/}"
    done
    [[ -n "$last" ]] && printf '%s' "$last"
}

cmd_restore() {
    _resolve
    local snap="${1:-}"
    if [[ -z "$snap" ]]; then
        snap="$(_latest_snapshot)" || true
        [[ -n "$snap" ]] || die "No snapshot found under $BACKUP_DIR. Pass one explicitly, or check --backup-dir."
        info "Restoring latest snapshot: $snap"
    fi
    [[ -d "$snap" && -f "$snap/manifest.tsv" ]] || die "Not a snapshot dir (missing manifest.tsv): $snap"

    # Preview.
    printf "${BOLD}Restore plan (snapshot → original location):${RESET}\n" >&2
    local label orig archive status
    while IFS=$'\t' read -r label orig archive status; do
        [[ "$status" == "present" ]] || continue
        local exists="new"
        if [[ -e "$orig" ]]; then exists="${YELLOW}EXISTS${RESET}"; fi
        printf "  ${CYAN}%-7s${RESET} → %s  [%b]\n" "$label" "$orig" "$exists" >&2
    done < "$snap/manifest.tsv"

    if $DRY_RUN; then warn "DRY RUN — nothing was restored."; return 0; fi
    _confirm "Restore these root(s) into their original locations?" \
        || { info "Aborted — nothing changed."; return 0; }

    while IFS=$'\t' read -r label orig archive status; do
        [[ "$status" == "present" ]] || continue
        local src="$snap/$archive"
        [[ -f "$src" ]] || die "Missing archive in snapshot: $src"
        if [[ -e "$orig" ]]; then
            if ! $FORCE; then
                die "Target exists: $orig — re-run with --force to overwrite it (its current content is NOT auto-backed-up)."
            fi
            _assert_removable "$orig"
            rm -rf "$orig"
        fi
        mkdir -p "$(dirname "$orig")"
        tar -xzf "$src" -C "$(dirname "$orig")" || die "Failed to extract $src into $(dirname "$orig")"
        ok "restored $label → $orig"
    done < "$snap/manifest.tsv"

    ok "Restore complete from: $snap"
}

# ── list ──────────────────────────────────────────────────────────────
cmd_list() {
    [[ -d "$BACKUP_DIR" ]] || { info "No snapshots under $BACKUP_DIR."; return 0; }
    local found=false d
    printf "${BOLD}Snapshots in %s:${RESET}\n" "$BACKUP_DIR" >&2
    for d in "$BACKUP_DIR"/cco-reset-*/; do
        [[ -d "$d" && -f "$d/manifest.tsv" ]] || continue
        found=true
        local n; n="$(grep -c $'\tpresent$' "$d/manifest.tsv" 2>/dev/null)" || n=0
        printf "  %s  ${CYAN}(%s root(s), %s)${RESET}\n" "$(basename "${d%/}")" "$n" "$(_dir_size "${d%/}")" >&2
    done
    $found || info "  (none)"
}

# ── Arg parsing & dispatch ────────────────────────────────────────────
# Print the leading comment header (everything between the shebang and `set -e`).
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '/^set -euo/d; s/^# \{0,1\}//'; }

main() {
    local cmd="reset"
    case "${1:-}" in
        reset|backup|restore|list|paths) cmd="$1"; shift ;;
        -h|--help) usage; exit 0 ;;
    esac

    local positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--backup-dir) BACKUP_DIR="$2"; shift 2 ;;
            -y|--yes)        ASSUME_YES=true; shift ;;
            -n|--dry-run)    DRY_RUN=true; shift ;;
            -f|--force)      FORCE=true; shift ;;
            -h|--help)       usage; exit 0 ;;
            -*)              die "Unknown option: $1" ;;
            *)               positional+=("$1"); shift ;;
        esac
    done

    case "$cmd" in
        reset)   cmd_reset ;;
        backup)  cmd_backup ;;
        restore) cmd_restore "${positional[0]:-}" ;;
        list)    cmd_list ;;
        paths)   cmd_paths ;;
    esac
}

main "$@"
