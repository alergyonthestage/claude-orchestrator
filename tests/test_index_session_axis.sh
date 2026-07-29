#!/usr/bin/env bash
# tests/test_index_session_axis.sh — the index taxonomy's session/host axis
# (ADR-0056 D6 + D7). Regression cover for the e2e v3.1 review §10.9d / root R-C.
#
# WHAT §10.9d OBSERVED. With the index moved aside under a LIVE session,
# `cco path list` answered *"the path index is empty — nothing is registered on
# this machine yet"* at **rc=0**, and `cco project show` rendered a FABRICATED
# card: three bound, readable mounts badged `[unresolved]`, the repo's host path
# silently degraded to its container path. Neither is a degraded answer — both
# are confident WRONG ones, which is strictly worse.
#
# WHAT THE DESIGN SAYS. Every assertion below cites the clause it traces to; none
# is derived from the implementation as written (project rule `testing.md`).
#
#   D6 — the classifier does NOT change: `_index_read_state` keeps its five
#        MECHANICAL states and stays usable on an ARBITRARY file argument, because
#        the legacy-location reconcile classifies other index files with the same
#        function (alternative A3 rejects a sixth state or a context-dependent
#        classification outright).
#   D6 — the axis lives in the INTERPRETATION: under a container-operator session
#        `absent` is non-benign and routes to the same fail-closed path as
#        unreadable/truncated/stale. ON THE HOST `absent` stays benign — a machine
#        with nothing registered yet legitimately has no index file.
#   D6 — TWO CAUSES, TWO SENTENCES, split by whether the index file's parent is
#        traversable: (a) the bind was severed / host state destroyed, (b) the
#        internal store is unreachable — the native-Linux DEFAULT, which must name
#        the platform limitation by name. Alternative A4 (one sentence for both)
#        was considered and rejected by the maintainer.
#   D2 — a remedy is a function of the print site: `cco resolve` is the specific
#        host-only string a container sentence may never prescribe.
#   D7 — when the index itself is unreadable, `cco project show` renders NO CARD
#        AT ALL, refusing at entry; and `[unresolved]` means EXACTLY ONE thing —
#        the index holds no binding for this member. Never "the probe failed",
#        never "I could not read the index".
#
# BOTH DIRECTIONS ARE ASSERTED, DELIBERATELY — the shape of the existing
# `test_index_empty_sentence_never_says_cco_resolve_in_a_session`. A "fix" that
# simply made `absent` fatal everywhere, or that deleted the `[unresolved]` badge,
# would be WRONG and must not pass here.
#
# EXIT CODES ARE ASSERTED, not only text: §10.9d's core defect was a confident
# wrong answer at rc=0, so a test that only reads the words would still certify it.

# ── Fixture mechanics ─────────────────────────────────────────────────
#
# (a) THE PREDICATE IS REAL, NEVER STUBBED. `_cco_container_operator` needs the
#     explicit flag AND three ABSOLUTE bucket paths (lib/paths.sh); a stubbed
#     predicate cannot regress-test the predicate — tests/helpers.sh lane note (a).
#     The operator exports therefore come from `_lane_operator_exports`, the single
#     source of truth for "what a lane operator session is"; inventing a second
#     spelling here is how the third one got invented.
# (b) THE STATE LIVES AT <CCO_STATE_HOME>/shared/index. The pre-S1
#     <CCO_STATE_HOME>/index no longer exists: a copy-paste of the older path
#     moves nothing and produces a FALSE PASS (ADR-0056, Verification, ⚠).
# (c) THE BUCKETS ARE MOUNTS in production, so the resolvers deliberately SKIP
#     `_cco_ensure_dir` under operator mode. That is what makes both `absent`
#     causes reachable hermetically: `shared/` present but empty → severed;
#     `shared/` absent or mode 000 → store unreachable.
# (d) A SESSION IS LAUNCHED FROM THE INDEX, so an operator fixture with no index
#     at all is a state that cannot occur (and since D6 is refused at entry).
#     `_sa_make_session` always seeds the real scaffold first, then each test
#     breaks it explicitly — the breakage is the thing under test, never the
#     starting condition.

