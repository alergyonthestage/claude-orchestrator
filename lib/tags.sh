#!/usr/bin/env bash
# lib/tags.sh — per-user tag registry (DATA) + `cco tag` / `cco list`.
#
# Tags replace the legacy vault profiles (ADR-0010/0011): a resource (pack,
# project, or template) carries zero or more transversal, multi-valued tags.
# Tags are INTERNAL, CLI-canonical (ADR-0011) — not hand-edited config — so the
# registry lives in the DATA bucket (<data>/cco/tags.yml; ADR-0015), per-user,
# synced cross-PC (Axis-1) but NEVER team-shared: tags appear in no pack.yml /
# project.yml / manifest / index, and there is no `!tags.yml` allowlist line.
#
# Registry format (design §2.2) — typed keys -> name -> inline [tags] list:
#   packs:
#     my-api: [work, infra]
#   projects:
#     cave-infra: [prod]
#   templates:
#     base-go: []
#
# `cco tag add/rm <name> <tag>` auto-detect the kind (project via the STATE index,
# pack/template via ~/.cco); --pack/--project/--template force it when a name is
# ambiguous. `cco list [--tag <t>]` is the unified discovery surface.
#
# Provides: cmd_tag(), cmd_list(), _tags_file(), _tags_get(), _tags_add(),
#   _tags_remove(), _tags_forget(), _tags_resources_with(), _tags_all(),
#   _tags_detect_kind()
# Dependencies: colors.sh, paths.sh (_cco_data_dir/_cco_config_dir),
#   index.sh (_index_get_project_repos/_index_list_projects)

# Absolute path to the per-user tag registry (DATA).
_tags_file() { printf '%s\n' "$(_cco_data_dir)/tags.yml"; }

_tags_ensure_file() {
    local f; f=$(_tags_file)
    [[ -f "$f" ]] && return 0
    mkdir -p "$(dirname "$f")"
    printf '# Per-user tag registry (DATA) — managed by `cco tag add/rm`; read by `cco list --tag`.\n' > "$f"
}

