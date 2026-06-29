#!/usr/bin/env bash
# lib/packs.sh — Pack resource helpers (manifest cleanup, conflicts, validate)
#
# Provides: _pack_resolve_dir(), _clean_pack_manifest(), _detect_pack_conflicts(),
#           _detect_cross_tree_conflicts(), _generate_pack_mounts(),
#           _validate_single_pack()
# Dependencies: colors.sh, utils.sh, yaml.sh
# Globals: PACKS_DIR

# Resolve a pack name to its on-disk directory using the MOUNT order (ADR-0019 D5
# / design §2.4 resolver table). Two local layers, local-first:
#   1. ~/.cco/packs/<name>        — the user's library / working copy (wins)
#   2. <repo>/.cco/packs/<name>   — project-local: authored source (entry has no
#                                   url) OR an opt-in last-layer cache (entry has url)
# The url-fetch layer (layer 2 of the table) is NOT performed here: at `cco start`
# a url-bearing pack missing from both local layers is a conscious-skip (warn),
# with the fetch offered by `cco resolve` / the unresolved prompt (P14, mirroring
# repo resolution). The CACHE-vs-authored distinction (the validate ERROR row) is
# `cco project validate`'s concern, not the mount resolver. Echoes the resolved
# absolute dir, or nothing if unresolved.
# Usage: _pack_resolve_dir <name> <project_cco_dir>
_pack_resolve_dir() {
    local name="$1" project_cco_dir="${2:-}"
    if [[ -d "$PACKS_DIR/$name" ]]; then
        printf '%s\n' "$PACKS_DIR/$name"
    elif [[ -n "$project_cco_dir" && -d "$project_cco_dir/packs/$name" ]]; then
        printf '%s\n' "$project_cco_dir/packs/$name"
    fi
}

# Remove stale files from a previous pack manifest (pre-ADR-14 legacy cleanup).
# Reads .pack-manifest, deletes listed files/dirs, then removes the manifest.
_clean_pack_manifest() {
    local project_dir="$1"
    local manifest
    manifest=$(_cco_project_pack_manifest "$project_dir")
    [[ ! -f "$manifest" ]] && return 0
    while IFS= read -r rel_path; do
        [[ -z "$rel_path" ]] && continue
        local full_path="$project_dir/.claude/${rel_path}"
        if [[ -f "$full_path" ]]; then
            rm -f "$full_path"
        elif [[ -d "$full_path" ]]; then
            rm -rf "$full_path"
        fi
    done < "$manifest"
    rm -f "$manifest"
}

