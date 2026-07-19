#!/usr/bin/env bash
# lib/cmd-pack.sh — Pack management commands
#
# Provides: cmd_pack_create(), cmd_pack_list(), cmd_pack_show(),
#           cmd_pack_remove(), cmd_pack_validate(),
#           cmd_pack_install(), cmd_pack_update(), cmd_pack_export(),
#           cmd_pack_internalize()
# Dependencies: colors.sh, utils.sh, yaml.sh, packs.sh, remote.sh
# Globals: PACKS_DIR (projects enumerated via the STATE index, P5)

# ── Pack commands ─────────────────────────────────────────────────────

cmd_pack_create() {
    check_global

    local name=""
    local template_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --template)
                [[ -z "${2:-}" ]] && die "--template requires a template name"
                template_name="$2"; shift 2 ;;
            --help|-h)
                cat <<'EOF'
Usage: cco pack create <name> [--template <name>]

Create a new knowledge pack.

Options:
  --template <name>    Use a specific template (default: base)
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

    [[ -z "$name" ]] && die "Usage: cco pack create <name>"

    # Validate name
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        die "Pack name must be lowercase letters, numbers, and hyphens only."
    fi

    local pack_dir="$PACKS_DIR/$name"
    [[ -d "$pack_dir" ]] && die "Pack '$name' already exists at packs/$name/"

    # Ensure the packs store exists (CONFIG bucket, ~/.cco/packs). Defense-in-depth
    # (R5): fail loudly if the store is read-only — the operator write-gate refuses
    # `pack create` below edit-global first, but a silent mkdir/cp failure must not
    # let the success message print on a tree that was never written.
    mkdir -p "$PACKS_DIR" || die "Cannot create packs store at $PACKS_DIR (read-only?)."

    # Resolve and copy template
    local template_dir
    template_dir=$(_resolve_template "pack" "${template_name:-base}")
    cp -r "$template_dir" "$pack_dir" || die "Failed to create pack at $pack_dir (read-only?)."

    # Replace name placeholder in pack.yml if present
    if [[ -f "$pack_dir/pack.yml" ]]; then
        _substitute "$pack_dir/pack.yml" "PACK_NAME" "$name"
        # Also replace literal "name: base" with actual name
        _sed_i "$pack_dir/pack.yml" "^name: base$" "name: $name"
    fi

    ok "Pack created at packs/$name/"
    info "Add resources to the subdirectories:"
    info "  knowledge/ — documentation files"
    info "  skills/    — skill directories (each with SKILL.md)"
    info "  agents/    — agent definition files (.md)"
    info "  rules/     — rule files (.md)"
    info "Edit packs/$name/pack.yml to declare resources"
}

cmd_pack_list() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        cat <<'EOF'
Usage: cco pack list

List all installed packs with resource counts (knowledge, skills, agents, rules)
and their per-user tags. Sort/filter by tag via the compact index, e.g.
`cco list pack --sort tag` or `cco list pack --tag <t>`.
EOF
        return 0
    fi

    check_global

    # Size the NAME column to the widest pack name (capped), so long names never
    # shift the count columns out of alignment (truncated with an ellipsis).
    local dir name namew=4 cap=24
    for dir in "$PACKS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        name=$(basename "$dir")
        (( ${#name} > namew )) && namew=${#name}
    done
    (( namew > cap )) && namew=$cap

    printf "${BOLD}%s %-11s %-8s %-8s %-8s %s${NC}\n" \
        "$(_fit_col "NAME" "$namew")" "KNOWLEDGE" "SKILLS" "AGENTS" "RULES" "TAGS"

    for dir in "$PACKS_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        name=$(basename "$dir")
        # Output scoping (ADR-0043): show only packs referenced by the current
        # project at read-project (the read-project mount already narrows to
        # these; routing through the layer makes it intentional + uniform).
        if ! _env_in_scope pack "$name"; then _env_note_hidden pack; continue; fi

        local pack_yml="$dir/pack.yml"
        local k_count="-" s_count="-" a_count="-" r_count="-"
        if [[ -f "$pack_yml" ]]; then
            # grep -c prints "0" but exits 1 on no match: use `|| true` (not a
            # second `echo 0`, which would emit "0\n0" and break the row layout).
            k_count=$(yml_get_pack_knowledge_files "$pack_yml" | grep -c . 2>/dev/null || true); k_count=${k_count:-0}
            s_count=$(yml_get_pack_skills "$pack_yml" | grep -c . 2>/dev/null || true); s_count=${s_count:-0}
            a_count=$(yml_get_pack_agents "$pack_yml" | grep -c . 2>/dev/null || true); a_count=${a_count:-0}
            r_count=$(yml_get_pack_rules "$pack_yml" | grep -c . 2>/dev/null || true); r_count=${r_count:-0}
        fi

        local tags
        tags=$(_tags_get packs "$name")
        printf "%s %-11s %-8s %-8s %-8s %s\n" \
            "$(_fit_col "$name" "$namew")" "$k_count" "$s_count" "$a_count" "$r_count" "${tags:-—}"
    done
    _env_flush_hidden_notice
}

cmd_pack_show() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                cat <<'EOF'
Usage: cco pack show <name>

Show details for a knowledge pack.
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

    [[ -z "$name" ]] && die "Usage: cco pack show <name>"
    # Output scoping (ADR-0043): refuse out-of-scope packs with a scope message
    # instead of a raw "not found at packs/<name>" (the narrowed mount hides them).
    _env_require_visible pack "$name"

    local pack_dir="$PACKS_DIR/$name"
    local pack_yml="$pack_dir/pack.yml"
    [[ ! -d "$pack_dir" ]] && die "Pack '$name' not found at packs/$name/"

    # Name
    local yml_name=""
    [[ -f "$pack_yml" ]] && yml_name=$(yml_get "$pack_yml" "name")
    echo -e "${BOLD}Pack: ${yml_name:-$name}${NC}"
    echo ""

    if [[ ! -f "$pack_yml" ]]; then
        warn "pack.yml not found"
        return 0
    fi

    # Knowledge
    echo -e "${BOLD}Knowledge:${NC}"
    local k_source
    k_source=$(yml_get_pack_knowledge_source "$pack_yml")
    if [[ -n "$k_source" ]]; then
        echo "  Source: $k_source"
    fi
    local k_files
    k_files=$(yml_get_pack_knowledge_files "$pack_yml")
    if [[ -n "$k_files" ]]; then
        while IFS=$'\t' read -r kfile kdesc; do
            [[ -z "$kfile" ]] && continue
            kdesc=$(echo "$kdesc" | sed 's/^ *//;s/ *$//')
            if [[ -n "$kdesc" ]]; then
                echo "  - $kfile — $kdesc"
            else
                echo "  - $kfile"
            fi
        done <<< "$k_files"
    else
        echo "  (none)"
    fi
    echo ""

    # Skills
    echo -e "${BOLD}Skills:${NC}"
    local skills
    skills=$(yml_get_pack_skills "$pack_yml")
    if [[ -n "$skills" ]]; then
        while IFS= read -r s; do
            [[ -z "$s" ]] && continue
            echo "  - $s"
        done <<< "$skills"
    else
        echo "  (none)"
    fi
    echo ""

    # Agents
    echo -e "${BOLD}Agents:${NC}"
    local agents
    agents=$(yml_get_pack_agents "$pack_yml")
    if [[ -n "$agents" ]]; then
        while IFS= read -r a; do
            [[ -z "$a" ]] && continue
            echo "  - $a"
        done <<< "$agents"
    else
        echo "  (none)"
    fi
    echo ""

    # Rules
    echo -e "${BOLD}Rules:${NC}"
    local rules
    rules=$(yml_get_pack_rules "$pack_yml")
    if [[ -n "$rules" ]]; then
        while IFS= read -r r; do
            [[ -z "$r" ]] && continue
            echo "  - $r"
        done <<< "$rules"
    else
        echo "  (none)"
    fi
    echo ""

    # Used by projects — enumerate via the STATE index ($PROJECTS_DIR is gone, P5).
    echo -e "${BOLD}Used by projects:${NC}"
    local found_any=false
    local proj_name proj_yml proj_packs
    while IFS=$'\t' read -r proj_name _ proj_yml; do
        proj_packs=$(yml_get_packs "$proj_yml")
        if echo "$proj_packs" | grep -qxF "$name"; then
            echo "  - $proj_name"
            found_any=true
        fi
    done < <(_project_foreach)
    if [[ "$found_any" == false ]]; then
        echo "  (none)"
    fi
}

cmd_pack_remove() {
    local name=""
    local yes=false force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) yes=true; shift ;;
            --force)  force=true; yes=true; shift ;;   # override the in-use block + imply -y
            --help|-h)
                cat <<'EOF'
