#!/usr/bin/env bash
# tests/test_store_writes.sh — RC-3 store-write path (05-store-write-path.md §6).
#
# A store write that cannot complete is an ERROR (exit 1), NEVER a false ✓, and a
# failed precondition refuses BEFORE any mutation (fail-closed). These verbs route
# their DATA/STATE/CACHE cascades through lib/store.sh; the ADR-0047 boundary is
# modelled hermetically by a `chmod` on the bucket parent (DAC applies to the owner
# too), in TWO distinct modes (§6.1):
#   opaque    — chmod 000 (non-traversable): existence predicates read FALSE, writes
#               fail. Models the boundary as shipped.
#   read-only — chmod 555 (traversable, non-writable): existence reads TRUE, writes
#               fail. Models the Linux bind-mount ownership case.
# Every such test early-returns when run as root (a root runner cannot be confined —
# it bypasses mode bits). CCO_STORE_ELEVATED is 1 under the operator lane, so the
# store crossing runs IN-PROCESS and the chmod seam is what produces the errno.

# ── Fixtures ──────────────────────────────────────────────────────────

# Seed a pack in the CONFIG store (~/.cco/packs) plus its DATA/STATE sidecars, so a
# remove/rename has a full cascade to touch. Usage: _sw_seed_pack <name>
_sw_seed_pack() {
    local name="$1"
    mkdir -p "$CCO_PACKS_DIR/$name"
    printf 'name: %s\n' "$name" > "$CCO_PACKS_DIR/$name/pack.yml"
    mkdir -p "$CCO_DATA_HOME/packs/$name" "$(state_shared)/packs/$name"
    printf 'url: local\n' > "$CCO_DATA_HOME/packs/$name/source"
}

# Seed a user template (kind project) + its sidecars. Usage: _sw_seed_template <name>
_sw_seed_template() {
    local name="$1"
    mkdir -p "$CCO_TEMPLATES_DIR/project/$name"
    printf 'name: %s\n' "$name" > "$CCO_TEMPLATES_DIR/project/$name/template.yml"
    mkdir -p "$CCO_DATA_HOME/templates/$name" "$(state_shared)/templates/$name"
}

# Seed an llms entry (CACHE). Usage: _sw_seed_llms <name>
_sw_seed_llms() {
    local name="$1"
    mkdir -p "$CCO_LLMS_DIR/$name"
    printf 'url: https://example.com/llms.txt\n' > "$CCO_LLMS_DIR/$name/source"
}

# Seed a remote in the DATA registry. Usage: _sw_seed_remote <name> <url>
_sw_seed_remote() {
    local name="$1" url="${2:-https://example.com/${1}.git}"
    mkdir -p "$CCO_DATA_HOME"
    printf '%s=%s\n' "$name" "$url" >> "$CCO_DATA_HOME/remotes"
}

# ── INV-S1: the store-op layer refuses traversal + bad kind ───────────
# A declared guard (not a bug-catcher): the elevated store-op re-entry must reject a
# path-traversal name and an unknown kind WITHOUT touching the FS. Pre-fix: store-op is
# an unknown verb, so both invocations die "Unknown cco command" instead — a different
# rc/message, so the positive-message assertion fails.
test_store_op_rejects_traversal_and_bad_kind() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    mkdir -p "$tmp/data" "$tmp/state" "$tmp/cache" "$tmp/home"
    local out rc=0
    out=$(
        export HOME="$tmp/home" CCO_ALLOW_HOST_RESOLVE=1
        export CCO_IN_CONTAINER=1 CCO_CONTAINER_OPERATOR=1 CCO_STORE_ELEVATED=1
        export CCO_DATA_HOME="$tmp/data" CCO_STATE_HOME="$tmp/state" CCO_CACHE_HOME="$tmp/cache"
        export CCO_ACCESS_TRIPLE="rw,rw,rw"
        unset CCO_SESSION_CONTEXT PROJECT_NAME CCO_CONFIG_TARGETS || true
        bash "$REPO_ROOT/bin/cco" __store store-op apply sidecar-purge packs "../evil" 2>&1
    ) || rc=$?
    assert_rc 1 "$rc" "traversal name must be refused" || return 1
    [[ "$out" == *"Invalid store op"* ]] \
        || { fail "traversal must be rejected at validation, got: $out"; return 1; }

    rc=0
    out=$(
        export HOME="$tmp/home" CCO_ALLOW_HOST_RESOLVE=1
        export CCO_IN_CONTAINER=1 CCO_CONTAINER_OPERATOR=1 CCO_STORE_ELEVATED=1
        export CCO_DATA_HOME="$tmp/data" CCO_STATE_HOME="$tmp/state" CCO_CACHE_HOME="$tmp/cache"
        export CCO_ACCESS_TRIPLE="rw,rw,rw"
        unset CCO_SESSION_CONTEXT PROJECT_NAME CCO_CONFIG_TARGETS || true
        bash "$REPO_ROOT/bin/cco" __store store-op apply sidecar-purge badkind x 2>&1
    ) || rc=$?
    assert_rc 1 "$rc" "bad kind must be refused" || return 1
    [[ "$out" == *"Invalid store op"* ]] \
        || { fail "an unknown kind must be rejected at validation, got: $out"; return 1; }
    return 0
}

