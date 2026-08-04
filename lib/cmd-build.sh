#!/usr/bin/env bash
# lib/cmd-build.sh — Build Docker image command
#
# Provides: cmd_build(), _cco_build_ref()
# Dependencies: colors.sh, utils.sh, paths.sh (_cco_config_dir,
#               _cco_claude_install_dir, _cco_claude_version_pref),
#               secrets.sh (_secret_match_content)
# Globals: IMAGE_NAME, REPO_ROOT
# Note: global setup scripts / MCP list live at the personal-store TOP LEVEL
# (~/.cco, design §2.3), written there by `cco init` / `cco init --migrate`,
# alongside the global `.claude/` (flat, ADR-0028 — no `global/` wrapper).

# Build provenance: the source ref this image is built from, as `<branch>@<shortsha>`
# (V1-F3 ≡ V5-8). It is baked to /opt/cco/BUILD so a session can answer "which code is
# this image running?" without trusting the launcher's memory — the e2e §4 template
# has that field precisely BECAUSE v2's cycle-0 was built from the wrong branch and
# the round's results had to be discarded. `.git/` is excluded from the build context,
# so the value is computed here on the host and passed as a build arg.
#
# FAIL-SAFE, never fail-closed: provenance is diagnostic, so anything unknowable —
# no git, no repo (an npm install or a tarball), a detached HEAD — degrades to a
# legible marker rather than breaking the build. A wrong-looking marker is a prompt to
# look; a failed build over a diagnostic field would be a defect of its own.
# Usage: _cco_build_ref [<dir>]   (defaults to $REPO_ROOT)
_cco_build_ref() {
    local dir="${1:-$REPO_ROOT}" branch sha
    command -v git >/dev/null 2>&1 || { printf 'unknown'; return 0; }
    git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || { printf 'unknown'; return 0; }
    branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""
    sha=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null) || sha=""
    [[ -n "$sha" ]] || { printf 'unknown'; return 0; }
    # Detached HEAD reports the literal "HEAD" as the branch — say so explicitly
    # rather than baking a name that looks like a branch but is not one.
    [[ -z "$branch" || "$branch" == "HEAD" ]] && branch="detached"
    printf '%s@%s' "$branch" "$sha"
}

cmd_build() {
    local no_cache=""
    local mcp_packages=""
    local cc_version=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-cache) no_cache="--no-cache"; shift ;;
            --mcp-packages) mcp_packages="$2"; shift 2 ;;
            --claude-version) cc_version="$2"; shift 2 ;;
            --help|-h)
                cat <<'EOF'
Usage: cco build [--no-cache] [--mcp-packages "pkg1 pkg2"] [--claude-version "x.y.z"]

Options:
  --no-cache               Rebuild without Docker cache AND reset the Claude Code
                           install cache (next `cco start` does a fresh install)
  --mcp-packages "pkgs"    Pre-install MCP server npm packages in the image
                           Also reads from ~/.cco/mcp-packages.txt if it exists
  --claude-version "x.y.z" One-off override of the Claude Code channel/version for
                           this build (latest|stable|x.y.z). The persistent
                           preference is the ~/.cco/claude-version config knob
                           (default: latest); Claude Code is installed at first
                           `cco start` and auto-updates in place.