# Detect name conflicts across packs (same filename in agents/rules, same dir in skills).
# Emits warnings for each conflict found.
_detect_pack_conflicts() {
    local pack_names="$1" project_cco_dir="${2:-}"
    local seen_agents_keys=() seen_agents_vals=()
    local seen_rules_keys=()  seen_rules_vals=()
    local seen_skills_keys=() seen_skills_vals=()
    while IFS= read -r pack_name; do
        [[ -z "$pack_name" ]] && continue
        local pack_root; pack_root=$(_pack_resolve_dir "$pack_name" "$project_cco_dir")
        [[ -z "$pack_root" ]] && continue
        local pack_yml="$pack_root/pack.yml"
        [[ ! -f "$pack_yml" ]] && continue
        local agents rules skills
        agents=$(yml_get_pack_agents "$pack_yml")
        rules=$(yml_get_pack_rules "$pack_yml")
        skills=$(yml_get_pack_skills "$pack_yml")
        local i owner
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            owner=""
            for ((i=0; i<${#seen_agents_keys[@]}; i++)); do
                [[ "${seen_agents_keys[$i]}" == "$f" ]] && { owner="${seen_agents_vals[$i]}"; break; }
            done
            [[ -n "$owner" ]] && warn "Agent '$f' defined in both pack '$owner' and '$pack_name' — '$pack_name' will overwrite"
            seen_agents_keys+=("$f"); seen_agents_vals+=("$pack_name")
        done <<< "$agents"
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            owner=""
            for ((i=0; i<${#seen_rules_keys[@]}; i++)); do
                [[ "${seen_rules_keys[$i]}" == "$f" ]] && { owner="${seen_rules_vals[$i]}"; break; }
            done
            [[ -n "$owner" ]] && warn "Rule '$f' defined in both pack '$owner' and '$pack_name' — '$pack_name' will overwrite"
            seen_rules_keys+=("$f"); seen_rules_vals+=("$pack_name")
        done <<< "$rules"
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            owner=""
            for ((i=0; i<${#seen_skills_keys[@]}; i++)); do
                [[ "${seen_skills_keys[$i]}" == "$f" ]] && { owner="${seen_skills_vals[$i]}"; break; }
            done
            [[ -n "$owner" ]] && warn "Skill '$f' defined in both pack '$owner' and '$pack_name' — '$pack_name' will overwrite"
            seen_skills_keys+=("$f"); seen_skills_vals+=("$pack_name")
        done <<< "$skills"
    done <<< "$pack_names"
}

# Detect cross-tree collisions between the committed project .claude/ config and
# the framework-reserved overlay tree (ADR-0005 F2). Pack and llms resources are
# overlaid read-only at /workspace/.claude/{packs,llms,rules,agents,skills}/...;
# a committed file at the same container path is shadowed (Docker applies the
# child :ro mount on top of the rw parent, so the overlay wins). This is
# detect-and-warn only — never a hard block (layered reachability, P14).
# Args: project_yml, pack_names, claude_dir (the committed project .claude tree —
# <repo>/.cco/claude in the decentralized layout, or the internal/tutorial .claude).
_detect_cross_tree_conflicts() {
    local project_yml="$1" pack_names="$2" claude_dir="$3" project_cco_dir="${4:-}"
    [[ ! -d "$claude_dir" ]] && return 0

    # Reserved namespaces: packs/ and llms/ are framework-owned subtrees (pack
    # knowledge dirs + llms docs mount here). Committed config must not author
    # into them — warn regardless of whether packs/llms are currently configured.
    local _ns
    for _ns in packs llms; do
        if [[ -d "$claude_dir/$_ns" ]] && [[ -n "$(ls -A "$claude_dir/$_ns" 2>/dev/null)" ]]; then
            warn "Committed .claude/$_ns/ is framework-reserved — its contents are shadowed by pack/llms :ro overlays."
        fi
    done

    # Per-file collisions in the shared rules/agents/skills trees. A user may
    # legitimately author there, so report the specific overlapping file.
    [[ -z "$pack_names" ]] && return 0
    local _pn _f
    while IFS= read -r _pn; do
        [[ -z "$_pn" ]] && continue
        local _proot; _proot=$(_pack_resolve_dir "$_pn" "$project_cco_dir")
        [[ -z "$_proot" ]] && continue
        local _pyml="$_proot/pack.yml"
        [[ ! -f "$_pyml" ]] && continue
        while IFS= read -r _f; do
            [[ -z "$_f" ]] && continue
            [[ -e "$claude_dir/rules/$_f" ]] && \
                warn "Committed .claude/rules/$_f collides with pack '$_pn' — the pack ':ro' overlay wins."
        done <<< "$(yml_get_pack_rules "$_pyml")"
        while IFS= read -r _f; do
            [[ -z "$_f" ]] && continue
            [[ -e "$claude_dir/agents/$_f" ]] && \
                warn "Committed .claude/agents/$_f collides with pack '$_pn' — the pack ':ro' overlay wins."
        done <<< "$(yml_get_pack_agents "$_pyml")"
        while IFS= read -r _f; do
            [[ -z "$_f" ]] && continue
            [[ -e "$claude_dir/skills/$_f" ]] && \
                warn "Committed .claude/skills/$_f collides with pack '$_pn' — the pack ':ro' overlay wins."
        done <<< "$(yml_get_pack_skills "$_pyml")"
    done <<< "$pack_names"
}

# Generate Docker volume mount lines for pack resources (ADR-14).
# Outputs compose-format volume lines to stdout for inclusion in docker-compose.yml.
# Called during compose generation in cmd_start.
_generate_pack_mounts() {
    local pack_names="$1" project_cco_dir="${2:-}"
    [[ -z "$pack_names" ]] && return 0

    echo "      # Pack resources (read-only mounts; three-layer resolution, ADR-0019 D5)"
    while IFS= read -r _pname; do
        [[ -z "$_pname" ]] && continue
        # Three-layer resolution: ~/.cco/packs → <repo>/.cco/packs cache.
        local _proot; _proot=$(_pack_resolve_dir "$_pname" "$project_cco_dir")
        if [[ -z "$_proot" ]]; then
            warn "Pack '$_pname' not resolved (not in ~/.cco/packs or <repo>/.cco/packs) — run 'cco resolve' or 'cco pack install <url>'."
            continue
        fi
        local _pyml="$_proot/pack.yml"
        [[ ! -f "$_pyml" ]] && continue
        if ! grep -qE '^(name|knowledge|llms|skills|agents|rules):' "$_pyml"; then
            warn "Pack '$_pname': pack.yml has no valid top-level keys — check for extra indentation."
            continue
        fi

        # Knowledge: mount knowledge dir → /workspace/.claude/packs/<name>
        local _k_files _k_source _k_dir
        _k_files=$(yml_get_pack_knowledge_files "$_pyml")
        if [[ -n "$_k_files" ]]; then
            _k_source=$(yml_get_pack_knowledge_source "$_pyml")
            _k_dir="${_k_source:-$_proot/knowledge}"
            _k_dir=$(expand_path "$_k_dir")
            [[ -d "$_k_dir" ]] && _compose_vol "${_k_dir}" "/workspace/.claude/packs/${_pname}" "ro"
        fi

        # Rules: individual file mounts (Claude Code reads flat *.md in rules/)
        local _rules
        _rules=$(yml_get_pack_rules "$_pyml")
        if [[ -n "$_rules" ]]; then
            while IFS= read -r _rf; do
                [[ -z "$_rf" ]] && continue
                local _rsrc="$_proot/rules/${_rf}"
                [[ -f "$_rsrc" ]] && _compose_vol "${_rsrc}" "/workspace/.claude/rules/${_rf}" "ro"
            done <<< "$_rules"
        fi

        # Agents: individual file mounts (Claude Code reads flat *.md in agents/)
        local _agents
        _agents=$(yml_get_pack_agents "$_pyml")
        if [[ -n "$_agents" ]]; then
            while IFS= read -r _af; do
                [[ -z "$_af" ]] && continue
                local _asrc="$_proot/agents/${_af}"
                [[ -f "$_asrc" ]] && _compose_vol "${_asrc}" "/workspace/.claude/agents/${_af}" "ro"
            done <<< "$_agents"
        fi

        # Skills: directory mounts (Claude Code expects skill dirs with SKILL.md)
        local _skills
        _skills=$(yml_get_pack_skills "$_pyml")
        if [[ -n "$_skills" ]]; then
            while IFS= read -r _sf; do
                [[ -z "$_sf" ]] && continue
                local _ssrc="$_proot/skills/${_sf}"
                [[ -d "$_ssrc" ]] && _compose_vol "${_ssrc}" "/workspace/.claude/skills/${_sf}" "ro"
            done <<< "$_skills"
        fi
    done <<< "$pack_names"
}

# Validate a single pack's structure and references. Returns 0 if valid, 1 if
# any error. Output is greppable (one "<name>: <reason>" line per finding + a
# "validate: N issue(s) [error=E warning=W]" summary, no inline symbols),
# matching `cco project validate` (ADR-0023 D2 / finding F1). A name/dir
# mismatch is a warning (non-fatal); everything else is an error. Quiet +
# "Pack '<name>' is valid" on success.
_validate_single_pack() {
    local name="$1"
    local pack_dir="$PACKS_DIR/$name"
    local pack_yml="$pack_dir/pack.yml"
    local -a errs=() warns=()

    # Structural early-outs (fatal) — still greppable + a summary line.
    if [[ ! -f "$pack_yml" ]]; then
        printf '%s: pack.yml not found\n' "$name"
        printf 'validate: 1 issue(s) [error=1 warning=0]\n'
        return 1
    fi
    if ! grep -qE '^(name|knowledge|llms|skills|agents|rules):' "$pack_yml"; then
        printf '%s: pack.yml has no valid top-level keys (check indentation)\n' "$name"
        printf 'validate: 1 issue(s) [error=1 warning=0]\n'
        return 1
    fi

    # Name matches directory (mismatch is a warning, not a failure).
    local yml_name
    yml_name=$(yml_get "$pack_yml" "name")
    if [[ -z "$yml_name" ]]; then
        errs+=("$name: 'name' field missing in pack.yml")
    elif [[ "$yml_name" != "$name" ]]; then
        warns+=("$name: YAML name '$yml_name' does not match directory name '$name'")
    fi

    # Knowledge source exists if specified
    local k_source
    k_source=$(yml_get_pack_knowledge_source "$pack_yml")
    if [[ -n "$k_source" ]]; then
        local expanded
        expanded=$(expand_path "$k_source")
        [[ ! -d "$expanded" ]] && errs+=("$name: knowledge source not found: $k_source")
    fi

    # Skills directories exist
    local skills
    skills=$(yml_get_pack_skills "$pack_yml")
    if [[ -n "$skills" ]]; then
        while IFS= read -r s; do
            [[ -z "$s" ]] && continue
            [[ ! -d "$pack_dir/skills/$s" ]] && errs+=("$name: skill directory not found: skills/$s")
        done <<< "$skills"
    fi

    # Agent files exist
    local agents
    agents=$(yml_get_pack_agents "$pack_yml")
    if [[ -n "$agents" ]]; then
        while IFS= read -r a; do
            [[ -z "$a" ]] && continue
            [[ ! -f "$pack_dir/agents/$a" ]] && errs+=("$name: agent file not found: agents/$a")
        done <<< "$agents"
    fi

    # Rule files exist
    local rules
    rules=$(yml_get_pack_rules "$pack_yml")
    if [[ -n "$rules" ]]; then
        while IFS= read -r r; do
            [[ -z "$r" ]] && continue
            [[ ! -f "$pack_dir/rules/$r" ]] && errs+=("$name: rule file not found: rules/$r")
        done <<< "$rules"
    fi

    # LLMs references — _validate_llms_refs prints greppable "<name>: ..." lines.
    local _llms_out
    _llms_out=$(_validate_llms_refs "$pack_yml" "$name")
    if [[ -n "$_llms_out" ]]; then
        while IFS= read -r _l; do [[ -n "$_l" ]] && errs+=("$_l"); done <<< "$_llms_out"
    fi

    local total=$(( ${#errs[@]} + ${#warns[@]} ))
    if [[ $total -gt 0 ]]; then
        local f
        for f in ${errs[@]+"${errs[@]}"};  do printf '%s\n' "$f"; done
        for f in ${warns[@]+"${warns[@]}"}; do printf '%s\n' "$f"; done
        printf 'validate: %d issue(s) [error=%d warning=%d]\n' "$total" "${#errs[@]}" "${#warns[@]}"
        [[ ${#errs[@]} -gt 0 ]] && return 1
        return 0
    fi
    ok "Pack '$name' is valid"
    return 0
}
