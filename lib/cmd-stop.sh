#!/usr/bin/env bash
# lib/cmd-stop.sh — Stop running sessions command
#
# Provides: cmd_stop()
# Dependencies: colors.sh, utils.sh, yaml.sh
# Globals: PROJECTS_DIR

cmd_stop() {
    if [[ "${1:-}" == "--help" ]]; then
        cat <<'EOF'
Usage: cco stop [<project>]

Stop running session(s) and clean up runtime state.

Without arguments, stops all running cco sessions.
With a project name, stops only that project's session.
EOF
        return 0
    fi

    local project="${1:-}"

    check_docker

    if [[ -n "$project" ]]; then
        local project_dir="$PROJECTS_DIR/$project"
        local project_yml="$project_dir/project.yml"
        local container_name="cc-${project}"

        if [[ -f "$project_yml" ]]; then
            local yml_name
            yml_name=$(yml_get "$project_yml" "name")
            [[ -n "$yml_name" ]] && container_name="cc-${yml_name}"
        fi

        if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
            docker stop "$container_name"
            ok "Stopped session '$project'"
        else
            warn "No running session for '$project'"
        fi

        # Clean up managed integration runtime state
        rm -f "$project_dir/.cco/managed/browser.json" "$project_dir/.cco/managed/.browser-port"
        rm -f "$project_dir/.cco/managed/github.json"
    else
        local containers
        containers=$(docker ps --filter "name=cc-" --format '{{.Names}}' 2>/dev/null)
        if [[ -z "$containers" ]]; then
            info "No running sessions."
            return 0
        fi
        echo "$containers" | while read -r name; do
            docker stop "$name"
            ok "Stopped $name"
        done
        # Clean managed runtime state for all projects (all sessions stopped)
        for proj_dir in "$PROJECTS_DIR"/*/; do
            rm -f "$proj_dir/.cco/managed/browser.json" "$proj_dir/.cco/managed/.browser-port"
            rm -f "$proj_dir/.cco/managed/github.json"
        done
    fi
}
