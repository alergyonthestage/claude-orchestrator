#!/usr/bin/env bash
# tests/test_whoami.sh — `cco whoami`, HOST branch: the CLI's own identity (A11 / FI-80)
#
# The in-container branch is covered by tests/test_operator_shim.sh; this file covers
# the branch that was untested — the host one. Contract: after the existing
# "host context" info line and BEFORE the dev-sandbox block, whoami renders a
# `cco CLI` block carrying `version:`, `provenance:` and `REPO_ROOT:`.
#
# ⚠ Why the fixture trees below exist. `cco --version` prints `cco 0.6.0` from an npm
# install and from a clone alike, and `which cco` answers PATH order — neither
# DISCRIMINATES, which is the whole reason this block exists. A test that only ever
# reads this machine's own REPO_ROOT would inherit exactly that defect, so provenance,
# version and REPO_ROOT are each also driven against a tree planted at a chosen path.

# ── Harness ──────────────────────────────────────────────────────────

# Run the full binary in a CLEAN HOST envelope; stdout+stderr → WA_OUT, status → WA_RC.
# This suite runs inside cco's own self-dev container, so the ambient operator envelope
# must be stripped and host mode forced, or `whoami` answers on the in-container branch
# and every assertion below is vacuous. Same idiom as
# test_dev_sandbox_flag_and_whoami_indicator, which proved it reaches the host branch
# from in here. CCO_DEV_SANDBOX is deliberately NOT unset: a caller exports it to
# engage the sandbox. Always returns 0 — the caller asserts on WA_RC explicitly.
# Usage: _whoami_host <path-to-bin/cco> <argv...>
_whoami_host() {
    local bin="$1"; shift
    local home; home=$(mktemp -d)
    WA_OUT=$(env -u CCO_CONTAINER_OPERATOR -u CCO_DATA_HOME -u CCO_STATE_HOME -u CCO_CACHE_HOME \
                 -u CCO_CCO_ACCESS -u CCO_CLAUDE_ACCESS -u CCO_SHOW_HOST_PATHS -u CCO_CONFIG_TARGETS \
                 -u PROJECT_NAME -u CCO_SESSION_CONTEXT -u XDG_STATE_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME \
                 CCO_IN_CONTAINER=0 HOME="$home" CCO_SKIP_BUILD=1 \
                 bash "$bin" "$@" 2>&1)
    WA_RC=$?
    rm -rf "$home"
    return 0
}

# WA_OUT with ANSI attributes stripped. The block's header is bold ($BOLD/$NC) and
# colours stay ON under capture (cco does not gate them on a tty), so a raw match on a
# field VALUE would carry a trailing reset sequence.
_whoami_plain() { printf '%s\n' "${WA_OUT:-}" | sed "s/$(printf '\033')\[[0-9;]*m//g"; }

