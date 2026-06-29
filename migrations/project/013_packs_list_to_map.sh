#!/usr/bin/env bash
# Migration 013 — convert the project `packs:` list to the coordinate map schema.
#
# Legacy:  packs:            New (ADR-0016 D2 / ADR-0019):  packs:
#            - my-pack                                        - name: my-pack
# A bare-name pack reference becomes a `- name:` entry so the final uniform
# project.yml/pack.yml schema (name + optional url/ref/resource) parses it. The
# Phase-2 `cco init --migrate` writes the map form directly; this migration
# upgrades any pre-existing legacy project.yml on `cco update`.

MIGRATION_ID=13
MIGRATION_DESC="Convert project packs: list to the coordinate map schema"

migrate() {
    local target_dir="$1"
    local yml="$target_dir/project.yml"
    [[ -f "$yml" ]] || return 0

    # Idempotent: do nothing unless there is at least one bare list-style entry.
    awk '
        /^packs:/ { p=1; next }
        p && /^[^ #]/ { p=0 }
        p && /^  - [^ ]/ && !/^  - name:/ { f=1 }
        END { exit (f ? 0 : 1) }
    ' "$yml" || return 0

    local tmp
    tmp=$(mktemp)
    awk '
        /^packs:/ { print; p=1; next }
        p && /^[^ #]/ { p=0 }
        p && /^  - name:/ { print; next }
        p && /^  - / {
            v=$0; sub(/^  - */, "", v); gsub(/["\047]/, "", v); sub(/ *#.*$/, "", v)
            gsub(/^ +| +$/, "", v)
            if (v != "" && v != "[]") { print "  - name: " v; next }
        }
        { print }
    ' "$yml" > "$tmp" && mv "$tmp" "$yml"
    return 0
}
