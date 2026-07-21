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

# ══════════════════════════════════════════════════════════════════════
# Container-operator lane (RC-2 / 04-host-path-class.md §6.4)
# ══════════════════════════════════════════════════════════════════════
# In a session the STATE index holds a HOST path that does not exist; the member
# is reachable only at the flat bind target <workdir>/<name>. `repo`/`extra-mount
# rename` write TWO independent stores (the index and project.yml), so the keystone
# brackets the WHOLE effect — asserting only the index certifies a half-apply.

# T1 — keystone. Measured: a fix that merely probes the mount at the strict guard
# returns rc=0 "✓ Renamed", re-keys the index, and leaves project.yml reading
# `- name: alpha` with the commit/push warning silently suppressed. Assertions (d)
# and (e) are what make this a keystone rather than a rubber stamp.
# ⚠ FAILS on pre-fix code: rc=1 at the host-path strict guard.
test_repo_rename_operator_probes_mount_not_host_path() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" edit-project alpha
    local mnt; mnt=$(operator_mount_unit alpha alpha)

    local rc=0
    _rr_cco_in "$mnt" repo rename alpha api -y || rc=$?

    # (a) the verb must complete
    assert_rc 0 "$rc" "operator repo rename" || return 1
    # (b)+(c) probe the mount, KEEP the host path: new key, unchanged value
    assert_index_path alpha api /Users/cco-e2e/code/alpha || return 1
    assert_index_path alpha alpha "" || return 1
    # (d) the OTHER store — the half-apply detector (§1.6)
    assert_projectyml_member "$mnt/.cco/project.yml" repos api        || return 1
    assert_projectyml_member "$mnt/.cco/project.yml" repos alpha absent || return 1
    # (e) the operator-facing consequence, suppressed by a half-apply
    assert_output_contains "Commit + push" || return 1
    assert_output_contains "$mnt" || return 1
    return 0
}

# T2 — host counterweight, deliberately GREEN before AND after: it proves the fix
# is scoped to operator mode and did not delete a real host-side guard. On the HOST
# an index binding that really is missing must still refuse, and refuse before any
# write ("not resolved on this machine" is stable across the vocabulary unification).
test_repo_rename_host_still_rejects_unresolved_member() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local unit="$tmp/repos/shop"; mkdir -p "$unit/.cco"
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
# In a session the member IS a bind-mount root, so the move must REFUSE (exit 2)
# with a host hint. ⚠ FAILS on pre-fix: rc=1 at the strict guard about `cco resolve`.
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

# cwd-first: `cco repo rename api` (one positional) from the mount resolves <old>
# through the mount basename (INV-F), not the index host path. ⚠ FAILS on pre-fix:
# "No repo is bound to /ws/alpha in project 'alpha'" (the index reverse lookup).
test_repo_rename_operator_cwd_first() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" edit-project alpha
    local mnt; mnt=$(operator_mount_unit alpha alpha)

    local rc=0
    _rr_cco_in "$mnt" repo rename api -y || rc=$?

    assert_rc 0 "$rc" "operator cwd-first repo rename" || return 1
    assert_index_path alpha api /Users/cco-e2e/code/alpha || return 1
    return 0
}

# E4-06: no host path leaks with show_host_paths off. ⚠ FAILS on pre-fix: the strict
# guard's die message interpolates the index host path verbatim.
test_repo_rename_operator_no_host_path_leak() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    OP_SHP=false setup_operator_session "$tmp" edit-project alpha
    local mnt; mnt=$(operator_mount_unit alpha alpha)

    local rc=0
    _rr_cco_in "$mnt" repo rename alpha api -y || rc=$?
    [[ "$CCO_OUTPUT" != *"/Users/cco-e2e"* ]] \
        || fail "operator repo rename leaked a host path with show_host_paths off: $CCO_OUTPUT" || return 1
    return 0
}

# §3.5 atomicity: an unwritable config tree refuses (exit 2) BEFORE any store is
# touched — never the silent half-apply of an index re-key with an unwritten
# project.yml. Skipped as root (mode bits are bypassed). ⚠ FAILS on pre-fix: rc=1
# at the strict guard, so the precondition property is untested there.
test_repo_rename_operator_unwritable_tree_is_atomic() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d); trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" edit-project alpha
    local mnt; mnt=$(operator_mount_unit alpha alpha)

    chmod 500 "$mnt/.cco"
    local rc=0
    _rr_cco_in "$mnt" repo rename alpha api -y || rc=$?
    chmod 700 "$mnt/.cco"

    assert_refused "$rc" "${CCO_OUTPUT:-}" "nothing was changed" || return 1
    # Fail-closed: nothing applied.
    assert_index_path alpha alpha /Users/cco-e2e/code/alpha || return 1
    assert_index_path alpha api "" || return 1
    return 0
}

