#!/usr/bin/env bash
# lib/yaml.sh — Simple YAML parsers for project.yml and pack.yml
#
# Provides: yml_set(), yml_remove(), _parse_bool(),
#           yml_get(), yml_get_list(),
#           yml_get_ports(), yml_get_env(),
#           yml_get_packs(), yml_get_pack_knowledge_source(),
#           yml_get_pack_knowledge_files(), yml_get_pack_skills(),
#           yml_get_pack_agents(), yml_get_pack_rules(),
#           yml_get_llms(), yml_get_llms_names()
#   Coordinate (decentralized-config) parsers — final schema, ADR-0016 D2 /
#   ADR-0019 / ADR-0023 D5: yml_get_repo_coords() (name url ref),
#   yml_get_mount_coords() (name url ref target readonly),
#   yml_get_pack_coords() (name url ref resource). yml_get_llms() now also
#   emits url (name desc variant url).
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
            # Parent exists — use awk to update/append ONLY under the correct parent
            local tmpf
            tmpf=$(mktemp)
            awk -v p="$parent" -v c="$child" -v v="$value" '
                $0 ~ "^"p":" { in_block=1; print; next }
                in_block && /^[^ ]/ {
                    # Leaving parent block — if child not found, insert before this line
                    if (!found) { print "  " c ": " v; found=1 }
                    in_block=0; print; next
                }
                in_block && $0 ~ "^  "c":" {
                    # Found child under correct parent — replace
                    print "  " c ": " v; found=1; next
                }
                { print }
                END {
                    # If still in block at EOF and child not found, append
                    if (in_block && !found) print "  " c ": " v
                }
            ' "$file" > "$tmpf"
            mv "$tmpf" "$file"
        else
            # Parent doesn't exist — create block
            printf '%s:\n  %s: %s\n' "$parent" "$child" "$value" >> "$file"
        fi
    else
        # Top-level key
        if grep -q "^${key}:" "$file" 2>/dev/null; then
            local tmpf
            tmpf=$(mktemp)
            awk -v k="$key" -v v="$value" '
                $0 ~ "^"k":" { print k ": " v; next }
                { print }
            ' "$file" > "$tmpf"
            mv "$tmpf" "$file"
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