# Echo the space-separated tags bound to <kind>/<name>, or empty if none.
# Usage: _tags_get <kind> <name>
_tags_get() {
    local kind="$1" name="$2" f
    f=$(_tags_file)
    [[ -f "$f" ]] || return 0
    awk -v sec="${kind}:" -v key="  ${name}:" '
        $0 == sec { in_sec = 1; next }
        in_sec && /^[^ #]/ { in_sec = 0 }
        in_sec && index($0, key) == 1 {
            line = $0
            sub(/^[^[]*\[/, "", line)   # strip up to and including the [
            sub(/\].*$/, "", line)      # strip the ] and trailing
            gsub(/,/, " ", line)        # CSV -> space-separated
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            print line
            exit
        }
    ' "$f"
}

# Rewrite (or insert) the <kind>/<name> entry with the given space-separated tag
# set (empty set => "[]"). The typed section is created if missing. Atomic.
# Usage: _tags_set <kind> <name> <space-separated-tags>
_tags_set() {
    local kind="$1" name="$2" tags="$3" f csv
    _tags_ensure_file
    f=$(_tags_file)
    # Normalize to a "[a, b]" inline list.
    csv=$(printf '%s' "$tags" | awk '{ for (i=1;i<=NF;i++){ printf "%s%s", (i>1?", ":""), $i } }')
    grep -qE "^${kind}:" "$f" 2>/dev/null || printf '%s:\n' "$kind" >> "$f"

    # Defense-in-depth (R5): fail loudly (exit 1) if the DATA registry is read-only
    # — the operator write-gate refuses tag writes below edit-global before we get
    # here, but a mktemp/awk/mv that silently fails must not let the caller echo
    # success onto a tree it never wrote (closes S5-01 at the source).
    local tmpf; tmpf=$(mktemp "${f}.XXXXXX") || die "Cannot write tags registry at $f (read-only?)."
    awk -v sec="${kind}:" -v key="  ${name}:" -v newline="  ${name}: [${csv}]" '
        $0 == sec { print; in_sec = 1; seen_key = 0; next }
        in_sec && /^[^ #]/ {
            if (!seen_key) { print newline; seen_key = 1 }
            in_sec = 0; print; next
        }
        in_sec && index($0, key) == 1 { print newline; seen_key = 1; next }
        { print }
        END { if (in_sec && !seen_key) print newline }
    ' "$f" > "$tmpf" && mv "$tmpf" "$f" || { rm -f "$tmpf"; die "Failed to update tags registry at $f (read-only?)."; }
}

# Add <tag> to <kind>/<name> (idempotent — no duplicate). Usage: _tags_add <kind> <name> <tag>
_tags_add() {
    local kind="$1" name="$2" tag="$3" cur t
    cur=$(_tags_get "$kind" "$name")
    for t in $cur; do [[ "$t" == "$tag" ]] && return 0; done
    _tags_set "$kind" "$name" "$cur $tag"
}

# Remove <tag> from <kind>/<name> (no-op if absent). Usage: _tags_remove <kind> <name> <tag>
_tags_remove() {
    local kind="$1" name="$2" tag="$3" cur t out=""
    cur=$(_tags_get "$kind" "$name")
    for t in $cur; do [[ "$t" == "$tag" ]] || out="$out $t"; done
    _tags_set "$kind" "$name" "$out"
}

# Remove the ENTIRE <kind>/<name> entry from the registry (no-op if absent;
# atomic). The lifecycle delete-cascade primitive (ADR-0021 Dec.2/4): used by
# `cco pack/template remove` and `cco forget` to drop a resource's tag binding
# when the resource itself is gone — distinct from _tags_remove, which drops a
# single tag while keeping the entry. Usage: _tags_forget <kind> <name>
_tags_forget() {
    local kind="$1" name="$2" f
    f=$(_tags_file)
    [[ -f "$f" ]] || return 0

    local tmpf; tmpf=$(mktemp "${f}.XXXXXX")
    awk -v sec="${kind}:" -v key="  ${name}:" '
        $0 == sec { print; in_sec = 1; next }
        in_sec && /^[^ #]/ { in_sec = 0 }
        in_sec && index($0, key) == 1 { next }
        { print }
    ' "$f" > "$tmpf" && mv "$tmpf" "$f"
}

# Re-key a resource's tag entry from <old> to <new> within <kind>, carrying the
# tag set over (the identity re-key primitive for `cco project rename`, ADR-0031
# D2). No-op when <old> has no tags (nothing to carry). Usage: _tags_rename <kind> <old> <new>
_tags_rename() {
    local kind="$1" old="$2" new="$3" cur
    cur=$(_tags_get "$kind" "$old")
    [[ -z "$cur" ]] && return 0
    _tags_set "$kind" "$new" "$cur"
    _tags_forget "$kind" "$old"
}

# Emit "<kind>\t<name>\t<space-separated-tags>" for every tagged resource.
_tags_all() {
    local f; f=$(_tags_file)
    [[ -f "$f" ]] || return 0
    awk '
        /^[a-z]+:[ \t]*$/ { kind = $0; sub(/:.*/, "", kind); next }
        /^  [^ ].*:/ {
            name = $0; sub(/^  /, "", name); sub(/:.*/, "", name)
            tags = $0; sub(/^[^[]*\[/, "", tags); sub(/\].*$/, "", tags)
            gsub(/,/, " ", tags); gsub(/^[ \t]+|[ \t]+$/, "", tags)
            if (kind != "") printf "%s\t%s\t%s\n", kind, name, tags
        }
    ' "$f"
}

# Emit "<kind>\t<name>" for resources carrying <tag>. Usage: _tags_resources_with <tag>
_tags_resources_with() {
    local tag="$1" kind name tags t
    while IFS=$'\t' read -r kind name tags; do
        for t in $tags; do
            [[ "$t" == "$tag" ]] && { printf '%s\t%s\n' "$kind" "$name"; break; }
        done
    done < <(_tags_all)
}

# Detect the kind (packs|projects|templates) a resource <name> belongs to. Echoes
# the kind on a unique match; on ambiguity or no match returns non-zero and echoes
# nothing (the caller reports). Usage: _tags_detect_kind <name>
_tags_detect_kind() {
    local name="$1" cfg matches=""
    cfg=$(_cco_config_dir)
    [[ -n "$(_index_get_project_repos "$name" 2>/dev/null)" ]] && matches="$matches projects"
    [[ -d "$cfg/packs/$name" ]]     && matches="$matches packs"
    [[ -d "$cfg/templates/$name" ]] && matches="$matches templates"
    matches="${matches# }"
    case "$matches" in
        "")          return 1 ;;          # not found
        *" "*)       printf '%s\n' "$matches"; return 2 ;;  # ambiguous (multi)
        *)           printf '%s\n' "$matches"; return 0 ;;  # unique
    esac
}

# ── cco tag ───────────────────────────────────────────────────────────

cmd_tag() {
    local action="${1:-}"; shift || true
    case "$action" in
        ""|--help|-h|help)
            cat <<'EOF'
Usage: cco tag add    <name> <tag> [--pack|--project|--template]
       cco tag remove <name> <tag> [--pack|--project|--template]   (alias: rm)

Manage the per-user tags of a pack, project, or template. The kind is detected
automatically (project via the index, pack/template via ~/.cco); pass --pack,
--project, or --template to disambiguate when a name exists in more than one.

Tags are private to you, synced across your machines, never shared with a team.
List by tag with: cco list --tag <tag>
EOF
            return 0
            ;;
        add|rm|remove) ;;
        *) die "Unknown 'cco tag' command: $action. Use 'cco tag add' or 'cco tag remove'." ;;
    esac

    local name="" tag="" forced_kind=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pack)     forced_kind="packs";     shift ;;
            --project)  forced_kind="projects";  shift ;;
            --template) forced_kind="templates"; shift ;;
            -*) die "Unknown option: $1. Run 'cco tag --help'." ;;
            *)
                if [[ -z "$name" ]]; then name="$1"
                elif [[ -z "$tag" ]]; then tag="$1"
                else die "Unexpected argument: $1"; fi
                shift
                ;;
        esac
    done
    [[ -z "$name" || -z "$tag" ]] && die "Usage: cco tag $action <name> <tag> [--pack|--project|--template]"

    local kind="$forced_kind" rc
    if [[ -z "$kind" ]]; then
        kind=$(_tags_detect_kind "$name"); rc=$?
        case $rc in
            1) die "No pack, project, or template named '$name' found. Create it first, or check the name." ;;
            2) die "'$name' is ambiguous ($kind) — disambiguate with --pack / --project / --template." ;;
        esac
    fi

    if [[ "$action" == "add" ]]; then
        _tags_add "$kind" "$name" "$tag"
        ok "tagged ${kind%s} '$name' with '$tag'"
    else
        _tags_remove "$kind" "$name" "$tag"
        ok "removed tag '$tag' from ${kind%s} '$name'"
    fi
}

