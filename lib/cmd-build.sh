#!/usr/bin/env bash
# lib/cmd-build.sh — Build Docker image command
#
# Provides: cmd_build()
# Dependencies: colors.sh, utils.sh
# Globals: GLOBAL_DIR, IMAGE_NAME, REPO_ROOT

cmd_build() {
    local no_cache=""
    local mcp_packages=""
    local cc_version=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-cache) no_cache="--no-cache"; shift ;;
            --mcp-packages) mcp_packages="$2"; shift 2 ;;
            --claude-version) cc_version="$2"; shift 2 ;;
            --help)
                cat <<'EOF'
Usage: cco build [--no-cache] [--mcp-packages "pkg1 pkg2"] [--claude-version "x.y.z"]

Options:
  --no-cache               Rebuild without Docker cache
  --mcp-packages "pkgs"    Pre-install MCP server npm packages in the image
                           Also reads from global/mcp-packages.txt if it exists
  --claude-version "x.y.z" Pin Claude Code to a specific version (default: latest)
EOF
                return 0
                ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    # Auto-load MCP packages from global/mcp-packages.txt
    local mcp_file="$GLOBAL_DIR/mcp-packages.txt"
    if [[ -z "$mcp_packages" && -f "$mcp_file" ]]; then
        mcp_packages=$(grep -v '^\s*#' "$mcp_file" | grep -v '^\s*$' | tr '\n' ' ')
        mcp_packages="${mcp_packages% }"  # trim trailing space
    fi

    check_docker
    info "Building Docker image '$IMAGE_NAME'..."

    local build_args=()
    if [[ -n "$cc_version" ]]; then
        build_args+=(--build-arg "CLAUDE_CODE_VERSION=$cc_version")
        info "Pinning Claude Code version: $cc_version"
    fi
    if [[ -n "$mcp_packages" ]]; then
        build_args+=(--build-arg "MCP_PACKAGES=$mcp_packages")
        info "Pre-installing MCP packages: $mcp_packages"
    fi

    # Include global setup script if present
    if [[ -f "$GLOBAL_DIR/setup.sh" ]]; then
        local setup_content
        setup_content=$(cat "$GLOBAL_DIR/setup.sh")
        if [[ -n "$setup_content" ]]; then
            build_args+=(--build-arg "SETUP_SCRIPT_CONTENT=$setup_content")
            info "Including global/setup.sh in build"
        fi
    fi

    docker build $no_cache "${build_args[@]+"${build_args[@]}"}" -t "$IMAGE_NAME" "$REPO_ROOT"
    ok "Image built successfully."
}
