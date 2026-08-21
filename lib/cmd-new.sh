#!/usr/bin/env bash
# lib/cmd-new.sh — Start temporary session command
#
# Provides: cmd_new()
# Dependencies: colors.sh, utils.sh, auth.sh, secrets.sh
# Globals: IMAGE_NAME

cmd_new() {
    check_global

    local repos=()
    local session_name=""
    local teammate_mode="tmux"
    local extra_ports=()
    local user_mounts=()        # --mount specs (ADR-0027 D2), :ro by default

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repos+=("$2"); shift 2 ;;
            --name) session_name="$2"; shift 2 ;;
            --teammate-mode) teammate_mode="$2"; shift 2 ;;
            --port) extra_ports+=("$2"); shift 2 ;;
            --mount) [[ $# -lt 2 ]] && die "--mount requires <src>[:<target>][:ro|:rw]."; user_mounts+=("$2"); shift 2 ;;
            # ADR-0059 A2 D23 — same spelling as `cco start`: the list is rendered,
            # the question is skipped. See lib/cmd-start.sh for the full rationale.
            --yes|-y) CCO_ASSUME_YES=1; shift ;;
            --help|-h)
                cat <<'EOF'
Usage: cco new [OPTIONS]

Options:
  --repo <path>        Repository to mount (repeatable, at least one required)
  --name <name>        Temporary session name (default: "tmp-<timestamp>")
  --teammate-mode <m>  Override display mode: tmux | auto
  --port <p>           Port mapping (repeatable)
  --mount <s>[:<t>][:ro|:rw]  Mount reference material (repeatable; read-only by
                       default, :rw to make writable; target defaults to
                       /workspace/<basename>)
  --yes, -y            Answer the start-time pause: show the messages, do not ask
                       (same as CCO_ASSUME_YES=1; CCO_NONINTERACTIVE=1 instead says
                       there is no terminal at all)
