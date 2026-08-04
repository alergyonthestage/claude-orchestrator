#!/usr/bin/env bash
# lib/cmd-project-export-import.sh — Project export/import (the 2×2 local-transport
# cells for projects; ADR-0018 D2). Projects are NOT published/installed — they ride
# the code-repo remote (P13) — so a tar is the only out-of-band transport. Export
# bundles the committed <repo>/.cco/ minus the gitignored secrets.env (ADR-0024 D6);
# import bootstraps a repo's <repo>/.cco/ from such a tar and registers it in the
# index, like `cco init`.
#
# Provides: cmd_project_export(), cmd_project_import()
# Dependencies: colors.sh, utils.sh, yaml.sh (yml_get/yml_get_packs), secrets.sh,
#               paths.sh, index.sh, packs.sh (_pack_resolve_dir — for
#               --bundle-packs dependency-closure, ADR-0019 D6),
#               cmd-resolve.sh (_resolve_find_unit_dir / _resolve_unit_dir_for_project)
# Globals: PACKS_DIR

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
    local name="" output="" bundle_packs=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output|-o)
                [[ -z "${2:-}" ]] && die "--output requires a path"
                output="$2"; shift 2 ;;
            --bundle-packs) bundle_packs=true; shift ;;
            --help|-h)
                cat <<'EOF'
Usage: cco project export [<name>] [--output <path>] [--bundle-packs]

Export a project's committed config (<repo>/.cco/) as a .tar.gz snapshot. The
gitignored secrets.env is never bundled. With no name, exports the project
hosted in the current repo (cwd-first). Import it elsewhere with
`cco project import`. Projects are not published/installed — they ride the
code-repo remote (ADR-0018 D2).

  --bundle-packs   Dependency-closure: also bundle the project's referenced packs
                   (the global ~/.cco/packs ones not already in <repo>/.cco/packs)
                   so the import is self-contained without their sharing repos
                   (ADR-0019 D6). `cco project import` installs them.
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

    # Dependency-closure (ADR-0019 D6): with --bundle-packs, also carry the
    # project's referenced packs so the import is self-contained without access to
    # their sharing repos. Only GLOBAL packs (~/.cco/packs) are bundled — packs
    # authored/cached in <repo>/.cco/packs already travel inside .cco. The flag is
    # the conscious opt-in; each bundled pack is secret-scanned too.
    local -a bundled=()
    if [[ "$bundle_packs" == true ]]; then
        local _pn _pdir _pleak
        while IFS= read -r _pn; do
            [[ -z "$_pn" ]] && continue
            _pdir=$(_pack_resolve_dir "$_pn" "$cco_dir")
            if [[ -z "$_pdir" ]]; then
                warn "Pack '$_pn' not resolved — not bundled (install it or add a url)."
                continue
            fi
            [[ "$_pdir" == "$cco_dir/packs/"* ]] && continue   # already inside .cco
            if ! _pleak=$(_project_export_scan_secrets "$_pdir"); then
                die "Refusing to bundle pack '$_pn' — potential secret detected:
  $_pleak"
            fi
            bundled+=("$_pn")
        done < <(yml_get_packs "$cco_dir/project.yml")
    fi

    if [[ ${#bundled[@]} -gt 0 ]]; then
        # Stage .cco + bundled-packs/, then tar the staging dir.
        local stage; stage=$(mktemp -d)
        cp -R "$cco_dir" "$stage/.cco"
        rm -f "$stage/.cco/secrets.env"; rm -rf "$stage/.cco/install-tmp"
        mkdir -p "$stage/bundled-packs"
        local _bn
        for _bn in "${bundled[@]}"; do
            cp -R "$(_pack_resolve_dir "$_bn" "$cco_dir")" "$stage/bundled-packs/$_bn"
        done
        tar czf "$archive" -C "$stage" .cco bundled-packs
        rm -rf "$stage"
        ok "Exported project '$proj_name' to $archive (bundled packs: ${bundled[*]})"
    else
        tar czf "$archive" -C "$repo_dir" \
            --exclude='.cco/secrets.env' \
            --exclude='.cco/install-tmp' \
            .cco
        ok "Exported project '$proj_name' to $archive"
    fi
}

cmd_project_import() {
    local archive="" force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            --help|-h)
                cat <<'EOF'
Usage: cco project import <archive> [--force]

Import a project from a .tar.gz snapshot (produced by `cco project export`)
into the current repo: unpacks <repo>/.cco/ and registers it in the index.
Refuses to overwrite an existing .cco/ unless --force. Re-create secrets.env
from secrets.env.example after import. If the archive carries bundled packs
(`export --bundle-packs`), they are installed into ~/.cco/packs (existing packs
are kept, never clobbered).
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

    # F12 name-uniqueness (project identity stays global — ADR-0051): the name
    # must be free, except a re-import into the same location (this project already
    # binds the target path). Path is the resource identity (§12).
    if [[ -n "$(_index_get_project_repos "$proj_name" 2>/dev/null || true)" ]] \
       && ! _index_paths_get_bindings "$target_repo" 2>/dev/null | cut -f1 | grep -qxF "$proj_name"; then
        rm -rf "$tmpdir"
        die "A project named '$proj_name' is already registered. 'cco forget' it first, or rename the imported project."
    fi

    # Place the config into the target repo, then register it in the index
    # (host this project in the current repo — mirrors `cco init`).
    rm -rf "$target_cco"
    cp -R "$tmpdir/.cco" "$target_cco"

    # Install any bundled packs (ADR-0019 D6 dependency-closure) into ~/.cco/packs,
    # never clobbering a pack the user already has.
    if [[ -d "$tmpdir/bundled-packs" ]]; then
        local _bp _bn
        for _bp in "$tmpdir"/bundled-packs/*/; do
            [[ -d "$_bp" ]] || continue
            _bn=$(basename "$_bp")
            if [[ -d "$PACKS_DIR/$_bn" ]]; then
                info "Bundled pack '$_bn' already present — kept your copy."
            else
                mkdir -p "$PACKS_DIR"
                cp -R "$_bp" "$PACKS_DIR/$_bn"
                ok "Installed bundled pack '$_bn'."
            fi
        done
    fi
    rm -rf "$tmpdir"

    # S2b: the import itself has landed (the .cco/ tree is extracted into the repo),
    # so this is a report, not a rollback — but without the binding `cco start
    # $proj_name` will not resolve it, and the ok below would have implied otherwise.
    if ! _index_set_path "$proj_name" "$proj_name" "$target_repo" \
       || ! _index_set_project_repos "$proj_name" "$proj_name"; then
        die "Imported project '$proj_name' into $target_cco, but it could not be registered in the machine-local index — 'cco start $proj_name' will not resolve it yet. Run 'cco resolve --scan $target_repo' to bind it."
    fi

    ok "Imported project '$proj_name' into $target_cco"
    info "Re-create secrets from .cco/secrets.env.example if the project needs them."
}
