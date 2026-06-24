#!/usr/bin/env bash
# tests/test_project_export_import.sh — cco project export/import (2×2 local
# transport for projects; ADR-0018 D2). Projects are not published/installed.

# Scaffold a decentralized project config (<repo>/.cco/) WITHOUT touching the
# index — cwd-first export needs only .cco/project.yml on disk.
_scaffold_project_cco() {
    local repo="$1" name="$2"
    mkdir -p "$repo/.cco/claude"
    cat > "$repo/.cco/project.yml" <<YAML
name: $name
repos: []
YAML
    echo "# $name project config" > "$repo/.cco/claude/CLAUDE.md"
    echo "TOKEN=" > "$repo/.cco/secrets.env.example"
}

# ── export / import round-trip ─────────────────────────────────────────

test_project_export_round_trip() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    local src="$tmpdir/repos/myproj"
    _scaffold_project_cco "$src" "myproj"
    cd "$src"
    run_cco project export
    assert_file_exists "$src/myproj.tar.gz"

    # Import into a different repo (myproj is not yet registered → no conflict).
    local dest="$tmpdir/repos/dest"; mkdir -p "$dest"
    cd "$dest"
    run_cco project import "$src/myproj.tar.gz"
    assert_output_contains "Imported"
    assert_file_exists "$dest/.cco/project.yml"
    assert_file_contains "$dest/.cco/project.yml" "name: myproj"
    assert_file_not_exists "$dest/.cco/secrets.env"

    # The import registered the project in the index: a by-name export now
    # resolves it (via _resolve_unit_dir_for_project → index) from any cwd.
    cd "$tmpdir"
    run_cco project export myproj --output "$tmpdir/byname.tar.gz"
    assert_file_exists "$tmpdir/byname.tar.gz"
}

test_project_export_excludes_secrets() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    local src="$tmpdir/repos/sec"
    _scaffold_project_cco "$src" "sec"
    echo "TOKEN=realsecret" > "$src/.cco/secrets.env"
    cd "$src"
    run_cco project export
    assert_file_exists "$src/sec.tar.gz"

    if tar tzf "$src/sec.tar.gz" | grep -q '.cco/secrets.env$'; then
        echo "ASSERTION FAILED: secrets.env must never be bundled"
        return 1
    fi
}

test_project_export_aborts_on_secret_leak() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    local src="$tmpdir/repos/leak"
    _scaffold_project_cco "$src" "leak"
    # A leaked credential in a tracked (non-secrets, non-.example) file blocks export.
    echo "API_KEY=sk-abc123def" > "$src/.cco/claude/notes.md"
    cd "$src"
    if run_cco project export 2>/dev/null; then
        echo "ASSERTION FAILED: export should abort on a secret leak"
        return 1
    fi
    assert_output_contains "secret" || return 1
}

test_project_import_refuses_existing() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    local src="$tmpdir/repos/p1"; _scaffold_project_cco "$src" "p1"
    cd "$src"; run_cco project export

    local dest="$tmpdir/repos/dest"; _scaffold_project_cco "$dest" "other"
    cd "$dest"
    if run_cco project import "$src/p1.tar.gz" 2>/dev/null; then
        echo "ASSERTION FAILED: import should refuse an existing .cco/ without --force"
        return 1
    fi
}

test_project_sharing_verbs_removed() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    # Projects are not published/installed/updated from a sharing repo (ADR-0018
    # D2); the current project-internalize is retired with them (ADR-0023 D4c).
    local verb
    for verb in publish install update internalize; do
        if run_cco project "$verb" foo bar 2>/dev/null; then
            echo "ASSERTION FAILED: 'cco project $verb' should be rejected (removed in P4-4)"
            return 1
        fi
        assert_output_contains "was removed" || return 1
    done
}

test_project_export_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco project export --help
    assert_output_contains "Export a project"
}

test_project_import_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    run_cco project import --help
    assert_output_contains "Import a project"
}