# A member bound in the index whose mount is absent refuses with its own remedy
# (not-mounted → exit 2), never the "cco resolve" host-only hint. ⚠ FAILS on pre-fix:
# rc=1 with the wrong wording.
test_repo_rename_operator_not_mounted_refuses() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" edit-project shop
    local mnt; mnt=$(operator_mount_unit shop backend)
    # A second member bound in the index but NOT mounted (no <ws>/ghost).
    seed_index_path ghost "/Users/cco-e2e/code/ghost" shop
    index_set_project_repos shop backend ghost

    local rc=0
    _rr_cco_in "$mnt" repo rename ghost renamed -y || rc=$?

    assert_refused "$rc" "${CCO_OUTPUT:-}" "not mounted in this session" || return 1
    [[ "$CCO_OUTPUT" != *"cco resolve"* ]] \
        || fail "a not-mounted refusal must not say 'cco resolve': $CCO_OUTPUT" || return 1
    return 0
}

# ── V3-03 / D-M9 Q-6: the WORKDIR-root ambiguity refusal ────────────────────────
# Q-6 designed a refusal for bare `cco repo rename <new>` at the container WORKDIR
# root ("always refused as ambiguous, no single-repo fallback"). Its SAFETY always
# held, but the designed MESSAGE was unreachable: _resolve_find_unit_dir fails there
# first and answers "run from inside a project repo … or pass <old> <new>" — advice
# that describes the wrong problem (the session's project IS known at the root, via
# _project_session_fallback; it is the MEMBER that is ambiguous).
# ⚠ FAILS on pre-fix: the generic unit-resolution die fires instead.
test_repo_rename_workdir_root_bare_is_ambiguous() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" edit-project shop
    operator_mount_unit shop backend >/dev/null
    # The flat session manifest `cco start` writes at the WORKDIR root — what
    # _project_session_fallback keys on, and what makes the root distinguishable
    # from "some directory that happens to have no project".
    printf 'name: shop\n' > "$CCO_WORKDIR/project.yml"

    local rc=0
    _rr_cco_in "$CCO_WORKDIR" repo rename api -y || rc=$?

    [[ $rc -ne 0 ]] || fail "bare rename at the WORKDIR root must be refused, got rc=0" || return 1
    [[ "$CCO_OUTPUT" == *"ambiguous"* ]] \
        || fail "the refusal must name the ambiguity (Q-6), got: $CCO_OUTPUT" || return 1
    # The remedy must be followable FROM HERE. "pass <old> <new>" is not: the 2-arg
    # form dies at the same unit resolution at the WORKDIR root, so advising it
    # would ship a remedy that cannot be followed — the S7 trap, inverted.
    [[ "$CCO_OUTPUT" != *"pass <old> <new>"* ]] \
        || fail "must not advise the 2-arg form, which also fails here: $CCO_OUTPUT" || return 1
    return 0
}

# The converse: OUTSIDE a session and away from any project, the generic message is
# still the right one. This is what keeps the fix a NEW arm rather than a rewrite of
# the existing die — and pins that the ambiguity arm cannot swallow the host case.
test_repo_rename_host_outside_project_keeps_generic_message() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$tmp/nowhere"

    local rc=0
    _rr_cco_in "$tmp/nowhere" repo rename api -y || rc=$?

    [[ $rc -ne 0 ]] || fail "rename outside any project must fail, got rc=0" || return 1
    [[ "$CCO_OUTPUT" == *"from inside a project repo"* ]] \
        || fail "the host/no-project case must keep the generic message, got: $CCO_OUTPUT" || return 1
    [[ "$CCO_OUTPUT" != *"ambiguous"* ]] \
        || fail "the ambiguity arm must not fire outside a session: $CCO_OUTPUT" || return 1
    return 0
}

