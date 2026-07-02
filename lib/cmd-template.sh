#!/usr/bin/env bash
# lib/cmd-template.sh — Template management commands
#
# Provides: cmd_template(), _resolve_template()
# Dependencies: colors.sh, utils.sh, yaml.sh
# Globals: TEMPLATES_DIR, NATIVE_TEMPLATES_DIR, PACKS_DIR (projects via the STATE index, P5)

# ── Template Resolution ──────────────────────────────────────────────

# Resolve a template by name. Checks user templates first, then native.
# Usage: _resolve_template "project" "base"
# Outputs the resolved template directory path.
_resolve_template() {
    local kind="$1"    # "project" or "pack"
    local name="$2"    # template name or empty for "base"

    name="${name:-base}"

    # 1. User templates (priority)
    if [[ -d "$TEMPLATES_DIR/$kind/$name" ]]; then
        echo "$TEMPLATES_DIR/$kind/$name"
        return 0
    fi

    # 2. Native templates (fallback)
    if [[ -d "$NATIVE_TEMPLATES_DIR/$kind/$name" ]]; then
        echo "$NATIVE_TEMPLATES_DIR/$kind/$name"
        return 0
    fi

    die "Template '$name' not found for $kind. Run 'cco template list --$kind' to see available templates."
}

# ── Template Commands ─────────────────────────────────────────────────

cmd_template() {
    local subcmd="${1:-}"
    if [[ -z "$subcmd" || "$subcmd" == "--help" || "$subcmd" == "-h" ]]; then
        cat <<'EOF'
Usage: cco template <command> [options]

Commands:
  show <name>                Show template details
  create <name>              Create a new user template
  update <name> [--all]      Update a template from its remote source
  validate [name] [--all]    Validate a template's structure
  remove <name>              Remove a user template
  publish <name> [remote]    Publish a template to a sharing repo
  install <url>              Install a template from a sharing repo
  export <name>              Export a template as a .tar.gz archive
  import <archive>           Import a template from a .tar.gz archive
  internalize <name>         Disconnect a template from its remote source

List templates with 'cco list template'. Templates mirror packs (create ·
install · update · publish · export · import · internalize · show · remove ·
validate). Note: native templates cannot be updated/removed (no recorded source).

Run 'cco template <command> --help' for command-specific options.
EOF
        return 0
    fi
    shift

    case "$subcmd" in
        list)        die "'cco template list' was removed — use 'cco list template' (ADR-0029)." ;;
        show)        cmd_template_show "$@" ;;
        create)      cmd_template_create "$@" ;;
        update)      cmd_template_update "$@" ;;
        validate)    cmd_template_validate "$@" ;;
        remove)      cmd_template_remove "$@" ;;
        publish)     cmd_template_publish "$@" ;;
        install)     cmd_template_install "$@" ;;
        export)      cmd_template_export "$@" ;;
        import)      cmd_template_import "$@" ;;
        internalize) cmd_template_internalize "$@" ;;
        *)           die "Unknown template command: $subcmd. Run 'cco template --help'." ;;
    esac
}

# Output scoping (ADR-0043): templates are personal-global. The operator shim
# already gates `template list` behind read-global+, so whenever this runs every
# template is in scope — no per-row filtering is needed here (unlike the compact
# `cco list`, which surfaces templates at any read level and scopes them there).
cmd_template_list() {
    local filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) filter="project"; shift ;;
            --pack)    filter="pack"; shift ;;
            --help|-h)
                cat <<'EOF'
Usage: cco template list [--project|--pack]

List all available templates (native + user-defined).
EOF
                return 0
                ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    local found=false

    # List project templates
    if [[ -z "$filter" || "$filter" == "project" ]]; then
        echo "Project templates:"
        # Native
        if [[ -d "$NATIVE_TEMPLATES_DIR/project" ]]; then
            local d
            for d in "$NATIVE_TEMPLATES_DIR/project"/*/; do
                [[ ! -d "$d" ]] && continue
                local name
                name=$(basename "$d")
                local desc=""
                if [[ -f "$d/template.yml" ]]; then
                    desc=$(awk '/^description:/ {$1=""; sub(/^ /, ""); print}' "$d/template.yml")
                fi
                printf "  %-20s (native)  %s\n" "$name" "$desc"
                found=true
            done
        fi
        # User
        if [[ -d "$TEMPLATES_DIR/project" ]]; then
            local d
            for d in "$TEMPLATES_DIR/project"/*/; do
                [[ ! -d "$d" ]] && continue
                local name
                name=$(basename "$d")
                local desc=""
                if [[ -f "$d/template.yml" ]]; then
                    desc=$(awk '/^description:/ {$1=""; sub(/^ /, ""); print}' "$d/template.yml")
                fi
                printf "  %-20s (user)    %s\n" "$name" "$desc"
                found=true
            done
        fi
        echo ""
    fi

    # List pack templates
    if [[ -z "$filter" || "$filter" == "pack" ]]; then
        echo "Pack templates:"
        # Native
        if [[ -d "$NATIVE_TEMPLATES_DIR/pack" ]]; then
            local d
            for d in "$NATIVE_TEMPLATES_DIR/pack"/*/; do
                [[ ! -d "$d" ]] && continue
                local name
                name=$(basename "$d")
                printf "  %-20s (native)\n" "$name"
                found=true
            done
        fi
        # User
        if [[ -d "$TEMPLATES_DIR/pack" ]]; then
            local d
            for d in "$TEMPLATES_DIR/pack"/*/; do
                [[ ! -d "$d" ]] && continue
                local name
                name=$(basename "$d")
                printf "  %-20s (user)\n" "$name"
                found=true
            done
        fi
        echo ""
    fi

    if ! $found; then
        info "No templates found."
    fi
}

