#!/usr/bin/env bash
# tests/test_sync_meta.sh — per-machine sync-state fingerprint (P1 Commit 2)
#
# Fingerprint contract (design §4.6 / ADR-0022 F39): hash over the §4.1 synced
# set (project.yml + claude/** [+ secrets.env.example]; NEVER secrets.env /
# repo-root .claude/); machine-agnostic content; divergence lazy/read-time;
# no stored fingerprint => pristine (never divergent).
#
# Mask-safe: every assertion is guarded with `… || return 1`.

# Each test runs in its own subshell (bin/test); these exports do not leak.
_sm_test_env() {
    export CCO_ALLOW_HOST_RESOLVE=1
    export CCO_STATE_HOME="$1"
    unset XDG_STATE_HOME CCO_DATA_HOME CCO_CACHE_HOME
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/sync-meta.sh"
}

# Build a repo unit at <root> with the given project.yml + one claude file.
# Usage: _sm_repo <root> <project_yml_body> [<claude_file_content>]
_sm_repo() {
    local root="$1" yml="$2" claude_body="${3:-# guidelines}"
    mkdir -p "$root/.cco/claude"
    printf '%s\n' "$yml" > "$root/.cco/project.yml"
    printf '%s\n' "$claude_body" > "$root/.cco/claude/CLAUDE.md"
}

test_sync_fingerprint_deterministic() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sm_test_env "$tmp/state"

    _sm_repo "$tmp/r" "name: demo"
    local a b
    a=$(_sync_fingerprint_compute "$tmp/r")
    b=$(_sync_fingerprint_compute "$tmp/r")
    [[ -n "$a" ]]        || { echo "ASSERTION FAILED: empty fingerprint"; return 1; }
    [[ "$a" == "$b" ]]   || { echo "ASSERTION FAILED: non-deterministic ($a vs $b)"; return 1; }
}

test_sync_fingerprint_changes_with_content() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sm_test_env "$tmp/state"

    _sm_repo "$tmp/r" "name: demo" "# original"
    local before; before=$(_sync_fingerprint_compute "$tmp/r")
    printf '%s\n' "# edited" > "$tmp/r/.cco/claude/CLAUDE.md"
    local after; after=$(_sync_fingerprint_compute "$tmp/r")
    [[ "$before" != "$after" ]] || { echo "ASSERTION FAILED: edit did not change fingerprint"; return 1; }
}

test_sync_fingerprint_machine_agnostic() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sm_test_env "$tmp/state"

    # Identical synced content at two DIFFERENT paths must fingerprint the same.
    _sm_repo "$tmp/path/one" "name: demo" "# same"
    _sm_repo "$tmp/totally/other/two" "name: demo" "# same"
    local h1 h2
    h1=$(_sync_fingerprint_compute "$tmp/path/one")
    h2=$(_sync_fingerprint_compute "$tmp/totally/other/two")
    [[ "$h1" == "$h2" ]] || { echo "ASSERTION FAILED: fingerprint leaked an absolute path ($h1 vs $h2)"; return 1; }
}

test_sync_fingerprint_ignores_secrets_env() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sm_test_env "$tmp/state"

    _sm_repo "$tmp/r" "name: demo"
    local base; base=$(_sync_fingerprint_compute "$tmp/r")

    # secrets.env (the real secret file) is NEVER in the synced set.
    printf 'TOKEN=abc\n' > "$tmp/r/.cco/secrets.env"
    local with_secret; with_secret=$(_sync_fingerprint_compute "$tmp/r")
    [[ "$base" == "$with_secret" ]] || { echo "ASSERTION FAILED: secrets.env changed the fingerprint"; return 1; }

    # secrets.env.example (the skeleton) IS in the synced set.
    printf 'TOKEN=\n' > "$tmp/r/.cco/secrets.env.example"
    local with_example; with_example=$(_sync_fingerprint_compute "$tmp/r")
    [[ "$base" != "$with_example" ]] || { echo "ASSERTION FAILED: secrets.env.example missing from synced set"; return 1; }
}

test_sync_fingerprint_ignores_repo_root_claude() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sm_test_env "$tmp/state"

    _sm_repo "$tmp/r" "name: demo"
    local base; base=$(_sync_fingerprint_compute "$tmp/r")

    # The repo-root .claude/ (Claude Code's own, not cco config) is excluded.
    mkdir -p "$tmp/r/.claude"
    printf 'noise\n' > "$tmp/r/.claude/settings.json"
    local after; after=$(_sync_fingerprint_compute "$tmp/r")
    [[ "$base" == "$after" ]] || { echo "ASSERTION FAILED: repo-root .claude leaked into the synced set"; return 1; }
}

test_sync_fingerprint_set_get_roundtrip() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sm_test_env "$tmp/state"

    _sync_fingerprint_set "/abs/repo" "deadbeef"
    [[ "$(_sync_fingerprint_get /abs/repo)" == "deadbeef" ]] || { echo "ASSERTION FAILED: roundtrip"; return 1; }
    _sync_fingerprint_set "/abs/repo" "cafef00d"
    [[ "$(_sync_fingerprint_get /abs/repo)" == "cafef00d" ]] || { echo "ASSERTION FAILED: upsert overwrite"; return 1; }
    # Upsert must not leave a duplicate line.
    local n; n=$(awk -F'\t' '$1=="/abs/repo"' "$(_sync_meta_file)" | wc -l | tr -d ' ')
    [[ "$n" -eq 1 ]] || { echo "ASSERTION FAILED: duplicate entry ($n)"; return 1; }
}

test_sync_fingerprint_clear() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sm_test_env "$tmp/state"

    _sync_fingerprint_set "/a" "x"
    _sync_fingerprint_set "/b" "y"
    _sync_fingerprint_clear "/a"
    [[ -z "$(_sync_fingerprint_get /a)" ]] || { echo "ASSERTION FAILED: /a not cleared"; return 1; }
    [[ "$(_sync_fingerprint_get /b)" == "y" ]] || { echo "ASSERTION FAILED: /b clobbered by clear"; return 1; }
}

test_sync_pristine_is_never_divergent() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sm_test_env "$tmp/state"

    _sm_repo "$tmp/r" "name: demo"
    # No stored fingerprint => pristine, never divergent.
    if _sync_is_divergent "$tmp/r"; then echo "ASSERTION FAILED: pristine repo reported divergent"; return 1; fi
}

test_sync_record_then_not_divergent() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sm_test_env "$tmp/state"

    _sm_repo "$tmp/r" "name: demo"
    _sync_record "$tmp/r"
    if _sync_is_divergent "$tmp/r"; then echo "ASSERTION FAILED: just-recorded repo reported divergent"; return 1; fi
}

test_sync_edit_after_record_is_divergent() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sm_test_env "$tmp/state"

    _sm_repo "$tmp/r" "name: demo" "# v1"
    _sync_record "$tmp/r"
    printf '%s\n' "# v2 (edited locally)" > "$tmp/r/.cco/claude/CLAUDE.md"
    _sync_is_divergent "$tmp/r" || { echo "ASSERTION FAILED: local edit not detected as divergent"; return 1; }
}

test_sync_record_noop_without_cco() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _sm_test_env "$tmp/state"

    mkdir -p "$tmp/code-only"   # a code-only member: no .cco/
    _sync_record "$tmp/code-only"
    [[ -z "$(_sync_fingerprint_get "$tmp/code-only")" ]] || { echo "ASSERTION FAILED: recorded a fingerprint for a .cco-less repo"; return 1; }
    if _sync_is_divergent "$tmp/code-only"; then echo "ASSERTION FAILED: code-only repo reported divergent"; return 1; fi
}
