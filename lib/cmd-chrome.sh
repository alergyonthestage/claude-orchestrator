#!/usr/bin/env bash
# lib/cmd-chrome.sh — Host-side Chrome debug session management
#
# Provides: cmd_chrome(), _chrome_resolve_port(), _chrome_is_running()
# Dependencies: colors.sh, utils.sh, yaml.sh
# Globals: PROJECTS_DIR
#
# NOTE: These commands run on the HOST, not inside the container.
# They manage Chrome's remote debugging session that the container
# connects to via chrome-devtools-mcp.

cmd_chrome() {
    local subcmd="${1:-start}"
    shift || true
    case "$subcmd" in
        start)  _chrome_start "$@" ;;
        stop)   _chrome_stop  "$@" ;;
        status) _chrome_status "$@" ;;
        --help|-h) _chrome_usage ;;
        *)      error "Unknown subcommand: $subcmd. Use: start, stop, status" ;;
    esac
}

_chrome_usage() {
    cat <<'EOF'
Usage: cco chrome [start|stop|status] [OPTIONS]

Manage a Chrome debug session on the host for browser automation.

Subcommands:
  start    Launch Chrome with remote debugging (default)
  stop     Kill the debug Chrome process
  status   Check if CDP endpoint is reachable

Options:
  --project <name>   Auto-detect port from project runtime state
  --port <n>         Explicit CDP port (default: 9222)

Port resolution priority:
  1. --port flag (explicit)
  2. --project → .managed/.browser-port file (effective runtime port)
  3. --project → project.yml browser.cdp_port
  4. Default: 9222
EOF
}

# Resolve port: --port flag > .managed/.browser-port file > project.yml > default 9222
_chrome_resolve_port() {
    local opt_port="" opt_project=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)    opt_port="$2";    shift 2 ;;
            --project) opt_project="$2"; shift 2 ;;
            *)         shift ;;
        esac
    done

    if [[ -n "$opt_port" ]]; then
        echo "$opt_port"; return
    fi

    if [[ -n "$opt_project" ]]; then
        # Warn if container is not running (stale runtime file)
        local yml_name container_name
        local proj_yml="$PROJECTS_DIR/$opt_project/project.yml"
        if [[ -f "$proj_yml" ]]; then
            yml_name=$(yml_get "$proj_yml" "name")
        fi
        [[ -z "${yml_name:-}" ]] && yml_name="$opt_project"
        container_name="cc-${yml_name}"
        if command -v docker &>/dev/null; then
            if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container_name}$"; then
                warn "Container ${container_name} is not running. Port may be stale."
            fi
        fi
        local runtime_file="$PROJECTS_DIR/$opt_project/.managed/.browser-port"
        if [[ -f "$runtime_file" ]]; then
            cat "$runtime_file"; return
        fi
        if [[ -f "$proj_yml" ]]; then
            local p; p=$(yml_get "$proj_yml" "browser.cdp_port")
            [[ -n "$p" ]] && echo "$p" && return
        fi
    fi

    echo "9222"
}

_chrome_start() {
    local port; port=$(_chrome_resolve_port "$@")
    local data_dir="${HOME}/.chrome-debug"

    if _chrome_is_running "$port"; then
        ok "Chrome is already running on CDP port ${port}"
        _chrome_status --port "$port"
        return 0
    fi

    info "Starting Chrome with remote debugging on port ${port}..."

    if [[ "$(uname)" == "Darwin" ]]; then
        local chrome_bin="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        if [[ ! -x "$chrome_bin" ]]; then
            error "Google Chrome not found at: $chrome_bin"
            info "Install Chrome from https://www.google.com/chrome/"
            return 1
        fi
        "$chrome_bin" \
            --remote-debugging-port="$port" \
            --remote-allow-origins="*" \
            --user-data-dir="$data_dir" \
            &>/dev/null &
        disown
    else
        local chrome_cmd=""
        for cmd in google-chrome google-chrome-stable chromium chromium-browser; do
            command -v "$cmd" &>/dev/null && chrome_cmd="$cmd" && break
        done
        if [[ -z "$chrome_cmd" ]]; then
            error "Chrome not found. Install with: sudo apt install google-chrome-stable"
            return 1
        fi
        "$chrome_cmd" \
            --remote-debugging-port="$port" \
            --remote-allow-origins="*" \
            --user-data-dir="$data_dir" \
            &>/dev/null &
        disown
    fi

    # Wait up to 5s for CDP to become available
    local i
    for i in 1 2 3 4 5; do
        sleep 1
        if _chrome_is_running "$port"; then
            ok "Chrome ready on CDP port ${port}"
            info "Profile: ${data_dir} (isolated from your main Chrome profile)"
            info "To stop: cco chrome stop"
            return 0
        fi
    done

    warn "Chrome started but CDP not yet reachable on port ${port}"
    info "Check with: cco chrome status"
}

_chrome_stop() {
    local port; port=$(_chrome_resolve_port "$@")
    if ! _chrome_is_running "$port"; then
        info "No Chrome debug session found on port ${port}"
        return 0
    fi
    local pid=""
    if command -v lsof &>/dev/null; then
        pid=$(lsof -ti "tcp:${port}" 2>/dev/null | head -1)
    elif command -v fuser &>/dev/null; then
        pid=$(fuser "${port}/tcp" 2>/dev/null | awk '{print $1}')
    fi
    if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null && ok "Chrome debug session stopped (pid ${pid})"
    else
        warn "Could not find process on port ${port}. Kill Chrome manually."
    fi
}

_chrome_status() {
    local port; port=$(_chrome_resolve_port "$@")
    if _chrome_is_running "$port"; then
        ok "Chrome is running and accepting CDP connections on port ${port}"
        local version_info browser_ver
        version_info=$(curl -s --max-time 2 "http://localhost:${port}/json/version" 2>/dev/null)
        browser_ver=$(echo "$version_info" | grep -o '"Browser":"[^"]*"' | cut -d'"' -f4)
        [[ -n "$browser_ver" ]] && info "Browser: ${browser_ver}"
    else
        warn "Chrome is not running or CDP port ${port} is not reachable"
        info "Start with: cco chrome start"
        return 1
    fi
}

_chrome_is_running() {
    local port="${1:-9222}"
    curl -s --max-time 1 "http://localhost:${port}/json/version" &>/dev/null
}