# Source the index stack into the CURRENT shell. bin/test gives every test
# function its own subshell, so these leak nowhere.
_sa_source_libs() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/index.sh"
}

# HOST context: no operator flag, no bucket overrides beyond STATE.
# Usage: _sa_host_env <root>
_sa_host_env() {
    export CCO_ALLOW_HOST_RESOLVE=1
    export CCO_STATE_HOME="$1/state"
    export HOME="$1/home"
    unset XDG_STATE_HOME CCO_DATA_HOME CCO_CACHE_HOME \
          CCO_CONTAINER_OPERATOR CCO_IN_CONTAINER 2>/dev/null || true
    return 0
}

# SESSION context — a real container-operator session (fixture note (a)).
# CCO_ALLOW_HOST_RESOLVE is deliberately UNSET: with it set, `_cco_resolver_guard`
# passes on the flag rather than on the predicate, so a regression that broke
# `_cco_container_operator` would stay invisible. Unset, a broken predicate makes
# the guard die loudly instead.
# Usage: _sa_session_env <root> [<project>]
_sa_session_env() {
    local root="$1" project="${2:-}"
    export CCO_DATA_HOME="$root/data" CCO_STATE_HOME="$root/state" \
           CCO_CACHE_HOME="$root/cache"
    export HOME="$root/home"
    unset XDG_STATE_HOME CCO_ALLOW_HOST_RESOLVE 2>/dev/null || true
    unset OP_TRIPLE OP_TARGETS OP_SHP 2>/dev/null || true
    eval "$(_lane_operator_exports read-all "$project")"
    return 0
}

# Seed a REAL index through the real API, host-side, so the on-disk format is
# production's. Asserts its own postcondition: a silently unseeded index would
# make every test below vacuous.
# Usage: _sa_seed_index <root> [<project>]
_sa_seed_index() {
    local root="$1" project="${2:-demo}"
    mkdir -p "$root/state/shared" "$root/data" "$root/cache" "$root/home"
    (
        source "$REPO_ROOT/lib/colors.sh"; source "$REPO_ROOT/lib/utils.sh"
        source "$REPO_ROOT/lib/paths.sh";  source "$REPO_ROOT/lib/index.sh"
        export CCO_ALLOW_HOST_RESOLVE=1 CCO_STATE_HOME="$root/state"
        unset CCO_CONTAINER_OPERATOR CCO_IN_CONTAINER CCO_DATA_HOME CCO_CACHE_HOME
        _index_set_path "$project" "$project" "/Users/cco-e2e/code/$project"
        _index_set_project_repos "$project" "$project"
    ) >/dev/null 2>&1
    [[ -s "$root/state/shared/index" ]] || {
        fail "fixture: seeding produced no index at $root/state/shared/index — every assertion below would be vacuous"
        return 1
    }
    return 0
}

# The full hermetic session: a seeded index PLUS the flat WORKDIR bind `cco start`
# creates, with the member repo mounted at <workdir>/<project> carrying its own
# .cco/project.yml. The member's index path is a HOST path that deliberately does
# not exist here — that is the real in-session topology (the repo is reachable
# only at its mount), and it is what makes a degraded-to-container-path rendering
# observable at all. One declared extra_mount `notes` is left UNBOUND on purpose:
# it is the one member for which `[unresolved]` is the CORRECT badge (D7).
# Usage: _sa_make_session <root> <project>
_sa_make_session() {
    local root="$1" project="$2"
    local mnt="$root/workspace/$project"
    mkdir -p "$mnt/.cco"
    printf 'name: %s\nrepos:\n  - name: %s\nextra_mounts:\n  - name: notes\n' \
        "$project" "$project" > "$mnt/.cco/project.yml"
    _sa_seed_index "$root" "$project" || return 1
    return 0
}

