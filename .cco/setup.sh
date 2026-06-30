#!/bin/bash
# Project setup script — executed at every `cco start` as root.
# Use for lightweight, project-specific runtime setup.
# Must be idempotent (runs on every session start).
#
# Example:
#   pip3 install --quiet pandas numpy 2>/dev/null
