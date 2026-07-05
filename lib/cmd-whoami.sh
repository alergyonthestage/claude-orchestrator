#!/usr/bin/env bash
# lib/cmd-whoami.sh — `cco whoami`: minimal session-state introspection (F4).
#
# Reports the session's own resolved access state so an in-container agent can
# reason about what it may read/write WITHOUT trial-and-error against the shim.
# It consumes the F4 exports (CCO_CCO_ACCESS / CCO_CLAUDE_ACCESS /
# CCO_SHOW_HOST_PATHS / PROJECT_NAME / CCO_CONFIG_TARGETS) and the ADR-0043 scope
# maps (access-scope.sh) — no filesystem probing. Read-safe, always available at
# any read level; refused only at `none` (where cco is refused wholesale, R6).
#
# NOTE: the verb NAME is provisional. The post-fix CLI-UX review finalizes it
# (`whoami` vs `session`; whether to reserve `cco status` for global cco state).
# This ships the CAPABILITY under a working name (fix design 02 §F4, ratified).
#
# Provides: cmd_whoami()
# Dependencies: colors.sh, paths.sh (_cco_container_operator), access-scope.sh

cmd_whoami() {
    case "${1:-}" in
        -h|--help)
            cat <<'EOF'
Usage: cco whoami

Report this session's resolved access state: the cco/claude access levels, the
current project (and config-editor targets, if any), and which config trees are
writable vs read-only. Read-only, always available in a session.
EOF
            return 0
            ;;
    esac

    # On the host there is no session envelope — cco runs unrestricted.
    if ! _cco_container_operator; then
        info "Not in a cco session (host context) — cco runs unrestricted here."
        return 0
    fi

    local level rscope wscope
    level=$(_env_access)
    rscope=$(_cco_level_read_scope "$level")
    wscope=$(_cco_level_write_scope "$level")

    # rw/ro/— for a target tree, derived from write_scope (single source).
    _wm() { _cco_write_scope_satisfies "$wscope" "$1" && printf 'rw' || printf 'ro'; }

    printf '%bSession access%b\n' "$BOLD" "$NC"
    printf '  cco_access:       %s  (read scope: %s, write scope: %s)\n' "$level" "$rscope" "$wscope"
    printf '  claude_access:    %s\n' "${CCO_CLAUDE_ACCESS:-repo}"
    printf '  show_host_paths:  %s\n' "${CCO_SHOW_HOST_PATHS:-true}"
    printf '  project:          %s\n' "${PROJECT_NAME:-(none)}"
    [[ -n "${CCO_CONFIG_TARGETS:-}" ]] && printf '  config targets:   %s\n' "${CCO_CONFIG_TARGETS}"
    echo ""
    printf '%bConfig trees%b\n' "$BOLD" "$NC"
    printf '  project config (<repo>/.cco):        %s\n' "$(_wm project)"
    printf '  personal store (~/.cco) + registry:  %s\n' "$(_wm global)"
    printf '  llms cache:                          %s\n' "$(_wm global)"
    if [[ "$wscope" == "all" ]]; then
        printf "  other projects' config:              rw (config-editor)\n"
    fi
    return 0
}
