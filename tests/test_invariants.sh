#!/usr/bin/env bash
# tests/test_invariants.sh — design invariant tests
#
# These tests directly encode the design invariants from
# docs/maintainers/foundation/analysis/spec.md and
# docs/maintainers/foundation/design/architecture.md. They MUST pass; failure means the
# implementation does not respect the architectural design.

# ── Invariant 1: Tool vs User Config Separation ───────────────────────
# defaults/ is tracked in git (tool code) and MUST NOT be modified by cco commands.

test_invariant_1_defaults_not_modified_by_init() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"

    # Hash all files in defaults/ before init
    local before_hash after_hash
    before_hash=$(find "$REPO_ROOT/defaults" -type f | LC_ALL=C sort | xargs sha1sum 2>/dev/null || \
                  find "$REPO_ROOT/defaults" -type f | LC_ALL=C sort | xargs md5 2>/dev/null)

    init_global "$tmpdir" --lang "English"

    # Hash after init — must be identical
    after_hash=$(find "$REPO_ROOT/defaults" -type f | LC_ALL=C sort | xargs sha1sum 2>/dev/null || \
                 find "$REPO_ROOT/defaults" -type f | LC_ALL=C sort | xargs md5 2>/dev/null)

    assert_equals "$before_hash" "$after_hash" \
        "defaults/ was modified by cco init (design invariant: defaults/ is read-only tool code)"
}

test_invariant_1_init_creates_in_global_not_defaults() {
    # cco init writes to global/, never to defaults/
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    init_global "$tmpdir" --lang "English"
    # global/.claude must exist (user copy)
    assert_dir_exists "$HOME/.cco/.claude"
    # defaults/ must not have been touched (no new timestamp marker)
    assert_dir_exists "$REPO_ROOT/defaults/global/.claude"
}

# ── Invariant 2: Context Hierarchy ───────────────────────────────────
# Global config → ~/.claude/ (user-scope, ro in container)
# Project config → /workspace/.claude (project-scope, rw in container)

test_invariant_2_global_config_at_home_claude_in_container() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_contains "$compose" "/home/claude/.claude/settings.json"
    assert_file_contains "$compose" "/home/claude/.claude/CLAUDE.md"
    assert_file_contains "$compose" "/home/claude/.claude/rules"
}

test_invariant_2_project_config_at_workspace_claude_readonly_by_default() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    # Decentralized source is <repo>/.cco/claude (no dot); the container target
    # /workspace/.claude is the fixed contract (P3 read-path flip).
    assert_file_contains "$compose" "/claude:/workspace/.claude"
    # ADR-0049 §6 REVERSES P17: a normal session no longer authors the project
    # Claude config by default. claude_access derives from cco (read-project →
    # Cp=ro), so B2 /workspace/.claude is mounted :ro. Authoring is now an explicit
    # opt-in (--claude-access repo or a cco edit level).
    if ! grep -qE "/claude:/workspace/\.claude:ro" "$compose"; then
        echo "ASSERTION FAILED: project .claude must be :ro by default (ADR-0049 reverses P17)"
        return 1
    fi
    # An explicit --claude-access repo re-opens B2 for authoring (Cp=rw).
    run_cco start "test-proj" --claude-access repo --dry-run --dump
    compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    if grep -qE "/claude:/workspace/\.claude:ro" "$compose"; then
        echo "ASSERTION FAILED: --claude-access repo must make project .claude rw"
        return 1
    fi
}

# ── Invariant 3: Auto Memory Path ────────────────────────────────────
# Claude state (memory + transcripts) is mounted as .cco/claude-state/ on the host.
# Container path is /home/claude/.claude/projects/-workspace
# (-workspace = WORKDIR /workspace with root slash replaced by dash)

test_invariant_3_auto_memory_exact_container_path() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_contains "$compose" "/home/claude/.claude/projects/-workspace"
}