# ── Generic YAML query engine ────────────────────────────────────────
# Navigates to a dot-separated key path (1-4 levels deep) and extracts
# a scalar value, list items, or map entries.
#
# Usage: _yml_query <file> <key_path> [mode]
#   mode: "scalar" (default) | "list" | "map"
#
# Examples:
#   _yml_query f "name"                              → depth 1 scalar
#   _yml_query f "auth.method"                       → depth 2 scalar
#   _yml_query f "docker.containers.policy"          → depth 3 scalar
#   _yml_query f "docker.containers.allow" list      → depth 3 list
#   _yml_query f "docker.containers.required_labels" map → depth 3 map
#   _yml_query f "docker.security.resources.memory"  → depth 4 scalar
_yml_query() {
    local file="$1" key_path="$2" mode="${3:-scalar}" depth="${4:-0}"

    # Split key path. Use progressive peeling (%%.*/#*.) to preserve
    # dots inside child keys (e.g., "policies.CLAUDE.md" → parent=policies, child=CLAUDE.md).
    local k1="" k2="" k3="" k4=""
    if [[ "$key_path" != *.* ]]; then
        k1="$key_path"
        [[ "$depth" == "0" ]] && depth=1
    else
        k1="${key_path%%.*}"
        local rest="${key_path#*.}"
        if [[ "$depth" == "0" ]]; then
            # Auto-detect: default to depth 2 (parent.child).
            # Callers needing depth 3+ pass it explicitly via wrappers.
            depth=2
        fi
        if [[ "$depth" -le 2 ]]; then
            # Depth 2: child keeps any internal dots (e.g., "CLAUDE.md")
            k2="$rest"
        elif [[ "$depth" -le 3 ]]; then
            # Depth 3: split rest into 2 parts
            k2="${rest%%.*}"
            k3="${rest#*.}"
        else
            # Depth 4: split rest into 3 parts
            k2="${rest%%.*}"
            rest="${rest#*.}"
            k3="${rest%%.*}"
            k4="${rest#*.}"
        fi
    fi

    awk -v k1="$k1" -v k2="$k2" -v k3="$k3" -v k4="$k4" \
        -v depth="$depth" -v mode="$mode" '
    function clean(s) {
        gsub(/["\047]/, "", s)
        sub(/ *#.*$/, "", s)
        gsub(/^ +| +$/, "", s)
        return s
    }
    /^ *#/ { next }

    # Level 1: match top-level key
    !at1 && $0 ~ "^"k1":" {
        at1 = 1
        if (depth == 1) {
            if (mode == "scalar") { sub(/^[^:]+: */, ""); print clean($0); exit }
            at_leaf = 1; li = 2; next
        }
        next
    }

    # Level 2: match 2-space indented key under level 1
    at1 && !at2 {
        if (/^[^ ]/) exit
        if (depth >= 2 && $0 ~ "^  "k2":") {
            at2 = 1
            if (depth == 2) {
                if (mode == "scalar") { sub(/^  [^:]+: */, ""); print clean($0); exit }
                at_leaf = 1; li = 4; next
            }
            next
        }
    }

    # Level 3: match 4-space indented key under level 2
    at2 && !at3 {
        if (/^  [^ ]/ && !/^    /) exit
        if (/^[^ ]/) exit
        if (depth >= 3 && $0 ~ "^    "k3":") {
            at3 = 1
            if (depth == 3) {
                if (mode == "scalar") { sub(/^    [^:]+: */, ""); print clean($0); exit }
                at_leaf = 1; li = 6; next
            }
            next
        }
    }

    # Level 4: match 6-space indented key under level 3
    at3 && !at_leaf {
        if (/^    [^ ]/ && !/^      /) exit
        if (/^  [^ ]/ && !/^    /) exit
        if (/^[^ ]/) exit
        if (depth >= 4 && $0 ~ "^      "k4":") {
            if (mode == "scalar") { sub(/^      [^:]+: */, ""); print clean($0); exit }
            at_leaf = 1; li = 8; next
        }
    }

    # Leaf extraction: collect list items or map entries at leaf indent (li)
    at_leaf {
        match($0, /^ */)
        if (RLENGTH < li && $0 !~ /^ *$/) exit

        if (mode == "list") {
            p = "^"; for (i = 0; i < li; i++) p = p " "; p = p "- "
            if ($0 ~ p) { sub(p, ""); s = clean($0); if (s != "") print s }
        }
        if (mode == "map") {
            p = "^"; for (i = 0; i < li; i++) p = p " "
            if ($0 ~ (p "[^ -]")) {
                sub(p, ""); sub(/ *#.*$/, ""); gsub(/["\047]/, "")
                gsub(/^ +| +$/, ""); sub(/: +/, ":")
                if ($0 != "") print
            }
        }
    }
    ' "$file"
}

# ── Public getter API (thin wrappers over _yml_query) ────────────────
# yml_get/yml_get_list auto-detect depth (default 2 for dotted keys,
# preserving dots in the child part — e.g., "policies.CLAUDE.md").
# yml_get_deep* pass explicit depth 3 or 4 to split further.

# Read a scalar value (depth 1-2, auto-detected).
# Dotted child keys preserved: yml_get f "policies.CLAUDE.md" works.
yml_get() { _yml_query "$1" "$2" scalar; }

# Read a list (depth 1-2, auto-detected).
yml_get_list() { _yml_query "$1" "$2" list; }

# Read a scalar from a 3-level key (e.g., "docker.containers.policy").
yml_get_deep() { _yml_query "$1" "$2" scalar 3; }

# Read a list from a 3-level key (e.g., "docker.containers.allow").
yml_get_deep_list() { _yml_query "$1" "$2" list 3; }

# Read a map from a 3-level key (e.g., "docker.containers.required_labels").
yml_get_deep_map() { _yml_query "$1" "$2" map 3; }

# Read a scalar from a 4-level key (e.g., "docker.security.resources.memory").
yml_get_deep4() { _yml_query "$1" "$2" scalar 4; }

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

# Parse repo coordinates from the final project.yml schema (ADR-0016 D2 /
# ADR-0017 D1). Each repo is name + OPTIONAL url + OPTIONAL ref; the absolute
# path is NOT here (it lives in the machine-local index, §3). Outputs one entry
# per line as: "<name>\t<url>\t<ref>".
yml_get_repo_coords() {
    local file="$1"
    awk '
        /^repos:/ { in_r=1; next }
        in_r && /^[^ #]/ { exit }
        in_r && /^  - / {
            if (name != "") print name "\t" url "\t" ref
            name=""; url=""; ref=""
            if (/^  - name:/) { sub(/^  - name: */, "") } else { sub(/^  - */, "") }
            gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, ""); name=$0
            next
        }
        in_r && /^    url:/ { sub(/^    url: */, ""); gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, ""); url=$0 }
        in_r && /^    ref:/ { sub(/^    ref: */, ""); gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, ""); ref=$0 }
        END { if (name != "") print name "\t" url "\t" ref }
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

# Parse extra_mount coordinates from the final project.yml schema (ADR-0023 D5).
# Each mount is name + OPTIONAL url + OPTIONAL ref + OPTIONAL target + OPTIONAL
# readonly; the host source path is NOT here (it lives in the machine-local
# index, §3). Outputs one entry per line as:
#   "<name>\t<url>\t<ref>\t<target>\t<readonly_raw>"
# readonly is emitted RAW (empty if absent) — the caller normalizes the default
# (true) via _parse_bool.
yml_get_mount_coords() {
    local file="$1"
    awk '
        /^extra_mounts:/ { in_m=1; next }
        in_m && /^[^ #]/ { exit }
        in_m && /^  - / {
            if (name != "") print name "\t" url "\t" ref "\t" target "\t" ro "\t" policy
            name=""; url=""; ref=""; target=""; ro=""; policy=""
            if (/^  - name:/) { sub(/^  - name: */, "") } else { sub(/^  - */, "") }
            gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, ""); name=$0
            next
        }
        in_m && /^    url:/      { sub(/^    url: */, "");      gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, ""); url=$0 }
        in_m && /^    ref:/      { sub(/^    ref: */, "");      gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, ""); ref=$0 }
        in_m && /^    target:/   { sub(/^    target: */, "");   gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, ""); target=$0 }
        in_m && /^    readonly:/ { sub(/^    readonly: */, ""); gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, ""); ro=$0 }
        in_m && /^    config_access_policy:/ { sub(/^    config_access_policy: */, ""); gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, ""); policy=$0 }
        END { if (name != "") print name "\t" url "\t" ref "\t" target "\t" ro "\t" policy }
    ' "$file"
}

