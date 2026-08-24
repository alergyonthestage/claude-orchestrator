#!/usr/bin/env bash
# lib/secrets.sh — Secrets loading, scan helpers, and migration helpers
#
# Provides:
#   Loading:   load_secrets_file(), load_global_secrets()
#   Scanning:  _secret_match_filename(), _secret_match_content(),
#              _secret_scan_paths(), _secret_scan_staged(), _secret_gitignore_probe()
#              _SECRET_FILENAME_PATTERNS, _SECRET_CONTENT_PATTERNS,
#              _SECRET_PROJECT_GITIGNORE_CLASSES
#   Deprecated: migrate_memory_to_claude_state() [use migrations/project/001],
#               _migrate_to_managed() [use migrations/global/001]
# Dependencies: colors.sh, utils.sh
# Globals: DEFAULTS_DIR
#
# Scanning rationale: vault save (pre-commit) and project publish
# (pre-push) both need to block known-secret files. Keeping the pattern
# lists and match semantics here avoids drift across the two gates —
# same class of mistake as #B10 (status/diff divergent counts).

# ── Secret patterns — canonical source of truth ─────────────────────

# Filename patterns (glob-style). Match is by basename or by path
# suffix — `.credentials.json` matches both `foo/.credentials.json` and
# a bare `.credentials.json`, and `.cco/remotes` matches any file
# ending with that relative path.
_SECRET_FILENAME_PATTERNS=(
    'secrets.env'
    '*.env'
    '*.key'
    '*.pem'
    '.credentials.json'
    '.netrc'
    '.cco/remotes'
)

# Content patterns (ERE). Scanned only on text files.
_SECRET_CONTENT_PATTERNS=(
    'API_KEY\s*[=:]'
    'SECRET_KEY\s*[=:]'
    'SECRET\s*[=:]'
    'PASSWORD\s*[=:]'
    'PRIVATE_KEY'
    'BEGIN RSA PRIVATE KEY'
    'BEGIN OPENSSH PRIVATE KEY'
    'ghp_[a-zA-Z0-9]'       # GitHub personal access token
    'gho_[a-zA-Z0-9]'       # GitHub OAuth token
    'sk-[a-zA-Z0-9]'        # OpenAI / Anthropic API key prefix
)

# Match a path against _SECRET_FILENAME_PATTERNS.
# Echoes the matched pattern on hit; return 0 on match, 1 otherwise.
# Usage: if hit=$(_secret_match_filename "$path"); then ...; fi
_secret_match_filename() {
    local path="$1"
    local base
    base=$(basename "$path")
    local pattern
    for pattern in "${_SECRET_FILENAME_PATTERNS[@]}"; do
        if [[ "$base" == $pattern || "$path" == *"$pattern" ]]; then
            echo "$pattern"
            return 0
        fi
    done
    return 1
}

# ── The project-config gitignore floor (ADR-0038 D7) ────────────────
#
# The secret filename classes cco's OWN project scaffold declares in
# <repo>/.cco/.gitignore (_cco_write_project_gitignore, lib/migrate.sh). This is
# the coverage `cco project save` refuses below — deliberately NOT the whole
# _SECRET_FILENAME_PATTERNS list above, which also carries `.netrc` and
# `.cco/remotes`. cco has never written those two into a project's .gitignore, so
# demanding them would refuse every project it scaffolded itself.
#
# The narrower floor costs nothing: the 2-pass scan runs on the staged set ALWAYS
# (D7), against the FULL pattern list — so a `.netrc` under .cco/ is still caught
# and still refuses the save. The floor decides what must be barred BEFORE staging;
# the scan is what actually reads the files.
#
# Kept in step with the scaffold by test_invariant_project_gitignore_floor_covered.
_SECRET_PROJECT_GITIGNORE_CLASSES=( 'secrets.env' '*.env' '*.key' '*.pem' '.credentials.json' )

# A concrete filename that matches <class>, for `git check-ignore` to rule on:
# coverage is measured by asking git, not by grepping the file for a literal.
# A glob class needs a real name to probe with; a literal class probes as itself.
_secret_gitignore_probe() {
    case "$1" in
        \**) printf 'cco-gitignore-probe%s\n' "${1#\*}" ;;
        *)   printf '%s\n' "$1" ;;
    esac
}

# Scan a file's contents for _SECRET_CONTENT_PATTERNS.
# Text-files only (binaries skipped). Stops at first match.
# Echoes "<line_number>:<pattern>" on hit; return 0 on match, 1 otherwise.
_secret_match_content() {
    local file="$1"
    [[ ! -f "$file" ]] && return 1
    file "$file" 2>/dev/null | grep -q "text" || return 1
    local pattern
    for pattern in "${_SECRET_CONTENT_PATTERNS[@]}"; do
        local match_line
        match_line=$(grep -nE "$pattern" "$file" 2>/dev/null | head -1 | cut -d: -f1)
        if [[ -n "$match_line" ]]; then
            echo "${match_line}:${pattern}"
            return 0
        fi
    done
    return 1
}

