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
#   rename.sh (_rename_validate / _rename_projectyml_current / _rename_preview_confirm /
#   _rename_assert_writable),
#   cmd-resolve.sh (_resolve_find_unit_dir),
#   paths.sh (_cco_project_id / _cco_member_probe_path / _cco_display_path /
#   _cco_member_name_from_mount),
#   access-scope.sh (_env_member_state / _env_unavailable),
#   local-paths.sh (_mount_declared_target).

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
               # cwd-first <old>: in operator mode $unit is a container mount path,
               # so reverse-resolve it to the member NAME (the index host path can
               # never match — INV-F); on the host, the index reverse lookup stands.
               if _cco_container_operator; then
                   old=$(_cco_member_name_from_mount "$unit") \
                       || die "Run 'cco $dash rename <new>' from a mounted member directory (e.g. \$CCO_WORKDIR/<name>), or pass <old> <new>."
               else
                   old=$(_index_name_for_path "$project" "$unit") || old=""
               fi
               [[ -n "$old" ]] \
                   || die "No $pretty is bound to $(_cco_display_path "" "$unit") in project '$project'. Pass <old> <new> explicitly."
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

    # ── Declared container target (INV-F.2; extra_mount only) ───────────
    # $unit is the cwd repo — mounted, so its project.yml is readable here. An
    # explicit extra_mount target: is where the mount actually lives, so it is the
    # correct probe path (repos have no explicit target — the arg stays empty).
    local oldtarget=""
    [[ "$kind" == "extra_mount" ]] && oldtarget=$(_mount_declared_target "$unit/.cco/project.yml" "$old")

    # ── Strict guard: the member must be inspectable in THIS context ────
    # INV-F: probe the mount (operator) / the host path (host), never existence-test
    # the raw index path in-container. A bound-but-unmounted member is refused with
    # its own remedy (not-mounted → exit 2), a genuinely missing one dies (unresolved
    # → exit 1); each speaks the shared D-M2 vocabulary, no host path leaked.
    local probe _st
    probe=$(_cco_member_probe_path "$old" "$oldpath" "$oldtarget")
    _st=$(_env_member_state "$old" "$oldpath" "$oldtarget")
    [[ "$_st" == here ]] || _env_unavailable "$_st" "$pretty" "$old"

    # ── Directory-move decision (D4 / §5) ──────────────────────────────
    # In a session the member IS a bind-mount root, so a directory move can only
    # fail (EBUSY) and leave the host tree untouched — refuse explicit --move-dir
    # (exit 2, D-M9/Q-5) rather than silently downgrade, and NEVER prompt (-t 0 is
    # true under tmux). The name-only rename proceeds. The move machinery below is
    # thereby host-exclusive.
    local base newpath="" do_move=false
    base=$(basename "$oldpath")
    if _cco_container_operator; then
        [[ "$move_dir" == true ]] && refuse \
            "'--move-dir' cannot run inside a session: '$old' is a bind-mount root here, so the move fails (EBUSY) and the host directory would be untouched. Run 'cco $dash rename --move-dir …' on your host. The name-only rename works here."
        do_move=false
    elif [[ "$move_dir" == true ]]; then
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

    # ── Fail-closed precondition (§3.5): the config tree that _rename_projectyml_current
    # will rewrite must be writable BY THIS PROCESS before any store is touched, so a
    # rename either wholly applies or wholly refuses — never the silent half-apply of
    # an index re-key with an unwritten project.yml. Probed at the CWD member repo's
    # .cco (the mount in a session — the copy that always holds this project.yml, and
    # which an extra_mount target does not), at the same identity as the real write (D-M4).
    #
    # BOTH stores are probed, because the verb writes both and v3 V3-01 failed on the
    # one that was not probed: the config tree was writable, the index bucket was not,
    # so the precondition passed and Phase 1 ran into a half-apply. Each probe runs at
    # its own write identity (de-elevated / elevated respectively) — see rename.sh.
    _rename_assert_writable "$unit/.cco" "cco $dash rename"
    _rename_assert_index_writable "cco $dash rename"

    # ── Apply: project.yml FIRST (members still keyed by <old>), then the index
    # re-key, then the host-only move. The reorder is a host NO-OP (the probe is the
    # identity there) and is what makes the in-container fix work at all: a mount
    # probed AFTER the re-key would resolve to a <workdir>/<new> that cannot exist,
    # so every member would classify unresolved and no project.yml would be rewritten
    # (§1.6). It is also the safer failure ordering — the hard distributed write
    # happens first; the cheap authoritative index write commits last.
    local -a changed=() failed=()
    local _tag _p
    while IFS=$'\t' read -r _tag _p; do
        case "$_tag" in
            changed) [[ -n "$_p" ]] && changed+=("$_p") ;;
            failed)  [[ -n "$_p" ]] && failed+=("$_p") ;;
        esac
    done < <(_rename_projectyml_current "$project" "$section" "$old" "$new")
    # S2b: a member's project.yml rewrite that could not be persisted. S3's
    # pre-flight probes the CWD unit's .cco only, so this is still reachable — a
    # DIFFERENT member unwritable, or ENOSPC mid-fan-out. Stop BEFORE the index
    # re-key: that keeps the two stores' disagreement one-directional (project.yml
    # partly re-keyed, index untouched) and therefore recoverable by re-running.
    # The die lives here, in the parent shell — inside the fan-out it would exit
    # only the process substitution.
    if [[ ${#failed[@]} -gt 0 ]]; then
        local _also=""
        [[ ${#changed[@]} -gt 0 ]] && _also=" It WAS re-keyed in ${#changed[@]} other repo(s) — revert those, or re-run once the cause is fixed."
        die "Renaming $pretty '$old' → '$new' could not rewrite project.yml in ${#failed[@]} member repo(s): ${failed[*]}. The machine-local index was NOT touched.${_also}"
    fi
    # The index write is the SECOND of the two stores, and its failure is what v3
    # V3-01 caught: called bare, it printed `✓` over three EACCES writes and left
    # project.yml re-keyed against an unchanged index. Errexit cannot cover this —
    # bin/cco runs the body in a `||` context — so check explicitly, and say which
    # store did change so the user can recover deterministically.
    if ! _index_rename_path "$project" "$old" "$new"; then
        local _recover=""
        [[ ${#changed[@]} -gt 0 ]] && _recover=" project.yml WAS re-keyed in ${#changed[@]} repo(s) — revert it, or re-run this rename on your host to bring the index into line."
        die "Renamed $pretty '$old' → '$new' in project.yml, but the machine-local index could not be updated.${_recover}"
    fi
    if [[ "$do_move" == true ]]; then
        mv "$oldpath" "$newpath" \
            || die "Failed to move '$oldpath' → '$newpath'. The name re-key is applied; re-run after resolving the cause."
        _index_set_path "$project" "$new" "$newpath" \
            || die "Moved '$oldpath' → '$newpath', but the index could not be re-bound to the new path. Re-run 'cco path set $new $newpath' on your host."
    fi

    ok "Renamed $pretty '$old' → '$new' in project '$project'."
    # A successful rename changes where this member is EXPECTED to be mounted, but a
    # live bind cannot follow — the session still has <old> at <workdir>/<old>, so
    # every later probe of <new> classifies not-mounted until restart (v3 V3-P). The
    # extra_mount note below covers the target-path change; repos need it MORE, since
    # their container path always tracks the name.
    _cco_container_operator \
        && info "This session still has '$old' mounted at ${CCO_WORKDIR:-/workspace}/$old — restart the session for the new name to take effect."
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
