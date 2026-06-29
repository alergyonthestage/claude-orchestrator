#!/usr/bin/env bash
# tests/test_project_add.sh — cco project add (P1 Commit 6; ADR-0023 D3)
#
# Embed-at-add: coordinate into the cwd project's .cco/project.yml + (with
# --path) the machine-local index binding. url-from-origin; flag applicability;
# duplicate guard; section creation. Mask-safe: `… || return 1`.

# Run bin/cco from a given cwd (inherits exported CCO_*/HOME); sets CCO_OUTPUT.
_pa_cco_in() {
    local dir="$1"; shift
    local rc=0
    CCO_OUTPUT=$(cd "$dir" && bash "$REPO_ROOT/bin/cco" "$@" 2>&1) || rc=$?
    return $rc
}

# Minimal decentralized project unit at <repo_root>/.cco/project.yml.
_pa_unit() {
    local root="$1"
    mkdir -p "$root/.cco"
    printf 'name: demo\nrepos:\n  - name: self\n' > "$root/.cco/project.yml"
}

test_add_repo_embeds_coordinate() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"

    _pa_cco_in "$tmp/dev/repo1" project add repo backend --url https://ex.com/backend.git --ref main || return 1
    local m="$tmp/dev/repo1/.cco/project.yml"
    assert_file_contains "$m" "- name: backend" || return 1
    assert_file_contains "$m" "url: https://ex.com/backend.git" || return 1
    assert_file_contains "$m" "ref: main" || return 1
}

test_add_repo_roundtrips_through_parser() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"

    _pa_cco_in "$tmp/dev/repo1" project add repo backend --url https://ex.com/b.git --ref dev || return 1
    # The embedded coordinate must be readable by the P0 parser.
    local out
    out=$(
        source "$REPO_ROOT/lib/colors.sh"
        source "$REPO_ROOT/lib/yaml.sh"
        yml_get_repo_coords "$tmp/dev/repo1/.cco/project.yml" | awk -F'\t' '$1=="backend"{print $2"|"$3}'
    )
    assert_equals "https://ex.com/b.git|dev" "$out" || return 1
}

test_add_repo_with_path_binds_index() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"
    mkdir -p "$tmp/dev/backend"

    _pa_cco_in "$tmp/dev/repo1" project add repo backend --url https://ex.com/b.git --path "$tmp/dev/backend" || return 1
    run_cco path list || return 1
    assert_output_contains "backend" || return 1
    assert_output_contains "$tmp/dev/backend" || return 1
}

test_add_repo_no_path_leaves_index_untouched() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"

    _pa_cco_in "$tmp/dev/repo1" project add repo backend --url https://ex.com/b.git || return 1
    run_cco path list || return 1
    assert_output_not_contains "backend" || return 1   # coordinate only; no index binding
}

test_add_repo_url_from_origin() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"
    mkdir -p "$tmp/dev/backend"
    git -C "$tmp/dev/backend" init -q || return 1
    git -C "$tmp/dev/backend" remote add origin https://ex.com/from-origin.git || return 1

    # No --url: must be derived from the clone's origin.
    _pa_cco_in "$tmp/dev/repo1" project add repo backend --path "$tmp/dev/backend" || return 1
    assert_file_contains "$tmp/dev/repo1/.cco/project.yml" "url: https://ex.com/from-origin.git" || return 1
}

test_add_mount_with_target_and_readonly() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"

    _pa_cco_in "$tmp/dev/repo1" project add mount assets --target /workspace/assets --readonly || return 1
    local m="$tmp/dev/repo1/.cco/project.yml"
    assert_file_contains "$m" "extra_mounts:" || return 1
    assert_file_contains "$m" "- name: assets" || return 1
    assert_file_contains "$m" "target: /workspace/assets" || return 1
    assert_file_contains "$m" "readonly: true" || return 1
}

test_add_llms_requires_url() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"

    local rc=0
    _pa_cco_in "$tmp/dev/repo1" project add llms docs || rc=$?
    [[ $rc -ne 0 ]] || { echo "ASSERTION FAILED: add llms without --url should fail"; return 1; }
    assert_output_contains "llms requires --url" || return 1
}

test_add_llms_embeds_url_and_variant() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"

    _pa_cco_in "$tmp/dev/repo1" project add llms anthropic --url https://docs.anthropic.com/llms.txt --variant full || return 1
    local m="$tmp/dev/repo1/.cco/project.yml"
    assert_file_contains "$m" "llms:" || return 1
    assert_file_contains "$m" "- name: anthropic" || return 1
    assert_file_contains "$m" "variant: full" || return 1
}

test_add_pack_embeds_coordinate() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"

    _pa_cco_in "$tmp/dev/repo1" project add pack mypack --url https://ex.com/packs.git --ref v1 || return 1
    local m="$tmp/dev/repo1/.cco/project.yml"
    assert_file_contains "$m" "packs:" || return 1
    assert_file_contains "$m" "- name: mypack" || return 1
    assert_file_contains "$m" "ref: v1" || return 1
}

test_add_pack_rejects_path() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"

    local rc=0
    _pa_cco_in "$tmp/dev/repo1" project add pack mypack --path "$tmp/x" || rc=$?
    [[ $rc -ne 0 ]] || { echo "ASSERTION FAILED: --path should be rejected for pack"; return 1; }
    assert_output_contains "not valid for pack" || return 1
}

test_add_duplicate_name_errors() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _pa_unit "$tmp/dev/repo1"

    _pa_cco_in "$tmp/dev/repo1" project add repo backend --url https://ex.com/b.git || return 1
    local rc=0
    _pa_cco_in "$tmp/dev/repo1" project add repo backend --url https://ex.com/other.git || rc=$?
    [[ $rc -ne 0 ]] || { echo "ASSERTION FAILED: duplicate add should fail"; return 1; }
    assert_output_contains "already present" || return 1
}

test_add_outside_project_errors() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/empty"

    local rc=0
    _pa_cco_in "$tmp/empty" project add repo x --url https://ex.com/x.git || rc=$?
    [[ $rc -ne 0 ]] || { echo "ASSERTION FAILED: add outside a project should fail"; return 1; }
    assert_output_contains "No .cco/project.yml" || return 1
}
