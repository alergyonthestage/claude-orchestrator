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
    mkdir -p "$CCO_DATA_HOME/packs/$name" "$CCO_STATE_HOME/packs/$name"
    printf 'url: local\n' > "$CCO_DATA_HOME/packs/$name/source"
}

# Seed a user template (kind project) + its sidecars. Usage: _sw_seed_template <name>
_sw_seed_template() {
    local name="$1"
    mkdir -p "$CCO_TEMPLATES_DIR/project/$name"
    printf 'name: %s\n' "$name" > "$CCO_TEMPLATES_DIR/project/$name/template.yml"
    mkdir -p "$CCO_DATA_HOME/templates/$name" "$CCO_STATE_HOME/templates/$name"
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
