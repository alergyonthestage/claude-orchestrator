#!/usr/bin/env bash
# lib/cmd-resolve.sh — index-backed path resolution (cco resolve / cco path)
#
# The top-level, consolidated resolution surface (design §3, ADR-0017 D2): it
# materializes the machine-local STATE index (lib/index.sh) for a decentralized
# project unit's referenced resources (repos + extra_mounts), reading the
# machine-agnostic coordinates (name + url) from <repo>/.cco/project.yml and
# binding each logical name -> absolute path on THIS machine.
#
#   cco resolve [project]      resolve the cwd (or named) project's members
#   cco resolve --scan <dir>   discover .cco/project.yml under <dir>, upsert index
#   cco resolve --all          resolve every project known to the index
#   cco path set <name> <abs>  low-level index override (move dirs, fix divergence)
#   cco path list              dump the name -> path bindings
#
# `cco resolve --scan` is a NON-DESTRUCTIVE merge-upsert (ADR-0022 D3): it never
# deletes out-of-<dir> mappings or `cco path set` overrides, and on an AD5
# name-already-bound-to-a-different-path conflict it KEEPS the existing binding
# (warn). There is no --prune in v1 (stale-entry GC is a reserved future).
#
# This is the FINAL form (new decentralized layout only: logical names + the
# STATE index). The legacy `cco project resolve` (central $PROJECTS_DIR layout +
# the @local/local-paths.yml schema bridge) is SUPERSEDED by this command and is
# removed at the P3 legacy cutover, once the P2 migration has moved projects into
# <repo>/.cco/ and the referencing tests retire.
#
# Provides: cmd_resolve(), cmd_path()
# Dependencies: colors.sh, utils.sh (expand_path/_path_exists), index.sh,
#   yaml.sh (yml_get/yml_get_repo_coords/yml_get_mount_coords), local-paths.sh
#   (_resolve_entry_index)

# ── Helpers ──────────────────────────────────────────────────────────

