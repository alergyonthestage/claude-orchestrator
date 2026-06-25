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
        ""|--help|help)
            cat <<'EOF'
Usage: cco tag add <name> <tag> [--pack|--project|--template]
       cco tag rm  <name> <tag> [--pack|--project|--template]

Manage the per-user tags of a pack, project, or template. The kind is detected
automatically (project via the index, pack/template via ~/.cco); pass --pack,
--project, or --template to disambiguate when a name exists in more than one.

Tags are private to you, synced across your machines, never shared with a team.
List by tag with: cco list --tag <tag>
EOF
            return 0
            ;;
        add|rm) ;;
        *) die "Unknown 'cco tag' command: $action. Use 'cco tag add' or 'cco tag rm'." ;;
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

cmd_list() {
    local filter=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|help)
                cat <<'EOF'
Usage: cco list [--tag <tag>]

List your packs, projects, and templates with their tags. With --tag, show only
resources carrying that tag.
EOF
                return 0
                ;;
            --tag) [[ $# -lt 2 ]] && die "--tag requires a value."; filter="$2"; shift 2 ;;
            -*) die "Unknown option: $1. Run 'cco list --help'." ;;
            *)  die "Unexpected argument: $1. Run 'cco list --help'." ;;
        esac
    done

    if [[ -n "$filter" ]]; then
        local kind name any=false
        echo -e "${BOLD}KIND        NAME${NC}"
        while IFS=$'\t' read -r kind name; do
            [[ -z "$kind" ]] && continue
            any=true
            printf '%-11s %s\n' "${kind%s}" "$name"
        done < <(_tags_resources_with "$filter")
        $any || info "no resources tagged '$filter'"
        return 0
    fi

    # Full listing: every tagged resource (the registry is the discovery surface).
    local kind name tags any=false
    echo -e "${BOLD}KIND        NAME                      TAGS${NC}"
    while IFS=$'\t' read -r kind name tags; do
        [[ -z "$kind" ]] && continue
        any=true
        printf '%-11s %-25s %s\n' "${kind%s}" "$name" "${tags:-—}"
    done < <(_tags_all)
    $any || info "no tagged resources yet — add one with 'cco tag add <name> <tag>'"
}
