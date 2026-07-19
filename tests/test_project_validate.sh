#!/usr/bin/env bash
# tests/test_project_validate.sh — `cco project validate` share-readiness
# (ADR-0023 D2; carries the ADR-0022 D4 pack-collision ERROR). Detect-only,
# never blocks (P14/P17). Exit = max severity: 0 share-ready · 1 reachability/
# coordinate gap · 2 path leak / duplicate id / pack collision. Greppable
# output; quiet on success unless -v.

# Run `cco <args>` from <dir>, capturing rc + CCO_OUTPUT. The env (CCO_*_HOME,
# CONFIG/PACKS/...) is exported by setup_cco_env, so a plain bin/cco inherits it.
# Usage: _pv_in <dir> <args...>
_pv_in() {
    local dir="$1"; shift
    local rc=0
    CCO_OUTPUT=$(cd "$dir" && bash "$REPO_ROOT/bin/cco" "$@" 2>&1) || rc=$?
    return $rc
}

# The host repo dir create_project lays down, used for cwd-first runs.
_pv_repo() { printf '%s' "$1/repos/$2"; }

# ── clean / success ──────────────────────────────────────────────────────

test_project_validate_clean_is_share_ready() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "clean" "$(cat <<'YAML'
name: clean
repos:
  - name: backend
    url: git@github.com:org/backend.git
    ref: main
llms:
  - name: react
    url: https://react.dev/llms-full.txt
YAML
)"
    local rc=0
    _pv_in "$(_pv_repo "$tmpdir" clean)" project validate || rc=$?
    assert_equals 0 "$rc"
    # quiet on success
    assert_output_not_contains "validate:"
}

test_project_validate_verbose_reports_success() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "clean" "$(cat <<'YAML'
name: clean
repos:
  - name: backend
    url: git@github.com:org/backend.git
YAML
)"
    local rc=0
    _pv_in "$(_pv_repo "$tmpdir" clean)" project validate -v || rc=$?
    assert_equals 0 "$rc"
    assert_output_contains "share-ready"
}

# ── exit 1: reachability / coordinate gaps ───────────────────────────────

test_project_validate_repo_without_url_is_gap() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "gap" "$(cat <<'YAML'
name: gap
repos:
  - name: backend
YAML
)"
    local rc=0
    _pv_in "$(_pv_repo "$tmpdir" gap)" project validate || rc=$?
    assert_equals 1 "$rc"
    assert_output_contains "repos.backend: no coordinate"
    assert_output_contains "reachability=1"
}

test_project_validate_llms_without_url_is_gap() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "lgap" "$(cat <<'YAML'
name: lgap
repos:
  - name: backend
    url: git@github.com:org/backend.git
llms:
  - name: react
YAML
)"
    local rc=0
    _pv_in "$(_pv_repo "$tmpdir" lgap)" project validate || rc=$?
    assert_equals 1 "$rc"
    assert_output_contains "llms.react: no coordinate"
}

test_project_validate_mount_without_url_is_gap_target_exempt() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    # The mount has only a (container-side, absolute) target and no url: that is
    # a coordinate gap (exit 1), and the absolute `target` must NOT be flagged.
    create_project "$tmpdir" "mgap" "$(cat <<'YAML'
name: mgap
repos:
  - name: backend
    url: git@github.com:org/backend.git
extra_mounts:
  - name: data
    target: /workspace/data
YAML
)"
    local rc=0
    _pv_in "$(_pv_repo "$tmpdir" mgap)" project validate || rc=$?
    assert_equals 1 "$rc"
    assert_output_contains "extra_mounts.data: no coordinate"
    assert_output_not_contains "real/absolute path '/workspace/data'"
}

# ── exit 2: machine-agnostic path leaks ──────────────────────────────────

test_project_validate_abspath_url_is_error() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "leak" "$(cat <<'YAML'
name: leak
repos:
  - name: backend
    url: /Users/me/dev/backend
YAML
)"
    local rc=0
    _pv_in "$(_pv_repo "$tmpdir" leak)" project validate || rc=$?
    assert_equals 2 "$rc"
    assert_output_contains "repos.backend: url is a real/absolute path"
    assert_output_contains "agnostic=1"
}

test_project_validate_stray_path_key_is_error() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    # The rejected D3 inline-path flow: a hand-edited path: key in committed
    # config. Reported (exit 2), never stripped.
    create_project "$tmpdir" "stray" "$(cat <<'YAML'
name: stray
repos:
  - name: backend
    url: git@github.com:org/backend.git
    path: /Users/me/dev/backend
