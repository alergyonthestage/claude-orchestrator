#!/usr/bin/env bash
# lib/cmd-project-publish.sh — Publish projects to Config Repos
#
# Provides: cmd_project_publish(), _publish_per_file_review(),
#           _copy_project_for_publish(), _publish_pack_to_tmpdir(),
#           _read_publish_ignore()
# Dependencies: colors.sh, utils.sh, yaml.sh, remote.sh, manifest.sh, paths.sh, update.sh
# Globals: PROJECTS_DIR, PACKS_DIR

# Read .cco/publish-ignore patterns from <file>.
# Skips empty lines and comment lines (#...). Emits one pattern per line
# on stdout. Canonical reader used by both the pre-publish secret scan
# and _copy_project_for_publish — do not inline this logic.
_read_publish_ignore() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local line
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        printf '%s\n' "$line"
    done < "$file"
}

cmd_project_publish() {
    local name="" remote_arg="" message="" dry_run=false force=false
    local token="" include_packs=true yes_mode=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --message)
                [[ -z "${2:-}" ]] && die "--message requires a value"
                message="$2"; shift 2 ;;
            --dry-run)        dry_run=true; shift ;;
            --force)          force=true; shift ;;
            --yes)            yes_mode=true; shift ;;
            --token)
                [[ -z "${2:-}" ]] && die "--token requires a value"
                token="$2"; shift 2 ;;
            --no-packs)       include_packs=false; shift ;;
            --help)
                cat <<'EOF'
Usage: cco project publish <name> [<remote>] [OPTIONS]

Publish a project template to a remote Config Repo with safety checks:
migration validation, secret scan, framework alignment, and diff review.

Arguments:
  <name>             Project to publish
  <remote>           Remote name or URL