cmd_template_show() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                cat <<'EOF'
Usage: cco template show <name>

Show details about a template including its structure and variables.
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$name" ]] && die "Usage: cco template show <name>"
    # Output scoping (ADR-0043): templates are a personal-global resource
    # (read-global+). The operator shim already gates this verb; require_visible
    # keeps the layer authoritative if the classification ever changes.
    _env_require_visible template "$name"

    # Try to find in both project and pack
    local template_dir="" kind=""
    for k in project pack; do
        if [[ -d "$TEMPLATES_DIR/$k/$name" ]]; then
            template_dir="$TEMPLATES_DIR/$k/$name"
            kind="$k (user)"
            break
        elif [[ -d "$NATIVE_TEMPLATES_DIR/$k/$name" ]]; then
            template_dir="$NATIVE_TEMPLATES_DIR/$k/$name"
            kind="$k (native)"
            break
        fi
    done

    [[ -z "$template_dir" ]] && die "Template '$name' not found."

    echo "Template: $name"
    echo "Type: $kind"
    echo "Path: $template_dir"

    if [[ -f "$template_dir/template.yml" ]]; then
        echo ""
        echo "Metadata (template.yml):"
        sed 's/^/  /' "$template_dir/template.yml"
    fi

    echo ""
    echo "Structure:"
    # Simple tree-like output
    (cd "$template_dir" && find . -type f | sed 's|^\./|  |' | sort)
}

cmd_template_create() {
    check_global
    local name=""
    local kind=""
    local from=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) kind="project"; shift ;;
            --pack)    kind="pack"; shift ;;
            --from)
                [[ -z "${2:-}" ]] && die "--from requires a resource path"
                from="$2"; shift 2 ;;
            --help|-h)
                cat <<'EOF'
Usage: cco template create <name> --project|--pack [--from <resource>]

Create a new user template.

Options:
  --project          Create a project template
  --pack             Create a pack template
  --from <resource>  Create template from an existing project or pack
                     (e.g., --from projects/my-app or --from packs/my-pack)
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$name" ]] && die "Usage: cco template create <name> --project|--pack"
    [[ -z "$kind" ]] && die "Specify --project or --pack"

    # Validate name
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        die "Template name must be lowercase letters, numbers, and hyphens only."
    fi

    local target_dir="$TEMPLATES_DIR/$kind/$name"
    [[ -d "$target_dir" ]] && die "Template '$name' already exists at templates/$kind/$name/"

    mkdir -p "$TEMPLATES_DIR/$kind"

    if [[ -n "$from" ]]; then
        # Create from existing resource
        local source_dir="" from_project=false _ud
        # A configured project (resolved via the STATE index): its committed
        # config lives in <repo>/.cco/ — the claude/ tree + project.yml + root
        # files. The central $PROJECTS_DIR layout is gone (P5).
        if _ud=$(_resolve_unit_dir_for_project "$from" 2>/dev/null); then
            source_dir="$_ud/.cco"
            from_project=true
        elif [[ -d "$PACKS_DIR/$from" ]]; then
            source_dir="$PACKS_DIR/$from"
        elif [[ -d "$from" ]]; then
            source_dir="$from"
        else
            die "Resource '$from' not found."
        fi

        cp -r "$source_dir" "$target_dir"

        # A project's authored config tree is committed as claude/; templates use
        # the native .claude/ layout (what `cco init --template` / the scaffold
        # reads). Rename when sourcing from a project's .cco/.
        if [[ "$from_project" == true && -d "$target_dir/claude" ]]; then
            mv "$target_dir/claude" "$target_dir/.claude"
        fi

        # Strip runtime state and generated artifacts (defensive — the committed
        # .cco/ holds none, but a pack/dir source might).
        rm -rf "$target_dir/.cco" "$target_dir/.tmp"
        # Templates carry an (emptied) secrets.env skeleton; the committed project
        # form is secrets.env.example. Normalize to a single emptied secrets.env.
        if [[ -f "$target_dir/secrets.env.example" && ! -f "$target_dir/secrets.env" ]]; then
            mv "$target_dir/secrets.env.example" "$target_dir/secrets.env"
        else
            rm -f "$target_dir/secrets.env.example"
        fi
        if [[ -f "$target_dir/secrets.env" ]]; then
            > "$target_dir/secrets.env"
        fi

        ok "Template '$name' created from '$from'"
        info "Review and customize at: templates/$kind/$name/"
        info "Consider replacing project-specific values with {{PLACEHOLDER}} variables."
    else
        # Create empty template from base
        local base_dir
        base_dir=$(_resolve_template "$kind" "base")
        cp -r "$base_dir" "$target_dir"

        ok "Template '$name' created at templates/$kind/$name/"
        info "Customize the template files, then use with:"
        info "  cco $kind create <name> --template $name"
    fi
}

