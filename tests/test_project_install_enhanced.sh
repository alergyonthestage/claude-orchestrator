#!/usr/bin/env bash
# tests/test_project_install_enhanced.sh — enhanced project install tests
#
# Tests auto-install of packs from Config Repo during project install.

# ── Helpers ─────────────────────────────────────────────────────────

# Create a bare git Config Repo with templates and packs.
_create_config_repo_with_packs() {
    local tmpdir="$1"
    local template_name="$2"
    shift 2
    local pack_names=("$@")

    local work_dir="$tmpdir/mock-work"
    local bare_dir="$tmpdir/mock-remote.git"

    mkdir -p "$work_dir/templates/$template_name/.claude/rules"
    mkdir -p "$work_dir/templates/$template_name/.cco/claude-state/memory"

    # Build packs list for project.yml
    local packs_section="packs: []"
    if [[ ${#pack_names[@]} -gt 0 ]]; then
        packs_section="packs:"
        for p in "${pack_names[@]}"; do
            packs_section+=$'\n'"  - $p"
        done
    fi

    cat > "$work_dir/templates/$template_name/project.yml" <<YAML
name: {{PROJECT_NAME}}
description: "{{DESCRIPTION}}"
repos: []
docker:
  ports: []
  env: {}
auth:
  method: oauth

$packs_section
YAML

    cat > "$work_dir/templates/$template_name/.claude/CLAUDE.md" <<'MD'
# Project: {{PROJECT_NAME}}
## Overview
{{DESCRIPTION}}
MD

    # Create packs
    local manifest_packs=""
    local manifest_templates="  - name: $template_name"
    for name in "${pack_names[@]+"${pack_names[@]}"}"; do
        mkdir -p "$work_dir/packs/$name/knowledge"
        cat > "$work_dir/packs/$name/pack.yml" <<YAML
name: $name
description: "Pack $name"
knowledge:
  files:
    - path: docs.md
YAML
        echo "# Docs for $name" > "$work_dir/packs/$name/knowledge/docs.md"
        manifest_packs+="  - name: $name"$'\n'
    done

    # Create manifest.yml
    if [[ -n "$manifest_packs" ]]; then
        cat > "$work_dir/manifest.yml" <<YAML
name: "test-config"
description: "Test config repo"

packs:
${manifest_packs}
templates:
  - name: $template_name
YAML
    else
        cat > "$work_dir/manifest.yml" <<YAML
name: "test-config"
description: "Test config repo"

packs: []

templates:
  - name: $template_name
YAML
    fi

    git init --bare -q "$bare_dir"
    git -C "$work_dir" init -q
    git -C "$work_dir" add -A
    git -C "$work_dir" commit -q -m "initial"
    git -C "$work_dir" remote add origin "$bare_dir"
    git -C "$work_dir" push -q origin main 2>/dev/null || \
        git -C "$work_dir" push -q origin master 2>/dev/null

    echo "$bare_dir"
}

# ── Tests ───────────────────────────────────────────────────────────

test_install_auto_installs_packs() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    local bare_dir
    bare_dir=$(_create_config_repo_with_packs "$tmpdir" "my-template" "alpha-pack" "beta-pack")

    run_cco project install "$bare_dir" --var "DESCRIPTION=test"
    assert_output_contains "Auto-installing pack"

    # Packs should be installed
    [[ -d "$CCO_PACKS_DIR/alpha-pack" ]] || {
        echo "ASSERTION FAILED: alpha-pack not installed"
        return 1
    }
    [[ -d "$CCO_PACKS_DIR/beta-pack" ]] || {
        echo "ASSERTION FAILED: beta-pack not installed"
        return 1
    }
}

test_install_skips_existing_packs() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Pre-install a pack
    mkdir -p "$CCO_PACKS_DIR/alpha-pack"
    echo "name: alpha-pack" > "$CCO_PACKS_DIR/alpha-pack/pack.yml"
    echo "local content" > "$CCO_PACKS_DIR/alpha-pack/local.md"

    local bare_dir
    bare_dir=$(_create_config_repo_with_packs "$tmpdir" "my-template" "alpha-pack")

    run_cco project install "$bare_dir" --var "DESCRIPTION=test"
    assert_output_contains "already installed"

    # Local content should be preserved (not overwritten)
    [[ -f "$CCO_PACKS_DIR/alpha-pack/local.md" ]] || {
        echo "ASSERTION FAILED: existing pack content was overwritten"
        return 1
    }
}

test_install_warns_missing_packs() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Create config repo with template that references a pack NOT in the repo
    local work_dir="$tmpdir/mock-work"
    local bare_dir="$tmpdir/mock-remote.git"
    mkdir -p "$work_dir/templates/my-template/.claude"

    cat > "$work_dir/templates/my-template/project.yml" <<'YAML'
name: {{PROJECT_NAME}}
description: "test"
repos: []
docker:
  ports: []
  env: {}
auth:
  method: oauth
packs:
  - nonexistent-pack
YAML
    cat > "$work_dir/templates/my-template/.claude/CLAUDE.md" <<'MD'
# {{PROJECT_NAME}}
MD
    cat > "$work_dir/manifest.yml" <<'YAML'
name: "test"
description: ""
packs: []
templates:
  - name: my-template
YAML

    git init --bare -q "$bare_dir"
    git -C "$work_dir" init -q
    git -C "$work_dir" add -A
    git -C "$work_dir" commit -q -m "init"
    git -C "$work_dir" remote add origin "$bare_dir"
    git -C "$work_dir" push -q origin main 2>/dev/null || \
        git -C "$work_dir" push -q origin master 2>/dev/null

    run_cco project install "$bare_dir"
    assert_output_contains "not found"
}

