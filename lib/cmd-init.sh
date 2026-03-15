#!/usr/bin/env bash
# lib/cmd-init.sh — Initialize user configuration command
#
# Provides: cmd_init()
# Dependencies: colors.sh, utils.sh, update.sh, cmd-build.sh, manifest.sh
# Globals: USER_CONFIG_DIR, GLOBAL_DIR, DEFAULTS_DIR, NATIVE_TEMPLATES_DIR, PROJECTS_DIR, PACKS_DIR, TEMPLATES_DIR, REPO_ROOT

cmd_init() {
    local force=false
    local lang_arg=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            --lang)
                [[ -z "${2:-}" ]] && die "--lang requires a value (e.g. --lang Italian)"
                lang_arg="$2"; shift 2 ;;
            --help)
                cat <<'EOF'
Usage: cco init [--force] [--lang <language>]

Initialize user configuration by copying defaults.

Options:
  --force                Overwrite existing global/ config with defaults
  --lang <lang>          Set languages non-interactively.
                         Single value: cco init --lang Italian
                         Three values:  cco init --lang "Italian:Italian:English"
                         Format: communication[:docs[:code]]
EOF
                return 0
                ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    # Language selection
    local comm_lang docs_lang code_lang
    if [[ -n "$lang_arg" ]]; then
        # Parse --lang value (colon-separated: comm[:docs[:code]])
        IFS=':' read -r comm_lang docs_lang code_lang <<< "$lang_arg"
        comm_lang="${comm_lang:-English}"
        docs_lang="${docs_lang:-$comm_lang}"
        code_lang="${code_lang:-English}"
    else
        echo ""
        info "Language configuration"
        echo "  Common choices: English, Italian, Spanish, French, German, Portuguese"
        read -rp "  Communication language (Claude responses) [English]: " comm_lang
        comm_lang="${comm_lang:-English}"
        read -rp "  Documentation language [${comm_lang}]: " docs_lang
        docs_lang="${docs_lang:-$comm_lang}"
        read -rp "  Code comments language [English]: " code_lang
        code_lang="${code_lang:-English}"
    fi

    # Copy global config
    if [[ -d "$GLOBAL_DIR/.claude" ]] && ! $force; then
        warn "Config already initialized, skipping (use --force to overwrite)"

        # Run pending migrations on existing install (if no .cco/meta yet)
        if [[ ! -f "$(_cco_global_meta)" ]]; then
            _run_migrations "global" "$GLOBAL_DIR/.claude" 0 ""
        fi
    else
        info "Copying default global config..."
        rm -rf "$GLOBAL_DIR"
        mkdir -p "$USER_CONFIG_DIR"
        mkdir -p "$GLOBAL_DIR"
        cp -r "$DEFAULTS_DIR/global/.claude" "$GLOBAL_DIR/.claude"

        # Replace language placeholders
        local lang_file="$GLOBAL_DIR/.claude/rules/language.md"
        sed -i '' "s/{{COMM_LANG}}/$comm_lang/g" "$lang_file" 2>/dev/null || \
            sed -i "s/{{COMM_LANG}}/$comm_lang/g" "$lang_file"
        sed -i '' "s/{{DOCS_LANG}}/$docs_lang/g" "$lang_file" 2>/dev/null || \
            sed -i "s/{{DOCS_LANG}}/$docs_lang/g" "$lang_file"
        sed -i '' "s/{{CODE_LANG}}/$code_lang/g" "$lang_file" 2>/dev/null || \
            sed -i "s/{{CODE_LANG}}/$code_lang/g" "$lang_file"

        ok "Global config initialized (languages: $comm_lang / $docs_lang / $code_lang)"

        # Generate .cco/meta with hashes of all installed files and latest schema
        local latest_schema
        latest_schema=$(_latest_schema_version "global")
        local now
        now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

        # Build manifest entries for all managed files
        mkdir -p "$GLOBAL_DIR/.claude/.cco"
        local meta_file="$GLOBAL_DIR/.claude/.cco/meta"
        (
            cd "$GLOBAL_DIR/.claude" || exit 1
            find . -type f ! -name 'meta' ! -path './.cco/*' | sed 's|^\./||' | sort | while IFS= read -r rel; do
                # Skip user-owned files
                local skip=false
                for uf in "${GLOBAL_USER_FILES[@]}"; do
                    [[ "$rel" == "$uf" ]] && skip=true && break
                done
                $skip && continue
                printf '%s\t%s\n' "$rel" "$(_file_hash "$GLOBAL_DIR/.claude/$rel")"
            done
        ) | _generate_cco_meta "$meta_file" "$latest_schema" "$now" \
            "$comm_lang" "$docs_lang" "$code_lang" "0"

        # Save base versions for future 3-way merge
        _save_all_base_versions "$GLOBAL_DIR/.claude/.cco/base" "$DEFAULTS_DIR/global/.claude" "global"

        # Run all migrations (marks schema as current — fresh install, nothing to migrate)
        _run_migrations "global" "$GLOBAL_DIR/.claude" 0 "$meta_file"
    fi

    # Copy global setup scripts if not present
    if [[ ! -f "$GLOBAL_DIR/setup-build.sh" && -f "$DEFAULTS_DIR/global/setup-build.sh" ]]; then
        cp "$DEFAULTS_DIR/global/setup-build.sh" "$GLOBAL_DIR/setup-build.sh"
        ok "Copied global/setup-build.sh template"
    fi
    if [[ ! -f "$GLOBAL_DIR/setup.sh" && -f "$DEFAULTS_DIR/global/setup.sh" ]]; then
        cp "$DEFAULTS_DIR/global/setup.sh" "$GLOBAL_DIR/setup.sh"
        ok "Copied global/setup.sh template"
    fi

    # Ensure projects, packs, and templates directories exist
    mkdir -p "$PROJECTS_DIR"
    mkdir -p "$PACKS_DIR"
    mkdir -p "$TEMPLATES_DIR"
    ok "Projects directory ready"
    ok "Packs directory ready"
    ok "Templates directory ready"

    # Create tutorial project (unless it already exists)
    local tutorial_dir="$PROJECTS_DIR/tutorial"
    if [[ ! -d "$tutorial_dir" ]]; then
        info "Creating tutorial project..."
        cp -r "$NATIVE_TEMPLATES_DIR/project/tutorial" "$tutorial_dir"

        # Substitute path placeholders in project.yml
        local tutorial_yml="$tutorial_dir/project.yml"
        sed -i '' "s|{{CCO_REPO_ROOT}}|$REPO_ROOT|g" "$tutorial_yml" 2>/dev/null || \
            sed -i "s|{{CCO_REPO_ROOT}}|$REPO_ROOT|g" "$tutorial_yml"
        sed -i '' "s|{{CCO_USER_CONFIG_DIR}}|$USER_CONFIG_DIR|g" "$tutorial_yml" 2>/dev/null || \
            sed -i "s|{{CCO_USER_CONFIG_DIR}}|$USER_CONFIG_DIR|g" "$tutorial_yml"

        # Bootstrap .cco/source, .cco/meta, .cco/base for tutorial project
        mkdir -p "$tutorial_dir/.cco"
        printf 'native:project/tutorial\n' > "$tutorial_dir/.cco/source"

        local tut_latest_schema
        tut_latest_schema=$(_latest_schema_version "project")
        local tut_now
        tut_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        local tut_meta="$tutorial_dir/.cco/meta"
        local tut_defaults="$NATIVE_TEMPLATES_DIR/project/base/.claude"

        (
            local entry rel policy
            for entry in "${PROJECT_FILE_POLICIES[@]}"; do
                rel="${entry%:*}"
                policy="${entry##*:}"
                [[ "$policy" != "tracked" ]] && continue
                rel="${rel#.claude/}"
                if [[ -f "$tutorial_dir/.claude/$rel" ]]; then
                    printf '%s\t%s\n' "$rel" "$(_file_hash "$tutorial_dir/.claude/$rel")"
                fi
            done
        ) | _generate_project_cco_meta "$tut_meta" "$tut_latest_schema" "$tut_now" "tutorial"

        _save_all_base_versions "$tutorial_dir/.cco/base" "$tut_defaults" "project"

        ok "Tutorial project ready — run 'cco start tutorial' to begin"
    fi

    # Generate manifest.yml if not present
    manifest_init "$USER_CONFIG_DIR"
    ok "manifest.yml ready"

    # PATH hint
    if ! command -v cco &>/dev/null; then
        echo ""
        info "Add cco to your PATH:"
        echo "  # bash:"
        echo "  echo 'export PATH=\"\$PATH:$REPO_ROOT/bin\"' >> ~/.bashrc && source ~/.bashrc"
        echo "  # zsh:"
        echo "  echo 'export PATH=\"\$PATH:$REPO_ROOT/bin\"' >> ~/.zshrc && source ~/.zshrc"
    fi

    # Try building Docker image (skipped when CCO_SKIP_BUILD=1, e.g. in test runner)
    if [[ "${CCO_SKIP_BUILD:-}" == "1" ]]; then
        : # Skip build silently (test mode)
    elif docker info >/dev/null 2>&1; then
        echo ""
        info "Building Docker image..."
        cmd_build
    else
        echo ""
        warn "Docker not running. Run 'cco build' when Docker is available."
    fi

    echo ""
    ok "Initialization complete!"
    echo "  Start the tutorial:    cco start tutorial"
    echo "  Create a project:      cco project create <name> --repo <path>"
}
