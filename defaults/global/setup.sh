#!/bin/bash
# Global setup script — executed during `cco build` as root.
# Install system packages, configure settings, add repositories.
# Changes apply to ALL projects.
#
# Example:
#   apt-get update && apt-get install -y chromium && rm -rf /var/lib/apt/lists/*