cmd_template_remove() {
    local name="" yes=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) yes=true; shift ;;
            --help|-h)
                cat <<'EOF'
Usage: cco template remove <name> [-y]

Remove a user-defined template and its id-keyed internal state (DATA install-
provenance, STATE merge base, the per-user tag binding). Native templates cannot
be removed. Previews the cascade and confirms first (ADR-0029 D2).

Options:
  -y, --yes   Skip the confirmation prompt
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$name" ]] && die "Usage: cco template remove <name>"

    # Find in user templates only
    local found_dir=""
    for k in project pack; do
        if [[ -d "$TEMPLATES_DIR/$k/$name" ]]; then
            found_dir="$TEMPLATES_DIR/$k/$name"
            break
        fi
    done

    [[ -z "$found_dir" ]] && die "User template '$name' not found. Only user templates can be removed."

    # ── Preview the cascade (ADR-0029 D2) ──────────────────────────────────
    info "cco template remove '$name' will delete:"
    info "  • $found_dir (the template)"
    [[ -d "$(_cco_data_dir)/templates/$name"  ]] && info "  • DATA:  install-provenance"
    [[ -d "$(_cco_state_dir)/templates/$name" ]] && info "  • STATE: merge base"
    local _ttags; _ttags=$(_tags_get templates "$name")
    [[ -n "$_ttags" ]] && info "  • tags:  [$_ttags]"

    _confirm_destructive "$yes" "Remove template '$name'?" || { info "Aborted"; return 0; }

    rm -rf "$found_dir"

    # Delete-cascade (ADR-0021 Dec.4): clean the id-keyed internal state an
    # installed template created — DATA install-provenance (`source`), STATE merge
    # base (`<state>/cco/templates/<name>/update/`), and the tags.yml binding.
    # No-ops for create-from templates that never recorded provenance.
    rm -rf "$(_cco_data_dir)/templates/$name"
    rm -rf "$(_cco_state_dir)/templates/$name"
    _tags_forget templates "$name"

    ok "Template '$name' removed."
}

# ── cco template internalize ──────────────────────────────────────────────
# Sever a template's one external coupling — the upstream url (ADR-0019 D3/D4,
# ADR-0023 D4): set its recorded DATA source to local so it stops receiving
# updates. With --as, fork to a new self-contained template instead, leaving the
# original linked. Templates have no knowledge.source, so this is the
# source-disconnect only (the template analog of `cco pack internalize`).
cmd_template_internalize() {
    local name="" newname=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --as) [[ -z "${2:-}" ]] && die "--as requires a new template name"; newname="$2"; shift 2 ;;
            --help|-h)
                cat <<'EOF'
Usage: cco template internalize <name> [--as <new-name>]

Disconnect a template from its remote sharing repo (set its recorded source to
local — it will no longer receive updates).

  --as <new-name>   Fork instead of in-place: copy <name> to a new self-contained
                    template <new-name>; the original stays linked to its source.
EOF
                return 0
                ;;
            -*) die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then name="$1"; shift
                else die "Unexpected argument: $1"; fi
                ;;
        esac
    done

    [[ -z "$name" ]] && die "Usage: cco template internalize <name> [--as <new-name>]"
    check_global

    # Locate the user template (project or pack kind). Native templates have no
    # source to disconnect and are not user-owned.
    local kind="" found_dir="" k
    for k in project pack; do
        if [[ -d "$TEMPLATES_DIR/$k/$name" ]]; then kind="$k"; found_dir="$TEMPLATES_DIR/$k/$name"; break; fi
    done
    [[ -z "$found_dir" ]] && die "User template '$name' not found."

    # --as: fork to a new self-contained template (the copy carries no DATA source).
    if [[ -n "$newname" ]]; then
        [[ "$newname" == "$name" ]] && die "--as name must differ from '$name'."
        [[ ! "$newname" =~ ^[a-z0-9][a-z0-9-]*$ ]] && die "Invalid template name '$newname' (use lowercase letters, digits, hyphens)."
        [[ -d "$TEMPLATES_DIR/$kind/$newname" ]] && die "Template '$newname' already exists."
        cp -R "$found_dir" "$TEMPLATES_DIR/$kind/$newname"
        ok "Forked template '$name' → '$newname' (original stays linked to its source)."
        name="$newname"
        found_dir="$TEMPLATES_DIR/$kind/$newname"
    fi

    # Disconnect: rewrite the DATA source to local, preserving install history.
    local sf; sf=$(_cco_template_source "$found_dir")
    if [[ -f "$sf" ]]; then
        local src_url; src_url=$(yml_get "$sf" "url")
        if [[ -n "$src_url" && "$src_url" != "local" ]]; then
            { printf 'url: local\n'; printf '# previously installed from: %s\n' "$src_url"; } > "$sf"
            ok "Template '$name' disconnected from remote source: $src_url"
            return 0
        fi
    fi
    ok "Template '$name' is already self-contained (no remote tracking)."
}

