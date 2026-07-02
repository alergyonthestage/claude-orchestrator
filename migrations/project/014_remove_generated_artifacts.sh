#!/usr/bin/env bash
# Migration 014 — remove committed generated session artifacts from a project's
# <repo>/.cco/claude/ and gitignore them going forward (ADR-0042 / ADR-0005 F1).
#
# Generated artifacts must never live in a committed tree (INV-2):
#   - workspace.yml       — retired; Level-A context is now injected via the
#                           CCO_SESSION_CONTEXT env var (ADR-0042 step 2), no file.
#   - packs.md            — absorbed into that injected context (R1-D2), no file.
#   - scheduled_tasks.lock — a runtime lock, never config.
# Early projects committed these before the decentralized-config cutover (bugs
# A1/A3/A6). This migration removes them (git rm when tracked so the deletion is
# staged, plain rm for an untracked leftover) and adds their exclusions to
# .cco/.gitignore so they never reappear. Idempotent: a clean project is a no-op.
#
# migrate() receives <repo>/.cco (the project unit dir), same as migration 013.

MIGRATION_ID=14
MIGRATION_DESC="Remove committed generated artifacts (workspace.yml/packs.md/scheduled_tasks.lock) + gitignore them"

# The generated files to purge + exclude, relative to the .cco dir.
_MIG014_FILES="claude/workspace.yml claude/packs.md claude/scheduled_tasks.lock"

# Remove one generated file (path relative to the .cco dir). git rm when tracked
# so the deletion is staged; plain rm for an untracked copy; no-op when absent.
_mig014_rm() {
    local ccodir="$1" rel="$2" f="$ccodir/$rel"
    if git -C "$ccodir" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
       && git -C "$ccodir" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
        git -C "$ccodir" rm -f "$rel" >/dev/null 2>&1 || rm -f "$f"
    else
        [[ -e "$f" ]] && rm -f "$f"
    fi
    return 0
}

migrate() {
    local ccodir="$1"
    [[ -d "$ccodir" ]] || return 0

    # 1. Purge the committed/leftover generated artifacts under claude/.
    local rel
    for rel in $_MIG014_FILES; do
        _mig014_rm "$ccodir" "$rel"
    done

    # 2. Ensure .cco/.gitignore excludes them going forward (idempotent).
    local gi="$ccodir/.gitignore"
    if [[ ! -f "$gi" ]]; then
        # Missing entirely → author the full skeleton (secret + generated), the
        # same content `cco init` scaffolds. _cco_write_project_gitignore is in
        # scope: migrations are sourced into the bin/cco environment.
        if type _cco_write_project_gitignore >/dev/null 2>&1; then
            _cco_write_project_gitignore "$gi"
            return 0
        fi
        : > "$gi"
    fi
    # Append only the generated-file exclusions that are missing — preserve any
    # user customizations already in the file.
    local added=0
    for rel in $_MIG014_FILES; do
        grep -qxF "$rel" "$gi" 2>/dev/null && continue
        if [[ $added -eq 0 ]]; then
            printf '\n# Generated session artifacts — never committed (ADR-0005 F1 / ADR-0042)\n' >> "$gi"
            added=1
        fi
        printf '%s\n' "$rel" >> "$gi"
    done
    return 0
}
