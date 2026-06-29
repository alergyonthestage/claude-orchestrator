#!/usr/bin/env bash
# tests/test_new.sh — `cco new` (ephemeral session) input validation
#
# M6 (26-06-2026 migration review): `cco new --name` flows into an EXIT-trap
# `rm -rf`, the temp dir path, and the generated docker-compose (container/network
# names, env). An unvalidated name allowed shell / path-traversal / YAML injection.
# The guard runs after global-config check but before any docker interaction, so a
# malicious name is rejected without launching anything.

test_new_rejects_shell_injection_name() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco new --repo "$tmpdir" --name 'x" && rm -rf ~ #' || true
    assert_output_contains "Invalid session name" \
        "cco new must reject a shell-injection --name (M6)"
}

test_new_rejects_path_traversal_name() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco new --repo "$tmpdir" --name '../../../etc' || true
    assert_output_contains "Invalid session name" \
        "cco new must reject a path-traversal --name (M6)"
}

test_new_rejects_yaml_break_name() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco new --repo "$tmpdir" --name 'a: b' || true
    assert_output_contains "Invalid session name" \
        "cco new must reject a name containing YAML-breaking characters (M6)"
}
