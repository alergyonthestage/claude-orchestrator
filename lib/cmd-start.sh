#!/usr/bin/env bash
# lib/cmd-start.sh — Start project session command
#
# Provides: cmd_start()
# Dependencies: colors.sh, utils.sh, yaml.sh, secrets.sh, workspace.sh, packs.sh
# Globals: PROJECTS_DIR, GLOBAL_DIR, IMAGE_NAME

cmd_start() {
    check_global

    local project=""
    local teammate_mode=""
    local use_api_key=false
    local dry_run=false
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

    local project_dir="$PROJECTS_DIR/$project"
    local project_yml="$project_dir/project.yml"

    [[ ! -d "$project_dir" ]] && die "Project '$project' not found. Run 'cco project list' to see available projects."
    [[ ! -f "$project_yml" ]] && die "No project.yml found in projects/$project/"

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
    local _global_meta="$GLOBAL_DIR/.claude/.cco-meta"
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

    # Warn about managed skills that shadow user-level copies
    if [[ -d "$GLOBAL_DIR/.claude/skills/init-workspace" ]]; then
        warn "init-workspace skill found in user global (global/.claude/skills/init-workspace)."
        warn "This skill is now managed (enterprise-level) and the managed version takes precedence."
        warn "You can safely remove the user copy: rm -rf global/.claude/skills/init-workspace"
    fi

    # Ensure claude-state directory exists (migrates legacy memory/ if needed)
    migrate_memory_to_claude_state "$project_dir"

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

    # ── Generate .managed/ integrations ──────────────────────────────────
    if [[ "$browser_enabled" == "true" ]]; then
        mkdir -p "$project_dir/.managed"
        _generate_browser_mcp "$project_dir/.managed/browser.json" \
            "$browser_mode" "$browser_effective_port" "$browser_mcp_args"
        echo "$browser_effective_port" > "$project_dir/.managed/.browser-port"
    else
        # Clean up stale managed files from a previous session
        rm -f "$project_dir/.managed/browser.json" "$project_dir/.managed/.browser-port"
    fi

    if [[ "$github_enabled" == "true" ]]; then
        mkdir -p "$project_dir/.managed"
        _generate_github_mcp "$project_dir/.managed/github.json" "$github_token_env"
    else
        rm -f "$project_dir/.managed/github.json"
    fi

    # Detect pack resource name conflicts (warning only, before compose generation)
    if [[ -n "$pack_names" ]]; then
        _detect_pack_conflicts "$pack_names"
    fi

    # ── Generate docker-compose.yml ──────────────────────────────────
    local compose_file="$project_dir/docker-compose.yml"

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
      # Claude state: auto memory + session transcripts (enables /resume across rebuilds)
      - ./claude-state:/home/claude/.claude/projects/-workspace
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
        if [[ -d "$project_dir/.managed" ]] && [[ -n "$(ls -A "$project_dir/.managed" 2>/dev/null)" ]]; then
            echo "      # Managed integrations"
            echo "      - ./.managed:/workspace/.managed:ro"
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

        # Docker socket (opt-out via docker.mount_socket: false)
        if [[ "$mount_socket" != "false" ]]; then
            echo "      # Docker socket"
            echo "      - /var/run/docker.sock:/var/run/docker.sock"
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
    local packs_md="$project_dir/.claude/packs.md"
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
    _generate_workspace_yml "$project_dir" "$project_name" "$project_yml" "$pack_names"

    # One-shot cleanup of legacy copied pack files (pre-ADR-14)
    _clean_pack_manifest "$project_dir"

    if $dry_run; then
        if [[ "$browser_enabled" == "true" ]]; then
            info "Browser: ${browser_mode} mode (CDP proxy localhost:${browser_effective_port} → host:${browser_effective_port})"
        fi
        info "Generated docker-compose.yml:"
        echo "---"
        cat "$compose_file"
        if [[ "$browser_enabled" == "true" && -f "$project_dir/.managed/browser.json" ]]; then
            echo ""
            info "Generated .managed/browser.json:"
            echo "---"
            cat "$project_dir/.managed/browser.json"
        fi
        if [[ "$github_enabled" == "true" && -f "$project_dir/.managed/github.json" ]]; then
            echo ""
            info "Generated .managed/github.json:"
            echo "---"
            cat "$project_dir/.managed/github.json"
        fi
        [[ -f "$packs_md" ]] && { echo ""; info "Generated .claude/packs.md:"; echo "---"; cat "$packs_md"; }
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
    docker compose -f "$compose_file" run --rm --service-ports "${run_env[@]+"${run_env[@]}"}" claude

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
        if [[ -f "$proj_dir/.managed/.browser-port" ]]; then
            claimed+=("$(cat "$proj_dir/.managed/.browser-port")")
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