# ── cco list ──────────────────────────────────────────────────────────

# ── cco list — the unified resource index (ADR-0029 D1) ────────────────
# `cco list` is the single listing surface: a compact cross-resource index
# (KIND/NAME/TAGS) by default, the rich per-kind view for a bare `cco list
# <kind>`, and a sortable/filterable index whenever --tag/--sort is given. The
# per-noun `cco <noun> list` verbs were removed (stubs redirect here).

# Canonical kind order for the compact index (lower = first).
_list_kind_rank() {
    case "$1" in
        project) echo 0 ;; builtin) echo 1 ;; pack) echo 2 ;; template) echo 3 ;;
        llms)    echo 4 ;; remote) echo 5 ;; *) echo 9 ;;
    esac
}

# Map a singular row-kind to its tags.yml section. Only project/pack/template
# are taggable (ADR-0011); llms/remote have no tags.
_list_tag_kind() {
    case "$1" in
        project) echo projects ;; pack) echo packs ;; template) echo templates ;;
        *)       echo "" ;;
    esac
}

# Emit "<kind>\t<name>" for the requested kind ("" = every kind). Enumerates
# the same sources the per-kind listers use (STATE index, ~/.cco stores, the
# remotes registry); guards empty globs under `set -u`.
_list_collect() {
    local want="$1" d b k rn rf
    if [[ -z "$want" || "$want" == project ]]; then
        while IFS='=' read -r b _; do
            [[ -z "$b" || "$b" == _template ]] && continue
            printf 'project\t%s\n' "$b"
        done < <(_index_list_projects)
    fi
    if [[ -z "$want" || "$want" == pack ]]; then
        for d in "$PACKS_DIR"/*/; do [[ -d "$d" ]] || continue; printf 'pack\t%s\n' "$(basename "$d")"; done
    fi
    if [[ -z "$want" || "$want" == template ]]; then
        # native + user, project + pack kinds; dedup by name.
        { for k in project pack; do
            for d in "$TEMPLATES_DIR/$k"/*/ "$NATIVE_TEMPLATES_DIR/$k"/*/; do
                [[ -d "$d" ]] || continue; basename "$d"
            done
          done; } | LC_ALL=C sort -u | while IFS= read -r b; do
            [[ -n "$b" ]] && printf 'template\t%s\n' "$b"
        done
    fi
    if [[ -z "$want" || "$want" == llms ]]; then
        for d in "$LLMS_DIR"/*/; do
            [[ -d "$d" ]] || continue; b=$(basename "$d"); [[ "$b" == .cco ]] && continue
            printf 'llms\t%s\n' "$b"
        done
    fi
    if [[ -z "$want" || "$want" == remote ]]; then
        rf=$(_remotes_file)
        if [[ -f "$rf" ]]; then
            while IFS='=' read -r rn _; do
                [[ -z "$rn" || "$rn" == \#* ]] && continue
                printf 'remote\t%s\n' "$rn"
            done < "$rf"
        fi
    fi
    # Internal built-ins (R3): reserved framework sessions, not index rows. Emitted
    # in the unified view and for the explicit `builtin` kind. cmd_list decides
    # whether to keep a STOPPED one (running-only default vs --include-internal).
    if [[ -z "$want" || "$want" == builtin ]]; then
        while IFS= read -r b; do
            [[ -n "$b" ]] && printf 'builtin\t%s\n' "$b"
        done < <(_cco_internal_builtins)
    fi
}

# Sort rank for the compact-list STATUS column: running first, then stopped,
# unknown, and the non-project '-' placeholder last.
_list_status_rank() {
    case "$1" in running) printf 0 ;; stopped) printf 1 ;; unknown) printf 2 ;; *) printf 3 ;; esac
}

