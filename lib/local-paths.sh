#!/usr/bin/env bash
# lib/local-paths.sh — Project path resolution (index-based)
#
# The machine-local STATE index (lib/index.sh) is the sole name→path map. Repos
# and extra_mounts in project.yml carry logical names only (coordinates); the
# absolute path is looked up in the index at resolution time. The legacy `@local`
# + `.cco/local-paths.yml` schema and its transitional bridge were removed in
# P4-5; only _local_paths_get (read-only) survives, used by `cco init --migrate`
# to recover real paths from a legacy vault backup.
#
# Provides: _local_paths_get(), _prompt_for_path(), _effective_repo_mounts(),
#   _effective_extra_mounts(), _resolve_entry_index(), _project_effective_paths()
#
# Session-start path resolution is NOT here: `cco start` and `cco resolve` share
# the SINGLE resolution surface _resolve_unit (lib/cmd-resolve.sh) — ADR-0033 / S1
# finding #7. The former parallel loop (_resolve_project_paths_impl /
# _resolve_start_paths) was retired to keep one entry point.
# Dependencies: colors.sh, utils.sh, yaml.sh

# ── local-paths.yml read/write helpers ───────────────────────────────

# Dump all key=value pairs of a section from local-paths.yml.
# Usage: _local_paths_get_section <file> <section>
# Output: newline-separated "key=value" lines (stdout), empty if no section.
# Note: sole entry point for reading sections (used by _local_paths_get and
# the bridge-legacy resolve path) to avoid drift.
_local_paths_get_section() {
    local file="$1" section="$2"
    [[ ! -f "$file" ]] && return 0

    awk -v section="$section" '
        $0 == section":" { in_section=1; next }
        in_section && /^[^ #]/ { exit }
        in_section && /^  / {
            line = $0
            sub(/^  /, "", line)
            colon = index(line, ":")
            if (colon > 0) {
                k = substr(line, 1, colon - 1)
                v = substr(line, colon + 1)
                sub(/^ +/, "", v)
                gsub(/["\047]/, "", v)
                if (k != "" && v != "") print k "=" v
            }
        }
    ' "$file"
}

# Read a single path value from local-paths.yml.
# Usage: _local_paths_get <file> <section> <key>
# Output: the path value (stdout), or empty string if not found.
_local_paths_get() {
    local file="$1" section="$2" key="$3"
    local dump
    dump=$(_local_paths_get_section "$file" "$section")
    [[ -z "$dump" ]] && return 0
    local line
    while IFS= read -r line; do
        local k="${line%%=*}" v="${line#*=}"
        if [[ "$k" == "$key" ]]; then
            printf '%s\n' "$v"
            return 0
        fi
    done <<< "$dump"
}

# ── Interactive prompt ───────────────────────────────────────────────

# Prompt user for a local path (TTY only).
# Usage: _prompt_for_path <name> <url> <suggested_path> <label>
# Output (stdout): resolved path
# Exit codes: 0=resolved, 1=skip, 2=abort
_prompt_for_path() {
    local name="$1" url="$2" suggested="$3" label="${4:-Repository}"

    if ! _cco_have_tty; then
        # No controlling terminal: cannot prompt
        return 2
    fi

    echo "" >&2
    echo -e "  ${BOLD}${label} '${name}'${NC} not found" >&2
    if [[ -n "$url" ]]; then
        echo -e "  URL: ${BLUE}${url}${NC}" >&2
    fi
    echo "" >&2

    local options=""
    if [[ -n "$url" ]]; then
        echo "  (c) Clone to ${suggested:-~/Projects/$name}" >&2
        options="c/p/s/q"
    else
        options="p/s/q"
    fi
    echo "  (p) Specify path" >&2
    # bash 3.2 compatible lowercase — no ${label,,} (macOS default bash)
    echo "  (s) Skip this $(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')" >&2
    echo "  (q) Exit" >&2
    echo "" >&2

    local reply
    printf "  Choice [%s]: " "$options" >&2
    read -r reply < /dev/tty

    case "$reply" in
        [Cc])
            if [[ -z "$url" ]]; then
                warn "No URL available for clone"
                # Fall through to path prompt
                printf "  Path for '%s': " "$name" >&2
                read -r reply < /dev/tty
                [[ -z "$reply" ]] && return 1
                local expanded
                # M7: absolutize (not just ~-expand) before storing in the index —
                # a relative path would resolve wrong from another cwd.
                expanded=$(_resolve_to_abs "$reply")
                # Use _path_exists (not `-d`) — extra_mounts may be files
                if ! _path_exists "$expanded"; then
                    warn "Path '$expanded' does not exist"
                    return 1
                fi
                echo "$expanded"
                return 0
            fi
            local clone_target="${suggested:-$HOME/Projects/$name}"
            clone_target=$(expand_path "$clone_target")
            local parent
            parent=$(dirname "$clone_target")
            mkdir -p "$parent"
            info "Cloning into $clone_target..."
            if git clone "$url" "$clone_target" >/dev/null 2>&1; then
                ok "Cloned $name"
                echo "$clone_target"
                return 0
            else
                error "Failed to clone $url"
                return 1
            fi
            ;;
        [Pp])
            printf "  Path for '%s': " "$name" >&2
            read -r reply < /dev/tty
            [[ -z "$reply" ]] && return 1
            local expanded
            # M7: absolutize (not just ~-expand) before storing in the index —
            # a relative path would resolve wrong from another cwd.
            expanded=$(_resolve_to_abs "$reply")
            # Use _path_exists (not `-d`) — extra_mounts may be files
            if ! _path_exists "$expanded"; then
                warn "Path '$expanded' does not exist"
                return 1
            fi
            echo "$expanded"
            return 0
            ;;
        [Ss])
            return 1
            ;;
        [Qq])
            return 2
            ;;
        *)
            warn "Invalid choice '$reply'"
            return 1
            ;;
    esac
}

