#!/bin/bash
# Global runtime setup — executed at every `cco start`, before project setup.
# Runs as user `claude` inside the container.
#
# USE FOR:
#   - Dotfiles (~/.tmux.conf, ~/.bashrc additions, ~/.vimrc)
#   - Shell aliases and functions
#   - tmux keybindings and configuration
#   - Lightweight pip/npm packages needed in all projects
#   - git config overrides (git config --global ...)
#
# DO NOT USE FOR:
#   - apt-get install, system packages, heavy downloads
#   → Use setup-build.sh instead (runs once at `cco build`)
#
# This script must be idempotent (safe to run multiple times).
# See: docs/user-guides/advanced/custom-environment.md
#
# Example:
#   # Add tmux keybinding
#   tmux bind-key C-b send-prefix 2>/dev/null || true
#
#   # Set shell alias
#   echo 'alias ll="ls -la"' >> ~/.bashrc
