#!/usr/bin/env bash
# lib/cmd-stop.sh — Stop running sessions command
#
# Provides: cmd_stop()
# Dependencies: colors.sh, utils.sh, yaml.sh, index.sh, paths.sh

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
        # Resolve the project's committed config via the STATE index; runtime
        # state lives in CACHE, keyed by project name.
        local container_name="cc-${project}"
        local repo proj_yml=""
        repo=$(_index_get_path "$project")
        [[ -n "$repo" ]] && proj_yml="$repo/.cco/project.yml"

        if [[ -n "$proj_yml" && -f "$proj_yml" ]]; then
            local yml_name
            yml_name=$(yml_get "$proj_yml" "name")
            [[ -n "$yml_name" ]] && container_name="cc-${yml_name}"
        fi

        if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
            docker stop "$container_name"
            ok "Stopped session '$project'"
        else
            warn "No running session for '$project'"
        fi

        # Clean up managed integration runtime state (CACHE, keyed by project name)
        local managed; managed=$(_cco_project_cache_managed "$project")
        rm -f "$managed/browser.json" "$managed/.browser-port" "$managed/github.json"
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
        local proj managed
        while IFS='=' read -r proj _; do
            [[ -z "$proj" ]] && continue
            managed=$(_cco_project_cache_managed "$proj")
            rm -f "$managed/browser.json" "$managed/.browser-port" "$managed/github.json"
        done < <(_index_list_projects)
    fi
}
