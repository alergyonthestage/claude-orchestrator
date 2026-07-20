#!/usr/bin/env bash
# lib/index.sh — Machine-local path index (STATE)
#
# The single source of machine-specific truth: logical name → absolute path
# (repos AND extra mounts) plus project → member repo names. Lives in STATE
# (<state>/cco/index), never committed, never synced, scan-rebuildable. It
# SUBSUMES the old @local markers and the per-repo .cco/local-paths.yml
# (ADR-0016 D4); project.yml carries only machine-agnostic names + url
# coordinates, the index materializes them on this machine (ADR-0014 D2).
#
# On-disk format (internal; regenerable, not a published contract):
#   version: 2
#   projects:
#     <project>: "<repo> <repo> ..."     # membership (globally-unique project keys)
#   project_paths:                        # per-project name → abs-path (ADR-0051)
#     <project>:
#       <name>: "<abs-path>"
#   llms: { <name>: "<abs-path>" }        # reserved global section (currently unused)
#   unscoped: { <name>: "<abs-path>" }    # orphan `cco path set` names (no project)
#
# Per-project name scoping (ADR-0051): the identity of a repo/extra_mount is its
# PATH; the name is only a per-project LABEL. Uniqueness (AD5′ — refuse a name
# already bound within the SAME project to a different path) is enforced by the
# callers via _index_path_conflicts(); cross-project same-name is legal. Writes
# are atomic (mktemp + mv), single-writer, no file lock: writes are user-serial;
# a rare race is last-writer-wins and self-heals via `cco resolve --scan`.
#
# Transitional migration (ADR-0051 D6): a still-version-1 index (flat global
# `paths:`) is READ as global-flat (the resolver tolerates both schemas); the
# first host-side WRITE upgrades it in place (_index_migrate_if_needed), lossless
# (each global name re-homes under every project listing it as a member; orphans
# → unscoped:). No `migrations/` script, no `cco update` — the index is
# machine-local, scan-rebuildable STATE.
#
# Provides: _index_file(), _index_get_path(), _index_get_path_any(),
#   _index_set_path(), _index_remove_path(), _index_set_unscoped(),
#   _index_path_conflicts(), _index_name_for_path(), _index_list_paths(),
#   _index_paths_get_bindings(), _index_bindings_for_name(),
#   _index_pp_* (per-project block primitives, ADR-0051), _index_get_project_repos(),
#   _index_set_project_repos(), _index_remove_project(), _index_list_projects(),
#   _index_rename_project(), _project_member_status(), _project_iter_members()
# (the name-based reverse lookup _index_repos_get_projects() is retired — ADR-0051
#  D5 replaces it with the path-based _index_paths_get_bindings())
# Dependencies: colors.sh, paths.sh (_cco_state_shared_dir/_cco_project_id),
#   sync-meta.sh (_sync_is_divergent) — both resolved at call time.

# Absolute path to the index file (STATE/shared; host-side guard applies via
# resolver). It lives in the shareable sub-bucket because every writer below
# replaces it atomically via a SIBLING temp file (mktemp "$f.XXXXXX" + mv), which
# needs a writable parent directory — the file itself being bind-mounted is not
# enough, and `mv` onto a bound file is EBUSY (v3 R1). Never move it back up.
_index_file() {
    printf '%s\n' "$(_cco_state_shared_dir)/index"
}

# Echo the on-disk schema version (integer). Absent/unreadable → 1 (the pre-v2
# global-flat schema, so a legacy or scaffold-less index reads as transitional).
_index_version() {
    local f; f=$(_index_file)
    [[ -f "$f" ]] || { printf '1\n'; return 0; }
    local v; v=$(awk -F': *' '/^version:/ { print $2; exit }' "$f")
    printf '%s\n' "${v:-1}"
}

# Create the v2 index scaffold if missing (all flat sections always present, so
# the section upsert/remove logic never has to create a section); otherwise
# upgrade a still-v1 index in place before any write (transitional migration).
_index_ensure_file() {
    local f; f=$(_index_file)
    if [[ ! -f "$f" ]]; then
        # Atomic create (mktemp + mv), the same convention as every other index
        # write — a direct multi-line redirect is the one non-atomic site, which
        # two concurrent first-runs could interleave.
        local tmpf; tmpf=$(mktemp "${f}.XXXXXX")
        {
            echo "# cco machine-local index — per-project logical name → absolute path + membership."
            echo "# Regenerable via 'cco resolve --scan'; never committed, never synced."
            echo "version: 2"
            echo "projects:"
            echo "project_paths:"
            echo "llms:"
            echo "unscoped:"
        } > "$tmpf" && mv "$tmpf" "$f"
        return 0
    fi
    _index_migrate_if_needed
}

