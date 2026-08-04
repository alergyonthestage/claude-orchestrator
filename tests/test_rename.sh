#!/usr/bin/env bash
# tests/test_rename.sh — lib/rename.sh shared machinery (ADR-0050 B.1).
#
# Unit-tests the pure, store-agnostic helpers: the YAML list-reference rewriter
# (_yaml_rename_list_ref, both scalar and mapping forms, section-scoped), its
# read-only companion (_yaml_list_has_ref), and the per-kind validator
# (_rename_validate). The project.yml fan-out helpers (_rename_projectyml_current
# / _rename_fanout_projectyml) are exercised end-to-end by the per-verb tests.

# Run a rename.sh function in a subshell with the real libs sourced (matches the
# harness seeders so behavior is identical to production). Echoes function output;
# return code is the function's. Usage: _rn <fn> <args...>
_rn() {
    ( set +e
      source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
      source "$REPO_ROOT/lib/paths.sh";  source "$REPO_ROOT/lib/index.sh"
      source "$REPO_ROOT/lib/rename.sh"
      "$@" )
}

# A project.yml-shaped fixture with every list form the rewriter must handle.
_rn_fixture() {
    cat <<'YAML'
name: demo
repos:
  - name: backend
    url: git@github.com:org/backend.git
    description: "API"
  - name: web
extra_mounts:
  - name: backend
    target: /workspace/aux
packs:
  - name: shared-pack
  - name: local.pack
llms:
  - svelte
  - name: shadcn-svelte
    description: "index"
YAML
}

# ── _yaml_rename_list_ref ────────────────────────────────────────────

test_yaml_rename_mapping_form() {
    local f; f=$(mktemp); trap "rm -f '$f'" EXIT
    _rn_fixture > "$f"
    _rn _yaml_rename_list_ref "$f" repos backend api || fail "expected a change" || return 1
    assert_file_contains "$f" "  - name: api" || return 1
    # repos[].name backend is now api; the entry's OTHER key lines are untouched
    assert_file_contains "$f" "    url: git@github.com:org/backend.git" || return 1
}

test_yaml_rename_is_section_scoped() {
    # Renaming 'backend' in repos: must NOT touch the identically-named
    # extra_mounts: entry (section-scoping is the load-bearing correctness rule).
    local f; f=$(mktemp); trap "rm -f '$f'" EXIT
    _rn_fixture > "$f"
    _rn _yaml_rename_list_ref "$f" repos backend api || return 1
    # extra_mounts still carries 'backend'
    awk '/^extra_mounts:/{s=1;next} /^[^ ]/{s=0} s&&/- name: backend/{f=1} END{exit f?0:1}' "$f" \
        || fail "extra_mounts 'backend' was wrongly rewritten" || return 1
}

test_yaml_rename_scalar_form() {
    local f; f=$(mktemp); trap "rm -f '$f'" EXIT
    _rn_fixture > "$f"
    _rn _yaml_rename_list_ref "$f" llms svelte svelte-5 || fail "expected a change" || return 1
    assert_file_contains "$f" "  - svelte-5" || return 1
    # the mapping-form llms entry is untouched
    assert_file_contains "$f" "  - name: shadcn-svelte" || return 1
}

test_yaml_rename_exact_match_no_overmatch() {
    # A name containing '.' must match literally, not as a regex wildcard.
    local f; f=$(mktemp); trap "rm -f '$f'" EXIT
    _rn_fixture > "$f"
    # 'local.pack' → 'localXpack' would be a false hit if '.' were a wildcard on
    # 'shared-pack'; assert shared-pack is untouched and local.pack renamed.
    _rn _yaml_rename_list_ref "$f" packs "local.pack" "localpack" || return 1
    assert_file_contains "$f" "  - name: localpack" || return 1
    assert_file_contains "$f" "  - name: shared-pack" || return 1
}

test_yaml_rename_no_match_returns_1() {
    local f; f=$(mktemp); trap "rm -f '$f'" EXIT
    _rn_fixture > "$f"
    local before; before=$(cat "$f")
    _rn _yaml_rename_list_ref "$f" repos nonexistent whatever \
        && fail "expected rc 1 for a name not present" || true
    [[ "$(cat "$f")" == "$before" ]] || fail "file changed despite no match" || return 1
}

test_yaml_rename_absent_section_returns_1() {
    local f; f=$(mktemp); trap "rm -f '$f'" EXIT
    printf 'name: demo\nrepos:\n  - name: backend\n' > "$f"
    _rn _yaml_rename_list_ref "$f" extra_mounts backend api \
        && fail "expected rc 1 when the section is absent" || true
}

