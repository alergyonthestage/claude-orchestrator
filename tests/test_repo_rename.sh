#!/usr/bin/env bash
# tests/test_repo_rename.sh — `cco repo rename` / `cco extra-mount rename`
# (ADR-0050 B.3, index-keyed kinds). These are PROJECT-SCOPED and PATH-ANCHORED
# (ADR-0051 D1): rename re-keys only the current project's binding + its
# project.yml entry; another project's same-named-different-path binding and its
# same-path label are left untouched. The directory move is opt-in (D4).

# Read the scoped index through the real API (subshell-sourced, like the seeders).
_rr_get_path() {
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
      source "$REPO_ROOT/lib/paths.sh";  source "$REPO_ROOT/lib/index.sh"
      _index_get_path "$1" "$2" )
}
_rr_members() {
    ( source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
      source "$REPO_ROOT/lib/paths.sh";  source "$REPO_ROOT/lib/index.sh"
      _index_get_project_repos "$1" )
}

# Run bin/cco from inside <dir> (cwd-first verbs need a project repo cwd).
# Sets CCO_OUTPUT; returns cco's exit code.
_rr_cco_in() {
    local dir="$1"; shift
    local rc=0
    CCO_OUTPUT=$(cd "$dir" && \
        CCO_USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR" CCO_PACKS_DIR="$CCO_PACKS_DIR" \
        CCO_TEMPLATES_DIR="$CCO_TEMPLATES_DIR" CCO_LLMS_DIR="$CCO_LLMS_DIR" \
        bash "$REPO_ROOT/bin/cco" "$@" 2>&1) || rc=$?
    return $rc
}

# Create project <proj> whose member repo <repo> lives at repos/<repo> and hosts a
# committed project.yml (name: proj; repos: - name: repo; extra_mounts: - name:
# assets). Seeds the scoped index (repo + the assets mount). Echoes the repo dir.
_rr_project() {
    local tmp="$1" proj="$2" repo="$3"
    local dir="${4:-$tmp/repos/$repo}"
    mkdir -p "$dir/.cco/claude" "$tmp/mounts/$proj-assets"
    cat > "$dir/.cco/project.yml" <<YAML
name: $proj
description: "t"
repos:
  - name: $repo
    description: "member"
extra_mounts:
  - name: assets
    target: /workspace/aux
YAML
    seed_index_path "$repo"   "$dir"                     "$proj"
    seed_index_path "assets"  "$tmp/mounts/$proj-assets" "$proj"
    index_set_project_repos "$proj" "$repo" "assets"
    printf '%s' "$dir"
}

# ── repo rename ──────────────────────────────────────────────────────

test_repo_rename_rekeys_index_and_projectyml() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local dir; dir=$(_rr_project "$tmp" shop backend)

    _rr_cco_in "$dir" repo rename backend api -y || fail "rename failed: $CCO_OUTPUT" || return 1

    [[ "$(_rr_get_path shop api)" == "$dir" ]] || fail "index: api must carry the path, got '$(_rr_get_path shop api)'" || return 1
    [[ -z "$(_rr_get_path shop backend)" ]]    || fail "index: old name must be gone" || return 1
    [[ "$(_rr_members shop)" == "api assets" ]] || fail "membership: got '$(_rr_members shop)'" || return 1
    assert_file_contains "$dir/.cco/project.yml" "  - name: api" || return 1
    assert_file_not_contains "$dir/.cco/project.yml" "- name: backend" || return 1
    # extra_mounts section untouched (section-scoping)
    assert_file_contains "$dir/.cco/project.yml" "  - name: assets" || return 1
}

test_repo_rename_cwd_first() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local dir; dir=$(_rr_project "$tmp" shop backend)

    # <old> omitted → the repo hosting cwd (backend) is renamed.
    _rr_cco_in "$dir" repo rename core -y || fail "cwd-first rename failed: $CCO_OUTPUT" || return 1
    [[ "$(_rr_get_path shop core)" == "$dir" ]] || fail "cwd-first: got '$(_rr_get_path shop core)'" || return 1
    [[ -z "$(_rr_get_path shop backend)" ]]     || fail "cwd-first: old gone" || return 1
}

