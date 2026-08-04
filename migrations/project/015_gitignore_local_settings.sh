#!/usr/bin/env bash
# Migration 015 — gitignore the generated settings.local.json mountpoint stub in
# a project's <repo>/.cco/claude/ (ADR-0049 §5).
#
# The functional-write floor binds a rw STATE copy of settings.local.json over the
# :ro project .claude tree. Docker cannot create that mountpoint inside a :ro bind,
# so `cco start` now seeds an inert stub at <repo>/.cco/claude/settings.local.json.
# The stub is generated, never authored: the live content lives in STATE and always
# shadows it. Exclude it so it never lands in a commit (INV-2).
#
# Unlike migration 014 this does NOT purge an existing file: a project that already
# carries a real settings.local.json there authored it deliberately, and `cco start`
# seeds STATE *from* it on first use. Removing it would destroy that content — and
# a tracked file is unaffected by .gitignore anyway, so it stays visible.
# Idempotent: re-running is a no-op once the exclusion is present.
#
# migrate() receives <repo>/.cco (the project unit dir), same as migration 014.

MIGRATION_ID=15
MIGRATION_DESC="Gitignore the generated settings.local.json mountpoint stub (ADR-0049 §5)"

# The generated file to exclude, relative to the .cco dir.
_MIG015_FILE="claude/settings.local.json"

migrate() {
    local ccodir="$1"
    [[ -d "$ccodir" ]] || return 0

    local gi="$ccodir/.gitignore"
    if [[ ! -f "$gi" ]]; then
        # Missing entirely → author the full skeleton (secret + generated), the
        # same content `cco init` scaffolds; it already carries the exclusion.
        # _cco_write_project_gitignore is in scope: migrations are sourced into
        # the bin/cco environment.
        if type _cco_write_project_gitignore >/dev/null 2>&1; then
            _cco_write_project_gitignore "$gi"
            return 0
        fi
        : > "$gi"
    fi

    # Append only when missing — preserve any user customizations already there.
    grep -qxF "$_MIG015_FILE" "$gi" 2>/dev/null && return 0
    if grep -qF '# Generated session artifacts' "$gi" 2>/dev/null; then
        # The 014 block exists — extend it in place rather than opening a second one.
        local tmpf; tmpf=$(mktemp "${gi}.XXXXXX") || return 0
        awk -v add="$_MIG015_FILE" '
            { print }
            !done && /^claude\/scheduled_tasks\.lock$/ { print add; done = 1 }
            END { if (!done) print add }
        ' "$gi" > "$tmpf" && mv "$tmpf" "$gi"
    else
        printf '\n# Generated session artifacts — never committed (ADR-0005 F1 / ADR-0042)\n%s\n' \
            "$_MIG015_FILE" >> "$gi"
    fi
    return 0
}
