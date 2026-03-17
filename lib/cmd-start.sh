#!/usr/bin/env bash
# lib/cmd-start.sh — Start project session command
#
# Provides: _setup_internal_tutorial(), cmd_start()
# Dependencies: colors.sh, utils.sh, yaml.sh, secrets.sh, workspace.sh, packs.sh
# Globals: PROJECTS_DIR, GLOBAL_DIR, IMAGE_NAME, REPO_ROOT, USER_CONFIG_DIR

# ── Internal Tutorial Setup ──────────────────────────────────────────
# Prepares the runtime directory for the internal tutorial project.
# Content (.claude/, project.yml) is refreshed from internal/tutorial/ every start.
# Session state (.cco/claude-state/, memory/) persists across starts.
_setup_internal_tutorial() {
    local source_dir="$REPO_ROOT/internal/tutorial"
    local runtime_dir="$USER_CONFIG_DIR/.cco/internal/tutorial"

    [[ ! -d "$source_dir" ]] && die "Internal tutorial not found at $source_dir"

    # Create runtime dir structure (first time only for state dirs)
    mkdir -p "$runtime_dir/.cco/claude-state"
    mkdir -p "$runtime_dir/memory"

    # Always refresh content from framework source (ensures tutorial is current)
    rm -rf "$runtime_dir/.claude"
    cp -r "$source_dir/.claude" "$runtime_dir/.claude"

    # Refresh project.yml with path substitution
    sed -e "s|{{CCO_REPO_ROOT}}|$REPO_ROOT|g" \
        -e "s|{{CCO_USER_CONFIG_DIR}}|$USER_CONFIG_DIR|g" \
        "$source_dir/project.yml" > "$runtime_dir/project.yml"

    # Copy setup.sh if present
    if [[ -f "$source_dir/setup.sh" ]]; then
        cp "$source_dir/setup.sh" "$runtime_dir/setup.sh"
    fi
}

cmd_start() {
    check_global

    local project=""
    local teammate_mode=""
    local use_api_key=false
    local dry_run=false
    local dry_run_dump=false
    local opt_chrome=""      # "on" | "off" | "" (unset = read from project.yml)
    local opt_github=""      # "on" | "off" | "" (unset = read from project.yml)
    local opt_docker=""      # "off" | "" (unset = read from project.yml)
    local extra_ports=()
    local extra_envs=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --teammate-mode) teammate_mode="$2"; shift 2 ;;
            --api-key) use_api_key=true; shift ;;
            --dry-run) dry_run=true; shift ;;
            --dump) dry_run_dump=true; shift ;;
            --chrome)     opt_chrome="on";  shift ;;
            --no-chrome)  opt_chrome="off"; shift ;;
            --github)     opt_github="on";  shift ;;
            --no-github)  opt_github="off"; shift ;;
            --no-docker)  opt_docker="off"; shift ;;
            --port) extra_ports+=("$2"); shift 2 ;;
            --env) extra_envs+=("$2"); shift 2 ;;
            --help)
                cat <<'EOF'
Usage: cco start <project> [OPTIONS]

Options:
  --teammate-mode <m>  Override display mode: tmux | auto
  --api-key            Use ANTHROPIC_API_KEY instead of OAuth
  --chrome             Enable browser automation for this session only
  --no-chrome          Disable browser automation for this session only
  --github             Enable GitHub MCP for this session only
  --no-github          Disable GitHub MCP for this session only
  --no-docker          Disable Docker socket mount for this session only
  --dry-run            Show the generated docker-compose without running
  --dump               With --dry-run: persist artifacts to .tmp/ for inspection
  --port <p>           Add extra port mapping (repeatable)
  --env <K=V>          Add extra environment variable (repeatable)

