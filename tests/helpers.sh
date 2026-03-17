#!/usr/bin/env bash
# tests/helpers.sh — shared setup, teardown, and assertion helpers
# Sourced by bin/test before running any test file.
# All functions are available in every test function's subshell context.

# ── Environment Setup ─────────────────────────────────────────────────

# Configure CCO env vars to point into $tmpdir, not the real global/projects
# Usage: setup_cco_env "$tmpdir"
setup_cco_env() {
    local tmpdir="$1"
    export CCO_USER_CONFIG_DIR="$tmpdir/user-config"
    export CCO_GLOBAL_DIR="$tmpdir/user-config/global"
    export CCO_PROJECTS_DIR="$tmpdir/user-config/projects"
    export CCO_PACKS_DIR="$tmpdir/user-config/packs"
    export CCO_TEMPLATES_DIR="$tmpdir/user-config/templates"
    export CCO_DUMMY_REPO="$tmpdir/dummy-repo"
    mkdir -p "$CCO_USER_CONFIG_DIR" "$CCO_GLOBAL_DIR" "$CCO_PROJECTS_DIR" \
             "$CCO_PACKS_DIR" "$CCO_TEMPLATES_DIR" "$CCO_DUMMY_REPO"
}

# Copy defaults/global/.claude into tmpdir/user-config/global/.claude
# (simulates cco init — all agents, skills, rules, settings are in global defaults)
# Usage: setup_global_from_defaults "$tmpdir"
setup_global_from_defaults() {
    local tmpdir="$1"
    mkdir -p "$tmpdir/user-config/global"
    cp -r "$REPO_ROOT/defaults/global/.claude" "$tmpdir/user-config/global/.claude"
    mkdir -p "$tmpdir/user-config/packs"
}

# Create a minimal project directory with the given project.yml content.
# Also creates .claude/ and memory/ directories.
# Usage: create_project "$tmpdir" "my-project" "$yml_content"
create_project() {
    local tmpdir="$1"
    local name="$2"
    local yml_content="$3"
    local project_dir="$tmpdir/user-config/projects/$name"
    mkdir -p "$project_dir/.claude"
    mkdir -p "$project_dir/memory"
    printf '%s\n' "$yml_content" > "$project_dir/project.yml"
}

# Create a pack definition in packs/<name>/pack.yml
# Usage: create_pack "$tmpdir" "pack-name" "$yml_content"
create_pack() {
    local tmpdir="$1"
    local name="$2"
    local yml_content="$3"
    local pack_dir="$tmpdir/user-config/packs/$name"
    mkdir -p "$pack_dir"
    printf '%s\n' "$yml_content" > "$pack_dir/pack.yml"
}

# Run bin/cco with CCO env vars set.
# Captures stdout+stderr into CCO_OUTPUT. Returns exit code.
# For dry-run commands, automatically extracts DRY_RUN_DIR from output.
# Usage: run_cco [args...]
run_cco() {
    DRY_RUN_DIR=""
    CCO_OUTPUT=$(
        CCO_USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR" \
        CCO_GLOBAL_DIR="$CCO_GLOBAL_DIR" \
        CCO_PROJECTS_DIR="$CCO_PROJECTS_DIR" \
        CCO_PACKS_DIR="$CCO_PACKS_DIR" \
        CCO_TEMPLATES_DIR="$CCO_TEMPLATES_DIR" \
        bash "$REPO_ROOT/bin/cco" "$@" 2>&1
    ) || return $?
    # Auto-extract dry-run dir if present in output (--dump mode persists to .tmp/)
    local _dr
    _dr=$(echo "$CCO_OUTPUT" | sed -n 's|.*Generated files available at: \(.*\)/|\1|p')
    if [[ -n "$_dr" ]]; then
        DRY_RUN_DIR="$_dr"
    fi
}

# ── Assertions ────────────────────────────────────────────────────────

fail() {
    echo "ASSERTION FAILED: $*"
    return 1
}

