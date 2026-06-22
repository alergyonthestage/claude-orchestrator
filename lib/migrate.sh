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

# ── Eager global migration (ADR-0025 §1 / design §9 P2) ──────────────
# The global/non-project cutover is EAGER, owned by `cco update`. On first run
# against a legacy install it populates ~/.cco from the verified backup
# (global/.claude + authored packs/ + templates/ + setup scripts + mcp-packages
# + secrets.env + languages), and seeds the atomic profile→tag set for
# profile-exclusive packs (ADR-0010 §5). Idempotent: ~/.cco/global/.claude
# presence is the "already migrated" signal. Reads from the backup (immutable
# snapshot), never the live user-config/ (which it leaves intact).

# Seed one resource→tag binding into the DATA tags registry (<data>/cco/tags.yml).
# Minimal writer for the one-shot migration seed; the full `cco tag` API is P3.
# Format (design §2.2): typed keys {packs,projects,templates} → name → [tags].
_cco_seed_resource_tag() {
    local kind="$1" name="$2" tag="$3"   # kind: packs|projects|templates
    local f; f="$(_cco_data_dir)/tags.yml"
    mkdir -p "$(dirname "$f")"
    [[ -f "$f" ]] || printf '# Per-user tag registry — seeded by cco migration\n' > "$f"
    # Ensure the typed section exists.
    grep -q "^${kind}:" "$f" 2>/dev/null || printf '%s:\n' "$kind" >> "$f"
    # Append/extend the resource entry (one-shot seed: a name appears once here).
    if grep -qE "^  ${name}:" "$f" 2>/dev/null; then
        # Already present — add the tag if missing (append inside the [] list).
        awk -v n="  ${name}:" -v t="$tag" '
            $0 ~ "^" n {
                if (index($0, t) == 0) { sub(/\]\s*$/, ", " t "]") }
            }
            { print }
        ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    else
        # Insert under the typed section header.
        awk -v sec="^${kind}:" -v line="  ${name}: [${tag}]" '
            { print }
            $0 ~ sec && !done { print line; done=1 }
        ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
}