# Run the real `cco` inside the session, from inside the mounted repo. Captures
# stdout+stderr → SA_OUT and the exit code → SA_RC; always returns 0 so the caller
# asserts explicitly (the lane-runner convention).
# Usage: _sa_run <root> <project> <argv...>
_sa_run() {
    local root="$1" project="$2"; shift 2
    SA_OUT=$(
        _sa_session_env "$root" "$project"
        export CCO_WORKDIR="$root/workspace"
        cd "$root/workspace/$project" || exit 1
        bash "$REPO_ROOT/bin/cco" "$@" 2>&1
    )
    SA_RC=$?
    return 0
}

# Move the index aside exactly as §10.9d did: a host-side `mv` under a live
# session. `shared/` — the directory S1 binds — survives, so the file simply
# vanishes and the state reads plain `absent`. Asserts that, because if the
# fixture produced `stale` instead it would be exercising the pre-S1 file-bind
# arm that ADR-0056 says does NOT catch this.
# Usage: _sa_move_index_aside <root>
_sa_move_index_aside() {
    local root="$1"
    mv "$root/state/shared/index" "$root/state/shared/index.moved" || {
        fail "fixture: could not move the index aside"; return 1; }
    [[ -d "$root/state/shared" ]] || {
        fail "fixture: shared/ must survive the move — that is what makes this the severed arm"; return 1; }
    return 0
}

# ══════════════════════════════════════════════════════════════════════
# D6 — the classifier stays PURE (alternative A3)
# ══════════════════════════════════════════════════════════════════════

# "_index_read_state keeps its five mechanical states" (D6). The enumeration is
# the assertion: every state the classifier can produce must be one of the five,
# and the two INTERPRETED names — `severed` / `store-unreachable`, which D6 puts
# in `_index_assert_readable` — must never come out of it. A sixth state, or a
# classifier that reported an interpretation, is exactly what A3 rejects.
test_index_read_state_keeps_its_five_mechanical_states() {
    [[ "$(id -u)" -eq 0 ]] && return 0   # the unreadable arm needs mode bits to bite
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    _sa_source_libs
    _sa_host_env "$tmp"
    _sa_seed_index "$tmp" || return 1

    local f; f=$(_index_file)
    local seen="" st

    st=$(_index_read_state);                seen="$seen ok:$st"
    [[ "$st" == ok ]] || fail "a seeded index must classify ok, got: $st"

    : > "$f"
    st=$(_index_read_state);                seen="$seen truncated:$st"
    [[ "$st" == truncated ]] || fail "a 0-byte index must classify truncated, got: $st"

    chmod 000 "$f"
    st=$(_index_read_state)
    chmod 644 "$f";                         seen="$seen unreadable:$st"
    [[ "$st" == unreadable ]] || fail "a mode-000 index must classify unreadable, got: $st"

    # nlink 0 cannot be synthesized without a mount, so `stat` is mocked on PATH
    # (the tests/mocks.sh convention). Everything below the syscall is real code.
    mkdir -p "$tmp/mockbin"
    printf '#!/usr/bin/env bash\necho 0\n' > "$tmp/mockbin/stat"
    chmod +x "$tmp/mockbin/stat"
    _sa_seed_index "$tmp" || return 1
    st=$(PATH="$tmp/mockbin:$PATH" _index_read_state); seen="$seen stale:$st"
    [[ "$st" == stale ]] || fail "an nlink-0 index must classify stale, got: $st"

    rm -f "$f"
    st=$(_index_read_state);                seen="$seen absent:$st"
    [[ "$st" == absent ]] || fail "a missing index must classify absent, got: $st"

    # The classifier never speaks the interpretation's vocabulary (D6/A3).
    [[ "$seen" != *severed* ]] \
        || fail "_index_read_state must never emit the INTERPRETED state 'severed': $seen"
    [[ "$seen" != *store-unreachable* ]] \
        || fail "_index_read_state must never emit the INTERPRETED state 'store-unreachable': $seen"
    return 0
}

