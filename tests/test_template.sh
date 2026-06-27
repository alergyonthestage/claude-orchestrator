#!/usr/bin/env bash
# tests/test_template.sh — Tests for template management commands

# ── _resolve_template ────────────────────────────────────────────────

test_template_resolve_native_fallback() {
    # _resolve_template falls back to native when no user template
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    # Set globals needed by _resolve_template
    export TEMPLATES_DIR="$CCO_TEMPLATES_DIR"
    export NATIVE_TEMPLATES_DIR="$REPO_ROOT/templates"

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/cmd-template.sh"

    local result
    result=$(_resolve_template "project" "base")
    assert_equals "$REPO_ROOT/templates/project/base" "$result" \
        "Should resolve to native project/base template"
}

test_template_resolve_user_priority() {
    # User templates take priority over native
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    export TEMPLATES_DIR="$CCO_TEMPLATES_DIR"
    export NATIVE_TEMPLATES_DIR="$REPO_ROOT/templates"

    # Create a user template
    mkdir -p "$CCO_TEMPLATES_DIR/project/base"
    echo "user-version" > "$CCO_TEMPLATES_DIR/project/base/marker.txt"

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/cmd-template.sh"

    local result
    result=$(_resolve_template "project" "base")
    assert_equals "$CCO_TEMPLATES_DIR/project/base" "$result" \
        "Should resolve to user template when it exists"
}

test_template_resolve_not_found() {
    # Nonexistent template triggers error
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    export TEMPLATES_DIR="$CCO_TEMPLATES_DIR"
    export NATIVE_TEMPLATES_DIR="$REPO_ROOT/templates"

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/cmd-template.sh"

    local output
    output=$(_resolve_template "project" "nonexistent" 2>&1) && {
        echo "ASSERTION FAILED: expected _resolve_template to fail"
        return 1
    }
    # Should have error message
    echo "$output" | grep -q "not found" || {
        echo "ASSERTION FAILED: expected 'not found' in error"
        return 1
    }
}

test_template_resolve_pack_native() {
    # Pack template resolves correctly
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    export TEMPLATES_DIR="$CCO_TEMPLATES_DIR"
    export NATIVE_TEMPLATES_DIR="$REPO_ROOT/templates"

    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/cmd-template.sh"

    local result
    result=$(_resolve_template "pack" "base")
    assert_equals "$REPO_ROOT/templates/pack/base" "$result" \
        "Should resolve to native pack/base template"
}

# ── cco template list ────────────────────────────────────────────────

test_template_list_shows_native() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco list template
    assert_output_contains "base"
    assert_output_contains "native"
}

test_template_list_filter_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco list template
    assert_output_contains "Project templates:"
    assert_output_contains "base"
}

test_template_list_filter_pack() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco list template
    assert_output_contains "Pack templates:"
    assert_output_contains "base"
}

test_template_list_shows_user_templates() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    # Create a user template
    mkdir -p "$CCO_TEMPLATES_DIR/project/custom"
    run_cco list template
    assert_output_contains "custom"
    assert_output_contains "user"
}

# ── cco template show ────────────────────────────────────────────────

test_template_show_native() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco template show base
    assert_output_contains "Template: base"
    assert_output_contains "native"
}

test_template_show_not_found() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco template show nonexistent && {
        echo "ASSERTION FAILED: expected show nonexistent to fail"
        return 1
    }
    return 0
}

# ── cco template create ──────────────────────────────────────────────

test_template_create_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"
    run_cco template create my-tmpl --project
    assert_dir_exists "$CCO_TEMPLATES_DIR/project/my-tmpl"
    assert_file_exists "$CCO_TEMPLATES_DIR/project/my-tmpl/project.yml"
}

test_template_create_pack() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"
    run_cco template create my-pack-tmpl --pack
    assert_dir_exists "$CCO_TEMPLATES_DIR/pack/my-pack-tmpl"
    assert_file_exists "$CCO_TEMPLATES_DIR/pack/my-pack-tmpl/pack.yml"
}

