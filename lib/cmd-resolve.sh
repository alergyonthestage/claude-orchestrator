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
    # Strip one pair of surrounding quotes first (ADR-0050 D8) — a path pasted as
    # '/my/repo' or "/my/repo" absolutizes to the literal dir, not a bogus quoted
    # name. Covers `cco path set`/`resolve` and the interactive path prompts, which
    # all flow through here.
    p=$(_strip_surrounding_quotes "$1")
    p=$(expand_path "$p")
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
        p=$(_index_get_path "$proj" "$r")
        if [[ -n "$p" && -f "$p/.cco/project.yml" ]]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

# ── Operator-mode (in-container) project resolution (R2/R4, ADR-0042/0043) ──
# The STATE index stores HOST paths that never resolve inside a container, so the
# host resolver above returns 1 in-session → the old "not found, run cco resolve"
# host-only hint. The wrapped cco instead resolves a project NAME to its MOUNTED
# project.yml, so self-introspection and membership scans work in-session. Two
# mount layouts (C2):
#   layout 1 (normal session): the current project's manifest is mounted at
#     /workspace/project.yml (its repo also lives at /workspace/<repo>/.cco/). There
#     is NO canonical /workspace/.cco/project.yml.
#   layout 2 (config-editor target): the target's .cco tree is mounted AT the mount
#     root — /workspace/<name>-config/project.yml (the mount IS the .cco dir).
# Resolution order: current project → config-editor target → built-in preset →
# unavailable-at-scope (return 1; the caller reports scope, never "run cco resolve").

