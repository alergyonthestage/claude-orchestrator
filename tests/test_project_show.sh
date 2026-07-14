#!/usr/bin/env bash
# tests/test_project_show.sh — cco project show and validate command tests
#
# Verifies project show and validate commands.

# ── show ──────────────────────────────────────────────────────────────

test_project_show_displays_name() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-proj" "$(cat <<YAML
name: my-proj
description: "A test project"
repos: []
YAML
)"
    run_cco project show "my-proj"
    assert_output_contains "my-proj"
}

test_project_show_lists_repos() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local repo_dir="$tmpdir/my-repo"
    mkdir -p "$repo_dir"
    seed_index_path "my-repo" "$repo_dir"
    create_project "$tmpdir" "my-proj" "$(cat <<YAML
name: my-proj
repos:
  - name: my-repo
YAML
)"
    run_cco project show "my-proj"
    assert_output_contains "my-repo"
}

test_project_show_lists_packs() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_pack "$tmpdir" "test-pack" "$(cat <<YAML
name: test-pack
YAML
)"
    create_project "$tmpdir" "my-proj" "$(cat <<YAML
name: my-proj
repos: []
packs:
  - test-pack
YAML
)"
    run_cco project show "my-proj"
    assert_output_contains "test-pack"
}

test_project_show_docker_config() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-proj" "$(cat <<YAML
name: my-proj
auth:
  method: api_key
docker:
  ports:
    - "3000:3000"
  env: {}
repos: []
YAML
)"
    run_cco project show "my-proj"
    assert_output_contains "api_key"
    assert_output_contains "3000:3000"
}

test_project_show_fails_if_not_found() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    if run_cco project show "nonexistent" 2>/dev/null; then
        echo "ASSERTION FAILED: should have failed for missing project"
        return 1
    fi
}

# ── D5 observability: roles + referenced-by + repo-centric view ──────

test_project_show_referenced_by() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    mkdir -p "$tmpdir/shared"
    create_project "$tmpdir" projA "name: projA
repos:
  - name: shared"
    # 'shared' is a member of projA AND referenced by projB. Under per-project
    # scoping (ADR-0051 D5) referenced-by is a PATH property: each project carries
    # its OWN binding to the same path, so seed 'shared' scoped to both.
    seed_index_path shared "$tmpdir/shared" projA
    seed_index_path shared "$tmpdir/shared" projB
    index_set_project_repos projB shared
    run_cco project show projA
    assert_output_contains "also referenced by: projB"
}

test_project_show_member_role_host() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    # A member repo whose .cco/ hosts projA → role 'host'.
    local hostrepo="$tmpdir/hostrepo"; mkdir -p "$hostrepo/.cco"
    printf 'name: projA\n' > "$hostrepo/.cco/project.yml"
    seed_index_path mainrepo "$hostrepo"
    create_project "$tmpdir" projA "name: projA
repos:
  - name: mainrepo"
    run_cco project show projA
    assert_output_contains "[host]"
}

test_project_show_repo_centric_view() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local repo="$tmpdir/myrepo"; mkdir -p "$repo/.cco"
    cat > "$repo/.cco/project.yml" <<'YML'
name: myproj
repos:
  - name: api
    url: git@github.com:org/api.git
YML
    cd "$repo"
    run_cco project show
    assert_output_contains "hosts project: myproj"
    assert_output_contains "api"
}

# ── R4: bare `cco project show` at the container WORKDIR root ─────────────────
# The trigger (_project_show_session_fallback) is env-driven so it is unit-testable
# without a live /workspace: CCO_WORKDIR points it at a tmp WORKDIR with a flat
# session manifest, and _cco_container_operator is stubbed for the operator branch.

_ps_fallback() {  # echoes the resolved name (or empty); operator stubbed per $1
    local operator="$1"
    (
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/paths.sh";  source "$REPO_ROOT/lib/cmd-project-query.sh"
        if [[ "$operator" == yes ]]; then _cco_container_operator() { return 0; }
        else _cco_container_operator() { return 1; }; fi
        _project_show_session_fallback "$PWD"
    )
}

test_project_show_r4_workdir_resolves_session() {
    local ws; ws=$(mktemp -d); trap "rm -rf '$ws'" EXIT
    : > "$ws/project.yml"
    local out
    out=$(cd "$ws" && CCO_WORKDIR="$ws" PROJECT_NAME=my-session _ps_fallback yes)
    [[ "$out" == "my-session" ]] \
        || fail "R4: at the WORKDIR root the fallback should resolve PROJECT_NAME, got: '$out'"
}

test_project_show_r4_no_project_name_no_fallback() {
    local ws; ws=$(mktemp -d); trap "rm -rf '$ws'" EXIT
    : > "$ws/project.yml"
    local out
    out=$(cd "$ws" && CCO_WORKDIR="$ws" _ps_fallback yes)   # PROJECT_NAME unset
    [[ -z "$out" ]] || fail "R4: no PROJECT_NAME → no fallback (usage error), got: '$out'"
}

test_project_show_r4_only_at_workdir_root() {
    local ws; ws=$(mktemp -d); trap "rm -rf '$ws'" EXIT
    : > "$ws/project.yml"; mkdir -p "$ws/sub"
    local out
    # A non-WORKDIR cwd (child-wins / no ambiguous deep resolution) → no fallback.
    out=$(cd "$ws/sub" && CCO_WORKDIR="$ws" PROJECT_NAME=my-session _ps_fallback yes)
    [[ -z "$out" ]] || fail "R4: fallback must fire ONLY at the WORKDIR root, got: '$out'"
}

test_project_show_r4_host_never_fires() {
    local ws; ws=$(mktemp -d); trap "rm -rf '$ws'" EXIT
    : > "$ws/project.yml"
    local out
    # Host (not operator) → the fallback is inert even at a matching cwd.
    out=$(cd "$ws" && CCO_WORKDIR="$ws" PROJECT_NAME=my-session _ps_fallback no)
    [[ -z "$out" ]] || fail "R4: host context must never trigger the fallback, got: '$out'"
}

test_project_show_r4_requires_flat_manifest() {
    local ws; ws=$(mktemp -d); trap "rm -rf '$ws'" EXIT
    # No flat project.yml at the WORKDIR → no fallback.
    local out
    out=$(cd "$ws" && CCO_WORKDIR="$ws" PROJECT_NAME=my-session _ps_fallback yes)
    [[ -z "$out" ]] || fail "R4: fallback needs a flat session manifest, got: '$out'"
}