# Upgrade a still-v1 (global-flat) index to v2 (per-project scoped) in place.
# Idempotent: a no-op once version >= 2. Runs on the first host-side WRITE after
# the new code is live (every write path funnels through _index_ensure_file).
_index_migrate_if_needed() {
    [[ "$(_index_version)" -ge 2 ]] && return 0
    _index_migrate_v1_to_v2
}

# The lossless v1 → v2 rewrite (ADR-0051 D6). Names are globally unique in v1, so
# each global `paths: <name>` re-homes under EVERY project that lists <name> as a
# member (a shared repo becomes an independent per-project binding with the same
# path); a flat name in no project's membership → the unscoped: bucket (kept).
_index_migrate_v1_to_v2() {
    local f; f=$(_index_file)
    [[ -f "$f" ]] || return 0
    local paths_dump projects_dump
    paths_dump=$(_index_section_dump paths)        # name=path lines (v1 flat)
    projects_dump=$(_index_section_dump projects)  # project=members lines

    local tmpf; tmpf=$(mktemp "${f}.XXXXXX")
    {
        echo "# cco machine-local index — per-project logical name → absolute path + membership."
        echo "# Regenerable via 'cco resolve --scan'; never committed, never synced."
        echo "version: 2"
        echo "projects:"
        local proj mem
        while IFS='=' read -r proj mem; do
            [[ -z "$proj" ]] && continue
            printf '  %s: "%s"\n' "$proj" "$mem"
        done <<< "$projects_dump"
        echo "project_paths:"
        local consumed=" " m mp hdr
        while IFS='=' read -r proj mem; do
            [[ -z "$proj" ]] && continue
            hdr=false
            for m in $mem; do
                mp=$(printf '%s\n' "$paths_dump" | grep -m1 -E "^${m}=" 2>/dev/null) || mp=""
                mp="${mp#*=}"
                [[ -z "$mp" ]] && continue
                $hdr || { printf '  %s:\n' "$proj"; hdr=true; }
                printf '    %s: "%s"\n' "$m" "$mp"
                consumed="${consumed}${m} "
            done
        done <<< "$projects_dump"
        echo "llms:"
        echo "unscoped:"
        local name path
        while IFS='=' read -r name path; do
            [[ -z "$name" ]] && continue
            case "$consumed" in *" $name "*) continue ;; esac
            printf '  %s: "%s"\n' "$name" "$path"
        done <<< "$paths_dump"
    } > "$tmpf" && mv "$tmpf" "$f"
}

# ── Generic section accessors (paths: and projects: share the shape) ──

