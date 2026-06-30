#!/usr/bin/env bash
# tests/test_update_provenance.sh — provenance-aware engine-update hint (ADR-0037
# D8). `cco update` runs migrations/discovery only; it must tell the user how to
# upgrade the cco ENGINE based on how cco was installed (npm / brew / clone).

test_provenance_npm() {
    source "$REPO_ROOT/lib/paths.sh"
    REPO_ROOT="/usr/local/lib/node_modules/@claude-orchestrator/cco"
    [[ "$(_cco_install_provenance)" == "npm" ]] \
        || fail "expected npm provenance for a node_modules path"
}

test_provenance_brew() {
    source "$REPO_ROOT/lib/paths.sh"
    REPO_ROOT="/opt/homebrew/Cellar/cco/0.4.0"
    [[ "$(_cco_install_provenance)" == "brew" ]] \
        || fail "expected brew provenance for a Cellar path"
}

test_provenance_clone() {
    local d; d=$(mktemp -d); trap "rm -rf '$d'" EXIT
    mkdir -p "$d/.git"
    source "$REPO_ROOT/lib/paths.sh"
    REPO_ROOT="$d"
    [[ "$(_cco_install_provenance)" == "clone" ]] \
        || fail "expected clone provenance for a .git working tree"
}

test_provenance_unknown() {
    local d; d=$(mktemp -d); trap "rm -rf '$d'" EXIT
    source "$REPO_ROOT/lib/paths.sh"
    REPO_ROOT="$d"
    [[ "$(_cco_install_provenance)" == "unknown" ]] \
        || fail "expected unknown provenance for a bare dir"
}

test_engine_hint_npm_prints_npm_command() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/cmd-update.sh"
    REPO_ROOT="/x/node_modules/@claude-orchestrator/cco"
    local out; out=$(_cco_engine_update_hint 2>&1)
    echo "$out" | grep -qF "npm update -g @claude-orchestrator/cco" \
        || fail "npm hint missing the npm update command: $out"
}

test_engine_hint_clone_prints_git_pull() {
    local d; d=$(mktemp -d); trap "rm -rf '$d'" EXIT
    mkdir -p "$d/.git"
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/cmd-update.sh"
    REPO_ROOT="$d"
    local out; out=$(_cco_engine_update_hint 2>&1)
    echo "$out" | grep -qF "git -C" \
        || fail "clone hint missing git pull: $out"
}

test_engine_hint_unknown_silent() {
    local d; d=$(mktemp -d); trap "rm -rf '$d'" EXIT
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/cmd-update.sh"
    REPO_ROOT="$d"
    local out; out=$(_cco_engine_update_hint 2>&1)
    [[ -z "$out" ]] || fail "unknown provenance should stay silent, got: $out"
}
