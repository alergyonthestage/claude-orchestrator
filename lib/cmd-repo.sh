#!/usr/bin/env bash
# lib/cmd-repo.sh — `cco repo rename` and `cco extra-mount rename` (ADR-0050 B.3).
#
# repo and extra_mount are the INDEX-KEYED kinds: their name is a per-project label
# for a host PATH (ADR-0051 — identity is the path, name is the label). A rename is
# therefore PROJECT-SCOPED and PATH-ANCHORED: it re-keys only the CURRENT project's
# binding + that project's project.yml entry, matched by path. No cross-project
# fan-out — another project's same-named-but-different-path binding is a different
# resource, and another project labeling the same path keeps its own label.
#
# The on-disk directory is a real working tree (its own git identity, possibly
# shared / externally referenced), so by default only the logical NAME is re-keyed;
# the directory move is opt-in, basename-gated, default-No (ADR-0050 D4 / §5).
#
# Provides: cmd_repo(), cmd_extra_mount()
# Dependencies: colors.sh, utils.sh, index.sh (_index_{get,set}_path /
#   _index_rename_path / _index_name_for_path / _index_get_project_repos),
#   rename.sh (_rename_validate / _rename_projectyml_current / _rename_preview_confirm),
#   cmd-resolve.sh (_resolve_find_unit_dir), paths.sh (_cco_project_id).

