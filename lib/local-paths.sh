#!/usr/bin/env bash
# lib/local-paths.sh — Unified local path resolution
#
# Separates machine-specific paths from portable project config.
# project.yml in vault/published copies uses @local markers;
# real paths are stored in .cco/local-paths.yml (gitignored, per-PC).
#
# Provides: _local_paths_get(), _local_paths_set(), _prompt_for_path(),
#   _sanitize_project_paths(), _resolve_project_paths(), _get_repo_url(),
#   _resolve_entry(), _write_local_paths(), _extract_local_paths(),
#   _restore_local_paths(), _resolve_all_local_paths(), _update_yml_path(),
#   _resolve_installed_paths()
# Dependencies: colors.sh, utils.sh, yaml.sh

# ── local-paths.yml read/write helpers ───────────────────────────────

# Dump all key=value pairs of a section from local-paths.yml.
# Usage: _local_paths_get_section <file> <section>
# Output: newline-separated "key=value" lines (stdout), empty if no section.
# Note: sole entry point for reading sections; _local_paths_get and
# _resolve_project_paths both go through this helper to avoid drift.
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

    if [[ "$has_key" == "yes" ]]; then
        # Update existing entry
        local tmpf
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
        local tmpf2
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
    echo "  (s) Skip this ${label,,}" >&2
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

# ── Sanitize: replace real paths with @local ─────────────────────────