# ── Effective mounts (index-backed) ──────────────────────────────────
#
# project.yml carries logical names only (coordinates via yml_get_repo_coords /
# yml_get_mount_coords); the absolute path comes from the STATE index
# (lib/index.sh). Post-resolution consumers (mount-gen, proxy, workspace,
# summaries) call these after _resolve_*_paths, so a
# resolved name binds to a real path and an unresolved one is consciously
# skipped (P14, #B17 — never a silent empty mount).

# Emit the RESOLVED repo set as "<name>\t<abs_path>" lines (one per repo). A
# member still unresolved after the F49 prompt has no index path → excluded.
_effective_repo_mounts() {
    local project_yml="$1"
    # Peel the name field by tab (IFS=$'\t' read collapses empty middle fields).
    local _ln name _p
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        name="${_ln%%$'\t'*}"
        [[ -z "$name" ]] && continue
        # Conscious-skip (design §4.4 / P14): a member still unresolved after
        # the F49 prompt has no index path — exclude it (never emit a silent
        # empty mount, #B17); _start_resolve_paths already warned + ⚠-badged it.
        _p=$(_index_get_path "$name")
        # Skip empty AND any NON-ABSOLUTE index value. A bogus marker like the
        # legacy `@local` must never reach the compose as a mount source — its
        # leading `@` is a reserved YAML char that breaks `docker compose`
        # (#B17 / conscious-skip; the index always stores absolute paths).
        [[ "$_p" != /* ]] && continue
        printf '%s\t%s\n' "$name" "$_p"
    done < <(yml_get_repo_coords "$project_yml" 2>/dev/null)
}

# Companion bridge for extra mounts. Emit "<abs_source>\t<target>\t<ro>" per
# mount (ro = "true"|"false"). LEGACY: source/target/ro from project.yml
# (source already resolved + expanded). NEW: source from the index by name,
# target defaults to /workspace/<name>, readonly defaults to true.
# Session-local mount override (set by the internal config-editor only): maps a few
# fixed internal mount names to host paths WITHOUT writing the persistent STATE index
# (review H4 — the index is user-facing config, not an ephemeral routing table; raw
# _index_set_path there clobbered user bindings like a repo named `cco-docs`).
# Newline-delimited "name<TAB>path" lines in the in-process global $_CCO_MOUNT_OVERRIDE.
_mount_override_get() {
    local name="$1" oname opath
    [[ -n "${_CCO_MOUNT_OVERRIDE:-}" ]] || return 1
    while IFS=$'\t' read -r oname opath; do
        [[ "$oname" == "$name" ]] && { printf '%s' "$opath"; return 0; }
    done <<< "$_CCO_MOUNT_OVERRIDE"
    return 1
}

_effective_extra_mounts() {
    local project_yml="$1"
    # Peel fields by tab (IFS=$'\t' read collapses empty middle fields, so
    # a name-only mount "name\t\t\ttarget\tro" would mis-assign target/ro).
    local _ln name target ro_raw ro rest policy
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        name="${_ln%%$'\t'*}"; rest="${_ln#*$'\t'}"   # rest = url\tref\ttarget\tro\tpolicy
        rest="${rest#*$'\t'}"                          # drop url
        rest="${rest#*$'\t'}"                          # drop ref
        target="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"  # target, rest = ro\tpolicy
        ro_raw="${rest%%$'\t'*}"
        policy="${rest#*$'\t'}"; [[ "$policy" == "$ro_raw" ]] && policy=""  # no policy field
        [[ -z "$name" ]] && continue
        # Conscious-skip: exclude an unresolved mount (no index path) rather
        # than emit a silent empty mount (#B17; design §4.4 / P14). A session-local
        # internal override (config-editor, H4) wins over the persistent index.
        local _ms; _ms=$(_mount_override_get "$name" || _index_get_path "$name")
        # Skip empty AND any NON-ABSOLUTE value (e.g. a stale `@local` marker —
        # leading `@` is a reserved YAML char that would break the compose).
        [[ "$_ms" != /* ]] && continue
        [[ -z "$target" ]] && target="/workspace/$name"
        ro=$(_parse_bool "$ro_raw" "true")
        # config_access_policy (ADR-0049 §7): governs NESTED .claude/.cco inside the
        # mount — ro (default, strict) | project (follow session knobs) | write.
        # Invalid/empty → ro (strict default). The 4th output field (extends the
        # abs_source<TAB>target<TAB>ro contract; readers ignore it unless they act).
        case "$policy" in project|write) : ;; *) policy="ro" ;; esac
        printf '%s\t%s\t%s\t%s\n' "$_ms" "$target" "$ro" "$policy"
    done < <(yml_get_mount_coords "$project_yml" 2>/dev/null)
}

# R7 — the DECLARED extra_mounts that do NOT resolve on this host (the set
# _effective_extra_mounts silently conscious-skips). One "<name>\t<target>" line
# each, so Level-A can surface them ("declared but not mounted this session")
# instead of leaving the agent to reason about a mount that is not there — the
# omission is terminal at `none` (no CLI to discover it). Marker-only: the
# auto-skip vs user-skip provenance degrades per the fix design's caveat (the skip
# choice is not recorded where this can read it).
_declared_unresolved_extra_mounts() {
    local project_yml="$1"
    local _ln name rest target _ms
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        name="${_ln%%$'\t'*}"; rest="${_ln#*$'\t'}"
        rest="${rest#*$'\t'}"   # drop url
        rest="${rest#*$'\t'}"   # drop ref
        target="${rest%%$'\t'*}"
        [[ -z "$name" ]] && continue
        _ms=$(_mount_override_get "$name" || _index_get_path "$name")
        [[ "$_ms" == /* ]] && continue   # resolved → not in the unresolved set
        [[ -z "$target" ]] && target="/workspace/$name"
        printf '%s\t%s\n' "$name" "$target"
    done < <(yml_get_mount_coords "$project_yml" 2>/dev/null)
}

# Single-entry resolution: look up <name> in the STATE index; if unresolved or
# its path is gone, prompt (reusing _prompt_for_path) and store the result in
# the index. No project.yml write (AD3 — project.yml has no path).
# Output: resolved abs path (stdout). Exit: 0=resolved, 1=skipped, 2=abort.
_resolve_entry_index() {
    local project_dir="$1" section="$2" name="$3" url="${4:-}"

    local existing
    existing=$(_index_get_path "$name")
    if [[ -n "$existing" ]] && _path_exists "$existing"; then
        echo "$existing"
        return 0
    fi

    local label="Repository"
    [[ "$section" == "extra_mounts" ]] && label="Mount"

    # Best-effort suggestion: a sibling directory from an existing index entry.
    local suggested=""
    if [[ "$section" == "repos" ]]; then
        local sib sibp
        sib=$(_index_list_paths | head -1)
        sibp="${sib#*=}"
        [[ -n "$sib" && -n "$sibp" ]] && suggested="$(dirname "$sibp")/$name"
    fi

    local resolved rc=0
    resolved=$(_prompt_for_path "$name" "$url" "$suggested" "$label") || rc=$?

    if [[ $rc -eq 0 && -n "$resolved" ]]; then
        _index_set_path "$name" "$resolved"
        echo "$resolved"
        return 0
    elif [[ $rc -eq 2 ]]; then
        return 2
    else
        return 1
    fi
}

# ── Effective paths — single source of truth for consumers ───────────

# Emit the effective (post-resolution) source path for every entry in a
# project.yml. Single read path for the post-resolution consumers (mount-gen and
# the proxy policy) — display and runtime agree because both derive from it.
#
# Output format (tab-separated lines on stdout):
#   <kind>\t<key>\t<effective_path>\t<status>
# where:
#   kind   = "repos" | "mounts"
#   key    = the logical repo/mount name
#   effective_path = the absolute path from the STATE index (empty if unresolved)
#   status = "exists" (reached via _path_exists), "missing" (index entry but the
#            path is absent), or "unresolved" (no STATE index entry)
#
# Usage: _project_effective_paths <project_dir>
_project_effective_paths() {
    local project_dir="$1"
    local project_yml="$project_dir/project.yml"

    [[ ! -f "$project_yml" ]] && return 0

    # Repos — logical names; abs path from the STATE index (unresolved = no entry).
    local _ln name effective status
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        name="${_ln%%$'\t'*}"
        [[ -z "$name" ]] && continue
        effective=$(_index_get_path "$name")
        if [[ -z "$effective" ]]; then
            printf 'repos\t%s\t\tunresolved\n' "$name"
            continue
        fi
        if _path_exists "$effective"; then
            status="exists"
        else
            status="missing"
        fi
        printf 'repos\t%s\t%s\t%s\n' "$name" "$effective" "$status"
    done < <(yml_get_repo_coords "$project_yml" 2>/dev/null)

    # Mounts — logical names; abs source from the STATE index; key = name.
    local _ml mname meffective mstatus
    while IFS= read -r _ml; do
        [[ -z "$_ml" ]] && continue
        mname="${_ml%%$'\t'*}"
        [[ -z "$mname" ]] && continue
        meffective=$(_index_get_path "$mname")
        if [[ -z "$meffective" ]]; then
            printf 'mounts\t%s\t\tunresolved\n' "$mname"
            continue
        fi
        if _path_exists "$meffective"; then
            mstatus="exists"
        else
            mstatus="missing"
        fi
        printf 'mounts\t%s\t%s\t%s\n' "$mname" "$meffective" "$mstatus"
    done < <(yml_get_mount_coords "$project_yml" 2>/dev/null)
}

# NOTE: the old `_assert_resolved_paths` blocking guard was removed — the P14
# conscious-skip in _effective_repo_mounts / _effective_extra_mounts (warn +
# exclude an unresolved reference, never a silent empty bind-mount, #B17) is the
# live mechanism. `_project_effective_paths` above remains the single read path.
