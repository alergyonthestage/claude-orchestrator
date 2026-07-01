#!/usr/bin/env bash
# tests/test_pack_resolution.sh — three-layer pack resolution at mount time
# (ADR-0019 D5 / design §2.4). Local-first: ~/.cco/packs/<name> wins over the
# project-local <repo>/.cco/packs/<name> (authored source or last-layer cache);
# a url-bearing pack missing from both local layers is a conscious-skip (warn),
# the url-fetch happening via `cco resolve`, not `cco start` (P14).

# Seed a project-local (repo) pack with one knowledge file.
# Usage: _seed_repo_pack <tmpdir> <project> <pack>
_seed_repo_pack() {
    local tmpdir="$1" proj="$2" pack="$3"
    local pdir; pdir="$(host_cco_dir "$tmpdir" "$proj")/packs/$pack"
    mkdir -p "$pdir/knowledge"
    printf 'name: %s\nknowledge:\n  files:\n    - guide.md\n' "$pack" > "$pdir/pack.yml"
    printf '# guide\n' > "$pdir/knowledge/guide.md"
}

# A minimal project that references one pack by name (authored, no url).
_pack_res_project() {
    local tmpdir="$1" proj="$2" pack="$3"
    create_project "$tmpdir" "$proj" "$(cat <<YAML
name: $proj
auth:
  method: oauth
docker:
  ports: []
  env: {}
repos:
  - name: dummy-repo
packs:
  - $pack
YAML
)"
}

test_pack_resolve_dir_local_first() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/packs.sh"
    PACKS_DIR="$CCO_PACKS_DIR"

    local repo_cco="$tmpdir/repo/.cco"
    mkdir -p "$PACKS_DIR/dup" "$repo_cco/packs/dup" "$repo_cco/packs/only"

    # Both present → global ~/.cco/packs wins.
    assert_equals "$PACKS_DIR/dup" "$(_pack_resolve_dir dup "$repo_cco")"
    # Repo-only → resolves to the project-local cache/source.
    assert_equals "$repo_cco/packs/only" "$(_pack_resolve_dir only "$repo_cco")"
    # Neither → empty (unresolved).
    assert_empty "$(_pack_resolve_dir ghost "$repo_cco")"
}

test_pack_resolves_from_repo_cache() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _pack_res_project "$tmpdir" "cache-proj" "repopack"
    _seed_repo_pack "$tmpdir" "cache-proj" "repopack"   # only in <repo>/.cco/packs

    run_cco start "cache-proj" --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    # Mounted from the project-local pack dir, at the standard container path.
    assert_file_contains "$compose" ":/workspace/.claude/packs/repopack:ro"
    assert_file_contains "$compose" "repos/cache-proj/.cco/packs/repopack/knowledge"
    assert_file_contains "$DRY_RUN_DIR/.claude/workspace.yml" "- path: /workspace/.claude/packs/repopack/guide.md"
}

test_pack_global_wins_over_repo_cache() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _pack_res_project "$tmpdir" "dup-proj" "dup"
    # Same name in BOTH the global library and the repo cache.
    _seed_repo_pack "$tmpdir" "dup-proj" "dup"
    mkdir -p "$CCO_PACKS_DIR/dup/knowledge"
    printf 'name: dup\nknowledge:\n  files:\n    - guide.md\n' > "$CCO_PACKS_DIR/dup/pack.yml"
    printf '# global\n' > "$CCO_PACKS_DIR/dup/knowledge/guide.md"

    run_cco start "dup-proj" --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    # The global ~/.cco/packs copy is mounted, not the repo cache.
    assert_file_contains "$compose" "$CCO_PACKS_DIR/dup/knowledge:/workspace/.claude/packs/dup:ro"
    if grep -q "repos/dup-proj/.cco/packs/dup/knowledge" "$compose"; then
        fail "repo cache should be shadowed by the global pack at mount"
    fi
}

test_pack_unresolved_warns_and_skips() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    # A url-bearing pack reference with the pack installed nowhere.
    create_project "$tmpdir" "miss-proj" "$(cat <<'YAML'
name: miss-proj
auth:
  method: oauth
docker:
  ports: []
  env: {}
repos:
  - name: dummy-repo
packs:
  - name: missingpack
    url: https://example.com/sharing.git
YAML
)"

    run_cco start "miss-proj" --dry-run --dump
    assert_output_contains "missingpack"
    assert_output_contains "not resolved"
    # Conscious-skip: start still produced a valid compose, no pack mount.
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    if grep -q "/workspace/.claude/packs/missingpack" "$compose"; then
        fail "unresolved pack must not be mounted"
    fi
}