assert_file_exists() {
    local file="$1"
    local msg="${2:-Expected file to exist: $file}"
    if [[ ! -f "$file" ]]; then
        echo "ASSERTION FAILED: $msg"
        echo "  File not found: $file"
        return 1
    fi
}

assert_file_not_exists() {
    local file="$1"
    local msg="${2:-Expected file NOT to exist: $file}"
    if [[ -f "$file" ]]; then
        echo "ASSERTION FAILED: $msg"
        echo "  File exists: $file"
        return 1
    fi
}

assert_dir_exists() {
    local dir="$1"
    local msg="${2:-Expected directory to exist: $dir}"
    if [[ ! -d "$dir" ]]; then
        echo "ASSERTION FAILED: $msg"
        echo "  Directory not found: $dir"
        return 1
    fi
}

assert_dir_not_exists() {
    local dir="$1"
    local msg="${2:-Expected directory NOT to exist: $dir}"
    if [[ -d "$dir" ]]; then
        echo "ASSERTION FAILED: $msg"
        echo "  Directory exists: $dir"
        return 1
    fi
}

# Assert file contains a literal string (not a regex)
# Uses -e to safely handle patterns starting with '-'
assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local msg="${3:-Expected '$file' to contain: $pattern}"
    if ! grep -qFe "$pattern" "$file" 2>/dev/null; then
        echo "ASSERTION FAILED: $msg"
        echo "  Pattern not found: $(printf '%q' "$pattern")"
        echo "  File contents ($(wc -l < "$file") lines):"
        sed 's/^/    /' "$file"
        return 1
    fi
}

# Assert file does NOT contain a literal string
assert_file_not_contains() {
    local file="$1"
    local pattern="$2"
    local msg="${3:-Expected '$file' NOT to contain: $pattern}"
    if grep -qFe "$pattern" "$file" 2>/dev/null; then
        echo "ASSERTION FAILED: $msg"
        echo "  Found unwanted pattern: $(printf '%q' "$pattern")"
        grep -nFe "$pattern" "$file" | sed 's/^/    /'
        return 1
    fi
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-Equality assertion failed}"
    if [[ "$expected" != "$actual" ]]; then
        echo "ASSERTION FAILED: $msg"
        echo "  Expected: $(printf '%q' "$expected")"
        echo "  Got:      $(printf '%q' "$actual")"
        return 1
    fi
}

assert_empty() {
    local actual="$1"
    local msg="${2:-Expected empty string}"
    if [[ -n "$actual" ]]; then
        echo "ASSERTION FAILED: $msg"
        echo "  Got: $(printf '%q' "$actual")"
        return 1
    fi
}

# Assert $CCO_OUTPUT (set by run_cco) contains a literal string
# Uses -e to safely handle patterns starting with '-'
assert_output_contains() {
    local pattern="$1"
    local msg="${2:-Expected output to contain: $pattern}"
    if ! echo "${CCO_OUTPUT:-}" | grep -qFe "$pattern"; then
        echo "ASSERTION FAILED: $msg"
        echo "  Pattern not found: $(printf '%q' "$pattern")"
        echo "  Actual output:"
        echo "${CCO_OUTPUT:-}" | sed 's/^/    /'
        return 1
    fi
}

# Assert file has NO unreplaced {{PLACEHOLDER}} pattern
assert_no_placeholder() {
    local file="$1"
    local placeholder="$2"
    local msg="${3:-Expected placeholder to be replaced in $file: $placeholder}"
    if grep -qFe "$placeholder" "$file" 2>/dev/null; then
        echo "ASSERTION FAILED: $msg"
        echo "  Unreplaced placeholder still present: $placeholder"
        return 1
    fi
}

# Assert file has no {{...}} placeholders at all
assert_no_placeholders() {
    local file="$1"
    local found
    found=$(grep -oE '\{\{[^}]+\}\}' "$file" 2>/dev/null || true)
    if [[ -n "$found" ]]; then
        echo "ASSERTION FAILED: unreplaced placeholders in $file"
        echo "$found" | sort -u | sed 's/^/  /'
        return 1
    fi
}

