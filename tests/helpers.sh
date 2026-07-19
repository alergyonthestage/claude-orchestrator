#!/usr/bin/env bash
# tests/helpers.sh — shared setup, teardown, and assertion helpers
# Sourced by bin/test before running any test file.
# All functions are available in every test function's subshell context.

# ── Environment Setup ─────────────────────────────────────────────────

# Configure CCO env vars to point into $tmpdir, not the real global/projects
# Usage: setup_cco_env "$tmpdir"
setup_cco_env() {
    local tmpdir="$1"
    # Redirect HOME so the CONFIG bucket (~/.cco) and every HOME-anchored
    # resolver land inside the tmpdir, not the developer's real home. After
    # Commit B, cco start/new read global config + secrets from ~/.cco and
    # session state from the STATE/CACHE buckets below.
    export HOME="$tmpdir/home"
    mkdir -p "$HOME"
    # Hermetic git identity in the redirected HOME: the suite has ~12
    # git-committing tests that previously relied on the ambient ~/.gitconfig.
    # protocol.file.allow=always is required for the local file:// remotes the
    # pack/project install/publish tests use.
    cat > "$HOME/.gitconfig" <<'GITCFG'
[user]
	name = cco-test
	email = cco-test@example.com
[protocol "file"]
	allow = always
GITCFG

    # Legacy-vault pointer: the pre-decentralized user-config store that
    # `cco init --migrate` reads from, and the runtime root for the internal
    # tutorial/config-editor sessions. It is NOT the flat-store home anymore (F1).
    export CCO_USER_CONFIG_DIR="$tmpdir/user-config"
    # Global config home is the flat ~/.cco/.claude (ADR-0028; = $HOME/.cco/.claude,
    # since HOME is redirected into $tmpdir above). bin/cco, the update/clean engines,
    # and check_global resolve it via _cco_global_claude_dir() from $HOME — there is
    # no CCO_GLOBAL_DIR override anymore (retired). Fixtures use $HOME/.cco/.claude.
    # Personal flat stores in their decentralized homes (F1; ADR-0016 D7/D8):
    # packs/templates in the CONFIG bucket (~/.cco), llms content+cache-state in
    # CACHE ($tmpdir/cache = CCO_CACHE_HOME below). These match what bin/cco
    # derives from the bucket resolvers, so migration writes and runtime reads
    # land in the same place (the F1 split-brain is closed).
    export CCO_PACKS_DIR="$tmpdir/home/.cco/packs"
    export CCO_TEMPLATES_DIR="$tmpdir/home/.cco/templates"
    export CCO_LLMS_DIR="$tmpdir/cache/llms"
    export CCO_DUMMY_REPO="$tmpdir/dummy-repo"
    # XDG 4-bucket overrides (decentralized config). CCO_ALLOW_HOST_RESOLVE
    # bypasses the in-container guard so the host-side resolver runs in test/dev.
    export CCO_DATA_HOME="$tmpdir/data"
    export CCO_STATE_HOME="$tmpdir/state"
    export CCO_CACHE_HOME="$tmpdir/cache"
    export CCO_ALLOW_HOST_RESOLVE=1
    mkdir -p "$CCO_USER_CONFIG_DIR" \
             "$CCO_PACKS_DIR" "$CCO_TEMPLATES_DIR" "$CCO_LLMS_DIR" "$CCO_DUMMY_REPO"
    # Seed the STATE index for the new-schema fixture (minimal_project_yml uses
    # the logical name "dummy-repo"). Legacy-schema fixtures (inline `- path:`)
    # are unaffected — they resolve via the transitional legacy path, not the
    # index.
    seed_index_path "dummy-repo" "$CCO_DUMMY_REPO"
}

# Decentralized STATE/CONFIG homes for the update-engine artifacts (H6 / the
# global .cco/meta decompose, ADR-0013 D4). The test env pins CCO_STATE_HOME
# and HOME, so these resolve deterministically without sourcing paths.sh.
# Project <id> = the project.yml `name:` (the dir basename in these fixtures).
state_global_meta()  { printf '%s' "$CCO_STATE_HOME/global/update/meta"; }
state_global_base()  { printf '%s' "$CCO_STATE_HOME/global/update/base"; }
state_project_meta() { printf '%s' "$CCO_STATE_HOME/projects/$1/update/meta"; }
state_project_base() { printf '%s' "$CCO_STATE_HOME/projects/$1/update/base"; }
# Generated docker-compose.yml → STATE, keyed by project name (mirrors cmd-start's
# session_state_dir; what `cco clean --generated` removes). $1 = project name.
state_project_compose() { printf '%s' "$CCO_STATE_HOME/projects/$1/docker-compose.yml"; }

