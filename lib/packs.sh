#!/usr/bin/env bash
# lib/packs.sh — Pack resource helpers (manifest, conflicts, copy, validate)
#
# Provides: _clean_pack_manifest(), _detect_pack_conflicts(),
#           _copy_pack_resources(), _validate_single_pack()
# Dependencies: colors.sh, utils.sh, yaml.sh
# Globals: GLOBAL_DIR

# Remove stale files from a previous pack manifest that are no longer needed.
# Reads .pack-manifest, deletes listed files, removes empty parent dirs.
_clean_pack_manifest() {
    local project_dir="$1"
    local manifest="$project_dir/.claude/.pack-manifest"
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
    local pack_names="$1"
    local seen_agents_keys=() seen_agents_vals=()
    local seen_rules_keys=()  seen_rules_vals=()
    local seen_skills_keys=() seen_skills_vals=()
    while IFS= read -r pack_name; do
        [[ -z "$pack_name" ]] && continue
        local pack_yml="$GLOBAL_DIR/packs/${pack_name}/pack.yml"
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

# Copy skills, agents, and rules from a pack into the project's .claude/ directory.
# Appends copied paths to the manifest file (4th argument).
# Called by cmd_start for each pack after compose generation.
_copy_pack_resources() {
    local pack_name="$1"
    local pack_yml="$2"
    local project_dir="$3"
    local manifest="$4"
    local pack_dir
    pack_dir="$(dirname "$pack_yml")"

    # Validate pack.yml structure: top-level keys must start at column 0
    if ! grep -qE '^(name|knowledge|skills|agents|rules):' "$pack_yml"; then
        warn "Pack '$pack_name': pack.yml has no valid top-level keys (name/knowledge/skills/agents/rules)."
        warn "  Check for extra indentation — all keys must start at column 0."
        return 0
    fi

    # Skills: each named subdirectory under pack/skills/ is a skill
    local skills
    skills=$(yml_get_pack_skills "$pack_yml")
    if [[ -n "$skills" ]]; then
        while IFS= read -r skill_name; do
            [[ -z "$skill_name" ]] && continue
            local skill_src="$pack_dir/skills/${skill_name}"
            if [[ -d "$skill_src" ]]; then
                mkdir -p "$project_dir/.claude/skills"
                cp -r "$skill_src" "$project_dir/.claude/skills/"
                echo "skills/${skill_name}" >> "$manifest"
            else
                warn "Pack '$pack_name' skill '$skill_name' not found at $skill_src — skipping"
            fi
        done <<< "$skills"
    fi

    # Agents: individual .md files under pack/agents/
    local agents
    agents=$(yml_get_pack_agents "$pack_yml")
    if [[ -n "$agents" ]]; then
        mkdir -p "$project_dir/.claude/agents"
        while IFS= read -r agent_file; do
            [[ -z "$agent_file" ]] && continue
            local src="$pack_dir/agents/${agent_file}"
            if [[ -f "$src" ]]; then
                cp "$src" "$project_dir/.claude/agents/"
                echo "agents/${agent_file}" >> "$manifest"
            else
                warn "Pack '$pack_name' agent '$agent_file' not found at $src — skipping"
            fi
        done <<< "$agents"
    fi

    # Rules: individual .md files under pack/rules/
    local rules
    rules=$(yml_get_pack_rules "$pack_yml")
    if [[ -n "$rules" ]]; then
        mkdir -p "$project_dir/.claude/rules"
        while IFS= read -r rule_file; do
            [[ -z "$rule_file" ]] && continue
            local src="$pack_dir/rules/${rule_file}"
            if [[ -f "$src" ]]; then
                cp "$src" "$project_dir/.claude/rules/"
                echo "rules/${rule_file}" >> "$manifest"
            else
                warn "Pack '$pack_name' rule '$rule_file' not found at $src — skipping"
            fi
        done <<< "$rules"
    fi

    # Knowledge: copy only the files listed in knowledge.files:
    local pack_files
    pack_files=$(yml_get_pack_knowledge_files "$pack_yml")
    if [[ -n "$pack_files" ]]; then
        local pack_source
        pack_source=$(yml_get_pack_knowledge_source "$pack_yml")
        [[ -z "$pack_source" ]] && pack_source="$pack_dir/knowledge"
        pack_source=$(expand_path "$pack_source")
        if [[ -d "$pack_source" ]]; then
            mkdir -p "$project_dir/.claude/packs/${pack_name}"
            local copied_any=0
            while IFS=$'\t' read -r fname _fdesc; do
                [[ -z "$fname" ]] && continue
                local src="$pack_source/$fname"
                local dst="$project_dir/.claude/packs/${pack_name}/$fname"
                if [[ -f "$src" ]]; then
                    mkdir -p "$(dirname "$dst")"
                    cp "$src" "$dst"
                    copied_any=1
                else
                    warn "Pack '$pack_name': knowledge file '$fname' not found in $pack_source"
                fi
            done <<< "$pack_files"
            # Track directory in manifest (like skills) for clean removal
            [[ $copied_any -eq 1 ]] && echo "packs/${pack_name}" >> "$manifest"
        else
            warn "Pack '$pack_name': knowledge source '$pack_source' not found"
        fi
    fi
}

# Validate a single pack's structure and references.
# Returns 0 if valid, 1 if errors found.
_validate_single_pack() {
    local name="$1"
    local pack_dir="$GLOBAL_DIR/packs/$name"
    local pack_yml="$pack_dir/pack.yml"
    local errors=0

    # pack.yml exists
    if [[ ! -f "$pack_yml" ]]; then
        error "Pack '$name': pack.yml not found"
        return 1
    fi

    # Valid top-level keys (reuse existing regex)
    if ! grep -qE '^(name|knowledge|skills|agents|rules):' "$pack_yml"; then
        error "Pack '$name': pack.yml has no valid top-level keys (check indentation)"
        return 1
    fi

    # Name matches directory
    local yml_name
    yml_name=$(yml_get "$pack_yml" "name")
    if [[ -z "$yml_name" ]]; then
        error "Pack '$name': 'name' field missing in pack.yml"
        ((errors++))
    elif [[ "$yml_name" != "$name" ]]; then
        warn "Pack '$name': YAML name '$yml_name' does not match directory name '$name'"
    fi

    # Knowledge source exists if specified
    local k_source
    k_source=$(yml_get_pack_knowledge_source "$pack_yml")
    if [[ -n "$k_source" ]]; then
        local expanded
        expanded=$(expand_path "$k_source")
        if [[ ! -d "$expanded" ]]; then
            error "Pack '$name': knowledge source not found: $k_source"
            ((errors++))
        fi
    fi

    # Skills directories exist
    local skills
    skills=$(yml_get_pack_skills "$pack_yml")
    if [[ -n "$skills" ]]; then
        while IFS= read -r s; do
            [[ -z "$s" ]] && continue
            if [[ ! -d "$pack_dir/skills/$s" ]]; then
                error "Pack '$name': skill directory not found: skills/$s"
                ((errors++))
            fi
        done <<< "$skills"
    fi

    # Agent files exist
    local agents
    agents=$(yml_get_pack_agents "$pack_yml")
    if [[ -n "$agents" ]]; then
        while IFS= read -r a; do
            [[ -z "$a" ]] && continue
            if [[ ! -f "$pack_dir/agents/$a" ]]; then
                error "Pack '$name': agent file not found: agents/$a"
                ((errors++))
            fi
        done <<< "$agents"
    fi

    # Rule files exist
    local rules
    rules=$(yml_get_pack_rules "$pack_yml")
    if [[ -n "$rules" ]]; then
        while IFS= read -r r; do
            [[ -z "$r" ]] && continue
            if [[ ! -f "$pack_dir/rules/$r" ]]; then
                error "Pack '$name': rule file not found: rules/$r"
                ((errors++))
            fi
        done <<< "$rules"
    fi

    if [[ $errors -gt 0 ]]; then
        return 1
    fi
    ok "Pack '$name' is valid"
    return 0
}