YAML
)"
    local rc=0
    _pv_in "$(_pv_repo "$tmpdir" stray)" project validate || rc=$?
    assert_equals 2 "$rc"
    assert_output_contains "forbidden 'path: /Users/me/dev/backend'"
}

# ── exit 2: duplicate ids ────────────────────────────────────────────────

test_project_validate_duplicate_id_is_error() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "dup" "$(cat <<'YAML'
name: dup
repos:
  - name: backend
    url: git@github.com:org/backend.git
  - name: backend
    url: git@github.com:org/backend2.git
YAML
)"
    local rc=0
    _pv_in "$(_pv_repo "$tmpdir" dup)" project validate || rc=$?
    assert_equals 2 "$rc"
    assert_output_contains "repos.backend: duplicate id"
    assert_output_contains "uniqueness=1"
}

# ── exit 2: pack collision (ADR-0022 D4) ─────────────────────────────────

test_project_validate_pack_collision_is_error() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "coll" "$(cat <<'YAML'
name: coll
repos:
  - name: backend
    url: git@github.com:org/backend.git
packs:
  - shared
YAML
)"
    # The authored pack lives in the repo AND a same-named global pack exists →
    # mount precedence runs the wrong one (silent-wrong-build).
    mkdir -p "$(host_cco_dir "$tmpdir" coll)/packs/shared"
    mkdir -p "$CCO_PACKS_DIR/shared"
    local rc=0
    _pv_in "$(_pv_repo "$tmpdir" coll)" project validate || rc=$?
    assert_equals 2 "$rc"
    assert_output_contains "packs.shared:"
    assert_output_contains "collision=1"
}

test_project_validate_authored_pack_no_collision_is_clean() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "auth" "$(cat <<'YAML'
name: auth
repos:
  - name: backend
    url: git@github.com:org/backend.git
packs:
  - local-guide
YAML
)"
    # Authored pack present only in the repo (no global same-name) → share-ready.
    mkdir -p "$(host_cco_dir "$tmpdir" auth)/packs/local-guide"
    local rc=0
    _pv_in "$(_pv_repo "$tmpdir" auth)" project validate || rc=$?
    assert_equals 0 "$rc"
}

# ── P15 discriminator: coordinate presence = cache vs authored source ─────
# These pin the load-bearing P15 rule (ADR-0019 D3 / design §2.4): the PRESENCE
# of a coordinate (url) marks a pack as a cache of an upstream; its ABSENCE marks
# an authored-in-repo source. The discriminator lives in `cco project validate`,
# not the url-agnostic mount resolver (_pack_resolve_dir). A delta-green run could
# otherwise mask a regression that treated a url-bearing pack as a source (or
# vice-versa) — a silent-wrong-build.

test_pack_with_coordinate_is_cache_not_source() {
    # SAME physical layout as the collision ERROR test (pack in BOTH the repo and
    # ~/.cco/packs) but the entry carries a url → it is a CACHE, so the D4
    # silent-wrong-build collision must NOT fire. The url flips ERROR → clean.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "cachepack" "$(cat <<'YAML'
name: cachepack
repos:
  - name: backend
    url: git@github.com:org/backend.git
packs:
  - name: shared
    url: https://example.com/sharing.git
YAML
)"
    mkdir -p "$(host_cco_dir "$tmpdir" cachepack)/packs/shared"
    mkdir -p "$CCO_PACKS_DIR/shared"
    local rc=0
    _pv_in "$(_pv_repo "$tmpdir" cachepack)" project validate || rc=$?
    assert_equals 0 "$rc"
    assert_output_not_contains "collision"
    assert_output_not_contains "packs.shared"
}

test_pack_without_coordinate_is_authored_source() {
    # A url-less pack is an authored-in-repo source: it MUST exist at
    # <repo>/.cco/packs/<name>. With no source anywhere, validate flags a
    # reachability gap (sev 1) — the authored half of the discriminator.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "authsrc" "$(cat <<'YAML'
name: authsrc
repos:
  - name: backend
    url: git@github.com:org/backend.git
packs:
  - orphan-pack
YAML
)"
    # orphan-pack created NOWHERE (neither repo nor ~/.cco/packs).
    local rc=0
    _pv_in "$(_pv_repo "$tmpdir" authsrc)" project validate || rc=$?
    assert_equals 1 "$rc"
    assert_output_contains "packs.orphan-pack:"
    assert_output_contains "no source"
    assert_output_contains "reachability=1"
}

# ── severity is the numeric max ──────────────────────────────────────────

test_project_validate_exit_is_max_severity() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    # A reachability gap (sev 1) AND a path leak (sev 2) → exit 2.
    create_project "$tmpdir" "mixed" "$(cat <<'YAML'