# ── INV-S3: the tag primitive fails loud behind an opaque boundary ────
# _tags_forget on an UNREACHABLE registry must return non-zero — never the silent
# `return 0` that orphans the binding (§1.3 / §6.1 worked example). OPAQUE mode (000):
# `[[ -f ]]` reads FALSE for the existing registry, so pre-fix returns 0 (measured:
# rc=0 at 000, rc=1 at 555 — hence the mode pin). Post-fix the opaque parent is
# detected and the function returns 1.
test_store_tags_forget_reports_failure() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    local rc=0
    (
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/paths.sh";  source "$REPO_ROOT/lib/tags.sh"
        export CCO_ALLOW_HOST_RESOLVE=1 CCO_DATA_HOME="$tmp/data"
        mkdir -p "$CCO_DATA_HOME"
        printf 'packs:\n  p: [work]\n' > "$CCO_DATA_HOME/tags.yml"
        chmod 000 "$CCO_DATA_HOME"                 # opaque parent (the ADR-0047 model)
        _tags_forget packs p
    ) || rc=$?
    assert_rc 1 "$rc" "_tags_forget on an opaque registry must fail loud (INV-S3)" || return 1
    return 0
}

# ── pack / template: a store write that cannot complete is an ERROR ────
# Operator session (CCO_STORE_ELEVATED pins the in-process crossing); the bucket chmod
# is the boundary seam. A failed store write must exit 1 with no ✓, and a fail-closed
# pre-flight must refuse BEFORE the claude-owned CONFIG dir is touched.

# READ-ONLY (555) DATA: the sidecar purge cannot be written, so `pack remove` must
# exit 1, print NO success tick, and leave the CONFIG pack dir intact (the pre-flight
# aborted Phase 1). Pre-fix: two `rm: Permission denied` lines then ✓, exit 0.
test_store_pack_remove_fails_loud_when_data_unwritable() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"; setup_operator_session "$tmp" edit-global
    _sw_seed_pack p
    chmod 555 "$CCO_DATA_HOME"
    local rc=0; run_cco pack remove p -y || rc=$?
    chmod 755 "$CCO_DATA_HOME"
    assert_rc 1 "$rc" "pack remove with unwritable DATA must fail loud" || return 1
    [[ "$CCO_OUTPUT" != *"Pack 'p' removed"* ]] \
        || { fail "no success tick on a failed store write: $CCO_OUTPUT"; return 1; }
    assert_dir_exists "$CCO_PACKS_DIR/p" || return 1   # fail-closed: CONFIG untouched
    return 0
}

# OPAQUE (000) sidecar parent: the pre-flight aborts before Phase 1, so the CONFIG
# pack dir must still exist. Pre-fix: the pack dir is already `rm`'d before the
# EACCES, so it is gone with exit 0.
test_store_pack_remove_plan_leaves_config_intact() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"; setup_operator_session "$tmp" edit-global
    _sw_seed_pack p
    chmod 000 "$CCO_DATA_HOME"
    local rc=0; run_cco pack remove p -y || rc=$?
    chmod 755 "$CCO_DATA_HOME"
    assert_rc 1 "$rc" "pack remove behind an opaque store must fail" || return 1
    assert_dir_exists "$CCO_PACKS_DIR/p" || return 1
    return 0
}