test_repo_rename_is_project_scoped() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local dirA; dirA=$(_rr_project "$tmp" proj-a backend "$tmp/repos/a-backend")
    local dirB; dirB=$(_rr_project "$tmp" proj-b backend "$tmp/repos/b-backend")   # homonym, DIFFERENT path

    _rr_cco_in "$dirA" repo rename backend api -y || fail "$CCO_OUTPUT" || return 1

    # proj-b's same-named-but-different-path binding is a different resource → untouched.
    [[ "$(_rr_get_path proj-b backend)" == "$dirB" ]] || fail "proj-b homonym must be untouched" || return 1
    [[ "$(_rr_members proj-b)" == "backend assets" ]]  || fail "proj-b membership untouched" || return 1
    assert_file_contains "$dirB/.cco/project.yml" "  - name: backend" || return 1
}

test_repo_rename_move_dir() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local dir; dir=$(_rr_project "$tmp" shop backend)   # dir basename == 'backend'

    _rr_cco_in "$dir" repo rename backend api --move-dir -y || fail "$CCO_OUTPUT" || return 1

    local newdir="$tmp/repos/api"
    assert_dir_exists "$newdir" || return 1
    assert_dir_not_exists "$dir" || return 1
    [[ "$(_rr_get_path shop api)" == "$newdir" ]] || fail "index path must follow the move, got '$(_rr_get_path shop api)'" || return 1
}

test_repo_rename_move_dir_refused_when_basename_differs() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    # member 'backend' whose dir basename is 'srv' (≠ old) → --move-dir must refuse.
    local dir="$tmp/repos/srv"
    mkdir -p "$dir/.cco/claude"
    printf 'name: shop\nrepos:\n  - name: backend\n' > "$dir/.cco/project.yml"
    seed_index_path backend "$dir" shop
    index_set_project_repos shop backend

    _rr_cco_in "$dir" repo rename backend api --move-dir -y \
        && fail "expected refusal when basename != old" || true
    assert_dir_exists "$dir" || return 1
}

test_repo_rename_rejects_duplicate_and_invalid() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local dir; dir=$(_rr_project "$tmp" shop backend)

    # new name already used in this project (the 'assets' mount name is index-bound)
    _rr_cco_in "$dir" repo rename backend assets -y \
        && fail "expected refusal renaming onto an in-use name" || true
    # invalid charset
    _rr_cco_in "$dir" repo rename backend "Bad Name" -y \
        && fail "expected refusal on invalid name" || true
    # unchanged
    [[ "$(_rr_get_path shop backend)" == "$dir" ]] || fail "binding must survive rejected renames" || return 1
}

# ── extra-mount rename ───────────────────────────────────────────────

test_extra_mount_rename_rekeys() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local dir; dir=$(_rr_project "$tmp" shop backend)

    _rr_cco_in "$dir" extra-mount rename assets media -y || fail "$CCO_OUTPUT" || return 1

    [[ -n "$(_rr_get_path shop media)" ]]   || fail "media must be bound" || return 1
    [[ -z "$(_rr_get_path shop assets)" ]]  || fail "assets must be gone" || return 1
    [[ "$(_rr_members shop)" == "backend media" ]] || fail "membership: got '$(_rr_members shop)'" || return 1
    assert_file_contains "$dir/.cco/project.yml" "  - name: media" || return 1
    # repos section untouched
    assert_file_contains "$dir/.cco/project.yml" "  - name: backend" || return 1
}

test_extra_mount_rename_requires_old() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local dir; dir=$(_rr_project "$tmp" shop backend)
    # no cwd-first for extra-mount: a single positional is a usage error
    _rr_cco_in "$dir" extra-mount rename media -y \
        && fail "extra-mount rename must require <old> <new>" || true
}