# ── _yaml_list_has_ref ───────────────────────────────────────────────

test_yaml_has_ref_present_and_absent() {
    local f; f=$(mktemp); trap "rm -f '$f'" EXIT
    _rn_fixture > "$f"
    _rn _yaml_list_has_ref "$f" packs shared-pack || fail "shared-pack should be found" || return 1
    _rn _yaml_list_has_ref "$f" llms svelte      || fail "scalar svelte should be found" || return 1
    _rn _yaml_list_has_ref "$f" packs shared-pack-x && fail "prefix must not match" || true
    # section-scoping: 'web' lives in repos, not packs
    _rn _yaml_list_has_ref "$f" packs web && fail "cross-section false positive" || true
}

# ── _rename_validate ─────────────────────────────────────────────────

test_rename_validate_accepts_valid_names() {
    _rn _rename_validate repo my-new-repo   || fail "valid repo name rejected" || return 1
    _rn _rename_validate pack shared-pack2   || fail "valid pack name rejected" || return 1
    _rn _rename_validate llms Svelte.Kit_v2  || fail "valid llms name rejected" || return 1
}

test_rename_validate_rejects_bad_charset() {
    # die() exits non-zero; the subshell surfaces it.
    _rn _rename_validate repo "Bad Name"  && fail "space accepted" || true
    _rn _rename_validate repo "UPPER"     && fail "uppercase accepted for repo" || true
    _rn _rename_validate pack "-leading"  && fail "leading hyphen accepted" || true
    _rn _rename_validate llms "bad/slash" && fail "slash accepted for llms" || true
}

test_rename_validate_rejects_reserved() {
    _rn _rename_validate repo global        && fail "reserved 'global' accepted" || true
    _rn _rename_validate pack all           && fail "reserved 'all' accepted" || true
    _rn _rename_validate template tutorial  && fail "reserved 'tutorial' accepted" || true
    _rn _rename_validate remote config-editor && fail "reserved 'config-editor' accepted" || true
}

# ── S2b: _yaml_rename_list_ref's three-valued contract ──────────────
# The primitive could not report failure, and its two failure modes lied in
# OPPOSITE directions: a failed `mv` returned 0, so the file was reported as
# REWRITTEN and the caller counted the member as re-keyed; a failed mktemp (or an
# awk that errored rather than finding nothing) returned 1, which every caller
# reads as the benign "nothing to rewrite" and skips in silence. Neither surfaces:
# bin/cco dispatches verbs as `cmd_foo "$@" || _cco_rc=$?`, and a `||` context
# disables errexit for the whole call tree. Contract now: 0 rewritten (durably) /
# 1 no change / 2 attempted and NOT persisted. Same shape as S2b-P's token
# primitive — absence and failure must never share a code.

# ⚠ FAILS on pre-fix: rc=1, indistinguishable from "this file has no such ref".
test_yaml_rename_unpersistable_returns_2() {
    [[ "$(id -u)" -eq 0 ]] && return 0   # root ignores the mode bits
    local d; d=$(mktemp -d); trap "chmod -R u+rwX '$d' 2>/dev/null; rm -rf '$d'" EXIT
    local f="$d/project.yml"; _rn_fixture > "$f"
    local before; before=$(cat "$f")
    chmod 555 "$d"                       # no sibling temp can be created here
    local rc=0
    _rn _yaml_rename_list_ref "$f" repos backend api || rc=$?
    chmod 755 "$d"
    [[ "$rc" -eq 2 ]] \
        || { fail "an unpersistable rewrite must return 2 — not 0 ('rewritten') and not 1 ('no change'); got rc=$rc"; return 1; }
    [[ "$(cat "$f")" == "$before" ]] \
        || { fail "a failed rewrite must leave the file byte-identical"; return 1; }
    return 0
}

# The discriminator that makes the contract usable: "this file does not reference
# <old>" must STAY 1. Folding it into 2 would make every unrelated member repo in a
# fan-out look like a failed write — trading a silent failure for a loud false one.
test_yaml_rename_absent_ref_stays_1_not_2() {
    local d; d=$(mktemp -d); trap "rm -rf '$d'" EXIT
    local f="$d/project.yml"; _rn_fixture > "$f"
    local rc=0
    _rn _yaml_rename_list_ref "$f" repos nonexistent whatever || rc=$?
    [[ "$rc" -eq 1 ]] \
        || { fail "a reference that is simply absent must return 1 (benign), got rc=$rc"; return 1; }
    return 0
}
