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
#   version: 1
#   paths:
#     <name>: "<abs-path>"
#   projects:
#     <project>: "<repo> <repo> ..."
#
# Mechanism only — AD5 uniqueness (refuse a name already bound to a different
# path) is enforced by the callers (cco init/join, cco resolve --scan), which
# use _index_path_conflicts(). Writes are atomic (mktemp + mv), single-writer,
# no file lock (v1): writes are user-serial; a rare race is last-writer-wins and
# self-heals via `cco resolve --scan` (ADR-0022 D2). Global-flat — one machine
# global paths: map; per-project namespacing is reserved post-v1 (H7).
#
# Provides: _index_file(), _index_get_path(), _index_set_path(),
#   _index_remove_path(), _index_path_conflicts(), _index_list_paths(),
#   _index_get_project_repos(), _index_set_project_repos(),
#   _index_remove_project(), _index_list_projects(), _index_repos_get_projects(),
#   _project_member_status(), _project_iter_members()
# Dependencies: colors.sh, paths.sh (_cco_state_dir/_cco_project_id),
#   sync-meta.sh (_sync_is_divergent) — both resolved at call time.

# Absolute path to the index file (STATE; host-side guard applies via resolver).
_index_file() {
    printf '%s\n' "$(_cco_state_dir)/index"
}

# Create the index scaffold if missing (both sections always present, so the
# section upsert/remove logic never has to create a section).
_index_ensure_file() {
    local f; f=$(_index_file)
    [[ -f "$f" ]] && return 0
    # Atomic create (mktemp + mv), the same convention as every other index write
    # (H7 / ADR-0022 D2) — a direct multi-line redirect is the one non-atomic site,
    # which two concurrent first-runs could interleave.
    local tmpf; tmpf=$(mktemp "${f}.XXXXXX")
    {
        echo "# cco machine-local index — logical name → absolute path + project membership."
        echo "# Regenerable via 'cco resolve --scan'; never committed, never synced."
        echo "version: 1"
        echo "paths:"
        echo "projects:"
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

# ── Public API ───────────────────────────────────────────────────────

# Echo the absolute path bound to a logical <name>, or empty if unresolved.
_index_get_path() { _index_section_get paths "$1"; }

# Reverse lookup: echo the FIRST logical name bound to <abs-path> in paths:, or
# empty. Complement of _index_get_path; recovers the host repo's logical name
# from its directory (membership must include the host so by-name resolution can
# relocate the unit even when the host is not listed in the manifest's repos:).
_index_name_for_path() {
    local target="$1" line name path
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        name="${line%%=*}"; path="${line#*=}"
        [[ "$path" == "$target" ]] && { printf '%s\n' "$name"; return 0; }
    done < <(_index_list_paths)
}

# Bind a logical <name> to an absolute <path> (upsert). The value is normalized
# at this boundary (_index_normalize_path); a non-absolute value that cannot be
# recovered is SKIPPED (no write) and the call returns 1 — the user-facing warn
# lives at the caller (resolve/migrate) where there is context. AD5 conflict
# policy lives in the caller — see _index_path_conflicts().
_index_set_path() {
    local norm
    norm=$(_index_normalize_path "$2") || return 1
    _index_section_set paths "$1" "$norm"
}

# Remove a logical <name> from the index.
_index_remove_path() { _index_section_remove paths "$1"; }

# List all bound names as "name=path" lines.
_index_list_paths() { _index_section_dump paths; }

# List all recorded projects as "project=<space-separated repo names>" lines.
_index_list_projects() { _index_section_dump projects; }

# Return 0 (true) iff <name> is already bound to a DIFFERENT absolute path
# (the AD5 uniqueness violation that init/join/scan must refuse). Returns 1 if
# unbound or already bound to the same path.
_index_path_conflicts() {
    local name="$1" path="$2" existing
    existing=$(_index_get_path "$name")
    [[ -z "$existing" ]] && return 1
    # Normalize both sides before comparing so two spellings of the SAME dir
    # (~/x vs /home/me/x, a $HOME prefix) are not a false AD5 conflict. Fall
    # back to the raw value if a side is not normalizable (defense-in-depth
    # against an already-dirty entry written before the boundary fix).
    local en pn
    en=$(_index_normalize_path "$existing") || en="$existing"
    pn=$(_index_normalize_path "$path") || pn="$path"
    [[ "$en" != "$pn" ]]
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

# Re-key a project's membership from <old> to <new>, preserving its member repo
# names (the identity re-key primitive for `cco project rename`, ADR-0031 D2).
# No-op-safe: an absent <old> just creates <new> with empty members — callers
# validate <old> exists and <new> is free first. Usage: _index_rename_project <old> <new>
_index_rename_project() {
    local old="$1" new="$2" members
    members=$(_index_get_project_repos "$old")
    _index_set_project_repos "$new" $members
    _index_remove_project "$old"
}

# Reverse lookup (ADR-0024 D5): echo the projects (one per line) that reference
# <repo> as a member. Complement of _index_get_project_repos; drives repo↔project
# observability in `cco project show` and the repo-centric view.
_index_repos_get_projects() {
    local repo="$1" line proj members m
    while IFS= read -r line; do
        proj="${line%%=*}"; members="${line#*=}"
        for m in $members; do
            [[ "$m" == "$repo" ]] && { printf '%s\n' "$proj"; break; }
        done
    done < <(_index_section_dump projects)
}

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
#   "<name>\t<abspath>\t<status>"   (abspath empty when status == unresolved)
# <status> comes from _project_member_status. This is the ownership-guarded loop
# shared by `cco join` (which members' project.yml `repos[]` to edit — owned,
# never foreign) and `cco forget --purge` (which repos' .cco/ are owned and may
# be deleted). Build-once; callers filter on <status>.
# Usage: while IFS=$'\t' read -r name path status; do …; done < <(_project_iter_members <project>)
_project_iter_members() {
    local project="$1" repo_name path status
    for repo_name in $(_index_get_project_repos "$project"); do
        path=$(_index_get_path "$repo_name")
        [[ -n "$path" && -d "$path" ]] || path=""
        status=$(_project_member_status "$project" "$path")
        printf '%s\t%s\t%s\n' "$repo_name" "$path" "$status"
    done
}
