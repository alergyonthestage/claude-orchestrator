#!/usr/bin/env bash
# tests/test_init.sh — cco init command tests (ADR-0026)
#
# The clean `cco init` does two things, run inside a repo:
#   1. ensures the global config (~/.cco/global = $CCO_GLOBAL_DIR) idempotently;
#   2. scaffolds the committed <repo>/.cco/ and registers it in the STATE index.
# Global-only setup elsewhere goes through the init_global helper (a throwaway
# repo); here we exercise the real scaffold by cd-ing into a per-test repo.
#
# Note: the Docker build is skipped (bin/test exports CCO_SKIP_BUILD=1).

# Create a fresh per-test repo dir and echo its path.
_init_repo() {
    local tmpdir="$1" name="${2:-myrepo}"
    local repo="$tmpdir/$name"
    mkdir -p "$repo"
    printf '%s' "$repo"
}

# ── Global-config ensure ─────────────────────────────────────────────

test_init_seeds_global_when_absent() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo; repo=$(_init_repo "$tmpdir" myrepo)
    ( cd "$repo" && run_cco init --name myrepo --lang "English" )
    assert_dir_exists  "$CCO_GLOBAL_DIR/.claude"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/settings.json"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/CLAUDE.md"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/agents/analyst.md"
    assert_file_exists "$CCO_GLOBAL_DIR/.claude/rules/language.md"
}

test_init_global_setup_scripts_to_cco_root() {
    # setup.sh / setup-build.sh / mcp-packages.txt land at the ~/.cco top level.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo; repo=$(_init_repo "$tmpdir" myrepo)
    ( cd "$repo" && run_cco init --name myrepo --lang "English" )
    assert_file_exists "$HOME/.cco/setup-build.sh"
    assert_file_exists "$HOME/.cco/setup.sh"
}

test_init_substitutes_comm_lang_single_value() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo; repo=$(_init_repo "$tmpdir" myrepo)
    ( cd "$repo" && run_cco init --name myrepo --lang "Italian" )
    local lang_file="$CCO_GLOBAL_DIR/.claude/rules/language.md"
    assert_file_contains "$lang_file" "Italian"
    assert_no_placeholder "$lang_file" "{{COMM_LANG}}"
    assert_no_placeholder "$lang_file" "{{DOCS_LANG}}"
    assert_no_placeholder "$lang_file" "{{CODE_LANG}}"
}

test_init_substitutes_three_lang_format() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo; repo=$(_init_repo "$tmpdir" myrepo)
    ( cd "$repo" && run_cco init --name myrepo --lang "Italian:Italian:English" )
    local lang_file="$CCO_GLOBAL_DIR/.claude/rules/language.md"
    assert_no_placeholder "$lang_file" "{{COMM_LANG}}"
    assert_no_placeholder "$lang_file" "{{DOCS_LANG}}"
    assert_no_placeholder "$lang_file" "{{CODE_LANG}}"
}

test_init_global_idempotent_skips_second() {
    # A second init (different repo) must NOT re-seed or clobber edited global config.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo1; repo1=$(_init_repo "$tmpdir" repo-one)
    ( cd "$repo1" && run_cco init --name repo-one --lang "English" )
    # Plant a canary in a user-owned global file
    printf '\n# CANARY\n' >> "$CCO_GLOBAL_DIR/.claude/mcp.json"
    local repo2; repo2=$(_init_repo "$tmpdir" repo-two)
    ( cd "$repo2" && run_cco init --name repo-two --lang "Italian" )
    # Global was left untouched (ensure is a one-time no-op)
    assert_file_contains "$CCO_GLOBAL_DIR/.claude/mcp.json" "# CANARY"
}

test_init_force_reseeds_global() {
    # --force re-seeds the global from defaults (documented reset escape hatch).
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo; repo=$(_init_repo "$tmpdir" myrepo)
    ( cd "$repo" && run_cco init --name myrepo --lang "English" )
    printf '\n# CANARY\n' >> "$CCO_GLOBAL_DIR/.claude/mcp.json"
    local repo2; repo2=$(_init_repo "$tmpdir" myrepo2)
    ( cd "$repo2" && run_cco init --name myrepo2 --force --lang "English" )
    assert_file_not_contains "$CCO_GLOBAL_DIR/.claude/mcp.json" "# CANARY"
}