# Echo the value for <key> in <section>, or empty if absent.
# Usage: _index_section_get <section> <key>
_index_section_get() {
    local section="$1" key="$2" f
    f=$(_index_file)
    [[ -f "$f" ]] || return 0
    awk -v section="$section" -v key="$key" '
        $0 == section":" { in_sec=1; next }
        in_sec && /^[^ #]/ { exit }
        in_sec && /^  / {
            line = $0; sub(/^  /, "", line)
            colon = index(line, ":")
            if (colon > 0) {
                k = substr(line, 1, colon - 1)
                v = substr(line, colon + 1)
                sub(/^ +/, "", v)
                sub(/^"/, "", v); sub(/"$/, "", v)   # strip only the quoting delimiters, not path chars (L7)
                if (k == key) { print v; exit }
            }
        }
    ' "$f"
}

# Upsert <key>: "<value>" into <section> (atomic). Value is stored quoted.
# Usage: _index_section_set <section> <key> <value>
_index_section_set() {
    local section="$1" key="$2" value="$3" f
    _index_ensure_file
    f=$(_index_file)

    local tmpf=""
    # shellcheck disable=SC2064
    trap 'rm -f ${tmpf:+"$tmpf"}' RETURN
    tmpf=$(mktemp "${f}.XXXXXX")

    # CCO_IDX_VAL passes the value via env to avoid AWK -v backslash expansion.
    CCO_IDX_VAL="$value" awk -v section="$section" -v key="$key" '
        BEGIN { val = ENVIRON["CCO_IDX_VAL"]; done = 0 }
        $0 == section":" { print; in_sec = 1; next }
        in_sec && /^[^ #]/ {
            if (!done) { print "  " key ": \"" val "\""; done = 1 }
            in_sec = 0
        }
        in_sec && /^  / {
            line = $0; sub(/^  /, "", line)
            colon = index(line, ":")
            if (colon > 0) {
                k = substr(line, 1, colon - 1)
                if (k == key) { print "  " key ": \"" val "\""; done = 1; next }
            }
            print; next
        }
        { print }
        END { if (in_sec && !done) print "  " key ": \"" val "\"" }
    ' "$f" > "$tmpf" && mv "$tmpf" "$f"
}

# Remove <key> from <section> (atomic; no-op if absent).
# Usage: _index_section_remove <section> <key>
_index_section_remove() {
    local section="$1" key="$2" f
    f=$(_index_file)
    [[ -f "$f" ]] || return 0

    local tmpf=""
    # shellcheck disable=SC2064
    trap 'rm -f ${tmpf:+"$tmpf"}' RETURN
    tmpf=$(mktemp "${f}.XXXXXX")

    awk -v section="$section" -v key="$key" '
        $0 == section":" { print; in_sec = 1; next }
        in_sec && /^[^ #]/ { in_sec = 0 }
        in_sec && /^  / {
            line = $0; sub(/^  /, "", line)
            colon = index(line, ":")
            if (colon > 0) {
                k = substr(line, 1, colon - 1)
                if (k == key) next
            }
        }
        { print }
    ' "$f" > "$tmpf" && mv "$tmpf" "$f"
}

# Dump all "key=value" lines of <section> (for list/scan).
# Usage: _index_section_dump <section>
_index_section_dump() {
    local section="$1" f
    f=$(_index_file)
    [[ -f "$f" ]] || return 0
    awk -v section="$section" '
        $0 == section":" { in_sec = 1; next }
        in_sec && /^[^ #]/ { exit }
        in_sec && /^  / {
            line = $0; sub(/^  /, "", line)
            colon = index(line, ":")
            if (colon > 0) {
                k = substr(line, 1, colon - 1)
                v = substr(line, colon + 1)
                sub(/^ +/, "", v)
                sub(/^"/, "", v); sub(/"$/, "", v)   # strip only the quoting delimiters, not path chars (L7)
                if (k != "" && v != "") print k "=" v
            }
        }
    ' "$f"
}

# ── Nested project_paths accessors (ADR-0051: per-project name scoping) ──
#
# The v2 index scopes repo/extra_mount names to their project. The identity of
# such a resource is its PATH; the name is only a per-project LABEL for it. The
# `project_paths:` section is nested two levels — an outer project key (2-space
# indent, no value) and inner name → path entries (4-space indent):
#
#   project_paths:
#     app-a:
#       backend: "/abs/backend"
#       web: "/abs/web"
#     app-b:
#       backend: "/abs/backend"   # SAME name, DIFFERENT project → homonym OK
#
# Invariant AD5′: within one project, one name → one path; the same name may bind
# different paths across projects; the same path may carry different names across
# projects. All uniqueness enforcement flows through _index_pp_conflicts().
#
# The awk below distinguishes an outer key line (/^  [^ ]/ — exactly two leading
# spaces then a non-space) from an inner entry line (/^    / — four leading
# spaces); the two classes are disjoint. The section ends at the next top-level
# key (/^[^ #]/). Values are stored quoted (the L7 delimiter convention).

# Echo the path bound to (<project>, <name>) in project_paths:, or empty.
# Usage: _index_pp_get <project> <name>
_index_pp_get() {
    local project="$1" name="$2" f
    f=$(_index_file)
    [[ -f "$f" ]] || return 0
    awk -v project="$project" -v name="$name" '
        $0 == "project_paths:" { in_sec = 1; next }
        in_sec && /^[^ #]/ { exit }
        in_sec && /^  [^ ]/ {
            pline = $0; sub(/^  /, "", pline); sub(/:.*/, "", pline)
            in_proj = (pline == project)
            next
        }
        in_sec && in_proj && /^    / {
            line = $0; sub(/^    /, "", line)
            colon = index(line, ":")
            if (colon > 0) {
                k = substr(line, 1, colon - 1)
                v = substr(line, colon + 1)
                sub(/^ +/, "", v)
                sub(/^"/, "", v); sub(/"$/, "", v)   # strip quoting delimiters only (L7)
                if (k == name) { print v; exit }
            }
        }
    ' "$f"
}

# Upsert (<project>, <name>) → "<value>" into project_paths: (atomic). The value
# is normalized at this boundary (_index_normalize_path); a non-absolute value
# that cannot be recovered is SKIPPED (no write) and the call returns 1. Creates
# the section and/or the project block on demand. AD5′ conflict policy lives in
# the caller — see _index_pp_conflicts(). Usage: _index_pp_set <project> <name> <path>
_index_pp_set() {
    local project="$1" name="$2" value norm f
    norm=$(_index_normalize_path "$3") || return 1
    value="$norm"
    _index_ensure_file
    f=$(_index_file)

    local tmpf=""
    # shellcheck disable=SC2064
    trap 'rm -f ${tmpf:+"$tmpf"}' RETURN
    tmpf=$(mktemp "${f}.XXXXXX")

    # CCO_IDX_VAL passes the value via env to avoid AWK -v backslash expansion.
    CCO_IDX_VAL="$value" awk -v project="$project" -v name="$name" '
        BEGIN { val = ENVIRON["CCO_IDX_VAL"]; done = 0; in_sec = 0; in_proj = 0; sec_seen = 0 }
        $0 == "project_paths:" { print; in_sec = 1; sec_seen = 1; next }
        in_sec && /^[^ #]/ {
            # Leaving the section — flush any pending insert first.
            if (!done) {
                if (in_proj) { print "    " name ": \"" val "\"" }
                else { print "  " project ":"; print "    " name ": \"" val "\"" }
                done = 1
            }
            in_sec = 0; in_proj = 0
            print; next
        }
        in_sec && /^  [^ ]/ {
            # A new project block starts: if we were inside the target block and
            # never found the name, insert it before moving on.
            if (in_proj && !done) { print "    " name ": \"" val "\""; done = 1 }
            pline = $0; sub(/^  /, "", pline); sub(/:.*/, "", pline)
            in_proj = (pline == project)
            print; next
        }
        in_sec && in_proj && /^    / {
            line = $0; sub(/^    /, "", line)
            colon = index(line, ":")
            k = (colon > 0) ? substr(line, 1, colon - 1) : line
            if (!done && k == name) { print "    " name ": \"" val "\""; done = 1; next }
            print; next
        }
        { print }
        END {
            if (!done) {
                if (in_proj)       { print "    " name ": \"" val "\"" }
                else if (in_sec)   { print "  " project ":"; print "    " name ": \"" val "\"" }
                else if (!sec_seen) {
                    print "project_paths:"
                    print "  " project ":"
                    print "    " name ": \"" val "\""
                }
            }
        }
    ' "$f" > "$tmpf" && mv "$tmpf" "$f"
}

# Remove (<project>, <name>) from project_paths: (atomic; no-op if absent). If
# the removal empties the project block, the block header is pruned too so the
# file never accumulates dangling empty projects.
# Usage: _index_pp_remove <project> <name>
_index_pp_remove() {
    local project="$1" name="$2" f
    f=$(_index_file)
    [[ -f "$f" ]] || return 0

    local tmpf=""
    # shellcheck disable=SC2064
    trap 'rm -f ${tmpf:+"$tmpf"}' RETURN
    tmpf=$(mktemp "${f}.XXXXXX")

    awk -v project="$project" -v name="$name" '
        # A project header is buffered in `pending` and only emitted once a
        # surviving child is seen — so a block emptied by the removal is dropped.
        function flush() { if (pending != "") { if (has_child) print pending; pending = ""; has_child = 0 } }
        $0 == "project_paths:" { print; in_sec = 1; next }
        in_sec && /^[^ #]/ { flush(); in_sec = 0; in_proj = 0; print; next }
        in_sec && /^  [^ ]/ {
            flush()
            pline = $0; sub(/^  /, "", pline); sub(/:.*/, "", pline)
            in_proj = (pline == project)
            pending = $0; has_child = 0
            next
        }
        in_sec && /^    / {
            line = $0; sub(/^    /, "", line)
            colon = index(line, ":")
            k = (colon > 0) ? substr(line, 1, colon - 1) : line
            if (in_proj && k == name) { next }     # drop the target inner entry
            if (pending != "") { print pending; pending = "" }
            has_child = 1
            print; next
        }
        { flush(); print }
        END { flush() }
    ' "$f" > "$tmpf" && mv "$tmpf" "$f"
}

# Remove an entire project block from project_paths: (atomic; no-op if absent).
# Usage: _index_pp_remove_project <project>
_index_pp_remove_project() {
    local project="$1" f
    f=$(_index_file)
    [[ -f "$f" ]] || return 0

    local tmpf=""
    # shellcheck disable=SC2064
    trap 'rm -f ${tmpf:+"$tmpf"}' RETURN
    tmpf=$(mktemp "${f}.XXXXXX")

    awk -v project="$project" '
        $0 == "project_paths:" { print; in_sec = 1; next }
        in_sec && /^[^ #]/ { in_sec = 0; in_proj = 0; print; next }
        in_sec && /^  [^ ]/ {
            pline = $0; sub(/^  /, "", pline); sub(/:.*/, "", pline)
            in_proj = (pline == project)
            if (in_proj) next
            print; next
        }
        in_sec && in_proj && /^    / { next }     # drop the target block children
        { print }
    ' "$f" > "$tmpf" && mv "$tmpf" "$f"
}

# Dump one project's bindings as "name=path" lines. Usage: _index_pp_dump_project <project>
_index_pp_dump_project() {
    local project="$1" f
    f=$(_index_file)
    [[ -f "$f" ]] || return 0
    awk -v project="$project" '
        $0 == "project_paths:" { in_sec = 1; next }
        in_sec && /^[^ #]/ { exit }
        in_sec && /^  [^ ]/ {
            pline = $0; sub(/^  /, "", pline); sub(/:.*/, "", pline)
            in_proj = (pline == project)
            next
        }
        in_sec && in_proj && /^    / {
            line = $0; sub(/^    /, "", line)
            colon = index(line, ":")
            if (colon > 0) {
                k = substr(line, 1, colon - 1)
                v = substr(line, colon + 1)
                sub(/^ +/, "", v)
                sub(/^"/, "", v); sub(/"$/, "", v)
                if (k != "" && v != "") print k "=" v
            }
        }
    ' "$f"
}

# Dump every binding as "project<TAB>name<TAB>path" lines (for list/scan/reverse).
_index_pp_dump_all() {
    local f
    f=$(_index_file)
    [[ -f "$f" ]] || return 0
    awk '
        $0 == "project_paths:" { in_sec = 1; next }
        in_sec && /^[^ #]/ { exit }
        in_sec && /^  [^ ]/ {
            cur = $0; sub(/^  /, "", cur); sub(/:.*/, "", cur)
            next
        }
        in_sec && /^    / {
            line = $0; sub(/^    /, "", line)
            colon = index(line, ":")
            if (colon > 0) {
                k = substr(line, 1, colon - 1)
                v = substr(line, colon + 1)
                sub(/^ +/, "", v)
                sub(/^"/, "", v); sub(/"$/, "", v)
                if (cur != "" && k != "" && v != "") printf "%s\t%s\t%s\n", cur, k, v
            }
        }
    ' "$f"
}

# ── Boundary normalization (the index stores absolute paths only) ─────
#
# The single normalizer for every value written to the paths: section. It
# expands the legacy local-paths.yml spellings (~, ~/…, $HOME, $HOME/…) — more
# than expand_path(), which only handles ~ — and REJECTS anything still
# non-absolute (relative / empty / a bare `@local` marker with no recovery).
# Rejecting at the write boundary keeps every reader (resolve, path list,
# conflict check, compose mount-gen) free of the tilde/@local poisoning that
# broke by-name resolve and produced false AD5 conflicts (design §3).
# Usage: _index_normalize_path <value>  → stdout abs path, return 0
#                                       → (non-absolute) no output, return 1
_index_normalize_path() {
    local p="$1"
    case "$p" in
        "~")        p="$HOME" ;;
        "~/"*)      p="$HOME/${p#\~/}" ;;
        '$HOME')    p="$HOME" ;;
        '$HOME/'*)  p="$HOME/${p#\$HOME/}" ;;
    esac
    [[ "$p" == /* ]] || return 1
    printf '%s\n' "$p"
}

# ── Public API (per-project scoped, ADR-0051; dual-schema read) ───────
#
# Every path accessor is now PROJECT-SCOPED: the name is a per-project label for
# a path. Reads tolerate a still-v1 (global-flat) index as a transitional
# fallback (the resolver keeps working until the first host-side write upgrades
# it); writes go through _index_ensure_file, which upgrades v1→v2 first.

# Echo the absolute path bound to (<project>, <name>), or empty if unresolved.
# Resolution order (ADR-0051 D2): the project's own binding, else the unscoped
# escape-hatch bucket (a `cco path set` pin made outside any project). There is
# NO cross-PROJECT fallback — another project's same-name binding is a different
# resource and is never consulted; the unscoped bucket is project-LESS, not a
# global default among project bindings (a generic `assets` mount resolved per
# project by `cco resolve` lives in each project's block, never unscoped). v1
# index → read the flat global binding by name. Usage: _index_get_path <project> <name>
_index_get_path() {
    if [[ "$(_index_version)" -ge 2 ]]; then
        local v; v=$(_index_pp_get "$1" "$2")
        [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }
        _index_section_get unscoped "$2"
    else
        _index_section_get paths "$2"
    fi
}

# Echo the FIRST path bound to <name> in ANY project, else the unscoped bucket
# (v1 → flat global). For the transitional / genuinely cross-project sites that
# resolve a bare repo name with no project context in hand: `cco sync --from`,
# `cco start --from`, config-editor `--repo`. Ambiguity across projects resolves
# to the first match. Usage: _index_get_path_any <name>
_index_get_path_any() {
    local name="$1" proj n path
    if [[ "$(_index_version)" -ge 2 ]]; then
        while IFS=$'\t' read -r proj n path; do
            [[ "$n" == "$name" ]] && { printf '%s\n' "$path"; return 0; }
        done < <(_index_pp_dump_all)
        _index_section_get unscoped "$name"
    else
        _index_section_get paths "$name"
    fi
}

# Reverse lookup within a project: echo the FIRST name that <project> binds to
# <abs-path>, or empty. Recovers the host repo's logical name from its directory
# (membership must include the host so by-name resolution can relocate the unit).
# Path-scoped comparison is normalized. Usage: _index_name_for_path <project> <abs-path>
_index_name_for_path() {
    local project="$1" target="$2" tn name path pn
    tn=$(_index_normalize_path "$target") || tn="$target"
    if [[ "$(_index_version)" -ge 2 ]]; then
        # The project's own bindings first, then the unscoped escape-hatch bucket
        # (mirrors _index_get_path's fallback — a global pin is name-recoverable).
        while IFS='=' read -r name path; do
            [[ -z "$name" ]] && continue
            pn=$(_index_normalize_path "$path") || pn="$path"
            [[ "$pn" == "$tn" ]] && { printf '%s\n' "$name"; return 0; }
        done < <(_index_pp_dump_project "$project"; _index_section_dump unscoped)
    else
        while IFS='=' read -r name path; do
            [[ -z "$name" ]] && continue
            pn=$(_index_normalize_path "$path") || pn="$path"
            [[ "$pn" == "$tn" ]] && { printf '%s\n' "$name"; return 0; }
        done < <(_index_section_dump paths)
    fi
}

# Bind (<project>, <name>) → <path> (upsert). Normalized at the boundary; a
# non-absolute value that cannot be recovered is SKIPPED (no write, return 1).
# AD5′ conflict policy lives in the caller — see _index_path_conflicts().
# Usage: _index_set_path <project> <name> <path>
_index_set_path() { _index_pp_set "$1" "$2" "$3"; }

# Remove (<project>, <name>) from the index (v1 → flat by name). An empty
# <project> targets the unscoped bucket (a `cco path set` orphan).
# Usage: _index_remove_path <project> <name>
_index_remove_path() {
    local project="$1" name="$2"
    [[ -z "$project" ]] && { _index_section_remove unscoped "$name"; return 0; }
    if [[ "$(_index_version)" -ge 2 ]]; then
        _index_pp_remove "$project" "$name"
    else
        _index_section_remove paths "$name"
    fi
}

# Bind a project-less name in the unscoped bucket (the `cco path set` escape
# hatch when the cwd is not inside a project). Usage: _index_set_unscoped <name> <path>
_index_set_unscoped() {
    local norm; norm=$(_index_normalize_path "$2") || return 1
    _index_ensure_file
    _index_section_set unscoped "$1" "$norm"
}

# List ALL bound names as "name=path" lines, project-flattened (v2: every
# project_paths binding + the unscoped bucket; v1: the flat global map). Used for
# the sibling-directory suggestion hint; project context is intentionally dropped.
_index_list_paths() {
    if [[ "$(_index_version)" -ge 2 ]]; then
        _index_pp_dump_all | awk -F'\t' 'NF>=3 { print $2 "=" $3 }'
        _index_section_dump unscoped
    else
        _index_section_dump paths
    fi
}

# List all recorded projects as "project=<space-separated repo names>" lines.
_index_list_projects() { _index_section_dump projects; }

# Return 0 (true) iff (<project>, <name>) is already bound to a DIFFERENT
# absolute path — the AD5′ chokepoint (ADR-0051 D3). Cross-project same-name is
# NOT a conflict. v1 index → the legacy global-flat check by name.
# Usage: _index_path_conflicts <project> <name> <path>
_index_path_conflicts() {
    if [[ "$(_index_version)" -ge 2 ]]; then
        _index_pp_conflicts "$1" "$2" "$3"
    else
        local existing en pn
        existing=$(_index_section_get paths "$2")
        [[ -z "$existing" ]] && return 1
        en=$(_index_normalize_path "$existing") || en="$existing"
        pn=$(_index_normalize_path "$3") || pn="$3"
        [[ "$en" != "$pn" ]]
    fi
}

# Return 0 (true) iff (<project>, <name>) is already bound to a DIFFERENT
# absolute path — the AD5′ uniqueness violation that init/join/scan must refuse
# under per-project scoping (ADR-0051 D3). The single project-aware chokepoint:
# a conflict exists ONLY when the SAME project already binds <name> to a
# different path; a cross-project same-name binding is NOT a conflict, and an
# unbound name is not a conflict. Both sides are normalized before comparing so
# two spellings of the same dir (~/x vs /home/me/x) are not a false conflict.
# Usage: _index_pp_conflicts <project> <name> <path>
_index_pp_conflicts() {
    local project="$1" name="$2" path="$3" existing
    existing=$(_index_pp_get "$project" "$name")
    [[ -z "$existing" ]] && return 1
    local en pn
    en=$(_index_normalize_path "$existing") || en="$existing"
    pn=$(_index_normalize_path "$path") || pn="$path"
    [[ "$en" != "$pn" ]]
}

# Path-based reverse lookup (ADR-0051 D5): echo the (project, name) bindings that
# resolve to <path>, one "project<TAB>name" line each. Replaces the name-based
# _index_repos_get_projects — sharing/GC/rename are PATH properties (§12 identity
# model), so "same resource" is decided by path coincidence, never by name. The
# target path is normalized so a tilde/$HOME spelling still matches.
# Usage: _index_paths_get_bindings <path>
_index_paths_get_bindings() {
    local target="$1" tn line proj name path pn
    tn=$(_index_normalize_path "$target") || tn="$target"
    while IFS=$'\t' read -r proj name path; do
        [[ -z "$path" ]] && continue
        pn=$(_index_normalize_path "$path") || pn="$path"
        [[ "$pn" == "$tn" ]] && printf '%s\t%s\n' "$proj" "$name"
    done < <(_index_pp_dump_all)
}

# Name-based cross-project lookup (ADR-0051 D4): echo every project_paths binding
# for a logical <name> across ALL projects, one "project<TAB>path" line each. The
# unscoped bucket is excluded (project-less). Powers add-time disambiguation — a
# name bound in OTHER projects is a homonym-or-reuse decision, not a collision.
# Usage: _index_bindings_for_name <name>
_index_bindings_for_name() {
    local want="$1" proj name path
    while IFS=$'\t' read -r proj name path; do
        [[ "$name" == "$want" ]] && printf '%s\t%s\n' "$proj" "$path"
    done < <(_index_pp_dump_all)
}

# Echo the space-separated member repo names of a <project>, or empty.
_index_get_project_repos() { _index_section_get projects "$1"; }

# Set a <project>'s member repo names (remaining args joined by spaces).
# Usage: _index_set_project_repos <project> <repo> [<repo> ...]
_index_set_project_repos() {
    local project="$1"; shift
    _index_section_set projects "$project" "$*"
}

# Remove a <project>'s membership entry.
_index_remove_project() { _index_section_remove projects "$1"; }

# Re-key a project's identity from <old> to <new>: its membership (projects:) AND
# its per-project path block (project_paths:, ADR-0051 — keyed by project name).
# The identity re-key primitive for `cco project rename` (ADR-0031 D2). No-op-safe:
# an absent <old> just creates <new> with empty members — callers validate <old>
# exists and <new> is free first. Usage: _index_rename_project <old> <new>
_index_rename_project() {
    local old="$1" new="$2" members name path
    members=$(_index_get_project_repos "$old")
    _index_set_project_repos "$new" $members
    _index_remove_project "$old"
    # Re-home the project_paths block (v2). No-op under v1 (dump is empty).
    while IFS='=' read -r name path; do
        [[ -z "$name" ]] && continue
        _index_pp_set "$new" "$name" "$path"
    done < <(_index_pp_dump_project "$old")
    _index_pp_remove_project "$old"
}

# Re-key a repo/extra_mount NAME within ONE project from <old> to <new>: its
# per-project path binding (project_paths[project]) AND its membership token in
# projects:<project>. Project-scoped (ADR-0051 D1) — never touches another
# project's binding, even one sharing the name or the same path (the name axis is
# per-project; identity is the path). The bound path is preserved (name axis only).
# No-op-safe: an <old> unbound in <project> skips the path re-key; the membership
# token rewrite is idempotent. Callers validate <new> is free in <project> first.
# The repo/extra_mount analogue of _index_rename_project (ADR-0050 D6).
# Usage: _index_rename_path <project> <old> <new>
_index_rename_path() {
    local project="$1" old="$2" new="$3" path members
    path=$(_index_pp_get "$project" "$old")
    if [[ -n "$path" ]]; then
        _index_pp_set "$project" "$new" "$path"
        _index_pp_remove "$project" "$old"
    fi
    members=$(_index_get_project_repos "$project")
    if [[ -n "$members" ]]; then
        local out="" tok
        for tok in $members; do
            [[ "$tok" == "$old" ]] && tok="$new"
            out="${out:+$out }$tok"
        done
        _index_set_project_repos "$project" $out
    fi
}

# NOTE: the name-based reverse lookup _index_repos_get_projects (ADR-0024 D5) is
# retired under per-project scoping (ADR-0051 D5) — "which projects use name X" is
# ambiguous when a name is a per-project label. Use _index_paths_get_bindings
# (path-based) instead: sharing/GC/rename are PATH properties (§12 identity model).

# ── Member sync-state classification (ADR-0024 D5 / sync-meta F39) ────
# The single source of truth for "what is this member repo, w.r.t. <project>".
# It joins three internal signals — the machine-local index (is it resolved
# here?), the committed project.yml `name:` (whom does it host?, ADR-0024 D1/D2),
# and the per-machine sync fingerprint (edited since the last sync?, sync-meta) —
# into one taxonomy reused by `cco project show`, `cco join`, and `cco forget`.
#
# Echoes exactly one of:
#   unresolved — no resolved path on this machine (the dir is missing). Can't
#                read its .cco/, can't act on its files; only index/membership.
#   code-only  — resolved, but NO committed .cco/project.yml (a Case-A reference
#                member that carries no config).
#   foreign    — resolved, .cco/project.yml hosts a DIFFERENT project (its
#                `name:` != <project>; the ADR-0024 D2 clobber-guard discriminator).
#                Belongs to another project (or a divergent unsynced copy keyed by
#                a different name) → never touched by same-id operations.
#   divergent  — resolved, OWNS <project> (`name:` ==) but its synced set was
#                edited locally since the last sync (_sync_is_divergent). Same
#                project name, content drifted.
#   synced     — resolved, owns <project>, in sync (fingerprint matches) or
#                pristine (never synced; no stored fingerprint => not divergent).
# Usage: _project_member_status <project> <repo_path>
_project_member_status() {
    local project="$1" repo_path="$2" hosted
    [[ -n "$repo_path" && -d "$repo_path" ]] || { printf 'unresolved'; return 0; }
    [[ -f "$repo_path/.cco/project.yml" ]]   || { printf 'code-only'; return 0; }
    hosted=$(_cco_project_id "$repo_path" 2>/dev/null)
    if   [[ "$hosted" != "$project" ]];        then printf 'foreign'
    elif _sync_is_divergent "$repo_path" 2>/dev/null; then printf 'divergent'
    else printf 'synced'; fi
}

# Iterate <project>'s member repos, emitting one TAB line per member:
#   "<name>\t<probe_path>\t<status>"   (probe_path empty when not inspectable here)
# Column 2 is the path at which the member is INSPECTABLE in the current context —
# the container MOUNT in operator mode (INV-F: the STATE index holds a HOST path
# that never exists in a session), the index host path on the host (probe is the
# identity there, so the emitted rows stay byte-identical). Membership is repos-only,
# which always mount at <workdir>/<name>, so the 2-arg probe is correct (INV-F.2 does
# not apply). INV-F.1 keeps a membership token with no path binding from being
# resolved to a mount it does not own. <status> comes from _project_member_status.
# This is the ownership-guarded loop shared by `cco join`/`cco forget --purge`/the
# rename verbs' project.yml rewrite. Build-once; callers filter on <status>.
# Usage: while IFS=$'\t' read -r name path status; do …; done < <(_project_iter_members <project>)
#
# OPERATOR ENUMERATION ARM (RC-3 §3.6, closes E6B-04). The member NAMES come from
# _index_get_project_repos, i.e. the STATE index — which sits behind the ADR-0047
# boundary and reads EMPTY as `claude` in a session (§1.3 row 4). RC-2 fixed column 2
# (the probe path) but left the enumeration source, so every loop over a project's
# members was VACUOUS in-container — the pack-rename pre-scan always passed and the
# rename verbs' project.yml rewrite reached nobody. When the project resolves to a
# mounted, claude-readable project.yml, enumerate its repos[] from THAT file instead
# (no crossing required) and probe each at its flat mount <workdir>/<name>. If the
# project is not mounted here (another project at read-all), fall back to the index
# loop — which is also the unchanged HOST path (the probe is the identity there, so
# rows stay byte-identical; test_index.sh:222 pins the shape).
_project_iter_members() {
    local project="$1" repo_name idx probe status
    if _cco_container_operator; then
        local yml line wd="${CCO_WORKDIR:-/workspace}"
        if yml=$(_resolve_project_yml "$project" 2>/dev/null) && [[ -f "$yml" ]]; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                repo_name="${line%%$'\t'*}"           # col 1 only; url/ref may be empty
                [[ -z "$repo_name" ]] && continue
                probe="$wd/$repo_name"                # repos always mount at <workdir>/<name>
                [[ -d "$probe" ]] || probe=""
                status=$(_project_member_status "$project" "$probe")
                printf '%s\t%s\t%s\n' "$repo_name" "$probe" "$status"
            done < <(yml_get_repo_coords "$yml")
            return 0
        fi
    fi
    for repo_name in $(_index_get_project_repos "$project"); do
        idx=$(_index_get_path "$project" "$repo_name")
        probe=$(_cco_member_probe_path "$repo_name" "$idx")   # "" when idx is "" (INV-F.1)
        [[ -n "$probe" && -d "$probe" ]] || probe=""
        status=$(_project_member_status "$project" "$probe")
        printf '%s\t%s\t%s\n' "$repo_name" "$probe" "$status"
    done
}