Session flags (--chrome, --no-chrome, --github, --no-github, --no-docker) override
project.yml for one session only. To change the default, edit project.yml instead.
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$project" ]]; then
                    project="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    [[ -z "$project" ]] && die "Usage: cco start <project>. Run 'cco project list' to see available projects."

    local project_dir
    local project_yml
    local is_internal=false

    if [[ "$project" == "tutorial" ]]; then
        # "tutorial" is a reserved name — always launches the built-in tutorial.
        # Block if user has a project named "tutorial" in user-config.
        if [[ -d "$PROJECTS_DIR/tutorial" ]]; then
            echo ""
            error "'tutorial' is a reserved name for the built-in tutorial."
            echo ""
            echo "  You have a project named 'tutorial' in your user-config."
            echo "  Please rename or remove it to use 'cco start tutorial':"
            echo ""
            echo "    Rename:  mv $PROJECTS_DIR/tutorial $PROJECTS_DIR/<new-name>"
            echo "    Remove:  rm -rf $PROJECTS_DIR/tutorial"
            echo ""
            echo "  After renaming, update any references to the old project name."
            die "Resolve the conflict and try again."
        fi
        is_internal=true
        _setup_internal_tutorial
        project_dir="$USER_CONFIG_DIR/.cco/internal/tutorial"
        project_yml="$project_dir/project.yml"
    else
        project_dir="$PROJECTS_DIR/$project"
        project_yml="$project_dir/project.yml"
        [[ ! -d "$project_dir" ]] && die "Project '$project' not found. Run 'cco project list' to see available projects."
        [[ ! -f "$project_yml" ]] && die "No project.yml found in projects/$project/"
    fi

    if ! $dry_run; then
        check_docker
        check_image
    fi

    # Parse project config
    local project_name
    project_name=$(yml_get "$project_yml" "name")
    [[ -z "$project_name" ]] && project_name="$project"

    # Validate project name (ADR-13: secure-by-default config parsing)
    if [[ ! "$project_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        die "Invalid project name '${project_name}': must match [a-zA-Z0-9][a-zA-Z0-9_-]* (no spaces or special characters)"
    fi
    if [[ ${#project_name} -gt 63 ]]; then
        die "Project name '${project_name}' is too long (${#project_name} chars, max 63)"
    fi

    # Check for existing running session
    if ! $dry_run && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^cc-${project_name}$"; then
        die "Project '${project_name}' already has a running session (container cc-${project_name}). Run 'cco stop ${project}' first."
    fi

    local auth_method
    auth_method=$(yml_get "$project_yml" "auth.method")
    [[ -z "$auth_method" ]] && auth_method="oauth"
    $use_api_key && auth_method="api_key"
    # Validate auth method
    if [[ "$auth_method" != "oauth" && "$auth_method" != "api_key" ]]; then
        warn "Invalid auth.method '${auth_method}' — defaulting to 'oauth'. Valid values: oauth, api_key"
        auth_method="oauth"
    fi

    local docker_image
    docker_image=$(yml_get "$project_yml" "docker.image")
    [[ -z "$docker_image" ]] && docker_image="$IMAGE_NAME"

    local mount_socket
    mount_socket=$(_parse_bool "$(yml_get "$project_yml" "docker.mount_socket")" "false")
    # --no-docker: disable Docker socket for this session only
    [[ "$opt_docker" == "off" ]] && mount_socket="false"

    local network
    network=$(yml_get "$project_yml" "docker.network")
    [[ -z "$network" ]] && network="cc-${project_name}"

    [[ -z "$teammate_mode" ]] && teammate_mode="tmux"

    # ── Browser config ───────────────────────────────────────────────────
    local browser_enabled browser_mode browser_cdp_port browser_effective_port browser_mcp_args
    browser_enabled=$(_parse_bool "$(yml_get "$project_yml" "browser.enabled")" "false")

    browser_mode=$(yml_get "$project_yml" "browser.mode")
    [[ -z "$browser_mode" ]] && browser_mode="host"

    # Session-level override: --chrome / --no-chrome take priority over project.yml
    [[ "$opt_chrome" == "on"  ]] && browser_enabled="true" && browser_mode="host"
    [[ "$opt_chrome" == "off" ]] && browser_enabled="false"

    browser_cdp_port=$(yml_get "$project_yml" "browser.cdp_port")
    [[ -z "$browser_cdp_port" ]] && browser_cdp_port="9222"
    # Validate: must be numeric and in valid port range
    if [[ ! "$browser_cdp_port" =~ ^[0-9]+$ ]] || [[ "$browser_cdp_port" -lt 1 ]] || [[ "$browser_cdp_port" -gt 65535 ]]; then
        die "Invalid browser.cdp_port '${browser_cdp_port}': must be a number between 1 and 65535"
    fi

    browser_mcp_args=$(yml_get_list "$project_yml" "browser.mcp_args")

    # Resolve effective port (auto-assign if preferred port is taken)
    browser_effective_port="$browser_cdp_port"
    if [[ "$browser_enabled" == "true" && "$browser_mode" == "host" ]]; then
        browser_effective_port=$(_resolve_browser_port "$browser_cdp_port" "$project_name")
    fi

    # ── GitHub config ─────────────────────────────────────────────────────
    local github_enabled github_token_env
    github_enabled=$(_parse_bool "$(yml_get "$project_yml" "github.enabled")" "false")

    github_token_env=$(yml_get "$project_yml" "github.token_env")
    [[ -z "$github_token_env" ]] && github_token_env="GITHUB_TOKEN"

    # Session-level override: --github / --no-github take priority over project.yml
    [[ "$opt_github" == "on"  ]] && github_enabled="true"
    [[ "$opt_github" == "off" ]] && github_enabled="false"

    # Parse packs early (needed both for compose and packs.md generation)
    local pack_names
    pack_names=$(yml_get_packs "$project_yml")

    # Warn if no repos defined (some projects like tutorial work without repos)
    local repos_check
    repos_check=$(yml_get_repos "$project_yml")
    [[ -z "$repos_check" ]] && warn "No repositories defined in project.yml. Work inside the container will not persist unless saved via extra_mounts."

    # Check for available updates
    local _global_meta; _global_meta=$(_cco_global_meta)
    if [[ -f "$_global_meta" ]]; then
        local _current_schema _latest_schema
        _current_schema=$(_read_cco_meta "$_global_meta")
        _latest_schema=$(_latest_schema_version "global")
        if [[ "$_current_schema" -lt "$_latest_schema" ]]; then
            info "Updates available. Run 'cco update' to apply."
        fi
    elif [[ -d "$GLOBAL_DIR/.claude" ]]; then
        info "Run 'cco update' to initialize the update system."
    fi

    # Check for unresolved merge conflicts in config files
    local _conflict_files=()
    local _check_dir _check_label
    for _check_dir in "$GLOBAL_DIR/.claude" "$project_dir/.claude"; do
        [[ ! -d "$_check_dir" ]] && continue
        if [[ "$_check_dir" == "$GLOBAL_DIR/.claude" ]]; then
            _check_label="global"
        else
            _check_label="project/$project"
        fi
        while IFS= read -r _cfile; do
            [[ -z "$_cfile" ]] && continue
            local _rel="${_cfile#$_check_dir/}"
            _conflict_files+=("$_check_label/.claude/$_rel")
        done < <(grep -rl '<<<<<<<' "$_check_dir" --include='*.md' --include='*.json' 2>/dev/null || true)
    done
    if [[ ${#_conflict_files[@]} -gt 0 ]]; then
        error "Unresolved merge conflicts in config files:"
        local _cf
        for _cf in "${_conflict_files[@]}"; do
            error "  - $_cf"
        done
        die "Resolve conflict markers before starting. Run 'cco update --sync' or edit the files manually."
    fi

    # Warn about managed skills that shadow user-level copies
    if [[ -d "$GLOBAL_DIR/.claude/skills/init-workspace" ]]; then
        warn "init-workspace skill found in user global (global/.claude/skills/init-workspace)."
        warn "This skill is now managed (enterprise-level) and the managed version takes precedence."
        warn "You can safely remove the user copy: rm -rf global/.claude/skills/init-workspace"
    fi

    # ── Dry-run: redirect generated files to a staging directory ─────────
    # Default dry-run: ephemeral temp dir, auto-cleaned on exit.
    # --dump: persist to .tmp/ for manual inspection.
    local output_dir="$project_dir"
    if $dry_run; then
        if $dry_run_dump; then
            output_dir="$project_dir/.tmp"
            rm -rf "$output_dir"
        else
            output_dir=$(mktemp -d)
            _cleanup_dry_run_dir() { rm -rf "$output_dir"; }
            trap _cleanup_dry_run_dir EXIT
        fi
        mkdir -p "$output_dir/.claude" "$output_dir/.cco/managed"
    fi

    # ── Persistent side effects: skip in dry-run ─────────────────────────
    if ! $dry_run; then
        # Auto-clean stale dry-run dump (starting implies approval)
        [[ -d "$project_dir/.tmp" ]] && rm -rf "$project_dir/.tmp"

        # Ensure claude-state directory exists (migrates legacy memory/ if needed)
        migrate_memory_to_claude_state "$project_dir"

        # Ensure memory directory exists (vault-tracked, separate from claude-state)
        mkdir -p "$project_dir/memory"

        # Ensure global state files exist (shared across all projects — must exist before Docker bind mount)
        mkdir -p "$GLOBAL_DIR/claude-state"

        # ~/.claude.json — preferences, MCP servers, session metadata (NOT auth tokens)
        # Re-sync from host when host has been updated (higher numStartups = more recent).
        local global_claude_json="$GLOBAL_DIR/claude-state/claude.json"
        if [[ -f "$HOME/.claude.json" ]]; then
            if [[ ! -f "$global_claude_json" ]]; then
                cp "$HOME/.claude.json" "$global_claude_json"
            else
                local host_startups global_startups
                host_startups=$(jq -r '.numStartups // 0' "$HOME/.claude.json" 2>/dev/null || echo 0)
                global_startups=$(jq -r '.numStartups // 0' "$global_claude_json" 2>/dev/null || echo 0)
                if [[ "$host_startups" -gt "$global_startups" ]]; then
                    cp "$HOME/.claude.json" "$global_claude_json"
                fi
            fi
        elif [[ ! -f "$global_claude_json" ]]; then
            echo '{}' > "$global_claude_json"
        fi
        # Container must never show onboarding — force hasCompletedOnboarding after any sync/creation.
        # Host may have false after logout+login; container needs true to skip the "theme: dark" screen.
        local current_onboarding
        current_onboarding=$(jq -r '.hasCompletedOnboarding // false' "$global_claude_json" 2>/dev/null || echo "false")
        if [[ "$current_onboarding" != "true" ]]; then
            jq '.hasCompletedOnboarding = true' "$global_claude_json" > "$global_claude_json.tmp" \
                && mv "$global_claude_json.tmp" "$global_claude_json"
        fi

        # ~/.claude/.credentials.json — OAuth tokens (access + refresh)
        # On macOS, Claude stores tokens in Keychain. On Linux (container), it reads from
        # ~/.claude/.credentials.json in plaintext. We seed this file from the macOS Keychain
        # so the container can authenticate without manual login.
        local global_creds="$GLOBAL_DIR/claude-state/.credentials.json"
        if [[ "$(uname)" == "Darwin" ]] && [[ "$auth_method" == "oauth" ]]; then
            local keychain_json
            keychain_json=$(security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w 2>/dev/null) || true
            if [[ -n "$keychain_json" ]]; then
                local keychain_expires file_expires
                keychain_expires=$(echo "$keychain_json" | jq -r '.claudeAiOauth.expiresAt // 0' 2>/dev/null || echo 0)
                file_expires=$(jq -r '.claudeAiOauth.expiresAt // 0' "$global_creds" 2>/dev/null || echo 0)
                if [[ "$keychain_expires" -gt "$file_expires" ]]; then
                    echo "$keychain_json" > "$global_creds"
                    chmod 600 "$global_creds"
                    info "Seeded credentials from macOS Keychain (keychain token is newer)"
                fi
            fi
        fi
        # Ensure the file exists (even if empty) so Docker bind mount doesn't create a directory
        if [[ ! -f "$global_creds" ]]; then
            echo '{}' > "$global_creds"
            chmod 600 "$global_creds"
        fi
    fi

    # ── Docker socket policy ──────────────────────────────────────────────
    if [[ "$mount_socket" == "true" ]]; then
        _generate_socket_policy "$project_yml" "$project_name" "$output_dir"
    else
        if ! $dry_run; then
            rm -f "$project_dir/.cco/managed/policy.json"
        fi
    fi

    # ── Generate .managed/ integrations ──────────────────────────────────
    if [[ "$browser_enabled" == "true" ]]; then
        mkdir -p "$output_dir/.cco/managed"
        _generate_browser_mcp "$output_dir/.cco/managed/browser.json" \
            "$browser_mode" "$browser_effective_port" "$browser_mcp_args"
        echo "$browser_effective_port" > "$output_dir/.cco/managed/.browser-port"
    else
        if ! $dry_run; then
            # Clean up stale managed files from a previous session
            rm -f "$project_dir/.cco/managed/browser.json" "$project_dir/.cco/managed/.browser-port"
        fi
    fi

    if [[ "$github_enabled" == "true" ]]; then
        mkdir -p "$output_dir/.cco/managed"
        _generate_github_mcp "$output_dir/.cco/managed/github.json" "$github_token_env"
    else
        if ! $dry_run; then
            rm -f "$project_dir/.cco/managed/github.json"
        fi
    fi

    # Detect pack resource name conflicts (warning only, before compose generation)
    if [[ -n "$pack_names" ]]; then
        _detect_pack_conflicts "$pack_names"
    fi

    # ── Generate docker-compose.yml ──────────────────────────────────
    mkdir -p "$output_dir/.cco"
    local compose_file
    compose_file=$(_cco_project_compose "$output_dir")

    {
        cat <<YAML
# AUTO-GENERATED by cco CLI from project.yml
# Manual edits will be overwritten on next \`cco start\`
# To customize, edit project.yml instead

services:
  claude:
    image: ${docker_image}
    container_name: cc-${project_name}
    stdin_open: true
    tty: true
    environment:
      - PROJECT_NAME=${project_name}
      - TEAMMATE_MODE=${teammate_mode}
      - CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
YAML

        # Extra env from project.yml
        while IFS= read -r env_line; do
            [[ -z "$env_line" ]] && continue
            local env_key="${env_line%%:*}"
            local env_val="${env_line#*: }"
            echo "      - ${env_key}=${env_val}"
        done <<< "$(yml_get_env "$project_yml")"

        # Extra env from CLI
        for env in "${extra_envs[@]+"${extra_envs[@]}"}"; do
            echo "      - ${env}"
        done

        # Docker socket proxy: advertise proxy socket to all processes in container
        if [[ "$mount_socket" == "true" ]]; then
            echo "      - DOCKER_HOST=unix:///var/run/docker-proxy.sock"
        fi

        # CDP proxy port for entrypoint socat (Chrome 145+ Host header fix)
        if [[ "$browser_enabled" == "true" && "$browser_mode" == "host" ]]; then
            echo "      - CDP_PORT=${browser_effective_port}"
        fi

        # API key auth
        if [[ "$auth_method" == "api_key" ]]; then
            echo "      - ANTHROPIC_API_KEY=\${ANTHROPIC_API_KEY}"
        fi

        echo "    volumes:"

        # ~/.claude.json — preferences, MCP servers, session metadata (persisted globally)
        echo "      - ${GLOBAL_DIR}/claude-state/claude.json:/home/claude/.claude.json"
        # ~/.claude/.credentials.json — OAuth tokens (seeded from macOS Keychain, auto-refreshed by Claude)
        echo "      - ${GLOBAL_DIR}/claude-state/.credentials.json:/home/claude/.claude/.credentials.json"

        # Global config (read-only)
        cat <<YAML
      # Global config
      - ${GLOBAL_DIR}/.claude/settings.json:/home/claude/.claude/settings.json:ro
      - ${GLOBAL_DIR}/.claude/CLAUDE.md:/home/claude/.claude/CLAUDE.md:ro
      - ${GLOBAL_DIR}/.claude/rules:/home/claude/.claude/rules:ro
      - ${GLOBAL_DIR}/.claude/agents:/home/claude/.claude/agents:ro
      - ${GLOBAL_DIR}/.claude/skills:/home/claude/.claude/skills:ro
      # Project config
      - ./.claude:/workspace/.claude
      - ./project.yml:/workspace/project.yml:ro
      # Claude state: session transcripts (enables /resume across rebuilds)
      - ./.cco/claude-state:/home/claude/.claude/projects/-workspace
      # Memory: auto memory files (vault-tracked, separate from transcripts)
      - ./memory:/home/claude/.claude/projects/-workspace/memory
YAML

        # Global MCP config (merged into ~/.claude.json by entrypoint)
        if [[ -f "$GLOBAL_DIR/.claude/mcp.json" ]]; then
            echo "      # Global MCP servers"
            echo "      - ${GLOBAL_DIR}/.claude/mcp.json:/home/claude/.claude/mcp-global.json:ro"
        fi

        # Project MCP config (Claude Code expands ${VAR} natively)
        if [[ -f "$project_dir/mcp.json" ]]; then
            echo "      # Project MCP servers"
            echo "      - ./mcp.json:/workspace/.mcp.json:ro"
        fi

        # Global runtime setup script (executed by entrypoint before project setup)
        if [[ -f "$GLOBAL_DIR/setup.sh" ]]; then
            echo "      # Global runtime setup"
            echo "      - ${GLOBAL_DIR}/setup.sh:/home/claude/global-setup.sh:ro"
        fi

        # Project setup script (runtime, executed by entrypoint)
        if [[ -f "$project_dir/setup.sh" ]]; then
            echo "      # Project setup script"
            echo "      - ./setup.sh:/workspace/setup.sh:ro"
        fi

        # Project MCP packages (runtime, installed by entrypoint)
        if [[ -f "$project_dir/mcp-packages.txt" ]]; then
            echo "      # Project MCP packages"
            echo "      - ./mcp-packages.txt:/workspace/mcp-packages.txt:ro"
        fi

        # Managed integrations directory (framework-generated, never edit manually)
        if [[ -d "$output_dir/.cco/managed" ]] && [[ -n "$(ls -A "$output_dir/.cco/managed" 2>/dev/null)" ]]; then
            echo "      # Managed integrations"
            echo "      - ./.cco/managed:/workspace/.managed:ro"
        fi

        # Repository mounts
        echo "      # Repositories"
        while IFS=: read -r repo_path repo_name; do
            [[ -z "$repo_path" ]] && continue
            repo_path=$(expand_path "$repo_path")
            if [[ ! -d "$repo_path" ]]; then
                warn "Repository path '$repo_path' does not exist — skipping"
                continue
            fi
            echo "      - ${repo_path}:/workspace/${repo_name}"
        done <<< "$(yml_get_repos "$project_yml")"

        # Extra mounts
        local extra_mounts
        extra_mounts=$(yml_get_extra_mounts "$project_yml")
        if [[ -n "$extra_mounts" ]]; then
            echo "      # Extra mounts"
            while IFS= read -r mount_line; do
                [[ -z "$mount_line" ]] && continue
                local source="${mount_line%%:*}"
                local rest="${mount_line#*:}"
                source=$(expand_path "$source")
                echo "      - ${source}:${rest}"
            done <<< "$extra_mounts"
        fi

        # Pack resources: read-only mounts from central pack registry (ADR-14)
        _generate_pack_mounts "$pack_names"

        # Git identity (commit author — read-only, no SSH keys)
        echo "      # Git identity"
        echo "      - \${HOME}/.gitconfig:/home/claude/.gitconfig:ro"

        # Docker socket (opt-in via docker.mount_socket: true)
        if [[ "$mount_socket" != "false" ]]; then
            echo "      # Docker socket"
            echo "      - /var/run/docker.sock:/var/run/docker.sock"
            # Policy file for socket proxy (if generated)
            if [[ -f "$output_dir/.cco/managed/policy.json" ]]; then
                echo "      - ./.cco/managed/policy.json:/etc/cco/policy.json:ro"
            fi
        fi

        # Ports
        local all_ports=()
        while IFS= read -r port; do
            [[ -z "$port" ]] && continue
            all_ports+=("$port")
        done <<< "$(yml_get_ports "$project_yml")"
        for port in "${extra_ports[@]+"${extra_ports[@]}"}"; do
            all_ports+=("$port")
        done

        if [[ ${#all_ports[@]} -gt 0 ]]; then
            echo "    ports:"
            for port in "${all_ports[@]}"; do
                echo "      - \"${port}\""
            done
        fi

        # extra_hosts (browser host mode — resolves host.docker.internal on Linux)
        if [[ "$browser_enabled" == "true" && "$browser_mode" == "host" ]]; then
            echo "    extra_hosts:"
            echo '      - "host.docker.internal:host-gateway"'
        fi

        # Network (must be the last service-level section)
        cat <<YAML
    networks:
      - ${network}
    working_dir: /workspace

networks:
  ${network}:
    name: ${network}
    driver: bridge
YAML
    } > "$compose_file"

    # Generate .claude/packs.md — instructional list of knowledge pack files
    local packs_md="$output_dir/.claude/packs.md"
    if [[ -n "$pack_names" ]]; then
        local packs_md_lines=0
        {
            echo "<!-- Auto-generated by cco start — do not edit manually -->"
            echo "The following knowledge files provide project-specific conventions and context."
            echo "Read the relevant files BEFORE starting any implementation, review, or design task."
            echo "Do not ask the user for context that is covered by these files."
            echo ""
            while IFS= read -r pack_name; do
                [[ -z "$pack_name" ]] && continue
                local pack_yml="$PACKS_DIR/${pack_name}/pack.yml"
                [[ ! -f "$pack_yml" ]] && continue
                if ! grep -qE '^(name|knowledge|skills|agents|rules):' "$pack_yml"; then
                    warn "Pack '$pack_name': pack.yml has no valid top-level keys — check for extra indentation."
                    continue
                fi
                local pack_files
                pack_files=$(yml_get_pack_knowledge_files "$pack_yml")
                [[ -z "$pack_files" ]] && continue
                while IFS=$'\t' read -r fname fdesc; do
                    [[ -z "$fname" ]] && continue
                    [[ -n "$fdesc" ]] && echo "- /workspace/.claude/packs/${pack_name}/${fname} — ${fdesc}" \
                                      || echo "- /workspace/.claude/packs/${pack_name}/${fname}"
                    (( packs_md_lines++ )) || true
                done <<< "$pack_files"
            done <<< "$pack_names"
        } > "$packs_md"
        ok "Generated .claude/packs.md (${packs_md_lines} file(s))"
    elif [[ -f "$packs_md" ]]; then
        rm -f "$packs_md"
    fi

    # Generate .claude/workspace.yml — structured project context for /init
    _generate_workspace_yml "$output_dir" "$project_name" "$project_yml" "$pack_names"

    # One-shot cleanup of legacy copied pack files (pre-ADR-14) — skip in dry-run
    if ! $dry_run; then
        _clean_pack_manifest "$project_dir"
    fi

    if $dry_run; then
        # ── Structured dry-run summary ───────────────────────────────────
        echo ""
        info "${BOLD}Dry-run summary for '${project_name}'${NC}"
        echo ""
        info "  Image:          ${docker_image}"
        info "  Auth:           ${auth_method}"
        info "  Teammate mode:  ${teammate_mode}"
        info "  Network:        ${network}"
        info "  Docker socket:  ${mount_socket}"
        if [[ "$mount_socket" == "true" ]]; then
            local _pol="project_only"
            _pol=$(yml_get_deep "$project_yml" "docker.containers.policy") || true
            [[ -z "$_pol" ]] && _pol="project_only"
            info "  Socket policy:  ${_pol}"
        fi
        if [[ "$browser_enabled" == "true" ]]; then
            info "  Browser:        ${browser_mode} mode (CDP port ${browser_effective_port})"
        else
            info "  Browser:        disabled"
        fi
        if [[ "$github_enabled" == "true" ]]; then
            info "  GitHub MCP:     enabled (token: \$${github_token_env})"
        else
            info "  GitHub MCP:     disabled"
        fi

        # Ports
        local all_ports=()
        while IFS= read -r _p; do
            [[ -z "$_p" ]] && continue
            all_ports+=("$_p")
        done <<< "$(yml_get_ports "$project_yml")"
        for _p in "${extra_ports[@]+"${extra_ports[@]}"}"; do
            all_ports+=("$_p")
        done
        if [[ ${#all_ports[@]} -gt 0 ]]; then
            info "  Ports:          ${all_ports[*]}"
        else
            info "  Ports:          (none)"
        fi

        # Repos
        local _repos
        _repos=$(yml_get_repos "$project_yml")
        if [[ -n "$_repos" ]]; then
            info "  Repos:"
            while IFS=: read -r _rp _rn; do
                [[ -z "$_rp" ]] && continue
                info "    - ${_rn} (${_rp})"
            done <<< "$_repos"
        fi

        # Packs
        if [[ -n "$pack_names" ]]; then
            info "  Packs:"
            while IFS= read -r _pk; do
                [[ -z "$_pk" ]] && continue
                info "    - ${_pk}"
            done <<< "$pack_names"
        fi

        echo ""
        if $dry_run_dump; then
            info "Generated files available at: ${output_dir}/"
            echo ""
            info "  .cco/docker-compose.yml"
            [[ -f "$output_dir/.cco/managed/policy.json" ]]  && info "  .cco/managed/policy.json"
            [[ -f "$output_dir/.cco/managed/browser.json" ]]  && info "  .cco/managed/browser.json"
            [[ -f "$output_dir/.cco/managed/github.json" ]]   && info "  .cco/managed/github.json"
            [[ -f "$packs_md" ]]                          && info "  .claude/packs.md"
            [[ -f "$output_dir/.claude/workspace.yml" ]]  && info "  .claude/workspace.yml"
            echo ""
            info "Inspect with: cat ${output_dir}/.cco/docker-compose.yml"
        else
            ok "Dry-run complete. Use --dump to persist generated files for inspection."
        fi
        return 0
    fi

    # Ensure ~/.claude.json exists on host (needed for MCP, session metadata)
    if [[ ! -f "$HOME/.claude.json" ]]; then
        echo '{}' > "$HOME/.claude.json"
    fi

    # Resolve auth and secrets for the session
    # OAuth: credentials are in ~/.claude/.credentials.json (seeded from macOS Keychain,
    # auto-refreshed by Claude). No env var needed — Claude reads the file directly.
    local run_env=()
    if [[ "$auth_method" == "api_key" ]]; then
        [[ -z "${ANTHROPIC_API_KEY:-}" ]] && die "ANTHROPIC_API_KEY is not set. Export it before running cco start --api-key."
        run_env+=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
    fi

    # Load global secrets as runtime env vars (for MCP servers that read env directly)
    load_global_secrets run_env
    # Load project-specific secrets (override global values — Docker uses last -e for duplicates)
    load_secrets_file run_env "$project_dir/secrets.env"

    info "Starting session for project '${project_name}'..."
    docker compose -f "$compose_file" --project-directory "$project_dir" run --rm --service-ports "${run_env[@]+"${run_env[@]}"}" claude

    ok "Session ended. Changes are in your repos."
}

# ── Browser support helpers ──────────────────────────────────────────

# Returns CDP ports claimed by running cco sessions (one per line).
# Iterates project directories (not container names) to avoid mismatch
# when project.yml `name:` differs from the directory name.
_collect_claimed_browser_ports() {
    local current_project="$1"
    local claimed=()
    for proj_dir in "$PROJECTS_DIR"/*/; do
        [[ ! -d "$proj_dir" ]] && continue
        local proj; proj=$(basename "$proj_dir")
        [[ "$proj" == "$current_project" ]] && continue
        local yml="$proj_dir/project.yml"
        [[ ! -f "$yml" ]] && continue
        local enabled; enabled=$(yml_get "$yml" "browser.enabled")
        [[ "$enabled" != "true" ]] && continue
        # Verify container is actually running (use yml name, fallback to dir name)
        local yml_name; yml_name=$(yml_get "$yml" "name")
        [[ -z "$yml_name" ]] && yml_name="$proj"
        local container="cc-${yml_name}"
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$" || continue
        # Read effective port (runtime file > project.yml > default)
        if [[ -f "$proj_dir/.cco/managed/.browser-port" ]]; then
            claimed+=("$(cat "$proj_dir/.cco/managed/.browser-port")")
        else
            local port; port=$(yml_get "$yml" "browser.cdp_port")
            [[ -z "$port" ]] && port="9222"
            claimed+=("$port")
        fi
    done
    # Guard: bash 3.2 + set -u treats empty arrays as unbound
    [[ ${#claimed[@]} -gt 0 ]] && printf '%s\n' "${claimed[@]}"
}

# Finds the lowest free port starting from preferred, skipping claimed ports
_resolve_browser_port() {
    local preferred="$1"
    local current_project="$2"
    local claimed=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && claimed+=("$line")
    done < <(_collect_claimed_browser_ports "$current_project")

    local port="$preferred"
    while true; do
        local taken=false
        # Guard: bash 3.2 + set -u treats empty arrays as unbound
        for c in ${claimed[@]+"${claimed[@]}"}; do
            [[ "$c" == "$port" ]] && taken=true && break
        done
        if [[ "$taken" == "false" ]]; then
            if [[ "$port" != "$preferred" ]]; then
                warn "Browser: CDP port ${preferred} is claimed by another session."
                warn "         Using port ${port} instead."
                info "         Run: cco chrome start --project ${current_project}"
            fi
            echo "$port"
            return
        fi
        ((port++))
    done
}

# Generates .managed/browser.json with chrome-devtools-mcp configuration
_generate_browser_mcp() {
    local out_file="$1" mode="$2" cdp_port="$3" mcp_args="${4:-}"

    local browser_url
    if [[ "$mode" == "host" ]]; then
        browser_url="http://localhost:${cdp_port}"
    else
        # container mode: deferred
        browser_url="http://browser:${cdp_port}"
    fi

    # Build extra args JSON lines from mcp_args (newline-separated list)
    local extra_args=""
    if [[ -n "$mcp_args" ]]; then
        while IFS= read -r arg; do
            if [[ -n "$arg" ]]; then
                # Escape backslashes first, then double quotes for valid JSON
                arg="${arg//\\/\\\\}"
                arg="${arg//\"/\\\"}"
                extra_args+=",
        \"${arg}\""
            fi
        done <<< "$mcp_args"
    fi

    printf '{
  "mcpServers": {
    "chrome-devtools": {
      "command": "chrome-devtools-mcp",
      "args": [
        "--browserUrl=%s",
        "--no-usage-statistics",
        "--no-performance-crux"%s
      ]
    }
  }
}\n' "$browser_url" "$extra_args" > "$out_file"
}

# Generates .managed/github.json with github MCP server configuration
# $1 = output file path
# $2 = token_env: name of the env var holding the GitHub token (e.g. GITHUB_TOKEN)
_generate_github_mcp() {
    local out_file="$1" token_env="$2"
    [[ -z "$token_env" ]] && token_env="GITHUB_TOKEN"

    printf '{
  "mcpServers": {
    "github": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_TOKEN": "${%s}"
      }
    }
  }
}\n' "$token_env" > "$out_file"
}

# Generates .managed/policy.json for the Docker socket proxy.
# Reads docker.containers, docker.mounts, docker.security from project.yml.
# $1 = project.yml path, $2 = project name, $3 = project dir
_generate_socket_policy() {
    local project_yml="$1" project_name="$2" project_dir="$3"

    mkdir -p "$project_dir/.cco/managed"
    local out_file="$project_dir/.cco/managed/policy.json"

    # Container policy
    local ct_policy ct_create ct_prefix
    ct_policy=$(yml_get_deep "$project_yml" "docker.containers.policy")
    ct_policy=$(yml_validate_enum "$ct_policy" "project_only" "project_only|allowlist|denylist|unrestricted")
    ct_create=$(_parse_bool "$(yml_get_deep "$project_yml" "docker.containers.create")" "true")
    ct_prefix=$(yml_get_deep "$project_yml" "docker.containers.name_prefix")
    [[ -z "$ct_prefix" ]] && ct_prefix="cc-${project_name}-"

    # Container allow/deny patterns
    local ct_allow_json="[]" ct_deny_json="[]"
    local ct_allow ct_deny
    ct_allow=$(yml_get_deep_list "$project_yml" "docker.containers.allow")
    ct_deny=$(yml_get_deep_list "$project_yml" "docker.containers.deny")
    if [[ -n "$ct_allow" ]]; then
        ct_allow_json=$(echo "$ct_allow" | jq -R . | jq -s .)
    fi
    if [[ -n "$ct_deny" ]]; then
        ct_deny_json=$(echo "$ct_deny" | jq -R . | jq -s .)
    fi

    # Required labels
    local ct_labels_json="{}"
    local ct_labels
    ct_labels=$(yml_get_deep_map "$project_yml" "docker.containers.required_labels")
    if [[ -n "$ct_labels" ]]; then
        ct_labels_json=$(echo "$ct_labels" | awk '{
            # Split only on the first colon to preserve colons in values
            idx = index($0, ":")
            if (idx > 0) {
                key = substr($0, 1, idx-1)
                val = substr($0, idx+1)
                printf "\"%s\":\"%s\"\n", key, val
            }
        }' | jq -s 'from_entries')
    else
        ct_labels_json="{\"cco.project\":\"${project_name}\"}"
    fi

    # Mount policy
    local mt_policy mt_force_ro
    mt_policy=$(yml_get_deep "$project_yml" "docker.mounts.policy")
    mt_policy=$(yml_validate_enum "$mt_policy" "project_only" "none|project_only|allowlist|any")
    mt_force_ro=$(_parse_bool "$(yml_get_deep "$project_yml" "docker.mounts.force_readonly")" "false")

    # Mount allowed paths: for project_only, collect repo paths
    # All paths are expanded (~ → /home/user) to match what Docker sends at runtime.
    local mt_allowed_json="[]"
    if [[ "$mt_policy" == "project_only" ]]; then
        local repo_paths
        repo_paths=$(yml_get_repos "$project_yml" | cut -d: -f1)
        if [[ -n "$repo_paths" ]]; then
            mt_allowed_json=$(while IFS= read -r _p; do
                [[ -z "$_p" ]] && continue
                expand_path "$_p"
            done <<< "$repo_paths" | jq -R . | jq -s .)
        fi
    else
        local mt_allow
        mt_allow=$(yml_get_deep_list "$project_yml" "docker.mounts.allow")
        if [[ -n "$mt_allow" ]]; then
            mt_allowed_json=$(while IFS= read -r _p; do
                [[ -z "$_p" ]] && continue
                expand_path "$_p"
            done <<< "$mt_allow" | jq -R . | jq -s .)
        fi
    fi

    # Path map: container prefix → host path.  In Docker-from-Docker, bind
    # mount paths reference the HOST filesystem, but shell expansion inside the
    # container produces container-local paths (e.g. ~ → /home/claude).
    # The proxy uses this map to translate container paths before validation
    # AND before forwarding to the Docker daemon.
    # Format: tab-separated lines "container_path\thost_path", fed to jq.
    local mt_pathmap_json="{}"
    local _pathmap_lines=""
    # Map each repo: /workspace/<name> → expanded host path
    local _repo_lines
    _repo_lines=$(yml_get_repos "$project_yml")
    if [[ -n "$_repo_lines" ]]; then
        while IFS=: read -r _rp _rn; do
            [[ -z "$_rp" ]] && continue
            local _host_p
            _host_p=$(expand_path "$_rp")
            _pathmap_lines="${_pathmap_lines}/workspace/${_rn}"$'\t'"${_host_p}"$'\n'
        done <<< "$_repo_lines"
    fi
    # Map extra_mounts: container target → expanded host source
    local _extra_mounts
    _extra_mounts=$(yml_get_extra_mounts "$project_yml" 2>/dev/null || true)
    if [[ -n "$_extra_mounts" ]]; then
        while IFS= read -r _em; do
            [[ -z "$_em" ]] && continue
            local _src="${_em%%:*}"
            local _rest="${_em#*:}"
            local _tgt="${_rest%%:*}"
            _src=$(expand_path "$_src")
            _pathmap_lines="${_pathmap_lines}${_tgt}"$'\t'"${_src}"$'\n'
        done <<< "$_extra_mounts"
    fi
    # Map container home → host home (for ~/... expansion inside container)
    _pathmap_lines="${_pathmap_lines}/home/claude"$'\t'"${HOME}"$'\n'
    if [[ -n "$_pathmap_lines" ]]; then
        mt_pathmap_json=$(printf '%s' "$_pathmap_lines" | grep -v '^$' | \
            jq -R 'split("\t") | {key: .[0], value: .[1]}' | jq -s 'from_entries')
    fi

    # Mount denied paths (explicit) — expanded like allowed paths
    local mt_denied_json="[]"
    local mt_deny
    mt_deny=$(yml_get_deep_list "$project_yml" "docker.mounts.deny")
    if [[ -n "$mt_deny" ]]; then
        mt_denied_json=$(while IFS= read -r _p; do
            [[ -z "$_p" ]] && continue
            expand_path "$_p"
        done <<< "$mt_deny" | jq -R . | jq -s .)
    fi

    # Security policy
    local sec_no_priv sec_no_sens sec_force_nonroot
    sec_no_priv=$(_parse_bool "$(yml_get_deep "$project_yml" "docker.security.no_privileged")" "true")
    sec_no_sens=$(_parse_bool "$(yml_get_deep "$project_yml" "docker.security.no_sensitive_mounts")" "true")
    sec_force_nonroot=$(_parse_bool "$(yml_get_deep "$project_yml" "docker.security.force_non_root")" "false")

    # Drop capabilities
    local sec_dropcaps_json="[\"SYS_ADMIN\",\"NET_ADMIN\"]"
    local sec_dropcaps
    sec_dropcaps=$(yml_get_deep_list "$project_yml" "docker.security.drop_capabilities")
    if [[ -n "$sec_dropcaps" ]]; then
        sec_dropcaps_json=$(echo "$sec_dropcaps" | jq -R . | jq -s .)
    fi

    # Resources (docker.security.resources.*)
    local sec_memory sec_cpus sec_max_ct
    sec_memory=$(yml_get_deep4 "$project_yml" "docker.security.resources.memory")
    sec_cpus=$(yml_get_deep4 "$project_yml" "docker.security.resources.cpus")
    sec_max_ct=$(yml_get_deep4 "$project_yml" "docker.security.resources.max_containers")

    # Convert memory string to bytes (e.g., "4g" → 4294967296)
    local memory_bytes=4294967296  # default 4g
    if [[ -n "$sec_memory" ]]; then
        case "$sec_memory" in
            *[gG]) memory_bytes=$(( ${sec_memory%[gG]} * 1024 * 1024 * 1024 )) ;;
            *[mM]) memory_bytes=$(( ${sec_memory%[mM]} * 1024 * 1024 )) ;;
            *)     memory_bytes="$sec_memory" ;;
        esac
    fi

    # Convert CPUs to nanoCPUs (e.g., "4" → 4000000000, "0.5" → 500000000)
    local nano_cpus=4000000000  # default 4
    if [[ -n "$sec_cpus" ]]; then
        # Use awk for fractional support (no bc dependency)
        nano_cpus=$(awk "BEGIN { printf \"%.0f\", $sec_cpus * 1000000000 }")
    fi

    [[ -z "$sec_max_ct" ]] && sec_max_ct=10

    # Network allowed prefixes
    local net_prefixes_json="[\"cc-${project_name}\"]"
    local custom_network
    custom_network=$(yml_get "$project_yml" "docker.network")
    if [[ -n "$custom_network" ]]; then
        net_prefixes_json="[\"${custom_network}\"]"
    fi

    # Write policy.json
    cat > "$out_file" <<POLICY
{
  "project_name": "${project_name}",
  "containers": {
    "policy": "${ct_policy}",
    "allow_patterns": ${ct_allow_json},
    "deny_patterns": ${ct_deny_json},
    "create_allowed": ${ct_create},
    "name_prefix": "${ct_prefix}",
    "required_labels": ${ct_labels_json}
  },
  "mounts": {
    "policy": "${mt_policy}",
    "allowed_paths": ${mt_allowed_json},
    "denied_paths": ${mt_denied_json},
    "implicit_deny": [
      "/var/run/docker.sock",
      "/etc/shadow",
      "/etc/sudoers"
    ],
    "force_readonly": ${mt_force_ro},
    "path_map": ${mt_pathmap_json}
  },
  "security": {
    "no_privileged": ${sec_no_priv},
    "no_sensitive_mounts": ${sec_no_sens},
    "force_non_root": ${sec_force_nonroot},
    "drop_capabilities": ${sec_dropcaps_json},
    "max_memory_bytes": ${memory_bytes},
    "max_nano_cpus": ${nano_cpus},
    "max_containers": ${sec_max_ct}
  },
  "networks": {
    "allowed_prefixes": ${net_prefixes_json}
  }
}
POLICY

    echo "[start] Generated Docker socket policy: containers=${ct_policy}, mounts=${mt_policy}" >&2
}