# Decode the injected Level-A session context (ADR-0042) from a generated
# docker-compose.yml. Replaces the retired workspace.yml file as the parity
# surface for tests. $1 = compose file path. Echoes the decoded block (empty if
# the env var is absent).
decode_session_context()  { grep -oE 'CCO_SESSION_CONTEXT=[A-Za-z0-9+/=]+'  "$1" 2>/dev/null | head -1 | cut -d= -f2- | base64 -d 2>/dev/null; }
decode_subagent_context() { grep -oE 'CCO_SUBAGENT_CONTEXT=[A-Za-z0-9+/=]+' "$1" 2>/dev/null | head -1 | cut -d= -f2- | base64 -d 2>/dev/null; }
state_pack_meta()    { printf '%s' "$CCO_STATE_HOME/packs/$1/update/meta"; }
state_pack_base()    { printf '%s' "$CCO_STATE_HOME/packs/$1/update/base"; }
# Managed runtime overlays → CACHE, keyed by project name (mirrors the production
# helper _cco_project_cache_managed; ADR-0005 / Commit B/T8). $1 = project name.
cache_project_managed() { printf '%s' "$CCO_CACHE_HOME/projects/$1/managed"; }
# Install-provenance `source` → DATA, identity-keyed (ADR-0022 D1). The file
# holds the machine-agnostic upstream coordinate only (url/ref/resource); the
# install commit + dates live in the STATE /update meta above.
data_pack_source()     { printf '%s' "$CCO_DATA_HOME/packs/$1/source"; }
data_project_source()  { printf '%s' "$CCO_DATA_HOME/projects/$1/source"; }
data_template_source() { printf '%s' "$CCO_DATA_HOME/templates/$1/source"; }
cco_languages_file() { printf '%s' "$HOME/.cco/languages"; }
cco_last_seen_file() { printf '%s' "$CCO_STATE_HOME/last_seen"; }
cco_last_read_file() { printf '%s' "$CCO_STATE_HOME/last_read"; }

# Seed a logical name → absolute path binding in the STATE index (the
# decentralized-config materialization of a repo/mount coordinate). Uses the
# real index API so the on-disk format matches production exactly.
# Under per-project name scoping (ADR-0051): with a <project> the binding is
# scoped (project_paths); without one it lands in the unscoped escape-hatch
# bucket, which _index_get_path <anyproject> <name> still resolves as a fallback —
# so the many legacy 2-arg fixtures keep resolving their members globally.
# Usage: seed_index_path <name> <abs_path> [<project>]
seed_index_path() {
    local name="$1" path="$2" project="${3:-}"
    (
        source "$REPO_ROOT/lib/colors.sh"
        source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/index.sh"
        if [[ -n "$project" ]]; then _index_set_path "$project" "$name" "$path"
        else _index_set_unscoped "$name" "$path"; fi
    )
}

# Seed a project → member-repo-names binding in the STATE index (space-separated,
# the canonical format). Usage: index_set_project_repos <project> <repo> [<repo>...]
index_set_project_repos() {
    local proj="$1"; shift
    (
        source "$REPO_ROOT/lib/colors.sh"
        source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/paths.sh"
        source "$REPO_ROOT/lib/index.sh"
        _index_set_project_repos "$proj" "$@"
    )
}

# Seed the decentralized global config (~/.cco/.claude) from the framework
# defaults — simulates `cco init`'s global-ensure. Resolves to $HOME/.cco/.claude
# in the test env (flat, ADR-0028), which is what check_global, cco start/new, and
# the update/clean engines read (design §2.3). Usage: <tmpdir>
setup_global_from_defaults() {
    local tmpdir="$1"
    mkdir -p "$HOME/.cco"
    cp -r "$REPO_ROOT/defaults/global/.claude" "$HOME/.cco/.claude"
    mkdir -p "$CCO_PACKS_DIR"
}

