#!/usr/bin/env bash
# lib/rename.sh — shared machinery for the per-kind `cco <kind> rename` verbs
# (ADR-0050). A rename is a multi-store identity re-key, not a single-file edit;
# this module single-sources the parts common to repo/extra_mount/pack/template/
# remote/llms rename so the five verbs stay thin wrappers (D6, DRY over copies):
#
#   _yaml_rename_list_ref   — rewrite a name inside ONE YAML list section
#                             (scalar `- old` and mapping `- name: old` forms),
#                             section-scoped. Generalizes _llms_rename_in_yaml.
#   _yaml_list_has_ref      — read-only companion: does a section reference a name?
#   _rename_validate        — per-kind charset + reserved-name guard (dies).
#   _rename_projectyml_current — rewrite <section>[].name in the CURRENT project's
#                             owned+resolved member repos only (repo/extra_mount,
#                             project-scoped — ADR-0051 D1).
#   _rename_fanout_projectyml — cross-project fan-out for globally-scoped refs
#                             (pack): rewrite every referencing project's members,
#                             surfacing unresolved members for the strict guard.
#   _rename_preview_confirm — uniform preview + _confirm_destructive (ADR-0029 D2).
#
# Kind-scoped uniqueness (the new name must not already name a resource of the
# same kind) is enforced at each call site, where the store to check is known.
#
# Dependencies: colors.sh, utils.sh (_cco_valid_project_name / _confirm_destructive
#   / RESERVED_PROJECT_NAMES / die), index.sh (_project_iter_members),
#   cmd-resolve.sh (_project_foreach).