# The 2-pass question itself (filename, then content), over an explicit list of
# <git_root>-relative paths read from STDIN; *.example is exempt (FR-S3).
# Echoes "<path>\t(why)" on the FIRST hit and returns 1 (block); returns 0 clean.
#
# It is separated from "which files are staged" because the two SAVE verbs are not
# the only callers any more: `cco project status` / `cco config status` must preview
# this refusal (ADR-0038 A2 D14), and a read verb may not stage to find out. Both
# therefore ask the same question of a set they computed — same function, same
# words, no second copy of the pattern matching to drift.
# Usage: <paths on stdin> | _secret_scan_paths <git_root>
_secret_scan_paths() {
    local root="$1" f hit
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        [[ "$f" == *.example ]] && continue
        if hit=$(_secret_match_filename "$f" 2>/dev/null) && [[ -n "$hit" ]]; then
            printf '%s\t(filename matches %s)\n' "$f" "$hit"; return 1
        fi
        if [[ -f "$root/$f" ]] && hit=$(_secret_match_content "$root/$f" 2>/dev/null) && [[ -n "$hit" ]]; then
            printf '%s\t(content matches at line %s)\n' "$f" "${hit%%:*}"; return 1
        fi
    done
    return 0
}

# The same question over the currently STAGED files of <git_root>, optionally
# narrowed to <pathspec>. This is the gate both `save` verbs run before committing.
#
# ONE scanner for both save gates — `cco config save` (~/.cco, the whole store) and
# `cco project save` (<repo>/.cco, path-scoped). It lives here, beside the pattern
# lists, for the reason this file's header already gives: a second copy drifts.
#
# The PATHSPEC is what lets one function serve both. Without it the project verb
# would scan the user's unrelated staged work and refuse over a file it was never
# going to commit — the twin can omit it only because it owns its whole tree.
# Usage: _secret_scan_staged <git_root> [<pathspec>]
_secret_scan_staged() {
    local root="$1" spec="${2:-}"
    local -a sel=()
    [[ -n "$spec" ]] && sel=( -- "$spec" )
    git -C "$root" diff --cached --name-only ${sel[@]+"${sel[@]}"} 2>/dev/null \
        | _secret_scan_paths "$root"
}

# Load secrets from a specific file into an array of -e flags
# Usage: load_secrets_file array_name file_path
load_secrets_file() {
    local _target=$1
    local secrets_file="$2"
    [[ ! -f "$secrets_file" ]] && return 0
    local line_num=0
    while IFS= read -r line; do
        line_num=$(( line_num + 1 ))
        # Skip empty lines and comments
        [[ -z "$line" || "$line" == \#* ]] && continue
        # Strip inline comments
        line="${line%%#*}"
        # Trim trailing whitespace
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        # Validate KEY=VALUE format
        if [[ "$line" != *=* ]]; then
            warn "$(basename "$secrets_file"):${line_num}: skipping malformed line (expected KEY=VALUE)"
            continue
        fi
        eval "${_target}+=(-e $(printf '%q' "$line"))"
    done < "$secrets_file"
}

# Load global secrets from the CONFIG bucket (~/.cco/secrets.env) into an array
# of -e flags. The secrets file is gitignored config, top-level in ~/.cco
# (design §2.3 / ADR-0016), NOT under global/.
# Usage: load_global_secrets array_name
load_global_secrets() {
    load_secrets_file "$1" "$(_cco_config_dir)/secrets.env"
}

# DEPRECATED: Use migrations/project/001_memory_to_claude_state.sh instead.
# Kept for backward compatibility with cmd-start.sh (users who haven't run cco update).
# Uses .cco/claude-state/ (post-consolidation path) with fallback for legacy installs.
migrate_memory_to_claude_state() {
    local project_dir="$1"
    local cs_dir
    cs_dir=$(_cco_project_claude_state "$project_dir")
    if [[ -d "$project_dir/memory" && ! -d "$cs_dir" ]]; then
        info "Migrating $project_dir/memory → $cs_dir/memory (one-time)"
        mkdir -p "$cs_dir"
        mv "$project_dir/memory" "$cs_dir/memory"
    fi
    mkdir -p "$cs_dir" "$project_dir/memory"
}

# DEPRECATED: Use migrations/global/001_managed_scope.sh instead.
# Kept for backward compatibility with existing installs that call cmd-init
# before running cco update for the first time.
_migrate_to_managed() {
    local global_dir; global_dir="$(_cco_config_dir)"
    local marker="$global_dir/.claude/.managed-migration-done"

    [[ -f "$marker" ]] && return 0
    [[ ! -d "$global_dir/.claude" ]] && return 0

    # Remove .system-manifest (no longer needed)
    rm -f "$global_dir/.claude/.system-manifest"

    # Legacy migration: remove old skills/init/ (renamed to init-workspace/)
    if [[ -d "$global_dir/.claude/skills/init" ]]; then
        rm -rf "$global_dir/.claude/skills/init"
        info "Migrated: removed old skills/init/ (renamed to init-workspace/)"
    fi

    # If settings.json contains hooks (old unified format),
    # replace with user-only settings
    if [[ -f "$global_dir/.claude/settings.json" ]]; then
        if grep -q '"hooks"' "$global_dir/.claude/settings.json" 2>/dev/null; then
            cp "$global_dir/.claude/settings.json" "$global_dir/.claude/settings.json.pre-managed"
            cp "$DEFAULTS_DIR/global/.claude/settings.json" "$global_dir/.claude/settings.json"
            info "Migrated: settings.json split (old version backed up as settings.json.pre-managed)"
        fi
    fi

    touch "$marker"
    ok "Managed scope migration complete"
}