test_invariant_3_memory_is_project_specific_host_path() {
    # Each project's state directory is isolated via mount
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "proj-a" "$(minimal_project_yml proj-a)"
    create_project "$tmpdir" "proj-b" "$(minimal_project_yml proj-b)"

    run_cco start "proj-a" --dry-run --dump
    local dir_a="$DRY_RUN_DIR"
    run_cco start "proj-b" --dry-run --dump
    local dir_b="$DRY_RUN_DIR"

    local compose_a="$dir_a/.cco/docker-compose.yml"
    local compose_b="$dir_b/.cco/docker-compose.yml"

    # Each project's compose references its own STATE claude-state directory
    # (machine-local, keyed by project identity; design §2.2)
    assert_file_contains "$compose_a" "projects/proj-a/session/claude-state"
    assert_file_contains "$compose_b" "projects/proj-b/session/claude-state"
    assert_file_not_contains "$compose_a" "projects/proj-b/session/claude-state"
    assert_file_not_contains "$compose_b" "projects/proj-a/session/claude-state"
}

# ── Invariant 4: Container/Network Naming ────────────────────────────

test_invariant_4_container_name_is_cc_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-project" "$(minimal_project_yml my-project)"
    run_cco start "my-project" --dry-run --dump
    assert_file_contains "$DRY_RUN_DIR/.cco/docker-compose.yml" \
        "container_name: cc-my-project"
}

test_invariant_4_network_name_is_cc_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "my-project" "$(minimal_project_yml my-project)"
    run_cco start "my-project" --dry-run --dump
    assert_file_contains "$DRY_RUN_DIR/.cco/docker-compose.yml" \
        "name: cc-my-project"
}

test_invariant_4_two_projects_have_distinct_names() {
    # Two projects must have distinct container/network names
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "proj-one" "$(minimal_project_yml proj-one)"
    create_project "$tmpdir" "proj-two" "$(minimal_project_yml proj-two)"

    run_cco start "proj-one" --dry-run --dump
    local dir_one="$DRY_RUN_DIR"
    run_cco start "proj-two" --dry-run --dump
    local dir_two="$DRY_RUN_DIR"

    assert_file_contains "$dir_one/.cco/docker-compose.yml" "cc-proj-one"
    assert_file_contains "$dir_two/.cco/docker-compose.yml" "cc-proj-two"
    assert_file_not_contains "$dir_one/.cco/docker-compose.yml" "cc-proj-two"
    assert_file_not_contains "$dir_two/.cco/docker-compose.yml" "cc-proj-one"
}

# ── Invariant 5: Read-Only Mounts ─────────────────────────────────────
# Global config, gitconfig, packs must always be :ro

test_invariant_5_all_global_config_mounts_are_readonly() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"

    # Every line mounting from the global config dir must end with :ro
    # Exception: settings.json is rw (Claude Code writes runtime preferences)
    # Global config now lives in the CONFIG bucket (~/.cco/.claude; design §2.3)
    local global_path="$HOME/.cco/.claude"
    local violations
    violations=$(grep -F "$global_path" "$compose" | grep -v ":ro" | grep -v "settings.json:" || true)
    if [[ -n "$violations" ]]; then
        echo "ASSERTION FAILED: global config mount(s) without :ro (Design Invariant 5)"
        echo "$violations" | sed 's/^/  /'
        return 1
    fi
}

# ── Invariant 8: Placeholder Substitution ────────────────────────────

test_invariant_8_no_placeholders_after_init() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local repo="$tmpdir/test-project"; mkdir -p "$repo"
    ( cd "$repo" && run_cco init --name "test-project" --lang "English" )
    local found
    found=$(grep -rE '\{\{[^}]+\}\}' "$repo/.cco" 2>/dev/null || true)
    if [[ -n "$found" ]]; then
        echo "ASSERTION FAILED: unreplaced placeholders found after cco init scaffold"
        echo "$found" | sed 's/^/  /'
        return 1
    fi
}

# ── Invariant 9: Secrets Never in Compose ─────────────────────────────
# global/secrets.env values must NEVER appear in docker-compose.yml

test_invariant_9_secrets_not_written_to_compose() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"

    # Plant a recognizable secret value where cco now reads it (~/.cco/secrets.env)
    printf 'MY_SECRET=hunter2\nDATABASE_PASSWORD=s3cr3t!\n' > "$HOME/.cco/secrets.env"

    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"

    assert_file_not_contains "$compose" "hunter2"
    assert_file_not_contains "$compose" "s3cr3t!"
    assert_file_not_contains "$compose" "MY_SECRET"
    assert_file_not_contains "$compose" "DATABASE_PASSWORD"
}