# The core of A3: the classification is MECHANICAL, so it does not move when the
# question is asked from inside a session. If `absent`-in-a-session were made a
# different state, the reconcile probe — which classifies arbitrary index files,
# where "in a session" is meaningless — would be reading policy as fact.
test_index_read_state_is_context_free_across_the_session_axis() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sa_source_libs
    _sa_host_env "$tmp"
    _sa_seed_index "$tmp" || return 1
    local f; f=$(_index_file)
    rm -f "$f"

    local host_st; host_st=$(_index_read_state)
    [[ "$host_st" == absent ]] \
        || fail "on the host a missing index must classify absent, got: $host_st"

    # A REAL operator context, not a stubbed predicate (fixture note (a)).
    local sess_st
    sess_st=$( _sa_session_env "$tmp" demo; _index_read_state )
    [[ "$sess_st" == "$host_st" ]] \
        || fail "the classifier must be context-free (ADR-0056 A3): host said '$host_st', the session said '$sess_st'"
    return 0
}

# "its optional file argument lets the reconcile probe classify ARBITRARY index
# files … with the SAME classifier" (D6). The property: the argument is what is
# classified — never the live index. Asserted in both directions so a function
# that ignored its argument (or that consulted the live index as a fallback)
# cannot pass.
test_index_read_state_classifies_an_arbitrary_file_argument() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sa_source_libs
    _sa_host_env "$tmp"
    _sa_seed_index "$tmp" || return 1
    local live; live=$(_index_file)

    # A healthy LIVE index must not make an absent/0-byte OTHER file read as ok.
    [[ "$(_index_read_state)" == ok ]] || fail "precondition: the live index must be ok"
    local st
    st=$(_index_read_state "$tmp/legacy-nowhere")
    [[ "$st" == absent ]] \
        || fail "an argument that does not exist must classify absent, got: $st (the live index leaked in)"
    : > "$tmp/legacy-empty"
    st=$(_index_read_state "$tmp/legacy-empty")
    [[ "$st" == truncated ]] \
        || fail "a 0-byte argument must classify truncated, got: $st"

    # …and an absent LIVE index must not make a healthy OTHER file read as absent.
    cp "$live" "$tmp/legacy-good"
    rm -f "$live"
    [[ "$(_index_read_state)" == absent ]] || fail "precondition: the live index must now be absent"
    st=$(_index_read_state "$tmp/legacy-good")
    [[ "$st" == ok ]] \
        || fail "a healthy argument must classify ok even with the live index gone, got: $st"
    return 0
}

# ══════════════════════════════════════════════════════════════════════
# D6 — the axis lives in the INTERPRETATION
# ══════════════════════════════════════════════════════════════════════

# "under `_cco_container_operator`, `absent` is non-benign and routes to the SAME
# fail-closed path as unreadable/truncated/stale" (D6). Asserted as an identity
# with the truncated arm rather than as a hardcoded constant, so "the same path"
# is what is actually pinned. §10.9d's defect was the answer at rc=0.
test_absent_index_is_non_benign_inside_a_session() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sa_source_libs
    _sa_seed_index "$tmp" || return 1
    _sa_session_env "$tmp" demo
    local f; f=$(_index_file)

    # Reference arm: a state that was ALREADY fail-closed before ADR-0056.
    : > "$f"
    local trunc_rc=0
    ( _index_assert_readable ) >/dev/null 2>&1 || trunc_rc=$?
    [[ "$trunc_rc" -ne 0 ]] \
        || fail "precondition: a truncated index must already be fail-closed, got rc=$trunc_rc"

    rm -f "$f"
    [[ "$(_index_read_state)" == absent ]] || fail "precondition: the index must read absent"
    local msg rc=0
    msg=$( ( _index_assert_readable ) 2>&1 ) || rc=$?
    [[ "$rc" -ne 0 ]] \
        || fail "ADR-0056 D6: in a session an absent index must NOT be benign — got rc=0 with: $msg"
    [[ "$rc" -eq "$trunc_rc" ]] \
        || fail "D6 routes absent-in-session to the SAME fail-closed path as truncated (rc=$trunc_rc), got rc=$rc"
    return 0
}