# Render a fixed-width, color-coded STATUS cell padded by VISIBLE length (so the
# color escapes never skew alignment). running=green, unknown=yellow, else plain.
_list_status_cell() {
    local s="$1" w=8 color="" pad
    case "$s" in running) color="$GREEN" ;; unknown) color="$YELLOW" ;; esac
    pad=$(( w - ${#s} )); (( pad < 0 )) && pad=0
    printf '%b%s%b%*s' "$color" "$s" "${color:+$NC}" "$pad" ""
}

cmd_list() {
    local filter="" sort_by="" kind="" reverse="" include_internal=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h|help)
                cat <<'EOF'
Usage: cco list [<kind>] [--tag <tag>] [--sort kind|name|tag] [--reverse|-r]
                [--include-internal]

Unified index of your resources. <kind> is one of:
  project | pack | template | llms | remote   (plural forms accepted)
  builtin                                      (internal sessions, see below)

  cco list                       Compact index of every resource (KIND NAME
                                 STATUS TAGS), ordered by kind then name.
  cco list <kind>                Detailed view for one kind (repos/status,
                                 resource counts, variants, …).
  cco list [<kind>] --tag <t>    Filter to resources carrying tag <t>.
  cco list [<kind>] --sort name  Sort by name (default: by kind, then name).
  cco list [<kind>] --sort tag   Sort by first tag (untagged last), then name.
  cco list [<kind>] --sort status  Sort by session status (running first), then name.
  cco list [<kind>] --reverse    Reverse the chosen order (alias: -r).
  cco list --include-internal    Also list internal built-ins (config-editor,
                                 tutorial) even when stopped.
  cco list builtin               Only the internal built-ins, with status.

STATUS is a session state (running | stopped | unknown) for projects and
built-ins; other kinds show '—'. In-container, `unknown` means the running
registry is out of scope/unreachable — never a false `stopped` (ADR-0045).
Internal built-ins (KIND 'builtin') are the reserved `cco start config-editor`
/`tutorial` sessions; they are shown only when RUNNING by default (add
--include-internal, or `cco list builtin`, to see them all).

Full detail for one resource: cco <kind> show <name>.
Tags are per-user (project/pack/template only); manage them with 'cco tag'.
EOF
                return 0
                ;;
            --tag)  [[ $# -lt 2 ]] && die "--tag requires a value."; filter="$2"; shift 2 ;;
            --sort) [[ $# -lt 2 ]] && die "--sort requires 'kind', 'name', 'tag', or 'status'."; sort_by="$2"
                    [[ "$sort_by" == kind || "$sort_by" == name || "$sort_by" == tag || "$sort_by" == status ]] \
                        || die "--sort must be 'kind', 'name', 'tag', or 'status'."
                    shift 2 ;;
            --reverse|-r)       reverse=1;         shift ;;
            --include-internal) include_internal=1; shift ;;
            project|projects)   kind="project";  shift ;;
            pack|packs)         kind="pack";      shift ;;
            template|templates) kind="template";  shift ;;
            llms)               kind="llms";      shift ;;
            remote|remotes)     kind="remote";    shift ;;
            builtin|builtins|internal) kind="builtin"; include_internal=1; shift ;;
            -*) die "Unknown option: $1. Run 'cco list --help'." ;;
            *)  die "Unknown resource kind: $1. Use project|pack|template|llms|remote. Run 'cco list --help'." ;;
        esac
    done

    # A bare kind (no filter, no sort, no reverse) shows the rich per-kind view.
    # 'builtin' has no dedicated rich view — it always flows to the compact index.
    if [[ -n "$kind" && "$kind" != builtin && -z "$filter" && -z "$sort_by" && -z "$reverse" ]]; then
        # R3: route the bare per-kind view through the scope layer too — the
        # aggregate `cco list` path already filters per row, but this branch bypassed
        # it, letting a global-class kind (template/remote) leak at read-project.
        # Project-class kinds fall through and filter their own rows + notice.
        _env_require_kind_visible "$kind"
        case "$kind" in
            project)  cmd_project_list ;;
            pack)     cmd_pack_list ;;
            template) cmd_template_list ;;
            llms)     _llms_list ;;
            remote)   _cmd_remote_list ;;
        esac
        return $?
    fi

    # Compact unified index (default, or whenever --tag/--sort/--reverse/scoped-with-filter).
    [[ -z "$sort_by" ]] && sort_by="kind"
    local rows="" rk rn tags tkind sortkey t found ftag namew=4 cap=30 st_raw
    while IFS=$'\t' read -r rk rn; do
        [[ -z "$rk" ]] && continue
        if [[ "$rk" == builtin ]]; then
            # Built-ins (R3) are framework sessions, not the user's private config →
            # never scope-hidden and never tagged. Default keeps only RUNNING ones
            # (clean list); --include-internal / `cco list builtin` shows all with status.
            st_raw=$(_cco_session_status "$rn"); tags=""
            [[ -z "$include_internal" && "$st_raw" != running ]] && continue
        else
            # Output scoping (ADR-0043): in operator mode, hide resources outside the
            # session's access scope and count them for the trailing notice (INV-B).
            if ! _env_in_scope "$rk" "$rn"; then _env_note_hidden "$rk"; continue; fi
            tkind=$(_list_tag_kind "$rk"); tags=""
            [[ -n "$tkind" ]] && tags=$(_tags_get "$tkind" "$rn")
            # Session status is a project-only concept (B3, tri-state B4); other kinds
            # carry the '-' placeholder. Rows already passed _env_in_scope, so a status
            # read here never reveals an out-of-scope project.
            if [[ "$rk" == project ]]; then st_raw=$(_cco_session_status "$rn"); else st_raw="-"; fi
        fi
        if [[ -n "$filter" ]]; then
            found=false
            for t in $tags; do [[ "$t" == "$filter" ]] && { found=true; break; }; done
            [[ "$found" == true ]] || continue
        fi
        case "$sort_by" in
            name)   sortkey="${rn}	${rk}" ;;
            tag)    ftag="${tags%% *}"
                    # tagged sort before untagged (0/1 prefix), then by first tag, then name.
                    if [[ -n "$tags" ]]; then sortkey="0${ftag}	${rn}"; else sortkey="1	${rn}"; fi ;;
            status) sortkey="$(_list_status_rank "$st_raw")	${rn}" ;;
            *)      sortkey="$(_list_kind_rank "$rk")	${rn}" ;;
        esac
        (( ${#rn} > namew )) && namew=${#rn}
        rows+="${sortkey}	${rk}	${rn}	${st_raw}	${tags:-—}"$'\n'
    done < <(_list_collect "$kind")

    if [[ -z "$rows" ]]; then
        # Nothing visible: if scope hid everything, the notice explains why
        # (hidden ≠ absent, INV-B); otherwise there is genuinely nothing.
        if [[ "${_ENV_HIDDEN_ANY:-}" == "1" ]]; then
            _env_flush_hidden_notice
        elif [[ -n "$filter" ]]; then
            info "No resources tagged '$filter'."
        else
            info "Nothing to list yet."
        fi
        return 0
    fi
    (( namew > cap )) && namew=$cap

    local -a sortargs=(-t'	' -k1,2); [[ -n "$reverse" ]] && sortargs+=(-r)
    printf "${BOLD}%-10s %s %-8s %s${NC}\n" "KIND" "$(_fit_col "NAME" "$namew")" "STATUS" "TAGS"
    printf '%s' "$rows" | LC_ALL=C sort "${sortargs[@]}" | while IFS=$'\t' read -r _k1 _k2 rk rn st_raw tags; do
        printf '%-10s %s %s %s\n' "$rk" "$(_fit_col "$rn" "$namew")" "$(_list_status_cell "$st_raw")" "$tags"
    done
    # Trailing count-only notice on stderr (INV-B/C); no-op when nothing hidden.
    _env_flush_hidden_notice
}
