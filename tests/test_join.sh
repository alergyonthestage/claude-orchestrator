#!/usr/bin/env bash
# tests/test_join.sh — `cco join <project>` Journey E (ADR-0034).
# Add the current repo as a MEMBER of an existing project: embed its coordinate
# into every in-sync member's repos[], bind its path in the index, and (with
# --sync) receive the project's .cco/. The former Journey-C form was removed.

# Seed a synced multi-repo project: each named repo gets a byte-identical
# committed .cco/project.yml (name: <proj>, repos: all members) and an index
# binding. No stored fingerprint → pristine → all members classify as `synced`.
_seed_synced_project() {
    local tmpdir="$1" proj="$2"; shift 2
    local r body="name: $proj"$'\n'"repos:"$'\n'
    for r in "$@"; do
        body+="  - name: $r"$'\n'"    url: git@example.com:org/$r.git"$'\n'
    done
    for r in "$@"; do
        local d="$tmpdir/repos/$r"
        mkdir -p "$d/.cco/claude"
        printf '%s' "$body" > "$d/.cco/project.yml"
        seed_index_path "$r" "$d"
    done
    index_set_project_repos "$proj" "$@"
}

# A throwaway git repo with an 'origin' remote, so url derivation has something.
_mk_git_repo() {
    local d="$1" url="$2"
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" remote add origin "$url"
}

test_join_adds_member_to_all_synced_members_and_index() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _seed_synced_project "$tmpdir" myproj repo-a repo-b

    local joiner="$tmpdir/repos/joiner"
    _mk_git_repo "$joiner" "git@example.com:org/joiner.git"

    cd "$joiner" || return 1
    run_cco join myproj --name joiner
    assert_output_contains "Joined 'myproj' as member 'joiner'"

    # repos[] edited in EVERY in-sync member, url auto-derived from origin.
    assert_file_contains "$tmpdir/repos/repo-a/.cco/project.yml" "name: joiner"
    assert_file_contains "$tmpdir/repos/repo-a/.cco/project.yml" "url: git@example.com:org/joiner.git"
    assert_file_contains "$tmpdir/repos/repo-b/.cco/project.yml" "name: joiner"

    # Index: membership + path binding.
    assert_file_contains "$(cco_index_file)" "joiner"
    assert_file_contains "$(cco_index_file)" 'joiner: "'"$joiner"'"'
}

test_join_unknown_project_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local joiner="$tmpdir/repos/joiner"
    _mk_git_repo "$joiner" "git@example.com:org/joiner.git"

    cd "$joiner" || return 1
    if run_cco join ghost --name joiner 2>/dev/null; then
        fail "join of an unregistered project should fail"
    fi
    assert_output_contains "No project named 'ghost'"
}

test_join_rejects_existing_member_name() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _seed_synced_project "$tmpdir" myproj repo-a repo-b
    local joiner="$tmpdir/repos/joiner"
    _mk_git_repo "$joiner" "git@example.com:org/joiner.git"

    # repo-a is already a member → reusing its name must be refused.
    cd "$joiner" || return 1
    if run_cco join myproj --name repo-a 2>/dev/null; then
        fail "join with an already-used member name should fail"
    fi
    assert_output_contains "already a member"
}

test_join_rejects_when_repo_hosts_the_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _seed_synced_project "$tmpdir" myproj repo-a repo-b

    # Running join from a repo that already HOSTS myproj is a no-op error.
    cd "$tmpdir/repos/repo-a" || return 1
    if run_cco join myproj --name repo-a2 2>/dev/null; then
        fail "join from the project's own host repo should fail"
    fi
    assert_output_contains "already hosts 'myproj'"
}

test_join_divergent_project_non_tty_dies() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _seed_synced_project "$tmpdir" myproj repo-a repo-b
    # Make repo-b divergent: a stored fingerprint the current content can't match.
    printf '%s\t%s\n' "$tmpdir/repos/repo-b" "deadbeefdivergent" >> "$CCO_STATE_HOME/sync-meta"

    local joiner="$tmpdir/repos/joiner"
    _mk_git_repo "$joiner" "git@example.com:org/joiner.git"

    # Non-interactive + divergent members → must refuse (Case C needs a choice).
    cd "$joiner" || return 1
    if run_cco join myproj --name joiner </dev/null 2>/dev/null; then
        fail "join into a divergent project should fail non-interactively"
    fi
    assert_output_contains "divergent"
    # Nothing was added to the in-sync member either.
    assert_file_not_contains "$tmpdir/repos/repo-a/.cco/project.yml" "name: joiner"
}

test_join_sync_copies_cco_into_joining_repo() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _seed_synced_project "$tmpdir" myproj repo-a

    local joiner="$tmpdir/repos/joiner"
    _mk_git_repo "$joiner" "git@example.com:org/joiner.git"

    cd "$joiner" || return 1
    run_cco join myproj --name joiner --sync

    # --sync copies the project's .cco/ into the joining repo (Case B).
    assert_file_exists "$joiner/.cco/project.yml"
    assert_file_contains "$joiner/.cco/project.yml" "name: myproj"
}

test_join_without_origin_warns_but_joins() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    _seed_synced_project "$tmpdir" myproj repo-a

    # A plain dir with no git origin → joins, url omitted, with a warning.
    local joiner="$tmpdir/repos/joiner"; mkdir -p "$joiner"
    cd "$joiner" || return 1
    run_cco join myproj --name joiner
    assert_output_contains "no 'origin' remote"
    assert_file_contains "$tmpdir/repos/repo-a/.cco/project.yml" "name: joiner"
}