# ── YAML list-reference rewriter ─────────────────────────────────────
# Rewrite a logical name <old> → <new> wherever it appears as an item of the YAML
# list section <section> in <file>. Handles BOTH forms cco emits:
#   scalar:   "  - old"            (e.g. llms:)
#   mapping:  "  - name: old"      (e.g. repos:/extra_mounts:/packs:)
# The rewrite is section-scoped: it starts at the "<section>:" top-level key and
# stops at the next top-level key, so it never bleeds into an adjacent section or
# a same-named key elsewhere. The value is compared as an exact string (never a
# regex) so a name containing '.' or '-' cannot over-match. Returns 0 iff at least
# one item changed (so callers can count), 1 otherwise; the file is only rewritten
# on a change. Usage: _yaml_rename_list_ref <file> <section> <old> <new>
_yaml_rename_list_ref() {
    local file="$1" section="$2" old="$3" new="$4"
    [[ -f "$file" ]] || return 1

    local tmp; tmp=$(mktemp "${file}.XXXXXX") || return 1
    if awk -v section="$section" -v old="$old" -v new="$new" '
        BEGIN { changed = 0; hdr = "^" section ":" }
        # Top-level "<section>:" opens the target section.
        $0 ~ hdr { in_sec = 1; print; next }
        # Any other top-level key (col-0, non-space, non-comment) closes it.
        in_sec && /^[^[:space:]#]/ { in_sec = 0 }
        in_sec {
            # Mapping form:  <indent>- name: <value>
            if (match($0, /^[[:space:]]*-[[:space:]]+name:[[:space:]]*/)) {
                pre = substr($0, 1, RLENGTH); val = substr($0, RLENGTH + 1)
                sub(/[[:space:]]+$/, "", val)
                if (val == old) { print pre new; changed = 1; next }
                print; next
            }
            # Scalar form:  <indent>- <value>
            if (match($0, /^[[:space:]]*-[[:space:]]+/)) {
                pre = substr($0, 1, RLENGTH); val = substr($0, RLENGTH + 1)
                sub(/[[:space:]]+$/, "", val)
                if (val == old) { print pre new; changed = 1; next }
                print; next
            }
        }
        { print }
        END { exit changed ? 0 : 1 }
    ' "$file" > "$tmp"; then
        mv "$tmp" "$file"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Read-only predicate: does <file> reference <name> as an item of list section
# <section> (scalar OR mapping form)? Returns 0 iff present. Used by pack fan-out
# to decide whether a project references the pack (so an unresolved member becomes
# a strict-guard blocker only for projects that actually use it).
# Usage: _yaml_list_has_ref <file> <section> <name>
_yaml_list_has_ref() {
    local file="$1" section="$2" name="$3"
    [[ -f "$file" ]] || return 1
    awk -v section="$section" -v name="$name" '
        BEGIN { hdr = "^" section ":" }
        $0 ~ hdr { in_sec = 1; next }
        in_sec && /^[^[:space:]#]/ { in_sec = 0 }
        in_sec {
            if (match($0, /^[[:space:]]*-[[:space:]]+name:[[:space:]]*/)) {
                val = substr($0, RLENGTH + 1); sub(/[[:space:]]+$/, "", val)
                if (val == name) { found = 1; exit }
                next
            }
            if (match($0, /^[[:space:]]*-[[:space:]]+/)) {
                val = substr($0, RLENGTH + 1); sub(/[[:space:]]+$/, "", val)
                if (val == name) { found = 1; exit }
            }
        }
        END { exit found ? 0 : 1 }
    ' "$file"
}

# ── Validation ───────────────────────────────────────────────────────
# Per-kind charset predicate + reserved-name guard for a proposed <new> name.
# Dies on failure before any write. Charset reuses each kind's existing predicate:
# repo/extra_mount/pack/template/remote share the project-name charset
# ([a-z0-9][a-z0-9-]*, starting alphanumeric); llms additionally allows uppercase
# and '.' (its installed-entry charset). Kind-scoped uniqueness is checked by the
# caller (store-specific). Usage: _rename_validate <kind> <new>
_rename_validate() {
    local kind="$1" new="$2" r
    case "$kind" in
        llms)
            [[ "$new" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] \
                || die "Invalid llms name '$new' — must start alphanumeric and contain only letters, digits, '.', '_' or '-'." ;;
        *)
            _cco_valid_project_name "$new" \
                || die "Invalid $kind name '$new' — lowercase letters, numbers, and hyphens only (starting alphanumeric)." ;;
    esac
    for r in "${RESERVED_PROJECT_NAMES[@]}"; do
        [[ "$new" == "$r" ]] && die "'$new' is a reserved name and cannot be used for a $kind."
    done
    return 0
}

# ── De-elevation for claude-owned config-tree writes (D-M4 / ADR-0047 §2) ──
# A store-touching rename trampolines the WHOLE verb to euid=cco-svc (bin/cco),
# which is right for the STATE-index re-key but WRONG for the member's
# <repo>/.cco tree — that is claude-owned, and cco-svc must never write it. A plain
# `bash` (never `bash -p`) resets euid→ruid=claude on entry when they differ
# (documented behaviour cco-svc-helper.c already relies on), and is a plain
# passthrough when they are already equal (the host and the hermetic suite). This
# only ever NARROWS privilege and is POSIX-correct by construction — no reliance on
# Docker Desktop fakeowner (D-M6). It is gated on CCO_STORE_ELEVATED=1, set by the
# setuid helper; the member-enumeration read of the STATE index stays in the
# elevated caller, only the file WRITE crosses back down.

# Run an EXTERNAL command as ruid=claude when this process is the elevated store
# re-entry. Only for external commands — a fresh bash sees no shell functions.
# Usage: _rename_deelevated <cmd> [args...]
_rename_deelevated() {
    if [[ "${CCO_STORE_ELEVATED:-}" == "1" ]]; then
        bash -c '"$@"' _ "$@"
    else
        "$@"
    fi
}

# Perform ONE member's project.yml list-rewrite as ruid=claude. Re-sources the
# rename machinery in the de-elevated bash because _yaml_rename_list_ref is a shell
# function; REPO_ROOT is passed as an argument, not inherited. Returns its status.
# Usage: _rename_yaml_write_owned <yml> <section> <old> <new>
_rename_yaml_write_owned() {
    local yml="$1" section="$2" old="$3" new="$4"
    if [[ "${CCO_STORE_ELEVATED:-}" == "1" ]]; then
        bash -c '
            source "$1/lib/colors.sh"; source "$1/lib/utils.sh"
            source "$1/lib/paths.sh";  source "$1/lib/rename.sh"
            _yaml_rename_list_ref "$2" "$3" "$4" "$5"
        ' _ "$REPO_ROOT" "$yml" "$section" "$old" "$new"
    else
        _yaml_rename_list_ref "$yml" "$section" "$old" "$new"
    fi
}

# §3.5 fail-closed precondition: assert <dir> is writable BY THIS PROCESS before any
# mutation. An identity-agnostic probe — an actual mktemp, not `test -w` (whose
# access(2) checks the REAL uid = claude even when euid = cco-svc, a false yes) —
# run at the SAME identity as the real write (de-elevated when elevated, D-M4), so
# it never passes on a tree the write cannot touch. Refuses (exit 2) before Phase-1
# mutates anything: fail-closed, never half-applied, however §8 Q1 is settled.
# Usage: _rename_assert_writable <dir> <what>
_rename_assert_writable() {
    local dir="$1" what="$2" t
    t=$(_rename_deelevated mktemp "$dir/.cco-wtest.XXXXXX" 2>/dev/null) \
        || refuse "Cannot write $what in this session ($dir is not writable by the cco store helper). Run '$what' on your host — nothing was changed."
    _rename_deelevated rm -f "$t" 2>/dev/null || true
}

# ── project.yml re-key (current project) ─────────────────────────────
# Rewrite <section>[].name <old>→<new> in EVERY owned+resolved member repo of
# <project> (project-scoped, ADR-0051 D1 — no cross-project fan-out). project.yml
# is replicated across a multi-repo project's members, so each owned copy is
# rewritten (mirrors cmd_project_rename's member loop). Echoes each changed repo
# path, one per line, so the caller can print the commit/push/sync reminder. The
# member enumeration comes from _project_iter_members, whose column 2 is the PROBE
# path (the container mount in operator mode — INV-F), so the rewrite reaches the
# mounted member instead of a non-existent host path. The write itself is
# de-elevated to ruid=claude (D-M4). Column 2 can be empty (unresolved member), so
# peel by hand (_peel_tab), never `IFS=$'\t' read` which folds the empty middle field.
# Usage: _rename_projectyml_current <project> <section> <old> <new>
_rename_projectyml_current() {
    local project="$1" section="$2" old="$3" new="$4"
    local _ln name path status yml
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        _peel_tab "$_ln" name path status
        case "$status" in synced|divergent) ;; *) continue ;; esac
        yml="$path/.cco/project.yml"
        [[ -f "$yml" ]] || continue
        if _rename_yaml_write_owned "$yml" "$section" "$old" "$new"; then
            printf '%s\n' "$path"
        fi
    done < <(_project_iter_members "$project")
}