test_init_emits_no_manifest() {
    # ADR-0012: the new cco init emits no manifest.yml anywhere.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo; repo=$(_init_repo "$tmpdir" myrepo)
    ( cd "$repo" && run_cco init --name myrepo --lang "English" )
    assert_file_not_exists "$HOME/.cco/manifest.yml"
    assert_file_not_exists "$CCO_USER_CONFIG_DIR/manifest.yml"
}

# ── Per-repo scaffold ────────────────────────────────────────────────

test_init_scaffolds_committed_tree() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo; repo=$(_init_repo "$tmpdir" myrepo)
    ( cd "$repo" && run_cco init --name myrepo --lang "English" )
    assert_file_exists "$repo/.cco/project.yml"
    assert_file_exists "$repo/.cco/claude/CLAUDE.md"
    assert_file_exists "$repo/.cco/claude/settings.json"
    assert_file_exists "$repo/.cco/secrets.env.example"
    assert_file_exists "$repo/.cco/.gitignore"
}

# ── cco init --template (instantiate from a named project template) ────

test_init_template_scaffolds_from_named_template() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # A user project-template carrying a distinctive marker.
    run_cco template create custom --project
    echo "# CUSTOM-TEMPLATE-MARKER" >> "$CCO_TEMPLATES_DIR/project/custom/project.yml"

    local repo; repo=$(_init_repo "$tmpdir" app)
    ( cd "$repo" && run_cco init --name app --template custom )

    assert_file_exists "$repo/.cco/project.yml"
    # Scaffolded from the named template (marker survives) with PROJECT_NAME applied.
    assert_file_contains "$repo/.cco/project.yml" "CUSTOM-TEMPLATE-MARKER"
    assert_file_contains "$repo/.cco/project.yml" "name: app"
}

test_init_template_nonexistent_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local repo; repo=$(_init_repo "$tmpdir" app)
    if ( cd "$repo" && run_cco init --name app --template ghost ) 2>/dev/null; then
        echo "ASSERTION FAILED: init --template should fail for a nonexistent template"
        return 1
    fi
}

test_init_template_resolves_custom_vars() {
    # P5-3d: cco init --template resolves arbitrary {{VAR}} placeholders across
    # project.yml AND the whole claude/ tree (not just CLAUDE.md). Non-interactive,
    # an unknown var substitutes its own name.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    run_cco template create custom --project
    printf '\n# region: {{DEPLOY_REGION}}\n' >> "$CCO_TEMPLATES_DIR/project/custom/project.yml"
    mkdir -p "$CCO_TEMPLATES_DIR/project/custom/.claude/rules"
    printf 'team {{TEAM_NAME}} owns this\n' > "$CCO_TEMPLATES_DIR/project/custom/.claude/rules/ownership.md"

    local repo; repo=$(_init_repo "$tmpdir" app)
    ( cd "$repo" && run_cco init --name app --template custom )

    # Custom var in project.yml resolved (no leftover braces).
    assert_no_placeholder "$repo/.cco/project.yml" "{{DEPLOY_REGION}}"
    assert_file_contains "$repo/.cco/project.yml" "region: DEPLOY_REGION"
    # A var in a non-CLAUDE.md file under claude/ is resolved too (new tree scan).
    assert_no_placeholder "$repo/.cco/claude/rules/ownership.md" "{{TEAM_NAME}}"
    assert_file_contains "$repo/.cco/claude/rules/ownership.md" "team TEAM_NAME owns"
}

test_init_project_yml_substituted() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo; repo=$(_init_repo "$tmpdir" myrepo)
    ( cd "$repo" && run_cco init --name acme-app --lang "English" )
    local yml="$repo/.cco/project.yml"
    assert_file_contains "$yml" "name: acme-app"
    assert_no_placeholder "$yml" "{{PROJECT_NAME}}"
    assert_no_placeholder "$yml" "{{DESCRIPTION}}"
}

test_init_claude_md_substituted() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo; repo=$(_init_repo "$tmpdir" myrepo)
    ( cd "$repo" && run_cco init --name acme-app --lang "English" )
    local md="$repo/.cco/claude/CLAUDE.md"
    assert_file_contains "$md" "# Project: acme-app"
    assert_no_placeholder "$md" "{{PROJECT_NAME}}"
}

