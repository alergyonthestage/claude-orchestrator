#!/usr/bin/env bash
# lib/yaml.sh — Simple YAML parsers for project.yml and pack.yml
#
# Provides: _parse_bool(), yml_get(), yml_get_list(), yml_get_repos(),
#           yml_get_ports(), yml_get_env(), yml_get_extra_mounts(),
#           yml_get_packs(), yml_get_pack_knowledge_source(),
#           yml_get_pack_knowledge_files(), yml_get_pack_skills(),
#           yml_get_pack_agents(), yml_get_pack_rules()
# Dependencies: colors.sh (warn)
# Globals: none

# Parse a YAML boolean value into canonical "true" or "false".
# Trims whitespace, normalizes case, accepts YAML standard variants.
# Returns the safe_default when the value is empty or unrecognized.
# Usage: _parse_bool <value> <safe_default>
# Example: _parse_bool "  Yes " "true"  → prints "true"
_parse_bool() {
    local raw="$1"
    local safe_default="${2:-true}"

    # Trim leading/trailing whitespace
    local val
    val=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Empty → use safe default
    if [[ -z "$val" ]]; then
        echo "$safe_default"
        return
    fi

    # Normalize to lowercase (bash 3.2 compatible — no ${val,,})
    val=$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')

    case "$val" in
        true|yes|on|1)  echo "true" ;;
        false|no|off|0) echo "false" ;;
        *)
            warn "Invalid boolean value '${raw}' — defaulting to '${safe_default}'"
            echo "$safe_default"
            ;;
    esac
}