# extra_mount with an implicit target (mount at <ws>/<name>). ⚠ FAILS on pre-fix at
# the strict guard.
test_extra_mount_rename_operator_implicit_target() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" edit-project shop
    local mnt; mnt=$(operator_mount_unit shop backend)
    printf 'name: shop\nrepos:\n  - name: backend\nextra_mounts:\n  - name: assets\n' \
        > "$mnt/.cco/project.yml"
    seed_index_path assets "/Users/cco-e2e/code/assets" shop
    mkdir -p "$CCO_WORKDIR/assets"        # the implicit-target mount

    local rc=0
    _rr_cco_in "$mnt" extra-mount rename assets media -y || rc=$?

    assert_rc 0 "$rc" "operator extra-mount rename (implicit target)" || return 1
    assert_projectyml_member "$mnt/.cco/project.yml" extra_mounts media        || return 1
    assert_projectyml_member "$mnt/.cco/project.yml" extra_mounts assets absent || return 1
    return 0
}

# extra_mount with an EXPLICIT target: the mount exists ONLY there — the §1.7
# detector. ⚠ FAILS on pre-fix at the guard, AND on a target-blind fix with "not
# mounted in this session" (it would probe <ws>/assets, which does not exist).
test_extra_mount_rename_operator_explicit_target() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" edit-project shop
    local mnt; mnt=$(operator_mount_unit shop backend)
    mkdir -p "$CCO_WORKDIR/docs/assets"   # the explicit-target mount, NOT <ws>/assets
    printf 'name: shop\nrepos:\n  - name: backend\nextra_mounts:\n  - name: assets\n    target: %s\n' \
        "$CCO_WORKDIR/docs/assets" > "$mnt/.cco/project.yml"
    seed_index_path assets "/Users/cco-e2e/code/assets" shop

    local rc=0
    _rr_cco_in "$mnt" extra-mount rename assets media -y || rc=$?

    assert_rc 0 "$rc" "operator extra-mount rename (explicit target)" || return 1
    assert_projectyml_member "$mnt/.cco/project.yml" extra_mounts media || return 1
    return 0
}

# Host regression guard for the §3.3 apply reorder (project.yml FIRST, then index):
# a resolved host member is re-keyed in BOTH stores, identical to before.
test_repo_rename_host_apply_order_unchanged() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local dir; dir=$(_rr_project "$tmp" shop backend)

    _rr_cco_in "$dir" repo rename backend api -y || fail "$CCO_OUTPUT" || return 1

    assert_index_path shop api "$dir" || return 1
    assert_index_path shop backend "" || return 1
    assert_projectyml_member "$dir/.cco/project.yml" repos api        || return 1
    assert_projectyml_member "$dir/.cco/project.yml" repos backend absent || return 1
    return 0
}

# T-R2 — the v3 V3-01 regression guard: an index write that cannot complete must
# FAIL LOUD, not print `✓` over a half-apply.
#
# This is the exact shape v3 found in a live container. The verb writes the two
# stores in order — project.yml FIRST (RC-2's deliberate ordering), the STATE index
# second — and the index write failed EACCES because its bucket parent was not
# writable. Nothing surfaced it: _index_rename_path checked none of its three
# sub-writes, cmd-repo.sh called it bare, and bin/cco's `|| _cco_rc=$?` dispatch had
# already disabled errexit for the whole call tree. Result: rc=0, "✓ Renamed", and a
# project.yml re-keyed against an unchanged index — user-visible immediately as
# `cco project show` flipping to `Repos: (none)`.
#
# The assertions that make this a real guard rather than a smoke test are (b) and
# (c): a fix that merely returned non-zero without suppressing the success tick, or
# that suppressed the tick without a usable message, still fails here.
# ⚠ FAILS on pre-fix code: rc=0 with "✓ Renamed".
test_repo_rename_operator_unwritable_index_fails_loud() {
    [[ "$(id -u)" -eq 0 ]] && return 0   # root ignores the mode bits
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_operator_session "$tmp" edit-project alpha
    local mnt; mnt=$(operator_mount_unit alpha alpha)

    # Make the INDEX bucket unwritable while the config tree stays writable — the
    # precise asymmetry of the live failure (v3 root cause C: the fail-closed probe
    # guards <repo>/.cco, which was never the tree that failed).
    chmod 555 "$(state_shared)"
    local rc=0
    _rr_cco_in "$mnt" repo rename alpha api -y || rc=$?
    chmod 755 "$(state_shared)"

    # (a) non-zero exit — the store write could not complete
    [[ "$rc" -ne 0 ]] || { fail "unwritable index must fail loud; got rc=0: $CCO_OUTPUT"; return 1; }
    # (b) NO success tick over a failed write (the false-success class itself)
    [[ "$CCO_OUTPUT" != *"✓ Renamed"* ]] \
        || { fail "no success tick on a failed index write: $CCO_OUTPUT"; return 1; }
    # (c) the message must name the real cause AND a remedy — an honest failure the
    #     user cannot act on is only half a fix.
    [[ "$CCO_OUTPUT" == *"index"* ]] \
        || { fail "the failure must name the index as the store that failed: $CCO_OUTPUT"; return 1; }
    # (d) the index really is untouched — no partial re-key survived
    assert_index_path alpha alpha /Users/cco-e2e/code/alpha || return 1
    assert_index_path alpha api "" || return 1
    # (e) FAIL-CLOSED (S3): the refusal lands BEFORE Phase 1, so the OTHER store is
    #     untouched too — the rename wholly refuses rather than half-applying. This is
    #     the property S2 alone cannot give: S2 makes the mid-write failure loud and
    #     recoverable, S3 makes it not happen. Both paths stay: if the probe ever
    #     passes and the write still fails (a race, or a condition the probe cannot
    #     see), S2's die-with-which-store-changed is the backstop.
    assert_projectyml_member "$mnt/.cco/project.yml" repos alpha        || return 1
    assert_projectyml_member "$mnt/.cco/project.yml" repos api   absent || return 1
    return 0
}

