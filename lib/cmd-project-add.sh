#!/usr/bin/env bash
# lib/cmd-project-add.sh — cco project add <repo|mount|llms|pack> (ADR-0023 D3)
#
# Embed-at-add: the P14 layer-a discoverable surface. Adds a referenced
# resource's machine-agnostic COORDINATE (name + url[/ref/variant/target/...])
# into the cwd project's <repo>/.cco/project.yml, and — with one-shot --path —
# also writes the machine-local name->path binding into the STATE index, in the
# same call. No real path ever enters the manifest (AD3/G8): --path touches only
# the index.
#
#   cco project add repo  <name> [--url --ref] [--path <p>]
#   cco project add mount <name> [--url --ref --target --readonly] [--path <p>]
#   cco project add llms  <name>  --url <u> [--variant <v>]
#   cco project add pack  <name> [--url --ref]
#
# cwd-first (the cwd/ancestor .cco/project.yml owns the add); --project <name>
# resolves a unit by index membership. url auto-derives from `git remote get-url
# origin` when --path is a clone and --url is omitted (ADR-0017 D1).
#
# This is the generic embed surface built on the P0 index/coordinate substrate;
# the pack-resolution BACKEND is P4/P5 (ADR-0022/F15). The legacy
# `cco project add-pack <project> <pack>` (central layout) is kept as the
# deprecated alias of `cco project add pack` and is removed at the P3 cutover.
#
# Provides: cmd_project_add()
# Dependencies: colors.sh, utils.sh (expand_path), index.sh (_index_set_path),
#   cmd-resolve.sh (_resolve_find_unit_dir/_resolve_unit_dir_for_project/
#   _resolve_to_abs)