# Read a value from project.yml using a simple parser (no yq dependency)
# Usage: yml_get <file> <key>
# Supports simple top-level and nested keys like "auth.method"
yml_get() {
    local file="$1"
    local key="$2"

    if [[ "$key" == *.* ]]; then
        local parent="${key%%.*}"
        local child="${key#*.}"
        # Find lines under parent, get child value
        awk -v parent="$parent" -v child="$child" '
            $0 ~ "^"parent":" { in_block=1; next }
            in_block && /^[^ ]/ { in_block=0 }
            in_block && $0 ~ "^  "child":" {
                sub(/^  [^:]+: */, "")
                gsub(/["\047]/, "")
                sub(/ *#.*$/, "")
                gsub(/^ +| +$/, "")
                print
                exit
            }
        ' "$file"
    else
        awk -v key="$key" '
            $0 ~ "^"key":" {
                sub(/^[^:]+: */, "")
                gsub(/["\047]/, "")
                sub(/ *#.*$/, "")
                gsub(/^ +| +$/, "")
                print
                exit
            }
        ' "$file"
    fi
}

# Read a simple list under a nested key (e.g., "browser.mcp_args")
# Outputs one item per line (stripped of quotes)
# Usage: yml_get_list <file> <key>
yml_get_list() {
    local file="$1"
    local key="$2"

    if [[ "$key" != *.* ]]; then
        # Top-level list
        awk -v key="$key" '
            $0 ~ "^"key":" { in_list=1; next }
            in_list && /^[^ #]/ { exit }
            in_list && /^  - / {
                sub(/^  - */, "")
                gsub(/["\047]/, "")
                sub(/ *#.*$/, "")
                gsub(/^ +| +$/, "")
                if ($0 != "") print
            }
        ' "$file"
    else
        local parent="${key%%.*}"
        local child="${key#*.}"
        awk -v parent="$parent" -v child="$child" '
            $0 ~ "^"parent":" { in_block=1; next }
            in_block && /^[^ ]/ { exit }
            in_block && $0 ~ "^  "child":" { in_list=1; next }
            in_list && /^  [^ ]/ && !/^    / { exit }
            in_list && /^[^ ]/ { exit }
            in_list && /^    - / {
                sub(/^    - */, "")
                gsub(/["\047]/, "")
                sub(/ *#.*$/, "")
                gsub(/^ +| +$/, "")
                if ($0 != "") print
            }
        ' "$file"
    fi
}

# Parse repos from project.yml
# Outputs lines of "host_path:mount_name"
yml_get_repos() {
    local file="$1"
    awk '
        /^repos:/ { in_repos=1; next }
        in_repos && /^[^ #]/ { exit }
        in_repos && /^  - path:/ {
            sub(/^  - path: */, "")
            gsub(/["\047]/, "")
            sub(/ *#.*$/, "")
            gsub(/^ +| +$/, "")
            path=$0
        }
        in_repos && /^    name:/ {
            sub(/^    name: */, "")
            gsub(/["\047]/, "")
            sub(/ *#.*$/, "")
            gsub(/^ +| +$/, "")
            if (path != "" && $0 != "") print path":"$0
            path=""
        }
    ' "$file"
}

# Parse ports from project.yml
yml_get_ports() {
    local file="$1"
    awk '
        /^  ports:/ || /^docker:/ { next }
        /^    - "?[0-9]/ {
            sub(/^    - */, "")
            gsub(/["\047]/, "")
            sub(/ *#.*$/, "")
            gsub(/^ +| +$/, "")
            print
        }
    ' "$file" | head -20
}

# Parse env vars from project.yml
yml_get_env() {
    local file="$1"
    awk '
        /^  env:/ { in_env=1; next }
        in_env && /^  [^ ]/ { exit }
        in_env && /^[^ ]/ { exit }
        in_env && /^    [A-Z]/ {
            sub(/^    /, "")
            gsub(/["\047]/, "")
            sub(/ *#.*$/, "")
            gsub(/^ +| +$/, "")
            print
        }
    ' "$file"
}

# Parse extra_mounts from project.yml
# Output format: source:target[:ro] (one per line)
# The raw readonly value is output as a 4th colon-separated field for the caller
# to normalize via _parse_bool. Format: source:target:ro_raw
yml_get_extra_mounts() {
    local file="$1"

    # AWK extracts raw values; bash normalizes booleans via _parse_bool
    local raw_mounts
    raw_mounts=$(awk '
        function emit() {
            if (source != "" && target != "") {
                # Output raw: source:target:ro_raw (ro_raw may be empty)
                print source ":" target ":" ro
            }
        }
        /^extra_mounts:/ { in_mounts=1; next }
        in_mounts && /^[^ #]/ { emit(); done=1; exit }
        in_mounts && /^  - source:/ {
            emit()
            sub(/^  - source: */, "")
            gsub(/["\047]/, "")
            sub(/ *#.*$/, "")
            gsub(/^ +| +$/, "")
            source = $0
            target = ""
            ro = ""
        }
        in_mounts && /^    target:/ {
            sub(/^    target: */, "")
            gsub(/["\047]/, "")
            sub(/ *#.*$/, "")
            gsub(/^ +| +$/, "")
            target = $0
        }
        in_mounts && /^    readonly:/ {
            sub(/^    readonly: */, "")
            gsub(/["\047]/, "")
            sub(/ *#.*$/, "")
            gsub(/^ +| +$/, "")
            ro = $0
        }
        END { if (!done && in_mounts) emit() }
    ' "$file")

    # Normalize boolean values and produce final output
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local mount_source mount_target ro_raw
        # Split on colons: source:target:ro_raw
        # source may contain colons (unlikely but safe), so we split from the right
        ro_raw="${line##*:}"
        local without_ro="${line%:*}"
        mount_target="${without_ro##*:}"
        mount_source="${without_ro%:*}"

        # Secure default: readonly=true when field is omitted (empty ro_raw)
        local ro_val
        ro_val=$(_parse_bool "$ro_raw" "true")

        local suffix=""
        [[ "$ro_val" == "true" ]] && suffix=":ro"
        echo "${mount_source}:${mount_target}${suffix}"
    done <<< "$raw_mounts"
}

# Parse packs list from project.yml
# Outputs one pack name per line
yml_get_packs() {
    local file="$1"
    awk '
        /^packs:/ { in_packs=1; next }
        in_packs && /^[^ #]/ { exit }
        in_packs && /^  - / {
            sub(/^  - */, "")
            gsub(/["\047]/, "")
            sub(/ *#.*$/, "")
            gsub(/^ +| +$/, "")
            if ($0 != "") print
        }
    ' "$file"
}

# Get knowledge source path from a pack.yml (knowledge.source:)
yml_get_pack_knowledge_source() {
    local file="$1"
    awk '
        /^knowledge:/ { in_k=1; next }
        in_k && /^[^ #]/ { exit }
        in_k && /^  source:/ { sub(/^  source: */, ""); gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, ""); print; exit }
    ' "$file"
}

# Get knowledge files from a pack.yml (knowledge.files:)
# Outputs one entry per line as: "<filename>\t<description>"
# Supports both string entries ("    - file.md") and object entries
# ("    - path: file.md\n      description: ...").
yml_get_pack_knowledge_files() {
    local file="$1"
    awk '
        /^knowledge:/ { in_k=1; next }
        in_k && /^[^ #]/ { exit }
        in_k && /^  files:/ { in_f=1; next }
        in_f && /^[^ ]/ { exit }
        in_f && /^  [^ #]/ && !/^    / { exit }
        in_f && /^    - / {
            if (/^    - path:/) {
                if (path != "") print path "\t" desc
                sub(/^    - path: */, ""); gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, "")
                path=$0; desc=""
            } else {
                if (path != "") print path "\t" desc
                path=""; desc=""
                sub(/^    - */, ""); gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, "")
                if ($0 != "") print $0 "\t"
            }
        }
        in_f && /^      description:/ {
            sub(/^      description: */, ""); gsub(/["\047]/, ""); sub(/ *#.*$/, ""); desc=$0
        }
        END { if (path != "") print path "\t" desc }
    ' "$file"
}

# Get skills list from a pack.yml (skills:)
# Outputs one skill name per line
yml_get_pack_skills() {
    local file="$1"
    awk '
        /^skills:/ { in_s=1; next }
        in_s && /^[^ #]/ { exit }
        in_s && /^  - / {
            sub(/^  - */, ""); gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, "")
            if ($0 != "") print
        }
    ' "$file"
}

# Get agents list from a pack.yml (agents:)
# Outputs one agent filename per line
yml_get_pack_agents() {
    local file="$1"
    awk '
        /^agents:/ { in_a=1; next }
        in_a && /^[^ #]/ { exit }
        in_a && /^  - / {
            sub(/^  - */, ""); gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, "")
            if ($0 != "") print
        }
    ' "$file"
}

# Get rules list from a pack.yml (rules:)
# Outputs one rule filename per line
yml_get_pack_rules() {
    local file="$1"
    awk '
        /^rules:/ { in_r=1; next }
        in_r && /^[^ #]/ { exit }
        in_r && /^  - / {
            sub(/^  - */, ""); gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, "")
            if ($0 != "") print
        }
    ' "$file"
}
