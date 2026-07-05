#!/usr/bin/env bash
# lib/session-context.sh — Level A session-context builder (ADR-0042)
#
# Replaces the retired lib/workspace.sh generator. Instead of writing a
# `workspace.yml` file into the session's .claude overlay (a generated artifact
# that leaked into committed trees — ADR-0042 P-a/P-b), cco start computes the
# host-side session context here and injects it into the container as an
# environment variable (CCO_SESSION_CONTEXT / CCO_SUBAGENT_CONTEXT, base64). The
# SessionStart / SubagentStart hooks decode it and emit it as additionalContext,
# merged with their in-container discovery (repos, skills, agents, MCP).
#
# Invariants (design §5): the block carries only session-fixed info (INV-1); no
# file is written to any committed or cache tree (INV-2); resource descriptions
# have exactly one structured source — project.yml (INV-3); host paths appear
# only in the gated path_map (INV-4, show_host_paths).
#
# Provides: _build_session_context(), _build_subagent_context(),
#           _session_collect_knowledge(), _session_collect_pathmap()
# Dependencies: yaml.sh, utils.sh, local-paths.sh (schema bridge), index.sh,
#   packs.sh (_pack_resolve_dir), llms.sh (_llms_render_entries)

# Collect knowledge-file entries (path + description) for the injected context.
# Iterates the active packs and emits one line per knowledge file:
# "<container_path>\t<desc>" (description may be empty). Unchanged in substance
# from the retired workspace.sh collector — only the consumer changed.
_session_collect_knowledge() {
    local pack_names="$1"
    local project_dir="$2"

    [[ -z "$pack_names" ]] && return 0
    while IFS= read -r pack_name; do
        [[ -z "$pack_name" ]] && continue
        local _pmroot; _pmroot=$(_pack_resolve_dir "$pack_name" "$project_dir")
        [[ -z "$_pmroot" ]] && continue
        local pack_yml="$_pmroot/pack.yml"
        [[ ! -f "$pack_yml" ]] && continue
        if ! grep -qE '^(name|knowledge|llms|skills|agents|rules):' "$pack_yml"; then
            warn "Pack '$pack_name': pack.yml has no valid top-level keys — check for extra indentation."
            continue
        fi
        local pack_files
        pack_files=$(yml_get_pack_knowledge_files "$pack_yml")
        [[ -z "$pack_files" ]] && continue
        local fname fdesc
        while IFS=$'\t' read -r fname fdesc; do
            [[ -z "$fname" ]] && continue
            printf '%s\t%s\n' "/workspace/.claude/packs/${pack_name}/${fname}" "$fdesc"
        done <<< "$pack_files"
    done <<< "$pack_names"
}

# Collect host->container path-map entries (gated by show_host_paths). Labelled
# triples so the agent never mistakes a host path for a container path.
# Resolution stays host-side, before compose (ADR-0007). Emits
# "<host>\t<target>\t<readonly>".
_session_collect_pathmap() {
    local project_yml="$1"

    local _repo_lines
    _repo_lines=$(_effective_repo_mounts "$project_yml")
    if [[ -n "$_repo_lines" ]]; then
        local _rn _host_p
        while IFS=$'\t' read -r _rn _host_p; do
            [[ -z "$_rn" ]] && continue
            printf '%s\t%s\tfalse\n' "$_host_p" "/workspace/${_rn}"
        done <<< "$_repo_lines"
    fi

    local _extra_mounts
    _extra_mounts=$(_effective_extra_mounts "$project_yml" 2>/dev/null || true)
    if [[ -n "$_extra_mounts" ]]; then
        local _src _tgt _ro
        while IFS=$'\t' read -r _src _tgt _ro; do
            [[ -z "$_src" ]] && continue
            [[ "$_ro" == "true" ]] || _ro="false"
            printf '%s\t%s\t%s\n' "$_src" "$_tgt" "$_ro"
        done <<< "$_extra_mounts"
    fi
}