# READ-ONLY DATA: `pack rename` must refuse BEFORE the CONFIG store dir moves — never
# the E6B-04 half-apply of a renamed dir with orphaned sidecars. Pre-fix: rc=0, old
# gone, new present, sidecars orphaned.
test_store_pack_rename_plan_blocks_before_store_mv() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"; setup_operator_session "$tmp" edit-global
    _sw_seed_pack p
    chmod 555 "$CCO_DATA_HOME"
    local rc=0; run_cco pack rename p q -y || rc=$?
    chmod 755 "$CCO_DATA_HOME"
    assert_rc 1 "$rc" "pack rename with unwritable DATA must refuse before the store mv" || return 1
    assert_dir_exists "$CCO_PACKS_DIR/p" || return 1
    assert_dir_not_exists "$CCO_PACKS_DIR/q" || return 1
    return 0
}

# The pack-rename pre-scan (cmd-pack.sh:577) must CLASSIFY members in-container: with a
# mounted project that has an unresolved member and references the pack, the rename is
# blocked. The index is SEALED, so pre-fix the enumeration is vacuous → blocked=empty →
# the rename proceeds (rc=0). Post-fix the members come from the mounted project.yml.
test_store_pack_rename_prescan_sees_members_in_container() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"; setup_operator_session "$tmp" edit-global shop
    _sw_seed_pack p1
    mkdir -p "$CCO_WORKDIR/shop/.cco"
    printf 'name: shop\nrepos:\n  - name: shop\n  - name: ghost\npacks:\n  - name: p1\n' \
        > "$CCO_WORKDIR/shop/.cco/project.yml"      # ghost is declared but NOT mounted
    chmod 000 "$CCO_STATE_HOME"                      # seal the index
    local rc=0; run_cco pack rename p1 q1 -y || rc=$?
    chmod 755 "$CCO_STATE_HOME"
    assert_rc 1 "$rc" "pack rename must block on an affected project's unresolved member" || return 1
    [[ "$CCO_OUTPUT" == *"unresolved member"* ]] \
        || { fail "the block must name the unresolved member: $CCO_OUTPUT"; return 1; }
    assert_dir_exists "$CCO_PACKS_DIR/p1" || return 1
    return 0
}

# §3.5: a project referencing the pack that is NOT mounted here cannot have its packs[]
# rewritten in-container, so `pack rename` refuses rather than silently drift. Pre-fix:
# rc=0, the reference in the unmounted project is left dangling.
test_store_pack_rename_refuses_on_unmounted_refs() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"; setup_operator_session "$tmp" edit-global shop
    _sw_seed_pack p1
    mkdir -p "$CCO_WORKDIR/shop/.cco"
    printf 'name: shop\nrepos:\n  - name: shop\npacks:\n  - name: p1\n' \
        > "$CCO_WORKDIR/shop/.cco/project.yml"
    seed_index_path shop  "$CCO_WORKDIR/shop" shop; index_set_project_repos shop shop
    seed_index_path other "$tmp/repos/other" other; index_set_project_repos other other   # NOT mounted
    local rc=0; run_cco pack rename p1 q1 -y || rc=$?
    assert_rc 1 "$rc" "pack rename must refuse when a referencing project is unmounted" || return 1
    [[ "$CCO_OUTPUT" == *"not mounted here"* ]] \
        || { fail "the refusal must name the unmounted scope: $CCO_OUTPUT"; return 1; }
    assert_dir_exists "$CCO_PACKS_DIR/p1" || return 1
    assert_dir_not_exists "$CCO_PACKS_DIR/q1" || return 1
    return 0
}

