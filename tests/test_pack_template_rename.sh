#!/usr/bin/env bash
# tests/test_pack_template_rename.sh — `cco pack rename` / `cco template rename`
# (ADR-0050 B.3, directory-keyed kinds). Pack rename re-keys the CONFIG store dir +
# pack.yml name:, the DATA/STATE sidecars, the tags, and fans out packs[] refs
# across referencing projects (pack names stay globally scoped). Template rename
# does the same minus the committed reference (discovery-only).

_ptr_tags() {   # _ptr_tags <kind> <name>
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
      source "$REPO_ROOT/lib/paths.sh";  source "$REPO_ROOT/lib/index.sh"
      source "$REPO_ROOT/lib/tags.sh"; _tags_get "$1" "$2" )
}
_ptr_set_tag() {   # _ptr_set_tag <kind> <name> <tags>
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
      source "$REPO_ROOT/lib/paths.sh";  source "$REPO_ROOT/lib/index.sh"
      source "$REPO_ROOT/lib/tags.sh"; _tags_set "$1" "$2" "$3" )
}

_ptr_project_yml() {   # name + a packs[] ref to <pack>
    local name="$1" pack="$2"
    cat <<YAML
name: $name
description: "t"
auth:
  method: oauth
docker:
  ports: []
  env: {}
repos:
  - name: dummy-repo
packs:
  - name: $pack
YAML
}

# ── pack rename ──────────────────────────────────────────────────────

test_pack_rename_rekeys_stores_and_fans_out_refs() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    create_pack "$tmp" oldpack "name: oldpack"$'\n'"description: p"
    mkdir -p "$CCO_DATA_HOME/packs/oldpack" "$(state_shared)/packs/oldpack/update"
    echo "url: local" > "$CCO_DATA_HOME/packs/oldpack/source"
    _ptr_set_tag packs oldpack work
    create_project "$tmp" app "$(_ptr_project_yml app oldpack)"

    run_cco pack rename oldpack newpack -y || fail "rename failed: $CCO_OUTPUT" || return 1

    # CONFIG store dir + pack.yml name:
    assert_dir_exists "$CCO_PACKS_DIR/newpack" || return 1
    assert_dir_not_exists "$CCO_PACKS_DIR/oldpack" || return 1
    assert_file_contains "$CCO_PACKS_DIR/newpack/pack.yml" "name: newpack" || return 1
    # DATA/STATE sidecars moved
    assert_dir_exists "$CCO_DATA_HOME/packs/newpack" || return 1
    assert_dir_not_exists "$CCO_DATA_HOME/packs/oldpack" || return 1
    assert_dir_exists "$(state_shared)/packs/newpack" || return 1
    # tag carried
    [[ "$(_ptr_tags packs newpack)" == "work" ]] || fail "tag not carried, got '$(_ptr_tags packs newpack)'" || return 1
    [[ -z "$(_ptr_tags packs oldpack)" ]] || fail "old tag must be gone" || return 1
    # packs[] fan-out into the referencing project.yml
    assert_file_contains "$(host_cco_dir "$tmp" app)/project.yml" "  - name: newpack" || return 1
    assert_file_not_contains "$(host_cco_dir "$tmp" app)/project.yml" "name: oldpack" || return 1
}

# _rename_fanout_projectyml's inner loop reads _project_iter_members, whose column 2
# (path) is EMPTY for an unresolved member. RC-2 fixed the sibling
# _rename_projectyml_current but left this one on `IFS=$'\t' read`, which folds the
# empty middle field and collapses "ghost\t\tunresolved" to status='' — so the
# `unresolved)` arm NEVER fires and an affected project's unresolved member is silently
# dropped from the strict guard (E6B-04 drift). ⚠ FAILS pre-fix: no `unresolved` line.
test_pack_rename_fanout_surfaces_unresolved_member() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    create_pack "$tmp" oldpack "name: oldpack"
    create_project "$tmp" app "$(_ptr_project_yml app oldpack)"
    # A second member of app, declared but UNRESOLVED (its index path is missing).
    seed_index_path ghost "$tmp/missing/ghost" app
    index_set_project_repos app app ghost

    local out
    out=$(
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/paths.sh";  source "$REPO_ROOT/lib/access-scope.sh"
        source "$REPO_ROOT/lib/index.sh";  source "$REPO_ROOT/lib/sync-meta.sh"
        source "$REPO_ROOT/lib/yaml.sh";   source "$REPO_ROOT/lib/rename.sh"
        source "$REPO_ROOT/lib/cmd-resolve.sh"
        export CCO_ALLOW_HOST_RESOLVE=1
        _rename_fanout_projectyml packs oldpack newpack
    )
    printf '%s\n' "$out" | grep -qE "^unresolved	app	ghost$" \
        || fail "fanout must surface app's unresolved member 'ghost' to the strict guard; got: $out"
    return 0
}

test_pack_rename_is_kind_scoped() {
    # A project named 'shared' must be untouched by 'cco pack rename shared ...'.
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    create_pack "$tmp" shared "name: shared"
    create_project "$tmp" shared "$(minimal_project_yml shared)"

    run_cco pack rename shared pool -y || fail "$CCO_OUTPUT" || return 1

    # the pack moved…
    assert_dir_exists "$CCO_PACKS_DIR/pool" || return 1
    # …but the same-named PROJECT is intact (index + project.yml name:)
    assert_file_contains "$(host_cco_dir "$tmp" shared)/project.yml" "name: shared" || return 1
    run_cco list project 2>/dev/null || true
}

test_pack_rename_rejects_missing_and_duplicate() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    create_pack "$tmp" p1 "name: p1"
    create_pack "$tmp" p2 "name: p2"
    run_cco pack rename nope x -y   && fail "expected 'not found'" || true
    run_cco pack rename p1 p2 -y    && fail "expected duplicate refusal" || true
    assert_dir_exists "$CCO_PACKS_DIR/p1" || return 1
}

# ── template rename ──────────────────────────────────────────────────

test_template_rename_moves_store_and_sidecars() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$CCO_TEMPLATES_DIR/project/oldtpl"
    printf 'description: t\n' > "$CCO_TEMPLATES_DIR/project/oldtpl/template.yml"
    mkdir -p "$CCO_DATA_HOME/templates/oldtpl" "$(state_shared)/templates/oldtpl/update"
    _ptr_set_tag templates oldtpl work

    run_cco template rename oldtpl newtpl -y || fail "rename failed: $CCO_OUTPUT" || return 1

    assert_dir_exists "$CCO_TEMPLATES_DIR/project/newtpl" || return 1
    assert_dir_not_exists "$CCO_TEMPLATES_DIR/project/oldtpl" || return 1
    assert_dir_exists "$CCO_DATA_HOME/templates/newtpl" || return 1
    assert_dir_not_exists "$CCO_DATA_HOME/templates/oldtpl" || return 1
    assert_dir_exists "$(state_shared)/templates/newtpl" || return 1
    [[ "$(_ptr_tags templates newtpl)" == "work" ]] || fail "tag not carried" || return 1
}

test_template_rename_not_found() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    run_cco template rename nope other -y && fail "expected 'not found'" || true
}
