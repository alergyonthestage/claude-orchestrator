#!/usr/bin/env bash
# lib/cmd-project-query.sh — Project listing and display
#
# Provides: cmd_project_list(), cmd_project_show()
# Dependencies: colors.sh, utils.sh, yaml.sh, local-paths.sh
# Globals: PACKS_DIR (projects enumerated via the STATE index, P5)

cmd_project_list() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        cat <<'EOF'
Usage: cco project list

List all configured projects with repo count and running status.
EOF
        return 0
    fi

    # Read-path honesty (v3 R3 / S4). This verb degraded even more quietly than
    # `path list`: _index_list_projects feeds a process substitution, so an
    # unreadable / truncated / stale index printed a BARE HEADER and exited 0 —
    # no message at all. Classify before the header, die (exit 1) naming the
    # real cause; `absent` is benign and reported honestly below.
    _index_assert_readable

    echo -e "${BOLD}NAME              REPOS    STATUS${NC}"

    # Enumerate via the STATE index (the sole name→path map; the central
    # $PROJECTS_DIR layout is gone, P5/AD3). Each project's committed config
    # lives in its host repo's <repo>/.cco/; degrade gracefully when the repo
    # is unresolved on this machine (still list the project, repo_count "-").
    local name unit_dir project_yml repo_count status project_name _yn shown=0
    while IFS='=' read -r name _; do
        [[ -z "$name" ]] && continue
        [[ "$name" == "_template" ]] && continue
        # Output scoping (ADR-0043): at read-project only the current project is
        # visible; the STATE index stays the complete internal map (INV-D).
        if ! _env_in_scope project "$name"; then _env_note_hidden project; continue; fi

        # Host- and operator-aware (R2): in-container this resolves the mounted
        # /workspace manifest; on the host, the STATE index.
        project_yml=$(_resolve_project_yml "$name" 2>/dev/null) || project_yml=""

        repo_count="-"
        if [[ -n "$project_yml" && -f "$project_yml" ]]; then
            repo_count=$(_effective_repo_mounts "$project_yml" | grep -c . 2>/dev/null || echo "0")
        fi

        # The index key is the project identity (== the cc-<name> container);
        # confirm against project.yml name: when the repo is resolvable.
        project_name="$name"
        if [[ -n "$project_yml" && -f "$project_yml" ]]; then
            _yn=$(yml_get "$project_yml" "name" 2>/dev/null)
            [[ -n "$_yn" ]] && project_name="$_yn"
        fi

        # Session identity is the compose `cco.project` label, not the container
        # name (`run --rm` discards `container_name`) — R1. Tri-state (B4): the
        # registry supplies in-container truth; `unknown` when it is unreachable.
        status=$(_cco_session_status_display "$project_name")

        printf "%-18s %-8s %b\n" "$name" "$repo_count" "$status"
        shown=$((shown + 1))
    done < <(_index_list_projects)
    # An honestly empty listing says so. Reached only when the index is readable
    # and genuinely holds no project — the failure shapes died above. Suppressed
    # when rows were merely scope-hidden: _env_flush_hidden_notice speaks for
    # that case, and printing both would contradict it (INV-E, one vocabulary).
    if [[ $shown -eq 0 ]] && ! _env_has_hidden; then info "$(_index_empty_sentence)"; fi
    _env_flush_hidden_notice
}

# Display role of a member repo w.r.t. <project> for `cco project show` (ADR-0024
# D5). Thin wrapper over the canonical _project_member_status (index.sh) so the
# classification lives in ONE place (shared with `cco join`/`cco forget`). Maps
# the canonical taxonomy onto the display labels:
#   synced     -> host       (config-bearing for <project>, in sync)
#   divergent  -> divergent  (owns <project> but .cco edited since last sync)
#   foreign    -> foreign    (hosts a DIFFERENT project — NEW: previously this
#                             case was mislabeled synced/divergent; the latent gap)
#   code-only  -> code-only  (resolved, no .cco)
#   unresolved -> code-only  (path missing here; the caller adds a [missing] badge)
# This also fixes a second latent bug: a same-name DIVERGENT member used to short-
# circuit to "host" (the name== check preceded the divergence check); it now
# reports "divergent" correctly.
_project_member_role() {
    local repo_path="$1" project="$2" repo_name="$3" status
    # Central projects mount via @local/local-paths; fall back to the index path.
    [[ ! -d "$repo_path" && -n "$repo_name" ]] && repo_path=$(_index_get_path "$project" "$repo_name" 2>/dev/null)
    # B-DF1: classify the member where it is actually inspectable — the container
    # mount in operator mode, the index host path on the host. _project_member_status
    # takes a ready path (it reads <path>/.cco/project.yml to tell synced/foreign/
    # code-only apart), so the translation belongs HERE, in the caller that still
    # has the member NAME. Passing the host path in-container made every member
    # `unresolved` → mislabelled `code-only`.
    status=$(_project_member_status "$project" "$(_cco_member_probe_path "$repo_name" "$repo_path")")
    case "$status" in
        synced)     printf 'host' ;;
        unresolved) printf 'code-only' ;;
        *)          printf '%s' "$status" ;;
    esac
}