# ── Invariant 10: Project Name Validation ─────────────────────────────
# Names must match ^[a-z0-9][a-z0-9-]*$

test_invariant_10_rejects_name_with_spaces() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local repo="$tmpdir/repo"; mkdir -p "$repo"
    if ( cd "$repo" && run_cco init --name "my project" ) 2>/dev/null; then
        echo "ASSERTION FAILED: should reject name with spaces (Design Invariant 10)"
        return 1
    fi
}

test_invariant_10_rejects_name_with_uppercase() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local repo="$tmpdir/repo"; mkdir -p "$repo"
    if ( cd "$repo" && run_cco init --name "MyProject" ) 2>/dev/null; then
        echo "ASSERTION FAILED: should reject uppercase name (Design Invariant 10)"
        return 1
    fi
}

test_invariant_10_rejects_name_with_underscore() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local repo="$tmpdir/repo"; mkdir -p "$repo"
    if ( cd "$repo" && run_cco init --name "my_project" ) 2>/dev/null; then
        echo "ASSERTION FAILED: should reject underscore in name (Design Invariant 10)"
        return 1
    fi
}

test_invariant_10_accepts_lowercase_hyphens_numbers() {
    # Valid name: lowercase letters, hyphens, digits
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local repo="$tmpdir/repo"; mkdir -p "$repo"
    ( cd "$repo" && run_cco init --name "valid-proj-123" --lang "English" )
    assert_file_contains "$repo/.cco/project.yml" "name: valid-proj-123"
}

# ── Invariant 11: no negative-only rc assertions (RC-17) ──────────────
# A container-operator test must assert an OUTCOME (an exact exit code plus an
# observable state change) or an EXPLICIT refusal (assert_refused). Asserting
# "the rc was not 2" states only "not refused by THIS gate" and is satisfied by a
# verb that dies rc=1 — it shipped `cco repo rename` dead-but-green for a whole
# release cycle (tests/test_operator_shim.sh:647-653, now retro-fitted).
#
# The pattern matches ANY rc-shaped identifier under `-ne` OR `!=`, not one token
# sequence: an operator-specific, case-sensitive `(OP_RC|CCO_RC|rc)` form lets the
# RC, exit_code, status and `!=` spellings straight past — forms a future author
# writes by accident, not by evasion. A deliberate exception carries a same-line
# `# allow-negative-rc: <why>` marker. (This comment deliberately avoids writing
# the banned expressions out: the invariant scans the whole tests/ tree, itself
# included, which is the correct behaviour — it may not exempt its own file.)
#
# THREE syntactic shapes, because a ban that closes one spelling of an idiom has
# not closed the idiom. The first draft required a `$` sigil and fixed the operand
# order, so the two forms a bash author reaches for most naturally after the test
# construct — the arithmetic one, where the sigil is optional, and the reversed
# comparison — both escaped it. Neither appears in tests/ today; they are closed
# now because "not a false green today" is not a property that survives the next
# author. Hence: sigil optional, and the reversed order is its own alternation.
#
# Scope, stated honestly: this closes the "not 2" idiom as a class, NOT the
# negative-space family. The sibling "not 0" idiom is one code over and is
# already widespread (46 sites); converting it is its own change with its own
# review, recorded as a follow-up in pre-revalidation-backlog.md.
test_invariant_11_no_negative_only_rc_assertions() {
    local ids='OP_RC|CCO_RC|RC|rc|exit_code|status|ret|code'
    local hits
    hits=$(grep -rnE \
             "(^|[^A-Za-z_0-9\$])\\\$?\\{?($ids)\\}?[[:space:]]*(-ne|!=)[[:space:]]*2([^0-9]|\$)|(^|[^A-Za-z_0-9])2[[:space:]]*(-ne|!=)[[:space:]]*\\\$?\\{?($ids)\\}?([^A-Za-z_0-9]|\$)" \
             "$REPO_ROOT/tests" | grep -v 'allow-negative-rc:' || true)
    [[ -z "$hits" ]] || fail "banned negative-only rc assertion (RC-17): assert an exact rc + a state change, or assert_refused"$'\n'"$hits"
}