# Sanitize project.yml: replace real paths with @local markers,
# inject url: fields from git remotes (best-effort).
# Handles both repos: (path:) and extra_mounts: (source:).
# Usage: _sanitize_project_paths <project_yml>
_sanitize_project_paths() {
    local yml_file="$1"
    local tmpf
    tmpf=$(mktemp "${yml_file}.XXXXXX")

    # Capture original repo info for URL extraction
    local orig_repos
    orig_repos=$(yml_get_repos "$yml_file" 2>/dev/null)

    # Build url map: name=url (RS-separated, \036)
    # Uses ASCII Record Separator instead of newline because macOS BWK awk
    # does not support literal newlines in -v variable assignments.
    local url_map=""
    if [[ -n "$orig_repos" ]]; then
        while IFS=: read -r repo_path repo_name; do
            [[ -z "$repo_name" ]] && continue
            # Skip entries already @local (no path to extract URL from)
            [[ "$repo_path" == "@local" ]] && continue
            local expanded
            expanded=$(expand_path "$repo_path" 2>/dev/null) || continue
            if [[ -d "$expanded/.git" ]]; then
                local remote_url
                remote_url=$(git -C "$expanded" remote get-url origin 2>/dev/null) || true
                if [[ -n "$remote_url" ]]; then
                    url_map+="${repo_name}=${remote_url}"$'\036'
                fi
            fi
        done <<< "$orig_repos"
    fi

    # Replace paths with @local and inject url: fields
    # Uses a pending_url flag instead of nested getline to avoid
    # consuming the next entry's "- path:" line (see review #1).
    awk -v url_map="$url_map" '
        BEGIN {
            n = split(url_map, entries, "\036")
            for (i = 1; i <= n; i++) {
                if (entries[i] == "") continue
                eq = index(entries[i], "=")
                if (eq > 0) {
                    k = substr(entries[i], 1, eq - 1)
                    urls[k] = substr(entries[i], eq + 1)
                }
            }
            pending_url = ""
        }

        # repos: section — replace path: and inject url:
        /^repos:/ { in_repos=1; in_mounts=0; print; next }
        in_repos && /^[^ #]/ {
            # Flush pending entry if section ends mid-collection
            if (_in_entry) {
                print _entry_path_line
                for (_bi = 1; _bi <= _entry_buf_n; _bi++) print _entry_buf[_bi]
                _in_entry = 0
            }
            if (pending_url != "") {
                print "    url: " pending_url
                pending_url = ""
            }
            in_repos=0
        }

        # If we have a pending url to inject, check if next line is url:
        in_repos && pending_url != "" {
            if ($0 ~ /^    url:/) {
                # Existing url: line — replace with our value
                print "    url: " pending_url
                pending_url = ""
                next
            } else {
                # Not a url: line — inject url before this line
                print "    url: " pending_url
                pending_url = ""
                # Fall through to process this line normally
            }
        }

        # Entry buffering: handles any field order (path/name/url)
        in_repos && /^  - path:/ && !_in_entry {
            _entry_path_line = $0
            _entry_path_val = $0
            sub(/^  - path: */, "", _entry_path_val)
            gsub(/[\"'"'"'[:space:]]/, "", _entry_path_val)
            _entry_buf_n = 0
            delete _entry_buf
            _in_entry = 1
            next
        }

        in_repos && _in_entry {
            if ($0 ~ /^    name:/) {
                _name_val = $0
                sub(/^    name: */, "", _name_val)
                gsub(/[\"'"'"'[:space:]]/, "", _name_val)

                if (_entry_path_val == "@local") {
                    print _entry_path_line
                    for (_bi = 1; _bi <= _entry_buf_n; _bi++) print _entry_buf[_bi]
                } else {
                    print "  - path: \"@local\""
                    # Skip buffered url: lines (will be re-injected via pending_url)
                    for (_bi = 1; _bi <= _entry_buf_n; _bi++) {
                        if (_entry_buf[_bi] !~ /^    url:/) print _entry_buf[_bi]
                    }
                    if (_name_val in urls) {
                        pending_url = urls[_name_val]
                    }
                }
                print $0
                _in_entry = 0
                next
            }
            if ($0 ~ /^  - / || ($0 !~ /^    / && $0 !~ /^$/)) {
                # Entry/section boundary without name: — flush as-is
                print _entry_path_line
                for (_bi = 1; _bi <= _entry_buf_n; _bi++) print _entry_buf[_bi]
                _in_entry = 0
                # Fall through to normal processing
            } else {
                _entry_buf_n++
                _entry_buf[_entry_buf_n] = $0
                next
            }
        }

        # extra_mounts: section — replace source:
        /^extra_mounts:/ { in_mounts=1; in_repos=0; pending_url=""; print; next }
        in_mounts && /^[^ #]/ { in_mounts=0 }
        in_mounts && /^  - source:/ {
            # Check if already @local
            p = $0
            sub(/^  - source: */, "", p)
            gsub(/[\"'"'"'[:space:]]/, "", p)
            if (p == "@local") {
                print $0
            } else {
                print "  - source: \"@local\""
            }
            next
        }

        { print }
        END {
            # Flush pending entry if file ends mid-collection
            if (_in_entry) {
                print _entry_path_line
                for (_bi = 1; _bi <= _entry_buf_n; _bi++) print _entry_buf[_bi]
            }
            if (pending_url != "") print "    url: " pending_url
        }
    ' "$yml_file" > "$tmpf" && mv "$tmpf" "$yml_file"
}

# ── Resolve: restore @local → real paths ─────────────────────────────

# Silently resolve @local markers from .cco/local-paths.yml.
# Best-effort — entries not found in local-paths.yml are left as @local.
# Usage: _resolve_project_paths <project_dir>
_resolve_project_paths() {
    local project_dir="$1"
    local project_yml="$project_dir/project.yml"
    local local_paths="$project_dir/.cco/local-paths.yml"
    local tmpf

    [[ ! -f "$project_yml" ]] && return 0
    [[ ! -f "$local_paths" ]] && return 0

    # Check if there are any @local markers to resolve
    if ! grep -q '"@local"\|@local' "$project_yml" 2>/dev/null; then
        return 0
    fi

    # Build substitution maps from local-paths.yml using the canonical
    # section reader (_local_paths_get_section). Convert newlines to RS
    # (\036) because macOS BWK awk rejects embedded newlines in -v.
    local repo_map="" mount_map=""
    local repos_content mounts_content
    repos_content=$(_local_paths_get_section "$local_paths" "repos")
    mounts_content=$(_local_paths_get_section "$local_paths" "extra_mounts")
    [[ -n "$repos_content" ]]  && repo_map=$(printf '%s'  "$repos_content"  | tr '\n' '\036')
    [[ -n "$mounts_content" ]] && mount_map=$(printf '%s' "$mounts_content" | tr '\n' '\036')

    # Apply substitutions to project.yml
    tmpf=$(mktemp "${project_yml}.XXXXXX")
    awk -v repo_map="$repo_map" -v mount_map="$mount_map" '
        BEGIN {
            # Parse repo map (RS-separated, \036)
            n = split(repo_map, entries, "\036")
            for (i = 1; i <= n; i++) {
                if (entries[i] == "") continue
                eq = index(entries[i], "=")
                if (eq > 0) {
                    repos[substr(entries[i], 1, eq - 1)] = substr(entries[i], eq + 1)
                }
            }
            # Parse mount map (RS-separated, \036)
            n = split(mount_map, entries, "\036")
            for (i = 1; i <= n; i++) {
                if (entries[i] == "") continue
                eq = index(entries[i], "=")
                if (eq > 0) {
                    mounts[substr(entries[i], 1, eq - 1)] = substr(entries[i], eq + 1)
                }
            }
        }

        # repos: section — resolve @local path using name as key
        /^repos:/ { in_repos=1; in_mounts=0; print; next }
        in_repos && /^[^ #]/ {
            if (_in_entry) {
                print _entry_first_line
                for (_bi = 1; _bi <= _entry_buf_n; _bi++) print _entry_buf[_bi]
                _in_entry = 0
            }
            in_repos=0
        }

        in_repos && /^  - path:/ && !_in_entry {
            _p = $0; sub(/^  - path: */, "", _p); gsub(/[\"'"'"'[:space:]]/, "", _p)
            if (_p == "@local") {
                _entry_first_line = $0
                _entry_buf_n = 0
                delete _entry_buf
                _in_entry = 1
                _entry_section = "repos"
            } else {
                print $0
            }
            next
        }

        in_repos && _in_entry {
            if ($0 ~ /^    name:/) {
                _nm = $0; sub(/^    name: */, "", _nm); gsub(/[\"'"'"'[:space:]]/, "", _nm)
                if (_nm in repos) {
                    print "  - path: \"" repos[_nm] "\""
                } else {
                    print _entry_first_line
                }
                for (_bi = 1; _bi <= _entry_buf_n; _bi++) print _entry_buf[_bi]
                print $0
                _in_entry = 0
                next
            }
            if ($0 ~ /^  - / || ($0 !~ /^    / && $0 !~ /^$/)) {
                print _entry_first_line
                for (_bi = 1; _bi <= _entry_buf_n; _bi++) print _entry_buf[_bi]
                _in_entry = 0
            } else {
                _entry_buf_n++; _entry_buf[_entry_buf_n] = $0; next
            }
        }

        # extra_mounts: section — resolve @local source using target as key
        /^extra_mounts:/ { in_mounts=1; in_repos=0; print; next }
        in_mounts && /^[^ #]/ {
            if (_in_entry) {
                print _entry_first_line
                for (_bi = 1; _bi <= _entry_buf_n; _bi++) print _entry_buf[_bi]
                _in_entry = 0
            }
            in_mounts=0
        }

        in_mounts && /^  - source:/ && !_in_entry {
            _p = $0; sub(/^  - source: */, "", _p); gsub(/[\"'"'"'[:space:]]/, "", _p)
            if (_p == "@local") {
                _entry_first_line = $0
                _entry_buf_n = 0
                delete _entry_buf
                _in_entry = 1
                _entry_section = "mounts"
            } else {
                print $0
            }
            next
        }

        in_mounts && _in_entry {
            if ($0 ~ /^    target:/) {
                _tgt = $0; sub(/^    target: */, "", _tgt); gsub(/[\"'"'"'[:space:]]/, "", _tgt)
                if (_tgt in mounts) {
                    print "  - source: \"" mounts[_tgt] "\""
                } else {
                    print _entry_first_line
                }
                for (_bi = 1; _bi <= _entry_buf_n; _bi++) print _entry_buf[_bi]
                print $0
                _in_entry = 0
                next
            }
            if ($0 ~ /^  - / || ($0 !~ /^    / && $0 !~ /^$/)) {
                print _entry_first_line
                for (_bi = 1; _bi <= _entry_buf_n; _bi++) print _entry_buf[_bi]
                _in_entry = 0
            } else {
                _entry_buf_n++; _entry_buf[_entry_buf_n] = $0; next
            }
        }

        { print }
        END {
            if (_in_entry) {
                print _entry_first_line
                for (_bi = 1; _bi <= _entry_buf_n; _bi++) print _entry_buf[_bi]
            }
        }
    ' "$project_yml" > "$tmpf" && mv "$tmpf" "$project_yml"
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

# ── Vault save: extract and restore ──────────────────────────────────

# Write repo and mount paths from project.yml to .cco/local-paths.yml.
# Called by _extract_local_paths before sanitizing.
# Usage: _write_local_paths <project_yml> <local_paths_file>
_write_local_paths() {
    local project_yml="$1" local_paths="$2"

    # Extract repos
    local repos
    repos=$(yml_get_repos "$project_yml" 2>/dev/null)
    if [[ -n "$repos" ]]; then
        while IFS=: read -r repo_path repo_name; do
            [[ -z "$repo_name" || -z "$repo_path" ]] && continue
            [[ "$repo_path" == "@local" ]] && continue
            # Check for {{REPO_*}} legacy markers — skip those too
            [[ "$repo_path" == *"{{REPO_"* ]] && continue
            _local_paths_set "$local_paths" "repos" "$repo_name" "$repo_path"
        done <<< "$repos"
    fi

    # Extract extra_mounts
    local mounts
    mounts=$(yml_get_extra_mounts "$project_yml" 2>/dev/null)
    if [[ -n "$mounts" ]]; then
        while IFS= read -r mount_line; do
            [[ -z "$mount_line" ]] && continue
            local source="${mount_line%%:*}"
            local rest="${mount_line#*:}"
            local target="${rest%%:*}"

            [[ -z "$source" || -z "$target" || "$source" == "@local" ]] && continue
            _local_paths_set "$local_paths" "extra_mounts" "$target" "$source"
        done <<< "$mounts"
    fi
}

# Pre-commit: extract local paths from all projects and sanitize project.yml.
# Usage: _extract_local_paths <vault_dir>
_extract_local_paths() {
    local vault_dir="$1"
    [[ ! -d "$vault_dir/projects" ]] && return 0

    local project_dir
    for project_dir in "$vault_dir"/projects/*/; do
        [[ ! -d "$project_dir" ]] && continue
        local project_yml="$project_dir/project.yml"
        local local_paths="$project_dir/.cco/local-paths.yml"
        local backup="$project_dir/.cco/project.yml.pre-save"

        [[ ! -f "$project_yml" ]] && continue

        # Recover from interrupted save
        if [[ -f "$backup" ]]; then
            warn "Restoring project.yml from interrupted save: $(basename "$project_dir")"
            cp "$backup" "$project_yml"
            rm -f "$backup"
        fi

        # Check if any paths need sanitizing (skip if all already @local)
        local has_real_paths=false
        local repos
        repos=$(yml_get_repos "$project_yml" 2>/dev/null)
        if [[ -n "$repos" ]]; then
            while IFS=: read -r repo_path _; do
                [[ -z "$repo_path" ]] && continue
                if [[ "$repo_path" != "@local" && "$repo_path" != *"{{REPO_"* ]]; then
                    has_real_paths=true
                    break
                fi
            done <<< "$repos"
        fi

        if ! $has_real_paths; then
            # Check extra_mounts too
            local mounts
            mounts=$(yml_get_extra_mounts "$project_yml" 2>/dev/null)
            if [[ -n "$mounts" ]]; then
                while IFS= read -r mount_line; do
                    [[ -z "$mount_line" ]] && continue
                    local source="${mount_line%%:*}"
                    if [[ "$source" != "@local" ]]; then
                        has_real_paths=true
                        break
                    fi
                done <<< "$mounts"
            fi
        fi

        if $has_real_paths; then
            # Backup before modification
            mkdir -p "$project_dir/.cco"
            cp "$project_yml" "$backup"

            # Write current paths to local-paths.yml
            # If this fails, restore from backup to avoid path loss (review #5)
            if ! _write_local_paths "$project_yml" "$local_paths"; then
                warn "Failed to save local paths for $(basename "$project_dir"), restoring backup"
                cp "$backup" "$project_yml"
                rm -f "$backup"
                continue
            fi

            # Sanitize project.yml (replace paths with @local)
            _sanitize_project_paths "$project_yml"
        fi
    done
}

# Post-commit: restore project.yml from backup.
# Usage: _restore_local_paths <vault_dir>
_restore_local_paths() {
    local vault_dir="$1"
    [[ ! -d "$vault_dir/projects" ]] && return 0

    local project_dir
    for project_dir in "$vault_dir"/projects/*/; do
        [[ ! -d "$project_dir" ]] && continue
        local backup="$project_dir/.cco/project.yml.pre-save"
        [[ ! -f "$backup" ]] && continue
        cp "$backup" "$project_dir/project.yml"
        rm -f "$backup"
    done
}

# ── Vault pull/switch: resolve all projects ──────────────────────────

# Silently resolve @local markers for all projects from local-paths.yml.
# Usage: _resolve_all_local_paths <vault_dir>
_resolve_all_local_paths() {
    local vault_dir="$1"
    [[ ! -d "$vault_dir/projects" ]] && return 0

    local project_dir
    for project_dir in "$vault_dir"/projects/*/; do
        [[ ! -d "$project_dir" ]] && continue
        _resolve_project_paths "$project_dir"
    done
}

# ── Start: resolve paths with interactive prompt ─────────────────────

# Update a single path: value in project.yml using AWK.
# Usage: _update_yml_path <project_yml> <section> <key_field> <key_value> <path_field> <new_path>
# section: "repos" or "extra_mounts"
# key_field/key_value: e.g. "name"/"backend-api" or "target"/"/workspace/docs"
# path_field: "path" or "source"
_update_yml_path() {
    local yml_file="$1" section="$2" key_field="$3" key_value="$4" path_field="$5" new_path="$6"
    local tmpf
    tmpf=$(mktemp "${yml_file}.XXXXXX")

    # Pass new_path via env to avoid AWK -v backslash expansion (W3)
    CCO_NEW_PATH="$new_path" awk -v section="$section" -v key_field="$key_field" \
        -v key_value="$key_value" -v path_field="$path_field" '
        BEGIN {
            section_re = "^" section ":$"
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

    local unresolved_msg="Unresolved @local paths — run 'cco project resolve' to configure"
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
    fi

    if [[ "$mode" == "install" && ${#resolved_repos[@]} -gt 0 ]]; then
        ok "Resolved paths: ${resolved_repos[*]}"
    fi
}

# Resolve @local entries in a newly installed project.
# Prompts for ALL unresolved immediately; warn on non-TTY unresolved.
# Usage: _resolve_installed_paths <project_dir>
_resolve_installed_paths() {
    _resolve_project_paths_impl "$1" "install"
}

# Resolve @local entries before session start (cco start flow).
# Non-TTY unresolved is fatal: the session cannot launch without paths.
# Usage: _resolve_start_paths <project_dir>
_resolve_start_paths() {
    _resolve_project_paths_impl "$1" "start"
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