# Populate ~/.cco from an extracted backup tree, run profile→tag seeding.
# $1 = extracted vault dir (has global/, packs/, templates/, .git, .vault-profile).
_cco_populate_global_from() {
    local src="$1" cfg
    cfg="$(_cco_config_dir)"

    # Global Claude config (shared across all profiles).
    if [[ -d "$src/global/.claude" ]]; then
        mkdir -p "$cfg/global"
        cp -r "$src/global/.claude" "$cfg/global/.claude"
    fi
    # Global setup scripts / mcp list (legacy: under global/).
    local f
    for f in setup.sh setup-build.sh mcp-packages.txt; do
        [[ -f "$src/global/$f" ]] && cp "$src/global/$f" "$cfg/$f"
    done
    # Secrets (gitignored; legacy under global/ or vault root) → ~/.cco top-level.
    for f in "$src/global/secrets.env" "$src/secrets.env"; do
        [[ -f "$f" ]] && { cp "$f" "$cfg/secrets.env"; break; }
    done
    for f in "$src/global/secrets.env.example" "$src/secrets.env.example"; do
        [[ -f "$f" ]] && { cp "$f" "$cfg/secrets.env.example"; break; }
    done
    # Authored templates (always shared → no origin tag).
    [[ -d "$src/templates" ]] && { mkdir -p "$cfg/templates"; cp -r "$src/templates/." "$cfg/templates/" 2>/dev/null || true; }
    # Working-tree packs (shared + the active profile's view).
    [[ -d "$src/packs" ]] && { mkdir -p "$cfg/packs"; cp -r "$src/packs/." "$cfg/packs/" 2>/dev/null || true; }

    # Languages: decompose the legacy global .cco/meta (old location) → ~/.cco/languages.
    local legacy_meta="$src/global/.claude/.cco/meta"
    if [[ -f "$legacy_meta" ]]; then
        local comm docs code
        comm=$(awk '/^languages:/{l=1;next} /^[a-z]/&&!/^  /{l=0} l&&/communication:/{sub(/.*: /,"");print;exit}' "$legacy_meta")
        docs=$(awk '/^languages:/{l=1;next} /^[a-z]/&&!/^  /{l=0} l&&/documentation:/{sub(/.*: /,"");print;exit}' "$legacy_meta")
        code=$(awk '/^languages:/{l=1;next} /^[a-z]/&&!/^  /{l=0} l&&/code_comments:/{sub(/.*: /,"");print;exit}' "$legacy_meta")
        [[ -n "$comm$docs$code" ]] && _write_languages "${comm:-English}" "${docs:-English}" "${code:-English}"
    fi

    # Atomic profile→tag seed: each non-default branch's .vault-profile packs are
    # profile-exclusive → populate (if missing) + tag with the origin profile.
    if [[ -d "$src/.git" ]]; then
        local default_branch branch
        default_branch=$(git -C "$src" rev-parse --verify main >/dev/null 2>&1 && echo main \
            || (git -C "$src" rev-parse --verify master >/dev/null 2>&1 && echo master \
            || git -C "$src" rev-parse --abbrev-ref HEAD 2>/dev/null))
        while IFS= read -r branch; do
            branch="${branch#"${branch%%[![:space:]]*}"}"   # ltrim
            [[ -z "$branch" || "$branch" == "$default_branch" ]] && continue
            local vp profile packs_list pack
            vp=$(git -C "$src" show "$branch:.vault-profile" 2>/dev/null || true)
            [[ -z "$vp" ]] && continue
            profile=$(printf '%s\n' "$vp" | awk '/^profile:/{sub(/.*: */,"");print;exit}')
            [[ -z "$profile" ]] && profile="$branch"
            packs_list=$(printf '%s\n' "$vp" | awk '
                /^  packs:/{p=1;next} /^[^ ]/{p=0} /^  [^ ]/&&!/^  packs:/{p=0}
                p&&/^    - /{sub(/^    - */,"");print}')
            while IFS= read -r pack; do
                [[ -z "$pack" ]] && continue
                # Populate the exclusive pack from its branch if not already present.
                if [[ ! -d "$cfg/packs/$pack" ]]; then
                    git -C "$src" archive "$branch" "packs/$pack" 2>/dev/null | tar -x -C "$cfg" 2>/dev/null || true
                fi
                _cco_seed_resource_tag packs "$pack" "$profile"
            done <<< "$packs_list"
        done < <(git -C "$src" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)
    fi
}

_cco_migrate_global() {
    _cco_host_side_ok || return 0

    local cfg state backups
    cfg="$(_cco_config_dir)"
    state="$(_cco_state_dir)"
    backups="$state/backups"

    # Already migrated (idempotent) → nothing to do.
    [[ -d "$cfg/global/.claude" ]] && return 0
    # No verified backup ⇒ no legacy install to migrate from (fresh install).
    _cco_have_backup "$backups" || return 0

    local backup
    backup=$(ls "$backups"/vault-*.tar.gz 2>/dev/null | head -1)
    [[ -n "$backup" ]] || return 0

    info "Migrating global config to the decentralized layout (~/.cco)…"
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/cco-migrate.XXXXXX") || { warn "Could not create a temp dir for migration."; return 1; }
    if ! tar -xzf "$backup" -C "$tmp" 2>/dev/null; then
        rm -rf "$tmp"
        warn "Could not read the legacy-vault backup — global migration skipped; retry on the next 'cco update'."
        return 1
    fi

    _cco_populate_global_from "$tmp"
    rm -rf "$tmp"

    # Migration summary + legacy-vault keep/remove note (maintainer-confirmed copy).
    ok "Migration complete — your global config now lives in ~/.cco:"
    echo "    • global/.claude   (agents, rules, skills, settings)" >&2
    echo "    • packs/, templates/   (authored resources)" >&2
    echo "    • setup.sh, setup-build.sh, mcp-packages.txt" >&2
    echo "    • secrets.env, languages" >&2
    echo "  Per-project config is migrated separately:" >&2
    echo "    cco init --migrate <project>   (run inside each repo)" >&2
    echo "" >&2
    info "Legacy vault preserved as a fallback at $USER_CONFIG_DIR (incl. its git history)."
    echo "  Remove the vault manually once you've confirmed the new layout works:" >&2
    echo "    rm -rf $USER_CONFIG_DIR" >&2
    echo "  cco will never delete it for you." >&2
    return 0
}