EOF
                return 0
                ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    # M6 (security): a user-supplied name flows into an EXIT-trap `rm -rf`, the temp
    # dir path, and the generated docker-compose (container/network names, env) —
    # validate it early (like cco start validates project names) to block shell /
    # path-traversal / YAML injection via `--name`. The auto default (tmp-<ts>) below
    # is always valid.
    [[ -n "$session_name" && ! "$session_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] \
        && die "Invalid session name '$session_name' — use letters, numbers, '-' and '_' only (must start alphanumeric)."

    [[ ${#repos[@]} -eq 0 ]] && die "At least one --repo is required."

    # ADR-0059 D9 — `cco new` gates too. It has its own launch path and takes the
    # terminal identically, and it is the verb that mounts ad-hoc repos, so it is
    # MORE exposed to path-resolution warnings, not less. Armed after argument
    # parsing so `--help` and a rejected flag leave no buffer behind.
    _cco_warn_capture_begin

    # Resolve --mount specs eagerly (ADR-0027 D2) so a bad source fails before
    # any compose is generated. Each becomes abs_src<TAB>target<TAB>ro.
    local user_mount_lines=()
    local _mspec
    for _mspec in ${user_mounts[@]+"${user_mounts[@]}"}; do
        user_mount_lines+=("$(_parse_user_mount_spec "$_mspec")")
    done

    check_docker
    check_image

    [[ -z "$session_name" ]] && session_name="tmp-$(date +%s)"

    # Check for existing running session
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^cc-${session_name}$"; then
        die "Session '${session_name}' already running (container cc-${session_name}). Run 'cco stop' first."
    fi

    local tmp_dir="/tmp/cc-${session_name}"
    # claude-state is the ~/.claude/projects tree (ADR-0055 D5), so the memory
    # dir sits under the -workspace key rather than at the bucket root.
    mkdir -p "$tmp_dir/claude-state/-workspace/memory" "$tmp_dir/.claude" || die "Failed to create temp directory: $tmp_dir"
    # ⚠ This trap REPLACES the sentinel trap bin/cco:14 arms — which is exactly why
    # the warn buffer cannot rely on an EXIT trap of its own (ADR-0059 D9). It is
    # swept here instead, alongside the temp dir, so a `die` between this line and
    # the gate leaves nothing behind either.
    trap 'rm -rf "'"$tmp_dir"'"; _cco_warn_capture_end' EXIT

    # Global config lives in the CONFIG bucket (~/.cco/.claude, flat — ADR-0028;
    # design §2.3). cco new is an ephemeral session: its transcripts/memory stay
    # in tmp_dir (no persistent project identity to key STATE by).
    local global_claude; global_claude="$(_cco_global_claude_dir)"

    # Create minimal project CLAUDE.md
    cat > "$tmp_dir/.claude/CLAUDE.md" <<EOF
# Temporary Session: ${session_name}

## Repositories
EOF

    # Validate repos and build mount list
    local repo_mounts=()
    for repo in "${repos[@]}"; do
        repo=$(expand_path "$repo")
        [[ ! -d "$repo" ]] && die "Repository path '$repo' does not exist."
        local repo_name
        repo_name=$(basename "$repo")
        repo_mounts+=("$repo:/workspace/$repo_name")
        echo "- /workspace/${repo_name}/" >> "$tmp_dir/.claude/CLAUDE.md"
    done

    # Generate docker-compose.yml
    local compose_file="$tmp_dir/docker-compose.yml"
    {
        cat <<YAML
# AUTO-GENERATED by cco CLI for temporary session
services:
  claude:
    image: $IMAGE_NAME
    container_name: cc-${session_name}
    stdin_open: true
    tty: true
    environment:
      - PROJECT_NAME=${session_name}
      - TEAMMATE_MODE=${teammate_mode}
      - CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
YAML

        # Forward debug mode to container
        if [[ "${CCO_DEBUG:-}" == "1" ]]; then
            echo "      - CCO_DEBUG=1"
        fi

        cat <<YAML
    volumes:
      - \${HOME}/.claude.json:/home/claude/.claude.json.seed:ro
      # Global config
      - ${global_claude}/settings.json:/home/claude/.claude/settings.json:ro
      - ${global_claude}/CLAUDE.md:/home/claude/.claude/CLAUDE.md:ro
      - ${global_claude}/rules:/home/claude/.claude/rules:ro
      - ${global_claude}/agents:/home/claude/.claude/agents:ro
      - ${global_claude}/skills:/home/claude/.claude/skills:ro
      # Session config
      - ${tmp_dir}/.claude:/workspace/.claude
      # Claude state: auto memory + session transcripts, every cwd key (ADR-0055 D5)
      - ${tmp_dir}/claude-state:/home/claude/.claude/projects
YAML

        # Global MCP config
        if [[ -f "$global_claude/mcp.json" ]]; then
            echo "      # Global MCP servers"
            echo "      - ${global_claude}/mcp.json:/home/claude/.claude/mcp-global.json:ro"
        fi

        echo "      # Repositories"

        for mount in "${repo_mounts[@]}"; do
            echo "      - ${mount}"
        done

        # Session reference mounts (--mount, ADR-0027 D2): read-only by default,
        # :rw opt-in. Pre-resolved to abs_src<TAB>target<TAB>ro above.
        if [[ ${#user_mount_lines[@]} -gt 0 ]]; then
            echo "      # Reference mounts (--mount)"
            local _uline _us _ut _uro _usuffix
            for _uline in "${user_mount_lines[@]}"; do
                IFS=$'\t' read -r _us _ut _uro <<< "$_uline"
                _usuffix=""
                [[ "$_uro" == "true" ]] && _usuffix=":ro"
                echo "      - ${_us}:${_ut}${_usuffix}"
            done
        fi

        # Git identity (commit author — read-only, no SSH keys)
        echo "      # Git identity"
        echo "      - \${HOME}/.gitconfig:/home/claude/.gitconfig:ro"

        # Docker socket
        echo "      # Docker socket"
        echo "      - /var/run/docker.sock:/var/run/docker.sock"

        echo "    ports:"
        if [[ ${#extra_ports[@]} -gt 0 ]]; then
            for port in "${extra_ports[@]}"; do
                echo "      - \"${port}\""
            done
        else
            # Default ports
            echo '      - "3000:3000"'
            echo '      - "8080:8080"'
        fi

        cat <<YAML
    working_dir: /workspace

networks:
  default:
    name: cc-${session_name}
    driver: bridge
YAML
    } > "$compose_file"

    # Resolve auth token for the session
    local run_env=()
    local token
    token=$(get_oauth_token)
    if [[ -n "$token" ]]; then
        run_env+=(-e "CLAUDE_CODE_OAUTH_TOKEN=$token")
    else
        warn "Could not extract OAuth token from Keychain. Claude may prompt for login."
    fi

    # Load global secrets
    load_global_secrets run_env

    # The gate (ADR-0059 D7/D9) — same placement rule as `cco start`: after secrets,
    # before anything takes the terminal. `_cco_warn_gate` is the shared
    # implementation (lib/utils.sh); a second copy here is how the twin verb would
    # keep the defect after the fix shipped.
    if ! _cco_warn_gate; then
        _cco_warn_capture_end
        info "Aborted — no session started."
        return 0
    fi
    _cco_warn_capture_end

    info "Starting temporary session '${session_name}'..."
    docker compose -f "$compose_file" run --rm --service-ports "${run_env[@]+"${run_env[@]}"}" claude

    ok "Session ended."
}