test_template_create_duplicate_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"
    run_cco template create dup-test --project
    run_cco template create dup-test --project && {
        echo "ASSERTION FAILED: expected duplicate create to fail"
        return 1
    }
    return 0
}

test_template_create_invalid_name_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"
    run_cco template create "Bad_Name" --project && {
        echo "ASSERTION FAILED: expected invalid name to fail"
        return 1
    }
    return 0
}

test_template_create_requires_kind() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"
    run_cco template create my-test && {
        echo "ASSERTION FAILED: expected missing --project/--pack to fail"
        return 1
    }
    return 0
}

# ── cco template remove ──────────────────────────────────────────────

test_template_remove_user() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"
    run_cco template create removable --project
    assert_dir_exists "$CCO_TEMPLATES_DIR/project/removable"
    run_cco template remove removable -y
    assert_dir_not_exists "$CCO_TEMPLATES_DIR/project/removable"
}

test_template_remove_cascades_internal_state() {
    # ADR-0021 Dec.4: removing an (installed) template cleans the id-keyed
    # internal state it created — DATA install-provenance, STATE merge base, and
    # the tags.yml binding.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"
    run_cco template create cascade-tmpl --project
    assert_dir_exists "$CCO_TEMPLATES_DIR/project/cascade-tmpl"

    # Simulate an installed, tagged template with merge bookkeeping.
    local src; src=$(data_template_source "cascade-tmpl")
    mkdir -p "$(dirname "$src")"; printf 'url: https://example.com/repo\n' > "$src"
    mkdir -p "$CCO_STATE_HOME/templates/cascade-tmpl/update/base"
    run_cco tag add cascade-tmpl scaffold

    run_cco template remove cascade-tmpl -y

    assert_dir_not_exists "$CCO_TEMPLATES_DIR/project/cascade-tmpl"
    assert_dir_not_exists "$CCO_DATA_HOME/templates/cascade-tmpl"
    assert_dir_not_exists "$CCO_STATE_HOME/templates/cascade-tmpl"
    run_cco list --tag scaffold
    if echo "${CCO_OUTPUT:-}" | grep -qF "cascade-tmpl"; then
        fail "tag binding for cascade-tmpl should be gone after remove"
    fi
}

test_template_remove_native_fails() {
    # Native templates can't be removed (they're not in user templates dir)
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco template remove base && {
        echo "ASSERTION FAILED: expected removing native template to fail"
        return 1
    }
    return 0
}

# ── project create --template ────────────────────────────────────────
# Removed in P3-3b: template-based project instantiation (`cco project create
# --template`) is gone with `cco project create`. The clean `cco init` scaffolds
# from templates/project/base only; template distribution (the 2x2) is P4/P5.

# ── pack create --template ───────────────────────────────────────────

test_pack_create_with_default_template() {
    # Default pack create uses templates/pack/base
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"
    run_cco pack create my-test-pack
    assert_dir_exists "$CCO_PACKS_DIR/my-test-pack"
    assert_file_exists "$CCO_PACKS_DIR/my-test-pack/pack.yml"
    # Name should be substituted
    assert_file_contains "$CCO_PACKS_DIR/my-test-pack/pack.yml" "name: my-test-pack"
    # Placeholder should be gone
    assert_file_not_contains "$CCO_PACKS_DIR/my-test-pack/pack.yml" "{{PACK_NAME}}"
}

test_pack_create_with_named_template() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"

    # Create a custom pack template
    mkdir -p "$CCO_TEMPLATES_DIR/pack/special/knowledge"
    cat > "$CCO_TEMPLATES_DIR/pack/special/pack.yml" <<'YAML'
name: {{PACK_NAME}}
# Special template
YAML

    run_cco pack create my-special --template special
    assert_dir_exists "$CCO_PACKS_DIR/my-special"
    assert_file_contains "$CCO_PACKS_DIR/my-special/pack.yml" "name: my-special"
    assert_file_contains "$CCO_PACKS_DIR/my-special/pack.yml" "Special template"
}