# READ-ONLY STATE: `template remove` must fail loud (the STATE sidecar cannot be
# purged), no ✓, CONFIG template dir intact. Pre-fix: exit 0 + ✓.
test_store_template_remove_fails_loud_when_state_unwritable() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"; setup_operator_session "$tmp" edit-global
    _sw_seed_template t
    # The op's STATE bucket is the shareable sub-bucket (that is where the sidecars
    # live and what the plan probes), so THAT is the tree to make unwritable —
    # chmod-ing the STATE root would leave the probe writable and the test vacuous.
    chmod 555 "$(state_shared)"
    local rc=0; run_cco template remove t -y || rc=$?
    chmod 755 "$(state_shared)"
    assert_rc 1 "$rc" "template remove with unwritable STATE must fail loud" || return 1
    [[ "$CCO_OUTPUT" != *"Template 't' removed"* ]] \
        || { fail "no success tick on a failed store write: $CCO_OUTPUT"; return 1; }
    assert_dir_exists "$CCO_TEMPLATES_DIR/project/t" || return 1
    return 0
}

# READ-ONLY DATA: `template rename` must refuse before the CONFIG dir moves. Pre-fix:
# rc=0, half-applied.
test_store_template_rename_plan_blocks() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"; setup_operator_session "$tmp" edit-global
    _sw_seed_template t
    chmod 555 "$CCO_DATA_HOME"
    local rc=0; run_cco template rename t u -y || rc=$?
    chmod 755 "$CCO_DATA_HOME"
    assert_rc 1 "$rc" "template rename with unwritable DATA must refuse before the store mv" || return 1
    assert_dir_exists "$CCO_TEMPLATES_DIR/project/t" || return 1
    assert_dir_not_exists "$CCO_TEMPLATES_DIR/project/u" || return 1
    return 0
}

# ── llms / remote: the RIGHT reason (RC-13), not a spurious `not found` ─
# These verbs `die not found` today when the confined store reads FALSE behind the
# boundary. Post-fix existence is a fact of the plan, so an UNREACHABLE store names
# the store instead of lying `not found`, and an unwritable store fails loud.

# OPAQUE (000) llms dir: `llms remove` must fail naming the STORE, not `LLMs 'x' not
# found`. Pre-fix: rc=1 with the wrong reason (cmd-llms.sh:615).
test_store_llms_remove_fails_loud_when_cache_opaque() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"; setup_operator_session "$tmp" edit-global
    _sw_seed_llms entry
    chmod 000 "$CCO_LLMS_DIR"
    local rc=0; run_cco llms remove entry -y || rc=$?
    chmod 755 "$CCO_LLMS_DIR"
    assert_rc 1 "$rc" "llms remove behind an opaque store must fail" || return 1
    [[ "$CCO_OUTPUT" == *"store"* ]] \
        || { fail "the refusal must name the store: $CCO_OUTPUT"; return 1; }
    [[ "$CCO_OUTPUT" != *"not found"* ]] \
        || { fail "an unreachable store must not lie 'not found': $CCO_OUTPUT"; return 1; }
    return 0
}

# OPAQUE (000) DATA: `remote remove` must name the STORE, not `Remote 'x' not found`.
# Pre-fix: rc=1, `Remote 'x' not found` (cmd-remote.sh:197).
#
# ⚠ HOST path (S5): D-V3-1 made `remote remove|rename` host-only, so in an operator
# session the shim now refuses them at exit 2 before the store is ever consulted —
# this property became unreachable there. It is NOT obsolete: the verbs still run on
# the host, where the same store failure is still possible, and where S2b-P's token
# primitives carry the other half of the cascade. So the guard moves to the host arm
# rather than being deleted. `test_operator_blocks_remote_remove_and_rename`
# (test_operator_shim.sh) covers the in-session half.
test_store_remote_remove_reports_store_not_message_not_found() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _sw_seed_remote r1
    chmod 000 "$CCO_DATA_HOME"
    local rc=0; run_cco remote remove r1 -y || rc=$?
    chmod 755 "$CCO_DATA_HOME"
    assert_rc 1 "$rc" "remote remove behind an opaque store must fail" || return 1
    [[ "$CCO_OUTPUT" == *"store"* ]] \
        || { fail "the refusal must name the store: $CCO_OUTPUT"; return 1; }
    [[ "$CCO_OUTPUT" != *"not found"* ]] \
        || { fail "an unreachable store must not lie 'not found': $CCO_OUTPUT"; return 1; }
    return 0
}

