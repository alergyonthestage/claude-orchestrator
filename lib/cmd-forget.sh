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
#     (shared-repo guard, _index_repos_get_projects).
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
# Provides: cmd_forget()
# Dependencies: colors.sh, paths.sh (_cco_{state,data,cache}_dir),
#   index.sh (_index_get_project_repos/_index_remove_project/_index_remove_path/
#   _index_repos_get_projects), tags.sh (_tags_get/_tags_forget)

# Return 0 (true) iff <repo> is still referenced by a project OTHER than the one
# currently being forgotten — i.e. its index paths: entry must be preserved.
_forget_repo_still_shared() {
    local repo="$1" forgetting="$2" p
    while IFS= read -r p; do
        [[ "$p" == "$forgetting" ]] && continue
        [[ -n "$p" ]] && return 0
    done < <(_index_repos_get_projects "$repo")
    return 1
}

cmd_forget() {
    local name="" force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) force=true; shift ;;
            --help|-h)
                cat <<'EOF'
Usage: cco forget <project> [-y]

Deregister a project on THIS machine: remove cco's internal, id-keyed
bookkeeping (the STATE index entry, STATE memory/session + update state, DATA
install-provenance, CACHE overlays, and the per-user tag binding).

The repo and its committed <repo>/.cco/ are NEVER touched. If the repo's .cco/
is kept, the project re-registers automatically on the next `cco start` from
that repo (or `cco resolve --scan`); only user-authored tags do not auto-return.

Options:
  -y, --yes            Skip the confirmation prompt
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

    # Member repos whose paths: entry is safe to drop (not shared with another
    # project). The shared-repo guard reads the index BEFORE any removal.
    local -a paths_to_remove=() paths_kept=()
    local repo
    for repo in $member_repos; do
        if _forget_repo_still_shared "$repo" "$name"; then
            paths_kept+=("$repo")
        else
            paths_to_remove+=("$repo")
        fi
    done

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
        info "  • index: KEEPING shared path entries (used by other projects) — ${paths_kept[*]}"
    fi
    [[ -d "$state_dir" ]] && info "  • STATE: $state_dir"
    [[ -d "$data_dir"  ]] && info "  • DATA:  $data_dir"
    [[ -d "$cache_dir" ]] && info "  • CACHE: $cache_dir"
    [[ -n "$cur_tags"  ]] && info "  • tags:  [$cur_tags] (will not auto-return)"

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
    [[ -n "$member_repos" ]] && _index_remove_project "$name"
    for repo in ${paths_to_remove[@]+"${paths_to_remove[@]}"}; do
        _index_remove_path "$repo"
    done
    rm -rf "$state_dir" "$data_dir" "$cache_dir"
    _tags_forget projects "$name"

    ok "Forgot project '$name' (repo untouched)."
    info "It re-registers on the next 'cco start' from its repo, or 'cco resolve --scan'."
}
