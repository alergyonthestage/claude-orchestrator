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
# Dependencies: colors.sh, paths.sh (_cco_container_operator), access-scope.sh,
#   yaml.sh (yml_get_repo_coords, for the mounted-repos line)

# Mounted code repos for the R1 identity block: the repo names in the session's
# /workspace/project.yml that are actually present as directories under /workspace
# (the mount happened). Reads only the mounted manifest + a dir test — no index or
# store probe (those sit behind the ADR-0047 boundary). Empty when config-only
# (e.g. config-editor global mode, or a repo-free built-in). Comma-joined.
_whoami_mounted_repos() {
    local pyml="/workspace/project.yml" name out=""
    [[ -f "$pyml" ]] || return 0
    while IFS=$'\t' read -r name _; do
        [[ -z "$name" ]] && continue
        [[ -d "/workspace/$name" ]] || continue
        out+="${out:+, }$name"
    done < <(yml_get_repo_coords "$pyml" 2>/dev/null)
    printf '%s' "$out"
}

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
        # Developer sandbox indicator (ADR-0052 §7): when engaged, the internal
        # buckets are isolated so a dev binary never collides with the published
        # one. Surfaced HERE (host branch) because the sandbox is a host-developer
        # tool — a real session never runs it. Report the resolved bucket paths so a
        # sandbox session is never mistaken for the real one.
        if _cco_dev_sandbox_active; then
            echo ""
            printf '%bDeveloper sandbox%b  internal state isolated (ADR-0052 §7)\n' "$BOLD" "$NC"
            printf '  sandbox root:  %s\n' "${CCO_DEV_SANDBOX_ROOT:-$(_cco_dev_sandbox_root)}"
            printf '  STATE:         %s\n' "$(_cco_state_dir)"
            printf '  DATA:          %s\n' "$(_cco_data_dir)"
            printf '  CACHE:         %s\n' "$(_cco_cache_dir)"
            printf '  CONFIG:        %s  (shared — not sandboxed)\n' "$(_cco_config_dir)"
        fi
        return 0
    fi

    # The resolved (G,Pc,Po) triple is the single source; read/write scopes are the
    # ordinal display over it, and each config tree's rw/ro/— is its axis value
    # (ADR-0046 §7). whoami+ (A1 §4.5): render the triple explicitly and state that
    # enforcement is the ADR-0047 privilege boundary.
    local rscope wscope _wg _wpc _wpo
    rscope=$(_env_read_scope)
    wscope=$(_env_write_scope)
    read -r _wg _wpc _wpo <<< "$(_env_triple)"

    # rw/ro/— for an axis value (rw>ro>none).
    _wm() { case "$1" in rw) printf 'rw' ;; ro) printf 'ro' ;; *) printf '—' ;; esac; }

    # ── Session identity (R1) ────────────────────────────────────────────
    # Identity first (the envelope), THEN access. In a config-editor session the
    # PROJECT_NAME is the synthetic 'config-editor' (the envelope) while the projects
    # it EDITS are CCO_CONFIG_TARGETS — two distinct concepts the old single 'project'
    # line conflated. Whether code repos are mounted (repo-aware authoring / a normal
    # session) vs config-only is surfaced too (answers "solo la .cco o anche il repo?").
    printf '%bSession%b\n' "$BOLD" "$NC"
    printf '  identity:         %s\n' "${PROJECT_NAME:-(none)}"
    [[ -n "${CCO_CONFIG_TARGETS:-}" ]] && \
        printf '  editing target:   %s\n' "${CCO_CONFIG_TARGETS//,/, }"
    local _repos; _repos=$(_whoami_mounted_repos)
    printf '  code repos:       %s\n' "${_repos:-— (config only)}"
    # Build provenance (V1-F3): which source ref this IMAGE was built from, baked at
    # /opt/cco/BUILD by the Dockerfile. Reported next to the access lines because the
    # e2e §4 template asks for both together, and because "the fix is in" is a claim
    # about the image, not the working tree — the two diverge constantly in self-dev
    # (a lib/ edit is invisible to a store-touching verb until the next `cco build`).
    # Absent on an image built before this landed: say so, never fabricate.
    local _build="unknown"
    [[ -r /opt/cco/BUILD ]] && read -r _build < /opt/cco/BUILD
    printf '  image built from: %s\n' "${_build:-unknown}"
    echo ""

    # ── Access (R2) ──────────────────────────────────────────────────────
    # One canonical form per line, no byte-duplication: `level` names the PRESET when
    # the resolved triple is symmetric, else `custom (…)` carrying the granular form
    # (the copy-pasteable --cco-access identity); `triple` is the explicit, readable
    # G/Pc/Po + read/write scope. Presets pass back by name, custom by its granular.
    local level_display preset
    if preset=$(_cco_triple_preset "$_wg $_wpc $_wpo"); then
        level_display="$preset"
    else
        level_display="custom (global=${_wg},current=${_wpc},others=${_wpo})"
    fi
    # claude_access is the Axis-B triple (Cr,Cp,Cg,Co) — the .claude AUTHORING trees
    # (ADR-0049); CCO_CLAUDE_ACCESS is its label, CCO_CLAUDE_TRIPLE the axes.
    local _cr _cp _cg _co
    IFS=, read -r _cr _cp _cg _co <<< "${CCO_CLAUDE_TRIPLE:-ro,ro,ro,ro}"
    printf '%bAccess%b\n' "$BOLD" "$NC"
    printf '  level:            %s\n' "$level_display"
    printf '  triple:           G=%s Pc=%s Po=%s  (read: %s, write: %s)\n' \
        "$_wg" "$_wpc" "$_wpo" "$rscope" "$wscope"
    printf '  claude_access:    %s\n' "${CCO_CLAUDE_ACCESS:-none}"
    printf '  claude triple:    Cr=%s Cp=%s Cg=%s Co=%s\n' "$_cr" "$_cp" "$_cg" "$_co"
    printf '  show_host_paths:  %s\n' "${CCO_SHOW_HOST_PATHS:-true}"
    echo ""
    printf '%bConfig trees (.cco)%b\n' "$BOLD" "$NC"
    printf '  project config (<repo>/.cco):        %s\n' "$(_wm "$_wpc")"
    printf '  personal store (~/.cco) + registry:  %s\n' "$(_wm "$_wg")"
    printf '  llms cache:                          %s\n' "$(_wm "$_wg")"
    if [[ "$(_cco_axis_rank "$_wpo")" -ge 1 ]]; then
        printf "  other projects' config:              %s\n" "$(_wm "$_wpo")"
    fi
    echo ""
    printf '%bAuthoring trees (.claude)%b\n' "$BOLD" "$NC"
    printf '  repo-native <repo>/.claude (Cr):     %s\n' "$(_wm "$_cr")"
    printf '  project <repo>/.cco/claude (Cp):     %s\n' "$(_wm "$_cp")"
    printf '  global ~/.cco/.claude (Cg):          %s\n' "$(_wm "$_cg")"
    if [[ "$(_cco_axis_rank "$_co")" -ge 1 ]] && [[ "$_co" == "rw" ]]; then
        printf "  other projects' .claude (Co):        %s\n" "$(_wm "$_co")"
    fi
    echo ""
    # Enforcement note (ADR-0047): the internal store (STATE index, DATA
    # registries, CACHE internals) is confined behind a mode-0700 cco-svc root the
    # agent cannot traverse; store-touching verbs are re-executed through a setuid
    # helper that re-checks this triple against the trusted session descriptor. So
    # these access values are enforced by a privilege boundary, not merely by
    # output-filtering — a raw read of the internal store fails with EACCES.
    printf '%bEnforcement%b  internal store confined behind the ADR-0047 privilege boundary —\n' "$BOLD" "$NC"
    printf '              store reads/writes are gated by this triple via the setuid cco-svc\n'
    printf '              helper (a raw read of the store fails), not just output-filtered.\n'
    return 0
}