# ── Template sharing (2×2; ADR-0018 D2, reuses the pack sharing path) ──────
# Templates carry a kind (project|pack), detected by the marker file inside the
# template dir (project.yml → project, pack.yml → pack). The sharing-repo layout
# is flat — templates/<name>/ — so the kind travels via that marker, never the
# path (ADR-0023 D4b; maintainer-confirmed both-kinds-by-marker).

# Echo a template's kind from its marker file, or return 1.
_template_kind_of() {
    local dir="$1"
    if [[ -f "$dir/project.yml" ]]; then printf 'project\n'
    elif [[ -f "$dir/pack.yml" ]]; then printf 'pack\n'
    else return 1; fi
}

# Locate a template dir + kind (user store first, then native). With an explicit
# kind, only that kind is searched. Echoes "<dir>\t<kind>", or returns 1.
_find_template() {
    local name="$1" want_kind="${2:-}" k d
    local kinds=(project pack)
    [[ -n "$want_kind" ]] && kinds=("$want_kind")
    for k in "${kinds[@]}"; do
        for d in "$TEMPLATES_DIR/$k/$name" "$NATIVE_TEMPLATES_DIR/$k/$name"; do
            [[ -d "$d" ]] && { printf '%s\t%s\n' "$d" "$k"; return 0; }
        done
    done
    return 1
}

# Install a template from a local directory into the user store, recording the
# DATA source coordinate, the STATE install meta (installed_commit), and the
# STATE base/ merge ancestor (mirrors the pack form). The optional <commit> is
# the upstream HEAD the install pinned — empty for a local/import snapshot, which
# leaves the template `indeterminate` under `cco update --check` (ADR-0022 D6).
# Usage: _install_template_from_dir <source_dir> <name> <kind> <url> <ref> <path> <force> [commit]
_install_template_from_dir() {
    local source_dir="$1" name="$2" kind="$3" url="$4" ref="$5" path="$6" force="$7" commit="${8:-}"
    local target_dir="$TEMPLATES_DIR/$kind/$name"

    if [[ -d "$target_dir" ]]; then
        if [[ "$force" == true ]]; then
            rm -rf "$target_dir"
        else
            local existing="" sf
            sf=$(_cco_template_source "$target_dir")
            [[ -f "$sf" ]] && existing=$(yml_get "$sf" "url")
            if [[ "$existing" == "$url" ]]; then
                info "Template '$name' already installed from same source — updating"
                rm -rf "$target_dir"
            else
                die "Template '$name' already exists (source: ${existing:-unknown}). Use --force to overwrite."
            fi
        fi
    fi

    mkdir -p "$TEMPLATES_DIR/$kind"
    cp -r "$source_dir" "$target_dir"
    rm -rf "$target_dir/.git"

    local sf
    sf=$(_cco_template_source "$target_dir")
    mkdir -p "$(dirname "$sf")"
    cat > "$sf" <<YAML
url: $url
resource: ${path:-}
ref: ${ref:-}
YAML
    local now; now=$(date +%Y-%m-%d)
    _meta_record_provenance "$(_cco_template_meta "$target_dir")" "$commit" "$now" "$now"
    _record_tree_as_base "$(_cco_template_base_dir "$target_dir")" "$target_dir"
    ok "Installed $kind template '$name'"
}

# ── cco template update ───────────────────────────────────────────────
# The pack-`update` analogue (ADR-0029 D3): re-clone an installed template from
# its recorded DATA source coordinate, re-install it (overwriting), and bump the
# STATE installed_commit. Supersedes the "future cco template sync" placeholder.

cmd_template_update() {
    local name="" force=false update_all=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)   update_all=true; shift ;;
            --force) force=true; shift ;;
            --help|-h)
                cat <<'EOF'
Usage: cco template update <name> [--force]
       cco template update --all [--force]

Update a template from its recorded remote source (the pack-update analogue).

Options:
  --all     Update every template that has a remote source
  --force   Overwrite local modifications
