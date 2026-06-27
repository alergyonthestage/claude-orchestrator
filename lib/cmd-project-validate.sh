#!/usr/bin/env bash
# cco project validate — the share-readiness contract (ADR-0023 D2; carries the
# ADR-0022 D4 pack same-name collision ERROR). Detect-only: it never blocks a
# git push (P14/P17). The exit code is the numeric MAX severity over all
# findings (composable, highest-severity-wins, like grep):
#   0  share-ready
#   1  reachability / coordinate gap   — a referenced id with no coordinate, or
#                                         (with --reachable) an unreachable one
#   2  non-machine-agnostic content    — a real/absolute host path where a
#                                         coordinate belongs, OR a duplicate id
#                                         within a section, OR a pack same-name
#                                         collision (silent-wrong-build, D4)
#
# Output is greppable: one "<section>.<id>: <reason>" line per finding, then a
# one-line tally. Quiet on success unless -v.
#
# Provides: cmd_project_validate()
# Depends:  cmd-resolve.sh (_resolve_find_unit_dir/_resolve_unit_dir_for_project),
#           yaml.sh (yml_get*, *_coords parsers), index.sh (_index_list_projects),
#           packs.sh (_pack_resolve_dir, PACKS_DIR), colors.sh.

# A trimmed scalar that begins with /, ~, or a Windows drive root is a real host
# path (machine-specific). Conservative by design — false-negatives over
# false-positives, since P14 forbids hard-blocking (mirrors lib/secrets.sh).
_PV_ABSPATH_ERE='^(/|~|[A-Za-z]:\\)'

# 0 if the trimmed value looks like a real/absolute host path.
_pv_abspath() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"   # ltrim
    [[ "$v" =~ $_PV_ABSPATH_ERE ]]
}

# 0 if <name> already appears in the space-delimited <list> (logical ids carry
# no spaces).
_pv_is_dup() {
    local item
    for item in $1; do [[ "$item" == "$2" ]] && return 0; done
    return 1
}

# Forbidden path-bearing keys: the new schema has NO `path:`/`source:` keys
# (host paths live in the machine-local index; sources are url coordinates).
# Any such key carrying an absolute value is the rejected "inline path in
# project.yml" flow (ADR-0023 D3) — the D2 safety-net reports it, never strips.
# Emits "<key>\t<value>" per offending line. `target:` (a container mount point)
# and the env/ports/setup container-side values are never scanned.
_pv_scan_stray_paths() {
    awk '
        /^[[:space:]]*(path|source):[[:space:]]*[^[:space:]]/ {
            key=$0; sub(/^[[:space:]]*/,"",key); sub(/:.*/,"",key)
            val=$0; sub(/^[^:]*:[[:space:]]*/,"",val)
            sub(/[ \t]+#.*$/,"",val); gsub(/^[ \t]+|[ \t]+$/,"",val)
            gsub(/^["\047]|["\047]$/,"",val)
            if (val ~ /^(\/|~|[A-Za-z]:\\)/) print key "\t" val
        }
    ' "$1"
}

# Run "$@" under a timeout when the platform provides one; else run directly.
_pv_run_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
    else "$@"; fi
}

# Probe a coordinate for reachability, offline-tolerant. Echoes ok|unreachable|
# unknown. A timeout / no-network is "unknown" (never a hard fail — P14).
_pv_probe() {
    local kind="$1" url="$2" rc code
    case "$kind" in
        llms)
            code=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo 000)
            case "$code" in
                2??|3??) echo ok ;;
                000)     echo unknown ;;
                *)       echo unreachable ;;
            esac
            ;;
        *)  # git remotes (repo / pack / mount). Reachability = can we connect and
            # read refs at all — NOT whether a HEAD exists (an empty-but-live
            # remote is reachable), so no --exit-code.
            if _pv_run_timeout 15 git ls-remote "$url" >/dev/null 2>&1; then
                echo ok
            else
                rc=$?
                if [[ $rc -eq 124 ]]; then echo unknown; else echo unreachable; fi
            fi
            ;;
    esac
}

