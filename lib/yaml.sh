#!/usr/bin/env bash
# lib/yaml.sh — Simple YAML parsers for project.yml and pack.yml
#
# Provides: yml_set(), yml_remove(), _parse_bool(),
#           yml_get(), yml_get_list(), yml_get_repos(),
#           yml_get_ports(), yml_get_env(), yml_get_extra_mounts(),
#           yml_get_packs(), yml_get_pack_knowledge_source(),
#           yml_get_pack_knowledge_files(), yml_get_pack_skills(),
#           yml_get_pack_agents(), yml_get_pack_rules()
# Dependencies: colors.sh (warn)
# Globals: none

# Set a top-level key: value in a YAML file.
# Updates the value if the key exists, appends if it doesn't.
# For nested keys (e.g., "remote_cache.commit"), creates the parent block if needed.
# Usage: yml_set <file> <key> <value>
yml_set() {
    local file="$1"
    local key="$2"
    local value="$3"

    if [[ "$key" == *.* ]]; then
        local parent="${key%%.*}"
        local child="${key#*.}"
        if grep -q "^${parent}:" "$file" 2>/dev/null; then
            # Parent exists — check if child exists under it
            if awk -v p="$parent" -v c="$child" '
                $0 ~ "^"p":" { in_block=1; next }
                in_block && /^[^ ]/ { exit 1 }
                in_block && $0 ~ "^  "c":" { found=1; exit 0 }
                END { exit (found ? 0 : 1) }
            ' "$file" 2>/dev/null; then
                # Child exists — update in place
                sed -i '' "s|^  ${child}: .*|  ${child}: ${value}|" "$file" 2>/dev/null || \
                    sed -i "s|^  ${child}: .*|  ${child}: ${value}|" "$file"
            else
                # Child doesn't exist — append under parent
                sed -i '' "/^${parent}:/a\\
  ${child}: ${value}" "$file" 2>/dev/null || \
                    sed -i "/^${parent}:/a\\  ${child}: ${value}" "$file"
            fi
        else
            # Parent doesn't exist — create block
            printf '%s:\n  %s: %s\n' "$parent" "$child" "$value" >> "$file"
        fi
    else
        # Top-level key
        if grep -q "^${key}:" "$file" 2>/dev/null; then
            sed -i '' "s|^${key}: .*|${key}: ${value}|" "$file" 2>/dev/null || \
                sed -i "s|^${key}: .*|${key}: ${value}|" "$file"
        else
            printf '%s: %s\n' "$key" "$value" >> "$file"
        fi
    fi
}

# Remove a top-level key (and its nested block if any) from a YAML file.
# Usage: yml_remove <file> <key>
yml_remove() {
    local file="$1"
    local key="$2"

    [[ ! -f "$file" ]] && return 0

    local tmpf
    tmpf=$(mktemp)
    awk -v key="$key" '
        $0 ~ "^"key":" { in_block=1; next }
        in_block && /^  / { next }
        in_block { in_block=0 }
        { print }
    ' "$file" > "$tmpf"
    mv "$tmpf" "$file"
}

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
            /^ *#/ { next }
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
            /^ *#/ { next }
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

