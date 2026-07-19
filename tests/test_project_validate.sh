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