# Resolve a CLI-supplied path to an absolute path (tilde + cwd-relative).
# The index stores absolute paths only (design §3).
_resolve_to_abs() {
    local p
    p=$(expand_path "$1")
    case "$p" in
        /*) printf '%s\n' "$p" ;;
        *)  printf '%s\n' "$(pwd -P)/$p" ;;
    esac
}

# Walk cwd and its ancestors for a <dir>/.cco/project.yml; echo the owning <dir>
# (the repo root that holds .cco/), or return 1 if none is found.
_resolve_find_unit_dir() {
    local d
    d="$(pwd -P)"
    while [[ -n "$d" && "$d" != "/" ]]; do
        if [[ -f "$d/.cco/project.yml" ]]; then
            printf '%s\n' "$d"
            return 0
        fi
        d="$(dirname "$d")"
    done
    [[ -f "/.cco/project.yml" ]] && { printf '%s\n' "/"; return 0; }
    return 1
}

# By-name lookup: a project's members are recorded in the index (projects:);
# read project.yml from the first member repo that is already on disk. Echoes
# the owning <repo> dir, or returns 1 if the project is unknown / has no
# resolved member to read the manifest from.
_resolve_unit_dir_for_project() {
    local proj="$1" repos r p
    repos=$(_index_get_project_repos "$proj")
    [[ -z "$repos" ]] && return 1
    for r in $repos; do
        p=$(_index_get_path "$r")
        if [[ -n "$p" && -f "$p/.cco/project.yml" ]]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

# Iterate the indexed projects, emitting one TAB line "<proj>\t<unit_dir>\t<yml>"
# for each whose host repo RESOLVES on this machine and has a project.yml. The
# reserved "_template" pseudo-entry and any unresolved / manifest-less project are
# skipped silently. This centralizes the common "do X for every resolvable
# project" loop. Callers that must instead act on UNresolved projects (warn,
# show a placeholder, or read only the index membership) iterate
# _index_list_projects directly — they are deliberately not collapsed here.
# Usage: while IFS=$'\t' read -r proj unit_dir yml; do …; done < <(_project_foreach)
_project_foreach() {
    local proj unit_dir yml
    while IFS='=' read -r proj _; do
        [[ -z "$proj" ]] && continue
        [[ "$proj" == "_template" ]] && continue
        unit_dir=$(_resolve_unit_dir_for_project "$proj" 2>/dev/null) || continue
        yml="$unit_dir/.cco/project.yml"
        [[ -f "$yml" ]] || continue
        printf '%s\t%s\t%s\n' "$proj" "$unit_dir" "$yml"
    done < <(_index_list_projects)
}

# Resolve every unresolved repo/mount of one project unit into the index,
# recording the project's repo membership. Reuses _resolve_entry_index (the
# index-materialization primitive: lookup -> prompt/clone -> store). Non-TTY
# unresolved entries are reported (warn), never block.
# Usage: _resolve_unit <unit_dir>
_resolve_unit() {
    local unit_dir="$1"
    local project_yml="$unit_dir/.cco/project.yml"
    [[ -f "$project_yml" ]] || { warn "No .cco/project.yml in $unit_dir"; return 1; }

    local proj_name
    proj_name=$(yml_get "$project_yml" name)

    local resolved=0 unresolved=0
    local -a member_repos=()
    local _ln name url path rc

    # Repos
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        _peel_tab "$_ln" name url
        [[ -z "$name" ]] && continue
        member_repos+=("$name")
        path=$(_index_get_path "$name")
        if [[ -n "$path" ]] && _path_exists "$path"; then
            continue
        fi
        if ! _cco_have_tty; then
            unresolved=$((unresolved + 1))
            warn "repo '$name' unresolved on this machine — run 'cco resolve' on a terminal${url:+ (or clone $url)}"
            continue
        fi
        rc=0
        _resolve_entry_index "$unit_dir" "repos" "$name" "$url" >/dev/null || rc=$?
        case $rc in
            0) resolved=$((resolved + 1)) ;;
            2) return 0 ;;                         # user quit
            *) unresolved=$((unresolved + 1)) ;;   # skipped
        esac
    done < <(yml_get_repo_coords "$project_yml" 2>/dev/null)

    # Extra mounts
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        _peel_tab "$_ln" name url
        [[ -z "$name" ]] && continue
        path=$(_index_get_path "$name")
        if [[ -n "$path" ]] && _path_exists "$path"; then
            continue
        fi
        if ! _cco_have_tty; then
            unresolved=$((unresolved + 1))
            warn "mount '$name' unresolved on this machine — run 'cco resolve' on a terminal${url:+ (or clone $url)}"
            continue
        fi
        rc=0
        _resolve_entry_index "$unit_dir" "extra_mounts" "$name" "$url" >/dev/null || rc=$?
        case $rc in
            0) resolved=$((resolved + 1)) ;;
            2) return 0 ;;
            *) unresolved=$((unresolved + 1)) ;;
        esac
    done < <(yml_get_mount_coords "$project_yml" 2>/dev/null)

    # Record project -> member repos membership (index projects: section).
    if [[ -n "$proj_name" && ${#member_repos[@]} -gt 0 ]]; then
        _index_set_project_repos "$proj_name" "${member_repos[@]}"
    fi

    if [[ $unresolved -eq 0 ]]; then
        ok "${proj_name:-project} resolved${resolved:+ ($resolved newly bound)}"
    else
        warn "${proj_name:-project}: $unresolved reference(s) still unresolved"
    fi
}

# Determine the logical name a discovered repo dir maps to: prefer a git origin
# url that matches a repo coordinate; fall back to the dir basename matching a
# coordinate name. Echoes the name, or returns 1 if no coordinate matches.
_resolve_scan_match_name() {
    local repo_dir="$1" project_yml="$2"
    local origin="" _ln name url base

    if git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
        origin=$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)
    fi
    if [[ -n "$origin" ]]; then
        while IFS= read -r _ln; do
            [[ -z "$_ln" ]] && continue
            _peel_tab "$_ln" name url
            if [[ -n "$url" && "$url" == "$origin" ]]; then
                printf '%s\n' "$name"
                return 0
            fi
        done < <(yml_get_repo_coords "$project_yml" 2>/dev/null)
    fi

    base="$(basename "$repo_dir")"
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        name="${_ln%%$'\t'*}"
        if [[ "$name" == "$base" ]]; then
            printf '%s\n' "$name"
            return 0
        fi
    done < <(yml_get_repo_coords "$project_yml" 2>/dev/null)
    return 1
}

# Discover .cco/project.yml units under <dir> and upsert the index
# non-destructively (ADR-0022 D3): bind each discovered repo's name -> path,
# refresh each project's membership, KEEP an existing binding on an AD5 conflict.
# Never deletes out-of-<dir> mappings or `cco path set` overrides; no --prune.
# Usage: _resolve_scan <dir>
_resolve_scan() {
    local dir="$1"
    [[ -d "$dir" ]] || die "Scan directory not found: $dir"
    dir="$(cd "$dir" && pwd -P)"

    local found=0 bound=0 kept=0
    local project_yml cco_dir repo_dir proj_name this_name existing
    local _ln name
    local -a names=()

    while IFS= read -r project_yml; do
        [[ -z "$project_yml" ]] && continue
        found=$((found + 1))
        cco_dir="$(dirname "$project_yml")"     # <repo>/.cco
        repo_dir="$(dirname "$cco_dir")"        # <repo>
        proj_name=$(yml_get "$project_yml" name)

        # Refresh project -> member repos membership from the manifest (truthful).
        names=()
        while IFS= read -r _ln; do
            [[ -z "$_ln" ]] && continue
            name="${_ln%%$'\t'*}"
            [[ -n "$name" ]] && names+=("$name")
        done < <(yml_get_repo_coords "$project_yml" 2>/dev/null)
        if [[ -n "$proj_name" && ${#names[@]} -gt 0 ]]; then
            _index_set_project_repos "$proj_name" "${names[@]}"
        fi

        # Bind THIS repo dir to its logical name (AD5 keep-existing on conflict).
        this_name=$(_resolve_scan_match_name "$repo_dir" "$project_yml") || this_name=""
        [[ -z "$this_name" ]] && continue
        if _index_path_conflicts "$this_name" "$repo_dir"; then
            existing=$(_index_get_path "$this_name")
            warn "scan: '$this_name' already bound to $existing — keeping existing (AD5); ignoring $repo_dir"
            kept=$((kept + 1))
        else
            _index_set_path "$this_name" "$repo_dir"
            bound=$((bound + 1))
        fi
    done < <(find "$dir" -type f -path '*/.cco/project.yml' 2>/dev/null)

    info "scan: $found unit(s) found, $bound binding(s) upserted, $kept conflict(s) kept"
}

