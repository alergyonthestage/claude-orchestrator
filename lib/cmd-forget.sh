#!/usr/bin/env bash
# lib/cmd-forget.sh — `cco forget <project>` deregistration (ADR-0021 Dec.2/3).
#
# The explicit inverse of the entry trio (init / init --migrate / join): "stop
# tracking this project on THIS machine." It removes cco's internal, id-keyed
# bookkeeping for the project and NEVER touches the user's repo or its committed
# <repo>/.cco/ — a project is decentralized config in the user's own repo,
# removed only by the user's own git.
#
# Cleaned (keyed by the project id = project.yml `name:` = the index key):
#   - STATE index: the `projects:<id>` membership entry, and each member repo's
#     `paths:<repo>` entry — but a member kept by ANOTHER project is preserved
#     (shared-repo guard, path-based via _index_paths_get_bindings).
#   - STATE  <state>/cco/projects/<id>/  (memory/session, update meta+base)
#   - DATA   <data>/cco/projects/<id>/   (install-provenance `source`)
#   - CACHE  <cache>/cco/projects/<id>/  (managed runtime overlays)
#   - the tags.yml `projects/<id>` binding (the one thing that does NOT
#     auto-return — re-tag if the project is resumed; ADR-0021 Dec.3).
#
# Self-healing (ADR-0021 Dec.3): if the repo's .cco/ is kept, the index
# re-registers from the still-valid project.yml on the next `cco start` from
# that repo (or `cco resolve --scan`). `forget` is therefore safe and reversible
# for everything except the user-authored tags.
#
# --purge (ADR-0021 D2 fwd-annot): optionally delete the committed <repo>/.cco/
# of every member repo this project OWNS (status synced|divergent via
# _project_member_status) — never a foreign/shared/code-only/unresolved repo —
# each backed up first (ADR-0006) with explicit consent (--purge, or an
# interactive prompt; non-interactive without --purge skips; ADR-0029 D2).
#
# Provides: cmd_forget()
# Dependencies: colors.sh, paths.sh (_cco_{state,data,cache}_dir),
#   index.sh (_index_get_project_repos/_index_remove_project/_index_pp_remove_project/
#   _index_paths_get_bindings/_project_iter_members), tags.sh (_tags_get/_tags_forget),
#   reminders.sh (_reminder_git_dirty)

# Return 0 (true) iff the PATH that <forgetting> binds <repo> to is still bound by
# a project OTHER than the one being forgotten (ADR-0051 D5 — sharing is a PATH
# property, decided by path coincidence, never by name). Informational under
# scoping: forgetting a project removes only ITS own labels, so a shared path is
# never orphaned on the machine. Usage: _forget_repo_still_shared <repo> <forgetting>
_forget_repo_still_shared() {
    local repo="$1" forgetting="$2" path proj name
    path=$(_index_get_path "$forgetting" "$repo")
    [[ -z "$path" ]] && return 1
    while IFS=$'\t' read -r proj name; do
        [[ "$proj" == "$forgetting" ]] && continue
        [[ -n "$proj" ]] && return 0
    done < <(_index_paths_get_bindings "$path")
    return 1
}

# Back up <repo>/.cco/ as a raw tar into STATE before --purge deletes it
# (ADR-0006 pattern: atomic-staged .tmp → verify → mv; 0600; machine-local,
# never synced). Echoes the archive path on success; returns 1 (no archive) on
# failure so the caller can REFUSE to delete — a purge must never destroy config
# it could not back up. <project> labels the archive; the tar is taken relative
# to the repo root so it expands back to .cco/.
_forget_backup_cco() {
    local repo="$1" project="$2" backups date_tag final tmp
    backups="$(_cco_state_dir)/backups"
    mkdir -p "$backups" 2>/dev/null || return 1
    date_tag=$(date -u +%Y%m%d-%H%M%S 2>/dev/null) || date_tag="unknown"
    final="$backups/forget-${project}-$(basename "$repo")-${date_tag}.tar.gz"
    tmp="$backups/.forget-${project}-$(basename "$repo")-${date_tag}.tar.gz.tmp"
    if tar -czf "$tmp" -C "$repo" .cco 2>/dev/null && tar -tzf "$tmp" >/dev/null 2>&1; then
        chmod 0600 "$tmp" 2>/dev/null || true
        mv "$tmp" "$final" && { printf '%s\n' "$final"; return 0; }
    fi
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

cmd_forget() {
    local name="" force=false purge=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) force=true; shift ;;
            --purge)  purge=true; shift ;;
            --help|-h)
                cat <<'EOF'