name: mixed
repos:
  - name: gapless
  - name: leaky
    url: /Users/me/x
YAML
)"
    local rc=0
    _pv_in "$(_pv_repo "$tmpdir" mixed)" project validate || rc=$?
    assert_equals 2 "$rc"
    assert_output_contains "reachability=1"
    assert_output_contains "agnostic=1"
}

# ── resolution: cwd-first, by-name, --all ────────────────────────────────

test_project_validate_by_name() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "named" "$(cat <<'YAML'
name: named
repos:
  - name: backend
YAML
)"
    # Run from OUTSIDE the repo; resolve by name via the index.
    local rc=0
    _pv_in "$tmpdir" project validate named || rc=$?
    assert_equals 1 "$rc"
    assert_output_contains "repos.backend: no coordinate"
}

test_project_validate_all_iterates_projects() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "good" "$(cat <<'YAML'
name: good
repos:
  - name: backend
    url: git@github.com:org/backend.git
YAML
)"
    create_project "$tmpdir" "bad" "$(cat <<'YAML'
name: bad
repos:
  - name: frontend
YAML
)"
    local rc=0
    _pv_in "$tmpdir" project validate --all || rc=$?
    assert_equals 1 "$rc"
    assert_output_contains "[bad]"
    assert_output_contains "repos.frontend: no coordinate"
}

# ── --reachable: offline-deterministic via a local bare repo ─────────────

test_project_validate_reachable_local_bare_repo() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    # A real, reachable git remote: a local bare repo addressed as file:// (so it
    # is not flagged as an absolute path). git ls-remote works offline.
    local bare="$tmpdir/bare.git"
    git init --bare -q "$bare"
    create_project "$tmpdir" "reach" "$(cat <<YAML
name: reach
repos:
  - name: backend
    url: file://$bare
YAML
)"
    local rc=0
    _pv_in "$(_pv_repo "$tmpdir" reach)" project validate --reachable || rc=$?
    assert_equals 0 "$rc"
}

test_project_validate_reachable_flags_unreachable() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    create_project "$tmpdir" "unreach" "$(cat <<YAML
name: unreach
repos:
  - name: backend
    url: file://$tmpdir/does-not-exist.git
YAML
)"
    local rc=0
    _pv_in "$(_pv_repo "$tmpdir" unreach)" project validate --reachable || rc=$?
    assert_equals 1 "$rc"
    assert_output_contains "not reachable"
}

# ── never blocks: detect-only, exit-code only ────────────────────────────

test_project_validate_help() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local rc=0
    _pv_in "$tmpdir" project validate --help || rc=$?
    assert_equals 0 "$rc"
    assert_output_contains "Detect-only"
    assert_output_contains "--reachable"
}

# ══════════════════════════════════════════════════════════════════════
# Container-operator lane (RC-2 class / 04-host-path-class.md §6.3)
# ══════════════════════════════════════════════════════════════════════
# `cco project validate <name>` resolved the unit through the host-only index
# resolver, so a mounted project died "not found" in a session. It now resolves
# through the operator-aware pair (_resolve_project_yml + _resolve_project_cco_dir).

# T3 — the keystone. Asserted POSITIVELY (rc 0 + a success marker); "assert it is
# not reported unresolved" would be the same negative-space error this lane bans.
# ⚠ FAILS on pre-fix: rc=1 "Project 'alpha' not found (… run 'cco resolve alpha')".
test_project_validate_operator_sees_mounted_member() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" read-project alpha
    local mnt; mnt=$(operator_mount_unit alpha alpha)
    cat > "$mnt/.cco/project.yml" <<'YAML'
name: alpha
repos:
  - name: alpha
    url: git@github.com:org/alpha.git
    ref: main
YAML
    local rc=0
    _pv_in "$mnt" project validate alpha -v || rc=$?
    assert_rc 0 "$rc" "operator project validate <name>" || return 1
    assert_output_contains "share-ready" || return 1
    return 0
}

# --all validates the MOUNTED project instead of skipping it, and never speaks the
# host-only "cco resolve" remedy in a session. ⚠ FAILS on pre-fix: stdout empty,
# stderr "skipping 'alpha' — its repo is unresolved here (run 'cco resolve alpha')".
test_validate_all_validates_mounted_project() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" read-project alpha
    local mnt; mnt=$(operator_mount_unit alpha alpha)
    cat > "$mnt/.cco/project.yml" <<'YAML'
name: alpha
repos:
  - name: alpha
    url: git@github.com:org/alpha.git