# Resolve every project recorded in the index (best-effort; skips projects with
# no resolved member to read the manifest from).
_resolve_all() {
    local any=false line proj unit_dir
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        proj="${line%%=*}"
        [[ -z "$proj" ]] && continue
        unit_dir=$(_resolve_unit_dir_for_project "$proj") || {
            warn "project '$proj': no resolved member to read project.yml — skipping (run 'cco resolve --scan')"
            continue
        }
        any=true
        info "resolving project '$proj'..."
        _resolve_unit "$unit_dir"
    done < <(_index_list_projects)
    $any || info "no projects in the index to resolve — try 'cco resolve --scan <dir>'"
}

# ── Commands ─────────────────────────────────────────────────────────

cmd_resolve() {
    local scan_dir="" do_all=false project=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                cat <<'EOF'
Usage: cco resolve [project] [options]

Materialize the machine-local path index for a project's referenced repos and
extra mounts, reading the machine-agnostic coordinates (name + url) from
<repo>/.cco/project.yml. Without a project argument, resolves the project whose
.cco/project.yml owns the current directory.

Options:
  --scan <dir>   Discover .cco/project.yml units under <dir> and upsert the
                 index (non-destructive: keeps out-of-<dir> mappings and
                 `cco path set` overrides; AD5 conflicts keep the existing
                 binding; no pruning).
  --all          Resolve every project recorded in the index.

Examples:
  cco resolve                      # resolve the project owning the cwd
  cco resolve myapp                # resolve a named project
  cco resolve --scan ~/dev         # bootstrap/refresh the index from a dir tree

Advanced:
  The path index is internal and normally maintained for you by resolve. To
  override a binding by hand — move a directory, fix a divergence, or register
  an externally-cloned repo — use the low-level escape hatch:
    cco path list                  # show the current logical-name → path index
    cco path set <name> <abs-path> # pin a logical name to an absolute path
EOF
                return 0
                ;;
            --scan)
                [[ $# -lt 2 ]] && die "--scan requires a <dir> argument."
                scan_dir="$2"; shift 2
                ;;
            --all) do_all=true; shift ;;
            -*) die "Unknown option: $1. Run 'cco resolve --help'." ;;
            *)
                if [[ -z "$project" ]]; then
                    project="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    if [[ -n "$scan_dir" ]]; then
        _resolve_scan "$scan_dir"
        return 0
    fi
    if $do_all; then
        _resolve_all
        return 0
    fi

    local unit_dir
    if [[ -n "$project" ]]; then
        unit_dir=$(_resolve_unit_dir_for_project "$project") \
            || die "Project '$project' is not resolvable yet — run 'cco resolve --scan <dir>' to discover it first."
    else
        unit_dir=$(_resolve_find_unit_dir) \
            || die "No .cco/project.yml found in the current directory or its parents. Run from a configured repo, name a project, or use 'cco resolve --scan <dir>'."
    fi
    _resolve_unit "$unit_dir"
}

cmd_path() {
    local sub="${1:-}"
    case "$sub" in
        ""|--help|-h)
            cat <<'EOF'
Usage: cco path <set|list>

Low-level editor for the machine-local path index (logical name -> absolute
path). Use it to move directories, fix divergence, or register externally
installed repos. For normal resolution prefer `cco resolve`.

Commands:
  set <name> <path>   Bind a logical name to an absolute path (cwd-relative and
                      ~ paths are expanded). Overwrites any existing binding.
  list                Print every name -> path binding.
EOF
            return 0
            ;;
        set)
            shift
            [[ $# -lt 2 ]] && die "Usage: cco path set <name> <path>"
            local name="$1" abs
            abs=$(_resolve_to_abs "$2")
            _index_set_path "$name" "$abs"
            ok "path set: $name -> $abs"
            _path_exists "$abs" || warn "note: '$abs' does not exist on this machine yet"
            ;;
        list)
            shift
            [[ $# -gt 0 ]] && die "Usage: cco path list (takes no arguments)"
            local line name path count=0
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                name="${line%%=*}"; path="${line#*=}"
                printf '%s\t%s\n' "$name" "$path"
                count=$((count + 1))
            done < <(_index_list_paths)
            if [[ $count -eq 0 ]]; then
                info "the path index is empty — run 'cco resolve' or 'cco resolve --scan <dir>'"
            fi
            ;;
        *)
            die "Unknown path command: $sub. Use 'cco path set' or 'cco path list'."
            ;;
    esac
}
