#!/usr/bin/env bash
# tests/helpers.sh — shared setup, teardown, and assertion helpers
# Sourced by bin/test before running any test file.
# All functions are available in every test function's subshell context.

# ── Environment Setup ─────────────────────────────────────────────────

# Configure CCO env vars to point into $tmpdir, not the real global/projects
# Usage: setup_cco_env "$tmpdir"
setup_cco_env() {
    local tmpdir="$1"
    export CCO_PROJECTS_DIR="$tmpdir/projects"
    export CCO_GLOBAL_DIR="$tmpdir/global"
    mkdir -p "$CCO_PROJECTS_DIR"
    mkdir -p "$CCO_GLOBAL_DIR"
}

# Copy defaults/global/.claude into tmpdir/global/.claude (simulates cco init)
# Usage: setup_global_from_defaults "$tmpdir"
setup_global_from_defaults() {
    local tmpdir="$1"
    mkdir -p "$tmpdir/global"
    cp -r "$REPO_ROOT/defaults/global/.claude" "$tmpdir/global/.claude"
    mkdir -p "$tmpdir/global/packs"
}

# Create a minimal project directory with the given project.yml content.
# Also creates .claude/ and memory/ directories.
# Usage: create_project "$tmpdir" "my-project" "$yml_content"
create_project() {
    local tmpdir="$1"
    local name="$2"
    local yml_content="$3"
    local project_dir="$tmpdir/projects/$name"
    mkdir -p "$project_dir/.claude"
    mkdir -p "$project_dir/memory"
    printf '%s\n' "$yml_content" > "$project_dir/project.yml"
}

# Create a pack definition in global/packs/<name>/pack.yml
# Usage: create_pack "$tmpdir" "pack-name" "$yml_content"
create_pack() {
    local tmpdir="$1"
    local name="$2"
    local yml_content="$3"
    local pack_dir="$tmpdir/global/packs/$name"
    mkdir -p "$pack_dir"
    printf '%s\n' "$yml_content" > "$pack_dir/pack.yml"
}

# Run bin/cco with CCO env vars set.
# Captures stdout+stderr into CCO_OUTPUT. Returns exit code.
# Usage: run_cco [args...]
run_cco() {
    CCO_OUTPUT=$(
        CCO_PROJECTS_DIR="$CCO_PROJECTS_DIR" \
        CCO_GLOBAL_DIR="$CCO_GLOBAL_DIR" \
        bash "$REPO_ROOT/bin/cco" "$@" 2>&1
    ) || return $?
}

# ── Assertions ────────────────────────────────────────────────────────

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
repos: []
YAML
}