# ── cco template --help ──────────────────────────────────────────────

test_template_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco template --help
    assert_output_contains "show"
    assert_output_contains "create"
    assert_output_contains "remove"
}

# ── Scenario 15: template create --project strips .cco/ ──────────────

test_template_create_from_project_strips_cco() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"

    # A decentralized project: committed config lives in <repo>/.cco/ (the
    # claude/ tree + project.yml + secrets.env.example). create_project seeds the
    # STATE index + the host repo, so `--from src-proj` resolves via the index (P5).
    create_project "$tmpdir" "src-proj" "$(cat <<YAML
name: src-proj
repos: []
YAML
)"
    local cco; cco=$(host_cco_dir "$tmpdir" "src-proj")
    echo "# project CLAUDE" > "$cco/claude/CLAUDE.md"
    echo "SECRET=" > "$cco/secrets.env.example"
    # Defensive: a stray runtime dir the template must strip.
    mkdir -p "$cco/.tmp"; echo "dump" > "$cco/.tmp/output"

    run_cco template create my-tmpl --project --from src-proj

    local tmpl_dir="$CCO_TEMPLATES_DIR/project/my-tmpl"
    assert_dir_exists "$tmpl_dir"
    assert_file_exists "$tmpl_dir/project.yml"
    # claude/ → .claude/ : templates use the native .claude/ layout.
    assert_dir_exists "$tmpl_dir/.claude"
    assert_file_exists "$tmpl_dir/.claude/CLAUDE.md"
    [[ ! -d "$tmpl_dir/claude" ]] || {
        echo "ASSERTION FAILED: claude/ should be renamed to .claude/ in the template"
        return 1
    }
    # .tmp/ should be stripped
    [[ ! -d "$tmpl_dir/.tmp" ]] || {
        echo "ASSERTION FAILED: .tmp/ should be stripped from template"
        return 1
    }
    # secrets.env.example → emptied secrets.env (the template's secret skeleton)
    assert_file_exists "$tmpl_dir/secrets.env"
    [[ ! -f "$tmpl_dir/secrets.env.example" ]] || {
        echo "ASSERTION FAILED: secrets.env.example should be normalized to secrets.env"
        return 1
    }
    local size
    size=$(wc -c < "$tmpl_dir/secrets.env")
    [[ "$size" -eq 0 ]] || {
        echo "ASSERTION FAILED: secrets.env should be emptied, not removed"
        return 1
    }
}

# ── Template sharing 2×2 (ADR-0018 D2; both kinds by marker) ───────────

# Minimal empty bare remote (structure-based discovery; no manifest.yml).
_tmpl_empty_bare_remote() {
    local tmpdir="$1" bare_dir="$tmpdir/tmpl-remote.git"
    local work="$tmpdir/tmpl-init-work"
    mkdir -p "$work"
    git -C "$work" init -q
    : > "$work/.gitkeep"
    git -C "$work" add -A
    git -C "$work" commit -q -m "init"
    git init --bare -q "$bare_dir"
    git -C "$work" remote add origin "$bare_dir"
    git -C "$work" push -q origin main 2>/dev/null || \
        git -C "$work" push -q origin master 2>/dev/null
    rm -rf "$work"
    echo "$bare_dir"
}

test_template_export_import_round_trip() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco template create myt --project
    cd "$tmpdir"
    run_cco template export myt
    assert_file_exists "$tmpdir/myt.tar.gz"

    run_cco template remove myt -y
    run_cco template import "$tmpdir/myt.tar.gz"
    assert_output_contains "Imported project template"
    assert_file_exists "$CCO_TEMPLATES_DIR/project/myt/project.yml"
}

test_template_export_import_pack_kind() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco template create packt --pack
    cd "$tmpdir"
    run_cco template export packt
    run_cco template remove packt -y
    run_cco template import "$tmpdir/packt.tar.gz"
    # Kind is detected from the pack.yml marker inside the archive.
    assert_output_contains "Imported pack template"
    assert_file_exists "$CCO_TEMPLATES_DIR/pack/packt/pack.yml"
}