# Record a finding. <bucket> reach|agnostic|unique|collide ; <sev> 1|2 ; <line>.
# Relies on bash dynamic scoping — the accumulators are locals of the calling
# _pv_validate_unit.
_pv_flag() {
    _PV_FIND+=("$3")
    case "$1" in
        reach)    _PV_NREACH=$(( _PV_NREACH + 1 )) ;;
        agnostic) _PV_NAGN=$(( _PV_NAGN + 1 )) ;;
        unique)   _PV_NUNIQ=$(( _PV_NUNIQ + 1 )) ;;
        collide)  _PV_NCOLL=$(( _PV_NCOLL + 1 )) ;;
    esac
    [[ "$2" -gt "$_PV_SEV" ]] && _PV_SEV="$2"
    return 0
}

# Per-section validators. Each peels its coordinate records (empty MIDDLE fields
# survive via _peel_tab — `IFS=$'\t' read` would collapse them) and records
# findings via _pv_flag. The accumulators live in _pv_validate_unit and are
# reached through bash dynamic scoping, so these run only as its callees.

# repos: url is the coordinate; no url = gap; dup name = uniqueness.
_pv_validate_repos() {
    local yml="$1" reachable="$2" _ln name url seen=""
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        _peel_tab "$_ln" name url
        [[ -z "$name" ]] && continue
        if _pv_is_dup "$seen" "$name"; then _pv_flag unique 2 "repos.$name: duplicate id within 'repos'"; fi
        seen="$seen $name"
        if [[ -z "$url" ]]; then
            _pv_flag reach 1 "repos.$name: no coordinate (url) — a teammate cloning the repo cannot resolve it"
        elif _pv_abspath "$url"; then
            _pv_flag agnostic 2 "repos.$name: url is a real/absolute path '$url'"
        elif [[ "$reachable" == true ]]; then
            [[ "$(_pv_probe repo "$url")" == unreachable ]] && _pv_flag reach 1 "repos.$name: url not reachable '$url'"
        fi
    done < <(yml_get_repo_coords "$yml")
}

# extra_mounts: same coordinate gap rule as repos (Q3); the container-side
# `target` path is exempt from the agnostic scan (not read here).
_pv_validate_mounts() {
    local yml="$1" reachable="$2" _ln name url seen=""
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        _peel_tab "$_ln" name url
        [[ -z "$name" ]] && continue
        if _pv_is_dup "$seen" "$name"; then _pv_flag unique 2 "extra_mounts.$name: duplicate id within 'extra_mounts'"; fi
        seen="$seen $name"
        if [[ -z "$url" ]]; then
            _pv_flag reach 1 "extra_mounts.$name: no coordinate (url) — only resolvable on this machine"
        elif _pv_abspath "$url"; then
            _pv_flag agnostic 2 "extra_mounts.$name: url is a real/absolute path '$url'"
        elif [[ "$reachable" == true ]]; then
            [[ "$(_pv_probe mount "$url")" == unreachable ]] && _pv_flag reach 1 "extra_mounts.$name: url not reachable '$url'"
        fi
    done < <(yml_get_mount_coords "$yml")
}

# llms: url is MANDATORY (ADR-0017) — no url = gap. Record shape is
# name\tdesc\tvariant\turl, so url is the 4th field.
_pv_validate_llms() {
    local yml="$1" reachable="$2" _ln name url _d _v seen=""
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        _peel_tab "$_ln" name _d _v url
        [[ -z "$name" ]] && continue
        if _pv_is_dup "$seen" "$name"; then _pv_flag unique 2 "llms.$name: duplicate id within 'llms'"; fi
        seen="$seen $name"
        if [[ -z "$url" ]]; then
            _pv_flag reach 1 "llms.$name: no coordinate (url) — llms references require a url"
        elif _pv_abspath "$url"; then
            _pv_flag agnostic 2 "llms.$name: url is a real/absolute path '$url'"
        elif [[ "$reachable" == true ]]; then
            [[ "$(_pv_probe llms "$url")" == unreachable ]] && _pv_flag reach 1 "llms.$name: url not reachable '$url'"
        fi
    done < <(yml_get_llms "$yml")
}

