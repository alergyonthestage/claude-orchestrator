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
# The trigger (_project_session_fallback) is env-driven so it is unit-testable
# without a live /workspace: CCO_WORKDIR points it at a tmp WORKDIR with a flat
# session manifest, and _cco_container_operator is stubbed for the operator branch.

_ps_fallback() {  # echoes the resolved name (or empty); operator stubbed per $1
    local operator="$1"
    (
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/paths.sh";  source "$REPO_ROOT/lib/cmd-project-query.sh"
        if [[ "$operator" == yes ]]; then _cco_container_operator() { return 0; }
        else _cco_container_operator() { return 1; }; fi
        _project_session_fallback "$PWD"
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

# ── B-DF1: members are probed at the MOUNT in-container, not the index host path ──
# The index stores HOST paths; in a session the member is bind-mounted at
# <workdir>/<name>. Probing the host path in-container always fails and mislabels a
# mounted repo `[missing]` + `code-only`. Same subshell/stub pattern as R4 above: it
# exercises the helper directly, so it never reaches the dispatcher (whose
# store-verb trampoline would re-enter the image-baked cco and defeat the test).

_ps_probe() {  # echoes the probe path; operator stubbed per $1
    local operator="$1"; shift
    (
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/paths.sh"
        if [[ "$operator" == yes ]]; then _cco_container_operator() { return 0; }
        else _cco_container_operator() { return 1; }; fi
        _cco_member_probe_path "$@"
    )
}

test_member_probe_operator_uses_mount() {
    local out
    out=$(CCO_WORKDIR=/ws _ps_probe yes "my-repo" "/Users/alex/code/my-repo")
    [[ "$out" == "/ws/my-repo" ]] \
        || fail "B-DF1: in operator mode a member must be probed at the mount, got: '$out'"
}

test_member_probe_host_uses_index_path() {
    local out
    out=$(CCO_WORKDIR=/ws _ps_probe no "my-repo" "/Users/alex/code/my-repo")
    [[ "$out" == "/Users/alex/code/my-repo" ]] \
        || fail "B-DF1: on the host the index path must pass through unchanged, got: '$out'"
}

test_member_probe_empty_name_falls_back() {
    local out
    # No name → nothing to build a mount path from; must not invent "/ws/".
    out=$(CCO_WORKDIR=/ws _ps_probe yes "" "/Users/alex/code/my-repo")
    [[ "$out" == "/Users/alex/code/my-repo" ]] \
        || fail "B-DF1: an empty name must fall back to the given path, got: '$out'"
}

test_member_probe_defaults_to_workspace() {
    local out
    out=$(_ps_probe yes "my-repo" "/Users/alex/code/my-repo")   # CCO_WORKDIR unset
    [[ "$out" == "/workspace/my-repo" ]] \
        || fail "B-DF1: the probe must default to the /workspace WORKDIR, got: '$out'"
}

# End-to-end on the classification itself: the same member that reads `code-only`
# (from `unresolved`) when probed at a non-existent host path must read `host`
# (synced) once probed at its mount — the exact B-DF1 mislabel.
_ps_role() {  # echoes the display role; operator stubbed per $1
    local operator="$1"; shift
    (
        source "$REPO_ROOT/lib/colors.sh";  source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/paths.sh";   source "$REPO_ROOT/lib/yaml.sh"
        source "$REPO_ROOT/lib/index.sh";   source "$REPO_ROOT/lib/sync-meta.sh"
        source "$REPO_ROOT/lib/cmd-project-query.sh"
        if [[ "$operator" == yes ]]; then _cco_container_operator() { return 0; }
        else _cco_container_operator() { return 1; }; fi
        # Isolate from the real index: the host path is deliberately absent, and the
        # fallback re-fetch must not consult a real store.
        _index_get_path() { printf '%s\n' "$2"; }
        _project_member_role "$@"
    )
}

test_member_role_operator_classifies_via_mount() {
    local ws; ws=$(mktemp -d); trap "rm -rf '$ws'" EXIT
    mkdir -p "$ws/my-repo/.cco"
    printf 'name: my-proj\n' > "$ws/my-repo/.cco/project.yml"
    local out
    # Host path absent (as it always is in-container); the mount carries the config.
    out=$(CCO_WORKDIR="$ws" _ps_role yes "/nonexistent/my-repo" "my-proj" "my-repo")
    [[ "$out" == "host" ]] \
        || fail "B-DF1: a mounted config-bearing member must classify as 'host', got: '$out'"
}

test_member_role_host_context_unaffected() {
    local ws; ws=$(mktemp -d); trap "rm -rf '$ws'" EXIT
    mkdir -p "$ws/my-repo/.cco"
    printf 'name: my-proj\n' > "$ws/my-repo/.cco/project.yml"
    local out
    # On the host an absent path is genuinely unresolved → code-only. Unchanged.
    out=$(CCO_WORKDIR="$ws" _ps_role no "/nonexistent/my-repo" "my-proj" "my-repo")
    [[ "$out" == "code-only" ]] \
        || fail "B-DF1: host classification must be unchanged (code-only), got: '$out'"
}

# ── S6 / v3 R4: `project show` asks the shared classifier ────────────────────
# The verb used to answer availability with ONE hardcoded sentence — it blamed
# ACCESS SCOPE and prescribed a scope widening — for two different realities. At
# read-all/edit-all nothing is hidden by scope and there is no widening left, so
# the sentence was simply false; meanwhile its sibling `project validate` gave the
# correct D-M2 answer for the same project in the same session. Three v3 sessions
# reported it from three vantages (V2-F04 ≡ V4-F-V4-02 ≡ V5-04) against one call
# site. Both arms below are pinned so the two states cannot re-converge on one
# spelling. Static counterpart: INV-ENV in test_invariants.sh.

# In scope (read-all sees every project) but NOT bound into this container.
# ⚠ FAILS on pre-fix: refuses "not available at this access scope … Widen the
# session's scope", naming a remedy that does not exist at read-all.
test_project_show_unmounted_is_not_a_scope_refusal() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" read-all alpha
    operator_mount_unit alpha alpha >/dev/null
    # beta: bound in the index to a host path that cannot exist here, never mounted.
    seed_index_path betarepo "/Users/cco-e2e/code/betarepo" beta
    index_set_project_repos beta betarepo

    local rc=0
    run_cco project show beta || rc=$?
    assert_refused "$rc" "${CCO_OUTPUT:-}" "not mounted in this session" || return 1
    [[ "$CCO_OUTPUT" != *"not available at this access scope"* ]] \
        || { fail "an unmounted project must not be reported as an access-scope problem: $CCO_OUTPUT"; return 1; }
    return 0
}

# The scope arm still refuses with the scope wording — replacing the local sentence
# with _env_unavailable must not cost the out-of-scope message (it routes back into
# _env_require_visible). Sibling of test_as_project_show_out_of_scope_refused.
test_project_show_out_of_scope_keeps_scope_wording() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" read-project alpha
    operator_mount_unit alpha alpha >/dev/null
    seed_index_path betarepo "/Users/cco-e2e/code/betarepo" beta
    index_set_project_repos beta betarepo

    local rc=0
    run_cco project show beta || rc=$?
    assert_refused "$rc" "${CCO_OUTPUT:-}" "not available at this access scope" || return 1
    return 0
}