test_template_publish_install_round_trip() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco template create sharet --project
    local bare; bare=$(_tmpl_empty_bare_remote "$tmpdir")

    run_cco remote add treg "$bare"
    run_cco template publish sharet treg
    assert_output_contains "Published"

    run_cco template remove sharet -y
    run_cco template install "$bare" --pick sharet
    assert_file_exists "$CCO_TEMPLATES_DIR/project/sharet/project.yml"
}

# P5-5a: install pins the upstream HEAD as installed_commit in the STATE meta,
# so `cco update --check` has a baseline to compare against (ADR-0022 D1/D6).
test_template_install_records_installed_commit() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco template create cmt --project
    local bare; bare=$(_tmpl_empty_bare_remote "$tmpdir")
    run_cco remote add r "$bare"
    run_cco template publish cmt r
    run_cco template remove cmt -y
    run_cco template install "$bare" --pick cmt

    local meta="$CCO_STATE_HOME/templates/cmt/update/meta"
    assert_file_exists "$meta"
    assert_file_contains "$meta" "installed_commit:"
    # the recorded commit matches the remote HEAD
    local head; head=$(git ls-remote "$bare" HEAD | head -1 | cut -f1)
    assert_file_contains "$meta" "$head"
}

test_template_publish_preserves_remote_only_changes() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco template create sync --project
    local bare; bare=$(_tmpl_empty_bare_remote "$tmpdir")
    run_cco remote add r "$bare"
    run_cco template publish sync r            # first publish → base recorded

    # Co-maintainer adds a remote-only file.
    local co="$tmpdir/co"; git clone -q "$bare" "$co"
    echo "# remote only" > "$co/templates/sync/extra.md"
    git -C "$co" add -A; git -C "$co" commit -q -m "co adds extra"
    git -C "$co" push -q origin HEAD

    # We change a different local file and republish (no --force).
    echo "# local note" >> "$CCO_TEMPLATES_DIR/project/sync/project.yml"
    run_cco template publish sync r
    assert_output_contains "Published"

    local verify="$tmpdir/verify"; git clone -q "$bare" "$verify"
    assert_file_contains "$verify/templates/sync/extra.md" "remote only" || return 1
    assert_file_contains "$verify/templates/sync/project.yml" "local note" || return 1
}

test_template_publish_aborts_on_conflict() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco template create cft --project
    local bare; bare=$(_tmpl_empty_bare_remote "$tmpdir")
    run_cco remote add r "$bare"
    run_cco template publish cft r

    local co="$tmpdir/co"; git clone -q "$bare" "$co"
    echo "# remote change" >> "$co/templates/cft/project.yml"
    git -C "$co" add -A; git -C "$co" commit -q -m "co edits"
    git -C "$co" push -q origin HEAD

    echo "# local change" >> "$CCO_TEMPLATES_DIR/project/cft/project.yml"
    if run_cco template publish cft r 2>/dev/null; then
        echo "ASSERTION FAILED: template publish should abort on conflict"
        return 1
    fi
    assert_output_contains "clobber" || return 1
}

test_template_sharing_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco template publish --help; assert_output_contains "Publish a template" || return 1
    run_cco template install --help; assert_output_contains "Install a template" || return 1
    run_cco template export --help;  assert_output_contains "Export a template"  || return 1
    run_cco template import --help;  assert_output_contains "Import a template"  || return 1
}

# ── cco template remove — non-TTY confirm guard (ADR-0029 D2) ─────────

test_template_remove_non_tty_without_yes_dies() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"
    run_cco template create guarded --project
    assert_dir_exists "$CCO_TEMPLATES_DIR/project/guarded"

    if run_cco template remove guarded </dev/null 2>/dev/null; then
        fail "template remove without -y in a non-TTY should die"
    fi
    assert_output_contains "re-run with -y"
    assert_dir_exists "$CCO_TEMPLATES_DIR/project/guarded"
}