Options:
  --message <msg>    Commit message (default: "publish project <name>")
  --dry-run          Show what would be published, don't push
  --force            Overwrite remote version without confirmation
  --yes              Skip interactive prompts (safety checks still apply)
  --no-packs         Don't bundle project's packs
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

    [[ -z "$name" ]] && die "Usage: cco project publish <name> [<remote>]"

    local project_dir="$PROJECTS_DIR/$name"
    local project_yml="$project_dir/project.yml"
    [[ ! -f "$project_yml" ]] && die "Project '$name' not found."

    [[ -z "$remote_arg" ]] && die "Remote required. Usage: cco project publish <name> <remote>"

    # Resolve remote URL
    local remote_url="" remote_is_named=false
    local resolved
    if resolved=$(remote_get_url "$remote_arg"); then
        remote_url="$resolved"
        remote_is_named=true
    elif [[ "$remote_arg" == *:* || "$remote_arg" == */* ]]; then
        remote_url="$remote_arg"
    else
        die "Remote '$remote_arg' not found. Register with 'cco remote add $remote_arg <url>'."
    fi

    # Auto-resolve token from remote if not explicitly provided
    if [[ -z "$token" ]]; then
        if $remote_is_named; then
            token=$(remote_get_token "$remote_arg" 2>/dev/null) || true
        else
            token=$(remote_resolve_token_for_url "$remote_url" 2>/dev/null) || true
        fi
    fi

    [[ -z "$message" ]] && message="publish project $name"

    # ── Pre-publish safety pipeline ──────────────────────────────────

    # STEP 1: MIGRATION CHECK (blocking)
    # Block publish if project has a schema_version that is behind the latest.
    # Projects without .cco/meta (schema=0) are not checked — they predate the
    # migration system and will be migrated on first `cco update`.
    local meta_file
    meta_file=$(_cco_project_meta "$project_dir")
    local current_schema
    current_schema=$(_read_cco_meta "$meta_file")
    local latest_schema
    latest_schema=$(_latest_schema_version "project")
    if [[ "$current_schema" -gt 0 && "$current_schema" -lt "$latest_schema" ]]; then
        error "Project '$name' has pending migrations (schema: $current_schema, latest: $latest_schema)."
        die "Run 'cco update' first to apply migrations."
    fi

    # STEP 2: FRAMEWORK ALIGNMENT CHECK (warning)
    local defaults_dir
    defaults_dir=$(_resolve_project_defaults_dir "$project_dir")
    local base_dir
    base_dir=$(_cco_project_base_dir "$project_dir")
    local fw_changes
    fw_changes=$(_collect_file_changes "$defaults_dir" "$project_dir/.claude" "$base_dir" "project")
    local fw_actionable
    fw_actionable=$(echo "$fw_changes" | grep -cvE '^(NO_UPDATE|USER_MODIFIED|$)' || true)

    if [[ $fw_actionable -gt 0 ]]; then
        warn "$fw_actionable framework default(s) have updates not yet applied."
        warn "Run 'cco update --sync $name' to review before publishing."
        if [[ "$yes_mode" != "true" && -t 0 ]]; then
            printf "Continue anyway? [y/N] " >&2
            local reply
            read -r reply < /dev/tty
            [[ ! "$reply" =~ ^[Yy]$ ]] && die "Aborted."
        fi
    fi

    # STEP 3: SECRET SCAN (blocking)
    # Two-pass scan on files that would actually be published:
    #   Pass 1: filename patterns (*.env, *.key, *.pem, .credentials.json, .netrc)
    #   Pass 2: content patterns (API_KEY=, SECRET=, PASSWORD=, token strings)
    # Excludes: .cco/, memory/, secrets.env (same as _copy_project_for_publish)
    # Also applies .cco/publish-ignore patterns so excluded files are not scanned.
    local -a secret_hits=()
    local -a _publishable_files=()

    # Read .cco/publish-ignore patterns (shared helper with _copy_project_for_publish)
    local -a _scan_ignore_patterns=()
    local _ig_line
    while IFS= read -r _ig_line; do
        [[ -n "$_ig_line" ]] && _scan_ignore_patterns+=("$_ig_line")
    done < <(_read_publish_ignore "$project_dir/.cco/publish-ignore")

    # Set up temp git repo for publish-ignore matching if patterns exist
    local _scan_ignore_dir=""
    if [[ ${#_scan_ignore_patterns[@]} -gt 0 ]]; then
        _scan_ignore_dir=$(mktemp -d)
        git -C "$_scan_ignore_dir" init -q 2>/dev/null || true
        printf '%s\n' "${_scan_ignore_patterns[@]}" > "$_scan_ignore_dir/.gitignore"
    fi

    # Collect all publishable files
    local -a _scan_dirs=()
    [[ -d "$project_dir/.claude" ]] && _scan_dirs+=("$project_dir/.claude")
    for _root_item in "$project_dir"/*; do
        [[ ! -e "$_root_item" ]] && continue
        local _root_base
        _root_base=$(basename "$_root_item")
        case "$_root_base" in
            .cco|.claude|memory|secrets.env) continue ;;
        esac
        [[ -f "$_root_item" ]] && _scan_dirs+=("$_root_item")
    done

    for _scan_target in "${_scan_dirs[@]+"${_scan_dirs[@]}"}"; do
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            [[ "$file" == */.cco/* ]] && continue
            # Apply publish-ignore filter: check if file matches any pattern
            if [[ -n "$_scan_ignore_dir" ]]; then
                local _scan_rel="${file#$project_dir/}"
                if git -C "$_scan_ignore_dir" check-ignore -q "$_scan_rel" 2>/dev/null; then
                    continue
                fi
            fi
            _publishable_files+=("$file")
        done < <(find "$_scan_target" -type f 2>/dev/null)
    done

    # Clean up temp git repo for ignore matching
    [[ -n "$_scan_ignore_dir" ]] && rm -rf "$_scan_ignore_dir"

    # Pass 1: filename match (canonical patterns in lib/secrets.sh)
    for file in "${_publishable_files[@]+"${_publishable_files[@]}"}"; do
        local match_pattern
        if match_pattern=$(_secret_match_filename "$file"); then
            secret_hits+=("${file#$project_dir/} (filename match: $match_pattern)")
        fi
    done

    # Pass 2: content match (canonical patterns in lib/secrets.sh)
    for file in "${_publishable_files[@]+"${_publishable_files[@]}"}"; do
        local match_info
        if match_info=$(_secret_match_content "$file"); then
            local rel="${file#$project_dir/}"
            local match_line="${match_info%%:*}"
            local match_pattern="${match_info#*:}"
            secret_hits+=("$rel:$match_line (content match: $match_pattern)")
        fi
    done

    if [[ ${#secret_hits[@]} -gt 0 ]]; then
        error "Potential secrets detected in publishable files:"
        for f in "${secret_hits[@]}"; do
            error "  - $f"
        done
        die "Remove secrets or add to .cco/publish-ignore"
    fi

    info "Publishing project '$name' to $remote_url..."

    # Clone remote repo
    local tmpdir
    tmpdir=$(_clone_for_publish "$remote_url" "$token")
    trap "_cleanup_clone '$tmpdir'" EXIT

    # Check for existing template on remote
    if [[ -d "$tmpdir/templates/$name" ]]; then
        if ! $force && ! $dry_run && [[ "$yes_mode" != "true" ]]; then
            warn "Template '$name' already exists on remote."
            if [[ -t 0 ]]; then
                printf "Overwrite? [y/N] " >&2
                local reply; read -r reply
                [[ ! "$reply" =~ ^[Yy]$ ]] && { _cleanup_clone "$tmpdir"; die "Aborted."; }
            else
                _cleanup_clone "$tmpdir"
                die "Template exists on remote. Use --force or --yes to overwrite."
            fi
        fi
        rm -rf "$tmpdir/templates/$name"
    fi

    # Copy project to templates/<name>/
    mkdir -p "$tmpdir/templates/$name"
    _copy_project_for_publish "$project_dir" "$tmpdir/templates/$name"

    # Sanitize paths: replace local paths with @local markers, inject url: fields
    _sanitize_project_paths "$tmpdir/templates/$name/project.yml"

    # Bundle packs if requested
    local -a published_packs=()
    if $include_packs; then
        local project_packs
        project_packs=$(yml_get_packs "$project_yml")
        while IFS= read -r pack_name; do
            [[ -z "$pack_name" ]] && continue
            if [[ -d "$PACKS_DIR/$pack_name" ]]; then
                # Copy pack to remote (internalize if needed)
                _publish_pack_to_tmpdir "$pack_name" "$tmpdir"
                published_packs+=("$pack_name")
            else
                warn "Pack '$pack_name' not found locally — skipping"
            fi
        done <<< "$project_packs"
    fi

    # Refresh manifest in temp dir
    manifest_refresh "$tmpdir"

    if $dry_run; then
        echo ""
        echo -e "${BOLD}Would publish:${NC}"
        echo "  Template: $name"
        if [[ ${#published_packs[@]} -gt 0 ]]; then
            echo "  Packs: ${published_packs[*]}"
        fi
        echo "  Remote: $remote_url"
        echo ""

        # Show diff for dry-run
        git -C "$tmpdir" add -A 2>/dev/null
        local diff_stat
        diff_stat=$(git -C "$tmpdir" diff --cached --stat 2>/dev/null)
        if [[ -n "$diff_stat" ]]; then
            echo -e "${BOLD}Changes vs published version:${NC}"
            echo "$diff_stat" | sed 's/^/  /'
        else
            echo "  No changes vs published version."
        fi

        _cleanup_clone "$tmpdir"
        trap - EXIT
        ok "Dry run complete — nothing pushed"
        return 0
    fi

    # STEP 6: DIFF REVIEW (interactive)
    # Show changes vs last published version and confirm
    git -C "$tmpdir" add -A 2>/dev/null
    local diff_stat
    diff_stat=$(git -C "$tmpdir" diff --cached --stat 2>/dev/null)

    if [[ -n "$diff_stat" ]]; then
        echo ""
        echo -e "${BOLD}Changes vs published version:${NC}"
        echo "$diff_stat" | sed 's/^/  /'
        echo ""

        # STEP 7: PER-FILE CONFIRMATION (interactive)
        if [[ "$yes_mode" != "true" && -t 0 ]]; then
            # Collect changed files
            local -a changed_files=()
            while IFS= read -r cfile; do
                [[ -z "$cfile" ]] && continue
                changed_files+=("$cfile")
            done < <(git -C "$tmpdir" diff --cached --name-only 2>/dev/null)

            if [[ ${#changed_files[@]} -gt 5 ]]; then
                # Many files: bulk confirm
                printf "Publish all %d changed files? [Y/n/review] " "${#changed_files[@]}" >&2
                local bulk_reply
                read -r bulk_reply < /dev/tty
                case "$bulk_reply" in
                    [Nn])
                        _cleanup_clone "$tmpdir"
                        trap - EXIT
                        die "Aborted."
                        ;;
                    review|r)
                        # Fall through to per-file review
                        _publish_per_file_review "$tmpdir" "${changed_files[@]}"
                        ;;
                esac
            else
                # Few files: per-file review
                _publish_per_file_review "$tmpdir" "${changed_files[@]}"
            fi
        fi
    else
        info "No changes vs published version."
    fi

    # Commit and push (re-add in case per-file review unstaged some)
    git -C "$tmpdir" add -A 2>/dev/null
    local has_changes
    has_changes=$(git -C "$tmpdir" diff --cached --quiet 2>/dev/null && echo "no" || echo "yes")
    if [[ "$has_changes" == "no" ]]; then
        _cleanup_clone "$tmpdir"
        trap - EXIT
        ok "No changes to publish."
        return 0
    fi
    git -C "$tmpdir" commit -q -m "$message"
    local publish_commit
    publish_commit=$(git -C "$tmpdir" rev-parse HEAD 2>/dev/null) || true
    git -C "$tmpdir" push origin HEAD >/dev/null 2>&1 \
        || { _cleanup_clone "$tmpdir"; die "Failed to push to $remote_url"; }

    _cleanup_clone "$tmpdir"
    trap - EXIT

    # Update publish metadata in .cco/source
    local source_file
    source_file=$(_cco_project_source "$project_dir")
    if [[ ! -f "$source_file" ]]; then
        # Create .cco/source for locally-created projects (track publish history)
        mkdir -p "$(dirname "$source_file")"
        printf 'source: local\n' > "$source_file"
    fi
    yml_set "$source_file" "published" "$(date +%Y-%m-%d)"
    [[ -n "$publish_commit" ]] && yml_set "$source_file" "publish_commit" "$publish_commit"

    local summary="Published project '$name'"
    if [[ ${#published_packs[@]} -gt 0 ]]; then
        summary+=" with packs: ${published_packs[*]}"
    fi
    ok "$summary"
}

# Interactive per-file review for publish.
# Shows diff for each changed file, asks (P)ublish/(S)kip/(D)iff/(A)bort.
# Skipped files are unstaged (git reset) so they won't be committed.
# Usage: _publish_per_file_review <tmpdir> <file1> [file2 ...]
_publish_per_file_review() {
    local tmpdir="$1"
    shift
    local -a files=("$@")
    local skipped=0

    for file in "${files[@]}"; do
        local status_char
        status_char=$(git -C "$tmpdir" diff --cached --name-status -- "$file" 2>/dev/null | cut -f1)
        local label="M"
        case "$status_char" in
            A) label="NEW" ;;
            D) label="DEL" ;;
            M) label="MOD" ;;
        esac

        printf "\n  %s [%s]\n" "$file" "$label" >&2
        printf "  (P)ublish / (S)kip / (D)iff / (A)bort: " >&2
        local reply
        read -r reply < /dev/tty

        case "$reply" in
            [Dd])
                # Show diff, then re-ask
                echo "" >&2
                git -C "$tmpdir" diff --cached -- "$file" 2>/dev/null | head -80 >&2
                echo "" >&2
                printf "  (P)ublish / (S)kip / (A)bort: " >&2
                read -r reply < /dev/tty
                case "$reply" in
                    [Ss]) git -C "$tmpdir" reset -q HEAD -- "$file" 2>/dev/null; skipped=$((skipped + 1)) ;;
                    [Aa]) die "Aborted." ;;
                    # Default: publish (keep staged)
                esac
                ;;
            [Ss])
                git -C "$tmpdir" reset -q HEAD -- "$file" 2>/dev/null
                skipped=$((skipped + 1))
                ;;
            [Aa])
                die "Aborted."
                ;;
            # Default (P or enter): publish (keep staged)
        esac
    done

    if [[ $skipped -gt 0 ]]; then
        info "Skipped $skipped file(s) from this publish."
    fi
}

# Copy project files for publishing, excluding runtime/generated files.
# Reads .cco/publish-ignore for additional exclusion patterns.
_copy_project_for_publish() {
    local src="$1" dst="$2"

    # Copy everything except excluded patterns
    local -a excludes=(
        ".cco"
        "memory"
        "secrets.env"
    )

    # Read .cco/publish-ignore patterns (shared helper)
    local -a ignore_patterns=()
    local _ig_line
    while IFS= read -r _ig_line; do
        [[ -n "$_ig_line" ]] && ignore_patterns+=("$_ig_line")
    done < <(_read_publish_ignore "$src/.cco/publish-ignore")

    # Build rsync-like exclusion via find + copy
    find "$src" -mindepth 1 -maxdepth 1 | while IFS= read -r item; do
        local base
        base=$(basename "$item")
        local skip=false
        for excl in "${excludes[@]}"; do
            [[ "$base" == "$excl" ]] && { skip=true; break; }
        done
        $skip && continue
        cp -R "$item" "$dst/"
    done

    # Remove nested .cco/ directories that were copied inside .claude/
    find "$dst" -mindepth 2 -name ".cco" -type d -exec rm -rf {} + 2>/dev/null || true

    # Apply publish-ignore patterns using a temporary .gitignore in a git repo
    # for full gitignore semantics (**, directory trails, path patterns)
    if [[ ${#ignore_patterns[@]} -gt 0 ]]; then
        # Init temp git repo for check-ignore
        git -C "$dst" init -q 2>/dev/null || true

        # Write patterns as .gitignore
        printf '%s\n' "${ignore_patterns[@]}" > "$dst/.gitignore"

        # Collect all files, check each against ignore patterns
        while IFS= read -r rel_path; do
            [[ -z "$rel_path" ]] && continue
            [[ "$rel_path" == .git/* || "$rel_path" == ".gitignore" ]] && continue
            if git -C "$dst" check-ignore -q "$rel_path" 2>/dev/null; then
                rm -rf "$dst/$rel_path"
            fi
        done < <(cd "$dst" && find . -mindepth 1 -not -path './.git/*' -print | sed 's|^\./||')

        # Remove empty directories left behind
        find "$dst" -mindepth 1 -type d -empty -delete 2>/dev/null || true

        # Clean up temp git repo and .gitignore
        rm -rf "$dst/.git" "$dst/.gitignore"
    fi
}

# Publish a pack into a tmpdir for bundling with a project.
_publish_pack_to_tmpdir() {
    local pack_name="$1" tmpdir="$2"
    local pack_dir="$PACKS_DIR/$pack_name"

    mkdir -p "$tmpdir/packs"
    if [[ -d "$tmpdir/packs/$pack_name" ]]; then
        rm -rf "$tmpdir/packs/$pack_name"
    fi
    cp -R "$pack_dir" "$tmpdir/packs/$pack_name"
    rm -rf "$tmpdir/packs/$pack_name/.cco"

    # Internalize if source-referencing
    local k_source=""
    k_source=$(yml_get_pack_knowledge_source "$tmpdir/packs/$pack_name/pack.yml")
    if [[ -n "$k_source" ]]; then
        local expanded_source
        expanded_source=$(expand_path "$k_source")
        if [[ -d "$expanded_source" ]]; then
            local k_files
            k_files=$(yml_get_pack_knowledge_files "$tmpdir/packs/$pack_name/pack.yml")
            mkdir -p "$tmpdir/packs/$pack_name/knowledge"
            while IFS=$'\t' read -r fname desc; do
                [[ -z "$fname" ]] && continue
                local src="$expanded_source/$fname"
                if [[ -f "$src" ]]; then
                    mkdir -p "$(dirname "$tmpdir/packs/$pack_name/knowledge/$fname")"
                    cp "$src" "$tmpdir/packs/$pack_name/knowledge/$fname"
                fi
            done <<< "$k_files"

            local tmpf; tmpf=$(mktemp)
            awk '
                /^knowledge:/ { in_k=1; print; next }
                in_k && /^  source:/ { next }
                in_k && /^[^ #]/ { in_k=0 }
                { print }
            ' "$tmpdir/packs/$pack_name/pack.yml" > "$tmpf"
            mv "$tmpf" "$tmpdir/packs/$pack_name/pack.yml"
        fi
    fi
}
