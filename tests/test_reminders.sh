#!/usr/bin/env bash
# tests/test_reminders.sh — non-blocking config reminder aggregator (P1 Commit 3)
#
# ADR-0008: (a) uncommitted ~/.cco, (b) uncommitted involved <repo>/.cco,
# (c) cross-repo divergence (§4.6 fingerprint). All advisory, never blocking
# (P14 / H1). Mask-safe: every assertion guarded with `… || return 1`.

# Self-contained env: redirect HOME (for ~/.cco) + STATE (for sync-meta), give a
# hermetic git identity, source the libs under test. CCO_ALLOW_HOST_RESOLVE=1 is
# required because the test runs inside the container (/.dockerenv present).
_rem_test_env() {
    local tmp="$1"
    export HOME="$tmp/home"; mkdir -p "$HOME"
    cat > "$HOME/.gitconfig" <<'GITCFG'
[user]
	name = cco-test
	email = cco-test@example.com
[init]
	defaultBranch = main
GITCFG
    export CCO_ALLOW_HOST_RESOLVE=1
    export CCO_STATE_HOME="$tmp/state"
    unset XDG_STATE_HOME CCO_DATA_HOME CCO_CACHE_HOME XDG_CONFIG_HOME
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/sync-meta.sh"
    source "$REPO_ROOT/lib/reminders.sh"
}

# Create a git repo at <root> with a .cco/ holding the given claude content,
# committed clean. Usage: _rem_repo <root> <claude_content>
_rem_repo() {
    local root="$1" content="$2"
    mkdir -p "$root/.cco/claude"
    printf 'name: demo\n' > "$root/.cco/project.yml"
    printf '%s\n' "$content" > "$root/.cco/claude/CLAUDE.md"
    git -C "$root" init -q
    git -C "$root" add -A
    git -C "$root" commit -q -m "init"
}

test_reminder_uncommitted_config_warns() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _rem_test_env "$tmp"

    local cfg; cfg=$(_cco_config_dir)          # ~/.cco
    git -C "$cfg" init -q
    printf 'pack\n' > "$cfg/packs.txt"          # uncommitted (untracked) change

    local out; out=$(_emit_config_reminders 2>&1)
    printf '%s' "$out" | grep -qF "~/.cco has uncommitted" || { echo "ASSERTION FAILED: missing (a) reminder; got: $out"; return 1; }
}

test_reminder_clean_config_silent() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _rem_test_env "$tmp"

    local cfg; cfg=$(_cco_config_dir)
    git -C "$cfg" init -q
    printf 'pack\n' > "$cfg/packs.txt"
    git -C "$cfg" add -A; git -C "$cfg" commit -q -m "init"

    local out; out=$(_emit_config_reminders 2>&1)
    printf '%s' "$out" | grep -qF "~/.cco has uncommitted" && { echo "ASSERTION FAILED: (a) fired on a clean config; got: $out"; return 1; }
    return 0
}

test_reminder_nongit_config_silent() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _rem_test_env "$tmp"

    _cco_config_dir >/dev/null                  # creates ~/.cco but NOT a git tree
    local out; out=$(_emit_config_reminders 2>&1)
    printf '%s' "$out" | grep -qF "~/.cco has uncommitted" && { echo "ASSERTION FAILED: (a) fired on a non-git config; got: $out"; return 1; }
    return 0
}

test_reminder_uncommitted_repo_cco_warns() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _rem_test_env "$tmp"

    _rem_repo "$tmp/repo1" "# v1"
    printf '%s\n' "# locally edited, not committed" > "$tmp/repo1/.cco/claude/CLAUDE.md"

    local out; out=$(_emit_config_reminders "$tmp/repo1" 2>&1)
    printf '%s' "$out" | grep -qF "repo1: .cco has uncommitted" || { echo "ASSERTION FAILED: missing (b) reminder; got: $out"; return 1; }
}

test_reminder_committed_repo_cco_silent() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _rem_test_env "$tmp"

    _rem_repo "$tmp/repo1" "# v1"               # clean, committed
    local out; out=$(_emit_config_reminders "$tmp/repo1" 2>&1)
    printf '%s' "$out" | grep -qF "repo1: .cco has uncommitted" && { echo "ASSERTION FAILED: (b) fired on a clean repo; got: $out"; return 1; }
    return 0
}

test_reminder_cross_repo_divergence_warns() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _rem_test_env "$tmp"

    _rem_repo "$tmp/repo1" "# config A"
    _rem_repo "$tmp/repo2" "# config B (different)"

    local out; out=$(_emit_config_reminders "$tmp/repo1" "$tmp/repo2" 2>&1)
    printf '%s' "$out" | grep -qF "divergent .cco" || { echo "ASSERTION FAILED: missing (c) divergence reminder; got: $out"; return 1; }
}

test_reminder_identical_repos_no_divergence() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _rem_test_env "$tmp"

    _rem_repo "$tmp/repo1" "# same config"
    _rem_repo "$tmp/repo2" "# same config"

    local out; out=$(_emit_config_reminders "$tmp/repo1" "$tmp/repo2" 2>&1)
    printf '%s' "$out" | grep -qF "divergent .cco" && { echo "ASSERTION FAILED: (c) fired on identical .cco; got: $out"; return 1; }
    return 0
}

test_reminder_single_repo_no_divergence() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _rem_test_env "$tmp"

    _rem_repo "$tmp/repo1" "# only one"
    local out; out=$(_emit_config_reminders "$tmp/repo1" 2>&1)
    printf '%s' "$out" | grep -qF "divergent .cco" && { echo "ASSERTION FAILED: (c) fired on a single repo; got: $out"; return 1; }
    return 0
}

test_reminder_always_returns_zero() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _rem_test_env "$tmp"

    # Dirty config + dirty repo + divergence: still non-blocking (P14).
    local cfg; cfg=$(_cco_config_dir); git -C "$cfg" init -q; printf 'x\n' > "$cfg/x"
    _rem_repo "$tmp/repo1" "# A"; printf '# edit\n' > "$tmp/repo1/.cco/claude/CLAUDE.md"
    _rem_repo "$tmp/repo2" "# B"

    local rc=0
    _emit_config_reminders "$tmp/repo1" "$tmp/repo2" >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 0 ]] || { echo "ASSERTION FAILED: aggregator returned non-zero ($rc) — must never block"; return 1; }
}