# True (exit 0) iff <section> in <file> already has an entry named <name>
# (matches both the coordinate form "- name: X" and the legacy "- X").
_yml_section_has_name() {
    local file="$1" section="$2" name="$3"
    awk -v sec="$section" -v target="$name" '
        $0 == sec":" { in_sec=1; next }
        in_sec && /^[^ #]/ { exit }
        in_sec && /^  - name:/ {
            line=$0; sub(/^  - name:[[:space:]]*/, "", line); gsub(/["\047[:space:]]/, "", line)
            if (line == target) { found=1; exit }
            next
        }
        in_sec && /^  - / {
            line=$0; sub(/^  - */, "", line); gsub(/["\047[:space:]]/, "", line)
            if (line == target) { found=1; exit }
        }
        END { exit !found }
    ' "$file"
}

# Append a coordinate entry to <section> of a project.yml/pack.yml. <name> is
# the entry's name:; remaining args are "key=value" 4-space sub-fields (empty
# values skipped). Creates the section if absent; upgrades a "section: []" stub.
# Usage: _yml_append_coord <file> <section> <name> [key=value ...]
_yml_append_coord() {
    local file="$1" section="$2" name="$3"; shift 3
    local block="  - name: $name"
    local kv k v
    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        [[ -z "$v" ]] && continue
        block+=$'\n'"    $k: $v"
    done

    if grep -q "^${section}: *\[\]" "$file" 2>/dev/null; then
        CCO_BLK="$block" awk -v sec="$section" '
            $0 ~ ("^" sec ": *\\[\\]") { print sec ":"; print ENVIRON["CCO_BLK"]; next }
            { print }
        ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    elif grep -q "^${section}:" "$file" 2>/dev/null; then
        CCO_BLK="$block" awk -v sec="$section" '
            $0 == sec":" { in_sec=1; print; next }
            in_sec && /^[^ #]/ { if (!ins) { print ENVIRON["CCO_BLK"]; ins=1 } in_sec=0; print; next }
            { print }
            END { if (in_sec && !ins) print ENVIRON["CCO_BLK"] }
        ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    else
        { printf '\n%s:\n' "$section"; printf '%s\n' "$block"; } >> "$file"
    fi
}

cmd_project_add() {
    local restype="${1:-}"
    case "$restype" in
        ""|--help|-h)
            cat <<'EOF'
Usage: cco project add <repo|mount|llms|pack> <name> [options]

Embed a referenced resource's coordinate into the current project's
.cco/project.yml (cwd-first). With --path, also bind the machine-local path in
the index (repo/mount only). No real path is ever written into project.yml.

Resource flags:
  repo   --url <u> --ref <r>                  [--path <p>]
  mount  --url <u> --ref <r> --target <t> --readonly  [--path <p>]
  llms   --url <u> --variant <v>              (url required)
  pack   --url <u> --ref <r>

Options:
  --path <p>     Bind name -> absolute path in the STATE index (repo/mount)
  --project <n>  Operate on a named project instead of the cwd one

When --path is a git clone and --url is omitted, the url is derived from
'git remote get-url origin'.
EOF
            return 0
            ;;
    esac
    shift
    case "$restype" in
        repo|mount|llms|pack) ;;
        *) die "Unknown resource type '$restype'. Use: cco project add <repo|mount|llms|pack> <name>." ;;
    esac

    local name="" url="" ref="" variant="" target="" path="" ro="" project=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url)      [[ $# -lt 2 ]] && die "--url requires a value";     url="$2";     shift 2 ;;
            --ref)      [[ $# -lt 2 ]] && die "--ref requires a value";     ref="$2";     shift 2 ;;
            --variant)  [[ $# -lt 2 ]] && die "--variant requires a value"; variant="$2"; shift 2 ;;
            --target)   [[ $# -lt 2 ]] && die "--target requires a value";  target="$2";  shift 2 ;;
            --path)     [[ $# -lt 2 ]] && die "--path requires a value";    path="$2";    shift 2 ;;
            --project)  [[ $# -lt 2 ]] && die "--project requires a value"; project="$2"; shift 2 ;;
            --readonly) ro="true"; shift ;;
            --help|-h)     cmd_project_add --help; return 0 ;;
            -*) die "Unknown option: $1. Run 'cco project add --help'." ;;
            *)
                if [[ -z "$name" ]]; then name="$1"; shift; else die "Unexpected argument: $1"; fi
                ;;
        esac
    done
    [[ -z "$name" ]] && die "Usage: cco project add $restype <name> [options]"

    # Flag applicability per resource type.
    case "$restype" in
        repo)
            [[ -n "$variant" ]] && die "--variant is not valid for repo"
            [[ -n "$target" || -n "$ro" ]] && die "--target/--readonly are not valid for repo"
            ;;
        mount)
            [[ -n "$variant" ]] && die "--variant is not valid for mount"
            ;;
        llms)
            [[ -n "$ref" || -n "$target" || -n "$ro" ]] && die "--ref/--target/--readonly are not valid for llms"
            [[ -n "$path" ]] && die "llms has no local path — use 'cco llms install' for content"
            [[ -z "$url" ]] && die "llms requires --url (it is mandatory; ADR-0017 D1)"
            ;;
        pack)
            [[ -n "$variant" || -n "$target" || -n "$ro" ]] && die "--variant/--target/--readonly are not valid for pack"
            [[ -n "$path" ]] && die "--path is not valid for pack (a pack's local copy lives under ~/.cco/packs)"
            ;;
    esac

    # Locate the target manifest (cwd-first; --project by index membership).
    local unit_dir
    if [[ -n "$project" ]]; then
        unit_dir=$(_resolve_unit_dir_for_project "$project") \
            || die "Project '$project' is not resolvable — run 'cco resolve --scan <dir>' first."
    else
        unit_dir=$(_resolve_find_unit_dir) \
            || die "No .cco/project.yml in the current directory or its parents. Run from a configured repo or pass --project <name>."
    fi
    local manifest="$unit_dir/.cco/project.yml"

    local section
    case "$restype" in
        repo)  section="repos" ;;
        mount) section="extra_mounts" ;;
        llms)  section="llms" ;;
        pack)  section="packs" ;;
    esac

    if _yml_section_has_name "$manifest" "$section" "$name"; then
        die "$restype '$name' is already present in $section — edit $manifest to change it."
    fi

    # url auto-derivation from origin (repo/mount with --path, no explicit --url).
    if [[ -z "$url" && -n "$path" ]]; then
        local _abs; _abs=$(_resolve_to_abs "$path")
        if git -C "$_abs" rev-parse --git-dir >/dev/null 2>&1; then
            url=$(git -C "$_abs" remote get-url origin 2>/dev/null || true)
            [[ -n "$url" ]] && info "derived url from origin: $url"
        fi
    fi

    # Build the coordinate sub-fields per type and embed them.
    local -a fields=()
    case "$restype" in
        repo|pack)
            [[ -n "$url" ]] && fields+=("url=$url")
            [[ -n "$ref" ]] && fields+=("ref=$ref")
            ;;
        mount)
            [[ -n "$url" ]]    && fields+=("url=$url")
            [[ -n "$ref" ]]    && fields+=("ref=$ref")
            [[ -n "$target" ]] && fields+=("target=$target")
            [[ -n "$ro" ]]     && fields+=("readonly=$ro")
            ;;
        llms)
            fields+=("url=$url")
            [[ -n "$variant" ]] && fields+=("variant=$variant")
            ;;
    esac
    _yml_append_coord "$manifest" "$section" "$name" ${fields[@]+"${fields[@]}"}

    # One-shot --path -> STATE index (repo/mount only).
    if [[ -n "$path" ]]; then
        local abs; abs=$(_resolve_to_abs "$path")
        _index_set_path "$name" "$abs"
        ok "bound $name -> $abs (index)"
    fi
    ok "added $restype '$name' to $(basename "$unit_dir")/.cco/project.yml"
}