# The other direction, and it is not optional: "ON THE HOST … a machine with
# nothing registered yet legitimately has no index file" (D6; the classifier note
# calls `absent` benign there). Without this arm a "fix" that made `absent` fatal
# EVERYWHERE would pass — and it would break every first-run `cco list`.
test_absent_index_stays_benign_on_the_host() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sa_source_libs
    _sa_host_env "$tmp"
    _sa_seed_index "$tmp" || return 1
    rm -f "$(_index_file)"
    [[ "$(_index_read_state)" == absent ]] || fail "precondition: the index must read absent"

    local msg rc=0
    msg=$( ( _index_assert_readable ) 2>&1 ) || rc=$?
    [[ "$rc" -eq 0 ]] \
        || fail "on the host an absent index must stay benign (rc=0), got rc=$rc: $msg"
    [[ -z "$msg" ]] \
        || fail "on the host an absent index must not be reported at all, got: $msg"
    return 0
}

# "TWO CAUSES, TWO SENTENCES, separated by probing the parent's traversability"
# (D6; A4 — one sentence for both — was rejected by the maintainer). The two
# sentences differing is therefore itself an assertion, not a nicety: a single
# generic message would satisfy every keyword check below and still be the
# rejected alternative.
test_session_absent_index_splits_into_two_causes() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sa_source_libs
    _sa_seed_index "$tmp" || return 1
    _sa_session_env "$tmp" demo
    rm -f "$(_index_file)"

    # (a) severed — the parent IS traversable, the file is simply gone. This is
    # §10.9d's own topology: a host-side `mv` with S1's directory bind intact.
    local sev rc_sev=0
    sev=$( ( _index_assert_readable ) 2>&1 ) || rc_sev=$?
    [[ "$rc_sev" -ne 0 ]] || fail "severed: an absent index in a session must refuse, got rc=0"
    # D6's table spells this row's content: "the index was readable at start and
    # is no longer", remedy "run cco on your host to inspect or rebuild it".
    [[ "$sev" == *readable* ]] \
        || fail "the severed sentence must say the index was readable at session start; got: $sev"
    [[ "$sev" == *host* ]] \
        || fail "D6's severed remedy is to run cco on the HOST; got: $sev"
    # …and it must NOT be the other row's content. The two rows are distinct
    # causes, so the platform limitation belongs to the unreachable-store one only.
    [[ "$sev" != *Linux* ]] \
        || fail "D6: a severed bind is not the platform limitation — that is the OTHER cause; got: $sev"

    # (b) store unreachable — the parent cannot be entered, so the file cannot
    # even be looked up. Reached here by removing `shared/` entirely; the
    # permission form of the same cause is the next test.
    rm -rf "$tmp/state/shared"
    local unr rc_unr=0
    unr=$( ( _index_assert_readable ) 2>&1 ) || rc_unr=$?
    [[ "$rc_unr" -ne 0 ]] || fail "store-unreachable: an unreachable store must refuse, got rc=0"

    # D6: this row "names the platform limitation, by name" and carries a
    # forward-pointer to the cycle-2 Linux ADR — because it is the DEFAULT state
    # of every native-Linux session, and A4 was rejected precisely so those users
    # can tell a known limitation from a broken installation.
    [[ "$unr" == *Linux* ]] \
        || fail "D6: the unreachable-store sentence must name the platform limitation by name; got: $unr"
    [[ "$unr" == *cycle-2* ]] \
        || fail "D6: the unreachable-store sentence must forward-point at the cycle-2 Linux ADR; got: $unr"

    # A4 rejected: one sentence for both causes is not the decided design.
    [[ "$sev" != "$unr" ]] \
        || fail "D6 requires TWO sentences for the two causes (A4 rejected); both read: $sev"
    return 0
}

# The permission form of the unreachable store — and the one that matters, because
# D6 names it the DEFAULT state of every session on native Linux: the host buckets
# are created mode 0700 for the elevated identity, so a session running as the
# user's own uid has no search permission on the parent and the lookup never even
# reaches the file. Skipped as root, which bypasses mode bits entirely and would
# certify a green that means nothing.
test_store_unreachable_arm_fires_on_an_untraversable_parent() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local tmp; tmp=$(mktemp -d)
    trap "chmod -R u+rwX '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
    _sa_source_libs
    _sa_seed_index "$tmp" || return 1
    _sa_session_env "$tmp" demo

    # The index is still THERE and perfectly healthy — only the parent is sealed.
    # That is the whole point: the session cannot tell, and must not guess.
    chmod 000 "$tmp/state/shared"
    local msg rc=0
    msg=$( ( _index_assert_readable ) 2>&1 ) || rc=$?
    chmod 700 "$tmp/state/shared" 2>/dev/null || true

    [[ "$rc" -ne 0 ]] \
        || fail "an untraversable store parent must refuse, got rc=0: $msg"
    [[ "$msg" == *Linux* ]] \
        || fail "D6: the untraversable-parent cause must name the platform limitation; got: $msg"
    [[ "$msg" != *"the file is gone"* ]] \
        || fail "D6: an unreachable store must NOT be reported as a severed bind — the file is still there; got: $msg"
    return 0
}

