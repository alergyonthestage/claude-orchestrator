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

    local tmpf; tmpf=$(mktemp "${f}.XXXXXX")
    awk -v sec="${kind}:" -v key="  ${name}:" -v newline="  ${name}: [${csv}]" '
        $0 == sec { print; in_sec = 1; seen_key = 0; next }
        in_sec && /^[^ #]/ {
            if (!seen_key) { print newline; seen_key = 1 }
            in_sec = 0; print; next
        }
        in_sec && index($0, key) == 1 { print newline; seen_key = 1; next }
        { print }
        END { if (in_sec && !seen_key) print newline }
    ' "$f" > "$tmpf" && mv "$tmpf" "$f"
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
        project) echo 0 ;; pack) echo 1 ;; template) echo 2 ;;
        llms)    echo 3 ;; remote) echo 4 ;; *) echo 9 ;;
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
}

cmd_list() {
    local filter="" sort_by="" kind="" reverse=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h|help)
                cat <<'EOF'
Usage: cco list [<kind>] [--tag <tag>] [--sort kind|name|tag] [--reverse|-r]

Unified index of your resources. <kind> is one of:
  project | pack | template | llms | remote   (plural forms accepted)

  cco list                       Compact index of every resource (KIND NAME
                                 TAGS), ordered by kind then name.
  cco list <kind>                Detailed view for one kind (repos/status,
                                 resource counts, variants, …).
  cco list [<kind>] --tag <t>    Filter to resources carrying tag <t>.
  cco list [<kind>] --sort name  Sort by name (default: by kind, then name).
  cco list [<kind>] --sort tag   Sort by first tag (untagged last), then name.
  cco list [<kind>] --reverse    Reverse the chosen order (alias: -r).

Full detail for one resource: cco <kind> show <name>.
Tags are per-user (project/pack/template only); manage them with 'cco tag'.
EOF
                return 0
                ;;
            --tag)  [[ $# -lt 2 ]] && die "--tag requires a value."; filter="$2"; shift 2 ;;
            --sort) [[ $# -lt 2 ]] && die "--sort requires 'kind', 'name', or 'tag'."; sort_by="$2"
                    [[ "$sort_by" == kind || "$sort_by" == name || "$sort_by" == tag ]] \
                        || die "--sort must be 'kind', 'name', or 'tag'."
                    shift 2 ;;
            --reverse|-r)       reverse=1;         shift ;;
            project|projects)   kind="project";  shift ;;
            pack|packs)         kind="pack";      shift ;;
            template|templates) kind="template";  shift ;;
            llms)               kind="llms";      shift ;;
            remote|remotes)     kind="remote";    shift ;;
            -*) die "Unknown option: $1. Run 'cco list --help'." ;;
            *)  die "Unknown resource kind: $1. Use project|pack|template|llms|remote. Run 'cco list --help'." ;;
        esac
    done

    # A bare kind (no filter, no sort, no reverse) shows the rich per-kind view.
    if [[ -n "$kind" && -z "$filter" && -z "$sort_by" && -z "$reverse" ]]; then
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
    local rows="" rk rn tags tkind sortkey t found ftag namew=4 cap=30
    while IFS=$'\t' read -r rk rn; do
        [[ -z "$rk" ]] && continue
        # Output scoping (ADR-0043): in operator mode, hide resources outside the
        # session's access scope and count them for the trailing notice (INV-B).
        if ! _env_in_scope "$rk" "$rn"; then _env_note_hidden "$rk"; continue; fi
        tkind=$(_list_tag_kind "$rk"); tags=""
        [[ -n "$tkind" ]] && tags=$(_tags_get "$tkind" "$rn")
        if [[ -n "$filter" ]]; then
            found=false
            for t in $tags; do [[ "$t" == "$filter" ]] && { found=true; break; }; done
            [[ "$found" == true ]] || continue
        fi
        case "$sort_by" in
            name) sortkey="${rn}	${rk}" ;;
            tag)  ftag="${tags%% *}"
                  # tagged sort before untagged (0/1 prefix), then by first tag, then name.
                  if [[ -n "$tags" ]]; then sortkey="0${ftag}	${rn}"; else sortkey="1	${rn}"; fi ;;
            *)    sortkey="$(_list_kind_rank "$rk")	${rn}" ;;
        esac
        (( ${#rn} > namew )) && namew=${#rn}
        rows+="${sortkey}	${rk}	${rn}	${tags:-—}"$'\n'
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
    printf "${BOLD}%-10s %s %s${NC}\n" "KIND" "$(_fit_col "NAME" "$namew")" "TAGS"
    printf '%s' "$rows" | LC_ALL=C sort "${sortargs[@]}" | while IFS=$'\t' read -r _k1 _k2 rk rn tags; do
        printf '%-10s %s %s\n' "$rk" "$(_fit_col "$rn" "$namew")" "$tags"
    done
    # Trailing count-only notice on stderr (INV-B/C); no-op when nothing hidden.
    _env_flush_hidden_notice
}