# ── project.yml re-key (cross-project fan-out, pack) ─────────────────
# For a globally-scoped ref (pack), rewrite <section>[].name <old>→<new> in every
# project that references <old>, across all its owned+resolved members. A project
# is "affected" iff its resolved primary project.yml references <old> in <section>;
# an affected project with an unresolved member cannot have that copy rewritten and
# would drift under cco sync's clobber-guard, so it is surfaced for the strict
# guard. Echoes tab-tagged lines the caller consumes:
#   changed<TAB><repo-path>              a rewritten project.yml
#   unresolved<TAB><project><TAB><member>  an affected project's unresolved member
# Usage: _rename_fanout_projectyml <section> <old> <new>
_rename_fanout_projectyml() {
    local section="$1" old="$2" new="$3"
    local proj unit yml name path status _mln
    while IFS=$'\t' read -r proj unit yml; do
        _yaml_list_has_ref "$yml" "$section" "$old" || continue
        # _project_iter_members' column 2 (path) is EMPTY for an unresolved member, so
        # peel by hand — `IFS=$'\t' read` folds the empty middle field (tab is IFS
        # whitespace), collapsing "ghost\t\tunresolved" to name=ghost/path=unresolved/
        # status='', which NEVER matches the `unresolved)` arm and silently drops an
        # affected project's unresolved member from the strict guard (E6B-04 drift).
        while IFS= read -r _mln; do
            [[ -z "$_mln" ]] && continue
            _peel_tab "$_mln" name path status
            case "$status" in
                synced|divergent)
                    [[ -f "$path/.cco/project.yml" ]] || continue
                    if _yaml_rename_list_ref "$path/.cco/project.yml" "$section" "$old" "$new"; then
                        printf 'changed\t%s\n' "$path"
                    fi ;;
                unresolved)
                    printf 'unresolved\t%s\t%s\n' "$proj" "$name" ;;
            esac
        done < <(_project_iter_members "$proj")
    done < <(_project_foreach)
}

# ── Preview + confirm ────────────────────────────────────────────────
# Uniform destructive-confirm for the rename verbs (ADR-0029 D2): print a bold
# <title>, one "• <bullet>" per remaining arg, then _confirm_destructive. Returns
# its status (0 = proceed). Usage: _rename_preview_confirm <skip> <title> <bullet>...
_rename_preview_confirm() {
    local skip="$1" title="$2"; shift 2
    echo -e "${BOLD}${title}${NC}"
    local b
    for b in "$@"; do echo "  • $b"; done
    _confirm_destructive "$skip" "Proceed?"
}