# The §10.9d sentence itself, and D2's rule about the print site. The refusal must
# not carry the benign vocabulary it replaced ("the path index is empty …
# nothing is registered on this machine yet"), and — D2 — it must not prescribe
# `cco resolve`, which the operator gate refuses in the very session printing it.
# Both `absent` causes are checked: a fix applied to one arm only is the sibling
# class this cycle exists to remove.
test_session_index_refusal_never_reports_an_empty_index() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sa_source_libs
    _sa_seed_index "$tmp" || return 1
    _sa_session_env "$tmp" demo
    rm -f "$(_index_file)"

    local arm msg rc
    for arm in severed store-unreachable; do
        [[ "$arm" == store-unreachable ]] && rm -rf "$tmp/state/shared"
        rc=0
        msg=$( ( _index_assert_readable ) 2>&1 ) || rc=$?
        [[ "$rc" -ne 0 ]] \
            || fail "$arm: the session must refuse, not answer at rc=0"
        [[ "$msg" != *"the path index is empty"* ]] \
            || fail "$arm: a read failure must never be reported as an empty index (§10.9d); got: $msg"
        [[ "$msg" != *"nothing is registered on this machine yet"* ]] \
            || fail "$arm: the benign empty-index sentence must not be reused for a read failure; got: $msg"
        [[ "$msg" != *"cco resolve"* ]] \
            || fail "$arm (ADR-0056 D2): an in-session remedy may not prescribe the host-only 'cco resolve'; got: $msg"
    done
    return 0
}

# ══════════════════════════════════════════════════════════════════════
# §10.9d end to end — the verbs that read the index
# ══════════════════════════════════════════════════════════════════════

# The headline reproduction, at the surface where it was observed: `cco path list`
# with the index moved aside under a live session. It answered the empty sentence
# at rc=0; D6 makes it a read failure.
test_path_list_refuses_when_the_index_is_moved_aside_in_a_session() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sa_make_session "$tmp" demo || return 1

    # Non-vacuity: the same command must SUCCEED before the index is moved, or the
    # refusal below would prove nothing about the index.
    _sa_run "$tmp" demo path list
    [[ "$SA_RC" -eq 0 ]] \
        || fail "precondition: 'cco path list' must work on a healthy session index, got rc=$SA_RC: $SA_OUT"

    _sa_move_index_aside "$tmp" || return 1
    _sa_run "$tmp" demo path list
    [[ "$SA_RC" -ne 0 ]] \
        || fail "§10.9d: 'cco path list' answered at rc=0 with the index moved aside; got: $SA_OUT"
    [[ "$SA_OUT" != *"the path index is empty"* ]] \
        || fail "§10.9d: the exact wrong answer came back — '$SA_OUT'"
    [[ "$SA_OUT" == *"cannot be read"* ]] \
        || fail "the refusal must name a READ failure, not something else; got: $SA_OUT"
    return 0
}

