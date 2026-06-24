#!/usr/bin/env bash
# lib/local-paths.sh — Project path resolution (index-based + transitional bridge)
#
# The machine-local STATE index is the name→path map. A transitional schema
# bridge (_effective_repo_mounts / _effective_extra_mounts /
# _project_effective_paths) still reads the legacy `- path:`/`- source:` schema
# with @local markers + .cco/local-paths.yml; that legacy branch collapses to
# index-only in P4-5c. The vault sanitize/extract/restore family was removed in
# P4-5b (orphaned when the vault + project publish/install were retired).
#
# Provides: _local_paths_get(), _local_paths_set(), _prompt_for_path(),
#   _get_repo_url(), _resolve_entry(), _update_yml_path(),
#   _resolve_project_paths_impl(), _resolve_start_paths(),
#   _effective_repo_mounts(), _effective_extra_mounts(), _resolve_entry_index(),
#   _project_effective_paths(), _assert_resolved_paths()
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

# Write or update a path value in local-paths.yml.
# Creates the file if it doesn't exist.
# Usage: _local_paths_set <file> <section> <key> <value>
_local_paths_set() {
    local file="$1" section="$2" key="$3" value="$4"

    # Create file if needed
    if [[ ! -f "$file" ]]; then
        mkdir -p "$(dirname "$file")"
        {
            echo "# Machine-specific path mappings — auto-managed by cco"
            echo "# Do not edit manually; use 'cco project resolve <name>' to update paths"
            echo ""
            echo "${section}:"
            echo "  ${key}: \"${value}\""
        } > "$file"
        return 0
    fi

    # Check if section and key exist
    local has_section has_key=""
    has_section=$(awk -v s="$section" '$0 == s":" { print "yes"; exit }' "$file")
    if [[ "$has_section" == "yes" ]]; then
        has_key=$(awk -v section="$section" -v key="$key" '
            $0 == section":" { in_section=1; next }
            in_section && /^[^ #]/ { exit }
            in_section {
                line = $0
                sub(/^  /, "", line)
                colon = index(line, ":")
                if (colon > 0) {
                    k = substr(line, 1, colon - 1)
                    if (k == key) { print "yes"; exit }
                }
            }
        ' "$file")
    fi

    # Cleanup any tempfile left behind if the AWK rewrite fails before
    # the atomic mv (so we never commit `foo.XXXXXX` ghosts — see #B20).
    local tmpf="" tmpf2=""
    # shellcheck disable=SC2064
    trap 'rm -f ${tmpf:+"$tmpf"} ${tmpf2:+"$tmpf2"}' RETURN

    if [[ "$has_key" == "yes" ]]; then
        # Update existing entry
        tmpf=$(mktemp "${file}.XXXXXX")
        # Pass value via env to avoid AWK -v backslash expansion
        CCO_VALUE="$value" awk -v section="$section" -v key="$key" '
            BEGIN { value = ENVIRON["CCO_VALUE"] }
            $0 == section":" { in_section=1; print; next }
            in_section && /^[^ #]/ { in_section=0 }
            in_section {
                line = $0
                sub(/^  /, "", line)
                colon = index(line, ":")
                if (colon > 0) {
                    k = substr(line, 1, colon - 1)
                    if (k == key) {
                        print "  " key ": \"" value "\""
                        next
                    }
                }
            }
            { print }
        ' "$file" > "$tmpf" && mv "$tmpf" "$file"
    elif [[ "$has_section" == "yes" ]]; then
        # Append entry to existing section (before next section or EOF)
        tmpf2=$(mktemp "${file}.XXXXXX")
        CCO_VALUE="$value" awk -v section="$section" -v key="$key" '
            BEGIN { value = ENVIRON["CCO_VALUE"] }
            $0 == section":" { in_section=1; print; next }
            in_section && /^[^ #]/ {
                # End of section — insert before next section
                print "  " key ": \"" value "\""
                in_section=0
                inserted=1
            }
            { print }
            END { if (in_section && !inserted) print "  " key ": \"" value "\"" }
        ' "$file" > "$tmpf2" && mv "$tmpf2" "$file"
    else
        # Append new section
        {
            echo ""
            echo "${section}:"
            echo "  ${key}: \"${value}\""
        } >> "$file"
    fi
}

# ── Interactive prompt ───────────────────────────────────────────────

# Prompt user for a local path (TTY only).
# Usage: _prompt_for_path <name> <url> <suggested_path> <label>
# Output (stdout): resolved path
# Exit codes: 0=resolved, 1=skip, 2=abort
_prompt_for_path() {
    local name="$1" url="$2" suggested="$3" label="${4:-Repository}"

    if [[ ! -t 0 ]]; then
        # Non-TTY: cannot prompt
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
                expanded=$(expand_path "$reply")
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
            expanded=$(expand_path "$reply")
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

# ── Single entry resolution ──────────────────────────────────────────

# Extract url: for a given repo name from project.yml.
# Usage: _get_repo_url <project_yml> <repo_name>
_get_repo_url() {
    local project_yml="$1" repo_name="$2"
    awk -v name="$repo_name" '
        /^repos:/ { in_repos=1; next }
        in_repos && /^[^ #]/ { exit }
        in_repos && /^    name:/ {
            n=$0; sub(/^    name: */, "", n); gsub(/[\"'"'"'[:space:]]/, "", n)
            current_name=n
        }
        in_repos && /^    url:/ && current_name == name {
            u=$0; sub(/^    url: */, "", u); gsub(/[\"'"'"'[:space:]]/, "", u)
            print u; exit
        }
    ' "$project_yml"
}

# Resolve a single @local entry: check local-paths.yml, prompt if needed.
# Usage: _resolve_entry <project_dir> <section> <key> [<url>]
# Output (stdout): resolved path, or empty (skip)
# Exit code: 0=resolved, 1=skipped, 2=abort
_resolve_entry() {
    local project_dir="$1" section="$2" key="$3" url="${4:-}"
    local local_paths="$project_dir/.cco/local-paths.yml"

    # Check local-paths.yml first. Use _path_exists (not `-d`) because
    # extra_mounts can legitimately point to a single file — e.g. a .docx
    # or .md — not only directories. Fix finding #B18.
    local stored_path
    stored_path=$(_local_paths_get "$local_paths" "$section" "$key")
    if [[ -n "$stored_path" ]]; then
        if _path_exists "$stored_path"; then
            echo "$stored_path"
            return 0
        fi
        # Path in local-paths.yml but doesn't exist — fall through to prompt
    fi

    # Determine label and suggested path
    local label="Repository"
    local suggested=""
    if [[ "$section" == "extra_mounts" ]]; then
        label="Mount"
    fi

    # Try to suggest a path based on siblings
    if [[ "$section" == "repos" && -f "$local_paths" ]]; then
        local sibling_path
        sibling_path=$(awk '
            /^repos:/ { in_section=1; next }
            in_section && /^[^ #]/ { exit }
            in_section && /^  / {
                line = $0; sub(/^  /, "", line)
                colon = index(line, ":")
                if (colon > 0) {
                    v = substr(line, colon + 1)
                    sub(/^ +/, "", v)
                    gsub(/["\047]/, "", v)
                    if (v != "") { print v; exit }
                }
            }
        ' "$local_paths")
        if [[ -n "$sibling_path" ]]; then
            local sibling_expanded
            sibling_expanded=$(expand_path "$sibling_path")
            local sibling_parent
            sibling_parent=$(dirname "$sibling_expanded")
            suggested="$sibling_parent/$key"
        fi
    fi

    # Prompt
    local resolved
    resolved=$(_prompt_for_path "$key" "$url" "$suggested" "$label")
    local rc=$?

    if [[ $rc -eq 0 && -n "$resolved" ]]; then
        # Save to local-paths.yml
        _local_paths_set "$local_paths" "$section" "$key" "$resolved"
        echo "$resolved"
        return 0
    elif [[ $rc -eq 2 ]]; then
        return 2  # abort
    else
        return 1  # skip
    fi
}

# ── Start: resolve paths with interactive prompt ─────────────────────

# Update a single path: value in project.yml using AWK.
# Usage: _update_yml_path <project_yml> <section> <key_field> <key_value> <path_field> <new_path>
# section: "repos" or "extra_mounts"
# key_field/key_value: e.g. "name"/"backend-api" or "target"/"/workspace/docs"
# path_field: "path" or "source"
_update_yml_path() {
    local yml_file="$1" section="$2" key_field="$3" key_value="$4" path_field="$5" new_path="$6"
    local tmpf=""
    # shellcheck disable=SC2064
    trap 'rm -f ${tmpf:+"$tmpf"}' RETURN
    tmpf=$(mktemp "${yml_file}.XXXXXX")

    # Pass new_path via env to avoid AWK -v backslash expansion (W3)
    CCO_NEW_PATH="$new_path" awk -v section="$section" -v key_field="$key_field" \
        -v key_value="$key_value" -v path_field="$path_field" '
        BEGIN {
            section_re = "^" section ":[[:space:]]*$"
            new_path = ENVIRON["CCO_NEW_PATH"]
        }
        $0 ~ section_re { in_section=1; print; next }
        in_section && /^[^ #]/ {
            if (_in_entry) {
                print _entry_path_line
                for (_bi = 1; _bi <= _entry_buf_n; _bi++) print _entry_buf[_bi]
                _in_entry = 0
            }
            in_section=0
        }

        in_section && $0 ~ "^  - " path_field ":" && !_in_entry {
            _entry_path_line = $0
            _entry_buf_n = 0
            delete _entry_buf
            _in_entry = 1
            next
        }

        in_section && _in_entry {
            kf_re = "^    " key_field ":"
            if ($0 ~ kf_re) {
                kv = $0; sub("^    " key_field ": *", "", kv)
                gsub(/[\"'"'"'"'"'"'[:space:]]/, "", kv)
                if (kv == key_value) {
                    print "  - " path_field ": \"" new_path "\""
                    for (_bi = 1; _bi <= _entry_buf_n; _bi++) print _entry_buf[_bi]
                    print $0
                    _in_entry = 0
                    next
                }
                # Key field found but value differs — not our entry, flush as-is
                print _entry_path_line
                for (_bi = 1; _bi <= _entry_buf_n; _bi++) print _entry_buf[_bi]
                print $0
                _in_entry = 0
                next
            }
            if ($0 ~ /^  - / || ($0 !~ /^    / && $0 !~ /^$/)) {
                # Entry boundary — not our entry, flush as-is
                print _entry_path_line
                for (_bi = 1; _bi <= _entry_buf_n; _bi++) print _entry_buf[_bi]
                _in_entry = 0
                # Fall through
            } else {
                _entry_buf_n++; _entry_buf[_entry_buf_n] = $0; next
            }
        }

        { print }
        END {
            if (_in_entry) {
                print _entry_path_line
                for (_bi = 1; _bi <= _entry_buf_n; _bi++) print _entry_buf[_bi]
            }
        }
    ' "$yml_file" > "$tmpf" && mv "$tmpf" "$yml_file"
}

# ── Project path resolution ──────────────────────────────────────────

# Resolve @local entries (repos + extra_mounts) in a project.yml.
# Shared implementation between install-time and session-start flows.
#
# Usage: _resolve_project_paths_impl <project_dir> <mode>
#   mode=install : non-TTY on unresolved → warn & continue; on abort → die
#                  "Installation aborted."; summarize resolved repos at end.
#   mode=start   : non-TTY on unresolved → die (cannot launch session);
#                  on abort → die "Aborted."; skip paths surface as warn
#                  (user chose to skip); no end-of-run summary.
#
# Design note: a single implementation prevents the class of drift that
# caused #B10 (status/diff divergence) — when two callsites reimplement
# the same categorization/resolution loop, they go out of sync silently.
_resolve_project_paths_impl() {
    local project_dir="$1" mode="$2"
    local project_yml="$project_dir/project.yml"

    [[ ! -f "$project_yml" ]] && return 0

    local unresolved_msg="Unresolved reference(s) on this machine — run 'cco resolve' to configure"
    local abort_msg="Aborted."
    [[ "$mode" == "install" ]] && abort_msg="Installation aborted."

    local -a resolved_repos=()

    # Resolve repos
    local repos
    repos=$(yml_get_repos "$project_yml" 2>/dev/null)
    if [[ -n "$repos" ]]; then
        while IFS=: read -r repo_path repo_name; do
            [[ -z "$repo_name" ]] && continue

            local needs_resolve=false
            if [[ "$repo_path" == "@local" || "$repo_path" == *"{{REPO_"* ]]; then
                needs_resolve=true
            else
                # _path_exists (not `-d`) so a literal file path is
                # accepted for extra_mounts; repos that resolve to a
                # non-directory will be caught by _assert_resolved_paths
                # downstream anyway.
                _path_exists "$repo_path" || needs_resolve=true
            fi

            if $needs_resolve; then
                local url
                url=$(_get_repo_url "$project_yml" "$repo_name")

                local resolved rc=0
                resolved=$(_resolve_entry "$project_dir" "repos" "$repo_name" "$url") || rc=$?

                if [[ $rc -eq 0 && -n "$resolved" ]]; then
                    _update_yml_path "$project_yml" "repos" "name" "$repo_name" "path" "$resolved"
                    resolved_repos+=("$repo_name")
                elif [[ $rc -eq 2 ]]; then
                    # Unresolved (non-TTY without data, or explicit abort)
                    if [[ ! -t 0 ]]; then
                        if [[ "$mode" == "start" ]]; then
                            die "$unresolved_msg"
                        else
                            warn "Repository '$repo_name' path does not exist — run 'cco project resolve' to configure"
                        fi
                    else
                        die "$abort_msg"
                    fi
                else
                    # Skipped — only start mode warns (session launches without it);
                    # install mode treats skip as silent (user will resolve later).
                    if [[ "$mode" == "start" ]]; then
                        warn "Repository '$repo_name' skipped — it will not be available in this session"
                    fi
                fi
            fi
        done <<< "$repos"
    else
        # NEW schema — resolve logical names into the STATE index.
        local _ln name url rest path needs_resolve
        while IFS= read -r _ln; do
            [[ -z "$_ln" ]] && continue
            name="${_ln%%$'\t'*}"; rest="${_ln#*$'\t'}"; url="${rest%%$'\t'*}"
            [[ -z "$name" ]] && continue
            path=$(_index_get_path "$name")
            needs_resolve=false
            if [[ -z "$path" ]] || ! _path_exists "$path"; then
                needs_resolve=true
            fi
            if $needs_resolve; then
                local resolved rc=0
                resolved=$(_resolve_entry_index "$project_dir" "repos" "$name" "$url") || rc=$?
                if [[ $rc -eq 0 && -n "$resolved" ]]; then
                    resolved_repos+=("$name")
                elif [[ $rc -eq 2 ]]; then
                    # rc==2: non-TTY (no prompt possible) OR a TTY user chose [q]uit.
                    if [[ ! -t 0 ]]; then
                        # non-TTY: warn + proceed without it (P14 conscious-skip
                        # equivalent — start excludes it + ⚠-badges it, never silent;
                        # design §4.4). install likewise warns and defers.
                        warn "Repository '$name' unresolved on this machine — run 'cco resolve' to configure"
                    else
                        die "$abort_msg"   # TTY: user chose [q]uit
                    fi
                else
                    # rc==1: user consciously [s]kipped at the F49 prompt.
                    if [[ "$mode" == "start" ]]; then
                        warn "Repository '$name' skipped — it will not be available in this session"
                    fi
                fi
            fi
        done < <(yml_get_repo_coords "$project_yml" 2>/dev/null)
    fi

    # Resolve extra_mounts
    local mounts
    mounts=$(yml_get_extra_mounts "$project_yml" 2>/dev/null)
    if [[ -n "$mounts" ]]; then
        while IFS= read -r mount_line; do
            [[ -z "$mount_line" ]] && continue
            local source="${mount_line%%:*}"
            local rest="${mount_line#*:}"
            local target="${rest%%:*}"

            if [[ "$source" == "@local" ]]; then
                local resolved rc=0
                resolved=$(_resolve_entry "$project_dir" "extra_mounts" "$target" "") || rc=$?

                if [[ $rc -eq 0 && -n "$resolved" ]]; then
                    _update_yml_path "$project_yml" "extra_mounts" "target" "$target" "source" "$resolved"
                elif [[ $rc -eq 2 ]]; then
                    if [[ ! -t 0 ]]; then
                        if [[ "$mode" == "start" ]]; then
                            die "$unresolved_msg"
                        else
                            warn "Mount '$target' path does not exist — run 'cco project resolve' to configure"
                        fi
                    else
                        die "$abort_msg"
                    fi
                else
                    if [[ "$mode" == "start" ]]; then
                        warn "Mount '$target' skipped — it will not be available in this session"
                    fi
                fi
            fi
        done <<< "$mounts"
    else
        # NEW schema — resolve logical mount names into the STATE index.
        local _ln name url rest path needs_resolve
        while IFS= read -r _ln; do
            [[ -z "$_ln" ]] && continue
            name="${_ln%%$'\t'*}"; rest="${_ln#*$'\t'}"; url="${rest%%$'\t'*}"
            [[ -z "$name" ]] && continue
            path=$(_index_get_path "$name")
            needs_resolve=false
            if [[ -z "$path" ]] || ! _path_exists "$path"; then
                needs_resolve=true
            fi
            if $needs_resolve; then
                local resolved rc=0
                resolved=$(_resolve_entry_index "$project_dir" "extra_mounts" "$name" "$url") || rc=$?
                if [[ $rc -eq 0 && -n "$resolved" ]]; then
                    :
                elif [[ $rc -eq 2 ]]; then
                    if [[ ! -t 0 ]]; then
                        # non-TTY: warn + proceed without it (P14; design §4.4).
                        warn "Mount '$name' unresolved on this machine — run 'cco resolve' to configure"
                    else
                        die "$abort_msg"   # TTY: user chose [q]uit
                    fi
                else
                    if [[ "$mode" == "start" ]]; then
                        warn "Mount '$name' skipped — it will not be available in this session"
                    fi
                fi
            fi
        done < <(yml_get_mount_coords "$project_yml" 2>/dev/null)
    fi

    if [[ "$mode" == "install" && ${#resolved_repos[@]} -gt 0 ]]; then
        ok "Resolved paths: ${resolved_repos[*]}"
    fi
}

# Resolve referenced paths before session start (cco start flow). TTY: the F49
# prompt offers clone/path/skip per unresolved member. Non-TTY or [s]kip: warn +
# proceed without it (conscious-skip, P14 — never a silent empty mount; design
# §4.4). The residue is counted + ⚠-badged by _start_resolve_paths.
# Usage: _resolve_start_paths <project_dir>
_resolve_start_paths() {
    _resolve_project_paths_impl "$1" "start"
}

# ── Schema bridge (transitional) ─────────────────────────────────────
#
# Commit A introduces the decentralized schema (logical names + the STATE
# index) without deleting the legacy `@local` + `.cco/local-paths.yml`
# machinery, which the vault/publish code and their tests still exercise
# (kept transitional, removed in P3/P4). The resolution + mount-generation
# consumers therefore read BOTH shapes, detected per-section:
#   - LEGACY: project.yml carries `repos:\n  - path:` / `extra_mounts:\n  -
#     source:` → yml_get_repos / yml_get_extra_mounts return non-empty.
#   - NEW: logical names only → those legacy parsers return empty; coordinates
#     come from yml_get_repo_coords / yml_get_mount_coords and the absolute
#     path from the STATE index (lib/index.sh).
# This whole section collapses to index-only once the legacy paths are deleted
# with the vault (P3) and the sharing rewrite (P4).

# Emit the RESOLVED repo set as "<name>\t<abs_path>" lines (one per repo),
# schema-agnostic. Callers are post-resolution consumers (mount-gen, proxy,
# workspace, summaries) — by contract _resolve_*_paths + _assert_resolved_paths
# have already run, so legacy paths are real (no @local) and index names are
# bound. LEGACY: literal project.yml path, expanded. NEW: index lookup by name.
_effective_repo_mounts() {
    local project_yml="$1"
    local legacy
    legacy=$(yml_get_repos "$project_yml" 2>/dev/null)
    if [[ -n "$legacy" ]]; then
        local rp rn
        while IFS=: read -r rp rn; do
            [[ -z "$rp" ]] && continue
            printf '%s\t%s\n' "$rn" "$(expand_path "$rp")"
        done <<< "$legacy"
    else
        # Peel fields by tab (IFS=$'\t' read collapses empty middle fields).
        local _ln name _p
        while IFS= read -r _ln; do
            [[ -z "$_ln" ]] && continue
            name="${_ln%%$'\t'*}"
            [[ -z "$name" ]] && continue
            # Conscious-skip (design §4.4 / P14): a member still unresolved after
            # the F49 prompt has no index path — exclude it (never emit a silent
            # empty mount, #B17); _start_resolve_paths already warned + ⚠-badged it.
            _p=$(_index_get_path "$name")
            [[ -z "$_p" ]] && continue
            printf '%s\t%s\n' "$name" "$_p"
        done < <(yml_get_repo_coords "$project_yml" 2>/dev/null)
    fi
}

# Companion bridge for extra mounts. Emit "<abs_source>\t<target>\t<ro>" per
# mount (ro = "true"|"false"). LEGACY: source/target/ro from project.yml
# (source already resolved + expanded). NEW: source from the index by name,
# target defaults to /workspace/<name>, readonly defaults to true.
_effective_extra_mounts() {
    local project_yml="$1"
    local legacy
    legacy=$(yml_get_extra_mounts "$project_yml" 2>/dev/null)
    if [[ -n "$legacy" ]]; then
        local line src rest tgt ro
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            src="${line%%:*}"
            rest="${line#*:}"
            if [[ "$rest" == *:ro ]]; then
                tgt="${rest%:ro}"; ro="true"
            else
                tgt="$rest"; ro="false"
            fi
            printf '%s\t%s\t%s\n' "$(expand_path "$src")" "$tgt" "$ro"
        done <<< "$legacy"
    else
        # Peel fields by tab (IFS=$'\t' read collapses empty middle fields, so
        # a name-only mount "name\t\t\ttarget\tro" would mis-assign target/ro).
        local _ln name target ro_raw ro rest
        while IFS= read -r _ln; do
            [[ -z "$_ln" ]] && continue
            name="${_ln%%$'\t'*}"; rest="${_ln#*$'\t'}"   # rest = url\tref\ttarget\tro
            rest="${rest#*$'\t'}"                          # drop url
            rest="${rest#*$'\t'}"                          # drop ref
            target="${rest%%$'\t'*}"
            ro_raw="${rest#*$'\t'}"
            [[ -z "$name" ]] && continue
            # Conscious-skip: exclude an unresolved mount (no index path) rather
            # than emit a silent empty mount (#B17; design §4.4 / P14).
            local _ms; _ms=$(_index_get_path "$name")
            [[ -z "$_ms" ]] && continue
            [[ -z "$target" ]] && target="/workspace/$name"
            ro=$(_parse_bool "$ro_raw" "true")
            printf '%s\t%s\t%s\n' "$_ms" "$target" "$ro"
        done < <(yml_get_mount_coords "$project_yml" 2>/dev/null)
    fi
}

# NEW-schema single-entry resolution (index-backed counterpart of
# _resolve_entry): look up <name> in the STATE index; if unresolved or its path
# is gone, prompt (reusing _prompt_for_path) and store the result in the index.
# No local-paths.yml, no project.yml write (AD3 — project.yml has no path).
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
# project.yml. Single read path used by `cco project resolve --show`
# (display) and `_assert_resolved_paths` (start guard). Guarantees that
# display and runtime agree — a `✓ exists` in resolve --show cannot
# coexist with an "Unresolved" die in cco start, because both derive
# from this one function.
#
# Output format (tab-separated lines on stdout):
#   <kind>\t<key>\t<effective_path>\t<status>
# where:
#   kind   = "repos" | "mounts"
#   key    = repo name (repos) or container target (mounts)
#   effective_path =
#       - the literal project.yml value if it is not @local / {{REPO_*}};
#       - otherwise the value from .cco/local-paths.yml if present;
#       - otherwise "@local" (unresolved).
#   status = "exists" (filesystem reached via _path_exists), "missing"
#            (value present but path absent), or "unresolved" (@local
#            without a local-paths.yml mapping).
#
# Usage: _project_effective_paths <project_dir>
_project_effective_paths() {
    local project_dir="$1"
    local project_yml="$project_dir/project.yml"
    local local_paths="$project_dir/.cco/local-paths.yml"

    [[ ! -f "$project_yml" ]] && return 0

    # Repos — sourced from "path:name" lines
    local repos
    repos=$(yml_get_repos "$project_yml" 2>/dev/null)
    if [[ -n "$repos" ]]; then
        local repo_path repo_name effective status
        while IFS=: read -r repo_path repo_name; do
            [[ -z "$repo_name" ]] && continue
            if [[ "$repo_path" == "@local" || "$repo_path" == *"{{REPO_"* ]]; then
                effective=$(_local_paths_get "$local_paths" "repos" "$repo_name")
                if [[ -z "$effective" ]]; then
                    printf 'repos\t%s\t@local\tunresolved\n' "$repo_name"
                    continue
                fi
            else
                effective="$repo_path"
            fi
            if _path_exists "$effective"; then
                status="exists"
            else
                status="missing"
            fi
            printf 'repos\t%s\t%s\t%s\n' "$repo_name" "$effective" "$status"
        done <<< "$repos"
    else
        # NEW schema — logical names; abs path from the STATE index.
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
    fi

    # Mounts — sourced from "source:target:readonly" lines; keyed by target
    local mounts
    mounts=$(yml_get_extra_mounts "$project_yml" 2>/dev/null)
    if [[ -n "$mounts" ]]; then
        local mount_line source rest target effective status
        while IFS= read -r mount_line; do
            [[ -z "$mount_line" ]] && continue
            source="${mount_line%%:*}"
            rest="${mount_line#*:}"
            target="${rest%%:*}"
            [[ -z "$target" ]] && continue
            if [[ "$source" == "@local" ]]; then
                effective=$(_local_paths_get "$local_paths" "extra_mounts" "$target")
                if [[ -z "$effective" ]]; then
                    printf 'mounts\t%s\t@local\tunresolved\n' "$target"
                    continue
                fi
            else
                effective="$source"
            fi
            if _path_exists "$effective"; then
                status="exists"
            else
                status="missing"
            fi
            printf 'mounts\t%s\t%s\t%s\n' "$target" "$effective" "$status"
        done <<< "$mounts"
    else
        # NEW schema — logical names; abs source from the STATE index; key = name.
        local _ln name effective status
        while IFS= read -r _ln; do
            [[ -z "$_ln" ]] && continue
            name="${_ln%%$'\t'*}"
            [[ -z "$name" ]] && continue
            effective=$(_index_get_path "$name")
            if [[ -z "$effective" ]]; then
                printf 'mounts\t%s\t\tunresolved\n' "$name"
                continue
            fi
            if _path_exists "$effective"; then
                status="exists"
            else
                status="missing"
            fi
            printf 'mounts\t%s\t%s\t%s\n' "$name" "$effective" "$status"
        done < <(yml_get_mount_coords "$project_yml" 2>/dev/null)
    fi
}

# Guard: assert every entry in project.yml is resolved AND its path
# exists on disk. Dies with a clear, actionable message otherwise.
# Called by `cco start` immediately after _resolve_start_paths, as the
# last line of defense against silently generating a docker-compose
# with unresolved @local markers (Docker would then create empty
# bind-mount directories — finding #B17).
#
# Usage: _assert_resolved_paths <project_dir> <project_name>
_assert_resolved_paths() {
    local project_dir="$1" project_name="$2"
    local -a problems=()

    local kind key effective status
    while IFS=$'\t' read -r kind key effective status; do
        [[ -z "$kind" ]] && continue
        case "$status" in
            exists) ;;
            unresolved)
                problems+=("$kind/$key: unresolved @local marker (no entry in .cco/local-paths.yml)")
                ;;
            missing)
                problems+=("$kind/$key: path '$effective' does not exist on this machine")
                ;;
        esac
    done < <(_project_effective_paths "$project_dir")

    if [[ ${#problems[@]} -gt 0 ]]; then
        error "Cannot start '$project_name' — unresolved paths:"
        local p
        for p in "${problems[@]}"; do
            error "  - $p"
        done
        die "Fix with 'cco project resolve $project_name' (or edit project.yml / .cco/local-paths.yml)."
    fi
}