# Echo the current project's mounted project.yml (layout 1). Fast path is the
# always-mounted /workspace/project.yml; falls back to scanning /workspace/*/.cco/.
_resolve_operator_current_yml() {
    local want="${PROJECT_NAME:-}" d yml n
    [[ -z "$want" ]] && return 1
    if [[ -f /workspace/project.yml ]]; then
        n=$(yml_get /workspace/project.yml name 2>/dev/null)
        [[ "$n" == "$want" ]] && { printf '%s\n' /workspace/project.yml; return 0; }
    fi
    for d in /workspace/*/; do
        yml="${d}.cco/project.yml"
        [[ -f "$yml" ]] || continue
        n=$(yml_get "$yml" name 2>/dev/null)
        [[ "$n" == "$want" ]] && { printf '%s\n' "$yml"; return 0; }
    done
    return 1
}

# Echo the project.yml path for <name> in operator mode, or return 1 (unavailable
# at THIS scope — a distinct status the caller renders as scope-limited, not the
# host-only "run cco resolve").
_resolve_operator_project_yml() {
    local name="$1" yml
    # 1. Current project (resolves from any cwd, including /workspace root).
    if [[ -n "${PROJECT_NAME:-}" && "$name" == "$PROJECT_NAME" ]]; then
        _resolve_operator_current_yml && return 0
    fi
    # 2. config-editor target (D9): its .cco is mounted at /workspace/<name>-config.
    if _env_csv_has "$name" "${CCO_CONFIG_TARGETS:-}"; then
        yml="/workspace/${name}-config/project.yml"
        [[ -f "$yml" ]] && { printf '%s\n' "$yml"; return 0; }
    fi
    # 3. Built-in preset — its generated config lives in the internal runtime dir.
    case "$name" in
        tutorial|config-editor)
            yml="$(_cco_internal_runtime_dir)/${name}/project.yml"
            [[ -f "$yml" ]] && { printf '%s\n' "$yml"; return 0; } ;;
    esac
    return 1
}

# Resolve a project NAME to its project.yml PATH, host- AND operator-aware — the
# single entry the read/introspection verbs use. Host: STATE index (host paths).
# Operator: the mounted /workspace trees. Returns 1 when unavailable at this scope.
_resolve_project_yml() {
    local name="$1" d
    if _cco_container_operator; then
        _resolve_operator_project_yml "$name"
        return $?
    fi
    d=$(_resolve_unit_dir_for_project "$name") || return 1
    printf '%s\n' "$d/.cco/project.yml"
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
    # Operator mode (R4): the host index paths don't resolve in-container. Enumerate
    # only the MOUNTED projects — the current project (normal session) plus every
    # config-editor target — via the operator resolver, so membership scans ("Used
    # by") answer correctly for what IS mounted and stay silent (unavailable at this
    # scope) for the rest, never a false "(none)". The unit_dir is dirname(.cco),
    # i.e. dirname(dirname(yml)) for a nested .cco, or dirname(yml) for a flat mount.
    if _cco_container_operator; then
        local names name
        names="${PROJECT_NAME:-}"
        [[ -n "${CCO_CONFIG_TARGETS:-}" ]] && names="${names},${CCO_CONFIG_TARGETS}"
        # Split the CSV without globbing; dedup by emitting each name once.
        local seen=","
        local IFS=','
        for name in $names; do
            [[ -z "$name" ]] && continue
            case "$seen" in *",${name},"*) continue ;; esac
            seen="${seen}${name},"
            yml=$(_resolve_operator_project_yml "$name" 2>/dev/null) || continue
            [[ -f "$yml" ]] || continue
            case "$yml" in
                */.cco/project.yml) unit_dir="${yml%/.cco/project.yml}" ;;
                *)                  unit_dir="${yml%/project.yml}" ;;
            esac
            printf '%s\t%s\t%s\n' "$name" "$unit_dir" "$yml"
        done
        return 0
    fi
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
        path=$(_index_get_path "$proj_name" "$name")
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
        path=$(_index_get_path "$proj_name" "$name")
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

    # LLMs (ADR-0032 D5): heal a referenced-but-uninstalled llms by fetching it
    # from its coordinate. Unified with repos/mounts under one heal verb (P14) —
    # not a separate `cco llms resolve`. The content lands in CACHE; the manifest
    # url stays as-is (a machine-local install, ADR-0017 D1), so this never edits
    # committed config. Non-TTY: warn + count, never block (mirrors repos).
    local desc variant
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        _peel_tab "$_ln" name desc variant url
        [[ -z "$name" ]] && continue
        [[ -d "${LLMS_DIR:-}/$name" ]] && continue          # already installed
        if ! _cco_have_tty; then
            unresolved=$((unresolved + 1))
            warn "llms '$name' not installed — run 'cco resolve' on a terminal${url:+ (or: cco llms install $url --name $name)}"
            continue
        fi
        rc=0
        _resolve_llms_entry "$name" "$url" "$variant" || rc=$?
        case $rc in
            0) resolved=$((resolved + 1)) ;;
            2) return 0 ;;                          # user quit
            *) unresolved=$((unresolved + 1)) ;;    # skipped
        esac
    done < <(yml_get_llms "$project_yml" 2>/dev/null)

    # Packs (ADR-0033): heal a referenced-but-uninstalled pack from its sharing-
    # repo url, unified with repos/mounts/llms under this one heal verb (P14). A
    # pack present in a local layer (~/.cco/packs or <repo>/.cco/packs) is already
    # resolved; a url-bearing one missing from both layers is offered for install
    # (reusing the `cco pack install --pick` backend, mirroring llms). No url and
    # not embedded → conscious-skip. Non-TTY: warn + count, never block.
    local pref presource
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        _peel_tab "$_ln" name url pref presource
        [[ -z "$name" ]] && continue
        [[ -n "$(_pack_resolve_dir "$name" "$unit_dir/.cco")" ]] && continue   # already in a local layer
        if ! _cco_have_tty; then
            unresolved=$((unresolved + 1))
            warn "pack '$name' not installed — run 'cco resolve' on a terminal${url:+ (or: cco pack install $url --pick $name)}"
            continue
        fi
        rc=0
        _resolve_pack_entry "$name" "$url" || rc=$?
        case $rc in
            0) resolved=$((resolved + 1)) ;;
            2) return 0 ;;                          # user quit
            *) unresolved=$((unresolved + 1)) ;;    # skipped
        esac
    done < <(yml_get_pack_coords "$project_yml" 2>/dev/null)

    # Ensure the HOST repo (the dir bearing .cco/project.yml) is part of the
    # recorded membership, so by-name resolution (_resolve_unit_dir_for_project)
    # can always relocate the unit — even when the host repo is not itself listed
    # in the manifest's repos: (a config-only host). Without this, recording
    # membership from repos: alone could drop the only locatable member.
    local _host_name; _host_name=$(_index_name_for_path "$proj_name" "$unit_dir")
    if [[ -n "$_host_name" ]]; then
        local _has=false _m
        for _m in ${member_repos[@]+"${member_repos[@]}"}; do
            [[ "$_m" == "$_host_name" ]] && { _has=true; break; }
        done
        $_has || member_repos+=("$_host_name")
    fi

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