EOF
                return 0 ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then name="$1"; shift
                else die "Unexpected argument: $1"; fi ;;
        esac
    done

    check_global

    if $update_all; then
        local updated=0
        local -a failed=()
        local d
        for d in "$TEMPLATES_DIR"/project/*/ "$TEMPLATES_DIR"/pack/*/; do
            [[ ! -d "$d" ]] && continue
            local sf; sf=$(_cco_template_source "$d")
            [[ ! -f "$sf" ]] && continue
            local u; u=$(yml_get "$sf" "url")
            [[ "$u" == "local" || -z "$u" ]] && continue
            local tn; tn=$(basename "$d")
            info "Updating $tn..."
            # Isolate errors: run in a subshell so die() does not abort the loop.
            if ( _update_single_template "$d" "$force" ); then
                updated=$((updated + 1))
            else
                warn "Failed to update '$tn'"
                failed+=("$tn")
            fi
        done
        if [[ $updated -eq 0 && ${#failed[@]} -eq 0 ]]; then
            info "No templates with remote sources found"
        elif [[ $updated -gt 0 && ${#failed[@]} -eq 0 ]]; then
            ok "Updated $updated template(s)"
        fi
        if [[ ${#failed[@]} -gt 0 ]]; then
            error "Failed to update ${#failed[@]} template(s): ${failed[*]}"
            return 1
        fi
        return 0
    fi

    [[ -z "$name" ]] && die "Usage: cco template update <name> [--force]"
    local found dir
    found=$(_find_template "$name") || die "Template '$name' not found."
    dir="${found%%$'\t'*}"
    _update_single_template "$dir" "$force"
}

# Update one installed template in place from its recorded DATA source. Mirrors
# _update_single_pack: re-clone the coordinate, re-install (force), refreshing
# the STATE installed_commit + base. Usage: _update_single_template <dir> [force]
_update_single_template() {
    local dir="$1"
    local force="${2:-false}"
    local name kind
    name=$(basename "$dir")
    kind=$(_template_kind_of "$dir") || die "Template '$name': no project.yml/pack.yml marker."

    local sf; sf=$(_cco_template_source "$dir")
    [[ ! -f "$sf" ]] && die "Template '$name' has no recorded source — cannot determine remote source"

    local url ref path
    url=$(yml_get "$sf" "url")
    ref=$(yml_get "$sf" "ref")
    path=$(yml_get "$sf" "resource")
    if [[ "$url" == "local" || -z "$url" ]]; then
        die "Template '$name' was created locally — no remote source to update from"
    fi

    local token=""
    token=$(remote_resolve_token_for_url "$url" 2>/dev/null) || true

    info "Fetching $url${ref:+ (ref: $ref)}..."
    local tmpdir
    tmpdir=$(_clone_config_repo "$url" "$ref" "$token")

    local remote_dir="$tmpdir"
    [[ -n "$path" ]] && remote_dir="$tmpdir/$path"
    if [[ ! -d "$remote_dir" ]]; then
        _cleanup_clone "$tmpdir"
        die "Remote path '${path:-/}' not found in cloned repo"
    fi

    local commit=""
    commit=$(git -C "$tmpdir" rev-parse HEAD 2>/dev/null) || true

    # Re-install (force=true: explicit update). This rewrites the DATA source
    # coordinate and records the new commit in the STATE meta.
    _install_template_from_dir "$remote_dir" "$name" "$kind" "$url" "$ref" "$path" true "$commit"

    _cleanup_clone "$tmpdir"
    ok "Updated template '$name'"
}

# ── cco template validate ─────────────────────────────────────────────
# The pack-`validate` analogue (ADR-0029 D3): structural validation of a
# template tree. Validates one named template, or every user template.

# Output scoping (ADR-0043): templates are GLOBAL-class, and the operator shim
# gates every `template` verb (incl. validate) to read-global+ — a scope where
# nothing is hidden — so no per-row `_env_in_scope` filter is wired here (same
# rationale as `template`/`remote list`).
cmd_template_validate() {
    check_global
    local name="" validate_all=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)   validate_all=true; shift ;;
            --help|-h)
                cat <<'EOF'
Usage: cco template validate [name] [--all]

Validate a template's structure (kind marker + expected tree). With no name (or
--all), validates every user template.
EOF
                return 0 ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then name="$1"; shift
                else die "Unexpected argument: $1"; fi ;;
        esac
    done

    if [[ -n "$name" && "$validate_all" == false ]]; then
        local found dir
        found=$(_find_template "$name") || die "Template '$name' not found."
        dir="${found%%$'\t'*}"
        _validate_single_template "$dir"
        return $?
    fi

    local has_errors=false found_any=false d
    for d in "$TEMPLATES_DIR"/project/*/ "$TEMPLATES_DIR"/pack/*/; do
        [[ ! -d "$d" ]] && continue
        found_any=true
        if ! _validate_single_template "$d"; then
            has_errors=true
        fi
    done
    if [[ "$found_any" == false ]]; then
        info "No user templates to validate."
        return 0
    fi
    [[ "$has_errors" == true ]] && return 1
    return 0
}

# Validate a single template directory's structure. Returns 0 if valid, 1 if a
# structural error is found (warnings do not fail). Usage:
# _validate_single_template <template_dir>
_validate_single_template() {
    local dir="$1"
    local name; name=$(basename "$dir")

    # Greppable output (one "<name>: <reason>" line + summary, no inline symbol),
    # matching cco project/pack validate (ADR-0023 D2 / finding F1).
    local kind
    if ! kind=$(_template_kind_of "$dir"); then
        printf '%s: no project.yml or pack.yml marker (cannot determine kind)\n' "$name"
        printf 'validate: 1 issue(s) [error=1 warning=0]\n'
        return 1
    fi

    # A project template scaffolds a config tree; this is a warning (not a
    # failure) so a hand-authored skeleton still validates.
    if [[ "$kind" == project && ! -d "$dir/.claude" && ! -d "$dir/claude" ]]; then
        printf '%s (%s): no .claude/ or claude/ config tree to scaffold\n' "$name" "$kind"
        printf 'validate: 1 issue(s) [error=0 warning=1]\n'
        return 0
    fi

    ok "Template '$name' ($kind) is valid"
    return 0
}

cmd_template_export() {
    local name="" kind="" output=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) kind="project"; shift ;;
            --pack)    kind="pack"; shift ;;
            --output|-o)
                [[ -z "${2:-}" ]] && die "--output requires a path"
                output="$2"; shift 2 ;;
            --help|-h)
                cat <<'EOF'
Usage: cco template export <name> [--project|--pack] [--output <path>]

Export a template as a .tar.gz archive (its kind travels via the project.yml /
pack.yml marker inside). With no --project/--pack, the kind is auto-detected.
EOF
                return 0 ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then name="$1"; shift
                else die "Unexpected argument: $1"; fi ;;
        esac
    done

    [[ -z "$name" ]] && die "Usage: cco template export <name> [--project|--pack]"
    local found dir tk
    found=$(_find_template "$name" "$kind") || die "Template '$name' not found${kind:+ for $kind}."
    dir="${found%%$'\t'*}"; tk="${found##*$'\t'}"

    local archive="${output:-${name}.tar.gz}"
    tar czf "$archive" -C "$(dirname "$dir")" "$name"
    ok "Exported $tk template '$name' to $archive"
}

cmd_template_import() {
    local archive="" force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            --help|-h)
                cat <<'EOF'
Usage: cco template import <archive> [--force]

Import a template from a .tar.gz archive. The kind is detected from the
project.yml / pack.yml marker inside. Use --force to overwrite an existing one.
EOF
                return 0 ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$archive" ]]; then archive="$1"; shift
                else die "Unexpected argument: $1"; fi ;;
        esac
    done

    [[ -z "$archive" ]] && die "Usage: cco template import <archive>"
    [[ -f "$archive" ]] || die "Archive not found: $archive"

    local tmpdir; tmpdir=$(mktemp -d)
    tar xzf "$archive" -C "$tmpdir" 2>/dev/null \
        || { rm -rf "$tmpdir"; die "Failed to extract archive: $archive"; }

    # Locate the template root: its <name>/ dir (export wraps it), or markers at
    # the archive root (defensive).
    local root="" d
    if [[ -f "$tmpdir/project.yml" || -f "$tmpdir/pack.yml" ]]; then
        root="$tmpdir"
    else
        for d in "$tmpdir"/*/; do
            [[ -f "${d}project.yml" || -f "${d}pack.yml" ]] && { root="${d%/}"; break; }
        done
    fi
    [[ -z "$root" ]] && { rm -rf "$tmpdir"; die "No template found in archive (missing project.yml/pack.yml)"; }

    local kind; kind=$(_template_kind_of "$root") \
        || { rm -rf "$tmpdir"; die "Cannot determine template kind"; }
    local name
    if [[ "$root" != "$tmpdir" ]]; then
        name=$(basename "$root")
    else
        name="${archive##*/}"; name="${name%.tar.gz}"
    fi

    local target="$TEMPLATES_DIR/$kind/$name"
    [[ -d "$target" && "$force" != true ]] \
        && { rm -rf "$tmpdir"; die "Template '$name' already exists at templates/$kind/$name/. Use --force."; }

    rm -rf "$target"
    mkdir -p "$(dirname "$target")"
    cp -R "$root" "$target"
    rm -rf "$target/.git" "$tmpdir"
    ok "Imported $kind template '$name'"
}