YAML
    local rc=0
    _pv_in "$mnt" project validate --all -v || rc=$?
    assert_rc 0 "$rc" "operator project validate --all" || return 1
    assert_output_contains "[alpha]" || return 1
    [[ "$CCO_OUTPUT" != *"cco resolve"* ]] \
        || fail "--all must not speak 'cco resolve' in a session: $CCO_OUTPUT" || return 1
    return 0
}

# read-all: a second project bound in the index but unmounted is COUNTED ("not
# mounted in this session"), while the mounted project is still validated.
# ⚠ FAILS on pre-fix: both are skipped as "unresolved here".
test_validate_all_notes_unmounted_at_read_all() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" read-all alpha
    local mnt; mnt=$(operator_mount_unit alpha alpha)
    cat > "$mnt/.cco/project.yml" <<'YAML'
name: alpha
repos:
  - name: alpha
    url: git@github.com:org/alpha.git
YAML
    # A second project in the index, bound but NOT mounted.
    seed_index_path betarepo "/Users/cco-e2e/code/betarepo" beta
    index_set_project_repos beta betarepo

    local rc=0
    _pv_in "$mnt" project validate --all || rc=$?
    assert_output_contains "[alpha]" || return 1
    assert_output_contains "not mounted in this session" || return 1
    [[ "$CCO_OUTPUT" != *"cco resolve"* ]] \
        || fail "the unmounted notice must not say 'cco resolve': $CCO_OUTPUT" || return 1
    return 0
}

# §3.2 step 2: a mounted project's authored-pack collision (both ~/.cco/packs/p1 and
# <repo>/.cco/packs/p1 present, no url) is flagged. ⚠ FAILS on pre-fix: rc=1 "not
# found" before any pack check runs.
test_validate_named_finds_authored_pack_collision() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" read-project alpha
    local mnt; mnt=$(operator_mount_unit alpha alpha)
    printf 'name: alpha\nrepos:\n  - name: alpha\n    url: git@github.com:org/alpha.git\npacks:\n  - name: p1\n' \
        > "$mnt/.cco/project.yml"
    mkdir -p "$mnt/.cco/packs/p1" "$CCO_PACKS_DIR/p1"

    local rc=0
    _pv_in "$mnt" project validate alpha || rc=$?
    assert_rc 2 "$rc" "authored-pack collision is a severity-2 finding" || return 1
    assert_output_contains "collides with a same-named" || return 1
    return 0
}

# An operator layout whose .cco directory is not reachable SKIPS the authored-pack
# checks (one informational line) rather than silently inverting them. ⚠ FAILS on
# pre-fix: rc=1 "not found" (the by-name resolver never reaches the pack checks).
test_validate_packs_skipped_when_cco_dir_absent() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" read-project solo
    # A FLAT session manifest at the WORKDIR root, no <ws>/<repo>/.cco to resolve.
    printf 'name: solo\nrepos:\n  - name: solo\n    url: git@github.com:org/solo.git\npacks:\n  - name: p1\n' \
        > "$CCO_WORKDIR/project.yml"

    local rc=0
    _pv_in "$CCO_WORKDIR" project validate solo || rc=$?
    assert_rc 0 "$rc" "cco_dir-absent validate is share-ready (checks skipped)" || return 1
    assert_output_contains "authored-pack checks skipped" || return 1
    [[ "$CCO_OUTPUT" != *"authored pack has no source"* ]] \
        || fail "a skipped check must not fire a false sourceless finding: $CCO_OUTPUT" || return 1
    return 0
}

# A config-editor edit target resolves through the CCO_CONFIG_TARGETS branch
# (E5-05/E5-06). ⚠ FAILS on pre-fix: rc=1 "not found".
test_validate_config_editor_target() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    OP_TARGETS=cave-auth setup_operator_session "$tmp" edit-global config-editor
    mkdir -p "$CCO_WORKDIR/cave-auth-config"
    printf 'name: cave-auth\nrepos:\n  - name: cave-auth\n    url: git@github.com:org/cave-auth.git\n' \
        > "$CCO_WORKDIR/cave-auth-config/project.yml"

    local rc=0
    _pv_in "$CCO_WORKDIR" project validate cave-auth -v || rc=$?
    assert_rc 0 "$rc" "config-editor target validate" || return 1
    assert_output_contains "share-ready" || return 1
    return 0
}

# Regression guard (passes today AND after): an out-of-scope named project is still
# refused (exit 2), now through the single classifier.
test_validate_named_out_of_scope_still_refuses() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" read-project alpha
    local mnt; mnt=$(operator_mount_unit alpha alpha)

    local rc=0
    _pv_in "$mnt" project validate beta || rc=$?
    assert_rc 2 "$rc" "an out-of-scope named project must refuse" || return 1
    return 0
}