# Parse packs list from project.yml
# Outputs one pack name per line. Handles BOTH the legacy string list
# ("  - packname") and the final coordinate map ("  - name: packname" with
# url/ref/resource sub-keys; ADR-0019). Sub-keys (4-space) are ignored here —
# use yml_get_pack_coords() for the full coordinate.
yml_get_packs() {
    local file="$1"
    awk '
        /^packs:/ { in_packs=1; next }
        in_packs && /^[^ #]/ { exit }
        in_packs && /^  - name:/ {
            sub(/^  - name: */, "")
            gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, "")
            if ($0 != "") print
            next
        }
        in_packs && /^  - / {
            sub(/^  - */, "")
            gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, "")
            if ($0 != "") print
        }
    ' "$file"
}

# Parse pack coordinates (final schema, ADR-0019 / ADR-0022 D4).
# Outputs one entry per line as: "<name>\t<url>\t<ref>\t<resource>".
# A bare string entry ("  - packname") yields the name with empty coordinates
# (a project-local AUTHORED pack — url absent = it IS the source, P15).
yml_get_pack_coords() {
    local file="$1"
    awk '
        /^packs:/ { in_p=1; next }
        in_p && /^[^ #]/ { exit }
        in_p && /^  - / {
            if (name != "") print name "\t" url "\t" ref "\t" resource
            name=""; url=""; ref=""; resource=""
            if (/^  - name:/) { sub(/^  - name: */, "") } else { sub(/^  - */, "") }
            gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, ""); name=$0
            next
        }
        in_p && /^    url:/      { sub(/^    url: */, "");      gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, ""); url=$0 }
        in_p && /^    ref:/      { sub(/^    ref: */, "");      gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, ""); ref=$0 }
        in_p && /^    resource:/ { sub(/^    resource: */, ""); gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, ""); resource=$0 }
        END { if (name != "") print name "\t" url "\t" ref "\t" resource }
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

# Parse llms list from project.yml or pack.yml (llms:)
# Outputs one entry per line as: "<name>\t<description>\t<variant>\t<url>"
# (url added for the final coordinate schema — llms url is MANDATORY in
# project.yml, ADR-0017 D1; empty for short form / pack legacy entries).
# Supports short form ("- svelte") and long form ("- name: svelte").
yml_get_llms() {
    local file="$1"
    awk '
        /^llms:/ { in_l=1; next }
        in_l && /^[^ #]/ { exit }
        in_l && /^  - / {
            if (/^  - name:/) {
                if (name != "") print name "\t" desc "\t" variant "\t" url
                sub(/^  - name: */, ""); gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, "")
                name=$0; desc=""; variant=""; url=""
            } else {
                if (name != "") print name "\t" desc "\t" variant "\t" url
                name=""; desc=""; variant=""; url=""
                sub(/^  - */, ""); gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, "")
                if ($0 != "") print $0 "\t\t\t"
            }
        }
        in_l && /^    description:/ {
            sub(/^    description: */, ""); gsub(/["\047]/, ""); sub(/ *#.*$/, ""); desc=$0
        }
        in_l && /^    variant:/ {
            sub(/^    variant: */, ""); gsub(/["\047]/, ""); sub(/ *#.*$/, ""); variant=$0
        }
        in_l && /^    url:/ {
            sub(/^    url: */, ""); gsub(/["\047]/, ""); sub(/ *#.*$/, ""); gsub(/^ +| +$/, ""); url=$0
        }
        END { if (name != "") print name "\t" desc "\t" variant "\t" url }
    ' "$file"
}

# Parse llms names only from project.yml or pack.yml (llms:)
# Outputs one name per line (for deduplication and validation).
yml_get_llms_names() {
    local file="$1"
    yml_get_llms "$file" | awk -F'\t' '{ if ($1 != "") print $1 }'
}