# Create a minimal decentralized project: a host repo with a committed
# <repo>/.cco/ (project.yml + claude/) + STATE index seed (paths: <name> -> host,
# projects: <name> -> <name>). This is the only layout cco reads (P5 — the central
# $PROJECTS_DIR layout is gone). `cco start <name>` resolves the host via the
# index; cwd-first resolves it via .cco/project.yml. Use host_cco_dir to target
# the committed config from a test.
# Usage: create_project "$tmpdir" "my-project" "$yml_content"
create_project() {
    local tmpdir="$1"
    local name="$2"
    local yml_content="$3"
    local host="$tmpdir/repos/$name"
    mkdir -p "$host/.cco/claude"
    printf '%s\n' "$yml_content" > "$host/.cco/project.yml"
    # Bind the project's own repo SCOPED to the project (ADR-0051) — production
    # `cco init`/`cco resolve` always write per-project bindings, never unscoped;
    # a scoped seed keeps the helper faithful (e.g. `cco forget` removes the whole
    # project_paths block, so an unscoped seed would leak past deregistration).
    seed_index_path "$name" "$host" "$name"
    index_set_project_repos "$name" "$name"
}

# Absolute path to a project's decentralized host .cco/ dir — the only layout
# cco reads (P5). Holds project.yml, claude/, mcp.json, setup.sh,
# mcp-packages.txt, secrets.env. Tests that pre-create config files for cco to
# read must target this dir. Usage: host_cco_dir "$tmpdir" "<name>"
host_cco_dir() { printf '%s' "$1/repos/$2/.cco"; }

# Create a pack definition in packs/<name>/pack.yml
# Usage: create_pack "$tmpdir" "pack-name" "$yml_content"
create_pack() {
    local tmpdir="$1"   # kept for signature compatibility; PACKS_DIR is now CONFIG
    local name="$2"
    local yml_content="$3"
    local pack_dir="$CCO_PACKS_DIR/$name"   # ~/.cco/packs (F1), not user-config
    mkdir -p "$pack_dir"
    printf '%s\n' "$yml_content" > "$pack_dir/pack.yml"
}

# Run `cco init` for GLOBAL setup only, isolating the per-repo scaffold.
#
# ADR-0026 makes `cco init` do TWO things: ensure the global config AND scaffold
# the current repo's <repo>/.cco/. Tests that only need global config must not
# scaffold into the cco repo root (where the suite runs). This helper runs
# `cco init` inside a throwaway per-test repo so the scaffold lands harmlessly,
# while ~/.cco/.claude is ensured. Forwards args (e.g. --lang) and sets CCO_OUTPUT
# exactly like run_cco. Usage: init_global "$tmpdir" [init-args...]
init_global() {
    local tmpdir="$1"; shift
    # Fresh throwaway repo with a unique valid name per call, so repeated
    # init_global invocations in one test never collide on the scaffold-exists
    # refusal or the index name-uniqueness guard (the scaffold side-effect is
    # irrelevant to global-setup tests; only ~/.cco/.claude matters).
    _CCO_IG_N=$(( ${_CCO_IG_N:-0} + 1 ))
    local name="ig-$_CCO_IG_N"
    local d="$tmpdir/.ig/$name"
    mkdir -p "$d"
    local _prev="$PWD"
    cd "$d" || return 1
    run_cco init --name "$name" "$@"
    local rc=$?
    cd "$_prev" 2>/dev/null || true
    return $rc
}