# ── INV-F probe locality (RC-2 / 04-host-path-class.md §6.7) ──────────
# A path read from the STATE index is a HOST path; in a container-operator session
# it must NEVER be existence-tested (it can never exist there — the member is bound
# at <workdir>/<name>). This catches the copy-paste regression class: a variable
# assigned from _index_get_path that is then -d/-f/-e-tested on a LATER line within
# the SAME function. Deliberately coarse and order-sensitive (a test on a line
# BEFORE the assignment, e.g. the effective-mounts fallback in cmd-project-query.sh,
# is fine; _index_get_path_any is a different, host-only accessor and word-bounded
# out). Availability is decided by _cco_member_probe_path / _env_member_state, never
# a raw -d.
#
# Allowlist — files where the pattern is legitimately present because the verb is
# HOST-ONLY (the shim refuses it before the body runs), so the host path is real:
#   cmd-forget.sh / cmd-join.sh — forget / join (host-only membership verbs)
#   cmd-config.sh               — `config validate` (host-only, ADR / CLI-surface review)
#   cmd-project-rename.sh       — `project rename` (host-only, re-keys machine state)
test_invariant_probe_locality() {
    local allow=" cmd-forget.sh cmd-join.sh cmd-config.sh cmd-project-rename.sh "
    local prog='
/^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{?[ \t]*$/ { for (v in seen) delete seen[v]; next }
{
  if (match($0, /[A-Za-z_][A-Za-z0-9_]*=\$\(_index_get_path[^A-Za-z0-9_]/)) {
    tok = substr($0, RSTART, RLENGTH); sub(/=.*/, "", tok); seen[tok] = 1
  }
  for (v in seen) {
    if (($0 ~ ("-[def] \"[$]" v "\"")) || ($0 ~ ("-[def] \"[$][{]" v "[}]\""))) {
      if ($0 !~ (v "=[$][(]_index_get_path")) print FILENAME ":" FNR ": " $0
    }
  }
}'
    local f base hits=""
    for f in "$REPO_ROOT"/lib/*.sh; do
        base=$(basename "$f")
        case "$allow" in *" $base "*) continue ;; esac
        local h; h=$(awk "$prog" "$f")
        [[ -n "$h" ]] && hits="${hits}${h}"$'\n'
    done
    [[ -z "$hits" ]] || fail "INV-F: an index HOST path is existence-tested in-container (probe via _cco_member_probe_path / _env_member_state instead):"$'\n'"$hits"
}

# ── INV-F.3 index resolver is host-only by contract (RC-2 §6.7) ───────
# _resolve_unit_dir_for_project returns a HOST unit directory and never resolves in
# a session. No module reachable under the operator shim whitelist may call it — a
# project NAME is resolved with the operator-aware _resolve_project_yml /
# _resolve_project_cco_dir. Denylist form: a new call site in any reachable module
# fails this. Comment mentions (Depends: lines) are excluded; only real calls count.
# cmd-resolve.sh (which DEFINES the resolver) and the host-only verbs (update /
# export-import / add / clean / chrome / start / stop) are outside the whitelist.
test_invariant_index_resolver_host_only() {
    local deny="cmd-project-validate.sh cmd-project-coords.sh cmd-project-query.sh \
cmd-llms.sh cmd-template.sh cmd-pack.sh cmd-repo.sh rename.sh tags.sh \
cmd-config.sh index.sh access-scope.sh paths.sh"
    local m f hits=""
    for m in $deny; do
        f="$REPO_ROOT/lib/$m"
        [[ -f "$f" ]] || continue
        # Real calls only: drop comment lines (first non-space char is #).
        local h; h=$(grep -nE '_resolve_unit_dir_for_project' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
        [[ -n "$h" ]] && hits="${hits}${m}: ${h}"$'\n'
    done
    [[ -z "$hits" ]] || fail "INV-F.3: host-only _resolve_unit_dir_for_project called from a shim-reachable module (use _resolve_project_yml / _resolve_project_cco_dir):"$'\n'"$hits"
}
