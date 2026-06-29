#!/usr/bin/env bash
# lib/utils.sh — General utility functions
#
# Provides: expand_path(), _path_exists(), _peel_tab(), check_docker(),
#           check_image(), check_global(), _check_reserved_project_name(),
#           _sed_i(), _sed_i_or_append(), _substitute()
# Dependencies: colors.sh
# Globals: IMAGE_NAME

# Expand ~ in paths
expand_path() {
    local path="$1"
    if [[ "$path" == ~* ]]; then
        path="${HOME}${path#\~}"
    fi
    echo "$path"
}

# Check if a path exists as either a file or a directory.
# Canonical check for project.yml sources — repos are directories,
# but extra_mounts can legitimately be single files (e.g. a .docx).
# Using `-d` alone (as pre-runtime-invariants code did) produced false
# negatives for file mounts. Always expand ~ before checking.
# Usage: _path_exists <path>
_path_exists() {
    local path
    path=$(expand_path "$1")
    [[ -e "$path" ]]
}

# True (0) when an interactive controlling terminal is reachable. Use this — NOT
# `[[ -t 0 ]]` — to gate interactive prompts. Resolve/start drive their prompts
# from `while read … done < <(yml_…)` loops, where fd 0 IS the process-
# substitution pipe, so `[[ -t 0 ]]` is ALWAYS false inside them even on a real
# terminal (this silently broke `cco resolve`, which then never prompted). The
# prompts themselves read from /dev/tty, so /dev/tty reachability is the correct
# interactivity test. The subshell keeps the probe from consuming the parent fd 0.
_cco_have_tty() {
    (exec < /dev/tty) 2>/dev/null
}

# Emit one docker-compose short-syntax bind-mount line, YAML-DOUBLE-QUOTED so a
# host path containing a space or a YAML-special char (e.g. a folder like
# `Cave gif`, or a leading `@`/`#`) cannot break `docker compose` parsing
# ('found character that cannot start any token'). Compose's own ':' volume
# splitting and `${VAR}` interpolation still apply to the quoted value (both run
# after YAML parsing). $1=host source, $2=container target, $3=mode (ro|rw|"").
# (Paths containing a literal '"' are not supported — not a real bind-mount case.)
_compose_vol() {
    local src="$1" tgt="$2" mode="${3:-}"
    if [[ -n "$mode" ]]; then
        printf '      - "%s:%s:%s"\n' "$src" "$tgt" "$mode"
    else
        printf '      - "%s:%s"\n' "$src" "$tgt"
    fi
}