# READ-ONLY (555) DATA: `remote rename` must fail loud, no `Renamed remote`. Pre-fix:
# the `:258` read passes under 555, the mv EACCES silently, exit 0 + ✓.
# ⚠ HOST path (S5) — same reason as the sibling above (D-V3-1).
test_store_remote_rename_fails_loud_when_data_unwritable() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _sw_seed_remote r1
    chmod 555 "$CCO_DATA_HOME"
    local rc=0; run_cco remote rename r1 r2 -y || rc=$?
    chmod 755 "$CCO_DATA_HOME"
    assert_rc 1 "$rc" "remote rename with unwritable DATA must fail loud" || return 1
    [[ "$CCO_OUTPUT" != *"Renamed remote"* ]] \
        || { fail "no success tick on a failed store write: $CCO_OUTPUT"; return 1; }
    return 0
}

# READ-ONLY (555) DATA: `remote add` must fail loud, no `Added remote`. Pre-fix: the
# dup-check reads empty, the append EACCES silently, exit 0 + ✓.
test_store_remote_add_fails_loud_when_registry_unwritable() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"; setup_operator_session "$tmp" edit-global
    mkdir -p "$CCO_DATA_HOME"
    chmod 555 "$CCO_DATA_HOME"
    local rc=0; run_cco remote add r1 https://example.com/r1.git || rc=$?
    chmod 755 "$CCO_DATA_HOME"
    assert_rc 1 "$rc" "remote add with unwritable registry must fail loud" || return 1
    [[ "$CCO_OUTPUT" != *"Added remote"* ]] \
        || { fail "no success tick on a failed store write: $CCO_OUTPUT"; return 1; }
    return 0
}

# ── §6.2: the OUTPUT contract on a failed store write ─────────────────
# The tick is a truth assertion again. Complements the state lock above by asserting
# on the MESSAGE: on a failed sidecar purge, `pack remove` must exit 1, must NOT emit
# the ✓ tick, AND must announce the failure (name the store) rather than fail
# silently. READ-ONLY (555) DATA. Pre-fix: two `rm: Permission denied` lines THEN
# `✓ Pack 'p' removed`, exit 0 — the tick lies and the errors are un-actionable.
test_store_pack_remove_prints_no_success_tick_on_failure() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"; setup_operator_session "$tmp" edit-global
    _sw_seed_pack p
    chmod 555 "$CCO_DATA_HOME"
    local rc=0; run_cco pack remove p -y || rc=$?
    chmod 755 "$CCO_DATA_HOME"
    assert_rc 1 "$rc" "a failed store write must exit 1, never 0" || return 1
    [[ "$CCO_OUTPUT" != *"Pack 'p' removed"* ]] \
        || { fail "the success tick must not print on a failed store write: $CCO_OUTPUT"; return 1; }
    [[ "$CCO_OUTPUT" == *store* ]] \
        || { fail "the failure must be announced (name the store), not silent: $CCO_OUTPUT"; return 1; }
    return 0
}

# ── §6.2: host parity LOCK (passes today by design) ───────────────────
# NORMAL perms, HOST path (no operator env → store.sh runs in-process): on a
# successful `pack rename`, the DATA + STATE sidecars move TOGETHER under the new key
# and the old keys are gone. This is a PARITY LOCK — it passes on pre-fix code too;
# its job is to prove the lib/store.sh sidecar-rekey cascade preserves the host's
# all-or-nothing sidecar move, so the boundary crossing never becomes a half-move.
test_store_pack_rename_all_or_nothing_on_sidecars() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"        # HOST context: no setup_operator_session
    _sw_seed_pack p
    local rc=0; run_cco pack rename p q -y || rc=$?
    assert_rc 0 "$rc" "pack rename on the host must succeed" || return 1
    assert_dir_exists "$CCO_DATA_HOME/packs/q"  || return 1
    assert_dir_exists "$(state_shared)/packs/q" || return 1
    assert_dir_not_exists "$CCO_DATA_HOME/packs/p"  || return 1
    assert_dir_not_exists "$(state_shared)/packs/p" || return 1
    assert_dir_exists "$CCO_PACKS_DIR/q" || return 1   # CONFIG moved too
    return 0
}

