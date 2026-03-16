#!/usr/bin/env bash
# lib/utils.sh — General utility functions
#
# Provides: expand_path(), check_docker(), check_image(), check_global(),
#           _check_reserved_project_name()
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
RESERVED_PROJECT_NAMES=("global" "all")

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