# ── Container-operator lane (RC-17 keystone / RC-2) ──────────────────
# In a session the STATE index holds a HOST path that does not exist; the member
# is reachable only at the flat bind target <workdir>/<name>. `repo rename` writes
# TWO independent stores — the index and project.yml — so the assertions below
# bracket the WHOLE effect. Asserting only the index certifies a half-apply:
# measured, a fix that merely probes the mount at the strict guard returns rc=0
# "✓ Renamed", re-keys the index, and leaves project.yml reading `- name: alpha`
# with the commit/push warning silently suppressed.

# ⚠ EXPECTED TO FAIL until RC-2 lands (04-host-path-class.md). This is the
# failing reproduction that stage must turn green, not a regression.
test_repo_rename_operator_probes_mount_not_host_path() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" edit-project alpha
    local mnt; mnt=$(operator_mount_unit alpha alpha)

    local rc=0
    _rr_cco_in "$mnt" repo rename alpha api -y || rc=$?

    # (a) The verb must complete. Today: rc=1 from lib/cmd-repo.sh's strict guard,
    #     `Member 'alpha' is not resolved on this machine (/Users/… is missing)` —
    #     it existence-tests the index HOST path instead of the mount.
    assert_rc 0 "$rc" "operator repo rename" || return 1
    # (b)+(c) Probe the mount, KEEP the host path: new key, unchanged value.
    assert_index_path alpha api /Users/cco-e2e/code/alpha || return 1
    assert_index_path alpha alpha "" || return 1
    # (d) The OTHER store. The mount is keyed by the member's OLD name for the
    #     whole session, so any mount probe performed AFTER the index re-key
    #     resolves to a path that does not exist — a fix that satisfies (a)-(c)
    #     but not this one is a half-apply, and it must fail loudly here.
    assert_projectyml_member "$mnt/.cco/project.yml" repos api        || return 1
    assert_projectyml_member "$mnt/.cco/project.yml" repos alpha absent || return 1
    # (e) The operator-facing consequence: the reminder is emitted only when the
    #     project.yml rewrite actually changed something, so a half-apply
    #     suppresses it SILENTLY, producing no error of its own.
    assert_output_contains "Commit + push" || return 1
    assert_output_contains "$mnt" || return 1
    return 0
}

# Counterweight to the test above (deliberately passes before AND after): the
# strict guard is scoped to operator mode, not deleted. On the HOST an index
# binding that really is missing must still refuse, and refuse before any write.
test_repo_rename_host_still_rejects_unresolved_member() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local unit="$tmp/repos/shop"
    mkdir -p "$unit/.cco"
    printf 'name: shop\nrepos:\n  - name: backend\n' > "$unit/.cco/project.yml"
    seed_index_path backend "$tmp/gone/backend" shop
    index_set_project_repos shop backend

    local rc=0
    _rr_cco_in "$unit" repo rename backend api -y || rc=$?

    assert_rc 1 "$rc" "host repo rename with a genuinely unresolved member" || return 1
    assert_output_contains "not resolved on this machine" || return 1
    # Fail-closed: neither store was touched.
    assert_index_path shop backend "$tmp/gone/backend" || return 1
    assert_index_path shop api "" || return 1
    return 0
}

# D-M9/Q-5: --move-dir is explicit user intent and is never silently downgraded.
# In a session the member IS a bind-mount root, so the move cannot work; the verb
# must REFUSE (exit 2) with a host hint rather than degrade to a name-only rename.
# ⚠ EXPECTED TO FAIL until RC-2 lands: today it dies rc=1 at the strict guard,
# with a message about `cco resolve` that names neither the real cause nor the remedy.
test_repo_rename_operator_move_dir_refused() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" edit-project alpha
    local mnt; mnt=$(operator_mount_unit alpha alpha)

    local rc=0
    _rr_cco_in "$mnt" repo rename alpha api --move-dir -y || rc=$?

    assert_refused "$rc" "${CCO_OUTPUT:-}" "on your host" || return 1
    # A refusal is fail-closed: the name-only half must NOT have been applied either.
    assert_index_path alpha alpha /Users/cco-e2e/code/alpha || return 1
    assert_index_path alpha api "" || return 1
    return 0
}