# Read a value from a 3-level nested key (e.g., "docker.containers.policy")
# Usage: yml_get_deep <file> <key>
yml_get_deep() {
    local file="$1"
    local key="$2"

    # Split key: docker.containers.policy → docker / containers / policy
    local l1 l2 l3
    l1="${key%%.*}"
    local rest="${key#*.}"
    l2="${rest%%.*}"
    l3="${rest#*.}"

    awk -v l1="$l1" -v l2="$l2" -v l3="$l3" '
        /^ *#/ { next }
        $0 ~ "^"l1":" { in_l1=1; next }
        in_l1 && /^[^ ]/ { exit }
        in_l1 && $0 ~ "^  "l2":" { in_l2=1; next }
        in_l2 && /^  [^ ]/ && !/^    / { exit }
        in_l2 && /^[^ ]/ { exit }
        in_l2 && $0 ~ "^    "l3":" {
            sub(/^    [^:]+: */, "")
            gsub(/["\047]/, "")
            sub(/ *#.*$/, "")
            gsub(/^ +| +$/, "")
            print
            exit
        }
    ' "$file"
}

# Read a list from a 3-level nested key (e.g., "docker.containers.allow")
# Outputs one item per line
# Usage: yml_get_deep_list <file> <key>
yml_get_deep_list() {
    local file="$1"
    local key="$2"

    local l1 l2 l3
    l1="${key%%.*}"
    local rest="${key#*.}"
    l2="${rest%%.*}"
    l3="${rest#*.}"

    awk -v l1="$l1" -v l2="$l2" -v l3="$l3" '
        /^ *#/ { next }
        $0 ~ "^"l1":" { in_l1=1; next }
        in_l1 && /^[^ ]/ { exit }
        in_l1 && $0 ~ "^  "l2":" { in_l2=1; next }
        in_l2 && /^  [^ ]/ && !/^    / { exit }
        in_l2 && /^[^ ]/ { exit }
        in_l2 && $0 ~ "^    "l3":" { in_l3=1; next }
        in_l3 && /^    [^ ]/ && !/^      / { exit }
        in_l3 && /^  [^ ]/ && !/^    / { exit }
        in_l3 && /^[^ ]/ { exit }
        in_l3 && /^      - / {
            sub(/^      - */, "")
            gsub(/["\047]/, "")
            sub(/ *#.*$/, "")
            gsub(/^ +| +$/, "")
            if ($0 != "") print
        }
    ' "$file"
}

# Read a map from a 3-level nested key (e.g., "docker.containers.required_labels")
# Outputs lines of "key:value"
# Usage: yml_get_deep_map <file> <key>
yml_get_deep_map() {
    local file="$1"
    local key="$2"

    local l1 l2 l3
    l1="${key%%.*}"
    local rest="${key#*.}"
    l2="${rest%%.*}"
    l3="${rest#*.}"

    awk -v l1="$l1" -v l2="$l2" -v l3="$l3" '
        /^ *#/ { next }
        $0 ~ "^"l1":" { in_l1=1; next }
        in_l1 && /^[^ ]/ { exit }
        in_l1 && $0 ~ "^  "l2":" { in_l2=1; next }
        in_l2 && /^  [^ ]/ && !/^    / { exit }
        in_l2 && /^[^ ]/ { exit }
        in_l2 && $0 ~ "^    "l3":" { in_l3=1; next }
        in_l3 && /^    [^ ]/ && !/^      / { exit }
        in_l3 && /^  [^ ]/ && !/^    / { exit }
        in_l3 && /^[^ ]/ { exit }
        in_l3 && /^      [^ -]/ {
            sub(/^      /, "")
            sub(/ *#.*$/, "")
            gsub(/["\047]/, "")
            gsub(/^ +| +$/, "")
            # Convert "key: value" to "key:value"
            sub(/: +/, ":")
            if ($0 != "") print
        }
    ' "$file"
}

# Read a value from a 4-level nested key (e.g., "docker.security.resources.memory")
# Usage: yml_get_deep4 <file> <key>
yml_get_deep4() {
    local file="$1"
    local key="$2"

    local l1 l2 l3 l4
    l1="${key%%.*}"
    local rest="${key#*.}"
    l2="${rest%%.*}"
    rest="${rest#*.}"
    l3="${rest%%.*}"
    l4="${rest#*.}"

    awk -v l1="$l1" -v l2="$l2" -v l3="$l3" -v l4="$l4" '
        /^ *#/ { next }
        $0 ~ "^"l1":" { in_l1=1; next }
        in_l1 && /^[^ ]/ { exit }
        in_l1 && $0 ~ "^  "l2":" { in_l2=1; next }
        in_l2 && /^  [^ ]/ && !/^    / { exit }
        in_l2 && /^[^ ]/ { exit }
        in_l2 && $0 ~ "^    "l3":" { in_l3=1; next }
        in_l3 && /^    [^ ]/ && !/^      / { exit }
        in_l3 && /^  [^ ]/ && !/^    / { exit }
        in_l3 && /^[^ ]/ { exit }
        in_l3 && $0 ~ "^      "l4":" {
            sub(/^      [^:]+: */, "")
            gsub(/["\047]/, "")
            sub(/ *#.*$/, "")
            gsub(/^ +| +$/, "")
            print
            exit
        }
    ' "$file"
}

# Validate an enum field. Returns the value if valid, or the default with a warning.
# Usage: yml_validate_enum <value> <default> <valid1|valid2|valid3>
yml_validate_enum() {
    local value="$1" default="$2" valid_values="$3"
    [[ -z "$value" ]] && { echo "$default"; return; }

    if echo "$valid_values" | tr '|' '\n' | grep -qx "$value"; then
        echo "$value"
    else
        warn "Invalid value '$value' — using default '$default' (valid: $valid_values)"
        echo "$default"
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