# Interactively heal one missing llms reference (ADR-0032 D5). Hybrid offer:
# install-from-url / use-a-different-url / skip (or specify-a-url / skip when no
# url is recorded). Downloads via the `cco llms install` backend (in a subshell
# so a download `die` cannot abort the whole resolve). Returns 0 = fetched,
# 2 = user quit, 1 = skipped. Callers gate this on _cco_have_tty.
_resolve_llms_entry() {
    local name="$1" url="$2" variant="$3"
    local reply
    if [[ -n "$url" ]]; then
        printf "llms '%s' not installed (url: %s)\n  [i] install from url · [d] use a different url · [s] skip · [q] quit: " "$name" "$url" >&2
        read -r reply </dev/tty || return 1
        case "$reply" in
            ""|[Ii]) ;;                                              # install from the recorded url
            [Dd]) printf "  url: " >&2; read -r url </dev/tty || return 1
                  [[ -z "$url" ]] && { warn "no url given — skipped"; return 1; } ;;
            [Qq]) return 2 ;;
            *)    return 1 ;;                                        # skip
        esac
    else
        printf "llms '%s' has no url coordinate.\n  [u] specify a url to install · [s] skip · [q] quit: " "$name" >&2
        read -r reply </dev/tty || return 1
        case "$reply" in
            [Uu]) printf "  url: " >&2; read -r url </dev/tty || return 1
                  [[ -z "$url" ]] && { warn "no url given — skipped"; return 1; } ;;
            [Qq]) return 2 ;;
            *)    return 1 ;;
        esac
    fi
    info "Installing llms '$name' from $url ..."
    ( _llms_install "$url" --name "$name" ${variant:+--variant "$variant"} ) \
        || { warn "llms '$name' install failed — left unresolved"; return 1; }
    return 0
}

# Interactively heal one missing pack reference (ADR-0033). Mirrors
# _resolve_llms_entry: install-from-url / use-a-different-url / skip (or
# specify-a-url / skip when no url is recorded). Installs via the `cco pack
# install` backend in a subshell (so a download `die` cannot abort the whole
# resolve). Returns 0 = installed, 2 = user quit, 1 = skipped. Callers gate this
# on _cco_have_tty. A pack already present in a local layer (~/.cco/packs or
# <repo>/.cco/packs) never reaches here — the caller skips it as resolved.
_resolve_pack_entry() {
    local name="$1" url="$2" reply
    if [[ -n "$url" ]]; then
        printf "pack '%s' not installed (url: %s)\n  [i] install from url · [d] use a different url · [s] skip · [q] quit: " "$name" "$url" >&2
        read -r reply </dev/tty || return 1
        case "$reply" in
            ""|[Ii]) ;;                                              # install from the recorded url
            [Dd]) printf "  url: " >&2; read -r url </dev/tty || return 1
                  [[ -z "$url" ]] && { warn "no url given — skipped"; return 1; } ;;
            [Qq]) return 2 ;;
            *)    return 1 ;;                                        # skip
        esac
    else
        printf "pack '%s' has no url coordinate and is not embedded locally.\n  [u] specify a url to install · [s] skip · [q] quit: " "$name" >&2
        read -r reply </dev/tty || return 1
        case "$reply" in
            [Uu]) printf "  url: " >&2; read -r url </dev/tty || return 1
                  [[ -z "$url" ]] && { warn "no url given — skipped"; return 1; } ;;
            [Qq]) return 2 ;;
            *)    return 1 ;;
        esac
    fi
    info "Installing pack '$name' from $url ..."
    ( cmd_pack_install "$url" --pick "$name" ) \
        || { warn "pack '$name' install failed — left unresolved"; return 1; }
    return 0
}

