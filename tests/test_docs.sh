#!/usr/bin/env bash
# tests/test_docs.sh — `cco docs`: offline browsing of the bundled user docs
# (ADR-0037 D9). run_cco captures stdout non-interactively, so _docs_page falls
# back to cat and the file content lands in CCO_OUTPUT.

test_docs_no_arg_lists_topics() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco docs
    assert_output_contains "reference/cli" || return 1
    # README is the index, not a listed topic.
    assert_output_not_contains "README"
}

test_docs_resolves_by_basename() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco docs cli
    # cli.md content (the CLI reference) is paged out.
    assert_output_contains "cco init"
}

test_docs_resolves_by_relative_path() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco docs configuration/guides/project-setup
    assert_output_contains "project"
}

test_docs_unknown_topic_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    if run_cco docs no-such-topic-xyz 2>/dev/null; then
        fail "Expected 'cco docs no-such-topic-xyz' to fail"
    fi
    assert_output_contains "No doc matches"
}

test_docs_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco docs --help
    assert_output_contains "Usage: cco docs"
}
