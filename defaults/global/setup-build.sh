#!/bin/bash
# Global build-time setup — executed once during `cco build` as root.
#
# USE FOR:
#   - apt-get install (system packages, compilers, CLI tools)
#   - Downloading and installing binary tools (terraform, kubectl, etc.)
#   - Heavy dependencies that would slow down every `cco start`
#
# DO NOT USE FOR:
#   - Dotfiles, tmux keybindings, shell aliases, git config
#   - User-level settings that should apply at runtime
#   → Use setup.sh instead (runs at every `cco start`)
#
# Changes require `cco build` to take effect.
# See: docs/user-guides/advanced/custom-environment.md
#
# Example:
# Install tree command
#   apt-get update \
#     && apt-get install -y --no-install-recommends tree \
#     && rm -rf /var/lib/apt/lists/*
