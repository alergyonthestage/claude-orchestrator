#!/usr/bin/env bash
# lib/utils.sh — General utility functions
#
# Provides: expand_path(), check_docker(), check_image(), check_global(),
#           _check_reserved_project_name(), _sed_i(), _sed_i_or_append(),
#           _substitute()
# Dependencies: colors.sh
# Globals: IMAGE_NAME, GLOBAL_DIR

# Expand ~ in paths
expand_path() {
    local path="$1"
    if [[ "$path" == ~* ]]; then
        path="${HOME}${path#\~}"
    fi
    echo "$path"
}

# Check Docker is running
check_docker() {
    if ! docker info >/dev/null 2>&1; then
        die "Docker daemon is not running. Start Docker Desktop."
    fi
}

# Check image exists
check_image() {
    if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        die "Docker image '$IMAGE_NAME' not found. Run 'cco build' first."
    fi
}

# Check global config exists (created by cco init)
check_global() {
    if [[ ! -d "$GLOBAL_DIR/.claude" ]]; then
        die "Global config not found. Run 'cco init' first."
    fi
}

# Reserved project names (used as keywords by CLI commands)
RESERVED_PROJECT_NAMES=("global" "all" "tutorial")

# Check if a project name is reserved
_check_reserved_project_name() {
    local name="$1"
    local reserved
    for reserved in "${RESERVED_PROJECT_NAMES[@]}"; do
        if [[ "$name" == "$reserved" ]]; then
            die "Project name '$name' is reserved. Choose a different name."
        fi
    done
}

# ── Portable sed -i ──────────────────────────────────────────────────
# macOS sed requires -i '' while GNU sed requires -i without argument.

# Replace all occurrences of a pattern in a file.
# Usage: _sed_i <file> <pattern> <replacement> [delimiter]
_sed_i() {
    local file="$1" pattern="$2" replacement="$3" delim="${4:-|}"
    sed -i '' "s${delim}${pattern}${delim}${replacement}${delim}g" "$file" 2>/dev/null || \
        sed -i "s${delim}${pattern}${delim}${replacement}${delim}g" "$file"
}

# Replace a key: value field in-place, or append it if missing.
# Usage: _sed_i_or_append <file> <key> <value>
_sed_i_or_append() {
    local file="$1" key="$2" value="$3"
    if grep -q "^${key}:" "$file" 2>/dev/null; then
        _sed_i "$file" "^${key}:.*" "${key}: ${value}"
    else
        printf '%s: %s\n' "$key" "$value" >> "$file"
    fi
}

# Replace a {{PLACEHOLDER}} in a file with a value.
# Uses awk to avoid delimiter conflicts (values may contain / or |).
# Usage: _substitute <file> <placeholder> <value>
_substitute() {
    local file="$1" placeholder="$2" value="$3"
    local token="{{${placeholder}}}"
    awk -v tok="$token" -v val="$value" '{gsub(tok, val); print}' "$file" > "$file.tmp" \
        && mv "$file.tmp" "$file"
}

# Run arbitrary sed expression(s) portably (macOS + GNU).
# Usage: _sed_i_raw <file> <sed_args...>
_sed_i_raw() {
    local file="$1"; shift
    sed -i '' "$@" "$file" 2>/dev/null || \
        sed -i "$@" "$file"
}