# Read a repo's optional description from project.yml (INV-3 single source).
# project.yml is the only structured home for descriptions now — no round-trip.
_session_repo_description() {
    local project_yml="$1" repo_name="$2"
    [[ -f "$project_yml" ]] || return 0
    awk -v name="$repo_name" '
        /^repos:/ { in_repos=1; next }
        in_repos && /^[^ #]/ { exit }
        in_repos && /^  - name:/ {
            sub(/^  - name: */, ""); gsub(/["\047]/, "")
            in_repo = ($0 == name); next
        }
        in_repos && /^  - / { in_repo=0 }
        in_repos && in_repo && /^    description:/ {
            sub(/^    description: */, ""); gsub(/["\047]/, ""); print; exit
        }
    ' "$project_yml"
}

# Read an extra-mount's optional description from project.yml (INV-3 single
# source), keyed by the mount's EFFECTIVE container target — the render loop
# only carries the target (_effective_extra_mounts drops the logical name), so
# each entry's effective target (explicit `target:` or the `/workspace/<name>`
# default) is reconstructed and matched. Fields may appear in any order.
_session_mount_description() {
    local project_yml="$1" mount_target="$2"
    [[ -f "$project_yml" ]] || return 0
    awk -v want="$mount_target" '
        function flush() {
            if (in_entry) {
                eff = (t != "" ? t : "/workspace/" n)
                if (eff == want) { print d; exit }
            }
        }
        /^extra_mounts:/ { in_em=1; next }
        in_em && /^[^ #]/ { flush(); exit }
        in_em && /^  - name:/ {
            flush()
            sub(/^  - name: */, ""); gsub(/["\047]/, "")
            n=$0; t=""; d=""; in_entry=1; next
        }
        in_em && in_entry && /^    target:/ {
            sub(/^    target: */, ""); gsub(/["\047]/, ""); t=$0
        }
        in_em && in_entry && /^    description:/ {
            sub(/^    description: */, ""); gsub(/["\047]/, ""); d=$0
        }
        END { flush() }
    ' "$project_yml"
}

# Build the FULL Level-A session-context block (SessionStart). Printed to stdout
# as plain text; the caller base64-encodes it into CCO_SESSION_CONTEXT. Sections
# are omitted when empty. Mirrors, in prose form, every section the retired
# workspace.yml carried (project/repos+desc/packs/knowledge/llms/extra_mounts/
# path_map) plus the wrapped-cco access declaration (design §2 division of labour).
#
# Args: <project_name> <project_yml> <pack_names> <project_dir> <show_host_paths>
#       <cco_access> <claude_md_present:true|false>
_build_session_context() {
    local project_name="$1" project_yml="$2" pack_names="$3" project_dir="$4"
    local show_host_paths="$5" cco_access="${6:-none}" claude_md_present="${7:-true}"

    local knowledge_entries llms_entries pathmap_entries=""
    knowledge_entries=$(_session_collect_knowledge "$pack_names" "$project_dir")
    llms_entries=$(_llms_render_entries "$project_yml" "$pack_names" "$project_dir")
    if [[ "$show_host_paths" == "true" ]]; then
        pathmap_entries=$(_session_collect_pathmap "$project_yml")
    fi

    echo "<CcoSessionInfo>"
    echo "This session runs under cco (claude-orchestrator), which manages the"
    echo "container, repos, and config. Repos are mounted at /workspace/<name>."
    # Wrapped-cco declaration — only when the shim is present (cco_access != none).
    if [[ "$cco_access" != "none" ]]; then
        echo "A wrapped \`cco\` CLI is available in-container for on-demand detail"
        echo "(access scope: ${cco_access}). Use \`cco list\`, \`cco <kind> show\`,"
        echo "and \`cco docs\` for more than this start-time summary."
        # ADR-0043 §5 awareness (INV-B pairing): at read-project the wrapped cco
        # gives a PROJECT-SCOPED view of ~/.cco — read verbs show only this
        # project + its referenced packs/llms; hidden ≠ absent. Only meaningful at
        # read-project (read-global/read-all/edit-* see the whole store).
        if [[ "$cco_access" == "read-project" ]]; then
            echo "At this scope the \`cco\` read verbs show a PROJECT-SCOPED view of"
            echo "your \`~/.cco\`: only this project and the packs/llms it references."
            echo "Templates, other projects, and unreferenced packs are hidden (a"
            echo "stderr notice says how many). A hidden resource is not missing —"
            echo "start a read-global session or run cco on your host to see all."
        fi
    else
        # R6: at `none` the wrapped cco is deliberately unavailable (least-privilege
        # floor). State it explicitly so the agent does not attempt cco commands.
        echo "The wrapped \`cco\` CLI is not available in this session (cco_access=none)."
    fi

    # Project resources: repos (+ optional description), packs, extra_mounts.
    local repos_output
    repos_output=$(_effective_repo_mounts "$project_yml")
    local extra_mounts_output
    extra_mounts_output=$(_effective_extra_mounts "$project_yml" 2>/dev/null || true)
    if [[ -n "$repos_output" || -n "$pack_names" || -n "$extra_mounts_output" ]]; then
        echo ""
        echo "Project resources:"
        if [[ -n "$repos_output" ]]; then
            local repo_name repo_path desc
            while IFS=$'\t' read -r repo_name repo_path; do
                [[ -z "$repo_name" ]] && continue
                desc=$(_session_repo_description "$project_yml" "$repo_name")
                if [[ -n "$desc" ]]; then
                    echo "- repo: ${repo_name} at /workspace/${repo_name} — ${desc}"
                else
                    echo "- repo: ${repo_name} at /workspace/${repo_name}"
                fi
            done <<< "$repos_output"
        fi
        if [[ -n "$pack_names" ]]; then
            local pack_name
            while IFS= read -r pack_name; do
                [[ -z "$pack_name" ]] && continue
                echo "- pack: ${pack_name}"
            done <<< "$pack_names"
        fi
        if [[ -n "$extra_mounts_output" ]]; then
            local _ws_src _ws_tgt _ws_ro _ws_desc _ws_ro_label
            while IFS=$'\t' read -r _ws_src _ws_tgt _ws_ro; do
                [[ -z "$_ws_tgt" ]] && continue
                _ws_desc=$(_session_mount_description "$project_yml" "$_ws_tgt")
                [[ "$_ws_ro" == "true" ]] && _ws_ro_label=" (read-only)" || _ws_ro_label=""
                if [[ -n "$_ws_desc" ]]; then
                    echo "- mount: ${_ws_tgt}${_ws_ro_label} — ${_ws_desc}"
                else
                    echo "- mount: ${_ws_tgt}${_ws_ro_label}"
                fi
            done <<< "$extra_mounts_output"
        fi
    fi

    # R7 — declared-but-unresolved resources. Named in project.yml but not
    # resolvable on this host, so cco start dropped them from the session mounts.
    # Surface them explicitly (marker-only) so the agent never reasons about a
    # resource that isn't there — the omission is terminal at `none` (no CLI to
    # discover the gap) and misleading at any level.
    local _unres_mounts _unres_llms
    _unres_mounts=$(_declared_unresolved_extra_mounts "$project_yml" 2>/dev/null || true)
    _unres_llms=$(_declared_unresolved_llms "$project_yml" "$pack_names" "$project_dir" 2>/dev/null || true)
    if [[ -n "$_unres_mounts" || -n "$_unres_llms" ]]; then
        echo ""
        echo "Declared but not mounted this session (unresolved on this host — fix with"
        echo "'cco resolve' on the host, or drop the stale reference from project.yml):"
        if [[ -n "$_unres_mounts" ]]; then
            local _um_name _um_tgt
            while IFS=$'\t' read -r _um_name _um_tgt; do
                [[ -z "$_um_name" ]] && continue
                echo "- mount: ${_um_name} (would mount at ${_um_tgt}) — unresolved"
            done <<< "$_unres_mounts"
        fi
        if [[ -n "$_unres_llms" ]]; then
            local _ul
            while IFS= read -r _ul; do
                [[ -z "$_ul" ]] && continue
                echo "- llms: ${_ul} — unresolved"
            done <<< "$_unres_llms"
        fi
    fi

    # Knowledge files (absorbed from the former packs.md — R1-D2). Preamble kept
    # for parity with the prior hook rendering.
    if [[ -n "$knowledge_entries" ]]; then
        echo ""
        echo "Knowledge files (project conventions). Read the relevant files BEFORE"
        echo "starting any implementation, review, or design task. Do not ask the"
        echo "user for context that is covered by these files."
        local _kpath _kdesc
        while IFS=$'\t' read -r _kpath _kdesc; do
            [[ -z "$_kpath" ]] && continue
            if [[ -n "$_kdesc" ]]; then
                echo "- ${_kpath} — ${_kdesc}"
            else
                echo "- ${_kpath}"
            fi
        done <<< "$knowledge_entries"
    fi

    # Official framework docs (llms.txt).
    if [[ -n "$llms_entries" ]]; then
        echo ""
        echo "Official Framework Documentation (llms.txt). Consult these BEFORE"
        echo "writing code that uses these frameworks — do not rely solely on"
        echo "training data. For large files read selectively (offset/limit)."
        local _lpath _ldesc
        while IFS=$'\t' read -r _lpath _ldesc; do
            [[ -z "$_lpath" ]] && continue
            if [[ -n "$_ldesc" ]]; then
                echo "- ${_lpath} — ${_ldesc}"
            else
                echo "- ${_lpath}"
            fi
        done <<< "$llms_entries"
    fi

    # Host<->container path map (INV-4): labelled host->target pairs, gated by
    # show_host_paths. A read-only runtime view of the user's own machine paths —
    # never committed state. Lets the agent hand the user copy-pasteable host
    # commands (config-safety.md warns against pasting host paths into commits).
    if [[ -n "$pathmap_entries" ]]; then
        echo ""
        echo "Host<->container path map (LEFT = host path on your machine, RIGHT ="
        echo "container path). Host paths are for handing the user copy-pasteable"
        echo "commands — never commit them."
        local _pm_host _pm_tgt _pm_ro
        while IFS=$'\t' read -r _pm_host _pm_tgt _pm_ro; do
            [[ -z "$_pm_host" ]] && continue
            if [[ "$_pm_ro" == "true" ]]; then
                echo "- ${_pm_host} -> ${_pm_tgt} (read-only)"
            else
                echo "- ${_pm_host} -> ${_pm_tgt}"
            fi
        done <<< "$pathmap_entries"
    fi

    # init-workspace nudge (design §7): Level A no longer depends on the skill —
    # a missing CLAUDE.md degrades only the rich narrative, never the session.
    if [[ "$claude_md_present" != "true" ]]; then
        echo ""
        echo "Tip: this project has no CLAUDE.md yet — run /init-workspace to author it."
    fi

    echo "</CcoSessionInfo>"
}

# Build the CONDENSED subagent-context block (SubagentStart). Subagents need key
# facts only (design §2): the knowledge + llms PATHS to read, no descriptions,
# no preambles. Printed to stdout; the caller base64-encodes it into
# CCO_SUBAGENT_CONTEXT. Empty output when there are no knowledge/llms entries.
#
# Args: <project_yml> <pack_names> <project_dir>
_build_subagent_context() {
    local project_yml="$1" pack_names="$2" project_dir="$3"

    local knowledge_entries llms_entries
    knowledge_entries=$(_session_collect_knowledge "$pack_names" "$project_dir")
    llms_entries=$(_llms_render_entries "$project_yml" "$pack_names" "$project_dir")
    [[ -z "$knowledge_entries" && -z "$llms_entries" ]] && return 0

    echo "<CcoSubagentInfo>"
    echo "Knowledge & framework docs (read the relevant ones before implementation tasks):"
    local _p _d
    if [[ -n "$knowledge_entries" ]]; then
        while IFS=$'\t' read -r _p _d; do
            [[ -z "$_p" ]] && continue
            echo "- ${_p}"
        done <<< "$knowledge_entries"
    fi
    if [[ -n "$llms_entries" ]]; then
        while IFS=$'\t' read -r _p _d; do
            [[ -z "$_p" ]] && continue
            echo "- ${_p}"
        done <<< "$llms_entries"
    fi
    echo "</CcoSubagentInfo>"
}