# ── §6.3: enumeration stays non-empty behind an unreadable index ──────
# _project_iter_members must emit one row per repos[] entry even when the STATE index
# is unreadable, by enumerating from the mounted project.yml (§3.6). This is the row
# that FAILS if §3.6 is descoped to RC-2's probe-path-only change: pre-fix the member
# NAMES come from the sealed index (reads EMPTY as claude behind the boundary), so the
# loop is vacuous. OPAQUE STATE (000) models the ADR-0047 boundary; shop is mounted
# with two declared members. Pre-fix: zero rows.
test_store_iter_members_nonempty_when_index_unreadable() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"; setup_operator_session "$tmp" edit-global shop
    # A mounted member that also hosts shop's committed config, plus a second declared
    # member — two repos[] entries the enumeration must surface even with STATE sealed.
    mkdir -p "$CCO_WORKDIR/backend/.cco"
    printf 'name: shop\nrepos:\n  - name: backend\n  - name: api\n' \
        > "$CCO_WORKDIR/backend/.cco/project.yml"
    seed_index_path backend "$CCO_WORKDIR/backend" shop
    index_set_project_repos shop backend api
    chmod 000 "$CCO_STATE_HOME"                        # the index is now unreadable
    local out; out=$(
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/paths.sh";  source "$REPO_ROOT/lib/index.sh"
        source "$REPO_ROOT/lib/yaml.sh";   source "$REPO_ROOT/lib/sync-meta.sh"
        source "$REPO_ROOT/lib/access-scope.sh"; source "$REPO_ROOT/lib/cmd-resolve.sh"
        _project_iter_members shop )
    chmod 700 "$CCO_STATE_HOME"
    local n; n=$(printf '%s\n' "$out" | grep -c .)
    [[ "$n" -eq 2 ]] \
        || { fail "sealed index: expected 2 member rows enumerated from project.yml, got $n: $out"; return 1; }
    return 0
}

# ── Q-10-OUT: install-family provenance verbs refuse UP FRONT ──────────
# D-M8/Q-10 leaves the install/update provenance writers UNCONVERTED in cycle 1; the
# _store_provenance_guard makes them a clean in-container REFUSAL (exit 2, names the
# reason + the host remedy) instead of installing to CONFIG and silently losing the
# DATA/STATE (or, for llms, CACHE) provenance behind the boundary. A fake URL never
# reaches the network — the guard fires first. Pre-fix (no guard): the verb proceeds
# past arg parsing toward a clone/download and dies with a network error (rc≠2, no
# provenance message). Drive each in an operator session with G=rw so the write gate
# would otherwise admit the verb.
_sw_assert_provenance_refusal() {   # <verb-label> <argv…>
    local label="$1"; shift
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"; setup_operator_session "$tmp" edit-global
    local rc=0; run_cco "$@" || rc=$?
    assert_rc 2 "$rc" "'cco $label' must refuse up front in a container session" || return 1
    [[ "$CCO_OUTPUT" == *"install-provenance"* ]] \
        || { fail "the refusal must name the provenance reason: $CCO_OUTPUT"; return 1; }
    [[ "$CCO_OUTPUT" == *"$label"* ]] \
        || { fail "the refusal must name the verb + host remedy: $CCO_OUTPUT"; return 1; }
    return 0
}

test_store_pack_install_refuses_provenance_in_container() {
    _sw_assert_provenance_refusal "pack install" pack install https://example.com/pack.git || return 1
    return 0
}

test_store_template_install_refuses_provenance_in_container() {
    _sw_assert_provenance_refusal "template install" template install https://example.com/tmpl.git || return 1
    return 0
}

test_store_llms_install_refuses_provenance_in_container() {
    _sw_assert_provenance_refusal "llms install" llms install https://example.com/llms.txt || return 1
    return 0
}
