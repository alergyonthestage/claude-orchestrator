#!/usr/bin/env bash
# lib/cmd-project-rename.sh — `cco project rename [<old>] <new>` (ADR-0031).
#
# A project's identity is its project.yml `name:` (= the STATE index `projects:`
# key = the DATA tags key = the `<state|cache|data>/cco/projects/<name>/` dir
# key; ADR-0024 D1). Renaming is therefore a multi-store identity RE-KEY, not a
# single-file edit:
#   1. project.yml `name:` in EVERY member repo's .cco/  (^name: at col 0)
#   2. STATE index   projects: <old> → <new>             (members preserved)
#   3. DATA  tags    projects: <old> → <new>             (tag set carried over)
#   4. STATE/CACHE/DATA  projects/<old> → projects/<new> (move; no-op if absent)
#
# Strict (ADR-0031 D3): refuse unless every member repo resolves on this machine
# — a partial `name:` rewrite diverges the un-rewritten members permanently under
# `cco sync`'s D2 clobber-guard. The machine-local re-key (2–4) is applied
# together after full pre-validation; the cross-repo project.yml edits (1) cannot
# be transactional across git working trees, so they are applied and the user is
# warned to commit + push + sync each changed repo (P17 delegate-to-git).
#
# Provides: cmd_project_rename()
# Dependencies: colors.sh, utils.sh (_cco_valid_project_name/_check_reserved_project_name/
#   _confirm_destructive/_sed_i), paths.sh (_cco_{state,cache,data}_dir/_cco_project_id),
#   index.sh (_index_get_project_repos/_index_get_path/_index_rename_project),
#   tags.sh (_tags_rename), cmd-resolve.sh (_resolve_find_unit_dir), yaml.sh (yml_get)

cmd_project_rename() {
    local skip_confirm=false
    local -a pos=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                cat <<'EOF'
Usage: cco project rename [<old>] <new>

Rename a project, re-keying its identity across every store: the project.yml
`name:` in each member repo, the machine-local index, the per-user tags, and the
internal STATE/CACHE/DATA directories. With one argument the current project (the
one hosting the working directory) is renamed.

Arguments:
  <old>    Project to rename (omit to rename the cwd's project)
  <new>    New project name (lowercase letters, numbers, hyphens; not reserved, not in use)

Options:
  -y, --yes    Skip the confirmation prompt

Every member repo must be resolved on this machine (run 'cco resolve' first) so
the identity stays consistent across the project's repos. After renaming, commit
+ push the updated .cco/project.yml in each member repo and run 'cco sync'.
EOF
                return 0
                ;;
            -y|--yes) skip_confirm=true; shift ;;
            -*) die "Unknown option: $1. Run 'cco project rename --help'." ;;
            *)  pos+=("$1"); shift ;;
        esac
    done

    # ── Resolve <old> and <new> (cwd-first when only <new> is given) ─────
    local old="" new=""
    case ${#pos[@]} in
        2) old="${pos[0]}"; new="${pos[1]}" ;;
        1) new="${pos[0]}"
           local unit; unit=$(_resolve_find_unit_dir) \
               || die "Run 'cco project rename' from a repo containing .cco/project.yml, or pass <old> <new>."
           old=$(_cco_project_id "$unit") ;;
        *) die "Usage: cco project rename [<old>] <new>" ;;
    esac
    [[ "$old" == "$new" ]] && die "Old and new names are the same ('$old') — nothing to rename."

    # ── <old> must be a registered project ──────────────────────────────
    local members; members=$(_index_get_project_repos "$old")
    [[ -n "$members" ]] || die "No project named '$old' is registered. Run 'cco list project' to see projects."

    # ── Validate <new> before touching anything ─────────────────────────
    _cco_valid_project_name "$new" \
        || die "Invalid project name '$new' — must be lowercase letters, numbers, and hyphens, starting alphanumeric (no spaces or special characters)."
    _check_reserved_project_name "$new"
    [[ -z "$(_index_get_project_repos "$new")" ]] \
        || die "A project named '$new' is already registered. Choose a different name or 'cco forget' it first."

    local state_root cache_root data_root b old_dir new_dir
    state_root=$(_cco_state_dir); cache_root=$(_cco_cache_dir); data_root=$(_cco_data_dir)
    for b in "$state_root" "$cache_root" "$data_root"; do
        if [[ -e "$b/projects/$new" ]]; then
            die "Internal directory '$b/projects/$new' already exists — refusing to rename onto it. Remove it or 'cco forget' the stale project first."
        fi
    done

    # ── Strict (D3): every member repo must resolve on this machine ──────
    local r p
    local -a resolved=() unresolved=()
    for r in $members; do
        p=$(_index_get_path "$r")
        if [[ -n "$p" && -d "$p" ]]; then resolved+=("$p"); else unresolved+=("$r"); fi
    done
    if [[ ${#unresolved[@]} -gt 0 ]]; then
        die "Cannot rename: member repo(s) not resolved on this machine: ${unresolved[*]}. Run 'cco resolve' to bring all members here first — a rename must rewrite project.yml in every member repo (ADR-0031)."
    fi

    # ── Preview + confirm (ADR-0029 D2) ─────────────────────────────────
    echo -e "${BOLD}Rename project '$old' → '$new'${NC}"
    echo "  • index membership, per-user tags, and internal STATE/CACHE/DATA dirs"
    echo "  • project.yml 'name:' in ${#resolved[@]} member repo(s):"
    for p in "${resolved[@]}"; do echo "      $p"; done
    _confirm_destructive "$skip_confirm" "Proceed?" || { info "Aborted — nothing changed."; return 0; }

    # ── Machine-local re-key (applied together; each step atomic) ────────
    for b in "$state_root" "$cache_root" "$data_root"; do
        old_dir="$b/projects/$old"; new_dir="$b/projects/$new"
        if [[ -d "$old_dir" ]]; then
            mv "$old_dir" "$new_dir" || die "Failed to move '$old_dir' → '$new_dir'. The rename is partially applied — re-run after resolving the cause."
        fi
    done
    _index_rename_project "$old" "$new"
    _tags_rename projects "$old" "$new"

    # ── Cross-repo project.yml 'name:' rewrite (delegate to git, P17) ────
    local yml cur
    local -a changed=()
    for p in "${resolved[@]}"; do
        yml="$p/.cco/project.yml"
        [[ -f "$yml" ]] || continue
        cur=$(yml_get "$yml" name 2>/dev/null) || cur=""
        if [[ "$cur" == "$old" ]]; then
            _sed_i "$yml" "^name:.*" "name: $new"
            changed+=("$p")
        elif [[ -n "$cur" && "$cur" != "$new" ]]; then
            warn "skipping $p/.cco/project.yml — its name is '$cur', not '$old' (left untouched)"
        fi
    done

    ok "Renamed project '$old' → '$new'."
    if [[ ${#changed[@]} -gt 0 ]]; then
        warn "Commit + push the updated .cco/project.yml in each member repo, then run 'cco sync':"
        for p in "${changed[@]}"; do info "  $p"; done
    fi
}