test_install_no_packs_still_works() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    local bare_dir
    bare_dir=$(_create_config_repo_with_packs "$tmpdir" "simple-template")

    run_cco project install "$bare_dir" --var "DESCRIPTION=test"
    assert_output_contains "installed"
    [[ -f "$CCO_PROJECTS_DIR/simple-template/project.yml" ]] || {
        echo "ASSERTION FAILED: project not installed"
        return 1
    }
}

test_install_warns_missing_repo_path() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Create config repo with template that has a repo with url
    local work_dir="$tmpdir/mock-work"
    local bare_dir="$tmpdir/mock-remote.git"
    mkdir -p "$work_dir/templates/repo-template/.claude"

    cat > "$work_dir/templates/repo-template/project.yml" <<'YAML'
name: {{PROJECT_NAME}}
description: "test"
repos:
  - path: /nonexistent/path/my-repo
    name: my-repo
    url: git@github.com:test/my-repo.git
docker:
  ports: []
  env: {}
auth:
  method: oauth
packs: []
YAML
    cat > "$work_dir/templates/repo-template/.claude/CLAUDE.md" <<'MD'
# {{PROJECT_NAME}}
MD
    cat > "$work_dir/manifest.yml" <<'YAML'
name: "test"
description: ""
packs: []
templates:
  - name: repo-template
YAML

    git init --bare -q "$bare_dir"
    git -C "$work_dir" init -q
    git -C "$work_dir" add -A
    git -C "$work_dir" commit -q -m "init"
    git -C "$work_dir" remote add origin "$bare_dir"
    git -C "$work_dir" push -q origin main 2>/dev/null || \
        git -C "$work_dir" push -q origin master 2>/dev/null

    # Non-interactive: should warn about missing path and suggest cco project resolve
    run_cco project install "$bare_dir"
    assert_output_contains "does not exist"
    assert_output_contains "cco project resolve"
}

test_install_noninteractive_fails_for_missing_repo_var() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Create config repo with template using REPO_* variable
    local work_dir="$tmpdir/mock-work"
    local bare_dir="$tmpdir/mock-remote.git"
    mkdir -p "$work_dir/templates/repo-tmpl/.claude"

    cat > "$work_dir/templates/repo-tmpl/project.yml" <<'YAML'
name: {{PROJECT_NAME}}
description: "test"
repos:
  - path: "{{REPO_MY_API}}"
    name: my-api
docker:
  ports: []
  env: {}
auth:
  method: oauth
packs: []
YAML
    cat > "$work_dir/templates/repo-tmpl/.claude/CLAUDE.md" <<'MD'
# {{PROJECT_NAME}}
MD
    cat > "$work_dir/manifest.yml" <<'YAML'
name: "test"
description: ""
packs: []
templates:
  - name: repo-tmpl
YAML

    git init --bare -q "$bare_dir"
    git -C "$work_dir" init -q
    git -C "$work_dir" add -A
    git -C "$work_dir" commit -q -m "init"
    git -C "$work_dir" remote add origin "$bare_dir"
    git -C "$work_dir" push -q origin main 2>/dev/null || \
        git -C "$work_dir" push -q origin master 2>/dev/null

    # Non-interactive: legacy {{REPO_*}} treated as unresolved path — warn, don't abort
    run_cco project install "$bare_dir"
    assert_output_contains "does not exist"
    assert_output_contains "cco project resolve"
}

test_install_noninteractive_succeeds_with_repo_var() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Create config repo with template using REPO_* variable
    local work_dir="$tmpdir/mock-work"
    local bare_dir="$tmpdir/mock-remote.git"
    mkdir -p "$work_dir/templates/repo-tmpl/.claude"

    cat > "$work_dir/templates/repo-tmpl/project.yml" <<'YAML'
name: {{PROJECT_NAME}}
description: "test"
repos:
  - path: "{{REPO_MY_API}}"
    name: my-api
docker:
  ports: []
  env: {}
auth:
  method: oauth
packs: []
YAML
    cat > "$work_dir/templates/repo-tmpl/.claude/CLAUDE.md" <<'MD'
# {{PROJECT_NAME}}
MD
    cat > "$work_dir/manifest.yml" <<'YAML'
name: "test"
description: ""
packs: []
templates:
  - name: repo-tmpl
YAML

    git init --bare -q "$bare_dir"
    git -C "$work_dir" init -q
    git -C "$work_dir" add -A
    git -C "$work_dir" commit -q -m "init"
    git -C "$work_dir" remote add origin "$bare_dir"
    git -C "$work_dir" push -q origin main 2>/dev/null || \
        git -C "$work_dir" push -q origin master 2>/dev/null

    # Should succeed with --var providing the path
    run_cco project install "$bare_dir" --var "REPO_MY_API=/tmp/my-api" --var "DESCRIPTION=test"
    assert_output_contains "installed"
    grep -q '/tmp/my-api' "$CCO_PROJECTS_DIR/repo-tmpl/project.yml" || {
        echo "ASSERTION FAILED: REPO_MY_API not resolved in project.yml"
        return 1
    }
}

test_install_with_packs_updates_manifest() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco init --lang "English"

    local bare_dir
    bare_dir=$(_create_config_repo_with_packs "$tmpdir" "my-template" "auto-pack")

    run_cco project install "$bare_dir" --var "DESCRIPTION=test"
    assert_file_contains "$CCO_USER_CONFIG_DIR/manifest.yml" "auto-pack"
}