test_init_no_remaining_placeholders() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo; repo=$(_init_repo "$tmpdir" myrepo)
    ( cd "$repo" && run_cco init --name acme-app --lang "English" )
    local found
    found=$(grep -rE '\{\{[^}]+\}\}' "$repo/.cco" 2>/dev/null || true)
    if [[ -n "$found" ]]; then
        echo "ASSERTION FAILED: unreplaced placeholders in scaffolded .cco/"
        echo "$found" | sed 's/^/  /'
        return 1
    fi
}

test_init_gitignore_excludes_secrets() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo; repo=$(_init_repo "$tmpdir" myrepo)
    ( cd "$repo" && run_cco init --name myrepo --lang "English" )
    assert_file_contains "$repo/.cco/.gitignore" "secrets.env"
    assert_file_contains "$repo/.cco/.gitignore" "!secrets.env.example"
}

test_init_no_internal_files_in_committed_tree() {
    # Internal data (meta/base/source/claude-state/memory) is STATE, never committed.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo; repo=$(_init_repo "$tmpdir" myrepo)
    ( cd "$repo" && run_cco init --name myrepo --lang "English" )
    assert_file_not_exists "$repo/.cco/meta"
    assert_file_not_exists "$repo/.cco/source"
    [[ ! -d "$repo/.cco/base" ]]         || fail ".cco/base/ must not be committed (it is STATE)"
    [[ ! -d "$repo/.cco/claude-state" ]] || fail ".cco/claude-state/ must not be committed (it is STATE)"
    [[ ! -d "$repo/.cco/memory" ]]       || fail "memory/ must not be committed (it is STATE)"
}

test_init_registers_index() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo; repo=$(_init_repo "$tmpdir" myrepo)
    ( cd "$repo" && run_cco init --name acme-app --lang "English" )
    local index="$CCO_STATE_HOME/index"
    assert_file_exists "$index"
    assert_file_contains "$index" "acme-app"
    assert_file_contains "$index" "$repo"
}

test_init_refuses_existing_cco() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo; repo=$(_init_repo "$tmpdir" myrepo)
    ( cd "$repo" && run_cco init --name myrepo --lang "English" )
    if ( cd "$repo" && run_cco init --name myrepo --lang "English" ) 2>/dev/null; then
        echo "ASSERTION FAILED: second init in the same repo should refuse the existing .cco/"
        return 1
    fi
}

test_init_force_overwrites_scaffold() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo; repo=$(_init_repo "$tmpdir" myrepo)
    ( cd "$repo" && run_cco init --name myrepo --lang "English" )
    printf '\n# SCAFFOLD_CANARY\n' >> "$repo/.cco/project.yml"
    ( cd "$repo" && run_cco init --name myrepo --force --lang "English" )
    assert_file_not_contains "$repo/.cco/project.yml" "# SCAFFOLD_CANARY"
}

# ── Name validation (moved from the removed test_project_create.sh) ──

test_init_rejects_uppercase_name() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo; repo=$(_init_repo "$tmpdir" myrepo)
    if ( cd "$repo" && run_cco init --name "MyProject" --lang "English" ) 2>/dev/null; then
        echo "ASSERTION FAILED: should reject an uppercase project name"
        return 1
    fi
}

test_init_rejects_underscore_name() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo; repo=$(_init_repo "$tmpdir" myrepo)
    if ( cd "$repo" && run_cco init --name "my_project" --lang "English" ) 2>/dev/null; then
        echo "ASSERTION FAILED: should reject a name with an underscore"
        return 1
    fi
}

test_init_rejects_reserved_name() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo; repo=$(_init_repo "$tmpdir" myrepo)
    # cd in the parent (this test's own subshell) so run_cco's CCO_OUTPUT propagates.
    cd "$repo"; run_cco init --name "tutorial" --lang "English" || true
    assert_output_contains "reserved"
}

test_init_accepts_valid_name_with_hyphens() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo; repo=$(_init_repo "$tmpdir" myrepo)
    ( cd "$repo" && run_cco init --name "my-valid-project-123" --lang "English" )
    assert_file_contains "$repo/.cco/project.yml" "name: my-valid-project-123"
}