# Assert the generated docker-compose.yml has the expected structure
assert_valid_compose() {
    local file="$1"
    assert_file_exists "$file" "docker-compose.yml was not generated at $file"
    assert_file_contains "$file" "services:"
    assert_file_contains "$file" "image: "
    assert_file_contains "$file" "stdin_open: true"
    assert_file_contains "$file" "tty: true"
    assert_file_contains "$file" "working_dir: /workspace"

    # Validate YAML syntax if python3 + PyYAML are available
    if command -v python3 >/dev/null 2>&1; then
        local _yaml_result
        _yaml_result=$(python3 -c "
import sys
try:
    import yaml
    yaml.safe_load(open(sys.argv[1]))
    print('ok')
except ImportError:
    print('no-yaml')
except Exception as e:
    print('error:', e)
    sys.exit(1)
" "$file" 2>/dev/null) || true
        if [[ "${_yaml_result:-}" == error:* ]]; then
            echo "ASSERTION FAILED: $file is not valid YAML: $_yaml_result"
            return 1
        fi
    fi
}

# ── Update System Helpers ──────────────────────────────────────────────

# Create a .cco/meta file with the given content
# Usage: create_cco_meta "$meta_file" "$content"
create_cco_meta() {
    local meta_file="$1"
    local content="$2"
    mkdir -p "$(dirname "$meta_file")"
    printf '%s\n' "$content" > "$meta_file"
}

# Modify a managed file to simulate a user edit
# Usage: modify_managed_file "$file_path"
modify_managed_file() {
    local file="$1"
    printf '\n# User customization\n' >> "$file"
}

# Assert $CCO_OUTPUT does NOT contain a literal string
assert_output_not_contains() {
    local pattern="$1"
    local msg="${2:-Expected output NOT to contain: $pattern}"
    if echo "${CCO_OUTPUT:-}" | grep -qFe "$pattern"; then
        echo "ASSERTION FAILED: $msg"
        echo "  Found unwanted pattern: $(printf '%q' "$pattern")"
        echo "  Actual output:"
        echo "${CCO_OUTPUT:-}" | sed 's/^/    /'
        return 1
    fi
}

# Extract the dry-run output directory from CCO_OUTPUT.
# dry-run prints "Generated files available at: <project_dir>/.tmp/"
# Sets DRY_RUN_DIR to the extracted path.
# Usage: extract_dry_run_dir
extract_dry_run_dir() {
    DRY_RUN_DIR=$(echo "${CCO_OUTPUT:-}" | sed -n 's|.*Generated files available at: \(.*/.tmp\)/.*|\1|p')
    if [[ -z "$DRY_RUN_DIR" ]]; then
        echo "HELPER ERROR: Could not extract dry-run directory from output"
        echo "  Output: ${CCO_OUTPUT:-}"
        return 1
    fi
}

# ── Framework Change Helpers ──────────────────────────────────────────

# Safely modify a tracked repo file for testing and guarantee restoration.
# Uses a trap to restore the file even if the test fails mid-execution.
# Usage: with_framework_change <file_relative_to_REPO_ROOT> <content_to_append>
# The file is restored automatically on EXIT via trap.
# NOTE: each call overwrites the previous trap; for multiple files use
# with_framework_changes (plural) instead.
with_framework_change() {
    local rel_path="$1"
    local content="$2"
    local full_path="$REPO_ROOT/$rel_path"
    # Save original content
    local backup_file
    backup_file=$(mktemp)
    cp "$full_path" "$backup_file"
    # Set trap to restore (preserves any previous EXIT trap by chaining)
    trap "cp '$backup_file' '$full_path'; rm -f '$backup_file'" EXIT
    # Apply change
    printf '%s' "$content" >> "$full_path"
}

# Safely modify multiple tracked repo files with guaranteed restoration.
# Usage: with_framework_changes <tmpdir_for_backups> <file1> <content1> [<file2> <content2> ...]
# All files are restored on EXIT.
with_framework_changes() {
    local backup_dir="$1"; shift
    mkdir -p "$backup_dir/__fw_backups"
    local restore_cmd=""
    while [[ $# -ge 2 ]]; do
        local rel_path="$1" content="$2"; shift 2
        local full_path="$REPO_ROOT/$rel_path"
        local safe_name
        safe_name=$(echo "$rel_path" | tr '/' '_')
        cp "$full_path" "$backup_dir/__fw_backups/$safe_name"
        restore_cmd+="cp '$backup_dir/__fw_backups/$safe_name' '$full_path'; "
        printf '%s' "$content" >> "$full_path"
    done
    trap "${restore_cmd} rm -rf '$backup_dir'" EXIT
}

# Create a local bare Config Repo with a project template for testing.
# Outputs the bare repo path. The repo contains:
#   templates/<tmpl_name>/project.yml
#   templates/<tmpl_name>/.claude/CLAUDE.md
#   templates/<tmpl_name>/.claude/rules/<rule_file>
#   manifest.yml
# Usage: _create_config_repo_with_template <tmpdir> <tmpl_name> [rule_content]
_create_config_repo_with_template() {
    local tmpdir="$1"
    local tmpl_name="$2"
    local rule_content="${3:-# Default rule}"
    local work_dir="$tmpdir/config-work"
    local bare_dir="$tmpdir/config-repo.git"

    mkdir -p "$work_dir/templates/$tmpl_name/.claude/rules"
    printf 'name: %s\ndescription: test\nrepos: []\n' "$tmpl_name" \
        > "$work_dir/templates/$tmpl_name/project.yml"
    printf '# Test CLAUDE.md for %s\n' "$tmpl_name" \
        > "$work_dir/templates/$tmpl_name/.claude/CLAUDE.md"
    printf '%s\n' "$rule_content" \
        > "$work_dir/templates/$tmpl_name/.claude/rules/team.md"
    cat > "$work_dir/manifest.yml" <<YAML
name: test-config
description: test
packs: []
templates:
  - name: $tmpl_name
    description: test template
YAML
    git -C "$work_dir" init -q
    git -C "$work_dir" add -A
    git -C "$work_dir" commit -q -m "init"
    git init --bare -q "$bare_dir"
    git -C "$work_dir" remote add origin "$bare_dir"
    git -C "$work_dir" push -q origin main 2>/dev/null || \
        git -C "$work_dir" push -q origin master 2>/dev/null
    echo "$bare_dir"
}

# Update a file in an existing Config Repo (push a new commit).
# Usage: _update_config_repo <bare_dir> <file_rel_path> <new_content>
_update_config_repo() {
    local bare_dir="$1"
    local rel_path="$2"
    local new_content="$3"
    local work_dir
    work_dir=$(mktemp -d)
    git clone -q "$bare_dir" "$work_dir"
    mkdir -p "$(dirname "$work_dir/$rel_path")"
    printf '%s\n' "$new_content" > "$work_dir/$rel_path"
    git -C "$work_dir" add -A
    git -C "$work_dir" commit -q -m "update: $rel_path"
    git -C "$work_dir" push -q origin main 2>/dev/null || \
        git -C "$work_dir" push -q origin master 2>/dev/null
    rm -rf "$work_dir"
}

# Get latest commit hash from a bare repo.
# Usage: _get_repo_head <bare_dir>
_get_repo_head() {
    git -C "$1" rev-parse HEAD
}

# ── Project Helpers ──────────────────────────────────────────────────

# Minimal project.yml for tests that only need dry-run + compose assertions
# Usage: minimal_project_yml "<name>"  (no repos, oauth auth, empty ports/env)
minimal_project_yml() {
    local name="${1:-test-proj}"
    cat <<YAML
name: $name
description: "Test project"
auth:
  method: oauth
docker:
  ports: []
  env: {}
repos:
  - path: $CCO_DUMMY_REPO
    name: dummy-repo
YAML
}