# ── S2b: the project.yml half of the fan-out (the S1–S3 residual) ────────────
# S1–S3 closed the INDEX half of `repo rename`. The project.yml half stayed exposed
# through _yaml_rename_list_ref, which could not report failure: a failed `mv`
# returned 0, the member was counted as re-keyed, and the verb went on to write the
# index — leaving the two stores disagreeing with a ✓ on screen.
#
# S3's pre-flight probes the CWD unit's .cco ONLY, so the still-reachable case is a
# DIFFERENT member being unwritable (or ENOSPC mid-fan-out). That is exactly what
# this fixture builds: cwd = backend (writable, so the pre-flight passes), web
# unwritable. ⚠ FAILS on pre-fix: rc=0, ✓ printed, index re-keyed to 'api'.
test_repo_rename_unwritable_member_projectyml_fails_loud() {
    [[ "$(id -u)" -eq 0 ]] && return 0   # root ignores the mode bits
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local a="$tmp/repos/backend" b="$tmp/repos/web" y
    mkdir -p "$a/.cco" "$b/.cco"
    for y in "$a" "$b"; do
        cat > "$y/.cco/project.yml" <<'YAML'
name: shop
description: "t"
repos:
  - name: backend
  - name: web
YAML
    done
    seed_index_path backend "$a" shop
    seed_index_path web     "$b" shop
    index_set_project_repos shop backend web

    chmod 555 "$b/.cco"
    local rc=0
    _rr_cco_in "$a" repo rename backend api -y || rc=$?
    chmod 755 "$b/.cco"

    # (a) non-zero — the fan-out could not complete
    [[ "$rc" -ne 0 ]] \
        || { fail "an unpersistable member rewrite must fail loud; got rc=0: $CCO_OUTPUT"; return 1; }
    # (b) no success tick over a write that did not land
    [[ "$CCO_OUTPUT" != *"✓ Renamed"* ]] \
        || { fail "no success tick over a failed project.yml write: $CCO_OUTPUT"; return 1; }
    # (c) the message must name WHICH member could not be rewritten — a fan-out
    #     failure the user cannot localise is only half a fix.
    [[ "$CCO_OUTPUT" == *"$b"* ]] \
        || { fail "the failure must name the member repo that could not be rewritten: $CCO_OUTPUT"; return 1; }
    # (d) the index is the SECOND store and the die lands before it, so the two
    #     stores' disagreement stays one-directional and re-running is safe.
    [[ "$(_rr_get_path shop backend)" == "$a" ]] \
        || { fail "the index must be untouched: 'backend' lost its binding"; return 1; }
    [[ -z "$(_rr_get_path shop api)" ]] \
        || { fail "the index must be untouched: 'api' was bound despite the failure"; return 1; }
    return 0
}