# Repo-centric view (ADR-0024 D5): from a repo dir, report the project it hosts,
# its members + each member's resolution, and the projects referencing this repo.
_project_show_repo_centric() {
    local repo="$1" hosted
    hosted=$(_cco_project_id "$repo")
    echo -e "${BOLD}Repo:${NC} $repo"
    echo "  hosts project: $hosted"
    echo ""
    echo -e "${BOLD}Members:${NC}"
    local _line rn p refby any=false
    while IFS= read -r _line; do
        rn="${_line%%$'\t'*}"
        [[ -z "$rn" ]] && continue
        any=true
        p=$(_index_get_path "$hosted" "$rn" 2>/dev/null)
        # Referenced-by = other projects mounting this PATH (ADR-0051 D5), not name.
        # Keyed on the INDEX path: bindings are recorded host-side, so the lookup
        # must use the host path even in-container (where $p is not inspectable).
        refby=$([[ -n "$p" ]] && _index_paths_get_bindings "$p" 2>/dev/null | cut -f1 | grep -vxF "$hosted" | sort -u | paste -sd, - 2>/dev/null)
        local l="  $rn"
        # Host-path hygiene (INV-4) via the single display helper — empty in ⇒
        # empty out (INV-F.1), so the (unresolved) rendering below is preserved for
        # a declared-but-unbound member and the outer -n guard is subsumed.
        p=$(_cco_display_path "$rn" "$p")
        [[ -n "$p" ]] && l="$l ($p)" || l="$l (unresolved)"
        [[ -n "$refby" ]] && l="$l — also in: $refby"
        echo "$l"
    done < <(yml_get_repo_coords "$repo/.cco/project.yml")
    $any || echo "  (none)"
}

# R4: at the container WORKDIR the session is a FLAT mount — /workspace/project.yml,
# with no repo-local .cco — so a bare `cco project show` there used to error (the
# repo-centric branch only fires for a repo-local <dir>/.cco/project.yml). This maps
# the WORKDIR root to the SESSION project (PROJECT_NAME), so cwd-based introspection
# works from /workspace exactly as it does inside a mounted repo dir. For config-editor
# that is the synthetic 'config-editor' envelope (its editing targets stay a distinct
# concept, surfaced by `cco whoami`). Constraints keep it narrow and unambiguous:
#   - operator mode only (the host has no /workspace and no session envelope);
#   - only AT the WORKDIR root — child-wins, a repo-local .cco above is handled first;
#   - only with a flat session manifest present.
# Prints the session project name to use, or nothing (caller then shows usage). The
# WORKDIR is overridable via CCO_WORKDIR (defaults to /workspace) so the trigger is
# unit-testable without a live /workspace mount.
_project_show_session_fallback() {
    local pwd_dir="${1:-$PWD}" workdir="${CCO_WORKDIR:-/workspace}"
    _cco_container_operator || return 0
    [[ "$pwd_dir" == "$workdir" ]] || return 0
    [[ -f "$workdir/project.yml" ]] || return 0
    printf '%s' "${PROJECT_NAME:-}"
}

cmd_project_show() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                cat <<'EOF'
Usage: cco project show <name>