# Run bin/cco with CCO env vars set.
# Captures stdout+stderr into CCO_OUTPUT. Returns exit code.
# For dry-run commands, automatically extracts DRY_RUN_DIR from output.
# Usage: run_cco [args...]
run_cco() {
    DRY_RUN_DIR=""
    CCO_OUTPUT=$(
        CCO_USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR" \
        CCO_PACKS_DIR="$CCO_PACKS_DIR" \
        CCO_TEMPLATES_DIR="$CCO_TEMPLATES_DIR" \
        CCO_LLMS_DIR="$CCO_LLMS_DIR" \
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
# Uses -e to safely handle patterns starting with '-'. Uses a here-string (not
# `echo | grep`): under `set -o pipefail`, grep exiting early on a match makes the
# upstream echo take SIGPIPE when the output exceeds the 64KB pipe buffer, which
# pipefail then reports as a failed pipeline — a false negative for large outputs
# (e.g. paging an 85KB doc). A here-string has no pipe, so grep's status is direct.
assert_output_contains() {
    local pattern="$1"
    local msg="${2:-Expected output to contain: $pattern}"
    if ! grep -qFe "$pattern" <<< "${CCO_OUTPUT:-}"; then
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
    # Here-string (not `echo | grep`) — see assert_output_contains for why.
    if grep -qFe "$pattern" <<< "${CCO_OUTPUT:-}"; then
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

# Copy the framework asset roots (defaults/ templates/ migrations/ changelog.yml)
# into a throwaway sandbox and point cco at it via CCO_FRAMEWORK_ROOT. Tests that
# simulate a framework update (a new default rule, a changed base template, a new
# migration, a changelog entry) mutate the SANDBOX copy — never the tracked repo
# tree. This is hermetic and concurrency/abort-safe: a trap- or git-checkout-based
# restore of a tracked file races under concurrent runs and is skipped on Ctrl-C,
# corrupting changelog.yml / the base template (F5). Idempotent and per-test
# (each test runs in its own subshell, so the export never leaks).
sandbox_framework() {
    [[ -n "${CCO_FRAMEWORK_ROOT:-}" && -d "${CCO_FRAMEWORK_ROOT:-}" ]] && return 0
    local fw; fw=$(mktemp -d)
    cp -r "$REPO_ROOT/defaults"      "$fw/defaults"
    cp -r "$REPO_ROOT/templates"     "$fw/templates"
    cp -r "$REPO_ROOT/migrations"    "$fw/migrations"
    cp    "$REPO_ROOT/changelog.yml" "$fw/changelog.yml"
    export CCO_FRAMEWORK_ROOT="$fw"
}

# Append to a "shipped" framework file for testing, hermetically. The change
# lands in the CCO_FRAMEWORK_ROOT sandbox (created on first use) — the tracked
# repo file is never touched, so no restore is needed.
# Usage: with_framework_change <file_relative_to_framework_root> <content_to_append>
with_framework_change() {
    local rel_path="$1"
    local content="$2"
    sandbox_framework
    printf '%s' "$content" >> "$CCO_FRAMEWORK_ROOT/$rel_path"
}

# Append to several framework files in one call (same hermetic sandbox model).
# The legacy first argument (a backup dir) is accepted for signature compatibility
# but ignored — no backups are taken because nothing tracked is mutated.
# Usage: with_framework_changes <ignored> <file1> <content1> [<file2> <content2> ...]
with_framework_changes() {
    shift  # discard the legacy backup-dir argument
    sandbox_framework
    while [[ $# -ge 2 ]]; do
        local rel_path="$1" content="$2"; shift 2
        printf '%s' "$content" >> "$CCO_FRAMEWORK_ROOT/$rel_path"
    done
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

# ── Container-operator lane (RC-17) ───────────────────────────────────
#
# The suite is structurally blind to container life. Three ad-hoc mechanisms
# existed (`_op_cco`/`_op_seed`, `_as_operator`, the `_ps_probe` stubs) and none
# models the one fact that DEFINES an in-container session: the STATE index holds
# a HOST path that does not exist, and the member is reachable only at the flat
# bind target <workdir>/<name>. A verb that existence-tests the index path there
# mislabels a perfectly mounted repo as missing — the RC-2 class.
#
# This lane is a FIXTURE + ASSERTION VOCABULARY layered on setup_cco_env; it is
# not a new runner and not a new tier, so lane tests stay in their subject-matter
# files and inside the single `bin/test` baseline. Three layers:
#   context   — _lane_operator_exports / setup_operator_session
#   topology  — operator_mount_member / operator_mount_unit
#   assertion — assert_rc / assert_refused / assert_gate_allows /
#               assert_index_path / assert_projectyml_member
# plus the static ban on negative-only rc assertions in test_invariants.sh.
#
# Design: docs/maintainers/configuration/agent-cco-access/e2e-review/
#         fix-design-v2/01-test-lane.md

# Emit the COMPLETE container-operator env as `export`/`unset` statements, to be
# eval'd either into the current shell (setup_operator_session) or into a
# subshell (assert_gate_allows, lane_cco, lane_cco_seeded). SINGLE SOURCE OF
# TRUTH: there is exactly one definition of "what a lane operator session is", so
# the consumers cannot drift — two vocabularies for one context is how the third
# one (`_ps_probe`) got invented.
#
# Three groups, all load-bearing:
#  (a) THE PREDICATE. _cco_container_operator (lib/paths.sh) needs the explicit
#      flag AND three ABSOLUTE bucket paths. Never stubbed: a stub cannot
#      regress-test the predicate, and a stubbed test cannot reach the dispatcher.
#  (b) THE GATE PIN. CCO_STORE_ELEVATED=1. repo|extra-mount rename (and every
#      other _cco_verb_touches_store verb) would otherwise re-exec the real setuid
#      helper when one is present — which it IS in the self-dev container — and
#      the TRUSTED :ro session descriptor then overrides the simulated level.
#      Measured: without the pin, `CCO_CCO_ACCESS=edit-project … repo rename
#      --help` returns rc=2 quoting the LIVE session's level. Consequence: the
#      lane never exercises the trampoline itself (that is
#      tests/test_privilege_boundary.sh's job).
#  (c) THE SANITISER. Every ambient session variable that steers a decision.
#      bin/test unsets these globally, but a helper that RELIES on the runner is
#      wrong the moment it is sourced from any other context — which is exactly
#      the `_op_cco` leak this lane supersedes (it never unset CCO_ACCESS_TRIPLE,
#      so inside a live cco session the ambient triple won). Mirror bin/test's list.
#
# PROJECT_NAME is UNSET, not left alone, when no project is given: leaving it
# alone lets a live session's PROJECT_NAME through, and with it every
# _env_is_current_project decision. Same reasoning for CCO_CONFIG_TARGETS,
# CCO_PROJECT_PACKS and CCO_PROJECT_LLMS, which are pinned deterministically.
# Optional caller vars (the `_op_seed` precedent): OP_TRIPLE → CCO_ACCESS_TRIPLE,
# OP_TARGETS → CCO_CONFIG_TARGETS, OP_SHP → CCO_SHOW_HOST_PATHS.
# Usage: eval "$(_lane_operator_exports <level> [<project>])"
_lane_operator_exports() {
    local level="$1" project="${2:-}"
    cat <<EOF
export CCO_IN_CONTAINER=1 CCO_CONTAINER_OPERATOR=1
export CCO_STORE_ELEVATED=1
export CCO_CCO_ACCESS='$level'
export CCO_SHOW_HOST_PATHS='${OP_SHP:-true}'
export CCO_CONFIG_TARGETS='${OP_TARGETS:-}'
export CCO_PROJECT_PACKS='' CCO_PROJECT_LLMS=''
EOF
    # CCO_SESSION_CONTEXT: inert while operator mode is ON, but if a future change
    # ever flips the predicate off it makes bin/cco refuse EVERY invocation (exit 2).
    printf 'unset CCO_SESSION_CONTEXT CCO_SUBAGENT_CONTEXT CCO_CLAUDE_ACCESS CCO_CONFIG_DIR || true\n'
    if [[ -n "$project" ]]; then printf "export PROJECT_NAME='%s'\n" "$project"
    else                         printf 'unset PROJECT_NAME || true\n'; fi
    # Deterministic triple: explicit when asked, otherwise ABSENT so _env_triple
    # derives it from the preset. Never inherited from an ambient session.
    if [[ -n "${OP_TRIPLE:-}" ]]; then printf "export CCO_ACCESS_TRIPLE='%s'\n" "$OP_TRIPLE"
    else                               printf 'unset CCO_ACCESS_TRIPLE || true\n'; fi
}

# Declare the current shell to be a container-operator session — for real, not by
# stubbing the predicate. Single responsibility: it never creates fixtures and
# never runs cco.
# PRECONDITION: setup_cco_env must have run (it owns HOME + CCO_{DATA,STATE,CACHE}_HOME).
# Usage: setup_operator_session <tmpdir> [<level>] [<project>]
setup_operator_session() {
    local tmpdir="$1" level="${2:-read-project}" project="${3:-}"
    if [[ "${CCO_STATE_HOME:-}" != /* ]]; then
        fail "setup_operator_session requires setup_cco_env first (CCO_STATE_HOME is not absolute)"
        return 1
    fi
    # The buckets are MOUNTS in production, so the resolvers deliberately SKIP
    # _cco_ensure_dir under operator mode (`cco start` creates them host-side).
    # Omitting this mkdir yields `mktemp: failed to create file via template
    # …/state/index.XXXXXX` and a SILENTLY EMPTY index — which would make every
    # lane test vacuous. Pinned by test_operator_lane_predicate_is_real.
    mkdir -p "$CCO_DATA_HOME" "$CCO_STATE_HOME" "$CCO_CACHE_HOME"
    # The flat WORKDIR: `cco start` bind-mounts every member at <workdir>/<name>.
    export CCO_WORKDIR="$tmpdir/workspace"
    mkdir -p "$CCO_WORKDIR"
    eval "$(_lane_operator_exports "$level" "$project")"
    # NOTE: setup_cco_env also exports CCO_ALLOW_HOST_RESOLVE=1, which _cco_resolver_guard
    # treats as equivalent to operator mode — so it changes no behaviour under test, but a
    # future fix keying off the GUARD (rather than the predicate) would be invisible here.
    return 0   # never let the last command's status leak under `set -e`
}

# Bind <name> in <project> to a HOST-shaped path that is deliberately ABSENT, and
# create the bind TARGET at $CCO_WORKDIR/<name>. This is the single fixture that
# makes the RC-2 class reproducible without Docker. Echoes the mount path.
# Usage: operator_mount_member <project> <name> [<host_path>]
operator_mount_member() {
    local project="$1" name="$2"
    # Absent on every runner: Linux CI, the self-dev container, a macOS dev host
    # (no such user). Host-SHAPED so failure messages read like the real defect.
    local host_path="${3:-/Users/cco-e2e/code/$name}"
    if [[ -e "$host_path" ]]; then
        # Loud, never silent: if a runner ever HAS this path the topology inverts
        # and every lane test built on it becomes meaningless.
        fail "lane fixture broken: $host_path exists on this runner — the operator topology requires an ABSENT host path" >&2
        return 1
    fi
    local mnt="$CCO_WORKDIR/$name"
    mkdir -p "$mnt"
    seed_index_path "$name" "$host_path" "$project"   # scoped binding (ADR-0051)
    printf '%s\n' "$mnt"
}

# Companion: a member that also HOSTS the project's committed config, so cwd-first
# verbs (_resolve_find_unit_dir) resolve from the mount. Composes, never duplicates.
# Usage: operator_mount_unit <project> <name> [<host_path>]
operator_mount_unit() {
    local project="$1" name="$2" host_path="${3:-}"
    local mnt
    mnt=$(operator_mount_member "$project" "$name" ${host_path:+"$host_path"}) || return 1
    mkdir -p "$mnt/.cco"
    printf 'name: %s\nrepos:\n  - name: %s\n' "$project" "$name" > "$mnt/.cco/project.yml"
    index_set_project_repos "$project" "$name"
    printf '%s\n' "$mnt"
}

# Read the scoped index through the REAL index API (subshell-sourced, like the
# seeders) — an effect assertion must go through the same door production uses.
# Usage: _lane_index_get <project> <name>
_lane_index_get() {
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
      source "$REPO_ROOT/lib/paths.sh";  source "$REPO_ROOT/lib/index.sh"
      _index_get_path "$1" "$2" )
}

# Read a project.yml list section through the REAL YAML API (lib/rename.sh).
# Usage: _lane_yaml_has_ref <yml> <section> <name>
_lane_yaml_has_ref() {
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
      source "$REPO_ROOT/lib/paths.sh";  source "$REPO_ROOT/lib/rename.sh"
      _yaml_list_has_ref "$1" "$2" "$3" )
}

# ── Lane assertion vocabulary ─────────────────────────────────────────
# Each helper replaces an idiom that can pass vacuously. The rule (RC-17): a
# container-operator test asserts an OUTCOME — an exact rc plus an observable
# state change read back through the real API — or an EXPLICIT refusal. Never
# "anything but 2".

# An EXACT exit code, stated positively. `run_cco` returns cco's rc, so a lane
# test captures it as:  local rc=0; run_cco repo rename a b -y || rc=$?
# Usage: assert_rc <expected> <actual> [<label>]
assert_rc() {
    local expected="$1" actual="$2" label="${3:-cco}"
    [[ "$actual" -eq "$expected" ]] && return 0
    fail "$label: expected rc=$expected, got rc=$actual: ${CCO_OUTPUT:-}"
    return 1
}

# A policy refusal: exit 2, never silent, and it must NAME the reason (B6).
# Generalises test_operator_shim.sh's private _b6_assert into shared vocabulary.
# Usage: assert_refused <rc> <output> <reason-substring>
assert_refused() {
    local rc="$1" out="$2" reason="$3"
    [[ "$rc" -eq 2 ]]      || { fail "expected a policy refusal (exit 2), got rc=$rc: $out"; return 1; }
    [[ -n "$out" ]]        || { fail "an exit-2 refusal must never be silent (B6)"; return 1; }
    [[ "$out" == *"$reason"* ]] \
        || { fail "exit-2 refusal should state the reason '$reason', got: $out"; return 1; }
    return 0
}

# THE replacement for the banned negative-only rc idiom (invariant 11). Asks ONE
# question — does the gate ADMIT this verb at this level — with a POSITIVE success
# signal, independent of cwd, store and mounts. (Spelled out in prose rather than
# written literally: the invariant scans the whole tests/ tree, this file
# included, and it may not exempt the lane that defines it.)
#
# SELF-CONTAINED BY CONSTRUCTION: it establishes the FULL operator env in its own
# subshell over its own throwaway buckets, and inherits NONE of it from the
# caller. A version that sets one variable and inherits the rest is measurably
# vacuous — it returns rc=0 + usage at EVERY level, making the <level> argument
# decorative. This is also why it does not depend on setup_operator_session:
# test_operator_shim.sh has no setup_cco_env to build on, and a one-shot gate
# probe has a genuinely different lifetime from a persistent lane fixture.
#
# "Inherits NONE of it" includes the three OP_* knobs _lane_operator_exports reads
# from its caller. They are honoured by the lane RUNNERS on purpose (the _op_seed
# precedent), but a gate probe that silently picked up an OP_TARGETS left over from
# an earlier lane_cco_seeded call in the same test function would be answering a
# different question than the one its arguments state — so they are cleared here,
# and the claim above is true by construction rather than by call-site discipline.
#
# Probe: `<verb> --help`. The shim classifies on <cmd> <sub> BEFORE dispatch, so
# the gate runs; the verb body then short-circuits on --help and returns 0. The
# usage-shape check is load-bearing: a verb with no --help handler must FAIL here
# rather than pass vacuously — that is the very class this lane exists to kill.
# Usage: assert_gate_allows <level> <verb> [<subverb>...]
assert_gate_allows() {
    local level="$1"; shift
    local out rc=0 tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/data" "$tmp/state" "$tmp/cache" "$tmp/home"
    out=$(
        export CCO_DATA_HOME="$tmp/data" CCO_STATE_HOME="$tmp/state" \
               CCO_CACHE_HOME="$tmp/cache" HOME="$tmp/home"
        unset OP_TRIPLE OP_TARGETS OP_SHP || true
        eval "$(_lane_operator_exports "$level" "")"
        bash "$REPO_ROOT/bin/cco" "$@" --help 2>&1
    ) || rc=$?
    rm -rf "$tmp"
    [[ $rc -eq 0 ]] \
        || { fail "gate must admit 'cco $*' at $level, got rc=$rc: $out"; return 1; }
    [[ "$out" == *Usage:* ]] \
        || { fail "'cco $* --help' printed no usage — the probe is vacuous: $out"; return 1; }
    return 0
}

# Read a rename's index half back through the real API.
# Usage: assert_index_path <project> <name> <expected-path>
assert_index_path() {
    local got; got=$(_lane_index_get "$1" "$2")
    [[ "$got" == "$3" ]] || { fail "index [$1] $2 → '$got', expected '$3'"; return 1; }
    return 0
}

# Read the OTHER half of a rename's effect back through the real YAML API. The
# index and project.yml are two independent stores that a rename must keep
# consistent; asserting only the index certifies a HALF-APPLY (measured: a
# minimal probe-the-mount fix returns rc=0 "✓ Renamed", re-keys the index, and
# leaves project.yml untouched with the commit/push warning silently suppressed).
# Usage: assert_projectyml_member <yml> <section> <name> [present|absent]
assert_projectyml_member() {
    local yml="$1" section="$2" name="$3" mode="${4:-present}"
    [[ -f "$yml" ]] || { fail "no project.yml at $yml"; return 1; }
    if _lane_yaml_has_ref "$yml" "$section" "$name"; then
        [[ "$mode" == present ]] || { fail "$yml: $section[] must NOT list '$name'"; return 1; }
    else
        [[ "$mode" == absent ]]  || { fail "$yml: $section[] must list '$name'"; return 1; }
    fi
    return 0
}

# ── Lane runners (supersede test_operator_shim.sh's _op_cco/_op_seed) ──
# One vocabulary for one context (D-M8/Q-13). Both build their env from
# _lane_operator_exports, so the missing-CCO_ACCESS_TRIPLE-unset latent bug in
# the former _op_cco cannot recur. Both capture stdout+stderr → OP_OUT and the
# exit code → OP_RC, and always return 0 so the caller asserts explicitly.

# Throwaway (unseeded) store: the shim classifies before any bucket use, so this
# is the right shape for pure gate questions.
# Usage: lane_cco <level> <argv...>
lane_cco() {
    local level="$1"; shift
    local tmp; tmp=$(mktemp -d)
    OP_OUT=$(
        export CCO_DATA_HOME="$tmp/data" CCO_STATE_HOME="$tmp/state" \
               CCO_CACHE_HOME="$tmp/cache" HOME="$tmp/home"
        eval "$(_lane_operator_exports "$level" "")"
        mkdir -p "$HOME"
        bash "$REPO_ROOT/bin/cco" "$@" 2>&1
    )
    OP_RC=$?
    rm -rf "$tmp"
    return 0
}

# SEEDED throwaway store so store-touching gates can resolve real resources:
# projects `alpha` + `beta` (each its own member repo) and a pack `p1`. Seeds via
# the real index API so the on-disk format matches production. $2 is the current
# PROJECT_NAME (may be `config-editor`). Honors OP_TARGETS / OP_SHP / OP_TRIPLE.
# Usage: lane_cco_seeded <level> <current-project> <argv...>
lane_cco_seeded() {
    local level="$1" cur="$2"; shift 2
    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/home/.cco/packs/p1" "$tmp/state" "$tmp/data" "$tmp/cache" \
             "$tmp/repos/alpha" "$tmp/repos/beta"
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
      source "$REPO_ROOT/lib/paths.sh";  source "$REPO_ROOT/lib/index.sh"
      # CCO_ALLOW_HOST_RESOLVE=1: seeding writes the index host-side; inside a
      # session container the anti-in-container guard (ADR-0007) otherwise refuses
      # index writes (mirrors setup_cco_env). No-op on the host.
      export CCO_STATE_HOME="$tmp/state" CCO_ALLOW_HOST_RESOLVE=1
      _index_set_path alpha alpha "$tmp/repos/alpha"; _index_set_project_repos alpha alpha
      _index_set_path beta  beta  "$tmp/repos/beta";  _index_set_project_repos beta  beta
    ) >/dev/null 2>&1
    OP_OUT=$(
        export CCO_DATA_HOME="$tmp/data" CCO_STATE_HOME="$tmp/state" \
               CCO_CACHE_HOME="$tmp/cache" HOME="$tmp/home"
        eval "$(_lane_operator_exports "$level" "$cur")"
        bash "$REPO_ROOT/bin/cco" "$@" 2>&1
    )
    OP_RC=$?
    rm -rf "$tmp"
    return 0
}

# ── ADR-0047 boundary seam (D-M8/Q-14) ────────────────────────────────
# Hermetically model the privilege boundary's ERRNO — not its mechanism. `chmod
# 000` on a bucket ancestor makes the store unreadable for a normal uid, which is
# the EACCES a `read-project` agent gets from the cco-svc-owned 0700 root. It is
# NOT the setuid trampoline (pinned off by CCO_STORE_ELEVATED=1) and it is NOT a
# substitute for the e2e gate — see 01-test-lane.md §5.3.
#
# MANDATORY self-check: root bypasses mode bits entirely, so a run as uid 0 would
# observe "no boundary" and certify a green that means nothing. That is precisely
# the false-green class this lane closes, so it FAILS LOUDLY rather than skipping
# silently. Usage: lane_seal_boundary <dir> / lane_unseal_boundary <dir>
lane_seal_boundary() {
    local dir="$1"
    if [[ "$(id -u)" -eq 0 ]]; then
        fail "boundary seam requires a non-root uid: root bypasses mode bits, so this test would pass vacuously (RC-17). Run the suite as a normal user."
        return 1
    fi
    [[ -d "$dir" ]] || { fail "boundary seam: no such directory: $dir"; return 1; }
    chmod 000 "$dir"
}

lane_unseal_boundary() {
    chmod 700 "$1" 2>/dev/null || true
    return 0
}

# Minimal project.yml for tests that only need dry-run + compose assertions.
# New (decentralized) schema: repos are logical names only — the absolute path
# for "dummy-repo" lives in the STATE index, seeded by setup_cco_env.
# Usage: minimal_project_yml "<name>"  (oauth auth, empty ports/env)
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
  - name: dummy-repo
YAML
}