cmd_template_install() {
    local url="" pick="" kind="" token="" force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pick)  [[ -z "${2:-}" ]] && die "--pick requires a template name"; pick="$2"; shift 2 ;;
            --project) kind="project"; shift ;;
            --pack)    kind="pack"; shift ;;
            --token) [[ -z "${2:-}" ]] && die "--token requires a value"; token="$2"; shift 2 ;;
            --force) force=true; shift ;;
            --help|-h)
                cat <<'EOF'
Usage: cco template install <url>[@ref] [--pick <name>] [--token <t>] [--force]

Install a template from a sharing repo (templates/<name>/, structure-discovered).
The kind is detected from the marker inside. With multiple templates, use --pick.
EOF
                return 0 ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$url" ]]; then url="$1"; shift
                else die "Unexpected argument: $1"; fi ;;
        esac
    done

    [[ -z "$url" ]] && die "Usage: cco template install <url> [--pick <name>]"

    # Split a trailing @ref (only when it is in the last path segment, so
    # scp-style git@host:org/repo is left intact).
    local ref="" last="${url##*/}"
    if [[ "$last" == *@* ]]; then ref="${last##*@}"; url="${url%@*}"; fi

    [[ -z "$token" ]] && token=$(remote_resolve_token_for_url "$url" 2>/dev/null) || true

    info "Fetching templates from $url${ref:+ (ref: $ref)}..."
    local tmpdir; tmpdir=$(_clone_config_repo "$url" "$ref" "$token")

    # The cloned upstream HEAD — pinned as the template's installed_commit so
    # `cco update --check` can tell whether the source has since advanced (D6).
    local clone_commit=""
    clone_commit=$(git -C "$tmpdir" rev-parse HEAD 2>/dev/null) || true

    local names; names=$(_discover_resources "$tmpdir" templates)
    [[ -z "$names" ]] && { _cleanup_clone "$tmpdir"; die "No templates found in $url (expected templates/<name>/)."; }

    local chosen=""
    if [[ -n "$pick" ]]; then
        if printf '%s\n' "$names" | grep -qx "$pick"; then chosen="$pick"
        else _cleanup_clone "$tmpdir"; die "Template '$pick' not found. Available: $(printf '%s ' $names)"; fi
    elif [[ $(printf '%s\n' "$names" | grep -c .) -eq 1 ]]; then
        chosen="$names"
    else
        _cleanup_clone "$tmpdir"
        die "Multiple templates available — pick one with --pick: $(printf '%s ' $names)"
    fi

    local src_dir="$tmpdir/templates/$chosen"
    local tk; tk=$(_template_kind_of "$src_dir") \
        || { _cleanup_clone "$tmpdir"; die "Template '$chosen' has no project.yml/pack.yml marker."; }

    _install_template_from_dir "$src_dir" "$chosen" "$tk" "$url" "$ref" "templates/$chosen" "$force" "$clone_commit"
    _cleanup_clone "$tmpdir"
}

