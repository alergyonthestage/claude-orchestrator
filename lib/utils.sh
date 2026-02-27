#!/usr/bin/env bash
# lib/utils.sh — General utility functions
#
# Provides: expand_path(), check_docker(), check_image(), check_global()
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
