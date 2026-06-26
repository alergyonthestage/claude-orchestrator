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

# The migration-state marker (<state>/cco/migration-state) is a newline-separated
# flag set. The FILE's presence means "legacy vault backed up" (F43); a
# `global-migrated` line means the eager global migration ran. The flag — not
# ~/.cco/global presence — is the idempotency gate (ADR-0026): `cco init` may
# populate ~/.cco/global from defaults, so presence is no longer a "migrated"
# signal. Writes are append-only so the backup step never wipes the flag.
_cco_marker_has() {
    local marker="$1" flag="$2"
    [[ -f "$marker" ]] || return 1
    grep -qxF "$flag" "$marker" 2>/dev/null
}
_cco_marker_add() {
    local marker="$1" flag="$2"
    _cco_marker_has "$marker" "$flag" && return 0
    printf '%s\n' "$flag" >> "$marker" 2>/dev/null || true
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
    # already exists — heal the marker and stop. Create only if absent (never
    # truncate: an existing marker may carry the global-migrated flag).
    if _cco_have_backup "$backups"; then
        [[ -f "$marker" ]] || : > "$marker" 2>/dev/null || true
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
    # Create only if absent (never truncate a marker that may carry global-migrated).
    mv -f "$tmp" "$final"
    [[ -f "$marker" ]] || : > "$marker" 2>/dev/null || true

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
# Delegates to the canonical writer `_tags_add` (lib/tags.sh) — single writer of
# the registry (P12 DRY). Format (design §2.2): typed keys {packs,projects,
# templates} → name → [tags]. kind: packs|projects|templates.
_cco_seed_resource_tag() {
    _tags_add "$1" "$2" "$3"
}

# Populate ~/.cco from an extracted backup tree, run profile→tag seeding.
# $1 = extracted vault dir (has global/, packs/, templates/, .git, .vault-profile).
_cco_populate_global_from() {
    local src="$1" cfg
    cfg="$(_cco_config_dir)"

    # Global Claude config (shared across all profiles). Stage into a same-dir
    # sibling then atomic-rename, so a partial/failed copy never leaves an
    # incomplete ~/.cco/global/.claude that check_global would wrongly accept (H1).
    if [[ -d "$src/global/.claude" ]]; then
        mkdir -p "$cfg/global"
        rm -rf "$cfg/global/.claude.tmp"
        if cp -r "$src/global/.claude" "$cfg/global/.claude.tmp"; then
            rm -rf "$cfg/global/.claude"
            mv "$cfg/global/.claude.tmp" "$cfg/global/.claude"
        else
            rm -rf "$cfg/global/.claude.tmp"
            warn "Failed to populate ~/.cco/global/.claude from the legacy vault."
            return 1
        fi
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

# Back up the current ~/.cco before a non-destructive migration overwrite, then
# ask explicit confirmation. Returns 0 to proceed (backup written + confirmed,
# and ~/.cco/global removed so the populate writes fresh), 1 to skip. The archive
# mirrors the raw-tar legacy backup; it lands in STATE (machine-local, 0600).
_cco_confirm_overwrite_global() {
    local cfg="$1" backups="$2"
    _cco_ensure_dir "$backups"
    local ts archive tmp
    ts=$(date -u +%Y%m%d-%H%M%S)
    archive="$backups/cco-config-$ts.tar.gz"
    tmp="$backups/.cco-config-$ts.tar.gz.tmp"
    if tar -czf "$tmp" -C "$cfg" . 2>/dev/null && tar -tzf "$tmp" >/dev/null 2>&1; then
        chmod 0600 "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$archive"
    else
        rm -f "$tmp"
        warn "Could not back up the current ~/.cco — aborting the global migration to stay safe."
        return 1
    fi
    warn "~/.cco/global already exists (populated by 'cco init' or a previous run)."
    info "Migrating the legacy vault will overwrite it. A restorable backup was saved:"
    echo "    $archive" >&2
    local ans=""
    if [[ "${CCO_ASSUME_YES:-}" == "1" ]]; then ans="y"
    elif (exec < /dev/tty) 2>/dev/null; then read -rp "  Proceed with the migration? [y/N]: " ans < /dev/tty; fi
    ans="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')"
    [[ "$ans" == "y" || "$ans" == "yes" ]] || return 1
    rm -rf "$cfg/global"
    return 0
}

_cco_migrate_global() {
    _cco_host_side_ok || return 0

    local cfg state backups marker
    cfg="$(_cco_config_dir)"
    state="$(_cco_state_dir)"
    backups="$state/backups"
    marker="$state/migration-state"

    # Idempotent (ADR-0026): the gate is the `global-migrated` marker flag, NOT
    # ~/.cco/global presence (which `cco init` may have created from defaults).
    _cco_marker_has "$marker" global-migrated && return 0
    # No verified backup ⇒ no legacy install to migrate from (fresh install).
    _cco_have_backup "$backups" || return 0

    # If ~/.cco/global already exists (e.g. `cco init` ran before `cco update`),
    # migration is NON-DESTRUCTIVE: back up the current ~/.cco (restorable) and
    # ask explicit confirmation before overwriting it from the vault.
    if [[ -d "$cfg/global/.claude" ]]; then
        _cco_confirm_overwrite_global "$cfg" "$backups" || { info "Global migration skipped (declined). Re-run 'cco update' to retry."; return 0; }
    fi

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

    if ! _cco_populate_global_from "$tmp"; then
        rm -rf "$tmp"
        warn "Global migration did not complete — your legacy vault is untouched; retry on the next 'cco update'."
        return 1
    fi
    rm -rf "$tmp"
    # Record the gate only after a successful populate (ADR-0026): a failed populate
    # must stay retryable on the next 'cco update', and must not leak its temp (H1).
    _cco_marker_add "$marker" global-migrated

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

# ── Lazy per-project migration (ADR-0006/0021 / design §9 P2) ───────
# `cco init --migrate <project> [--sync]` — run inside an already-cloned repo.
# Reads that project's config from the verified backup, writes the COMPLETE
# FINAL machine-agnostic <repo>/.cco/ in ONE pass (repos+llms+packs coordinates),
# relocates memory to STATE, prompts profile→tag, and registers the index LAST.
# Atomic & staged (F44); name-uniqueness asserted (F12); non-clobbering (F11).

# Parse legacy `repos:` (sanitized path:@local + name + url[+ref], or raw path)
# → one TSV line "name<TAB>url<TAB>ref<TAB>path" per repo.
_migrate_legacy_repos() {
    awk '
        function flush(){ if(name!="") print name "\t" url "\t" ref "\t" path; name=url=ref=path="" }
        function val(l,  v){ v=l; sub(/^[a-z_]+: */,"",v); gsub(/["\047]/,"",v); sub(/ *#.*$/,"",v); gsub(/^ +| +$/,"",v); return v }
        function field(l,  k){ k=l; sub(/:.*/,"",k); gsub(/^ +/,"",k);
            if(k=="path")path=val(l); else if(k=="name")name=val(l);
            else if(k=="url")url=val(l); else if(k=="ref")ref=val(l) }
        /^repos:/{r=1;next}
        r&&/^[^ #]/{flush();r=0}
        r&&/^  - /{ flush(); line=$0; sub(/^  - /,"",line); field(line); next }
        r&&/^    [a-z]/{ line=$0; sub(/^    /,"",line); field(line) }
        END{flush()}
    ' "$1"
}

# Parse a simple legacy list section (`packs:` / `llms:` as `- name`) → names.
_migrate_legacy_list() {
    awk -v sec="$2" '
        $0 ~ "^" sec ":" {s=1;next}
        s&&/^[^ #]/{exit}
        s&&/^  - name:/{v=$0;sub(/^  - name: */,"",v);gsub(/["\047]/,"",v);gsub(/^ +| +$/,"",v);print v;next}
        s&&/^  - /{v=$0;sub(/^  - */,"",v);gsub(/["\047]/,"",v);sub(/ *#.*$/,"",v);gsub(/^ +| +$/,"",v);if(v!="")print v}
    ' "$1"
}

# Read a single top-level YAML scalar (e.g. `source:`/`url:`/`variant:`) from a file.
_migrate_yml_scalar() {
    awk -v k="$2" '$0 ~ "^" k ":" {sub(/^[a-z_]+: */,"");gsub(/["\047]/,"");gsub(/^ +| +$/,"");print;exit}' "$1" 2>/dev/null
}

# ── P4 source→DATA relocation (ADR-0022 D1) ──────────────────────────
# Relocate a single resource's LEGACY in-tree .cco/source (old keys
# source:/path: + machine-local commit:/installed:/updated: + the dropped
# publish_target:) to the DATA coordinate file (url:/resource:/ref:) plus the
# STATE /update meta bookkeeping. Idempotent: a no-op when there is no legacy
# source. publish_target is dropped — the default remote is re-derived on demand
# from the url (F4).
_relocate_legacy_source() {
    local legacy="$1" new_src="$2" meta="$3"
    [[ -f "$legacy" ]] || return 0
    local url ref resource commit installed updated
    url=$(_migrate_yml_scalar "$legacy" source)
    ref=$(_migrate_yml_scalar "$legacy" ref)
    resource=$(_migrate_yml_scalar "$legacy" path)
    commit=$(_migrate_yml_scalar "$legacy" commit)
    installed=$(_migrate_yml_scalar "$legacy" installed)
    updated=$(_migrate_yml_scalar "$legacy" updated)
    # A bare-url first line (pre-FI-7 format) carries no `source:` key.
    if [[ -z "$url" ]]; then
        local first; first=$(head -1 "$legacy" 2>/dev/null)
        case "$first" in http://*|https://*) url="$first" ;; esac
    fi
    mkdir -p "$(dirname "$new_src")"
    {
        printf 'url: %s\n' "${url:-local}"
        [[ -n "$resource" ]] && printf 'resource: %s\n' "$resource"
        [[ -n "$ref" ]] && printf 'ref: %s\n' "$ref"
    } > "$new_src"
    _meta_record_provenance "$meta" "$commit" "$installed" "$updated"
    rm -f "$legacy"
    # Drop the now-empty .cco dir if nothing else remains (best-effort).
    rmdir "$(dirname "$legacy")" 2>/dev/null || true
}

# Relocate every installed pack's legacy in-tree source into DATA. Run early in
# `cco update` (idempotent; usually a no-op). Projects keep no DATA source under
# the decentralized model, and llms source is CACHE-split (ADR-0016 D2) — packs
# are the only resource whose provenance moves here.
_relocate_legacy_pack_sources() {
    [[ -d "${PACKS_DIR:-}" ]] || return 0
    local pack_dir
    for pack_dir in "$PACKS_DIR"/*/; do
        [[ -d "$pack_dir" ]] || continue
        [[ -f "$pack_dir/.cco/source" ]] || continue
        _relocate_legacy_source "$pack_dir/.cco/source" \
            "$(_cco_pack_source "$pack_dir")" "$(_cco_pack_meta "$pack_dir")"
    done
}

# The project's origin profile (the non-default branch whose .vault-profile lists
# it under sync.projects), or empty if shared/on the default branch.
_cco_project_origin_profile() {
    local src="$1" project="$2" default_branch branch
    [[ -d "$src/.git" ]] || return 0
    default_branch=$(git -C "$src" rev-parse --verify main >/dev/null 2>&1 && echo main \
        || (git -C "$src" rev-parse --verify master >/dev/null 2>&1 && echo master \
        || git -C "$src" rev-parse --abbrev-ref HEAD 2>/dev/null))
    while IFS= read -r branch; do
        branch="${branch#"${branch%%[![:space:]]*}"}"
        [[ -z "$branch" || "$branch" == "$default_branch" ]] && continue
        local vp
        vp=$(git -C "$src" show "$branch:.vault-profile" 2>/dev/null || true)
        [[ -z "$vp" ]] && continue
        if printf '%s\n' "$vp" | awk -v p="$project" '
            /^  projects:/{s=1;next} /^  [a-z]/&&!/^  projects:/{s=0} /^[^ ]/{s=0}
            s&&/^    - /{sub(/^    - */,"");gsub(/[ \t\r]/,"");if($0==p)f=1} END{exit f?0:1}'; then
            printf '%s' "$(printf '%s\n' "$vp" | awk '/^profile:/{sub(/.*: */,"");gsub(/[ \t\r]/,"");print;exit}')"
            return 0
        fi
    done < <(git -C "$src" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)
}

# Build the final project.yml at $out from the legacy project at $leg. Emits
# index entries (name<TAB>path) for repos+mounts to the file at $idx_out.
_cco_build_project_yml() {
    local leg="$1" out="$2" idx_out="$3" src="$4"
    local leg_yml="$leg/project.yml" lpaths="$leg/.cco/local-paths.yml"
    local name desc
    name=$(_migrate_yml_scalar "$leg_yml" name)
    desc=$(awk '/^description:/{sub(/^description: */,"");print;exit}' "$leg_yml" 2>/dev/null)
    : > "$idx_out"
    {
        printf 'name: %s\n' "$name"
        [[ -n "$desc" ]] && printf 'description: %s\n' "$desc"
        printf '\n'
        # repos — final coordinates (name + url? + ref?); paths → index.
        # Tab-PEEL each field: `IFS=$'\t' read` collapses empty middle fields
        # (a repo with no ref would shift @local into the ref slot).
        printf 'repos:'
        local any_repo=false rname rurl rref rpath _rline
        while IFS= read -r _rline; do
            [[ -z "$_rline" ]] && continue
            rname="${_rline%%$'\t'*}"; _rline="${_rline#*$'\t'}"
            rurl="${_rline%%$'\t'*}";  _rline="${_rline#*$'\t'}"
            rref="${_rline%%$'\t'*}";  rpath="${_rline#*$'\t'}"
            [[ -z "$rname" ]] && continue
            any_repo=true
            printf '\n  - name: %s' "$rname"
            [[ -n "$rurl" ]] && printf '\n    url: %s' "$rurl"
            [[ -n "$rref" ]] && printf '\n    ref: %s' "$rref"
            # Resolve the machine-local path for the index.
            local real="$rpath"
            [[ "$real" == "@local" || -z "$real" ]] && real=$(_local_paths_get "$lpaths" repos "$rname")
            [[ -n "$real" ]] && printf '%s\t%s\n' "$rname" "$real" >> "$idx_out"
        done < <(_migrate_legacy_repos "$leg_yml")
        $any_repo || printf ' []'
        printf '\n'
        # llms — coordinate from the installed entry's .cco/source (url/variant)
        local lname lsrc lurl lvar first=true
        while IFS= read -r lname; do
            [[ -z "$lname" ]] && continue
            $first && { printf '\nllms:'; first=false; }
            lsrc="$src/llms/$lname/.cco/source"
            lurl=$(_migrate_yml_scalar "$lsrc" url)
            lvar=$(_migrate_yml_scalar "$lsrc" variant)
            printf '\n  - name: %s' "$lname"
            [[ -n "$lurl" ]] && printf '\n    url: %s' "$lurl"
            [[ -n "$lvar" && "$lvar" != "index" ]] && printf '\n    variant: %s' "$lvar"
        done < <(_migrate_legacy_list "$leg_yml" llms)
        $first || printf '\n'
        # packs — list → map; url backfilled from the pack's recorded source
        # (read IN PLACE; the source→DATA relocation is P4). Absent → authored.
        local pname psrc purl pref pfirst=true
        while IFS= read -r pname; do
            [[ -z "$pname" ]] && continue
            $pfirst && { printf '\npacks:'; pfirst=false; }
            psrc="$src/packs/$pname/.cco/source"
            purl=$(_migrate_yml_scalar "$psrc" source); [[ "$purl" == "local" ]] && purl=""
            pref=$(_migrate_yml_scalar "$psrc" ref)
            printf '\n  - name: %s' "$pname"
            [[ -n "$purl" ]] && printf '\n    url: %s' "$purl"
            [[ -n "$pref" ]] && printf '\n    ref: %s' "$pref"
        done < <(_migrate_legacy_list "$leg_yml" packs)
        $pfirst || printf '\n'
    } > "$out"
}

# The committed .cco/ secret-exclusion gitignore (design §2.1).
_cco_write_project_gitignore() {
    cat > "$1" <<'GI'
secrets.env
*.env
*.key
*.pem
.credentials.json
!secrets.env.example
GI
}

_cco_migrate_project() {
    _cco_host_side_ok || return 0
    local project="$1" do_sync="${2:-false}"
    [[ -n "$project" ]] || die "cco init --migrate requires a project name."

    local state backups backup
    state="$(_cco_state_dir)"
    backups="$state/backups"
    # M8: a verified backup must exist and be readable before any migrate read.
    _cco_have_backup "$backups" || die "No legacy-vault backup found — run any cco command first to create one."
    backup=$(ls "$backups"/vault-*.tar.gz 2>/dev/null | head -1)
    tar -tzf "$backup" >/dev/null 2>&1 || die "Legacy-vault backup is unreadable; aborting migration."

    local target="$PWD"
    [[ -d "$target/.cco" ]] && die "$target/.cco already exists — refusing to clobber (remove it or migrate elsewhere)."

    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/cco-pmigrate.XXXXXX") || die "Could not create a temp dir."
    # shellcheck disable=SC2064
    # EXIT (not RETURN): die() calls exit, which bypasses a RETURN trap and would
    # leave the extracted vault — including secrets.env — behind in /tmp (H2).
    trap "rm -rf '$tmp'" EXIT
    tar -xzf "$backup" -C "$tmp" 2>/dev/null || die "Could not extract the legacy-vault backup."

    # Locate the legacy project (working-tree first; else from its profile branch).
    # Track the hosting branch + profile so the gitignored files (secrets.env,
    # memory/, local-paths.yml) of a NON-ACTIVE profile can be recovered from the
    # vault's profile-state shadow (BL1/BL2 — design §9 "secrets from the working
    # tree / the matching profile-state/<branch>/ shadow").
    local leg="$tmp/projects/$project"
    local found_on_branch="" found_profile="" shadow_base=""
    if [[ ! -f "$leg/project.yml" ]]; then
        local b
        while IFS= read -r b; do
            [[ -z "$b" ]] && continue
            if git -C "$tmp" cat-file -e "$b:projects/$project/project.yml" 2>/dev/null; then
                git -C "$tmp" archive "$b" "projects/$project" 2>/dev/null | tar -x -C "$tmp" 2>/dev/null \
                    && { found_on_branch="$b"; break; }
            fi
        done < <(git -C "$tmp" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)
    fi
    [[ -f "$leg/project.yml" ]] || die "Project '$project' not found in the legacy vault backup."

    # Resolve the profile-state shadow base for a non-active profile. The shadow is
    # keyed by PROFILE name (from .vault-profile), not the branch name
    # (_archive/vault/profile-isolation-design.md §2.4). Stage the shadowed,
    # gitignored local-paths.yml into $leg so the project.yml builder still registers
    # the repos' machine-local paths in the index.
    if [[ -n "$found_on_branch" ]]; then
        found_profile=$(git -C "$tmp" show "$found_on_branch:.vault-profile" 2>/dev/null \
            | awk '/^profile:/{sub(/.*: */,"");gsub(/[ \t\r]/,"");print;exit}')
        [[ -z "$found_profile" ]] && found_profile="$found_on_branch"
        shadow_base="$tmp/.cco/profile-state/$found_profile/projects/$project"
        if [[ ! -f "$leg/.cco/local-paths.yml" && -f "$shadow_base/.cco/local-paths.yml" ]]; then
            mkdir -p "$leg/.cco"
            cp "$shadow_base/.cco/local-paths.yml" "$leg/.cco/local-paths.yml" 2>/dev/null || true
        fi
    fi

    # F12: name-uniqueness — the project name must not already bind elsewhere.
    local mig_name; mig_name=$(_migrate_yml_scalar "$leg/project.yml" name)
    [[ -n "$mig_name" ]] || mig_name="$project"
    local existing; existing=$(_index_get_project_repos "$mig_name" 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
        die "A project named '$mig_name' is already registered. Migrate under a different name or 'cco forget' it first."
    fi

    # Stage the final .cco/ under temp, then atomic-move into place (F44).
    local stage="$tmp/.cco-stage" idx="$tmp/index-entries"
    mkdir -p "$stage/claude"
    _cco_build_project_yml "$leg" "$stage/project.yml" "$idx" "$tmp"
    # Authored config tree: legacy projects/<p>/.claude → .cco/claude.
    [[ -d "$leg/.claude" ]] && cp -r "$leg/.claude/." "$stage/claude/" 2>/dev/null || true
    # H5 project config + secrets (gitignored) + skeleton. The gitignored secrets.env
    # comes from the working tree for an active-profile project, or from the
    # profile-state shadow for a non-active profile (BL1).
    local f
    for f in mcp.json setup.sh mcp-packages.txt secrets.env secrets.env.example; do
        if [[ -f "$leg/$f" ]]; then
            cp "$leg/$f" "$stage/$f"
        elif [[ -n "$shadow_base" && -f "$shadow_base/$f" ]]; then
            cp "$shadow_base/$f" "$stage/$f"
        fi
    done
    [[ -f "$stage/secrets.env" && ! -f "$stage/secrets.env.example" ]] && \
        sed 's/=.*/=/' "$stage/secrets.env" > "$stage/secrets.env.example" 2>/dev/null || true
    # Authored (no-coordinate) packs travel with the project (P15).
    if [[ -d "$leg/.cco/packs" ]]; then
        mkdir -p "$stage/packs"; cp -r "$leg/.cco/packs/." "$stage/packs/" 2>/dev/null || true
    fi
    _cco_write_project_gitignore "$stage/.gitignore"

    # Secret-scan committed files (secrets.env is gitignored; *.example exempt, FR-S3).
    local cf hit
    while IFS= read -r cf; do
        [[ "$cf" == *"/secrets.env" || "$cf" == *.example ]] && continue
        if hit=$(_secret_match_filename "$cf" 2>/dev/null) && [[ -n "$hit" ]]; then
            die "Refusing to migrate: a secret-like file would be committed: ${cf#$stage/}"
        fi
    done < <(find "$stage" -type f ! -path '*/secrets.env')

    # Atomic move into the repo (F44): a partial .cco/ never survives a failure.
    mv "$stage" "$target/.cco" || die "Failed to install the migrated .cco/ into $target."

    # Memory → STATE, machine-local, non-clobber (F11 / ADR-0009). For a non-active
    # profile the memory lives in the profile-state shadow, not the archived tree (BL2).
    # Canonical session-memory home (H7): must equal where cmd-start mounts it
    # (<state>/projects/<id>/session/memory), not <state>/projects/<id>/memory.
    local mem_dst src_mem; mem_dst="$(_cco_project_session_memory "$mig_name")"
    for src_mem in "$leg/memory" ${shadow_base:+"$shadow_base/memory"}; do
        [[ -d "$src_mem" ]] || continue
        mkdir -p "$mem_dst"
        cp -rn "$src_mem/." "$mem_dst/" 2>/dev/null || true
    done

    # Register the index LAST (so a failed migrate leaves no dangling binding).
    # Member names are space-separated (the canonical index format, §3).
    local rname rpath; local -a repo_names=()
    while IFS=$'\t' read -r rname rpath; do
        [[ -z "$rname" ]] && continue
        # AD5 (ADR-0002): never silently re-point a logical name already bound to a
        # different path (mirrors cco init / resolve --scan). Keep the project
        # membership but warn so the user can rebind deliberately (H3).
        if _index_path_conflicts "$rname" "$rpath"; then
            warn "Repo '$rname' is already bound to $(_index_get_path "$rname") — keeping the existing binding (AD5). Run 'cco resolve' to rebind."
        else
            _index_set_path "$rname" "$rpath"
        fi
        repo_names+=("$rname")
    done < "$idx"
    [[ ${#repo_names[@]} -gt 0 ]] && _index_set_project_repos "$mig_name" "${repo_names[@]}"

    # Born at the latest schema + seed the 3-way-merge base (P5): the migration
    # wrote the complete final project.yml/claude tree in one pass, so `cco update`
    # must run zero (legacy .claude-layout) migrations against it.
    _cco_project_seed_update_state "$target/.cco" "base"

    ok "Migrated project '$mig_name' into $target/.cco/ (Case A)."

    # Profile→tag prompt (ADR-0010 §5 / F42) — only for a non-default origin profile.
    local origin; origin=$(_cco_project_origin_profile "$tmp" "$project")
    if [[ -n "$origin" ]]; then
        echo "This project came from vault profile '$origin'." >&2
        echo "Convert it into a tag? You'll find it with: cco list --tag $origin" >&2
        local ans=""
        if [[ "${CCO_ASSUME_YES:-}" == "1" ]]; then ans="y"
        elif (exec < /dev/tty) 2>/dev/null; then read -rp "  Convert? [Y/n]: " ans < /dev/tty; fi
        ans="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')"
        if [[ "$ans" != "n" ]]; then
            _cco_seed_resource_tag projects "$mig_name" "$origin"
            ok "Tagged '$mig_name' as '$origin'."
        fi
    fi

    if [[ "$do_sync" == "true" ]]; then
        info "Propagating .cco/ to the project's other member repos…"
        cmd_sync --auto-approve 2>/dev/null || warn "Run 'cco sync' to propagate to member repos."
    fi
    return 0
}

# `cco join [--sync]` — register a freshly-cloned, already-migrated repo's .cco/
# into this machine's index (reuses the resolve/index primitives). The repo
# hosts its own project; member paths are resolved on demand at start/resolve.
# Scope (review H6): this is Journey C — registering a repo that ALREADY has a
# committed .cco/project.yml. Journey E (`cco join <project>` adding the current
# repo as a NEW member to an existing project's repos[]) is NOT implemented here
# and needs a maintainer design decision (it changes join's signature + edits a
# holder repo's project.yml). Until then `cco join` takes no project argument.
cmd_join() {
    local do_sync=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sync) do_sync=true; shift ;;
            --help) echo "Usage: cco join [--sync]   (run inside a cloned repo that already has a committed .cco/; registers its project + members on this machine)"; return 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    local repo="$PWD"
    [[ -f "$repo/.cco/project.yml" ]] || die "No .cco/project.yml here — run 'cco join' inside a cloned project repo."
    local pname; pname=$(_cco_project_id "$repo")
    # Register member repos by name (space-separated, §3); unresolved paths are
    # prompted at start/resolve.
    local rname; local -a repo_names=()
    while IFS=$'\t' read -r rname _ _; do
        [[ -z "$rname" ]] && continue
        repo_names+=("$rname")
    done < <(yml_get_repo_coords "$repo/.cco/project.yml")
    [[ ${#repo_names[@]} -gt 0 ]] && _index_set_project_repos "$pname" "${repo_names[@]}"
    # Guidance (H6): join binds no member paths, so by-name `cco resolve <pname>`
    # cannot find the unit yet. Point at the cwd-based resolve, which walks up from
    # this repo and works without a prior binding.
    ok "Joined project '$pname' on this machine. Run 'cco resolve' from inside this repo to bind its member paths."
    [[ "$do_sync" == "true" ]] && { cmd_sync --auto-approve 2>/dev/null || true; }
    return 0
}