cmd_template_publish() {
    local name="" remote_arg="" kind="" message="" dry_run=false force=false token=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) kind="project"; shift ;;
            --pack)    kind="pack"; shift ;;
            --message) [[ -z "${2:-}" ]] && die "--message requires a value"; message="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            --force)   force=true; shift ;;
            --token)   [[ -z "${2:-}" ]] && die "--token requires a value"; token="$2"; shift 2 ;;
            --help|-h)
                cat <<'EOF'
Usage: cco template publish <name> [<remote>] [--project|--pack] [OPTIONS]

Publish a template to a sharing repo (templates/<name>/). Sync-before-publish:
pulls + 3-way merges against the template-scoped STATE base/, aborting on a
conflict (never clobbers a co-maintainer — P16). --force overwrites the remote.

Options:
  --message <msg>    Commit message (default: "publish template <name>")
  --dry-run          Show what would be published, don't push
  --force            Overwrite the remote with your local version (opt-in)
  --token <token>    Auth token for HTTPS remotes
EOF
                return 0 ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then name="$1"
                elif [[ -z "$remote_arg" ]]; then remote_arg="$1"
                else die "Unexpected argument: $1"; fi
                shift ;;
        esac
    done

    [[ -z "$name" ]] && die "Usage: cco template publish <name> [<remote>]"
    local found tmpl_dir tk
    found=$(_find_template "$name" "$kind") || die "Template '$name' not found${kind:+ for $kind}."
    tmpl_dir="${found%%$'\t'*}"; tk="${found##*$'\t'}"

    # Resolve remote: explicit arg, else re-derive from the recorded source url.
    local remote_url="" remote_name=""
    if [[ -n "$remote_arg" ]]; then
        local resolved
        if resolved=$(remote_get_url "$remote_arg"); then
            remote_url="$resolved"; remote_name="$remote_arg"
        elif [[ "$remote_arg" == *:* || "$remote_arg" == */* ]]; then
            remote_url="$remote_arg"
        else
            die "Remote '$remote_arg' not found. Register with 'cco remote add $remote_arg <url>'."
        fi
    else
        local sf rec
        sf=$(_cco_template_source "$tmpl_dir")
        [[ -f "$sf" ]] && rec=$(yml_get "$sf" "url")
        if [[ -n "${rec:-}" && "$rec" != "local" ]]; then
            remote_url="$rec"
            remote_name=$(remote_get_name_for_url "$rec" 2>/dev/null) || true
        else
            die "No remote given and none recorded. Usage: cco template publish $name <remote>"
        fi
    fi

    if [[ -z "$token" ]]; then
        if [[ -n "$remote_name" ]]; then token=$(remote_get_token "$remote_name" 2>/dev/null) || true
        else token=$(remote_resolve_token_for_url "$remote_url" 2>/dev/null) || true; fi
    fi
    [[ -z "$message" ]] && message="publish template $name"

    info "Publishing $tk template '$name' to $remote_url..."
    local tmpdir; tmpdir=$(_clone_for_publish "$remote_url" "$token")
    trap "_cleanup_clone '$tmpdir'" EXIT

    # OURS = the publishable template tree (defensively drop any local-only .cco).
    local ours_dir="$tmpdir/.cco-ours"
    cp -R "$tmpl_dir" "$ours_dir"
    rm -rf "$ours_dir/.cco"

    # Sync-before-publish: 3-way merge vs the template-scoped STATE base/ and the
    # remote tree (ADR-0022 D5 / P16), reusing the pack merge engine.
    local theirs_dir="$tmpdir/templates/$name"
    local merged_dir="$tmpdir/.cco-merged" base_dir
    base_dir=$(_cco_template_base_dir "$tmpl_dir")

    if $force; then
        [[ -d "$theirs_dir" ]] && \
            warn "--force: overwriting the remote copy of '$name' with your local version."
        rm -rf "$merged_dir"; cp -R "$ours_dir" "$merged_dir"
    else
        local merge_rc=0
        _pack_sync_merge "$base_dir" "$ours_dir" "$theirs_dir" "$merged_dir" || merge_rc=$?
        if [[ $merge_rc -ne 0 ]]; then
            _cleanup_clone "$tmpdir"; trap - EXIT
            if $dry_run; then
                warn "Would conflict with co-maintainer changes on the remote (files above)."
                info "Run 'cco template install $remote_url --pick $name' first, or republish with --force."
                return 0
            fi
            die "Publish would clobber co-maintainer changes on the remote (conflicting files above).
  Re-install the remote template first, then republish, or use --force to overwrite."
        fi
    fi

    rm -rf "$theirs_dir"; mkdir -p "$tmpdir/templates"
    cp -R "$merged_dir" "$theirs_dir"
    rm -rf "$merged_dir" "$ours_dir"

    if $dry_run; then
        echo ""
        echo -e "${BOLD}Would publish:${NC}"
        echo "  Template: $name ($tk)"
        echo "  Remote: $remote_url"
        echo "  Files:"
        find "$theirs_dir" -type f | sed "s|$tmpdir/||; s/^/    /"
        _cleanup_clone "$tmpdir"; trap - EXIT
        ok "Dry run complete — nothing pushed"
        return 0
    fi

    git -C "$tmpdir" add -A
    if git -C "$tmpdir" diff --cached --quiet; then
        info "Remote already up to date — nothing to publish."
    else
        git -C "$tmpdir" commit -q -m "$message"
        git -C "$tmpdir" push origin HEAD >/dev/null 2>&1 \
            || { _cleanup_clone "$tmpdir"; trap - EXIT; die "Failed to push to $remote_url"; }
    fi

    _record_tree_as_base "$base_dir" "$theirs_dir"
    # Record the published url as the template's upstream coordinate (F4-style).
    local sf
    sf=$(_cco_template_source "$tmpl_dir")
    mkdir -p "$(dirname "$sf")"
    if [[ -f "$sf" ]]; then _sed_i_or_append "$sf" "url" "$remote_url"
    else printf 'url: %s\nresource: templates/%s\nref:\n' "$remote_url" "$name" > "$sf"; fi

    _cleanup_clone "$tmpdir"; trap - EXIT
    ok "Published $tk template '$name' to $remote_url"
}

# Resolve {{VARIABLE}} patterns across a staged project template (ADR-0019 D7 —
# scaffold-time substitution; wired into `cco init --template`). Scans project.yml
# plus the whole claude/ tree (the new <repo>/.cco/ layout; legacy .claude/ is also
# picked up if present). PROJECT_NAME is always preset; other vars are taken from
# the preset list, prompted on a TTY (DESCRIPTION defaults to a TODO), or
# substituted name-as-value non-interactively.
# Usage: _resolve_template_vars <project_dir> <project_name> [KEY=VALUE ...]
_resolve_template_vars() {
    local project_dir="$1"
    local project_name="$2"
    shift 2

    # Build lookup of preset vars as newline-separated "KEY=VALUE" entries
    # (bash 3.2 compatible — no associative arrays)
    local preset_list=""
    while [[ $# -gt 0 ]]; do
        preset_list+="$1"$'\n'
        shift
    done

    # Always preset PROJECT_NAME (unless already in list)
    if ! echo "$preset_list" | grep -q "^PROJECT_NAME="; then
        preset_list+="PROJECT_NAME=$project_name"$'\n'
    fi

    # Find all template files to process: project.yml + the whole claude/ tree
    # (new layout), or the legacy .claude/ tree.
    local -a template_files=()
    [[ -f "$project_dir/project.yml" ]] && template_files+=("$project_dir/project.yml")
    local _ctree _tf
    for _ctree in "$project_dir/claude" "$project_dir/.claude"; do
        [[ -d "$_ctree" ]] || continue
        while IFS= read -r _tf; do
            [[ -n "$_tf" ]] && template_files+=("$_tf")
        done < <(find "$_ctree" -type f 2>/dev/null)
    done

    # Collect all variables from all files
    local all_vars=""
    for file in "${template_files[@]+"${template_files[@]}"}"; do
        local file_vars
        file_vars=$(grep -oE '\{\{[A-Z_]+\}\}' "$file" 2>/dev/null | sort -u || true)
        all_vars+="$file_vars"$'\n'
    done
    all_vars=$(echo "$all_vars" | sort -u | grep -v '^$' || true)

    [[ -z "$all_vars" ]] && return 0

    # Build sed substitution args
    local -a sed_args=()
    local var name value
    for var in $all_vars; do
        name="${var//[\{\}]/}"

        # Lookup in preset list
        local preset_match
        preset_match=$(echo "$preset_list" | grep "^${name}=" | head -1 || true)

        if [[ -n "$preset_match" ]]; then
            value="${preset_match#*=}"
        elif [[ -t 0 ]]; then
            # Interactive prompt
            local default=""
            case "$name" in
                DESCRIPTION) default="TODO: Add project description" ;;
            esac
            if [[ -n "$default" ]]; then
                read -rp "  $name [$default]: " value < /dev/tty
                value="${value:-$default}"
            else
                read -rp "  $name: " value < /dev/tty
            fi
            [[ -z "$value" ]] && die "Value required for $name"
        else
            # Non-interactive: use sensible defaults or fail for required vars
            case "$name" in
                DESCRIPTION) value="TODO: Add project description" ;;
                *)  value="$name" ;;
            esac
        fi

        sed_args+=("-e" "s|{{$name}}|$value|g")
    done

    # Apply substitutions to all template files
    for file in "${template_files[@]+"${template_files[@]}"}"; do
        _sed_i_raw "$file" "${sed_args[@]}"
    done
}