# ADR-0056's Verification names the family the container probe re-runs: `path
# list`, `list`, `list projects`, `project show <p>` — "confirm each reports a
# read failure". `project validate --all` is included because it enumerates the
# index too, and D6 routes every enumerator through the same guard; its --all
# lane would otherwise validate ZERO projects and return the share-ready exit 0.
test_index_reading_verbs_all_refuse_when_the_index_is_moved_aside() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sa_make_session "$tmp" demo || return 1
    _sa_move_index_aside "$tmp" || return 1

    local v
    for v in "path list" "list" "list projects" "project show demo" "project validate --all"; do
        # shellcheck disable=SC2086
        _sa_run "$tmp" demo $v
        [[ "$SA_RC" -ne 0 ]] \
            || fail "'cco $v' must report a read failure with the index moved aside, got rc=0: $SA_OUT"
        [[ "$SA_OUT" == *"cannot be read"* ]] \
            || fail "'cco $v' must name the read failure; got: $SA_OUT"
        [[ "$SA_OUT" != *"the path index is empty"* ]] \
            || fail "'cco $v' reported a read failure as an empty index; got: $SA_OUT"
    done
    return 0
}

# ══════════════════════════════════════════════════════════════════════
# D7 — no fabricated card, and one meaning for [unresolved]
# ══════════════════════════════════════════════════════════════════════

# "When the index itself is unreadable, `project show` renders NO CARD AT ALL,
# refusing at entry … A card that badges bound, readable mounts `[unresolved]`
# and silently degrades a host path to its container path is not a degraded
# answer — it is a FABRICATED one" (D7). Asserted as the absence of every part of
# the card, not just of the badge: refusing at ENTRY is the contract, so a verb
# that printed the header and then died would still be wrong.
test_project_show_renders_no_card_when_the_index_is_unreadable() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sa_make_session "$tmp" demo || return 1

    # Non-vacuity: the card must exist first, or "no card" is trivially true.
    _sa_run "$tmp" demo project show demo
    [[ "$SA_RC" -eq 0 && "$SA_OUT" == *"Project: demo"* ]] \
        || fail "precondition: 'cco project show demo' must render a card on a healthy index, got rc=$SA_RC: $SA_OUT"

    _sa_move_index_aside "$tmp" || return 1
    _sa_run "$tmp" demo project show demo
    [[ "$SA_RC" -ne 0 ]] \
        || fail "D7: 'cco project show' must refuse on an unreadable index, got rc=0: $SA_OUT"
    local part
    for part in "Project: demo" "Repos:" "Extra mounts:" "Packs:" "Status:"; do
        [[ "$SA_OUT" != *"$part"* ]] \
            || fail "D7: no card at all — '$part' was rendered off an unreadable index: $SA_OUT"
    done
    [[ "$SA_OUT" != *"[unresolved]"* ]] \
        || fail "D7: '[unresolved]' must never mean 'I could not read the index'; got: $SA_OUT"
    # §10.9d's second symptom, named explicitly: with the index unreadable the
    # member's host path fell back to the path it is MOUNTED at, so the card
    # asserted a location it had no binding for. No card means no such claim.
    [[ "$SA_OUT" != *"$tmp/workspace/demo"* ]] \
        || fail "D7/§10.9d: the repo's host path was silently degraded to its container path: $SA_OUT"
    return 0
}

# The other direction of D7's first bullet: "`[unresolved]` := the index holds no
# binding for this member." It is a real badge with a real meaning, so a fix that
# simply deleted it would be wrong. `notes` is declared in project.yml and bound
# nowhere; with a perfectly READABLE index that is exactly what `[unresolved]`
# reports — and the member repo, which IS bound and IS mounted, must not carry it.
test_unresolved_means_no_binding_not_an_unreadable_index() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sa_make_session "$tmp" demo || return 1

    _sa_run "$tmp" demo project show demo
    [[ "$SA_RC" -eq 0 ]] \
        || fail "a healthy index must still render the card, got rc=$SA_RC: $SA_OUT"
    # Line-scoped, not a whole-output glob: the badge must sit on the UNBOUND
    # member's own row, and nowhere else.
    if ! printf '%s\n' "$SA_OUT" | grep -q 'notes.*\[unresolved\]'; then
        fail "D7: an unbound declared extra_mount must still badge [unresolved]; got: $SA_OUT"
        return 1
    fi
    if printf '%s\n' "$SA_OUT" | grep -q '^ *demo .*\[unresolved\]'; then
        fail "D7: a member the index DOES bind must not be badged [unresolved]; got: $SA_OUT"
        return 1
    fi
    return 0
}