# Echo the value of an indented `  <key>: <value>` row of the block (first match).
# No `head`/`tail` in the extraction path: the status of a pipeline is its LAST
# command's, so a `grep` that found nothing would be masked by a successful tail.
# Usage: _whoami_field <key>
_whoami_field() {
    local key="$1" hit
    hit=$(_whoami_plain | grep -E "^[[:space:]]*${key}:[[:space:]]" || true)
    hit=${hit%%$'\n'*}          # first row only
    hit=${hit#*:}               # drop the key
    printf '%s' "$hit" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# 1-based line number of the first line containing <literal>, or "" if absent.
# Usage: _whoami_line_of <literal>
_whoami_line_of() {
    local hit
    hit=$(_whoami_plain | grep -nF "$1" || true)
    hit=${hit%%$'\n'*}
    printf '%s' "${hit%%:*}"
}

# Plant a RUNNABLE cco tree whose REPO_ROOT resolves to exactly $1.
# bin/cco is a real COPY, never a symlink: the binary readlink-resolves its own path
# (bin/cco:20-26) precisely so a PATH symlink still finds the tool root — a symlinked
# fixture would resolve straight back to the real repo and silently test nothing.
# lib/ IS a symlink (1.5MB, and the code under test is the same code either way).
# Usage: _whoami_plant_tree <root> <version-for-package.json>
_whoami_plant_tree() {
    local root="$1" version="$2"
    mkdir -p "$root/bin"
    cp "$REPO_ROOT/bin/cco" "$root/bin/cco"
    ln -s "$REPO_ROOT/lib" "$root/lib"
    printf '{"name":"@claude-orchestrator/cco","version":"%s"}\n' "$version" > "$root/package.json"
}

# ── The block renders, with the exact literal keys ───────────────────

test_whoami_host_renders_the_cli_identity_block() {
    _whoami_host "$REPO_ROOT/bin/cco" whoami
    [[ $WA_RC -eq 0 ]] || fail "cco whoami must succeed on the host, got rc=$WA_RC: $WA_OUT" || return 1
    # Branch proof: the host branch is the one that says so. Without this the whole
    # file could be asserting against the in-container branch and never notice.
    _whoami_plain | grep -qF "host context" \
        || fail "did not reach the HOST branch, got: $WA_OUT" || return 1

    _whoami_plain | grep -qF "cco CLI" \
        || fail "host whoami must render the 'cco CLI' section header, got: $WA_OUT" || return 1
    local key
    for key in version provenance REPO_ROOT; do
        _whoami_plain | grep -qE "^[[:space:]]*${key}:" \
            || fail "host whoami must carry the literal key '${key}:', got: $WA_OUT" || return 1
    done
    return 0
}

# ── version: the package.json field, never a literal ─────────────────

test_whoami_host_version_is_the_package_json_version() {
    local expected
    expected=$(jq -r .version "$REPO_ROOT/package.json")
    [[ -n "$expected" && "$expected" != "null" ]] \
        || fail "fixture broken: cannot read .version from package.json" || return 1

    _whoami_host "$REPO_ROOT/bin/cco" whoami
    local got; got=$(_whoami_field version)
    [[ "$got" == "$expected" ]] \
        || fail "version must be package.json's '$expected', got: '$got'" || return 1
    return 0
}

# The same clause, made DISCRIMINATING: a hardcoded "0.6.0" satisfies the test above
# and fails here. The version follows the tree the running binary was reached through.
test_whoami_host_version_follows_the_running_trees_package_json() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local root="$tmp/plain/cco"
    _whoami_plant_tree "$root" "9.9.9-a11-fixture"

    _whoami_host "$root/bin/cco" whoami
    [[ $WA_RC -eq 0 ]] || fail "planted tree: whoami failed rc=$WA_RC: $WA_OUT" || return 1
    local got; got=$(_whoami_field version)
    [[ "$got" == "9.9.9-a11-fixture" ]] \
        || fail "version must come from the RUNNING tree's package.json, got: '$got'" || return 1
    return 0
}

# ── REPO_ROOT: the resolved absolute framework tree ──────────────────

test_whoami_host_repo_root_is_the_resolved_absolute_tree() {
    _whoami_host "$REPO_ROOT/bin/cco" whoami
    local got; got=$(_whoami_field REPO_ROOT)
    [[ "$got" == /* ]] \
        || fail "REPO_ROOT must be ABSOLUTE, not a relative path, got: '$got'" || return 1
    [[ -f "$got/bin/cco" ]] \
        || fail "REPO_ROOT must name the framework tree (no bin/cco under it), got: '$got'" || return 1
    [[ "$(cd -P "$got" && pwd)" == "$(cd -P "$REPO_ROOT" && pwd)" ]] \
        || fail "REPO_ROOT must be this framework tree ($REPO_ROOT), got: '$got'" || return 1

    # Discriminating half: it tracks the tree the binary was reached through, so a
    # constant (or a $PWD-derived value) cannot pass both halves.
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local root="$tmp/elsewhere/cco"
    _whoami_plant_tree "$root" "0.0.0-fixture"
    _whoami_host "$root/bin/cco" whoami
    got=$(_whoami_field REPO_ROOT)
    [[ "$got" == "$root" ]] \
        || fail "REPO_ROOT must resolve to the running tree '$root', got: '$got'" || return 1
    return 0
}

# ── provenance: one of npm|brew|clone|unknown, and it DISCRIMINATES ──

test_whoami_host_provenance_discriminates_by_install_shape() {
    # (a) this tree: whatever it is, it must be one of the four legible values —
    #     never empty, never fabricated.
    _whoami_host "$REPO_ROOT/bin/cco" whoami
    local got; got=$(_whoami_field provenance)
    case "$got" in
        npm|brew|clone|unknown) ;;
        *) fail "provenance must be one of npm|brew|clone|unknown, got: '$got'"; return 1 ;;
    esac

    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT

    # (b) npm-shaped path → npm. Same shape test_update_provenance.sh drives
    #     _cco_install_provenance with; here it must reach the RENDERED field.
    local npm_root="$tmp/usr/local/lib/node_modules/@claude-orchestrator/cco"
    _whoami_plant_tree "$npm_root" "0.0.0-fixture"
    _whoami_host "$npm_root/bin/cco" whoami
    got=$(_whoami_field provenance)
    [[ "$got" == "npm" ]] \
        || fail "an npm-shaped REPO_ROOT must render provenance 'npm', got: '$got'" || return 1

    # (c) plain non-git dir → unknown. Fail-SAFE: diagnostic, so an unclassifiable
    #     tree degrades to a legible marker rather than blowing up or going empty.
    local plain_root="$tmp/plain/cco"
    _whoami_plant_tree "$plain_root" "0.0.0-fixture"
    [[ ! -d "$plain_root/.git" ]] || fail "fixture broken: plain tree must have no .git" || return 1
    _whoami_host "$plain_root/bin/cco" whoami
    got=$(_whoami_field provenance)
    [[ "$got" == "unknown" ]] \
        || fail "a plain non-git REPO_ROOT must render provenance 'unknown', got: '$got'" || return 1
    return 0
}

# ── Ordering: identity first, then the sandbox modifier ──────────────

test_whoami_host_identity_block_precedes_the_dev_sandbox_block() {
    export CCO_DEV_SANDBOX=1          # passed through by _whoami_host, HOME is throwaway
    _whoami_host "$REPO_ROOT/bin/cco" whoami
    [[ $WA_RC -eq 0 ]] || fail "whoami under the sandbox failed rc=$WA_RC: $WA_OUT" || return 1

    local info_ln id_ln sb_ln
    info_ln=$(_whoami_line_of "host context")
    id_ln=$(_whoami_line_of "cco CLI")
    sb_ln=$(_whoami_line_of "Developer sandbox")
    # Both endpoints must be present, or the comparison below is vacuous.
    [[ -n "$sb_ln" ]] \
        || fail "fixture broken: the sandbox block did not render, got: $WA_OUT" || return 1
    [[ -n "$id_ln" ]] \
        || fail "the 'cco CLI' block must render under the sandbox too, got: $WA_OUT" || return 1
    [[ -n "$info_ln" ]] \
        || fail "fixture broken: no host-context line, got: $WA_OUT" || return 1

    [[ $info_ln -lt $id_ln ]] \
        || fail "the identity block must come AFTER the host-context line (info=$info_ln, cco CLI=$id_ln): $WA_OUT" || return 1
    [[ $id_ln -lt $sb_ln ]] \
        || fail "identity first, sandbox second (cco CLI=$id_ln, Developer sandbox=$sb_ln): $WA_OUT" || return 1
    return 0
}

# ── The block is HOST-only ───────────────────────────────────────────

test_whoami_container_branch_has_no_cli_identity_block() {
    lane_cco read-all whoami
    [[ $OP_RC -eq 0 ]] || fail "'cco whoami' must succeed at read-all, got rc=$OP_RC: $OP_OUT" || return 1
    # Branch proof: the in-container branch is the one with the Session identity block.
    [[ "$OP_OUT" == *"Session"* ]] \
        || fail "did not reach the in-container branch, got: $OP_OUT" || return 1
    [[ "$OP_OUT" != *"cco CLI"* ]] \
        || fail "the 'cco CLI' block is host-only; it must not render in a session: $OP_OUT" || return 1
    return 0
}