Usage: cco forget <project> [-y] [--purge]

Deregister a project on THIS machine: remove cco's internal, id-keyed
bookkeeping (the STATE index entry, STATE memory/session + update state, DATA
install-provenance, CACHE overlays, and the per-user tag binding).

By default the repo and its committed <repo>/.cco/ are NEVER touched. If the
repo's .cco/ is kept, the project re-registers automatically on the next
`cco start` from that repo (or `cco resolve --scan`); only user-authored tags do
not auto-return.

With --purge, ALSO delete the committed <repo>/.cco/ of every member repo that
this project OWNS (its project.yml `name:` == <project>) — a repo that hosts a
different project, or is shared with another project, is left untouched. Each
deletion is preceded by a backup tar into STATE, and a warning if the .cco/ has
uncommitted changes. --purge is the explicit consent (no extra prompt; works
non-interactively, like -y); without it an interactive run asks before deleting.

Options:
  -y, --yes            Skip the deregistration confirmation prompt
  --purge              Also delete owned <repo>/.cco/ dirs (with backup); the
                       explicit consent for that deletion
EOF
                return 0
                ;;
            -*) die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then name="$1"; shift
                else die "Unexpected argument: $1"; fi
                ;;
        esac
    done

    [[ -z "$name" ]] && die "Usage: cco forget <project>"

    # ── Gather what exists to deregister (id = the name argument) ──────────
    local member_repos; member_repos=$(_index_get_project_repos "$name")
    local state_dir data_dir cache_dir
    state_dir="$(_cco_state_dir)/projects/$name"
    data_dir="$(_cco_data_dir)/projects/$name"
    cache_dir="$(_cco_cache_dir)/projects/$name"
    local cur_tags; cur_tags=$(_tags_get projects "$name")

    # Under per-project scoping (ADR-0051) forgetting a project removes ALL of its
    # own per-project labels (project_paths block); other projects keep their own
    # independent bindings. The shared check is now informational: which of this
    # project's paths remain referenced (under any label) by another project — so
    # the user knows the directory is not orphaned on the machine. Read BEFORE any
    # removal.
    local -a paths_to_remove=() paths_kept=()
    local repo
    for repo in $member_repos; do
        paths_to_remove+=("$repo")
        _forget_repo_still_shared "$repo" "$name" && paths_kept+=("$repo")
    done

    # Owned member repos whose committed .cco/ --purge may delete: resolved AND
    # owned by THIS project (status synced|divergent). foreign/code-only/unresolved
    # are never purged (the ownership guard composes with the shared-repo guard —
    # a shared repo hosts another project, so its name differs → foreign → kept).
    # Computed BEFORE any index removal so _project_iter_members can resolve paths.
    local -a purge_paths=() purge_div=()
    local m_name m_path m_status
    while IFS=$'\t' read -r m_name m_path m_status; do
        [[ -z "$m_name" ]] && continue
        case "$m_status" in
            synced|divergent) purge_paths+=("$m_path"); purge_div+=("$m_status") ;;
        esac
    done < <(_project_iter_members "$name")

    # Nothing tracked at all → surface the typo rather than silently succeeding.
    if [[ -z "$member_repos" && ! -d "$state_dir" && ! -d "$data_dir" \
          && ! -d "$cache_dir" && -z "$cur_tags" ]]; then
        local _ftip="Re-discover it with 'cco resolve --scan <dir>'."
        [[ -f "$PWD/.cco/project.yml" ]] && \
            _ftip="This directory has a .cco/ — register it with 'cco join', or re-discover with 'cco resolve --scan <dir>'."
        die "Project '$name' is not tracked on this machine — nothing to forget. $_ftip"
    fi

    # ── Preview ───────────────────────────────────────────────────────────
    info "cco forget '$name' will deregister (the repo and its .cco/ are untouched):"
    [[ -n "$member_repos" ]] && info "  • index: project membership entry"
    if [[ ${#paths_to_remove[@]} -gt 0 ]]; then
        info "  • index: path entries — ${paths_to_remove[*]}"
    fi
    if [[ ${#paths_kept[@]} -gt 0 ]]; then
        info "  • note: these paths stay referenced by other projects (their bindings are untouched) — ${paths_kept[*]}"
    fi
    [[ -d "$state_dir" ]] && info "  • STATE: $state_dir"
    [[ -d "$data_dir"  ]] && info "  • DATA:  $data_dir"
    [[ -d "$cache_dir" ]] && info "  • CACHE: $cache_dir"
    [[ -n "$cur_tags"  ]] && info "  • tags:  [$cur_tags] (will not auto-return)"
    if [[ ${#purge_paths[@]} -gt 0 ]]; then
        if [[ "$purge" == true ]]; then
            warn "  • --purge: DELETE owned .cco/ (backed up first) in:"
        else
            info "  • owned repos with a .cco/ (pass --purge to delete them, with backup):"
        fi
        local _i
        for _i in "${!purge_paths[@]}"; do
            local _tag=""; [[ "${purge_div[$_i]}" == "divergent" ]] && _tag="  ${YELLOW}[divergent — unsynced local edits]${NC}"
            info "      ${purge_paths[$_i]}/.cco${_tag}"
        done
    fi

    # ── Confirm ─────────────────────────────────────────────────────────────
    if [[ "$force" != true ]]; then
        if [[ -t 0 ]]; then
            printf "Forget '%s'? [y/N] " "$name" >&2
            local reply; read -r reply
            [[ "$reply" =~ ^[Yy]$ ]] || { info "Aborted"; return 0; }
        else
            die "Refusing to forget '$name' without confirmation — re-run with -y."
        fi
    fi

    # ── Execute (out-of-repo bookkeeping only) ────────────────────────────
    # Remove this project's membership AND its entire per-project path block
    # (ADR-0051 D5). Other projects' bindings — even to the same paths — are their
    # own independent labels and are never touched.
    # S2b: checked BEFORE the irreversible rm -rf below. Called bare, a failed index
    # removal left the project still listed in the index while its STATE/DATA/CACHE
    # were already gone — half-forgotten, and the half that survives is the one
    # `cco start` reads. Dying first keeps the operation re-runnable.
    if [[ -n "$member_repos" ]]; then
        if ! _index_remove_project "$name" || ! _index_pp_remove_project "$name"; then
            die "Could not remove '$name' from the machine-local index — nothing was deleted. Check the index bucket's permissions and free space, then re-run."
        fi
    fi
    rm -rf "$state_dir" "$data_dir" "$cache_dir"
    _tags_forget projects "$name"

    # ── Optional --purge: delete owned <repo>/.cco/ (with backup + consent) ──
    # Consent model (ADR-0021 D2 fwd-annot / ADR-0029 D2): --purge IS the explicit
    # consent (proceeds, also non-interactively); without it an interactive run
    # asks, and a non-interactive run SKIPS the deletion (the opt-in stage never
    # fires unattended — the default "repo untouched" is preserved).
    if [[ ${#purge_paths[@]} -gt 0 ]]; then
        local do_purge=false
        if [[ "$purge" == true ]]; then
            do_purge=true
        elif [[ -t 0 ]]; then
            printf "Also DELETE the owned .cco/ dir(s) above? [y/N] " >&2
            local preply; read -r preply
            [[ "$preply" =~ ^[Yy]$ ]] && do_purge=true
        else
            info "Non-interactive: skipping .cco/ deletion (re-run with --purge to delete)."
        fi

        if [[ "$do_purge" == true ]]; then
            local _i p archive
            for _i in "${!purge_paths[@]}"; do
                p="${purge_paths[$_i]}"
                [[ -d "$p/.cco" ]] || continue
                if _reminder_git_dirty "$p" ".cco"; then
                    warn "$(basename "$p"): .cco/ has uncommitted changes — backing up before delete"
                fi
                if archive=$(_forget_backup_cco "$p" "$name"); then
                    rm -rf "$p/.cco"
                    ok "Deleted $p/.cco (backup: $archive)"
                else
                    warn "Could not back up $p/.cco — left in place (not deleted)"
                fi
            done
        fi
    fi

    ok "Forgot project '$name'."
    info "It re-registers on the next 'cco start' from its repo, or 'cco resolve --scan'."
}
