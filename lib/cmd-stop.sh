#!/usr/bin/env bash
# lib/cmd-stop.sh — Stop running sessions command
#
# Provides: cmd_stop()
# Dependencies: colors.sh, utils.sh, yaml.sh, index.sh, paths.sh, cmd-resolve.sh

cmd_stop() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
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

    # Session running registry (ADR-0045): reap any stale markers first (backstop for
    # prior no-`cco stop` exits), then drop the marker(s) for what we stop below.
    _cco_running_reconcile

    if [[ -n "$project" ]]; then
        # Resolve the project's committed config via the STATE index; runtime
        # state lives in CACHE, keyed by project name. Use the membership resolver
        # (not _index_get_path on the project key) so a joined multi-repo project —
        # whose key is in `projects:` but not `paths:` — still finds its project.yml
        # and the `name:` container override.
        # Session identity is the `cco.project` label (R1). The label value is the
        # project.yml `name:` (when the repo resolves) else the index/arg name.
        local label_name="$project"
        local repo proj_yml=""
        repo=$(_resolve_unit_dir_for_project "$project" 2>/dev/null)
        [[ -n "$repo" ]] && proj_yml="$repo/.cco/project.yml"

        if [[ -n "$proj_yml" && -f "$proj_yml" ]]; then
            local yml_name
            yml_name=$(yml_get "$proj_yml" "name")
            [[ -n "$yml_name" ]] && label_name="$yml_name"
        fi

        local ids; ids=$(_cco_session_container_ids "$label_name")
        if [[ -n "$ids" ]]; then
            # `run --rm` removes the container on stop; target the live IDs by label.
            echo "$ids" | while read -r cid; do docker stop "$cid" >/dev/null; done
            ok "Stopped session '$project'"
        else
            warn "No running session for '$project'"
        fi
        _cco_running_unmark "$label_name"

        # Clean up managed integration runtime state (CACHE, keyed by project name)
        local managed; managed=$(_cco_project_cache_managed "$project")
        rm -f "$managed/browser.json" "$managed/.browser-port" "$managed/github.json"
    else
        # All running sessions: match by the `cco.project` label key (R1) — the
        # former `name=cc-` filter matched nothing under `run --rm`.
        local containers
        containers=$(_cco_any_session_containers)
        if [[ -z "$containers" ]]; then
            info "No running sessions."
            return 0
        fi
        echo "$containers" | while IFS=$'\t' read -r cid proj; do
            [[ -z "$cid" ]] && continue
            docker stop "$cid" >/dev/null
            [[ -n "$proj" ]] && _cco_running_unmark "$proj"
            ok "Stopped ${proj:-$cid}"
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