Usage: cco pack remove <name> [-y] [--force]

Remove a knowledge pack and its id-keyed internal state (DATA install-
provenance, STATE merge base/meta, the per-user tag binding). Previews the
cascade and confirms first (ADR-0029 D2).

Options:
  -y, --yes   Skip the confirmation prompt
  --force     Remove even if the pack is still used by a project (implies -y)
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

    [[ -z "$name" ]] && die "Usage: cco pack remove <name>"

    local pack_dir="$PACKS_DIR/$name"
    [[ ! -d "$pack_dir" ]] && die "Pack '$name' not found at packs/$name/"

    # Check if used by any projects — enumerate via the STATE index (P5).
    local used_by=()
    local proj_name proj_yml proj_packs
    while IFS=$'\t' read -r proj_name _ proj_yml; do
        proj_packs=$(yml_get_packs "$proj_yml")
        if echo "$proj_packs" | grep -qxF "$name"; then
            used_by+=("$proj_name")
        fi
    done < <(_project_foreach)

    # ── Preview the cascade (ADR-0029 D2) ──────────────────────────────────
    # Never probe the confined DATA/STATE buckets here (INV-S6): behind the ADR-0047
    # boundary the -d predicate reads FALSE for a path that exists, so the preview
    # would silently omit sidecars that ARE about to be removed. Announce them plainly.
    info "cco pack remove '$name' will delete:"
    info "  • packs/$name/ (the pack)"
    info "  • its machine-local DATA/STATE sidecars + per-user tag binding"

    # In-use is a --force block (not a confirm): a still-referenced pack is only
    # removable with --force, which overrides the block and implies -y.
    if [[ ${#used_by[@]} -gt 0 ]]; then
        warn "Pack '$name' is used by: ${used_by[*]}"
        [[ "$force" != true ]] && \
            die "Refusing to remove a pack still in use — re-run with --force to remove anyway."
    fi

    _confirm_destructive "$yes" "Remove pack '$name'?" || { info "Aborted"; return 0; }

    # Delete-cascade (ADR-0021 Dec.4): clean the id-keyed internal state this pack
    # created, not just the CONFIG copy — DATA install-provenance, STATE merge
    # base/meta, and the tags.yml binding. These live behind the ADR-0047 boundary, so
    # they go through lib/store.sh: a fail-closed pre-flight (crossing #1) refuses
    # BEFORE the claude-owned CONFIG dir is touched if the store cannot be written,
    # then the cascade applies (crossing #2) — all-or-nothing, never a false ✓.
    _store_check sidecar-purge packs "$name"
    rm -rf "$pack_dir" || die "Failed to remove packs/$name."
    _store_apply sidecar-purge packs "$name"

    ok "Pack '$name' removed"
}

cmd_pack_validate() {
    check_global

    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                cat <<'EOF'
Usage: cco pack validate [name]

Validate pack structure. Validates all packs if no name given.
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

    if [[ -n "$name" ]]; then
        # Output scoping (ADR-0043): refuse out-of-scope packs with a scope message.
        _env_require_visible pack "$name"
        [[ ! -d "$PACKS_DIR/$name" ]] && die "Pack '$name' not found"
        _validate_single_pack "$name"
    else
        local has_errors=false
        for dir in "$PACKS_DIR"/*/; do
            [[ ! -d "$dir" ]] && continue
            local pack_name
            pack_name=$(basename "$dir")
            # Output scoping (ADR-0043): only validate packs in the session's scope.
            if ! _env_in_scope pack "$pack_name"; then _env_note_hidden pack; continue; fi
            if ! _validate_single_pack "$pack_name"; then
                has_errors=true
            fi
        done
        _env_flush_hidden_notice
        if [[ "$has_errors" == true ]]; then
            return 1
        fi
    fi
}

# ── Install / Update / Export ──────────────────────────────────────────

cmd_pack_install() {
    local url="" pick="" token="" force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pick)
                [[ -z "${2:-}" ]] && die "--pick requires a pack name"
                pick="$2"; shift 2
                ;;
            --token)
                [[ -z "${2:-}" ]] && die "--token requires a value"
                token="$2"; shift 2
                ;;
            --force) force=true; shift ;;
            --help|-h)
                cat <<'EOF'
Usage: cco pack install <source> [options]

Install packs from a remote sharing repo.

Arguments:
  <source>          Git URL or registered remote name

Options:
  --pick <name>     Install a specific pack by name
  --token <token>   Auth token for HTTPS repos
  --force           Overwrite existing packs without asking

URL can include @ref suffix: <url>@<branch-or-tag>

Examples:
  cco pack install albit --pick alberghi-it
  cco pack install https://github.com/team/config.git
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$url" ]]; then
                    url="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$url" ]] && die "Usage: cco pack install <source> [--pick <name>]\n\n<source> can be a git URL or a registered remote name."
    _store_provenance_guard "pack install"   # D-M8/Q-10: DATA/STATE provenance, cycle-2 conversion
    check_global

    # Resolve remote name → URL + token
    local resolved_url
    resolved_url=$(remote_get_url "$url" 2>/dev/null) || true
    if [[ -n "$resolved_url" ]]; then
        if [[ -z "$token" ]]; then
            token=$(remote_get_token "$url" 2>/dev/null) || true
        fi
        url="$resolved_url"
    fi

    # Parse @ref suffix
    local ref=""
    if [[ "$url" == *@* ]]; then
        # Only treat as ref if it doesn't look like user@host (SSH)
        local after_at="${url##*@}"
        if [[ "$after_at" != *:* && "$after_at" != *.* ]]; then
            ref="$after_at"
            url="${url%@*}"
        fi
    fi

    # Auto-resolve token from registered remote if not explicitly provided
    if [[ -z "$token" ]]; then
        token=$(remote_resolve_token_for_url "$url" 2>/dev/null) || true
    fi

    info "Cloning $url${ref:+ (ref: $ref)}..."
    local tmpdir
    tmpdir=$(_clone_config_repo "$url" "$ref" "$token")
    trap "_cleanup_clone '$tmpdir'" EXIT

    # Capture commit hash for version tracking
    local clone_commit=""
    clone_commit=$(git -C "$tmpdir" rev-parse HEAD 2>/dev/null) || true

    # Detect repo type by structure (ADR-0018 D3 — no manifest.yml): a single-pack
    # repo carries pack.yml at the root; a multi-pack sharing repo carries packs/.
    local single_pack=false
    if [[ -f "$tmpdir/pack.yml" ]]; then
        single_pack=true
    elif [[ -d "$tmpdir/packs" ]]; then
        :  # multi-pack sharing repo
    else
        _cleanup_clone "$tmpdir"
        die "Not a valid sharing repo: no pack.yml (single pack) or packs/ directory found"
    fi

    if $single_pack; then
        # Single-pack repo: install the root as a pack
        local name
        name=$(yml_get "$tmpdir/pack.yml" "name")
        [[ -z "$name" ]] && die "pack.yml has no 'name' field"
        _install_pack_from_dir "$tmpdir" "$name" "$url" "$ref" "" "$force" "$clone_commit"
    else
        # Multi-pack repo: discover available packs by structure
        local available
        available=$(_discover_resources "$tmpdir" packs)

        if [[ -z "$available" ]]; then
            _cleanup_clone "$tmpdir"
            die "No packs found in the sharing repo (packs/<name>/pack.yml)"
        fi

        if [[ -n "$pick" ]]; then
            # Install specific pack
            if ! echo "$available" | grep -qxF "$pick"; then
                _cleanup_clone "$tmpdir"
                die "Pack '$pick' not found in the sharing repo. Available: $(echo "$available" | tr '\n' ' ')"
            fi
            _install_pack_from_dir "$tmpdir/packs/$pick" "$pick" "$url" "$ref" "packs/$pick" "$force" "$clone_commit"
        else
            # Install all packs
            local count=0
            while IFS= read -r name; do
                [[ -z "$name" ]] && continue
                _install_pack_from_dir "$tmpdir/packs/$name" "$name" "$url" "$ref" "packs/$name" "$force" "$clone_commit"
                count=$((count + 1))
            done <<< "$available"
            ok "Installed $count pack(s) from $url"
        fi
    fi

    _cleanup_clone "$tmpdir"
    trap - EXIT
}

# ── cco pack rename ───────────────────────────────────────────────────
# Re-key a pack across every store its name lives in (ADR-0050): the CONFIG store
# dir (packs/<old> → packs/<new>) + its pack.yml `name:`, the id-keyed DATA
# install-provenance + STATE merge base/meta, the per-user tag binding, and the
# `packs[]` reference in every project that uses it (pack names are globally
# scoped — unaffected by ADR-0051's per-project index scoping). Strict (ADR-0031
# D3): refuse if a referencing project has an unresolved member, whose replicated
# project.yml copy would drift under cco sync's clobber-guard.
cmd_pack_rename() {
    local old="" new="" yes=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) yes=true; shift ;;
            --help|-h)
                cat <<'EOF'
Usage: cco pack rename <old> <new>

Rename a knowledge pack, re-keying it across the CONFIG store (packs/<name>/ +
pack.yml name:), the machine-local DATA/STATE sidecars, the per-user tags, and the
packs[] reference in every project that uses it. Every referencing project must be
resolved on this machine (run 'cco resolve' first). After renaming, commit + push
the updated .cco/project.yml in each changed repo and run 'cco sync'.

Options:
  -y, --yes   Skip the confirmation prompt
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1. Run 'cco pack rename --help'." ;;
            *)
                if [[ -z "$old" ]]; then old="$1"
                elif [[ -z "$new" ]]; then new="$1"
                else die "Unexpected argument: $1"; fi
                shift ;;
        esac
    done

    [[ -z "$old" || -z "$new" ]] && die "Usage: cco pack rename <old> <new>"
    [[ "$old" == "$new" ]] && die "Old and new names are the same ('$old') — nothing to rename."

    local old_dir="$PACKS_DIR/$old" new_dir="$PACKS_DIR/$new"
    [[ -d "$old_dir" ]] || die "Pack '$old' not found at packs/$old/."
    _rename_validate pack "$new"
    [[ -e "$new_dir" ]] && die "Pack '$new' already exists at packs/$new/. Choose a different name."

    # ── Strict pre-scan: referencing projects must be fully resolved ────
    # Peel the member record by hand: _project_iter_members' column 2 (path) is EMPTY
    # for an unresolved member, so `IFS=$'\t' read` would fold the middle field and
    # never see status=unresolved (E6B-04). The enumeration is now non-vacuous
    # in-container (index §3.6), so this guard actually classifies mounted members.
    local proj unit yml mname mpath mstatus _mrec
    local -a affected=() blocked=()
    while IFS=$'\t' read -r proj unit yml; do
        _yaml_list_has_ref "$yml" packs "$old" || continue
        affected+=("$proj")
        while IFS= read -r _mrec; do
            [[ -z "$_mrec" ]] && continue
            _peel_tab "$_mrec" mname mpath mstatus
            [[ "$mstatus" == unresolved ]] && blocked+=("$proj:$mname")
        done < <(_project_iter_members "$proj")
    done < <(_project_foreach)
    [[ ${#blocked[@]} -gt 0 ]] && \
        die "Cannot rename pack '$old': unresolved member(s) in referencing project(s): ${blocked[*]}. Run 'cco resolve' first (ADR-0031)."

    # ── Fail-closed pre-flight (RC-3 §3.4 Phase 0) ──────────────────────
    # Crossing #1: the DATA/STATE sidecar re-key must be writable BEFORE any store is
    # touched — never the E6B-04 half-apply of a renamed CONFIG dir with orphaned
    # sidecars. Also carries the unmounted-project census (§3.5): a project referencing
    # this pack that is not mounted here cannot have its packs[] rewritten in-container,
    # so it would drift — refuse (never silently narrow). On the host the census is 0.
    _store_check sidecar-rekey packs "$old" "$new"
    if [[ "${_STORE_REFS:-0}" -gt 0 ]]; then
        die "Cannot rename pack '$old' in this session: $_STORE_REFS project(s) on this machine are not mounted here, so a packs[] reference they may carry cannot be updated (it would drift). Run 'cco pack rename $old $new' on your host, or start a session that mounts them."
    fi

    # ── Preview + confirm (ADR-0029 D2) ─────────────────────────────────
    local -a bullets=(
        "packs/$old/ → packs/$new/ (+ pack.yml name:)"
        "DATA install-provenance + STATE merge base/meta + per-user tags"
    )
    [[ ${#affected[@]} -gt 0 ]] && bullets+=("packs[] reference in project(s): ${affected[*]}")
    _rename_preview_confirm "$yes" "Rename pack '$old' → '$new'" "${bullets[@]}" \
        || { info "Aborted — nothing changed."; return 0; }

    # ── Store re-key ────────────────────────────────────────────────────
    # CONFIG store dir first (claude-owned), then the DATA/STATE sidecar+tags cascade
    # through lib/store.sh (crossing #2, all-or-nothing behind the ADR-0047 boundary).
    mv "$old_dir" "$new_dir" || die "Failed to move packs/$old → packs/$new."
    [[ -f "$new_dir/pack.yml" ]] && _sed_i "$new_dir/pack.yml" "^name:.*" "name: $new"
    _store_apply sidecar-rekey packs "$old" "$new"

    # ── Cross-project packs[] fan-out (delegate to git, P17) ────────────
    local tag val
    local -a changed=()
    while IFS=$'\t' read -r tag val _; do
        [[ "$tag" == changed ]] && changed+=("$val")
    done < <(_rename_fanout_projectyml packs "$old" "$new")

    ok "Renamed pack '$old' → '$new'."
    if [[ ${#changed[@]} -gt 0 ]]; then
        warn "Commit + push the updated .cco/project.yml in each changed repo, then run 'cco sync':"
        printf '%s\n' "${changed[@]}" | sort -u | while IFS= read -r p; do info "  $p"; done
    fi
}

cmd_pack_update() {
    local name="" force=false update_all=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)   update_all=true; shift ;;
            --force) force=true; shift ;;
            --help|-h)
                cat <<'EOF'
Usage: cco pack update <name> [--force]
       cco pack update --all [--force]

Update a pack from its recorded remote source.

Options:
  --all     Update all packs with a remote source
  --force   Overwrite local modifications
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

    _store_provenance_guard "pack update"   # D-M8/Q-10: DATA/STATE provenance, cycle-2 conversion
    check_global

    if $update_all; then
        local updated=0
        local -a failed_packs=()
        for dir in "$PACKS_DIR"/*/; do
            [[ ! -d "$dir" ]] && continue
            local pack_name
            pack_name=$(basename "$dir")
            local source_file
            source_file=$(_cco_pack_source "$dir")
            [[ ! -f "$source_file" ]] && continue
            local source_url
            source_url=$(yml_get "$source_file" "url")
            [[ "$source_url" == "local" || -z "$source_url" ]] && continue
            info "Updating $pack_name..."
            # Isolate errors: run in subshell so die() does not abort the loop
            if ( _update_single_pack "$pack_name" "$force" ); then
                updated=$((updated + 1))
            else
                warn "Failed to update '$pack_name'"
                failed_packs+=("$pack_name")
            fi
        done
        if [[ $updated -eq 0 && ${#failed_packs[@]} -eq 0 ]]; then
            info "No packs with remote sources found"
        elif [[ $updated -gt 0 && ${#failed_packs[@]} -eq 0 ]]; then
            ok "Updated $updated pack(s)"
        fi
        if [[ ${#failed_packs[@]} -gt 0 ]]; then
            error "Failed to update ${#failed_packs[@]} pack(s): ${failed_packs[*]}"
            return 1
        fi
        return 0
    fi

    [[ -z "$name" ]] && die "Usage: cco pack update <name> [--force]"
    [[ ! -d "$PACKS_DIR/$name" ]] && die "Pack '$name' not found"

    _update_single_pack "$name" "$force"
}

cmd_pack_export() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                cat <<'EOF'
Usage: cco pack export <name>

Export a pack as a .tar.gz archive.
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

    [[ -z "$name" ]] && die "Usage: cco pack export <name>"
    [[ ! -d "$PACKS_DIR/$name" ]] && die "Pack '$name' not found"

    local archive="${name}.tar.gz"
    tar czf "$archive" -C "$PACKS_DIR" --exclude='.cco/source' \
        --exclude='.cco/install-tmp' "$name"
    ok "Exported pack to $archive"
}

# Import a pack from a .tar.gz archive — the local-transport counterpart of
# `cco pack export` (the 2×2 "consume" cell; ADR-0018 D2). An exported tar
# carries no upstream coordinate (export omits `source`, which lives in DATA),
# so the import is an **internalized snapshot** recorded as locally-authored
# (`url: local`); `cco pack update` does not apply.
cmd_pack_import() {
    local archive="" force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            --help|-h)
                cat <<'EOF'
Usage: cco pack import <archive> [--force]

Import a pack from a .tar.gz archive (the counterpart of `cco pack export`).
The imported pack is an internalized snapshot (source: local) — `cco pack
update` does not apply. Use --force to overwrite an existing pack.
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$archive" ]]; then
                    archive="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$archive" ]] && die "Usage: cco pack import <archive>"
    [[ -f "$archive" ]] || die "Archive not found: $archive"
    _store_provenance_guard "pack import"   # D-M8/Q-10: DATA/STATE provenance, cycle-2 conversion

    local tmpdir; tmpdir=$(mktemp -d)
    tar xzf "$archive" -C "$tmpdir" 2>/dev/null \
        || { rm -rf "$tmpdir"; die "Failed to extract archive: $archive"; }

    # Locate the pack root: a top-level dir carrying pack.yml (`export` wraps the
    # pack in its <name>/ dir), or pack.yml at the archive root (defensive).
    local pack_root="" d
    if [[ -f "$tmpdir/pack.yml" ]]; then
        pack_root="$tmpdir"
    else
        for d in "$tmpdir"/*/; do
            [[ -f "${d}pack.yml" ]] && { pack_root="${d%/}"; break; }
        done
    fi
    [[ -z "$pack_root" ]] && { rm -rf "$tmpdir"; die "No pack found in archive (missing pack.yml)"; }

    # Identity = the archived dir name, else the pack.yml `name:`.
    local name
    if [[ "$pack_root" != "$tmpdir" ]]; then
        name=$(basename "$pack_root")
    else
        name=$(yml_get "$pack_root/pack.yml" "name")
    fi
    [[ -z "$name" ]] && { rm -rf "$tmpdir"; die "Could not determine pack name from archive"; }

    _install_pack_from_dir "$pack_root" "$name" "local" "" "" "$force"

    rm -rf "$tmpdir"
}

# ── Internal helpers for install/update ────────────────────────────────

# Install a pack from a local directory (clone temp or single-pack root).
# Usage: _install_pack_from_dir <source_dir> <name> <url> <ref> <path> <force> [commit]
_install_pack_from_dir() {
    local source_dir="$1"
    local name="$2"
    local url="$3"
    local ref="$4"
    local path="$5"
    local force="$6"
    local commit="${7:-}"

    local target_dir="$PACKS_DIR/$name"

    # Conflict check
    if [[ -d "$target_dir" ]]; then
        if [[ "$force" == true ]]; then
            rm -rf "$target_dir"
        else
            local existing_source="" existing_src_file
            existing_src_file=$(_cco_pack_source "$target_dir")
            if [[ -f "$existing_src_file" ]]; then
                existing_source=$(yml_get "$existing_src_file" "url")
            fi

            if [[ "$existing_source" == "$url" ]]; then
                info "Pack '$name' already installed from same source — updating"
                rm -rf "$target_dir"
            elif [[ "$existing_source" == "local" ]]; then
                die "Pack '$name' was created locally. Use --force to overwrite."
            else
                die "Pack '$name' already exists (source: ${existing_source:-unknown}). Use --force to overwrite."
            fi
        fi
    fi

    # Copy pack contents
    cp -r "$source_dir" "$target_dir"

    # Remove .git if present (from single-pack repos)
    rm -rf "$target_dir/.git"

    # Write the DATA source provenance (machine-agnostic upstream coordinate
    # only) + the STATE meta bookkeeping (install commit + dates), ADR-0022 D1.
    local now src_file
    now=$(date +%Y-%m-%d)
    src_file=$(_cco_pack_source "$target_dir")
    mkdir -p "$(dirname "$src_file")"
    cat > "$src_file" <<YAML
url: $url
resource: ${path:-}
ref: ${ref:-}
YAML
    _meta_record_provenance "$(_cco_pack_meta "$target_dir")" "${commit:-}" "$now" "$now"

    # Record the installed tree as the pack-scoped STATE base/ — the merge
    # ancestor a future sync-before-publish reuses (ADR-0022 D5).
    _record_pack_base "$target_dir" "$target_dir"

    ok "Installed pack '$name'"
}

# Update a single pack from its recorded source.
# Usage: _update_single_pack <name> <force>
_update_single_pack() {
    local name="$1"
    local force="${2:-false}"
    local source_file
    source_file=$(_cco_pack_source "$PACKS_DIR/$name")

    if [[ ! -f "$source_file" ]]; then
        die "Pack '$name' has no recorded source — cannot determine remote source"
    fi

    local source_url source_ref source_path
    source_url=$(yml_get "$source_file" "url")
    source_ref=$(yml_get "$source_file" "ref")
    source_path=$(yml_get "$source_file" "resource")

    if [[ "$source_url" == "local" || -z "$source_url" ]]; then
        die "Pack '$name' was created locally — no remote source to update from"
    fi

    # Auto-resolve token from registered remote
    local token=""
    token=$(remote_resolve_token_for_url "$source_url" 2>/dev/null) || true

    info "Fetching $source_url${source_ref:+ (ref: $source_ref)}..."
    local tmpdir
    tmpdir=$(_clone_config_repo "$source_url" "$source_ref" "$token")

    # Determine source directory within clone
    local remote_dir="$tmpdir"
    if [[ -n "$source_path" ]]; then
        remote_dir="$tmpdir/$source_path"
    fi

    if [[ ! -d "$remote_dir" ]]; then
        _cleanup_clone "$tmpdir"
        die "Remote path '$source_path' not found in cloned repo"
    fi

    # Capture commit hash for version tracking
    local update_commit=""
    update_commit=$(git -C "$tmpdir" rev-parse HEAD 2>/dev/null) || true

    # Install (force=true since we're explicitly updating). This rewrites the
    # DATA source coordinate and records the new commit + updated date in the
    # STATE meta (_meta_record_provenance) — no separate date bump needed.
    _install_pack_from_dir "$remote_dir" "$name" "$source_url" "$source_ref" "$source_path" true "$update_commit"

    _cleanup_clone "$tmpdir"
    ok "Updated pack '$name'"
}

# ── Pack internalize ─────────────────────────────────────────────────

cmd_pack_internalize() {
    local name="" newname=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --as) [[ -z "${2:-}" ]] && die "--as requires a new pack name"; newname="$2"; shift 2 ;;
            --help|-h)
                cat <<'EOF'
Usage: cco pack internalize <name> [--as <new-name>]

Convert a pack to fully self-contained and locally owned (sever its one external
coupling — the upstream url; ADR-0019 D3/D4, ADR-0023 D4):
  - If pack.yml has knowledge.source, copies referenced files into
    the pack's own knowledge/ directory and removes the source: field.
  - If the pack tracks a remote sharing repo, disconnects by setting its
    recorded url to local (the pack will no longer receive remote updates).

  --as <new-name>   Fork instead of in-place: copy <name> to a new self-contained
                    pack <new-name>; the original stays linked to its source.
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

    [[ -z "$name" ]] && die "Usage: cco pack internalize <name> [--as <new-name>]"
    _store_provenance_guard "pack internalize"   # D-M8/Q-10: DATA/STATE provenance, cycle-2 conversion
    check_global

    local pack_dir="$PACKS_DIR/$name"
    local pack_yml="$pack_dir/pack.yml"
    [[ ! -d "$pack_dir" ]] && die "Pack '$name' not found in packs/."
    [[ ! -f "$pack_yml" ]] && die "Pack '$name': pack.yml not found."

    # --as: fork to a new self-contained pack, leaving the original linked. The
    # copy carries no DATA source, so it is locally-authored by construction; the
    # internalize below then folds in any knowledge.source. (ADR-0023 D4 fork.)
    if [[ -n "$newname" ]]; then
        [[ "$newname" == "$name" ]] && die "--as name must differ from '$name'."
        [[ ! "$newname" =~ ^[a-z0-9][a-z0-9-]*$ ]] && die "Invalid pack name '$newname' (use lowercase letters, digits, hyphens)."
        [[ -d "$PACKS_DIR/$newname" ]] && die "Pack '$newname' already exists."
        cp -R "$pack_dir" "$PACKS_DIR/$newname"
        # Retitle the forked pack.yml (top-level name:).
        local _tmpn; _tmpn=$(mktemp)
        awk -v n="$newname" '!done && /^name:/ { print "name: " n; done=1; next } { print }' \
            "$PACKS_DIR/$newname/pack.yml" > "$_tmpn" && mv "$_tmpn" "$PACKS_DIR/$newname/pack.yml"
        ok "Forked pack '$name' → '$newname' (original stays linked to its source)."
        name="$newname"
        pack_dir="$PACKS_DIR/$newname"
        pack_yml="$pack_dir/pack.yml"
    fi

    local did_something=false

    # ── 1. Knowledge source internalization ───────────────────────────
    local k_source
    k_source=$(yml_get_pack_knowledge_source "$pack_yml")
    if [[ -n "$k_source" ]]; then
        # Expand and validate source path
        local expanded_source
        expanded_source=$(expand_path "$k_source")
        if [[ ! -d "$expanded_source" ]]; then
            die "Knowledge source not found: $k_source (expanded: $expanded_source)"
        fi

        # Get file list and copy
        local k_files
        k_files=$(yml_get_pack_knowledge_files "$pack_yml")
        local count=0
        if [[ -n "$k_files" ]]; then
            mkdir -p "$pack_dir/knowledge"
            while IFS=$'\t' read -r fname desc; do
                [[ -z "$fname" ]] && continue
                local src="$expanded_source/$fname"
                local dst="$pack_dir/knowledge/$fname"
                if [[ -f "$src" ]]; then
                    mkdir -p "$(dirname "$dst")"
                    cp "$src" "$dst"
                    count=$((count + 1))
                else
                    warn "File not found: $src (skipping)"
                fi
            done <<< "$k_files"
        fi

        # Remove source: line from pack.yml
        local tmpfile
        tmpfile=$(mktemp)
        awk '
            /^knowledge:/ { in_k=1; print; next }
            in_k && /^  source:/ { next }
            in_k && /^[^ #]/ { in_k=0 }
            { print }
        ' "$pack_yml" > "$tmpfile"
        mv "$tmpfile" "$pack_yml"

        ok "Knowledge internalized: $count file(s) copied to knowledge/"
        did_something=true
    fi

    # ── 2. Sharing-repo source disconnection ──────────────────────────
    local source_file
    source_file=$(_cco_pack_source "$pack_dir")
    if [[ -f "$source_file" ]]; then
        local source_url
        source_url=$(yml_get "$source_file" "url")
        if [[ -n "$source_url" && "$source_url" != "local" ]]; then
            # Overwrite the DATA source — set url to local, preserve install
            # history as a comment.
            {
                printf 'url: local\n'
                printf '# previously installed from: %s\n' "$source_url"
            } > "$source_file"

            # Clear the cached remote HEAD from the STATE meta if present
            local meta_file
            meta_file=$(_cco_pack_meta "$pack_dir")
            if [[ -f "$meta_file" ]]; then
                yml_remove "$meta_file" "remote_cache"
            fi

            ok "Disconnected from remote source: $source_url"
            did_something=true
        fi
    fi

    # ── 3. Report if nothing to do ────────────────────────────────────
    if [[ "$did_something" != "true" ]]; then
        ok "Pack '$name' is already self-contained (no knowledge source, no remote tracking)"
    fi
}

# ── Pack publish ─────────────────────────────────────────────────────

# ── Sync-before-publish helpers (ADR-0022 D5 / design §6.2) ──────────────

# Whole-file equality treating "absent" as a content state: both-absent → equal,
# one-absent → not equal, else byte-compare. Used by the 3-way tree merge so that
# adds/deletes resolve naturally.
_pack_merge_eq() {
    local a="$1" b="$2"
    if [[ ! -e "$a" && ! -e "$b" ]]; then return 0; fi
    if [[ ! -e "$a" || ! -e "$b" ]]; then return 1; fi
    cmp -s "$a" "$b"
}

# Copy a file, creating its parent directory.
_pack_merge_put() {
    mkdir -p "$(dirname "$2")"
    cp "$1" "$2"
}

# Whole-file 3-way tree merge for sync-before-publish (ADR-0022 D5 — NOT
# line-level: D5 mandates abort-on-conflict, so update-merge.sh's _merge_file
# conflict-marker path is deliberately not used here).
# Usage: _pack_sync_merge <base_dir> <ours_dir> <theirs_dir> <out_dir>
# Any input dir may be absent/empty (treated as "no files"). Per relative file,
# over the union of the three trees:
#   ours == theirs            → take ours   (no divergence either way)
#   ours == base (unchanged)  → take theirs (theirs holds the change/delete)
#   theirs == base (unchanged)→ take ours    (ours holds the change/delete)
#   else (both diverged)      → CONFLICT
# Writes the merged tree into <out_dir> (recreated). Returns 0 = clean,
# 1 = conflict (conflicting paths printed to stderr; out_dir is then discarded
# by the caller). Never blind-overwrites a co-maintainer's remote-only work (P16).
_pack_sync_merge() {
    local base_dir="$1" ours_dir="$2" theirs_dir="$3" out_dir="$4"
    rm -rf "$out_dir"
    mkdir -p "$out_dir"

    # Union of relative file paths across the three trees (sorted, de-duped).
    local rels d
    rels=$(
        {
            for d in "$base_dir" "$ours_dir" "$theirs_dir"; do
                [[ -d "$d" ]] && ( cd "$d" && find . -type f 2>/dev/null )
            done
            true
        } | sed 's|^\./||' | sort -u
    )

    local conflict=0 rel b o t
    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        b="$base_dir/$rel"; o="$ours_dir/$rel"; t="$theirs_dir/$rel"
        if _pack_merge_eq "$o" "$t"; then
            [[ -f "$o" ]] && _pack_merge_put "$o" "$out_dir/$rel"
        elif _pack_merge_eq "$o" "$b"; then
            [[ -f "$t" ]] && _pack_merge_put "$t" "$out_dir/$rel"
        elif _pack_merge_eq "$t" "$b"; then
            [[ -f "$o" ]] && _pack_merge_put "$o" "$out_dir/$rel"
        else
            conflict=1
            printf '  conflict: %s\n' "$rel" >&2
        fi
    done <<< "$rels"

    return $conflict
}

# Record a tree at an explicit STATE base/ location — the local, never-sync merge
# ancestor for the next sync-before-publish (ADR-0022 D5 / ADR-0013 D2). Generic
# (reused by pack and template publish/install). <tree_dir> is copied verbatim
# minus any local-only .cco.
# Usage: _record_tree_as_base <base_dir> <tree_dir>
_record_tree_as_base() {
    local base_dir="$1" tree_dir="$2"
    rm -rf "$base_dir"
    mkdir -p "$(dirname "$base_dir")"
    cp -R "$tree_dir" "$base_dir"
    rm -rf "$base_dir/.cco"
}

# Record a published/installed pack tree as the pack-scoped STATE base/.
# Usage: _record_pack_base <pack_dir> <tree_dir>
_record_pack_base() {
    _record_tree_as_base "$(_cco_pack_base_dir "$1")" "$2"
}

# Bake a pack's knowledge.source into <dir> (publish-time internalization): copy
# the referenced knowledge files into <dir>/knowledge/ and strip knowledge.source
# from <dir>/pack.yml. No-op when the pack declares no knowledge.source.
_pack_internalize_knowledge() {
    local dir="$1"
    local k_source
    k_source=$(yml_get_pack_knowledge_source "$dir/pack.yml")
    [[ -z "$k_source" ]] && return 0

    info "Internalizing knowledge from $k_source..."
    local expanded_source
    expanded_source=$(expand_path "$k_source")
    if [[ ! -d "$expanded_source" ]]; then
        warn "Knowledge source not found: $k_source — publishing without internalization"
        return 0
    fi

    local k_files
    k_files=$(yml_get_pack_knowledge_files "$dir/pack.yml")
    mkdir -p "$dir/knowledge"
    while IFS=$'\t' read -r fname desc; do
        [[ -z "$fname" ]] && continue
        local src="$expanded_source/$fname"
        if [[ -f "$src" ]]; then
            mkdir -p "$(dirname "$dir/knowledge/$fname")"
            cp "$src" "$dir/knowledge/$fname"
        else
            warn "Knowledge file not found: $src"
        fi
    done <<< "$k_files"

    # Remove source: from the published pack.yml
    local tmpf; tmpf=$(mktemp)
    awk '
        /^knowledge:/ { in_k=1; print; next }
        in_k && /^  source:/ { next }
        in_k && /^[^ #]/ { in_k=0 }
        { print }
    ' "$dir/pack.yml" > "$tmpf"
    mv "$tmpf" "$dir/pack.yml"
}

cmd_pack_publish() {
    local name="" remote_arg="" message="" dry_run=false force=false token=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --message)
                [[ -z "${2:-}" ]] && die "--message requires a value"
                message="$2"; shift 2 ;;
            --dry-run)  dry_run=true; shift ;;
            --force)    force=true; shift ;;
            --token)
                [[ -z "${2:-}" ]] && die "--token requires a value"
                token="$2"; shift 2 ;;
            --help|-h)
                cat <<'EOF'
Usage: cco pack publish <name> [<remote>] [OPTIONS]

Publish a pack to a remote sharing repo.

Arguments:
  <name>             Pack to publish
  <remote>           Remote name or URL (default: re-derived from the pack's
                     recorded upstream against your registered remotes)

Options:
  --message <msg>    Commit message (default: "publish pack <name>")
  --dry-run          Show what would be published, don't push
  --force            Overwrite the remote pack with your local version,
                     skipping the sync-before-publish merge (opt-in clobber)
  --token <token>    Auth token for HTTPS remotes
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                elif [[ -z "$remote_arg" ]]; then
                    remote_arg="$1"
                else
                    die "Unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    [[ -z "$name" ]] && die "Usage: cco pack publish <name> [<remote>]"

    local pack_dir="$PACKS_DIR/$name"
    [[ ! -f "$pack_dir/pack.yml" ]] && die "Pack '$name' not found."

    # Resolve remote URL
    local remote_url="" remote_name=""
    _resolve_publish_remote "$remote_arg" "$pack_dir" remote_url remote_name

    [[ -z "$message" ]] && message="publish pack $name"

    # Auto-resolve token from remote if not explicitly provided
    if [[ -z "$token" ]]; then
        if [[ -n "$remote_name" ]]; then
            token=$(remote_get_token "$remote_name" 2>/dev/null) || true
        else
            token=$(remote_resolve_token_for_url "$remote_url" 2>/dev/null) || true
        fi
    fi

    info "Publishing pack '$name' to $remote_url..."

    # Clone remote repo (push-ready)
    local tmpdir
    tmpdir=$(_clone_for_publish "$remote_url" "$token")
    trap "_cleanup_clone '$tmpdir'" EXIT

    # ── Prepare OURS: the publishable form of the local pack ────────────
    # Copy the local pack, drop the local-only framework dir (provenance lives
    # in DATA since ADR-0022 D1), and bake any knowledge.source. Staged outside
    # the published tree so it is never committed.
    local ours_dir="$tmpdir/.cco-ours"
    cp -R "$pack_dir" "$ours_dir"
    rm -rf "$ours_dir/.cco"
    _pack_internalize_knowledge "$ours_dir"

    # ── Sync-before-publish (ADR-0022 D5 / design §6.2) ─────────────────
    # theirs = the co-maintainer's current remote tree (absent on a first
    # publish to an empty repo); base = the pack-scoped STATE merge ancestor
    # (the tree we last published/installed; absent before any). The 3-way merge
    # auto-applies non-conflicting divergence and aborts on a real conflict —
    # it never blind-overwrites a co-maintainer's remote-only work (P16). With
    # base+theirs empty the merge degenerates to "publish ours" (first publish).
    local theirs_dir="$tmpdir/packs/$name"
    local merged_dir="$tmpdir/.cco-merged" base_dir
    base_dir=$(_cco_pack_base_dir "$pack_dir")

    if $force; then
        # Explicit, opt-in escape hatch: replace the remote pack with our local
        # version, skipping the merge (deliberate clobber of any divergence).
        [[ -d "$theirs_dir" ]] && \
            warn "--force: overwriting the remote copy of '$name' with your local version."
        rm -rf "$merged_dir"
        cp -R "$ours_dir" "$merged_dir"
    else
        local merge_rc=0
        _pack_sync_merge "$base_dir" "$ours_dir" "$theirs_dir" "$merged_dir" || merge_rc=$?
        if [[ $merge_rc -ne 0 ]]; then
            _cleanup_clone "$tmpdir"; trap - EXIT
            if $dry_run; then
                warn "Would conflict with co-maintainer changes on the remote (files above)."
                info "Run 'cco pack update $name' first, or republish with --force to overwrite."
                return 0
            fi
            die "Publish would clobber co-maintainer changes on the remote (conflicting files above).
  Run 'cco pack update $name' to merge the remote changes locally, then republish.
  Or 'cco pack publish $name --force' to overwrite the remote with your version."
        fi
    fi

    # Place the merged (publishable) tree into the clone, then drop the staging
    # dirs so they never reach the commit.
    rm -rf "$theirs_dir"
    mkdir -p "$tmpdir/packs"
    cp -R "$merged_dir" "$theirs_dir"
    rm -rf "$merged_dir" "$ours_dir"

    if $dry_run; then
        echo ""
        echo -e "${BOLD}Would publish:${NC}"
        echo "  Pack: $name"
        echo "  Remote: $remote_url"
        echo "  Files:"
        find "$theirs_dir" -type f | sed "s|$tmpdir/||; s/^/    /"
        _cleanup_clone "$tmpdir"
        trap - EXIT
        ok "Dry run complete — nothing pushed"
        return 0
    fi

    # Commit and push (skip cleanly when the remote already matches our version).
    git -C "$tmpdir" add -A
    if git -C "$tmpdir" diff --cached --quiet; then
        info "Remote already up to date — nothing to publish."
    else
        git -C "$tmpdir" commit -q -m "$message"
        git -C "$tmpdir" push origin HEAD >/dev/null 2>&1 \
            || { _cleanup_clone "$tmpdir"; trap - EXIT; die "Failed to push to $remote_url"; }
    fi

    # Record the published tree as the new pack-scoped STATE base/ — the merge
    # ancestor for the next sync-before-publish (ADR-0022 D5).
    _record_pack_base "$pack_dir" "$theirs_dir"

    # Record the published url as the pack's upstream coordinate (working-copy
    # model, P16): the sharing repo is now the source-of-truth, so a subsequent
    # `cco pack publish <name>` re-derives this remote on demand (F4) without a
    # stored publish_target.
    _record_pack_publish_url "$pack_dir" "$remote_url"

    _cleanup_clone "$tmpdir"
    trap - EXIT
    ok "Published pack '$name' to $remote_url"
}

# Resolve remote for publish: name → URL. With no explicit arg, re-derive the
# default remote (F4 / ADR-0022 D1) by reverse-looking-up the pack's recorded
# upstream `url` against the DATA remotes registry — no stored publish_target.
_resolve_publish_remote() {
    local remote_arg="$1" pack_dir="$2"
    # Output: sets the url var ($3) and the remote-name var ($4) in caller scope

    if [[ -n "$remote_arg" ]]; then
        # Try as registered remote name first
        local resolved
        if resolved=$(remote_get_url "$remote_arg"); then
            eval "$3=\$resolved"
            eval "$4=\$remote_arg"
            return 0
        fi
        # Treat as direct URL if contains : or /
        if [[ "$remote_arg" == *:* || "$remote_arg" == */* ]]; then
            eval "$3=\$remote_arg"
            eval "$4="
            return 0
        fi
        die "Remote '$remote_arg' not found. Register with 'cco remote add $remote_arg <url>'."
    fi

    # Re-derive from the recorded upstream coordinate: reverse-lookup its url
    # in the remotes registry (F4). The url is itself a usable push target even
    # when not registered (the name is then empty; token auto-resolve may fail).
    local src_file recorded_url
    src_file=$(_cco_pack_source "$pack_dir")
    if [[ -f "$src_file" ]]; then
        recorded_url=$(yml_get "$src_file" "url")
        if [[ -n "$recorded_url" && "$recorded_url" != "local" ]]; then
            local rname
            if rname=$(remote_get_name_for_url "$recorded_url"); then
                eval "$3=\$recorded_url"
                eval "$4=\$rname"
                return 0
            fi
            # Reachable url but not a registered remote — push to it directly.
            eval "$3=\$recorded_url"
            eval "$4="
            return 0
        fi
    fi

    die "No remote specified and the pack has no registered upstream. Usage: cco pack publish <name> <remote>"
}

# Record the upstream url the pack was published to in its DATA source (so the
# default remote can be re-derived on the next publish — F4). Replaces the old
# stored publish_target.
_record_pack_publish_url() {
    local pack_dir="$1" url="$2"
    [[ -z "$url" ]] && return 0
    local source_file
    source_file=$(_cco_pack_source "$pack_dir")
    mkdir -p "$(dirname "$source_file")"
    if [[ -f "$source_file" ]]; then
        _sed_i_or_append "$source_file" "url" "$url"
    else
        printf 'url: %s\n' "$url" > "$source_file"
    fi
}
