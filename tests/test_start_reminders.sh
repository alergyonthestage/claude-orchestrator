#!/usr/bin/env bash
# tests/test_start_reminders.sh — cco start config reminders (P1 Commit 5)
#
# H1 (ADR-0008): cco start runs the non-blocking reminder aggregator AFTER
# member resolution. P1 wires ONLY this hook; the rest of the §4.4 source
# selection (--from, Case-C, divergence notice, source transparency) lands in
# P2 against the decentralized layout. The aggregator is silent when members
# carry no <repo>/.cco/ (the pre-P2 central layout) — see test_start_dry_run for
# that path. Here members are decentralized git repos that DO carry .cco/.
# Mask-safe: every assertion guarded with `… || return 1`.

# A central project.yml (start-compatible) listing the given member repos.
# Usage: _str_proj_yml <proj_name> <repo_name>...
_str_proj_yml() {
    local name="$1"; shift
    printf 'name: %s\n' "$name"
    printf 'description: "Test"\n'
    printf 'auth:\n  method: oauth\n'
    printf 'docker:\n  ports: []\n  env: {}\n'
    printf 'repos:\n'
    local r
    for r in "$@"; do printf '  - name: %s\n' "$r"; done
}

# A git repo with a committed .cco/ holding the given CLAUDE.md content.
# Usage: _str_git_repo <root> <claude_content>
_str_git_repo() {
    local root="$1" content="$2"
    mkdir -p "$root/.cco/claude"
    printf 'name: demo\n' > "$root/.cco/project.yml"
    printf '%s\n' "$content" > "$root/.cco/claude/CLAUDE.md"
    git -C "$root" init -q
    git -C "$root" add -A
    git -C "$root" commit -q -m init
}

test_start_reminds_uncommitted_member_cco() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_global_from_defaults "$tmp"

    _str_git_repo "$tmp/repoA" "# committed"
    printf '%s\n' "# locally edited, uncommitted" > "$tmp/repoA/.cco/claude/CLAUDE.md"
    seed_index_path repoA "$tmp/repoA"

    create_project "$tmp" "proj" "$(_str_proj_yml proj repoA)"
    run_cco start proj --dry-run || return 1
    assert_output_contains "repoA: .cco has uncommitted" || return 1
}

test_start_silent_when_member_cco_clean() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_global_from_defaults "$tmp"

    _str_git_repo "$tmp/repoA" "# clean committed"
    seed_index_path repoA "$tmp/repoA"

    create_project "$tmp" "proj" "$(_str_proj_yml proj repoA)"
    run_cco start proj --dry-run || return 1
    assert_output_not_contains "repoA: .cco has uncommitted" || return 1
}

test_start_reminds_cross_repo_divergence() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_global_from_defaults "$tmp"

    _str_git_repo "$tmp/repoA" "# config A"
    _str_git_repo "$tmp/repoB" "# config B (different)"   # both clean, divergent content
    seed_index_path repoA "$tmp/repoA"
    seed_index_path repoB "$tmp/repoB"

    create_project "$tmp" "proj" "$(_str_proj_yml proj repoA repoB)"
    run_cco start proj --dry-run || return 1
    assert_output_contains "divergent .cco" || return 1
}

test_start_no_divergence_when_members_identical() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_global_from_defaults "$tmp"

    _str_git_repo "$tmp/repoA" "# same config"
    _str_git_repo "$tmp/repoB" "# same config"
    seed_index_path repoA "$tmp/repoA"
    seed_index_path repoB "$tmp/repoB"

    create_project "$tmp" "proj" "$(_str_proj_yml proj repoA repoB)"
    run_cco start proj --dry-run || return 1
    assert_output_not_contains "divergent .cco" || return 1
}

test_start_succeeds_with_reminders() {
    # The reminder hook must not break the start flow (P14 non-blocking): a dirty
    # member still produces a successful dry-run compose.
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    setup_global_from_defaults "$tmp"

    _str_git_repo "$tmp/repoA" "# committed"
    printf '%s\n' "# dirty" > "$tmp/repoA/.cco/claude/CLAUDE.md"
    seed_index_path repoA "$tmp/repoA"

    create_project "$tmp" "proj" "$(_str_proj_yml proj repoA)"
    run_cco start proj --dry-run --dump || return 1
    assert_file_exists "$DRY_RUN_DIR/.cco/docker-compose.yml" || return 1
}
