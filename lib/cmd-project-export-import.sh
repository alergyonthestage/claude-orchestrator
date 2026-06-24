#!/usr/bin/env bash
# lib/cmd-project-export-import.sh — Project export/import (the 2×2 local-transport
# cells for projects; ADR-0018 D2). Projects are NOT published/installed — they ride
# the code-repo remote (P13) — so a tar is the only out-of-band transport. Export
# bundles the committed <repo>/.cco/ minus the gitignored secrets.env (ADR-0024 D6);
# import bootstraps a repo's <repo>/.cco/ from such a tar and registers it in the
# index, like `cco init`.
#
# Provides: cmd_project_export(), cmd_project_import()
# Dependencies: colors.sh, utils.sh, yaml.sh, secrets.sh, paths.sh, index.sh,
#               cmd-resolve.sh (_resolve_find_unit_dir / _resolve_unit_dir_for_project)

# 2-pass secret scan over a <repo>/.cco/ tree (filename + content; *.example and the
# gitignored secrets.env are exempt — secrets.env is never bundled). Echoes the
# offending relative path on the first hit, returns 1 (block). Mirrors
# cmd-config.sh:_config_scan_staged.
_project_export_scan_secrets() {
    local cco_dir="$1" f rel hit
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        rel="${f#"$cco_dir"/}"
        [[ "$rel" == "secrets.env" ]] && continue
        [[ "$rel" == *.example ]] && continue
        if hit=$(_secret_match_filename "$rel" 2>/dev/null) && [[ -n "$hit" ]]; then
            printf '%s\t(filename matches %s)\n' "$rel" "$hit"; return 1
        fi
        if hit=$(_secret_match_content "$f" 2>/dev/null) && [[ -n "$hit" ]]; then
            printf '%s\t(content matches at line %s)\n' "$rel" "${hit%%:*}"; return 1
        fi
    done < <(find "$cco_dir" -type f 2>/dev/null)
    return 0
}

cmd_project_export() {
    local name="" output=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output|-o)
                [[ -z "${2:-}" ]] && die "--output requires a path"
                output="$2"; shift 2 ;;
            --help)
                cat <<'EOF'
Usage: cco project export [<name>] [--output <path>]

Export a project's committed config (<repo>/.cco/) as a .tar.gz snapshot. The
gitignored secrets.env is never bundled. With no name, exports the project
hosted in the current repo (cwd-first). Import it elsewhere with
`cco project import`. Projects are not published/installed — they ride the
code-repo remote (ADR-0018 D2).
EOF
                return 0 ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then name="$1"; shift
                else die "Unexpected argument: $1"; fi ;;
        esac
    done

    # Resolve the project's <repo> dir: by name via the index, else cwd-first.
    local repo_dir=""
    if [[ -n "$name" ]]; then
        repo_dir=$(_resolve_unit_dir_for_project "$name") \
            || die "Project '$name' not found (no resolved member repo). Run 'cco resolve $name'."
    else
        repo_dir=$(_resolve_find_unit_dir) \
            || die "Not inside a project repo. Run from a repo with .cco/project.yml, or pass a project name."
    fi

    local cco_dir="$repo_dir/.cco"
    [[ -f "$cco_dir/project.yml" ]] || die "No project config at $cco_dir/project.yml"
    local proj_name; proj_name=$(yml_get "$cco_dir/project.yml" "name")
    [[ -z "$proj_name" ]] && proj_name="$(basename "$repo_dir")"

    # Secret scan (blocking) — secrets.env is gitignored and excluded below.
    local leak
    if ! leak=$(_project_export_scan_secrets "$cco_dir"); then
        die "Refusing to export — potential secret detected:
  $leak
  Move secrets into .cco/secrets.env (gitignored, never bundled)."
    fi

    local archive="${output:-${proj_name}.tar.gz}"
    tar czf "$archive" -C "$repo_dir" \
        --exclude='.cco/secrets.env' \
        --exclude='.cco/install-tmp' \
        .cco
    ok "Exported project '$proj_name' to $archive"
}

cmd_project_import() {
    local archive="" force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            --help)
                cat <<'EOF'
Usage: cco project import <archive> [--force]

Import a project from a .tar.gz snapshot (produced by `cco project export`)
into the current repo: unpacks <repo>/.cco/ and registers it in the index.
Refuses to overwrite an existing .cco/ unless --force. Re-create secrets.env
from secrets.env.example after import.
EOF
                return 0 ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$archive" ]]; then archive="$1"; shift
                else die "Unexpected argument: $1"; fi ;;
        esac
    done

    [[ -z "$archive" ]] && die "Usage: cco project import <archive>"
    [[ -f "$archive" ]] || die "Archive not found: $archive"

    local target_repo; target_repo="$(pwd -P)"
    local target_cco="$target_repo/.cco"
    if [[ -f "$target_cco/project.yml" && "$force" != true ]]; then
        die "$target_cco already exists — refusing to clobber. Use --force, or 'cco join' to add this repo to an existing project."
    fi

    # Extract to a temp dir, validate it carries a project .cco/.
    local tmpdir; tmpdir=$(mktemp -d)
    tar xzf "$archive" -C "$tmpdir" 2>/dev/null \
        || { rm -rf "$tmpdir"; die "Failed to extract archive: $archive"; }
    [[ -f "$tmpdir/.cco/project.yml" ]] \
        || { rm -rf "$tmpdir"; die "Archive is not a project export (missing .cco/project.yml)"; }

    local proj_name; proj_name=$(yml_get "$tmpdir/.cco/project.yml" "name")
    [[ -z "$proj_name" ]] && { rm -rf "$tmpdir"; die "Could not determine project name from archive"; }

    # F12 name-uniqueness: the name must not already bind a DIFFERENT repo.
    local existing_path; existing_path=$(_index_get_path "$proj_name" 2>/dev/null || true)
    if [[ -n "$existing_path" && "$existing_path" != "$target_repo" ]]; then
        rm -rf "$tmpdir"
        die "A project named '$proj_name' is already registered to $existing_path. 'cco forget' it first, or rename the imported project."
    fi

    # Place the config into the target repo, then register it in the index
    # (host this project in the current repo — mirrors `cco init`).
    rm -rf "$target_cco"
    cp -R "$tmpdir/.cco" "$target_cco"
    rm -rf "$tmpdir"

    _index_set_path "$proj_name" "$target_repo"
    _index_set_project_repos "$proj_name" "$proj_name"

    ok "Imported project '$proj_name' into $target_cco"
    info "Re-create secrets from .cco/secrets.env.example if the project needs them."
}