# Parse a CLI --mount spec into an "<abs_source>\t<target>\t<ro>" line
# (the same TSV shape _effective_extra_mounts emits, so the compose-gen
# consumes both uniformly). Spec: "src[:target][:ro|:rw]".
#   - Read-only is the DEFAULT (ADR-0027 D2 — the common reference-mount case);
#     a trailing ":rw" opts into writable.
#   - target defaults to /workspace/<basename src>.
#   - src is expanded (~) and made absolute against $PWD for a truthful bind.
# Dies on an empty or non-existent source. Usage: _parse_user_mount_spec <spec>
_parse_user_mount_spec() {
    local spec="$1"
    local mode="ro" src target
    case "$spec" in
        *:ro) mode="ro"; spec="${spec%:ro}" ;;
        *:rw) mode="rw"; spec="${spec%:rw}" ;;
    esac
    src="${spec%%:*}"
    if [[ "$spec" == *:* ]]; then target="${spec#*:}"; else target=""; fi
    [[ -z "$src" ]] && die "Invalid --mount spec (empty source): $1"
    src=$(expand_path "$src")
    [[ "$src" != /* ]] && src="$PWD/$src"
    _path_exists "$src" || die "--mount source does not exist: $src"
    [[ -z "$target" ]] && target="/workspace/$(basename "$src")"
    local ro="true"; [[ "$mode" == "rw" ]] && ro="false"
    printf '%s\t%s\t%s\n' "$src" "$target" "$ro"
}

# Split a TAB-separated record into the named variables, one field each.
# This centralizes the "peel by hand" idiom repeated across the coordinate
# readers (resolve / project-validate / project-coords): it MUST be a manual
# peel, never `IFS=$'\t' read`, because tab is whitespace to `read`, which
# collapses adjacent delimiters and so silently drops empty MIDDLE fields —
# exactly the fields the coordinate emitters (yaml.sh *_coords) can produce
# (e.g. a repo with a name but no url → "name\t\tref"). Here each named var
# receives exactly one field, empty fields are preserved, trailing fields
# beyond the last named var are ignored, and missing fields yield empty vars.
# Usage: _peel_tab <record> <var1> [<var2> ...]
_peel_tab() {
    local _rec="$1"; shift
    local _name
    for _name in "$@"; do
        if [[ "$_rec" == *$'\t'* ]]; then
            printf -v "$_name" '%s' "${_rec%%$'\t'*}"
            _rec="${_rec#*$'\t'}"
        else
            printf -v "$_name" '%s' "$_rec"
            _rec=""
        fi
    done
}

# Fit <str> into exactly <width> display columns for a table column: pad short
# strings with trailing spaces, truncate long ones to <width>-1 chars + a
# 1-column ellipsis ("…"). Inputs are ASCII (validated names/tags), so character
# count == display width. We pad manually (not via printf '%-Ns') because the
# ellipsis is multi-byte: printf would pad by bytes and shift the next column.
# Print the result with a plain '%s' and join columns with single spaces.
# Usage: _fit_col <str> <width>
_fit_col() {
    local _s="$1" _w="$2" _n
    _n=${#_s}
    if (( _n > _w )); then
        printf '%s…' "${_s:0:$((_w - 1))}"   # truncated → exactly <width> columns
        return 0
    fi
    printf '%s%*s' "$_s" "$((_w - _n))" ''
}

# Check Docker is running
check_docker() {
    if ! docker info >/dev/null 2>&1; then
        die "Docker daemon is not running. Start Docker Desktop."
    fi
}

# Check image exists
check_image() {
    if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        die "Docker image '$IMAGE_NAME' not found. Run 'cco build' first."
    fi
}

# Check global config exists (created by cco init, or migrated by cco update).
# A legacy user (vault backup present, ~/.cco/.claude not yet populated) must be
# pointed at 'cco update' — the eager global migration — not 'cco init', which would
# seed defaults and force an unexpected overwrite-confirm on the next update (H5).
check_global() {
    if [[ ! -d "$(_cco_global_claude_dir)" ]]; then
        if _cco_have_backup "$(_cco_state_dir)/backups" 2>/dev/null; then
            die "Global config not found, but a legacy vault backup exists. Run 'cco update' to migrate your global config from the vault."
        fi
        die "Global config not found. Run 'cco init' first."
    fi
}

# Reserved project names (used as keywords by CLI commands)
RESERVED_PROJECT_NAMES=("global" "all" "tutorial" "config-editor")

# Check if a project name is reserved
_check_reserved_project_name() {
    local name="$1"
    local reserved
    for reserved in "${RESERVED_PROJECT_NAMES[@]}"; do
        if [[ "$name" == "$reserved" ]]; then
            die "Project name '$name' is reserved. Choose a different name."
        fi
    done
}

# ── Destructive-action confirmation (ADR-0029 D2) ────────────────────
# The uniform contract for every destructive / irreversible action. The CALLER
# prints the preview (what will be removed, incl. any id-keyed cascade) and
# performs any "--force overrides an in-use/overwrite block" check BEFORE calling
# this; the helper owns only the remaining three steps:
#   1. skip == true  → proceed silently (set by -y/--yes, or --force which
#                      implies -y).
#   2. otherwise, on a TTY → ask "<prompt> [y/N]" (default No) and read the reply.
#   3. otherwise (no TTY, no skip) → die with a "re-run with -y" message, so a
#      destructive action is never performed unattended by accident.
# Returns 0 to proceed, non-zero when the user answers No (caller prints an
# "Aborted" line and returns 0). Models cmd_forget's confirm, but DIES (never
# silently skips) when non-interactive — the ADR-0029 D2 maintainer ruling.
# Usage: _confirm_destructive <skip-bool> <prompt>
_confirm_destructive() {
    local skip="$1" prompt="$2" reply
    [[ "$skip" == true ]] && return 0
    if [[ ! -t 0 ]]; then
        die "Refusing to proceed without confirmation ($prompt) — re-run with -y."
    fi
    printf '%s [y/N] ' "$prompt" >&2
    read -r reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ── Portable sed -i ──────────────────────────────────────────────────
# macOS sed requires -i '' while GNU sed requires -i without argument.

# Replace all occurrences of a pattern in a file.
# Usage: _sed_i <file> <pattern> <replacement> [delimiter]
_sed_i() {
    local file="$1" pattern="$2" replacement="$3" delim="${4:-|}"
    sed -i '' "s${delim}${pattern}${delim}${replacement}${delim}g" "$file" 2>/dev/null || \
        sed -i "s${delim}${pattern}${delim}${replacement}${delim}g" "$file"
}

# Replace a key: value field in-place, or append it if missing.
# Usage: _sed_i_or_append <file> <key> <value>
_sed_i_or_append() {
    local file="$1" key="$2" value="$3"
    if grep -q "^${key}:" "$file" 2>/dev/null; then
        _sed_i "$file" "^${key}:.*" "${key}: ${value}"
    else
        printf '%s: %s\n' "$key" "$value" >> "$file"
    fi
}

# Replace a {{PLACEHOLDER}} in a file with a value.
# Uses awk to avoid delimiter conflicts (values may contain / or |).
# Usage: _substitute <file> <placeholder> <value>
_substitute() {
    local file="$1" placeholder="$2" value="$3"
    local token="{{${placeholder}}}"
    # Escape & and \ in value to prevent awk gsub back-reference interpretation
    awk -v tok="$token" -v val="$value" '
        BEGIN { gsub(/\\/, "\\\\", val); gsub(/&/, "\\\\&", val) }
        { gsub(tok, val); print }
    ' "$file" > "$file.tmp" \
        && mv "$file.tmp" "$file"
}

# Run arbitrary sed expression(s) portably (macOS + GNU).
# Usage: _sed_i_raw <file> <sed_args...>
_sed_i_raw() {
    local file="$1"; shift
    sed -i '' "$@" "$file" 2>/dev/null || \
        sed -i "$@" "$file"
}
