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

    # The resolved (G,Pc,Po) triple is the single source; read/write scopes are the
    # ordinal display over it, and each config tree's rw/ro/— is its axis value
    # (ADR-0046 §7). (whoami+ — the explicit triple line, granular form hint, and
    # privilege-boundary note — lands in the Phase III per-command pass.)
    local level rscope wscope _wg _wpc _wpo
    level=$(_env_access)
    rscope=$(_env_read_scope)
    wscope=$(_env_write_scope)
    read -r _wg _wpc _wpo <<< "$(_env_triple)"

    # rw/ro/— for an axis value (rw>ro>none).
    _wm() { case "$1" in rw) printf 'rw' ;; ro) printf 'ro' ;; *) printf '—' ;; esac; }

    printf '%bSession access%b\n' "$BOLD" "$NC"
    printf '  cco_access:       %s  (G=%s Pc=%s Po=%s; read scope: %s, write scope: %s)\n' \
        "$level" "$_wg" "$_wpc" "$_wpo" "$rscope" "$wscope"
    printf '  claude_access:    %s\n' "${CCO_CLAUDE_ACCESS:-repo}"
    printf '  show_host_paths:  %s\n' "${CCO_SHOW_HOST_PATHS:-true}"
    printf '  project:          %s\n' "${PROJECT_NAME:-(none)}"
    [[ -n "${CCO_CONFIG_TARGETS:-}" ]] && printf '  config targets:   %s\n' "${CCO_CONFIG_TARGETS}"
    echo ""
    printf '%bConfig trees%b\n' "$BOLD" "$NC"
    printf '  project config (<repo>/.cco):        %s\n' "$(_wm "$_wpc")"
    printf '  personal store (~/.cco) + registry:  %s\n' "$(_wm "$_wg")"
    printf '  llms cache:                          %s\n' "$(_wm "$_wg")"
    if [[ "$(_cco_axis_rank "$_wpo")" -ge 1 ]]; then
        printf "  other projects' config:              %s\n" "$(_wm "$_wpo")"
    fi
    return 0
}
