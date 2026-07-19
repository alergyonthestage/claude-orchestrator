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