# packs: a url-less entry is an AUTHORED-in-repo source (LEGAL, P15) — NOT a gap.
# The D4 ERROR is a no-url authored pack that ALSO exists as a same-named global
# ~/.cco/packs/X (mount precedence then runs the WRONG pack — a silent-wrong-
# build). A url-carrying entry follows the normal coordinate rules.
_pv_validate_packs() {
    local yml="$1" reachable="$2" cco_dir="$3" _ln name url ref resource seen=""
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        _peel_tab "$_ln" name url ref resource
        [[ -z "$name" ]] && continue
        if _pv_is_dup "$seen" "$name"; then _pv_flag unique 2 "packs.$name: duplicate id within 'packs'"; fi
        seen="$seen $name"
        if [[ -z "$url" ]]; then
            # authored-in-repo source
            if [[ -d "$PACKS_DIR/$name" && -d "$cco_dir/packs/$name" ]]; then
                _pv_flag collide 2 "packs.$name: authored-in-repo pack collides with a same-named ~/.cco/packs/$name (silent-wrong-build — ADR-0022 D4)"
            elif [[ ! -d "$cco_dir/packs/$name" && ! -d "$PACKS_DIR/$name" ]]; then
                _pv_flag reach 1 "packs.$name: authored pack has no source — expected $cco_dir/packs/$name"
            fi
        else
            _pv_abspath "$url" && _pv_flag agnostic 2 "packs.$name: url is a real/absolute path '$url'"
            if [[ "$reachable" == true ]] && ! _pv_abspath "$url"; then
                [[ "$(_pv_probe pack "$url")" == unreachable ]] && _pv_flag reach 1 "packs.$name: url not reachable '$url'"
            fi
            _pv_abspath "$resource" && _pv_flag agnostic 2 "packs.$name: resource is a real/absolute path '$resource'"
        fi
    done < <(yml_get_pack_coords "$yml")
}

# stray forbidden path keys (the rejected inline-path flow, D3).
_pv_validate_stray_paths() {
    local yml="$1" skey sval
    while IFS=$'\t' read -r skey sval; do
        [[ -z "$skey" ]] && continue
        _pv_flag agnostic 2 "project.yml: forbidden '$skey: $sval' — host paths live in the index, not in committed config (run 'cco resolve' / 'cco project add ... --path')"
    done < <(_pv_scan_stray_paths "$yml")
}