EOF
                return 0
                ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    # Global setup scripts / MCP list live at the personal-store top level
    # (~/.cco, design §2.3) — written there by init/migrate; readers must match.
    local cfg_dir; cfg_dir="$(_cco_config_dir)"

    # Auto-load MCP packages from ~/.cco/mcp-packages.txt
    local mcp_file="$cfg_dir/mcp-packages.txt"
    if [[ -z "$mcp_packages" && -f "$mcp_file" ]]; then
        mcp_packages=$(grep -v '^\s*#' "$mcp_file" | grep -v '^\s*$' | tr '\n' ' ')
        mcp_packages="${mcp_packages% }"  # trim trailing space
    fi

    # On --no-cache, reset the Claude Code native-install cache (ADR-0039,
    # decision 4) so the next `cco start` performs a clean install. The binary is
    # no longer baked into the image — it lives in this CACHE dir, bind-mounted
    # into the container — so a pure image rebuild would otherwise reuse the old
    # install. `cco clean` never touches this dir (CACHE is out of its scope).
    if [[ -n "$no_cache" ]]; then
        local install_dir; install_dir="$(_cco_claude_install_dir)"
        if [[ -d "$install_dir" ]]; then
            # Empty the install CONTENTS but PRESERVE the bin/ and share/ directory
            # NODES: they are Docker Desktop bind-mount sources, and `rm -rf`-ing
            # them triggers a macOS VirtioFS/gRPC-FUSE stale-share bug — the daemon
            # caches a negative entry, so the next `cco start` fails with "mount
            # source path …: no such file or directory" even though cco re-creates
            # the dir host-side before the mount. The entrypoint reinstalls whenever
            # the binary (~/.local/bin/claude) is absent (ADR-0039), so clearing the
            # contents is enough to force a clean install without losing the shared
            # directory nodes.
            find "$install_dir" -mindepth 1 -maxdepth 1 ! -name bin ! -name share \
                -exec rm -rf {} + 2>/dev/null || true
            find "$install_dir/bin" "$install_dir/share" -mindepth 1 -delete 2>/dev/null || true
            mkdir -p "$install_dir/bin" "$install_dir/share"
            info "Reset Claude Code install cache (fresh install on next start)"
        fi
    fi

    check_docker
    info "Building Docker image '$IMAGE_NAME'..."

    # Bake the Claude Code channel/version default into the image. Precedence:
    # the one-off --claude-version flag, else the ~/.cco/claude-version config
    # knob (default `latest`). `cco start` re-forwards the knob when set; the
    # baked value is the fallback for a knob-less install (ADR-0039 decision 1).
    local build_args=()

    # Build provenance (V1-F3 ≡ V5-8). `.git/` is excluded from the build context
    # (.dockerignore), so the Dockerfile cannot derive this — it must be passed in.
    build_args+=(--build-arg "CCO_BUILD_REF=$(_cco_build_ref)")

    if [[ -n "$cc_version" ]]; then
        build_args+=(--build-arg "CLAUDE_CODE_VERSION=$cc_version")
        info "Pinning Claude Code channel/version (this build): $cc_version"
    else
        local cc_pref; cc_pref="$(_cco_claude_version_pref)"
        build_args+=(--build-arg "CLAUDE_CODE_VERSION=$cc_pref")
        [[ "$cc_pref" != "latest" ]] && info "Claude Code channel/version (config knob): $cc_pref"
    fi
    if [[ -n "$mcp_packages" ]]; then
        build_args+=(--build-arg "MCP_PACKAGES=$mcp_packages")
        info "Pre-installing MCP packages: $mcp_packages"
    fi

    # Include global build-time setup script if present
    local setup_build_file=""
    if [[ -f "$cfg_dir/setup-build.sh" ]]; then
        setup_build_file="$cfg_dir/setup-build.sh"
    elif [[ -f "$cfg_dir/setup.sh" ]]; then
        # Backward compatibility: pre-migration users may still have only setup.sh
        # Check if it contains actual commands (not just comments/blanks)
        if grep -qvE '^\s*$|^\s*#' "$cfg_dir/setup.sh" 2>/dev/null; then
            warn "~/.cco/setup.sh has content but setup-build.sh does not exist."
            warn "Since v2, setup.sh runs at start time (runtime). Build-time commands belong in setup-build.sh."
            warn "Run 'cco update' to migrate, or rename setup.sh → setup-build.sh manually."
            # Use it as build script for backward compat
            setup_build_file="$cfg_dir/setup.sh"
        fi
    fi
    if [[ -n "$setup_build_file" ]]; then
        local setup_content
        setup_content=$(cat "$setup_build_file")
        if [[ -n "$setup_content" ]]; then
            # Warn if script appears to contain secrets (build args are visible in
            # docker history). Use the canonical content matcher (lib/secrets.sh) so
            # this gate never drifts from vault-save / project-export (#10).
            if _secret_match_content "$setup_build_file" >/dev/null 2>&1; then
                warn "$(basename "$setup_build_file") may contain secrets (matched a known secret pattern)."
                warn "Build args are visible in 'docker history'. Move secrets to secrets.env instead."
            fi
            build_args+=(--build-arg "SETUP_BUILD_SCRIPT_CONTENT=$setup_content")
            info "Including $(basename "$setup_build_file") in build"
        fi
    fi

    docker build $no_cache "${build_args[@]+"${build_args[@]}"}" -t "$IMAGE_NAME" "$REPO_ROOT"
    ok "Image built successfully."
}