Show details for a configured project.
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    # Repo-centric view (ADR-0024 D5): invoked from a repo dir that hosts a
    # project, with no explicit name → summarize this repo's relationships.
    # Child-wins: a repo-local .cco (e.g. /workspace/<repo>) takes precedence over
    # the session fallback below.
    if [[ -z "$name" && -f "$PWD/.cco/project.yml" ]]; then
        _project_show_repo_centric "$PWD"
        return $?
    fi
    # R4: at the container WORKDIR root a bare `cco project show` resolves the SESSION
    # project (see _project_show_session_fallback), so cwd-based introspection works
    # from /workspace just as inside a mounted repo dir.
    [[ -z "$name" ]] && name=$(_project_show_session_fallback)
    [[ -z "$name" ]] && die "Usage: cco project show <name>"
    # Output scoping (ADR-0043): a detail verb refuses out-of-scope resources
    # with a clear message rather than a raw "not found" (graceful degradation).
    _env_require_visible project "$name"

    # Resolve the project's committed <repo>/.cco/project.yml. Host- and
    # operator-aware (R2): in-container this resolves the mounted /workspace
    # manifest; on the host, the STATE index. An unresolvable name yields a
    # context-appropriate message — "unavailable at this scope" in a session (its
    # .cco is not mounted), "run cco resolve" on the host.
    local project_yml
    if project_yml=$(_resolve_project_yml "$name" 2>/dev/null) && [[ -f "$project_yml" ]]; then
        :
    elif _cco_container_operator; then
        refuse "Project '$name' is not available at this access scope — its config is not mounted in this session. Widen the session's scope on the host, or run cco there."
    else
        die "Project '$name' not found (unknown, or its repo is unresolved here — run 'cco resolve $name')."
    fi

    # Name and description
    local yml_name
    yml_name=$(yml_get "$project_yml" "name")
    local description
    description=$(yml_get "$project_yml" "description")

    echo -e "${BOLD}Project: ${yml_name:-$name}${NC}"
    [[ -n "$description" ]] && echo "  $description"
    echo ""

    # Repos (schema-agnostic via the bridge: name<TAB>abs_path)
    echo -e "${BOLD}Repos:${NC}"
    local repos
    repos=$(_effective_repo_mounts "$project_yml")
    if [[ -n "$repos" ]]; then
        local repo_name repo_path
        local _unresolved=0
        while IFS=$'\t' read -r repo_name repo_path; do
            [[ -z "$repo_name" ]] && continue
            # D5 (ADR-0024): each member's role + the other projects referencing it.
            local role refby
            role=$(_project_member_role "$repo_path" "${yml_name:-$name}" "$repo_name")
            # Referenced-by = other projects mounting this PATH (ADR-0051 D5).
            refby=$([[ -n "$repo_path" ]] && _index_paths_get_bindings "$repo_path" 2>/dev/null | cut -f1 | grep -vxF "${yml_name:-$name}" | sort -u | paste -sd, - 2>/dev/null)
            local suffix="[$role]"
            [[ -n "$refby" ]] && suffix="$suffix — also referenced by: $refby"
            # B-DF1: probe the member where it lives in THIS context (mount
            # in-container, index host path on the host) — never the host path
            # in-container, which cannot exist and made every mounted repo read
            # `[missing]` + "N reference(s) unresolved".
            local _probe _disp
            _probe=$(_cco_member_probe_path "$repo_name" "$repo_path")
            # Host-path hygiene (INV-4), orthogonal to the probe, through the single
            # display helper: a host path is shown only where show_host_paths permits
            # it; otherwise the mount is rendered. Defensive `${:-unresolved}` parity
            # with the prior fallback for a never-empty _effective_repo_mounts path.
            _disp=$(_cco_display_path "$repo_name" "$repo_path")
            _disp="${_disp:-unresolved}"
            if [[ -d "$_probe" ]]; then
                echo "  $repo_name ($_disp) $suffix"
            else
                echo -e "  $repo_name ($_disp) ${YELLOW}[missing]${NC} $suffix"
                _unresolved=$(( _unresolved + 1 ))
            fi
        done <<< "$repos"
        # Passive ⚠ badge (F49 / ADR-0019 D2 layer-e) — awareness, never a block.
        if [[ $_unresolved -gt 0 ]]; then
            echo -e "  ${YELLOW}⚠${NC} ${yml_name:-$name}: $_unresolved reference(s) unresolved — run 'cco resolve $name' to configure them"
        fi
    else
        echo "  (none)"
    fi
    echo ""

    # Packs
    echo -e "${BOLD}Packs:${NC}"
    local packs
    packs=$(yml_get_packs "$project_yml")
    if [[ -n "$packs" ]]; then
        while IFS= read -r pack; do
            [[ -z "$pack" ]] && continue
            if [[ -d "$PACKS_DIR/$pack" ]]; then
                echo "  $pack"
            else
                echo -e "  $pack ${YELLOW}[not found]${NC}"
            fi
        done <<< "$packs"
    else
        echo "  (none)"
    fi
    echo ""

    # Docker config
    echo -e "${BOLD}Docker:${NC}"
    local auth_method
    auth_method=$(yml_get "$project_yml" "auth.method")
    echo "  Auth: ${auth_method:-oauth}"
    local ports
    ports=$(yml_get_ports "$project_yml")
    if [[ -n "$ports" ]]; then
        echo "  Ports: $(echo "$ports" | tr '\n' ' ')"
    else
        echo "  Ports: (none)"
    fi
    local network
    network=$(yml_get "$project_yml" "docker.network")
    echo "  Network: ${network:-cc-${yml_name:-$name}}"
    echo ""

    # Status — detect via the `cco.project` label (R1), not the container name.
    # Tri-state (B4): `unknown` in-container when the registry is unreachable.
    echo -e "${BOLD}Status:${NC}"
    echo -e "  $(_cco_session_status_display "${yml_name:-$name}")"
}