# Validate one unit. Args: <project_yml> <unit_cco_dir> <label> <reachable> <verbose> <prefix>
# Prints findings + a tally; returns the unit's max severity (0/1/2).
_pv_validate_unit() {
    local yml="$1" cco_dir="$2" label="$3" reachable="$4" verbose="$5" prefix="$6"
    local -a _PV_FIND=()
    local _PV_SEV=0 _PV_NREACH=0 _PV_NAGN=0 _PV_NUNIQ=0 _PV_NCOLL=0

    # project.yml 'name' must be present (a content error).
    local pname; pname=$(yml_get "$yml" name)
    [[ -z "$pname" ]] && _pv_flag agnostic 2 "project.yml: missing required field 'name'"

    _pv_validate_repos       "$yml" "$reachable"
    _pv_validate_mounts      "$yml" "$reachable"
    _pv_validate_llms        "$yml" "$reachable"
    _pv_validate_packs       "$yml" "$reachable" "$cco_dir"
    _pv_validate_stray_paths "$yml"

    # ---- emit ----
    local f
    if [[ ${#_PV_FIND[@]} -gt 0 ]]; then
        local ids="" idkey nids=0
        for f in "${_PV_FIND[@]}"; do
            printf '%s%s\n' "$prefix" "$f"
            idkey="${f%%: *}"                     # "<section>.<id>" (or "project.yml")
            _pv_is_dup "$ids" "$idkey" || { ids="$ids $idkey"; nids=$(( nids + 1 )); }
        done
        printf '%svalidate: %d issue(s) across %d id(s) [reachability=%d agnostic=%d uniqueness=%d collision=%d]\n' \
            "$prefix" "${#_PV_FIND[@]}" "$nids" "$_PV_NREACH" "$_PV_NAGN" "$_PV_NUNIQ" "$_PV_NCOLL"
    elif [[ "$verbose" == true ]]; then
        ok "Project '${pname:-$label}' is share-ready"
    fi
    return "$_PV_SEV"
}

cmd_project_validate() {
    local all=false reachable=false verbose=false target=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)        all=true; shift ;;
            --reachable)  reachable=true; shift ;;
            -v|--verbose) verbose=true; shift ;;
            --help|-h)
                cat <<'EOF'
Usage: cco project validate [name] [--all] [--reachable] [-v]

Check that a project's config is safe to share via its repo remote: every
referenced repo/mount/llms/pack carries a reachable, machine-agnostic
coordinate, no real host paths leak, and no pack-name collision shadows an
authored pack. Detect-only — it never blocks a git push.

Arguments:
  name           Project to validate (defaults to the cwd's hosted project)

Options:
  --all          Validate every project in the index
  --reachable    Also probe that each coordinate is currently reachable
  -v, --verbose  Print a line on success too

Exit codes: 0 share-ready · 1 reachability/coordinate gap · 2 path leak,
duplicate id, or pack collision.
EOF
                return 0 ;;
            -*) die "Unknown option: $1" ;;
            *)
                [[ -n "$target" ]] && die "Unexpected argument: $1"
                target="$1"; shift ;;
        esac
    done

    local max=0 rc

    if [[ "$all" == true ]]; then
        [[ -n "$target" ]] && die "'cco project validate --all' takes no project name."
        local proj unit_dir yml first=true
        while IFS='=' read -r proj _; do
            [[ -z "$proj" ]] && continue
            unit_dir=$(_resolve_unit_dir_for_project "$proj" 2>/dev/null) || {
                warn "skipping '$proj' — its repo is unresolved here (run 'cco resolve $proj')"; continue; }
            yml="$unit_dir/.cco/project.yml"
            [[ -f "$yml" ]] || continue
            [[ "$first" == true ]] || echo ""
            first=false
            echo "[$proj]"
            _pv_validate_unit "$yml" "$unit_dir/.cco" "$proj" "$reachable" "$verbose" "  " || rc=$?
            [[ "${rc:-0}" -gt "$max" ]] && max="${rc:-0}"
            rc=0
        done < <(_index_list_projects)
        return "$max"
    fi

    # Single unit: cwd-first, else resolve [name] via the index.
    local unit_dir yml
    if [[ -z "$target" ]]; then
        unit_dir=$(_resolve_find_unit_dir) \
            || die "No project here — run from a repo that has .cco/project.yml, or pass a project name (or --all)."
    else
        unit_dir=$(_resolve_unit_dir_for_project "$target" 2>/dev/null) \
            || die "Project '$target' not found (unknown, or its repo is unresolved here — run 'cco resolve $target')."
    fi
    yml="$unit_dir/.cco/project.yml"
    [[ -f "$yml" ]] || die "Project has no .cco/project.yml at $unit_dir."

    _pv_validate_unit "$yml" "$unit_dir/.cco" "$(basename "$unit_dir")" "$reachable" "$verbose" "" || max=$?
    return "$max"
}
