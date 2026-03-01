#!/usr/bin/env bash
# lib/cmd-init.sh — Initialize user configuration command
#
# Provides: cmd_init()
# Dependencies: colors.sh, utils.sh, update.sh, cmd-build.sh
# Globals: GLOBAL_DIR, DEFAULTS_DIR, PROJECTS_DIR, REPO_ROOT

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
        warn "global/ already exists, skipping (use --force to overwrite)"

        # Run pending migrations on existing install (if no .cco-meta yet)
        if [[ ! -f "$GLOBAL_DIR/.claude/.cco-meta" ]]; then
            _run_migrations "global" "$GLOBAL_DIR/.claude" 0 ""
        fi
    else
        info "Copying default global config to global/..."
        rm -rf "$GLOBAL_DIR"
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

        ok "Global config initialized at global/ (languages: $comm_lang / $docs_lang / $code_lang)"

        # Generate .cco-meta with hashes of all installed files and latest schema
        local latest_schema
        latest_schema=$(_latest_schema_version "global")
        local now
        now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

        # Build manifest entries for all managed files
        local meta_file="$GLOBAL_DIR/.claude/.cco-meta"
        (
            cd "$GLOBAL_DIR/.claude" || exit 1
            find . -type f ! -name '.cco-meta' | sed 's|^\./||' | sort | while IFS= read -r rel; do
                # Skip user-owned files
                local skip=false
                for uf in "${GLOBAL_USER_FILES[@]}"; do
                    [[ "$rel" == "$uf" ]] && skip=true && break
                done
                $skip && continue
                printf '%s\t%s\n' "$rel" "$(_file_hash "$GLOBAL_DIR/.claude/$rel")"
            done
        ) | _generate_cco_meta "$meta_file" "$latest_schema" "$now" \
            "$comm_lang" "$docs_lang" "$code_lang"

        # Run all migrations (marks schema as current — fresh install, nothing to migrate)
        _run_migrations "global" "$GLOBAL_DIR/.claude" 0 "$meta_file"
    fi

    # Copy global setup script if not present
    if [[ ! -f "$GLOBAL_DIR/setup.sh" && -f "$DEFAULTS_DIR/global/setup.sh" ]]; then
        cp "$DEFAULTS_DIR/global/setup.sh" "$GLOBAL_DIR/setup.sh"
        ok "Copied global/setup.sh template"
    fi

    # Ensure projects and packs directories exist
    mkdir -p "$PROJECTS_DIR"
    mkdir -p "$GLOBAL_DIR/packs"
    ok "Projects directory ready at projects/"
    ok "Packs directory ready at global/packs/ (define reusable knowledge groups here)"

    # PATH hint
    if ! command -v cco &>/dev/null; then
        echo ""
        info "Add cco to your PATH:"
        echo "  # bash:"
        echo "  echo 'export PATH=\"\$PATH:$REPO_ROOT/bin\"' >> ~/.bashrc && source ~/.bashrc"
        echo "  # zsh:"
        echo "  echo 'export PATH=\"\$PATH:$REPO_ROOT/bin\"' >> ~/.zshrc && source ~/.zshrc"
    fi

    # Try building Docker image
    echo ""
    if docker info >/dev/null 2>&1; then
        info "Building Docker image..."
        cmd_build
    else
        warn "Docker not running. Run 'cco build' when Docker is available."
    fi

    echo ""
    ok "Initialization complete. Create your first project with:"
    echo "  cco project create <name> --repo <path>"
}