# Render a one-line status row per referenced resource of a unit (ADR-0033) —
# the "always show the status of every referenced resource" surface of
# `cco resolve`. Read-only; reports the post-heal state uniformly across repos,
# extra_mounts, llms and packs (✓ resolved / ⚠ unresolved [+url]). Healing has
# already run in _resolve_unit; this only reports. Goes to stderr like the rest
# of the resolve surface.
# Usage: _resolve_render_status <unit_dir>
_resolve_render_status() {
    local unit_dir="$1"
    local project_yml="$unit_dir/.cco/project.yml"
    [[ -f "$project_yml" ]] || return 0
    local _ln name url desc variant pref presource p pdir
    local proj_name; proj_name=$(yml_get "$project_yml" name 2>/dev/null)
    printf '\n  Referenced resources:\n' >&2

    # repos / extra_mounts — resolved iff the index path exists on disk.
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        _peel_tab "$_ln" name url
        [[ -z "$name" ]] && continue
        p=$(_index_get_path "$proj_name" "$name")
        if [[ -n "$p" ]] && _path_exists "$p"; then
            printf '    %-5s %-22s ✓ %s\n' "repo" "$name" "$p" >&2
        else
            printf '    %-5s %-22s ⚠ unresolved%s\n' "repo" "$name" "${url:+ (url: $url)}" >&2
        fi
    done < <(yml_get_repo_coords "$project_yml" 2>/dev/null)
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        _peel_tab "$_ln" name url
        [[ -z "$name" ]] && continue
        p=$(_index_get_path "$proj_name" "$name")
        if [[ -n "$p" ]] && _path_exists "$p"; then
            printf '    %-5s %-22s ✓ %s\n' "mount" "$name" "$p" >&2
        else
            printf '    %-5s %-22s ⚠ unresolved%s\n' "mount" "$name" "${url:+ (url: $url)}" >&2
        fi
    done < <(yml_get_mount_coords "$project_yml" 2>/dev/null)

    # llms — resolved iff installed in LLMS_DIR (content lives in CACHE).
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        _peel_tab "$_ln" name desc variant url
        [[ -z "$name" ]] && continue
        if [[ -d "${LLMS_DIR:-}/$name" ]]; then
            printf '    %-5s %-22s ✓ installed\n' "llms" "$name" >&2
        else
            printf '    %-5s %-22s ⚠ unresolved%s\n' "llms" "$name" "${url:+ (url: $url)}" >&2
        fi
    done < <(yml_get_llms "$project_yml" 2>/dev/null)

    # packs — resolved iff present in a local layer (~/.cco/packs or <repo>/.cco/packs).
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        _peel_tab "$_ln" name url pref presource
        [[ -z "$name" ]] && continue
        pdir=$(_pack_resolve_dir "$name" "$unit_dir/.cco")
        if [[ -n "$pdir" ]]; then
            printf '    %-5s %-22s ✓ %s\n' "pack" "$name" "$pdir" >&2
        else
            printf '    %-5s %-22s ⚠ unresolved%s\n' "pack" "$name" "${url:+ (url: $url)}" >&2
        fi
    done < <(yml_get_pack_coords "$project_yml" 2>/dev/null)
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
    local -a names=() scanned_projects=()

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
            scanned_projects+=("$proj_name")
        fi

        # Bind THIS repo dir to its logical name (AD5 keep-existing on conflict).
        this_name=$(_resolve_scan_match_name "$repo_dir" "$project_yml") || this_name=""
        [[ -z "$this_name" ]] && continue
        if _index_path_conflicts "$proj_name" "$this_name" "$repo_dir"; then
            existing=$(_index_get_path "$proj_name" "$this_name")
            warn "scan: '$this_name' already bound in '$proj_name' to $existing — keeping existing (AD5′); ignoring $repo_dir"
            kept=$((kept + 1))
        else
            _index_set_path "$proj_name" "$this_name" "$repo_dir"
            bound=$((bound + 1))
        fi
    done < <(find "$dir" -type f -path '*/.cco/project.yml' 2>/dev/null)

    # Pass 2 (ADR-0051 D5): bind each project's SHARED members — members it lists
    # but that are HOSTED by a different unit in the scan — under this project's
    # OWN scope too, to the same path (path is identity). Without this a member
    # listed by project A yet hosted by project B stays unresolved under A, so A's
    # membership names a repo with no A-scoped binding (e.g. `cco sync` from A then
    # can't reach it). Only adopt a path discovered INSIDE the scanned tree; never
    # override an existing A-scoped binding (AD5′ keep-existing).
    local sp mpath
    for sp in ${scanned_projects[@]+"${scanned_projects[@]}"}; do
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            [[ -n "$(_index_get_path "$sp" "$name")" ]] && continue
            mpath=$(_index_get_path_any "$name")
            [[ -z "$mpath" ]] && continue
            case "$mpath" in "$dir"/*|"$dir") ;; *) continue ;; esac
            _index_set_path "$sp" "$name" "$mpath"
            bound=$((bound + 1))
        done < <(_index_get_project_repos "$sp" | tr ' ' '\n')
    done

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
    # Always show the post-heal status of every referenced resource (ADR-0033).
    _resolve_render_status "$unit_dir"
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
            # Per-project scoping (ADR-0051): a name is a per-project label. Bind
            # it in the project hosting the cwd if there is one; otherwise it is a
            # project-less pin → the unscoped bucket. Emit a hint when the index
            # name no longer matches the directory basename (name↔path divergence).
            local _pset_dir _pset_proj="" _pbase
            if _pset_dir=$(_resolve_find_unit_dir 2>/dev/null); then
                _pset_proj=$(yml_get "$_pset_dir/.cco/project.yml" name 2>/dev/null)
            fi
            if [[ -n "$_pset_proj" ]]; then
                _index_set_path "$_pset_proj" "$name" "$abs"
                ok "path set: [$_pset_proj] $name -> $abs"
            else
                _index_set_unscoped "$name" "$abs"
                ok "path set: $name -> $abs (unscoped — not inside a project)"
            fi
            _path_exists "$abs" || warn "note: '$abs' does not exist on this machine yet"
            _pbase=$(basename "$abs")
            # Use `if`, not `[[ … ]] && info`: as the case's LAST statement the
            # latter leaks a false condition (path not yet on disk — a legitimate
            # pre-clone pin) as a non-zero exit, failing the whole `cco path set`.
            if [[ -d "$abs" && "$name" != "$_pbase" ]]; then
                info "hint: index name '$name' ≠ directory basename '$_pbase' — 'cco repo rename $name $_pbase' aligns them."
            fi
            ;;
        list)
            shift
            [[ $# -gt 0 ]] && die "Usage: cco path list (takes no arguments)"
            local proj name path norm count=0 malformed=0 hidden=0 _vis label
            # Output scoping (ADR-0043/0046 §7, A1 §4.3): the path index is the raw
            # machine-local name→host-path map (repos/mounts), not a taxonomy kind.
            # Under per-project scoping (ADR-0051) each binding has a single OWNING
            # project (project_paths); its visibility follows that project exactly
            # like `cco list project`: the current project's entries are always
            # shown (Pc≥ro, INV-2), other projects' entries need Po≥ro (read-all).
            # So we scope whenever Po<ro (read-project/read-global) and hide any
            # entry whose owner is not a current project — config-editor-aware via
            # _env_is_current_project (PROJECT_NAME ∪ CCO_CONFIG_TARGETS). Unscoped
            # (project-less) pins have no owner → never scoped-hidden. Host paths
            # are ADDITIONALLY gated by show_host_paths, trustworthy behind the
            # ADR-0047 boundary (S1b): at show_host_paths=off we render logical
            # names only. Host context is never scoped (INV-A); uses the layer's
            # helpers, no ad-hoc context re-derivation (INV-E).
            local _scope_paths=false _hide_hostpaths=false
            if _cco_container_operator; then
                [[ "$(_cco_axis_rank "$(_env_axis Po)")" -lt 1 ]] && _scope_paths=true
                [[ "${CCO_SHOW_HOST_PATHS:-true}" != "true" ]] && _hide_hostpaths=true
            fi
            # Emit "<project>\t<name>\t<path>" for every scoped binding, then the
            # unscoped bucket tagged with the __unscoped__ sentinel (a real empty
            # first column can't survive `read` — TAB is IFS-whitespace and gets
            # collapsed; the sentinel is not a valid project name).
            while IFS=$'\t' read -r proj name path; do
                [[ -z "$name" ]] && continue
                [[ "$proj" == "__unscoped__" ]] && proj=""
                # Per-project label so homonyms across projects stay distinct.
                if [[ -n "$proj" ]]; then label="[$proj] $name"; else label="$name"; fi
                if [[ "$_scope_paths" == true && -n "$proj" ]]; then
                    if ! _env_is_current_project "$proj"; then hidden=$((hidden + 1)); continue; fi
                fi
                # show_host_paths gate (S1b): render logical names only when host
                # paths are masked for this session. The malformed-path check is
                # moot then (the host path is not shown), so it is skipped.
                if [[ "$_hide_hostpaths" == true ]]; then
                    printf '%s\n' "$label"
                    count=$((count + 1)); continue
                fi
                # The index stores absolute paths only (boundary normalization).
                # Normalize for display, and flag any value that is still
                # non-absolute (a stale ~/@local entry written before the fix or
                # hand-edited) instead of printing it as if it were valid.
                if norm=$(_index_normalize_path "$path"); then
                    printf '%s\t%s\n' "$label" "$norm"
                else
                    printf '%s\t%s  ⚠ malformed (non-absolute)\n' "$label" "$path"
                    malformed=$((malformed + 1))
                fi
                count=$((count + 1))
            done < <(_index_pp_dump_all; _index_section_dump unscoped \
                | awk '{ i=index($0,"="); if (i>0) printf "__unscoped__\t%s\t%s\n", substr($0,1,i-1), substr($0,i+1) }')
            if [[ $count -eq 0 && $hidden -eq 0 ]]; then
                info "the path index is empty — run 'cco resolve' or 'cco resolve --scan <dir>'"
            elif [[ $malformed -gt 0 ]]; then
                warn "$malformed malformed index entr$([[ $malformed -eq 1 ]] && printf y || printf ies) — run 'cco update' to normalize, or 'cco resolve --scan <dir>' to rebind"
            fi
            if [[ $hidden -gt 0 ]]; then
                # Hidden path entries belong to OTHER projects (owner ≠ a current
                # project), which are visible only at Po≥ro — i.e. read-all, NOT
                # read-global (read-global still hides other projects; A1 §2.2).
                printf 'note: %s path entr%s hidden by access scope (cco_access=%s) — start a read-all session or run cco on your host to see everything.\n' \
                    "$hidden" "$([[ $hidden -eq 1 ]] && printf y || printf ies)" "$(_env_access)" >&2
            fi
            ;;
        *)
            die "Unknown path command: $sub. Use 'cco path set' or 'cco path list'."
            ;;
    esac
}
