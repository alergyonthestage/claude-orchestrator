#!/usr/bin/env bash
# tests/test_template_internalize.sh — `cco template internalize` (ADR-0019 D3/D4,
# ADR-0023 D4). Sever a template's one external coupling (the upstream url): set
# its DATA source to local. With --as, fork to a new self-contained template,
# leaving the original linked. Templates have no knowledge.source, so this is the
# source-disconnect only.

# Mark a user template as installed-from-a-sharing-repo by seeding its DATA source.
_seed_template_source() {
    local name="$1" url="$2"
    local sf; sf=$(data_template_source "$name")
    mkdir -p "$(dirname "$sf")"
    printf 'url: %s\nresource:\nref:\n' "$url" > "$sf"
}

test_template_internalize_disconnects_source() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"
    run_cco template create linked-t --project
    _seed_template_source "linked-t" "https://example.com/sharing.git"

    run_cco template internalize linked-t
    assert_output_contains "disconnected from remote source"
    assert_file_contains "$(data_template_source linked-t)" "url: local"
}

test_template_internalize_already_self_contained() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"
    run_cco template create local-t --project   # created locally, no DATA source

    run_cco template internalize local-t
    assert_output_contains "already self-contained"
}

test_template_internalize_as_forks_leaving_original() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"
    run_cco template create base-t --project
    _seed_template_source "base-t" "https://example.com/sharing.git"

    run_cco template internalize base-t --as fork-t
    assert_output_contains "Forked template 'base-t'"
    assert_dir_exists "$CCO_TEMPLATES_DIR/project/fork-t"
    # Fork is self-contained (no inherited DATA source).
    assert_file_not_exists "$(data_template_source fork-t)"
    # Original stays linked to its source.
    assert_file_contains "$(data_template_source base-t)" "example.com"
}

test_template_internalize_nonexistent_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"
    if run_cco template internalize ghost 2>/dev/null; then
        fail "internalize of a missing template should fail"
    fi
}