# Shared engine for the two index-keyed rename verbs.
#   <kind>       repo | extra_mount   (label for messages + charset predicate)
#   <section>    repos | extra_mounts (project.yml list section to rewrite)
#   <cwd_first>  true|false           (repo may omit <old>; extra_mount may not)
# Usage: _rename_index_keyed <kind> <section> <cwd_first> [<old>] <new> [-y] [--move-dir]
_rename_index_keyed() {
    local kind="$1" section="$2" cwd_first="$3"; shift 3
    local dash="${kind//_/-}" pretty="${kind//_/ }"
    local skip=false move_dir=false
    local -a pos=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes)   skip=true; shift ;;
            --move-dir) move_dir=true; shift ;;
            --help|-h)  _rename_index_keyed_help "$kind" "$cwd_first"; return 0 ;;
            -*) die "Unknown option: $1. Run 'cco $dash rename --help'." ;;
            *)  pos+=("$1"); shift ;;
        esac
    done

    # ── Current project (from cwd) ──────────────────────────────────────
    local unit project
    unit=$(_resolve_find_unit_dir) \
        || die "Run 'cco $dash rename' from inside a project repo (a directory with .cco/project.yml), or pass <old> <new>."
    project=$(_cco_project_id "$unit") \
        || die "Cannot determine the current project from $unit/.cco/project.yml."

    # ── Resolve <old> and <new> (cwd-first when only <new> is given) ─────
    local old="" new=""
    case ${#pos[@]} in
        2) old="${pos[0]}"; new="${pos[1]}" ;;
        1) if [[ "$cwd_first" == true ]]; then
               new="${pos[0]}"
               old=$(_index_name_for_path "$project" "$unit") \
                   || die "No $pretty is bound to $unit in project '$project'. Pass <old> <new> explicitly."
               [[ -n "$old" ]] \
                   || die "No $pretty is bound to $unit in project '$project'. Pass <old> <new> explicitly."
           else
               die "Usage: cco $dash rename <old> <new>"
           fi ;;
        *) if [[ "$cwd_first" == true ]]; then die "Usage: cco $dash rename [<old>] <new>"
           else die "Usage: cco $dash rename <old> <new>"; fi ;;
    esac
    [[ "$old" == "$new" ]] && die "Old and new names are the same ('$old') — nothing to rename."

    # ── <old> must be bound in THIS project; <new> free; charset/reserved ─
    local oldpath; oldpath=$(_index_get_path "$project" "$old")
    [[ -n "$oldpath" ]] \
        || die "No $pretty named '$old' in project '$project'. Run 'cco project show $project' to see its members."
    _rename_validate "$kind" "$new"
    [[ -z "$(_index_get_path "$project" "$new")" ]] \
        || die "A $pretty named '$new' already exists in project '$project'. Choose a different name."

    # ── Strict guard: the member must be resolved on this machine ───────
    [[ -d "$oldpath" ]] \
        || die "Member '$old' is not resolved on this machine ($oldpath is missing). Run 'cco resolve' first — a rename must rewrite project.yml in the member repo (ADR-0031)."

    # ── Directory-move decision (D4 / §5) ──────────────────────────────
    local base newpath="" do_move=false
    base=$(basename "$oldpath")
    if [[ "$move_dir" == true ]]; then
        [[ "$base" == "$old" ]] \
            || die "--move-dir needs the directory basename ('$base') to equal <old> ('$old'); refusing an ambiguous move."
        do_move=true
    elif [[ "$skip" != true && "$base" == "$old" && -t 0 ]]; then
        newpath="$(dirname "$oldpath")/$new"
        printf 'Also move the directory %s → %s? (external references to the old path are NOT updated) [y/N] ' "$oldpath" "$newpath" >&2
        local reply; read -r reply
        [[ "$reply" =~ ^[Yy]$ ]] && do_move=true
    fi
    [[ "$do_move" == true ]] && newpath="$(dirname "$oldpath")/$new"
    [[ "$do_move" == true && -e "$newpath" ]] \
        && die "Refusing to move onto an existing path: $newpath."

    # ── Preview + confirm (ADR-0029 D2) ─────────────────────────────────
    local -a bullets=(
        "index binding + membership token in project '$project'"
        "$section [].name in this project's project.yml (member repos)"
    )
    [[ "$do_move" == true ]] && bullets+=("move directory $oldpath → $newpath")
    _rename_preview_confirm "$skip" "Rename $pretty '$old' → '$new' (project '$project')" "${bullets[@]}" \
        || { info "Aborted — nothing changed."; return 0; }

    # ── Apply: index re-key (project-scoped), then project.yml, then move ─
    _index_rename_path "$project" "$old" "$new"
    local -a changed=()
    local p
    while IFS= read -r p; do [[ -n "$p" ]] && changed+=("$p"); done \
        < <(_rename_projectyml_current "$project" "$section" "$old" "$new")
    if [[ "$do_move" == true ]]; then
        mv "$oldpath" "$newpath" \
            || die "Failed to move '$oldpath' → '$newpath'. The name re-key is applied; re-run after resolving the cause."
        _index_set_path "$project" "$new" "$newpath"
    fi

    ok "Renamed $pretty '$old' → '$new' in project '$project'."
    # Coincident-name note: renaming a repo/mount never renames a same-named project.
    [[ -n "$(_index_get_project_repos "$old")" ]] \
        && info "Note: a project named '$old' exists and was left untouched — use 'cco project rename' for that."
    # extra_mount with an implicit target: its container mount path tracks the name.
    [[ "$kind" == "extra_mount" ]] \
        && info "If this mount has no explicit 'target:', its container path changes from /workspace/$old to /workspace/$new."
    if [[ ${#changed[@]} -gt 0 ]]; then
        warn "Commit + push the updated .cco/project.yml in each member repo, then run 'cco sync':"
        for p in "${changed[@]}"; do info "  $p"; done
    fi
}

_rename_index_keyed_help() {
    local kind="$1" cwd_first="$2" dash="${1//_/-}"
    local argline="<old> <new>"
    [[ "$cwd_first" == true ]] && argline="[<old>] <new>"
    cat <<EOF
Usage: cco $dash rename $argline

Rename a $dash's logical name within the CURRENT project, re-keying the machine-
local index binding and the '$([[ "$kind" == repo ]] && echo repos || echo extra_mounts)' entry in this project's
project.yml. The directory, its git identity, and the url/ref coordinate are
unchanged by default. The name is a per-project label: this does NOT touch another
project that references the same path, and does NOT rename a project of the same name.
EOF
    [[ "$cwd_first" == true ]] && cat <<'EOF'

With <old> omitted, the resource hosting the working directory is renamed.
EOF
    cat <<EOF

Every member repo must be resolved on this machine (run 'cco resolve' first).
After renaming, commit + push the updated .cco/project.yml in each changed repo
and run 'cco sync'.

Options:
  -y, --yes        Skip the confirmation prompt
      --move-dir   Also move the directory on disk (basename must equal <old>)
EOF
}

# ── Verb entrypoints ─────────────────────────────────────────────────

cmd_repo() {
    local sub="${1:-}"
    case "$sub" in
        ""|--help|-h)
            cat <<'EOF'
Usage: cco repo <command>

Commands:
  rename [<old>] <new>   Rename a repo's per-project label (cwd-first when <old> omitted)

A repo's name is a per-project label for a host path (ADR-0051); rename re-keys the
current project only. List a project's repos with 'cco project show <name>'.
EOF
            return 0 ;;
        rename) shift; _rename_index_keyed repo repos true "$@" ;;
        *) die "Unknown repo command: '$sub'. Run 'cco repo --help'." ;;
    esac
}

cmd_extra_mount() {
    local sub="${1:-}"
    case "$sub" in
        ""|--help|-h)
            cat <<'EOF'
Usage: cco extra-mount <command>

Commands:
  rename <old> <new>   Rename an extra_mount's per-project label

An extra_mount's name is a per-project label for a host path (ADR-0051); rename
re-keys the current project only. List a project's mounts with 'cco project show <name>'.
EOF
            return 0 ;;
        rename) shift; _rename_index_keyed extra_mount extra_mounts false "$@" ;;
        *) die "Unknown extra-mount command: '$sub'. Run 'cco extra-mount --help'." ;;
    esac
}
