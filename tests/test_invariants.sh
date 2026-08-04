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
    # ADR-0049 §6 REVERSES P17: a normal session no longer authors the project
    # Claude config by default. claude_access derives from cco (read-project →
    # Cp=ro), so B2 /workspace/.claude is mounted :ro. Authoring is now an explicit
    # opt-in (--claude-access repo or a cco edit level).
    #
    # Since ADR-0055 D7 the SOURCE behind that target is the framework-composed
    # view whenever B2 is :ro (the functional-write floor needs a mountpoint to
    # hang on), so what this invariant pins is the MODE of the mount holding
    # /workspace/.claude — not which directory happens to be behind it.
    if ! grep -qE ':/workspace/\.claude:ro"$' "$compose"; then
        echo "ASSERTION FAILED: project .claude must be :ro by default (ADR-0049 reverses P17)"
        return 1
    fi
    if grep -qE ':/workspace/\.claude"$' "$compose"; then
        echo "ASSERTION FAILED: /workspace/.claude must not be rw by default"
        return 1
    fi
    # An explicit --claude-access repo re-opens B2 for authoring (Cp=rw) — and with
    # no floor to compose for, the parent goes back to the committed tree itself.
    run_cco start "test-proj" --claude-access repo --dry-run --dump
    compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    if ! grep -qE '/claude:/workspace/\.claude"$' "$compose"; then
        echo "ASSERTION FAILED: --claude-access repo must make project .claude rw"
        return 1
    fi
    return 0
}

# ── Invariant 3: Auto Memory Path ────────────────────────────────────
# Claude state (memory + transcripts) is mounted as .cco/claude-state/ on the host.
# Since ADR-0055 D5 the bucket is the whole ~/.claude/projects TREE; the auto-memory
# child still lands at the -workspace key (WORKDIR /workspace with the root slash
# replaced by a dash, per Claude Code's cwd-keying convention).

test_invariant_3_auto_memory_exact_container_path() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_contains "$compose" "/home/claude/.claude/projects/-workspace/memory\""
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

# ── INV-TTY single interactivity spelling (test-runner capture-hang class) ──
# Every interactive prompt gate must go through _cco_have_tty() (lib/utils.sh) —
# the SINGLE place that probes /dev/tty AND honours CCO_NONINTERACTIVE. The raw
# `(exec < /dev/tty)` reachability probe is banned everywhere else: a gate spelled
# inline cannot be forced non-interactive, so when a caller CAPTURES the command's
# output (`out=$(cmd 2>&1)` — the test runner's _run_test, the nested $() in
# run_cco, any script wrapper) the prompt text is swallowed while the read blocks
# on the terminal: a silent, unattributable hang. It bites ONLY from a real
# terminal — CI/Docker have no controlling tty, so every prompt already takes its
# non-interactive branch and the suite is green — which is why `cco init`'s
# repo-name prompt froze the suite undetected for so long. utils.sh is the probe's
# one legitimate home (the helper body); a deliberate exception elsewhere carries a
# same-line `# allow-raw-tty: <why>` marker. (`[[ -t 0 ]]` is left to convention —
# it has legitimate non-prompt uses (piped-stdin detection) a static ban would
# false-positive; the codebase carries none as a prompt gate today.)
test_invariant_tty_gate_single_spelling() {
    # 1. Live tree: no raw probe outside the helper. migrations/ is scanned too —
    #    a migration runs under `cco update` with the libs sourced, so it must reach
    #    for _cco_have_tty like everything else (010_tutorial_to_internal.sh hid one
    #    raw probe here, latent-hanging the suite the moment it ran from a terminal).
    local hits
    hits=$(grep -rnE 'exec[[:space:]]*<[[:space:]]*/dev/tty' \
             "$REPO_ROOT/lib" "$REPO_ROOT/bin" "$REPO_ROOT/migrations" \
             | grep -vE '/utils\.sh:' | grep -v 'allow-raw-tty:' || true)
    [[ -z "$hits" ]] || fail "INV-TTY: raw '(exec < /dev/tty)' interactivity probe outside _cco_have_tty — route the gate through _cco_have_tty so CCO_NONINTERACTIVE can force it off (test-runner capture-hang class):"$'\n'"$hits"

    # 2. Discrimination (a static invariant cannot "fail on reverted lib/", so it
    #    must PROVE it catches the shape it forbids). Plant the raw probe in a
    #    throwaway lib/ and assert the same grep flags it.
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    mkdir -p "$tmp/lib"
    printf '%s\n' '_probe() { if (exec < /dev/tty) 2>/dev/null; then read -r x; fi; }' > "$tmp/lib/cmd-fake.sh"
    local planted
    planted=$(grep -rnE 'exec[[:space:]]*<[[:space:]]*/dev/tty' "$tmp/lib" \
                | grep -vE '/utils\.sh:' | grep -v 'allow-raw-tty:' || true)
    [[ -n "$planted" ]] \
        || { fail "INV-TTY lint does NOT discriminate: a planted raw /dev/tty probe went uncaught"; return 1; }
    return 0
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
# DELIBERATELY NOT in `deny`: cmd-resolve.sh (RC-2 / 04 §6.7). It is the only
# module that may call _resolve_unit_dir_for_project, for three shapes a static
# lint cannot cheaply distinguish: (1) it DEFINES the resolver and the host/operator
# dispatcher _resolve_project_yml/_resolve_project_cco_dir, whose HOST branch (after
# `_cco_container_operator` returns) is the correct place for it; (2) the operator
# arm of _project_iter_members guards its host `while`; (3) the bodies of the
# HOST-ONLY verb `cco resolve` (_resolve_all, cmd_resolve) which is refused in
# operator mode anyway. A robust asserted operator-branch-shape exemption over these
# six heterogeneous sites needs control-flow analysis and is too brittle for a lint;
# it is tracked as cycle-2 in pre-revalidation-backlog.md rather than left silent.
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

# ── INV-S6 the CLASS guard (RC-3 / 05-store-write-path.md §6.5) ───────
# No code OUTSIDE the primitive layers may mutate an ADR-0047-confined bucket (DATA
# registries, STATE index sidecars, CACHE llms) or evaluate an existence predicate on
# one. Behind the opaque boundary every `[[ -f/-d ]]` on a confined path reads FALSE
# for something that exists (§1.3), so a command body that `rm`/`mv`s a bucket path,
# or branches on `[[ -d ]]` of one, silently half-applies or reports the wrong reason.
# The destructive/re-key cascades therefore go through lib/store.sh; this static guard
# keeps them there.
#
# MECHANISM — assignment provenance, not a naive grep. A `grep _cco_data_dir` on the
# PRE-FIX tree measured 9 hits of which only 4 were real (design §6.5): it flags
# resolver warm-ups and comments, and — fatally — MISSES every site that resolves the
# bucket into a local variable first (`data_root=$(_cco_state_dir); mv "$data_root/…"`,
# the `local rf; rf=$(_remotes_file)` split idiom, `$llms_dir`). A guard blind to the
# majority of its class certifies. Instead, per file, an awk pass:
#   1. taints every variable whose RHS names a confined-bucket resolver or an
#      already-tainted variable — including the `local x; x=$(…)` split form;
#   2. flags any FS-mutating statement (rm/mv/mkdir/cp/mktemp, or a `>`/`>>` redirect
#      to a non-/dev/null target) [KIND=MUT] OR existence predicate ([[ -f/-d/-e/-r/-w
#      … ]]) [KIND=PRED] whose target expands a tainted variable or calls a resolver
#      directly. The PRED half is what enforces INV-S6 — a mutation-only lint cannot
#      see §1.3 at all.
#
# TRACKED confined resolvers (the destructive/re-key + registry/token buckets):
#   _cco_data_dir _cco_state_dir _cco_cache_dir _cco_llms_dir _cco_remotes_file
#   _cco_remotes_token_file  + the thin wrappers _remotes_file / _remotes_token_file.
# NOT tracked, deliberately: the install/update PROVENANCE resolvers (_cco_pack_meta,
# _cco_template_base_dir, …) and the CONFIG globals (PACKS_DIR/TEMPLATES_DIR — plain rw
# binds, not confined). Provenance conversion is cycle 2 (D-M8/Q-10); cycle 1 gives
# those verbs a fail-fast _store_provenance_guard instead, so they never reach the
# store behind the boundary at all.
#
# EXCLUSIONS + ALLOWLIST (each with its reason). Post-fix, the ONLY surviving hits are:
#   EXCLUDED (the primitive/boundary layers themselves; skipped entirely):
#     store.sh     — the crossing primitive (the ONE module that reaches the buckets);
#     paths.sh     — defines the resolvers;
#     index.sh     — the STATE index primitive layer (reached only elevated/host-only);
#     sync-meta.sh — the STATE merge primitive layer;
#     tags.sh      — delegates to lib/store.sh post-conversion (the tag primitive).
#   ALLOWLIST — host-only verb files (row 14: the shim REFUSES these in-container, so
#     the raw store access is host-legitimate — the boundary is never in play):
#     cmd-forget.sh cmd-clean.sh cmd-config.sh cmd-start.sh cmd-update.sh migrate.sh
#     cmd-project-rename.sh.
#   ALLOWLIST — cmd-remote.sh registry/token READ helpers + token PRIMITIVES + the
#     elevated/host verbs (by function): the destructive verbs (_cmd_remote_add/remove/
#     rename) are CONVERTED and stay scanned; only the read helpers (remote_get_url/
#     token/name_for_url, remote_list_names, remote_resolve_token_for_url), the
#     whole-verb-elevated `remote list` (_cmd_remote_list), the host-only `remote
#     set-token` (_cmd_remote_set_token), and the token-store single-writer primitives
#     (_remote_token_set/_remote_token_remove — delegated to by lib/store.sh, like
#     tags.sh) are exempt. Their claude-side reads read false behind the boundary but
#     are cosmetic (preview only) or never reached in-container.
#
# This is a STATIC invariant: unlike a reproduction it does not "fail on reverted
# lib/". Its discrimination is proven directly — the test plants a raw store mutation
# in a copy of a non-allowlisted file and asserts the guard catches it.

_store_lint_prog() {
    cat <<'AWK'
BEGIN {
  RES="_cco_data_dir|_cco_state_dir|_cco_cache_dir|_cco_llms_dir|_cco_remotes_file|_cco_remotes_token_file|_remotes_file|_remotes_token_file"
  fn="(toplevel)"
}
/^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{?[ \t]*$/ { fn=$0; sub(/\(\).*/,"",fn); for (v in seen) delete seen[v]; next }
{
  line=$0; s=line
  while (match(s, /(^|[ \t;])[A-Za-z_][A-Za-z0-9_]*=/)) {
    seg=substr(s, RSTART, RLENGTH); vn=seg; gsub(/[ \t;]/,"",vn); sub(/=$/,"",vn)
    rest=substr(s, RSTART+RLENGTH); r=rest; sub(/;.*/,"",r)
    t=0
    if (r ~ ("(" RES ")")) t=1
    else { for (v in seen) if (index(r,"$"v)||index(r,"${"v)) t=1 }
    if (t && vn!="") seen[vn]=1
    s=substr(s, RSTART+RLENGTH)
  }
  isfs=(line ~ /(^|[ \t;&|(])(rm|mv|mkdir|cp|mktemp)[ \t]/)
  isredir=(line ~ />>?[ \t]*"/ && line !~ /\/dev\/null/)
  ispred=(line ~ /\[\[[^]]*-[defrw][ \t]+/)
  if (isfs||isredir||ispred) {
    hit=0
    if (line ~ ("\\$\\(?(" RES ")")) hit=1
    for (v in seen) if (index(line,"$"v)||index(line,"${"v)) hit=1
    if (hit) { k=(isfs||isredir)?"MUT":"PRED"; print FILENAME "|" fn "|" k }
  }
}
AWK
}

# Echo the VIOLATING hits (one "<basename>|<func>|<kind>" per line) found in <libdir>,
# i.e. every hit outside the exclusion set + allowlist. Empty output = clean.
_store_lint_violations() {
    local libdir="$1" f b prog line hf fn kind
    prog=$(_store_lint_prog)
    local excluded=" store.sh paths.sh index.sh sync-meta.sh tags.sh "
    local host_only=" cmd-forget.sh cmd-clean.sh cmd-config.sh cmd-start.sh cmd-update.sh migrate.sh cmd-project-rename.sh "
    local remote_allow="|remote_get_url|remote_get_token|remote_get_name_for_url|remote_list_names|remote_resolve_token_for_url|_cmd_remote_list|_cmd_remote_set_token|_remote_token_set|_remote_token_remove|"
    for f in "$libdir"/*.sh; do
        b=$(basename "$f")
        case "$excluded"  in *" $b "*) continue ;; esac
        case "$host_only" in *" $b "*) continue ;; esac
        while IFS='|' read -r hf fn kind; do
            [[ -z "$hf" ]] && continue
            if [[ "$b" == "cmd-remote.sh" && "$remote_allow" == *"|$fn|"* ]]; then continue; fi
            printf '%s|%s|%s\n' "$b" "$fn" "$kind"
        done < <(awk "$prog" "$f")
    done
}

test_invariant_no_direct_store_access_outside_primitives() {
    # 1. The live tree must be clean: every confined-bucket mutation/predicate outside
    #    the primitive layers is either in store.sh (excluded) or a documented
    #    host-only/read-helper allowlist entry.
    local v; v=$(_store_lint_violations "$REPO_ROOT/lib")
    [[ -z "$v" ]] || fail "INV-S6: raw ADR-0047-confined store access (rm/mv/redirect [MUT] or existence predicate [PRED]) outside the primitive layers — route it through lib/store.sh:"$'\n'"$v"

    # 2. Discrimination (the lint must PROVE it catches a violation, since a static
    #    invariant cannot "fail on reverted lib/"). Plant a raw store mutation in a
    #    copy of a NON-allowlisted file and assert the guard flags it.
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    cp "$REPO_ROOT"/lib/*.sh "$tmp/" 2>/dev/null || { fail "lint self-test: could not stage lib/"; return 1; }
    printf '\n_lint_probe_violation() {\n    local d; d=$(_cco_data_dir)\n    rm -rf "$d/packs/evil"\n}\n' >> "$tmp/cmd-pack.sh"
    local planted; planted=$(_store_lint_violations "$tmp")
    [[ -n "$planted" ]] \
        || { fail "INV-S6 lint does NOT discriminate: a planted raw store mutation went uncaught (RC-17 §6.5)"; return 1; }
    [[ "$planted" == *"cmd-pack.sh|_lint_probe_violation|MUT"* ]] \
        || { fail "INV-S6 lint mis-attributed the planted violation: $planted"; return 1; }
    return 0
}

# ── INV-STATE the STATE allow-list (v3 R1 / fix-design-v3/00-plan.md §2) ──
# STATE crosses the ADR-0047 boundary on an explicit ALLOW-LIST: only the shareable
# `shared/` sub-bucket (rw, a DIRECTORY bind) and the `running/` registry (ro). The
# complement is load-bearing and must never be bound — `remotes-token` is 0600 auth,
# and `projects/<id>/session/` holds transcripts and memory. This is a fail-SAFE
# posture: a file added under STATE later is unmounted unless someone moves it into
# shared/ deliberately. Widening the bind to the STATE root (the "one-line fix" two
# v3 sessions proposed) would silently flip it to fail-OPEN, which is exactly what
# this guard exists to prevent.
#
# It also pins the SHAPE: the index must not go back to being bound as a single
# FILE. That was v3 R1 — a file bind gives index writers no writable parent for
# their `mktemp "$f.XXXXXX"` sibling, and `mv` onto a bound file is EBUSY, so
# in-container index writes failed while the verb still reported success.
test_invariant_state_mount_allowlist() {
    local f="$REPO_ROOT/lib/cmd-start.sh"
    [[ -f "$f" ]] || { fail "INV-STATE: lib/cmd-start.sh not found"; return 1; }
    # Every _compose_vol whose TARGET is under the boundary's state/ tree. Scoped to
    # real _compose_vol call lines: the CCO_STATE_HOME env line and the block comments
    # also name that path and are not mounts.
    local targets
    targets=$(grep -E '_compose_vol' "$f" | grep -vE '^[[:space:]]*#' \
        | grep -oE '/var/lib/cco-internal/state/[A-Za-z0-9_./-]*' | sort -u)
    [[ -n "$targets" ]] || { fail "INV-STATE: no STATE mount targets found — did the mount move?"; return 1; }
    local t bad=""
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        case "$t" in
            /var/lib/cco-internal/state/cco/shared|/var/lib/cco-internal/state/cco/running) ;;
            *) bad="${bad}${t}"$'\n' ;;
        esac
    done <<< "$targets"
    [[ -z "$bad" ]] || fail "INV-STATE: STATE mount target outside the allow-list {shared, running} — remotes-token, transcripts and memory must never cross (v3 R1):"$'\n'"$bad"

    # The index must be reached through the shared sub-bucket, never bound directly.
    if grep -qE '_compose_vol[^#]*state/cco/index' "$f"; then
        fail "INV-STATE: the index is bound as a FILE again — bind the shared/ DIRECTORY (v3 R1: mktemp sibling needs a writable parent; mv onto a mountpoint is EBUSY)"
    fi
    # And the resolver must agree that the index lives in the shared bucket.
    grep -qE '_cco_state_shared_dir' "$REPO_ROOT/lib/index.sh" \
        || fail "INV-STATE: lib/index.sh no longer resolves the index under STATE/shared"
}

# ── INV-IDX index writes are status-checked where errexit cannot help (v3 R2) ──
# bin/cco dispatches every command body in a `|| _cco_rc=$?` context (to capture the
# rc), and that DISABLES errexit for the entire call tree. So a failing index write
# does not abort the verb: `cco repo rename` printed `✓` over three EACCES writes and
# left project.yml re-keyed against an unchanged index (v3 V3-01). Explicit status
# propagation is therefore the only available mechanism, and it has to be enforced.
#
# Scope: EVERY module that writes the index from a command body. It started at the
# container-reachable ones (`cmd-repo.sh` + its `rename.sh` helpers) with the
# host-only writers recorded as follow-up; S2b closed them in two waves — `cmd-join.sh`
# / `cmd-init.sh` first (their damage escapes the machine: init prints "registered it
# in the index (1 repo)", a sentence asserting the very write that failed; join tells
# the user to commit and push a project.yml declaring a member no index binds), then
# the remaining five. The exemption paragraph this header used to carry is GONE,
# which was the point of growing the list rather than documenting it (§3b item 4).
#
# `lib/index.sh` is deliberately NOT in the list, and this is not a leftover. It is
# the writer layer itself, where a call in TAIL position IS the propagation —
# `_index_set_path() { _index_pp_set "$1" "$2" "$3"; }` is correct precisely because
# the status becomes the function's return. This lint's form (bare call = violation)
# cannot tell that apart from a discarded status, so applying it there would demand
# noise that changes nothing. Its internal cascades — `_index_rename_path` and
# `_index_rename_project`, the two that chain several sub-writes and can therefore
# half-apply — carry explicit `|| return 1` and behavioural guards instead.
#
# Form: a bare call — the writer is the first token of the STATEMENT and the
# statement carries no `||`/`&&` — is a violation. `if ! _index_… ; then` does not
# match, because there the writer is not the first token. Backslash continuations
# are joined before the check, so the idiomatic
#     _index_set_path … \
#         || die "…"
# is correctly read as checked (a line-oriented grep flags it as bare — that false
# positive is why this joins first).
# Join backslash-continued lines so a statement is one record. Line numbers stay
# those of the statement's FIRST line, which is what a reader needs.
_idx_join_continuations() {
    awk '{
        if (buf != "") { sub(/^[[:space:]]+/, " "); buf = buf $0 }
        else { buf = $0; ln = NR }
        if (buf ~ /\\$/) { sub(/\\$/, "", buf); next }
        print ln ":" buf; buf = ""
    } END { if (buf != "") print ln ":" buf }' "$1"
}

test_invariant_index_writes_status_checked() {
    local scoped="cmd-repo.sh rename.sh cmd-join.sh cmd-init.sh cmd-forget.sh
                  cmd-project-add.sh cmd-project-export-import.sh cmd-resolve.sh
                  local-paths.sh migrate.sh"
    local writers='_index_(rename_path|set_path|set_project_repos|pp_set|pp_remove|set_unscoped|remove_path|remove_project|ensure_file)'
    local m f hits=""
    for m in $scoped; do
        f="$REPO_ROOT/lib/$m"
        [[ -f "$f" ]] || continue
        local h
        # Records are "<line>:<joined statement>"; the writer must be the first token.
        h=$(_idx_join_continuations "$f" | grep -E "^[0-9]+:[[:space:]]*${writers}\b" | grep -vE '\|\||&&' || true)
        [[ -n "$h" ]] && hits="${hits}${m}: ${h}"$'\n'
    done
    [[ -z "$hits" ]] || fail "INV-IDX: unchecked index write in a module this guard covers — errexit is disabled by bin/cco's \`|| _cco_rc=\$?\` dispatch, so the failure would be silent (v3 R2):"$'\n'"$hits"

    # Discrimination: a static guard must prove it catches the shape it forbids.
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    cp "$REPO_ROOT/lib/cmd-repo.sh" "$tmp/" || { fail "INV-IDX self-test: could not stage cmd-repo.sh"; return 1; }
    printf '\n_lint_probe_unchecked() {\n    _index_rename_path "$p" "$o" "$n"\n}\n' >> "$tmp/cmd-repo.sh"
    local planted
    planted=$(_idx_join_continuations "$tmp/cmd-repo.sh" | grep -E "^[0-9]+:[[:space:]]*${writers}\b" | grep -vE '\|\||&&' || true)
    [[ -n "$planted" ]] \
        || { fail "INV-IDX does NOT discriminate: a planted bare index write went uncaught"; return 1; }
    return 0
}

# ── INV-ENV one predicate, one spelling: the availability vocabulary (v3 R4) ──
# "Is this NAMED RESOURCE here / not-mounted / unresolved / out-of-scope?" is ONE
# predicate, and lib/access-scope.sh owns both its answer (_env_project_state /
# _env_member_state) and its wording (_env_unavailable / _env_unavailable_warn /
# _env_unavailable_sentence / _env_require_visible). A verb that spells a state
# itself drifts from the shared one, and drift is invisible until a live session
# puts the two sentences side by side.
#
# That is exactly what happened: `cco project show` answered with one hardcoded
# sentence blaming ACCESS SCOPE and prescribing a scope widening — false whenever
# nothing was hidden (at edit-all there is no widening left) and identical for two
# different realities, while its sibling `cco project validate` gave the correct
# D-M2 answer in the same session. Three v3 sessions reported it from three
# vantages (V2-F04 ≡ V4-F-V4-02 ≡ V5-04) against one call site. This is the class
# RC-4 was created to eliminate ("one predicate, four spellings, one of which
# drifted"), recurred — so it gets a guard rather than another fix.
#
# Form: the four state fragments below are the vocabulary. Outside access-scope.sh
# they may appear only in a module on `ratified`, and only up to its budget.
# Comment lines are exempt (docs quote the vocabulary on purpose).
#
# Each ratified module owns a DIFFERENT predicate, spelled in exactly one function
# — that is why it is not a violation of "one predicate, one spelling":
#   store.sh   1  _store_unwritable_refuse   — a STORE BUCKET's writability, not a
#                                              named resource (a bucket is never
#                                              "unresolved"). Governed by INV-S3b.
#   rename.sh  1  _rename_assert_index_writable — same bucket predicate, pre-flight.
#   cmd-start.sh 2 _ce_skip_note             — config-editor's mount-drop predicate,
#                                              HOST side (cco start never runs in a
#                                              session); deliberately worded to the
#                                              same D-M2 vocabulary (its own comment
#                                              pins that), reasons ∈ unresolved|stale|
#                                              homonym|reserved|noconfig|reference.
#                                              S7 added the last two and a <kind> noun
#                                              WITHOUT a third spelling: arms carry the
#                                              detail, the single warn carries the state.
#   cmd-resolve.sh 0 — RETIRED by ADR-0056 D3 (S4). It held one spelling because
#                      `cco path list`'s notice "must say read-all where the shared
#                      notice says read-global", with the note "reconciling the
#                      shared one is V4-F-V4-03 / Q-C3". That reconciliation landed:
#                      _env_widening_clause now derives the widening from WHAT IS
#                      HIDDEN, and a `path` row rides Po exactly as a project does,
#                      so the site routes through _env_note_hidden + the shared
#                      flush and spells nothing. The entry is REMOVED rather than
#                      left at 1 — a budget nobody spends is an invitation.
#   cmd-project-rename.sh 1 cmd_project_rename — an AGGREGATE over member repos
#                                              (a plural list), not a single
#                                              resource's state; host-only verb.
#
# The budget is a CEILING, so deleting a spelling never fails the guard and adding
# one always does. Raising a budget is a deliberate act that has to be argued here.
test_invariant_env_one_spelling_per_state() {
    local vocab='not available at this access scope|not mounted in this session|not resolved on this machine|hidden by access scope'
    local ratified="store.sh:1 rename.sh:1 cmd-start.sh:2 cmd-project-rename.sh:1"
    local f base budget n hits=""
    for f in "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/bin/cco; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f")
        [[ "$base" == access-scope.sh ]] && continue          # the owner
        n=$(grep -nE "$vocab" "$f" | grep -cvE '^[0-9]+:[[:space:]]*#' || true)
        [[ "$n" -eq 0 ]] && continue
        budget=0
        case " $ratified " in *" $base:"*) budget=${ratified##*"$base":}; budget=${budget%% *} ;; esac
        if [[ "$n" -gt "$budget" ]]; then
            hits="${hits}${base}: $n spelling(s), budget $budget"$'\n'
            hits="${hits}$(grep -nE "$vocab" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | cut -c1-100)"$'\n'
        fi
    done
    [[ -z "$hits" ]] || fail "INV-ENV: an availability state is spelled outside lib/access-scope.sh — ask _env_project_state/_env_member_state and render with _env_unavailable[_warn] (v3 R4):"$'\n'"$hits"

    # Discrimination arm 1: a NEW spelling in an unlisted module must be caught.
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    printf 'f() {\n    refuse "Project %s is not available at this access scope."\n}\n' "'\$n'" > "$tmp/cmd-unlisted.sh"
    n=$(grep -nE "$vocab" "$tmp/cmd-unlisted.sh" | grep -cvE '^[0-9]+:[[:space:]]*#' || true)
    [[ "$n" -gt 0 ]] \
        || { fail "INV-ENV does NOT discriminate: a planted local state spelling went uncaught"; return 1; }

    # Discrimination arm 2: a comment quoting the vocabulary must NOT be caught —
    # otherwise the guard would push authors to stop documenting it.
    printf '# a doc line about "not mounted in this session"\n' > "$tmp/cmd-comment.sh"
    n=$(grep -nE "$vocab" "$tmp/cmd-comment.sh" | grep -cvE '^[0-9]+:[[:space:]]*#' || true)
    [[ "$n" -eq 0 ]] \
        || { fail "INV-ENV over-reaches: a comment quoting the vocabulary was flagged"; return 1; }

    # Discrimination arm 3: the budget must bite — a SECOND spelling in a ratified
    # module (here store.sh, budget 1) is a violation even though the module is listed.
    cp "$REPO_ROOT/lib/store.sh" "$tmp/" || { fail "INV-ENV self-test: could not stage store.sh"; return 1; }
    printf '\n_lint_probe_extra() {\n    refuse "the bucket is not mounted in this session"\n}\n' >> "$tmp/store.sh"
    n=$(grep -nE "$vocab" "$tmp/store.sh" | grep -cvE '^[0-9]+:[[:space:]]*#' || true)
    [[ "$n" -gt 1 ]] \
        || { fail "INV-ENV budget does NOT bite: a second spelling in a ratified module went uncaught"; return 1; }
    return 0
}

# ── INV-LOCAL: no self-reference inside a single `local` statement ────
# `local a="$1" b="$a/x"` does not do what it reads like. `local` is a BUILTIN, so
# every one of its arguments is expanded BEFORE any assignment happens: `$a` there
# resolves to the CALLER's `a` (bash is dynamically scoped), or aborts as unbound
# under `set -u`. Both failure modes are silent-until-they-are-not — the shipped
# instance (ADR-0054's mountpoint stub) was accidentally correct on one call path,
# because a caller happened to hold identically-named variables, and a silent no-op
# on another: `cco start` then died in runc on a mountpoint that was never created.
# Split the statement; the shape is unreviewable, not merely fragile.
_local_selfref_prog() {
    cat <<'AWK'
/^[[:space:]]*local[[:space:]]/ {
  line = $0
  sub(/^[[:space:]]*local[[:space:]]+/, "", line)
  sub(/;.*$/, "", line)          # after a `;` it is a NEW command — assignments have landed
  n = split(line, parts, /[[:space:]]+/)
  delete declared; out = ""
  for (i = 1; i <= n; i++) {
    p = parts[i]; eq = index(p, "=")
    if (eq == 0) { name = p; rhs = "" } else { name = substr(p, 1, eq - 1); rhs = substr(p, eq + 1) }
    if (name !~ /^[A-Za-z_][A-Za-z0-9_]*$/) continue
    for (d in declared)
      if (index(rhs, "$" d) > 0 || index(rhs, "${" d) > 0) out = out " " d
    declared[name] = 1
  }
  if (out != "") print FILENAME ":" FNR ": [self-ref:" out " ]  local " substr(line, 1, 90)
}
AWK
}

_local_selfref_violations() {
    local prog; prog=$(_local_selfref_prog)
    local f; local -a files=()
    while IFS= read -r f; do files+=("$f"); done < <(
        find "$@" -type f \( -name '*.sh' -o -name 'cco' \) 2>/dev/null | sort)
    [[ ${#files[@]} -gt 0 ]] || return 0
    awk "$prog" "${files[@]}" 2>/dev/null || true
}

test_invariant_no_local_self_reference() {
    # 1. The live tree must be clean.
    local hits
    hits=$(_local_selfref_violations "$REPO_ROOT/lib" "$REPO_ROOT/bin" \
                                     "$REPO_ROOT/migrations" "$REPO_ROOT/config")
    [[ -z "$hits" ]] || fail "INV-LOCAL: a \`local\` statement references a name it declares in the SAME statement — the RHS is expanded before the assignment, so it reads the CALLER's variable (or dies under set -u). Split it into two statements:"$'\n'"$hits"

    # 2. Discrimination: a static invariant cannot "fail on reverted lib/", so it
    #    must prove it catches the shape it forbids.
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    mkdir -p "$tmp/lib"
    cat > "$tmp/lib/cmd-fake.sh" <<'PLANT'
_f() {
    local a="$1" b="$a/x"
    echo "$b"
}
_g() {
    local a="$1"
    local b="$a/x"
    echo "$b"
}
PLANT
    local planted; planted=$(_local_selfref_violations "$tmp/lib")
    [[ -n "$planted" ]] \
        || { fail "INV-LOCAL lint does NOT discriminate: a planted self-reference went uncaught"; return 1; }
    # ...and must not flag the CORRECT two-statement form on the very next line.
    [[ "$(printf '%s\n' "$planted" | wc -l | tr -d ' ')" == "1" ]] \
        || fail "INV-LOCAL lint over-reports: the split form is legal, got:"$'\n'"$planted"
    return 0
}

# ── INV-MP: mountpoint ancestry, container side (ADR-0055 D4 — R-D) ───────────
# For every bind cco generates, every ancestor of the target that the container
# runtime would otherwise have to materialise must already exist, owned by the
# writer. An ancestor the runtime creates is root:root — harmless when something
# is mounted ON it (the bind hides it), fatal when it is only passed THROUGH:
# `claude` can traverse it and create nothing beside the bind. That is R-D.
# ~/.claude/projects was exactly such a pass-through ancestor, so every per-cwd
# session key other than the bound -workspace failed with EACCES *at runtime* —
# a broken feature rather than a broken boot, which is why it survived three
# rounds of review.
#
# Runs against a REALLY GENERATED compose file: a fixture would only re-assert
# the fixture, and this class is invisible to the hermetic lane by construction
# (RC-17 — v3's STATE bucket, FI-31, now R-D).
#
# DIVISION OF LABOUR, stated rather than left implicit:
#   • this lint owns the IMAGE side — an ancestor outside every cco mount must be
#     pre-created in the Dockerfile, and the allowed set is PARSED from the
#     Dockerfile so the two cannot drift (the way its comment drifted from its
#     own mkdir: the rule was written down and applied to one path);
#   • an ancestor strictly INSIDE a cco mount is created host-side by cco and is
#     covered by test_start_claude_view.sh / test_start_transcripts_layout.sh,
#     which assert those directories directly.
#
# SCOPE: ancestors under /home/claude and /workspace — the trees `claude` must be
# able to write. Elsewhere (/etc, /var/run) nothing needs to create a sibling.
test_invariant_mount_ancestry_owned() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    # A pack shipping skills exercises the view lane, so the generated file carries
    # the deepest targets cco can emit.
    create_pack "$tmpdir" "s-pack" "$(printf 'name: s-pack\nskills:\n  - deploy\n')"
    mkdir -p "$CCO_PACKS_DIR/s-pack/skills/deploy"
    echo "# deploy" > "$CCO_PACKS_DIR/s-pack/skills/deploy/SKILL.md"
    create_project "$tmpdir" "test-proj" "$(printf 'name: test-proj\nrepos:\n  - name: dummy-repo\npacks:\n  - s-pack\n')"

    run_cco start "test-proj" --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    [[ -f "$compose" ]] || { fail "INV-MP: no generated compose to lint"; return 1; }

    # Pre-created in the image: tokens starting with '/' in the user-setup RUN,
    # PLUS their ancestors — the RUN is a `mkdir -p` followed by `chown -R
    # claude:claude /home/claude`, so an intermediate directory is created and
    # owned just as surely as the leaf it was created for.
    local image_dirs=$'\n' d
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        while [[ "$d" == /?* ]]; do
            [[ "$image_dirs" == *$'\n'"$d"$'\n'* ]] || image_dirs+="$d"$'\n'
            d="${d%/*}"
        done
    done <<< "$(sed -n '/^RUN groupadd/,/chown -R claude/p' "$REPO_ROOT/Dockerfile" \
        | tr ' \t\\' '\n\n\n' | grep '^/' | sed 's:/*$::' | sort -u)"
    [[ "$image_dirs" == *"/home/claude/.claude"* ]] \
        || { fail "INV-MP: cannot parse the image's pre-created dirs from the Dockerfile"; return 1; }

    # Every bind TARGET. Peel an optional :ro|:rw, then take the last ':' field —
    # a container target never contains ':'. Port lines parse to a non-'/' value
    # and fall out at the scope check below.
    local line raw targets=$'\n'
    while IFS= read -r line; do
        case "$line" in *' - "'*) ;; *) continue ;; esac
        raw="${line#*\"}"; raw="${raw%\"*}"
        case "$raw" in *:ro|*:rw) raw="${raw%:*}" ;; esac
        targets+="${raw##*:}"$'\n'
    done < "$compose"
    [[ "$targets" == *"/home/claude/.claude"* ]] \
        || { fail "INV-MP: no /home/claude targets in the generated compose — did the mounts move?"; return 1; }

    local t p bad=""
    while IFS= read -r t; do
        case "$t" in /home/claude/*|/workspace/*) ;; *) continue ;; esac
        p="${t%/*}"
        while [[ -n "$p" && "$p" != "/" ]]; do
            # A tree root the image owns outright (chown -R) — stop here.
            case "$p" in /home/claude|/workspace) break ;; esac
            # Itself a mount target: the bind lands on top, ownership unobservable.
            # Its own ancestors are checked when the outer loop reaches it.
            [[ "$targets"    == *$'\n'"$p"$'\n'* ]] && break
            # Pre-created in the image, claude-owned by the RUN's chown -R.
            [[ "$image_dirs" == *$'\n'"$p"$'\n'* ]] && break
            # Strictly inside a cco mount → cco creates it host-side (see above).
            local m inside="" ; while IFS= read -r m; do
                [[ -n "$m" ]] || continue
                case "$p" in "$m"/*) inside=yes; break ;; esac
            done <<< "$targets"
            [[ -n "$inside" ]] && break
            bad="${bad}  ${p}   (ancestor of ${t})"$'\n'
            break
        done
    done <<< "$targets"

    [[ -z "$bad" ]] || fail "INV-MP: mountpoint ancestor left for the container runtime to create — it will be root-owned and \`claude\` will not be able to write beside the bind (R-D). Pre-create it in the Dockerfile beside the other XDG base dirs:"$'\n'"$bad"
}

# The other half of INV-MP D4, which the ancestry lint cannot reach: an ancestor
# that is itself a mount target is exempt by construction, so removing
# `/home/claude/.claude/projects` from the Dockerfile is invisible to it (verified —
# the lint still passes). That entry is what stands between a future lane binding a
# single key again and R-D, so its presence is asserted directly against the set the
# comment above it documents.
test_invariant_mount_ancestry_image_set() {
    local f="$REPO_ROOT/Dockerfile"
    [[ -f "$f" ]] || { fail "INV-MP: Dockerfile not found"; return 1; }
    local block; block=$(sed -n '/^RUN groupadd/,/chown -R claude/p' "$f")
    [[ -n "$block" ]] || { fail "INV-MP: cannot find the user-setup RUN block"; return 1; }
    local d missing=""
    for d in /home/claude/.claude /home/claude/.claude/projects /home/claude/.cco/packs \
             /home/claude/.local/bin /home/claude/.local/share /home/claude/.local/state \
             /home/claude/.cache; do
        case "$block" in *"$d"*) ;; *) missing="${missing}  ${d}"$'\n' ;; esac
    done
    [[ -z "$missing" ]] || fail "INV-MP: the image no longer pre-creates a documented mountpoint ancestor. An ancestor that is currently a mount target is EXEMPT from the ancestry lint, so dropping it here fails nothing until a lane stops binding it — which is how R-D shipped:"$'\n'"$missing"
}

# ── INV-YAML the section-boundary CLASS guard (R-E / runbook §6.1) ────
#
# THE INVARIANT — one spelling of "where does a YAML section end", comment-block
# aware: buffer the trailing run of top-level comment and blank lines; on the next
# top-level key, emit before the buffered run, then flush. The sanctioned spelling
# is `_yml_append_coord` in lib/cmd-project-add.sh, reached by all four verbs that
# add a coordinate (`cco project add {repo,mount,llms,pack}`, `cco init`,
# `cco join`). Behavioural coverage: the golden-file round trip in
# tests/test_project_add.sh.
#
# THE CLASS this lint guards — INSERTION, not parsing. The comment-blind idiom
# `/^[^ #]/` appears ~40 times across lib/, and in the overwhelming majority it is
# a READER (`{ exit }`, `{ in_sec = 0 }`, a parse into a stream). For a reader the
# distinction is unobservable: a top-level comment run contains no `  - name:`
# entry lines, so treating it as inside the section reads exactly the same set.
# The defect only exists where the boundary decides WHERE NEW CONTENT IS EMITTED —
# there, comment-blindness silently relocates a user's entry into someone else's
# section. A lint over every reader would be ~40 lines of noise on day one, and a
# lint that is noise gets silenced rather than heeded.
#
# ALLOWLIST — files where an insertion at the boundary is present and correct,
# with the reason recorded (a bare file name is not a justification):
#   lib/cmd-project-add.sh — DEFINES the sanctioned spelling.
#   lib/index.sh           — the STATE index: a GENERATED file with no comments,
#                            so the trailing run is always empty. (Named in the
#                            runbook as the reason this lands as one-spelling-
#                            plus-a-lint rather than a local patch: the idiom was
#                            already spreading.)
#   lib/tags.sh            — the DATA tags registry: same reason, generated and
#                            never hand-edited (CLAUDE.md, "Framework state").
#
# ⚠ lib/migrate.sh WAS allowlisted here by S5, and the entry is GONE (S6). It was
# never an exemption on the merits: S5 recorded it as "NOT clean" because the llms
# url-recovery rewriter destroyed comments outright, a different defect from the
# misplacement this invariant names, out of that session's scope. S6 fixed the
# rewriter — it now injects into a verbatim pass-through under this very
# buffer-and-flush rule — so the entry stopped being earned and the file is
# scanned like any other. Its two legacy PARSERS (_migrate_legacy_repos /
# _migrate_legacy_mounts) spell the boundary `/^[^ ]/` with an explicit `/^#/`
# skip in front, which is behaviourally identical to what they had and keeps the
# insertion-class idiom out of a file the lint reads.
test_invariant_yaml_section_end_one_spelling() {
    local allow=" cmd-project-add.sh index.sh tags.sh "
    # An awk rule that (a) tests the top-level section-end idiom, (b) EMITS in its
    # action (`print <something>` — not a bare `print`/`print $0`, which re-emits
    # the boundary line itself — or a flush() of buffered content), and (c) does
    # NOT `exit` there. (c) is what separates a rewriter from a parser: a rewriter
    # must copy the rest of the file, so it never terminates the scan at the
    # boundary; a parser that has found its answer does (session-context.sh:120).
    local prog='
/\/\^\[\^ #\]\// {
  act = $0
  sub(/.*\/\^\[\^ #\]\//, "", act)
  if (act ~ /(^|[^a-zA-Z_])exit([^a-zA-Z_]|$)/) next
  if (act ~ /print[ \t]+[^ \t;}]/ || act ~ /flush\(\)/) print FILENAME ":" FNR ": " $0
}'
    local f base hits="" h
    for f in "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/bin/cco "$REPO_ROOT"/migrations/*/*.sh; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f")
        case "$allow" in *" $base "*) continue ;; esac
        h=$(awk "$prog" "$f")
        [[ -n "$h" ]] && hits="${hits}${h}"$'\n'
    done
    [[ -z "$hits" ]] || { fail "INV-YAML: a second INSERTION-class implementation of the YAML section-end idiom. A top-level comment block belongs to the NEXT key by YAML convention, so a \`/^[^ #]/\` boundary slides the insertion past it and into the following section (R-E). Route the insert through _yml_append_coord (lib/cmd-project-add.sh), or extend the allowlist here WITH ITS REASON:"$'\n'"$hits"; return 1; }

    # Discrimination — a static lint that cannot fail is indistinguishable from an
    # inert one. Plant the forbidden shape in a throwaway lib/ and assert it fires.
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    mkdir -p "$tmp/lib"
    cat > "$tmp/lib/cmd-fake.sh" <<'PLANT'
_fake_append() {
    awk -v sec="$1" '
        $0 == sec":" { in_sec=1; print; next }
        in_sec && /^[^ #]/ { if (!ins) { print ENVIRON["BLK"]; ins=1 } in_sec=0; print; next }
        { print }
    ' "$2"
}
PLANT
    local planted; planted=$(awk "$prog" "$tmp/lib/cmd-fake.sh")
    [[ -n "$planted" ]] \
        || { fail "INV-YAML lint does NOT discriminate: a planted comment-blind insertion went uncaught"; return 1; }
    # …and does NOT fire on a pure READER, which is outside the class.
    cat > "$tmp/lib/cmd-reader.sh" <<'PLANT'
_fake_read() {
    awk -v sec="$1" '
        $0 == sec":" { in_sec=1; next }
        in_sec && /^[^ #]/ { exit }
        in_sec && /^  - name:/ { print; next }
    ' "$2"
}
PLANT
    local reader; reader=$(awk "$prog" "$tmp/lib/cmd-reader.sh")
    [[ -z "$reader" ]] \
        || { fail "INV-YAML lint over-fires: a pure reader (no emission at the boundary) was flagged:"$'\n'"$reader"; return 1; }
    return 0
}

# ── INV-EXIT the sentinel discipline (R-G / runbook §6.2) ─────────────
#
# THE INVARIANT — bin/cco's EXIT trap prints "✗ cco exited unexpectedly (exit N)"
# unless `_cco_completed` is true. Only lib/colors.sh's three exit primitives
# (die 1 · refuse 2 · _cco_exit N) set it, so a raw shell `exit` anywhere else —
# or an `|| exit $?` propagating a status out of a SUBSHELL die, whose assignment
# died with the subshell — leaves it false and glues an ✗ onto a perfectly correct
# run. Both shipped: the group-help paths of `cco project` / `cco pack` printed it
# on exit 0, and a mistyped --cco-access printed it after a well-formed INV-2
# refusal on the host. Behavioural coverage: the two arm tests below.
#
# MECHANISM — only SHELL exits count; the ~70 `exit` tokens in lib/ are almost all
# awk program text (`{ print; exit }`), which terminates awk, not cco. Quoted
# regions, comments and heredoc bodies are therefore removed before matching. Four
# hazards are handled explicitly, each of which produced a false positive while
# this was being written: the close-literal-reopen quote token (4 chars, in
# lib/llms.sh and lib/paths.sh) must not invert the single-quote state; an
# apostrophe in a prose comment must not either; a heredoc body is DATA (`cco
# update --help` prints the literal text "(… exit 0)"); and a heredoc delimiter is
# usually quoted, so its opener is matched on the raw line. The quote character
# arrives via -v because an awk "\x27" escape is a gawk extension that would
# silently not fire on the macOS/BSD awk this project targets. migrations/ is
# scanned: a migration runs under `cco update` with the libs sourced, so its
# `exit` is cco's exit — the same reason INV-TTY scans it.
#
# ALLOWLIST (by file, with the reason — a raw exit is legal only where it does NOT
# terminate the cco process):
#   lib/colors.sh   — DEFINES die / refuse / _cco_exit, the three primitives.
#   lib/cmd-init.sh — `cd "$gclaude" || exit 1` inside an explicit ( … ) subshell:
#                     it exits the subshell, and a cd that fails there IS an
#                     undiagnosed crash — the trap firing is correct.
_inv_exit_shell_exits() {
    # Emits "<file>:<line>: <text>" for every `exit` reached in SHELL context.
    awk -v q="'" '
      BEGIN { inq = 0; indq = 0; inhd = 0 }
      inhd { if ($0 ~ ("^[ \t]*" hdw "[ \t]*$")) inhd = 0; next }
      {
        line = $0; out = ""; i = 1; n = length(line)
        while (i <= n) {
          c = substr(line, i, 1)
          if (inq && substr(line, i, 4) == q "\\" q q) { i += 4; continue }
          if (indq && c == "\\") { i += 2; continue }
          if (!indq && c == q)    { inq = !inq;   i++; continue }
          if (!inq  && c == "\"") { indq = !indq; i++; continue }
          if (!inq && !indq && c == "#" && (i == 1 || substr(line, i-1, 1) ~ /[ \t;&|(]/)) break
          if (!inq && !indq) out = out c
          i++
        }
        if (out ~ /(^|[;&|(){}[:space:]])exit([[:space:]]|;|$)/) print FILENAME ":" FNR ": " $0
        hl = line; gsub(/"/, "", hl); gsub(q, "", hl)
        if (match(hl, /<<-?[ \t]*[A-Za-z_][A-Za-z0-9_]*/) \
            && (RSTART == 1 || substr(hl, RSTART - 1, 1) != "<")) {
          hdw = substr(hl, RSTART, RLENGTH); sub(/^<<-?[ \t]*/, "", hdw)
          inhd = 1
        }
      }' "$1"
}

test_invariant_exit_sentinel_discipline() {
    local allow_file=" colors.sh cmd-init.sh "
    local f base hits="" h
    for f in "$REPO_ROOT"/bin/cco "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/migrations/*/*.sh; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f")
        case "$allow_file" in *" $base "*) continue ;; esac
        h=$(_inv_exit_shell_exits "$f")
        [[ -n "$h" ]] && hits="${hits}${h}"$'\n'
    done
    [[ -z "$hits" ]] || { fail "INV-EXIT: a raw shell \`exit\` outside lib/colors.sh's primitives. It leaves the EXIT-trap sentinel false, so bin/cco prints \"✗ cco exited unexpectedly\" over a deliberate exit — which is both a lie and a mask for the real crashes the trap exists to catch (R-G). Use _cco_exit <code> (or die / refuse); for an exit that is subshell-local, extend the allowlist here WITH ITS REASON:"$'\n'"$hits"; return 1; }

    # Discrimination, both directions.
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    printf '%s\n' 'cmd_x() { [[ -z "$1" ]] && { usage; exit 0; }; }'     > "$tmp/raw.sh"
    printf '%s\n' 'cmd_y() { local t; t=$(_resolve "$1") || exit $?; }'  > "$tmp/prop.sh"
    local a b c
    a=$(_inv_exit_shell_exits "$tmp/raw.sh")
    [[ -n "$a" ]] || { fail "INV-EXIT lint does NOT discriminate: a planted bare 'exit 0' (the group-help arm) went uncaught"; return 1; }
    b=$(_inv_exit_shell_exits "$tmp/prop.sh")
    [[ -n "$b" ]] || { fail "INV-EXIT lint does NOT discriminate: a planted '|| exit \$?' (the subshell-propagation arm) went uncaught"; return 1; }
    # …and does NOT fire on the shapes a naive grep would mistake for shell exits:
    # awk program text under both quotings, a prose comment, and a heredoc body.
    {
        printf '%s\n' 'f() { awk "/^x:/ { print; exit }" "$1"; }'
        printf '%s\n' "g() { awk '/^y:/ { print v; exit }' \"\$1\"; }"
        printf '%s\n' "h() { awk -F': *' '/^n:/{gsub(/[\"'\\''\"]/,\"\",\$2); print \$2; exit}' \"\$1\"; }"
        printf '%s\n' "# it doesn't matter how the caller chose to exit here"
        printf '%s\n' 'u() { cat <<EOF' '  --flag   does a thing (read-only, exit 0)' 'EOF' '}'
    } > "$tmp/awkonly.sh"
    c=$(_inv_exit_shell_exits "$tmp/awkonly.sh")
    [[ -z "$c" ]] || { fail "INV-EXIT lint over-fires: non-shell text was read as a shell exit:"$'\n'"$c"; return 1; }
    return 0
}

# ── INV-EXIT arm 1: a SUCCESSFUL run must not be reported as a crash ──
# `cco project` / `cco pack` with no subcommand print their group help and exit 0.
# Both exited without setting the sentinel, so every such run ended with
# "✗ cco exited unexpectedly (exit 0)" printed under its own help text.
test_invariant_exit_sentinel_group_help_is_not_a_crash() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    local ns rc
    for ns in project pack; do
        rc=0; run_cco "$ns" || rc=$?
        [[ $rc -eq 0 ]] || { fail "INV-EXIT: 'cco $ns' group help should exit 0, got $rc"; return 1; }
        case "$CCO_OUTPUT" in
            *"Usage: cco $ns"*) ;;
            *) fail "INV-EXIT: 'cco $ns' did not print its group help — the arm-1 assertion would be vacuous:"$'\n'"$CCO_OUTPUT"; return 1 ;;
        esac
        case "$CCO_OUTPUT" in
            *"exited unexpectedly"*)
                fail "INV-EXIT: 'cco $ns' printed the crash notice on a SUCCESSFUL exit-0 run:"$'\n'"$CCO_OUTPUT"
                return 1 ;;
        esac
    done
}

# ── INV-EXIT arm 2: a CORRECT refusal must not be reported as a crash ─
# The access resolver runs inside a command substitution, so its `die` set the
# sentinel in a SUBSHELL and the parent propagated the status with a bare
# `|| exit $?` — leaving the trap to append "✗ cco exited unexpectedly (exit 1)"
# to a well-formed refusal. This is the path a user hits by mistyping
# --cco-access, so it fired on the HOST on an ordinary typo. Two shapes, one
# mechanism: an unknown preset, and an explicit INV-2 floor violation.
test_invariant_exit_sentinel_access_refusal_is_not_a_crash() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"

    local spec want rc
    for spec in "read-projekt|Invalid cco_access" "current=none|INV-2"; do
        want="${spec#*|}"
        rc=0; run_cco start test-proj --cco-access "${spec%%|*}" --dry-run || rc=$?
        [[ $rc -ne 0 ]] || { fail "INV-EXIT: --cco-access '${spec%%|*}' should have been refused, got exit 0"; return 1; }
        case "$CCO_OUTPUT" in
            *"$want"*) ;;
            *) fail "INV-EXIT: expected the '$want' refusal for --cco-access '${spec%%|*}' — the arm-2 assertion would be vacuous:"$'\n'"$CCO_OUTPUT"; return 1 ;;
        esac
        case "$CCO_OUTPUT" in
            *"exited unexpectedly"*)
                fail "INV-EXIT: the crash notice was appended to a well-formed refusal for --cco-access '${spec%%|*}':"$'\n'"$CCO_OUTPUT"
                return 1 ;;
        esac
    done
}

# ── INV-AVAIL the CLASS guard (ADR-0056 D1 / D9) ──────────────────────
# INV-AVAIL: no verb computes an availability or scope-widening answer for itself.
# Every such answer is produced by lib/access-scope.sh, which owns (a) the
# three-state classification, (b) the sentence, (c) the remedy and (d) the exit
# code. Deliberately the same shape as INV-S6, whose CLASS lint has held.
#
# ── Why a SECOND guard beside INV-ENV ────────────────────────────────
# INV-ENV (above) already budgets the four STATE SENTENCES. It is a pure string
# count, and it is blind to the two halves that actually shipped the defect:
#   1. the PREDICATE — `[[ -d "$_probe" ]]` renders availability without ever
#      spelling a state sentence, so INV-ENV scored `project show` clean while it
#      badged a mounted-but-unbindable member `[missing]` for three cycles;
#   2. the BADGES + the RETIRED REMEDY — `[missing]`, `[unresolved]` and
#      `cco resolve` are the reserved strings D9 names, and none of them appear in
#      INV-ENV's vocabulary.
# INV-ENV answers "is the state spelled in one place"; INV-AVAIL answers "is the
# state DECIDED in one place". Neither subsumes the other.
#
# ── MECHANISM — assignment provenance, not a naive grep (D9, from INV-S6) ──
# A guard blind to the `local x; x=$(…)` split idiom misses the majority of its
# class and certifies anyway — that is the recorded INV-S6 lesson, and the very
# site this unit fixes is written in exactly that idiom:
#     local _probe; _probe=$(_cco_member_probe_path "$n" "$p")
#     if [[ -d "$_probe" ]]; then …
# A grep for `_cco_member_probe_path` on the same line as `[[ -d` finds NOTHING
# there. So, per file, an awk pass:
#   1. taints every variable whose RHS names an availability-path resolver or an
#      already-tainted variable — including the split form;
#   2. flags an existence predicate ([[ -d/-e/-f/-r/-w … ]]) whose target expands a
#      tainted variable or calls a resolver directly                    [KIND=PRED]
#   3. flags a reserved AVAILABILITY string on a non-comment line       [KIND=STR]
# Taint does not leak across function boundaries (reset at each definition), which
# is what keeps a same-named local in an unrelated function from false-flagging.
#
# TRACKED availability resolver — deliberately EXACTLY ONE: _cco_member_probe_path.
# Its whole purpose is "where do I look to decide whether this member is available
# here" (the container mount in operator mode, the index host path on the host), so
# an existence predicate on its result IS an availability decision, by construction
# and with no false positives.
#
# ⚠ The wider set was tried first and REJECTED, which is worth recording because the
# obvious next maintainer will try it again: tracking _resolve_project_yml /
# _index_get_path / _mount_source_for as well flags twelve sites, and every one of
# them is legitimate — `[[ -f "$project_yml" ]] || die "has no readable
# project.yml"` runs AFTER the owner already answered `here`, and asks a different
# question (is the manifest readable), not an availability question. A lint whose
# hits are mostly legitimate gets allowlisted until it is inert, which is the
# failure mode D9 exists to avoid. INV-S6 could ban its whole resolver set because
# behind the ADR-0047 boundary those reads are MEANINGLESS; here they are meaningful.
# NOT tracked for the same reason: _cco_display_path (a PRESENTATION helper — INV-4
# host-path hygiene; its result is never probed).
#
# RESERVED STRINGS (D9): the two badges and the two notice fragments are absolute —
# they belong to the owner, full stop. `cco resolve` is different in kind: D2 makes
# a remedy a function of the PRINT SITE, and the verb is legitimate advice ON THE
# HOST. So it is flagged only when it appears WITHOUT a host qualifier on the same
# line, in a file the operator shim can actually reach. That is the rule
# index.sh:160-164 already implements and D2 generalises.
_avail_lint_prog() {
    cat <<'AWK'
BEGIN {
  RES="_cco_member_probe_path"
  STR="\\[missing\\]|\\[unresolved\\]|not mounted in this session|not available at this access scope"
  QUAL="on your host|on the host|on a terminal|_cco_container_operator"
  fn="(toplevel)"; nrem=0; ctxaware=0
}
function flushfn(  i) {
  if (!ctxaware) for (i=0;i<nrem;i++) print rem[i]
  nrem=0; ctxaware=0
}
/^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{?[ \t]*$/ {
  flushfn()
  fn=$0; sub(/\(\).*/,"",fn); for (v in seen) delete seen[v]
  nrem=0; ctxaware=0
  next
}
/^[ \t]*#/ { next }                                   # comments are exempt (docs quote the vocabulary)
{
  line=$0; s=line
  # 1. taint propagation, including the `local x; x=$(...)` split form
  while (match(s, /(^|[ \t;])[A-Za-z_][A-Za-z0-9_]*=/)) {
    seg=substr(s, RSTART, RLENGTH); vn=seg; gsub(/[ \t;]/,"",vn); sub(/=$/,"",vn)
    rest=substr(s, RSTART+RLENGTH); r=rest; sub(/;.*/,"",r)
    t=0
    if (r ~ ("(" RES ")")) t=1
    else { for (v in seen) if (index(r,"$"v)||index(r,"${"v)) t=1 }
    if (t && vn!="") seen[vn]=1
    s=substr(s, RSTART+RLENGTH)
  }
  # 2. existence predicate on a tainted/resolver path → the verb is deciding
  if (line ~ /\[\[[^]]*-[defrw][ \t]+/) {
    hit=0
    if (line ~ ("\\$\\(?(" RES ")")) hit=1
    for (v in seen) if (index(line,"$"v)||index(line,"${"v)) hit=1
    if (hit) print FILENAME "|" fn "|PRED"
  }
  # 3. a reserved availability string outside the owner
  if (line ~ (STR)) print FILENAME "|" fn "|STR"
  # 4. the retired remedy, unqualified at a container-reachable print site (D2).
  #    A line carrying its own qualifier is fine; so is a line inside a function
  #    that CONSULTS the print site (_cco_container_operator), because such a
  #    function's host arm is legitimately unqualified — that is the shape
  #    index.sh:160-164 uses and D2 blesses. Deferred to end-of-function so the
  #    consult may appear after the message it governs.
  if (line ~ (QUAL)) ctxaware=1
  if (line ~ /cco resolve/ && line !~ (QUAL)) rem[nrem++]=FILENAME "|" fn "|REMEDY"
}
END { flushfn() }
AWK
}

# Echo the VIOLATING hits ("<basename>|<func>|<kind>" per line) found in <libdir>.
# Empty output = clean.
_avail_lint_violations() {
    local libdir="$1" f b prog hf fn kind
    prog=$(_avail_lint_prog)
    # EXCLUDED — the owner itself, plus the two layers whose subject is a STORE
    # BUCKET rather than a named resource (a bucket is never "unresolved"; their
    # own predicate is governed by INV-S3b/INV-S6, and INV-ENV budgets their
    # sentence). index.sh is the index PRIMITIVE: it defines _index_get_path and
    # owns the read-state taxonomy ADR-0056 D6 put there deliberately.
    local excluded=" access-scope.sh store.sh rename.sh index.sh "
    # ALLOWLIST — HOST-ONLY verb files. The operator shim REFUSES these in-container
    # (bin/cco: start|stop|build|new|resolve|sync|init|join|forget|update|clean, plus
    # project rename/export/import/add and pack/template publish|export), so a
    # `cco resolve` remedy printed there is read on the host, where it is exactly
    # right — D2 is a statement about the PRINT SITE, not about the string.
    local host_only=" cmd-resolve.sh cmd-sync.sh cmd-init.sh cmd-join.sh cmd-forget.sh"
    host_only+=" cmd-clean.sh cmd-update.sh cmd-config.sh cmd-start.sh migrate.sh"
    host_only+=" cmd-project-rename.sh cmd-project-export-import.sh cmd-project-add.sh"
    host_only+=" packs.sh local-paths.sh "
    for f in "$libdir"/*.sh; do
        b=$(basename "$f")
        case "$excluded"  in *" $b "*) continue ;; esac
        case "$host_only" in *" $b "*) continue ;; esac
        while IFS='|' read -r hf fn kind; do
            [[ -z "$hf" ]] && continue
            printf '%s|%s|%s\n' "$b" "$fn" "$kind"
        done < <(awk "$prog" "$f")
    done
}

test_invariant_no_local_availability_decisions() {
    # 1. The live tree must be clean.
    local v; v=$(_avail_lint_violations "$REPO_ROOT/lib")
    [[ -z "$v" ]] || fail "INV-AVAIL: a verb decides availability for itself — an existence predicate on a member/mount/project path [PRED], or a reserved availability string [STR], outside lib/access-scope.sh. Ask _env_member_state/_env_project_state and render with _env_unavailable[_warn] (ADR-0056 D1):"$'\n'"$v"

    # 2. Discrimination (D9, mandatory). A STATIC invariant cannot "fail on reverted
    #    lib/", so an undemonstrated lint is indistinguishable from an inert one.
    #    Both arms are planted in a STAGED copy of a NON-allowlisted file.
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    cp "$REPO_ROOT"/lib/*.sh "$tmp/" 2>/dev/null || { fail "INV-AVAIL self-test: could not stage lib/"; return 1; }

    # 2a. MUST FIRE — and specifically through the SPLIT idiom a naive grep misses:
    #     the resolver and the predicate are on DIFFERENT lines.
    printf '\n_lint_probe_avail() {\n    local p\n    p=$(_cco_member_probe_path "$1" "$2")\n    if [[ -d "$p" ]]; then echo here; fi\n}\n' \
        >> "$tmp/cmd-project-query.sh"
    local planted; planted=$(_avail_lint_violations "$tmp")
    [[ "$planted" == *"cmd-project-query.sh|_lint_probe_avail|PRED"* ]] \
        || { fail "INV-AVAIL does NOT discriminate: a planted split-idiom availability probe went uncaught (this is the exact shape of the shipped defect):"$'\n'"${planted:-<no hits>}"; return 1; }

    # 2b. MUST FIRE — a reserved string in a container-reachable file.
    printf '\n_lint_probe_badge() {\n    echo "  x [missing]"\n}\n' >> "$tmp/cmd-template.sh"
    planted=$(_avail_lint_violations "$tmp")
    [[ "$planted" == *"cmd-template.sh|_lint_probe_badge|STR"* ]] \
        || { fail "INV-AVAIL does NOT discriminate: a planted reserved badge went uncaught"; return 1; }

    # 2c. MUST NOT FIRE — a comment quoting the vocabulary, and an existence
    #     predicate on a path that is NOT an availability path. Without this arm a
    #     guard that flags every `[[ -d ]]` in lib/ would also "pass" 2a, and would
    #     be unusable rather than discriminating.
    rm -rf "$tmp"; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    cp "$REPO_ROOT"/lib/*.sh "$tmp/" 2>/dev/null || { fail "INV-AVAIL self-test: could not re-stage lib/"; return 1; }
    printf '\n# a doc line about [missing] and "not mounted in this session"\n_lint_probe_ok() {\n    local d="$HOME/somewhere"\n    if [[ -d "$d" ]]; then echo fine; fi\n}\n' \
        >> "$tmp/cmd-template.sh"
    planted=$(_avail_lint_violations "$tmp")
    [[ "$planted" != *"_lint_probe_ok"* ]] \
        || { fail "INV-AVAIL over-reaches: a non-availability existence test / a comment quoting the vocabulary was flagged:"$'\n'"$planted"; return 1; }
    return 0
}

# ── INV-AVAIL/CONSUMER — reading the answer from the wrong owner ──────
#
# THE INVARIANT — a verb that turns `_project_iter_members`' / `_project_member_status`'
# status into a REFUSAL must ask `_env_member_state` first.
#
# WHY A SECOND ARM. INV-AVAIL's three arms guard how a verb COMPUTES availability
# (a probe predicate), and which BADGES it spells. FI-41 shipped through all three
# untouched: `cco pack rename` computed nothing and spelled no badge — it branched on
# the index-level word `unresolved` and printed the `cco resolve` remedy. That word
# means "the probe is not inspectable in THIS context", and column 2 is the container
# MOUNT in operator mode, so in a session it covers two realities and the remedy fits
# only one. On the host the same word is honest, which is why every host-only verb
# file stays allowlisted here exactly as it is for the D2 arm.
#
# The meta-root, one level out from the cycle's own: not "a predicate every call site
# computes for itself" but **a call site reading the right value from the wrong owner**.
#
# The awk source lives in its own function — NOT inline as `prog=$(cat <<'AWK' … )` —
# because bash 3.2's legacy command-substitution scanner does not skip heredoc bodies
# (bin/cco:181-186 carries the rule; FI-46 is what happens when it is forgotten).
_avail_consumer_lint_prog() {
    cat <<'AWK'
BEGIN { fn="(toplevel)"; t=0; br=0; sp=0; ask=0 }
function flushfn() {
  if (t && br && sp && !ask) print FILENAME "|" fn "|CONSUMER"
  t=0; br=0; sp=0; ask=0
}
/^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{?[ \t]*$/ {
  flushfn(); fn=$0; sub(/\(\).*/,"",fn); next
}
/^[ \t]*#/ { next }
{
  if ($0 ~ /_project_iter_members|_project_member_status/)        t=1
  if ($0 ~ /(==[ \t]*"?unresolved"?)|(^[ \t]*unresolved\))/)      br=1
  if ($0 ~ /(^|[ \t;&|(])(die|refuse)[ \t"]/)                     sp=1
  if ($0 ~ /_env_member_state|_env_project_state/)                ask=1
}
END { flushfn() }
AWK
}

_avail_consumer_lint_violations() {
    local libdir="$1" f b
    local prog
    prog=$(_avail_consumer_lint_prog)
    # Same exemptions as the D2 arm, for the same reasons: access-scope.sh IS the
    # owner, index.sh DEFINES the status vocabulary, rename.sh routes the status as a
    # DATA tag rather than a message, store.sh has its own guard. Host-only verb files
    # are exempt because the shim refuses them in-container — where `unresolved` cannot
    # be a not-mounted member, the conflation this arm exists to catch cannot arise.
    local excluded=" access-scope.sh store.sh rename.sh index.sh "
    local host_only=" cmd-resolve.sh cmd-sync.sh cmd-init.sh cmd-join.sh cmd-forget.sh"
    host_only+=" cmd-clean.sh cmd-update.sh cmd-config.sh cmd-start.sh migrate.sh"
    host_only+=" cmd-project-rename.sh cmd-project-export-import.sh cmd-project-add.sh"
    host_only+=" packs.sh local-paths.sh "
    for f in "$libdir"/*.sh; do
        b=$(basename "$f")
        case "$excluded"  in *" $b "*) continue ;; esac
        case "$host_only" in *" $b "*) continue ;; esac
        while IFS='|' read -r hf fn kind; do
            [[ -z "$hf" ]] && continue
            printf '%s|%s|%s\n' "$b" "$fn" "$kind"
        done < <(awk "$prog" "$f")
    done
}

test_invariant_no_status_word_refusals() {
    # 1. The live tree must be clean.
    local v; v=$(_avail_consumer_lint_violations "$REPO_ROOT/lib")
    [[ -z "$v" ]] || fail "INV-AVAIL/CONSUMER: a verb refuses on _project_iter_members' status word without asking _env_member_state — in a session that word cannot tell a NOT-MOUNTED member from an unresolved one, so the remedy fits only one of them (FI-41):"$'\n'"$v"

    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    cp "$REPO_ROOT"/lib/*.sh "$tmp/" 2>/dev/null || { fail "INV-AVAIL/CONSUMER self-test: could not stage lib/"; return 1; }

    # 2a. MUST FIRE — the exact shape FI-41 shipped: iterate members, branch on the
    #     status word, refuse. No _env_member_state anywhere in the function.
    printf '\n_lint_probe_consumer() {\n    local n p s\n    while IFS=$'"'"'\\t'"'"' read -r n p s; do\n        [[ "$s" == unresolved ]] && die "unresolved member $n. Run '"'"'cco resolve'"'"' on your host first."\n    done < <(_project_iter_members "$1")\n}\n' \
        >> "$tmp/cmd-pack.sh"
    local planted; planted=$(_avail_consumer_lint_violations "$tmp")
    [[ "$planted" == *"cmd-pack.sh|_lint_probe_consumer|CONSUMER"* ]] \
        || { fail "INV-AVAIL/CONSUMER does NOT discriminate: a planted status-word refusal went uncaught (this is the exact shape of the shipped defect):"$'\n'"${planted:-<no hits>}"; return 1; }

    # 2b. MUST NOT FIRE — the same shape, fixed: the owner is asked. Without this arm
    #     the guard would flag the remedy as well as the defect, and a lint that cannot
    #     be satisfied is one somebody deletes.
    rm -rf "$tmp"; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    cp "$REPO_ROOT"/lib/*.sh "$tmp/" 2>/dev/null || { fail "INV-AVAIL/CONSUMER self-test: could not re-stage lib/"; return 1; }
    printf '\n_lint_probe_fixed() {\n    local n p s st\n    while IFS=$'"'"'\\t'"'"' read -r n p s; do\n        [[ "$s" == unresolved ]] || continue\n        st=$(_env_member_state "$n" "$(_index_get_path "$1" "$n")")\n        [[ "$st" == not-mounted ]] && _env_unavailable not-mounted repo "$n"\n        die "unresolved member $n."\n    done < <(_project_iter_members "$1")\n}\n' \
        >> "$tmp/cmd-pack.sh"
    planted=$(_avail_consumer_lint_violations "$tmp")
    [[ "$planted" != *"_lint_probe_fixed"* ]] \
        || { fail "INV-AVAIL/CONSUMER over-reaches: the SANCTIONED shape (asks _env_member_state, then refuses) was flagged:"$'\n'"$planted"; return 1; }
    return 0
}

# ── INV-DESC — the trusted descriptor's keys cross the boundary ───────
#
# THE INVARIANT — every key `cco start` writes into the trusted session descriptor
# (lib/cmd-start.sh, the block redirected into "$session_descriptor") appears in
# ALLOWED_KEYS[] in config/cco-svc-helper.c.
#
# WHY A LINT AND NOT A COMMENT. The helper builds the elevated child's environment
# FROM SCRATCH (ADR-0047 R2: never argv, never the caller's env) and copies over only
# whitelisted descriptor keys. A key the writer emits and the whitelist omits is
# therefore dropped IN SILENCE: no error, no refusal, no exit code — the elevated cco
# simply runs without a signal the host believes it sent. Both sides look correct in
# isolation, which is why the writer's own "Keys mirror the helper's whitelist" comment
# survived being false.
#
# WHY THE SUITE COULD NOT SEE IT. A bash test exercises such a signal by exporting it
# and calling the consumer in-process (tests/test_access_scope.sh does exactly this for
# CCO_STORE_TOTALS) — a path that never crosses the setuid boundary, so it passes on a
# tree where the real path is inert. This is the RC-17 shape: the hermetic lane cannot
# observe container reality. A STATIC cross-file lint can, because the correspondence
# it checks is a property of the two source files, not of a running container.
#
# THE SHIPPED DEFECT this closes: CCO_STORE_TOTALS (ADR-0056 D5) was written into the
# descriptor by S4 and never whitelisted, so the "hidden by access scope" notice stayed
# silent about exactly the resources D5 exists to count — `cco list packs` showed 1 of 6
# packs with no notice at all. Found by the post-build container probe, not by the suite.
#
# DELIBERATELY ONE-DIRECTIONAL: written ⊆ allowed. The reverse (a whitelisted key no
# writer emits) is dead surface, not a behavioural defect — and failing on it would
# reject a legitimate two-commit sequence that widens the whitelist before the writer
# uses it. ADR-0047's minimal-surface argument is served by review, not by this lint.

#
# SECOND ARM — the same family, the other registry. A descriptor key is also a variable
# the SUITE must neutralize: `bin/test` unsets the ambient session environment so a
# self-dev run behaves like a host run (its own comment explains why). A key missing
# there leaks a REAL session value into every test that reads it — for CCO_STORE_TOTALS,
# a hidden-count supplement three notice tests never asked for, failing in-container and
# passing on the host, which is indistinguishable from the known host-only set until
# someone diffs the names. Same omission class as the whitelist, found the same day: a
# signal family with more than one registry needs the correspondence linted, not
# remembered.

# Echo the keys `cco start` writes into the trusted descriptor, one per line. Both arms
# below read the writer through THIS function, so they can never disagree about what a
# descriptor key is. Arg: <path to cmd-start.sh> (a path, so the self-tests can read a
# STAGED copy).
#
# The keys are the printf'd KEY= names inside the group redirected into
# "$session_descriptor": buffer since the opening `{`, emit at the redirect. So a printf
# anywhere else in the file (the compose stream, another verb) is not a descriptor key,
# and the block can move without the lint chasing line numbers.
#
# The awk source is a function, not an inline `$(cat <<'AWK' … )` — see FI-46 and
# bin/cco:181-186: bash 3.2 cannot parse a heredoc inside a command substitution.
_desc_lint_written_keys_prog() {
    cat <<'AWK'
/^[[:space:]]*\{[[:space:]]*$/ { n = 0; next }
match($0, /printf '[A-Z_][A-Z_0-9]*=/) {
    k = substr($0, RSTART + 8); sub(/=.*/, "", k); buf[n++] = k
}
/^[[:space:]]*\}[[:space:]]*>[[:space:]]*"\$session_descriptor"/ {
    for (i = 0; i < n; i++) print buf[i]; n = 0
}
AWK
}

_desc_lint_written_keys() {
    local prog
    prog=$(_desc_lint_written_keys_prog)
    awk "$prog" "$1"
}

# Echo the members of <keys> absent from the space-delimited <registry>, one per line.
# A parse failure on either side must never read as "clean", so it is reported as a hit.
_desc_lint_absent_from() {
    local keys="$1" registry="$2" what="$3" k
    [[ -n "$keys" ]]         || { echo "__NO_DESCRIPTOR_KEYS_PARSED__"; return 0; }
    [[ "$registry" != "  " ]] || { echo "__NO_${what}_PARSED__"; return 0; }
    while IFS= read -r k; do
        [[ -n "$k" ]] || continue
        case "$registry" in *" $k "*) ;; *) echo "$k" ;; esac
    done <<< "$keys"
}

# Descriptor keys missing from the helper's whitelist (empty = clean).
# Args: <cmd-start.sh> <cco-svc-helper.c>.
_desc_lint_missing_keys() {
    local allowed
    # Whitelist entries: the quoted names in the ALLOWED_KEYS[] initialiser.
    allowed=" $(sed -n '/ALLOWED_KEYS\[\][[:space:]]*=[[:space:]]*{/,/};/p' "$2" \
        | grep -o '"[A-Z_][A-Z_0-9]*"' | tr -d '"' | tr '\n' ' ') "
    _desc_lint_absent_from "$(_desc_lint_written_keys "$1")" "$allowed" NO_WHITELIST
}

# Descriptor keys the SUITE RUNNER does not neutralize (empty = clean).
# Args: <cmd-start.sh> <bin/test>.
_desc_lint_unneutralized_keys() {
    local cleared=" " tok
    # The unset statement: from the `unset` keyword to the redirect that closes it,
    # keeping only shell-variable-shaped tokens (drops 2>/dev/null, ||, true, \).
    for tok in $(sed -n '/^unset /,/2>\/dev\/null/p' "$2"); do
        [[ "$tok" =~ ^[A-Z][A-Z_0-9]*$ ]] && cleared+="$tok "
    done
    _desc_lint_absent_from "$(_desc_lint_written_keys "$1")" "$cleared" NO_UNSET_LIST
}

# Descriptor keys the OPERATOR LANE sanitiser leaves to chance (empty = clean).
# Args: <cmd-start.sh> <tests/helpers.sh>.
#
# Here "neutralized" is wider than in bin/test: _lane_operator_exports deliberately SETS
# most of these to a deterministic value (that is the point of a lane) and unsets the
# rest. Either is fine; what is not fine is a key it never mentions, because then the
# value comes from whatever session happens to be running — the very leak its own
# comment (c) says it exists to prevent.
_desc_lint_unpinned_lane_keys() {
    local pinned=" " tok region
    region=$(sed -n '/^_lane_operator_exports()/,/^}/p' "$2")
    for tok in $(printf '%s' "$region" | tr -c 'A-Za-z0-9_' ' '); do
        [[ "$tok" =~ ^[A-Z][A-Z_0-9]*$ ]] && pinned+="$tok "
    done
    _desc_lint_absent_from "$(_desc_lint_written_keys "$1")" "$pinned" NO_LANE_REGION
}

test_invariant_descriptor_keys_whitelisted() {
    local writer="$REPO_ROOT/lib/cmd-start.sh" helper="$REPO_ROOT/config/cco-svc-helper.c"
    [[ -f "$writer" && -f "$helper" ]] \
        || { fail "INV-DESC: descriptor writer or setuid helper not found"; return 1; }

    # 1. The live tree must be clean.
    local missing; missing=$(_desc_lint_missing_keys "$writer" "$helper")
    [[ -z "$missing" ]] || { fail "INV-DESC: \`cco start\` writes a descriptor key the setuid helper does not whitelist, so the elevated cco never receives it — silently, and invisibly to a suite that exports the signal in-process. Add it to ALLOWED_KEYS[] in config/cco-svc-helper.c (and rebuild: the helper is compiled into the image):"$'\n'"$missing"; return 1; }

    # 2. Discrimination (D9, mandatory). A static invariant cannot "fail on a reverted
    #    tree" when both halves of the correspondence move together, so the proof is a
    #    planted violation — in both directions — over STAGED copies.
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    cp "$writer" "$tmp/cmd-start.sh"; cp "$helper" "$tmp/helper.c"

    # 2a. MUST FIRE — a new descriptor key that nobody whitelisted: the exact shape of
    #     the shipped CCO_STORE_TOTALS defect.
    awk '/^[[:space:]]*\}[[:space:]]*>[[:space:]]*"\$session_descriptor"/ && !done {
            print "                printf '\''CCO_LINT_PLANT=%s\\n'\'' \"x\""; done = 1
         } { print }' "$tmp/cmd-start.sh" > "$tmp/planted.sh"
    grep -q 'CCO_LINT_PLANT' "$tmp/planted.sh" \
        || { fail "INV-DESC self-test: could not plant a descriptor key — has the descriptor block moved?"; return 1; }
    missing=$(_desc_lint_missing_keys "$tmp/planted.sh" "$tmp/helper.c")
    [[ "$missing" == *"CCO_LINT_PLANT"* ]] \
        || { fail "INV-DESC does NOT discriminate: a planted un-whitelisted descriptor key went uncaught (this is the exact shape of the shipped defect):"$'\n'"${missing:-<no hits>}"; return 1; }

    # 2b. MUST NOT FIRE — the same key, now whitelisted. Without this arm a lint that
    #     flagged every key unconditionally would also "pass" 2a.
    sed 's/"CCO_CONFIG_TARGETS",/"CCO_LINT_PLANT",\n    "CCO_CONFIG_TARGETS",/' \
        "$tmp/helper.c" > "$tmp/helper-ok.c"
    grep -q 'CCO_LINT_PLANT' "$tmp/helper-ok.c" \
        || { fail "INV-DESC self-test: could not plant a whitelist entry"; return 1; }
    missing=$(_desc_lint_missing_keys "$tmp/planted.sh" "$tmp/helper-ok.c")
    [[ -z "$missing" ]] \
        || { fail "INV-DESC over-reaches: a properly whitelisted descriptor key was flagged:"$'\n'"$missing"; return 1; }

    # 2c. MUST NOT FIRE — a printf of a KEY= outside the descriptor group is not a
    #     descriptor key (the compose stream emits env lines of the same shape).
    printf '\n_lint_probe_other() {\n    printf '\''CCO_OTHER_PLANT=%%s\\n'\'' "x"\n}\n' \
        >> "$tmp/planted.sh"
    missing=$(_desc_lint_missing_keys "$tmp/planted.sh" "$tmp/helper-ok.c")
    [[ "$missing" != *"CCO_OTHER_PLANT"* ]] \
        || { fail "INV-DESC over-reaches: a printf outside the descriptor group was read as a descriptor key:"$'\n'"$missing"; return 1; }
    return 0
}

# ── INV-AVAIL/D5 — counting a store kind means declaring it ───────────
#
# THE INVARIANT — a function that calls `_env_note_seen` (it enumerates a store kind,
# row by row, for the host-total supplement) also calls `_env_store_subject` (it says
# which kinds its notice may speak about). The two are halves of one statement: seen is
# "how many I found", subject is "what I was looking for", and the supplement is the
# difference. A function with only the first half enumerates without declaring, so its
# rows are counted and then dropped — silently, because the ratified default is silence.
#
# WHY THIS SHAPE. The kinds are often variables (`_env_note_seen "$rk"` in the unified
# lister, `_env_store_subject $_ENV_STORE_KINDS` beside it), so matching kind NAMES
# statically would be noise. Function-level co-presence is what is checkable, and it is
# exactly the omission class: an exhaustive enumerator either declares or it does not.
#
# ⚠ THE OTHER DIRECTION IS NOT LINTED. Declaring without enumerating is harmless and
# often right: the supplement is total-minus-seen, so a declared kind with no rows
# yields the whole total — precisely the G=none case D5 exists for (`cco list packs`
# with the pack mount absent declares pack and sees nothing). Linting that direction
# would flag the design.
#
# Own function for the awk source, never an inline `$(cat <<'AWK' … )` — bash 3.2's
# command-substitution scanner does not skip heredoc bodies (FI-46, bin/cco:181-186).
_seen_lint_prog() {
    cat <<'AWK'
/^[_a-zA-Z][_a-zA-Z0-9]*\(\)[[:space:]]*\{/ { fn = $0; sub(/\(\).*/, "", fn); seen = 0; subj = 0 }
$0 ~ /_env_note_seen/ && $0 !~ /^[[:space:]]*#/     { if (fn != "") seen = 1 }
$0 ~ /_env_store_subject/ && $0 !~ /^[[:space:]]*#/ { if (fn != "") subj = 1 }
/^\}/ { if (fn != "" && seen && !subj) print fn; fn = ""; seen = 0; subj = 0 }
AWK
}

_seen_lint_violations() {
    local libdir="$1" f b prog
    prog=$(_seen_lint_prog)
    for f in "$libdir"/*.sh; do
        b=$(basename "$f")
        # The owner DEFINES both primitives; its mentions are definitions, not calls.
        [[ "$b" == "access-scope.sh" ]] && continue
        awk "$prog" "$f" | sed "s|^|${b}: |"
    done
}

test_invariant_store_subject_declared_where_counted() {
    local v; v=$(_seen_lint_violations "$REPO_ROOT/lib")
    [[ -z "$v" ]] || { fail "INV-AVAIL/D5: a verb counts enumerated rows (_env_note_seen) without declaring which store kinds its notice may speak about (_env_store_subject), so those rows are counted and then dropped — the supplement stays silent about resources that exist. Declare the subject beside the enumeration loop:"$'\n'"$v"; return 1; }

    # Discrimination, both directions, on a staged copy of a real (non-owner) file.
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    cp "$REPO_ROOT"/lib/*.sh "$tmp/" 2>/dev/null || { fail "INV-D5 self-test: could not stage lib/"; return 1; }

    # MUST FIRE — enumerates, never declares.
    printf '\n_lint_probe_counts_only() {\n    _env_note_seen pack\n}\n' >> "$tmp/cmd-template.sh"
    local planted; planted=$(_seen_lint_violations "$tmp")
    [[ "$planted" == *"_lint_probe_counts_only"* ]] \
        || { fail "INV-D5 does NOT discriminate: a planted count-without-declare went uncaught:"$'\n'"${planted:-<no hits>}"; return 1; }

    # MUST NOT FIRE — the correct pairing.
    printf '\n_lint_probe_counts_and_declares() {\n    _env_store_subject pack\n    _env_note_seen pack\n}\n' \
        >> "$tmp/cmd-template.sh"
    planted=$(_seen_lint_violations "$tmp")
    [[ "$planted" != *"_lint_probe_counts_and_declares"* ]] \
        || { fail "INV-D5 over-reaches: a correctly paired enumerator was flagged:"$'\n'"$planted"; return 1; }
    return 0
}

# The second registry: the same descriptor keys must be neutralized by the suite runner.
# Split from the whitelist arm so a failure names WHICH registry drifted — the remedies
# are in different files and only one of them needs a rebuild.
test_invariant_descriptor_keys_neutralized_in_suite() {
    local writer="$REPO_ROOT/lib/cmd-start.sh" runner="$REPO_ROOT/bin/test"
    [[ -f "$writer" && -f "$runner" ]] \
        || { fail "INV-DESC: descriptor writer or test runner not found"; return 1; }

    # 1. The live tree must be clean.
    local leaked; leaked=$(_desc_lint_unneutralized_keys "$writer" "$runner")
    [[ -z "$leaked" ]] || { fail "INV-DESC: \`cco start\` writes a descriptor key that bin/test does not unset, so a self-dev run inherits the REAL session's value and tests that read it fail in-container while passing on the host — which reads as one more host-only failure. Add it to the unset list in bin/test:"$'\n'"$leaked"; return 1; }

    # 2. Discrimination. MUST FIRE on a staged runner with one key dropped from the unset
    #    list — literally the pre-fix state of bin/test for CCO_STORE_TOTALS.
    #
    #    The victim is whatever key the writer lists first, so the plant must not depend
    #    on how THAT key happens to be spelled in the registry: the drop is scoped to the
    #    registry's own region and confirmed by awk (exit 3 when nothing was removed),
    #    never by grepping the whole file — a comment naming the key would defeat that,
    #    and a plant that quietly removes nothing is an inert lint wearing a PASS.
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    local victim; victim=$(_desc_lint_written_keys "$writer" | grep -v '^PROJECT_NAME$' | head -1)
    [[ -n "$victim" ]] || { fail "INV-DESC self-test: no descriptor key to drop"; return 1; }
    awk -v v="$victim" '
        /^unset /         { inb = 1 }
        inb               { if (gsub("(^| )" v "( |$)", " ")) removed = 1 }
        /2>\/dev\/null/   { inb = 0 }
                          { print }
        END               { exit(removed ? 0 : 3) }
    ' "$runner" > "$tmp/test-runner" \
        || { fail "INV-DESC self-test: could not drop '$victim' from bin/test's unset list"; return 1; }
    leaked=$(_desc_lint_unneutralized_keys "$writer" "$tmp/test-runner")
    [[ "$leaked" == *"$victim"* ]] \
        || { fail "INV-DESC does NOT discriminate: '$victim' dropped from bin/test's unset list went uncaught:"$'\n'"${leaked:-<no hits>}"; return 1; }

    # 3. The THIRD registry: the operator-lane sanitiser, which by its own comment (c)
    #    must not rely on the runner. Same key set, wider notion of "handled".
    local helpers="$REPO_ROOT/tests/helpers.sh"
    [[ -f "$helpers" ]] || { fail "INV-DESC: tests/helpers.sh not found"; return 1; }
    local unpinned; unpinned=$(_desc_lint_unpinned_lane_keys "$writer" "$helpers")
    [[ -z "$unpinned" ]] || { fail "INV-DESC: a descriptor key is neither pinned nor unset by _lane_operator_exports (tests/helpers.sh), so an operator-lane test inherits it from whatever cco session is running — its own comment (c) is the argument against exactly this. Pin it deterministically beside CCO_PROJECT_PACKS:"$'\n'"$unpinned"; return 1; }

    # MUST FIRE on a staged helpers.sh with every mention of the victim removed from the
    # lane function — whatever form it takes there (an export, an unset, a printf).
    # The staged file is only ever LINTED, never sourced, so dropping whole lines is safe.
    awk -v v="$victim" '
        /^_lane_operator_exports\(\)/ { inb = 1 }
        inb && /^}/                   { inb = 0 }
        inb && index($0, v)           { removed = 1; next }
                                      { print }
        END                           { exit(removed ? 0 : 3) }
    ' "$helpers" > "$tmp/helpers.sh" \
        || { fail "INV-DESC self-test: could not drop '$victim' from _lane_operator_exports"; return 1; }
    unpinned=$(_desc_lint_unpinned_lane_keys "$writer" "$tmp/helpers.sh")
    [[ "$unpinned" == *"$victim"* ]] \
        || { fail "INV-DESC does NOT discriminate: '$victim' dropped from the lane sanitiser went uncaught:"$'\n'"${unpinned:-<no hits>}"; return 1; }
    return 0
}

# ── INV-B32 the bash-3.2 CLASS guard (FI-46) ──────────────────────────
# A heredoc opened INSIDE a command substitution is unparseable by bash 3.2 — macOS's
# stock /bin/bash, and one of the two platforms this project supports. Its legacy
# `$( … )` scanner does not skip heredoc bodies, so punctuation in the body desyncs it,
# it never finds the closing `)`, and the WHOLE FILE dies: not one failing test but an
# aborted run whose log carries `0 failed` and no `Results:` line. `bin/cco:181-186`
# has carried the prohibition since the `cco help` incident; FI-46 is the same defect
# re-entering through a late in-cycle fix, in the file that guards every other
# invariant.
#
# WHY STATIC, NOT BEHAVIOURAL. The suite's own interpreter is bash 5.2 in the image and
# 3.2 only on a macOS host, so a behavioural regression test is green wherever the suite
# normally runs and proves nothing. The cover must read the SOURCE — which is what makes
# it work in both environments.
#
# WHAT ACTUALLY TRIGGERS IT (measured on real bash 3.2, not assumed). The body's own
# punctuation decides: an unbalanced quote (`it's`) or a bare unquoted paren aborts the
# parse; a body with balanced quotes, or with parens INSIDE quotes, parses fine. Two of
# FI-46's three sites aborted; the third was benign and would have stayed benign until
# someone added an apostrophe to a comment. **That is precisely why the rule is the
# unconditional one and not "keep the body tidy": survival depends on incidental
# punctuation a later edit can change without touching the construct.**
#
# SCOPE — two arms, because the tree is not uniform:
#   * `bin/` `lib/` `migrations/` `scripts/` — host-executed shipped or maintainer code
#     (`cco update` runs the migrations, and the maintainer runs `scripts/release.sh`,
#     under the same /bin/bash 3.2). Measured CLEAN of the entire class, so they carry
#     the UNCONDITIONAL rule: no heredoc inside a substitution, at all.
#     ⚠ `scripts/` was MISSING from this list when the guard was first written, and was
#     noticed only when `scripts/release.sh` was edited — the very file the maintainer
#     runs on macOS at every release. A named directory list is a lower bound; ask what
#     executes in the hostile environment, not which directories came to mind.
#   * `tests/` — the FI-46 shape only: the substitution as the RHS of an ASSIGNMENT.
#     180 argument-position fixtures (`create_project … "$(cat <<YAML`) predate this
#     guard and parse on 3.2 today; banning them outright is a 180-site refactor and a
#     maintainer's call, recorded on the roadmap, not a decision this lint makes.
# `config/` is deliberately unscanned: the entrypoint and hooks only ever run inside the
# image (bash 5.x), where the idiom parses.
#
# MECHANISM. Per non-comment line: find each `$(` that is not the `$((` of an arithmetic
# expansion, then flag only if a heredoc operator (`<<`, `<<-`, never the `<<<`
# herestring) appears BEFORE that substitution's closing `)`. The ordering test is what
# keeps `x=$(foo); cat <<EOF` — a heredoc opened after the substitution already closed —
# from reading as a violation. Comment lines are skipped by design: the prohibition is
# stated verbatim, idiom included, at `bin/cco:182` and beside each site it was written
# for.
_b32_lint_prog() {
    cat <<'AWK'
/^[[:space:]]*#/ { next }
{
  line = $0; off = 0
  while (1) {
    rest0 = substr(line, off + 1)
    if (!match(rest0, /\$\(/)) break
    abs = off + RSTART
    off = abs + 1
    rest = substr(line, abs + 2)
    if (substr(rest, 1, 1) == "(") continue          # $(( … )): `<<` there is a shift
    r2 = rest " "
    hp = 0
    if (match(r2, /(^|[^<])<<[^<]/)) hp = RSTART     # a heredoc opener, not `<<<`
    cp = index(rest, ")")
    if (hp > 0 && (cp == 0 || hp < cp)) {
      pre = substr(line, 1, abs - 1); sub(/"$/, "", pre)
      kind = (pre ~ /[A-Za-z_][A-Za-z0-9_]*=$/) ? "ASSIGN" : "ARG"
      print FILENAME "|" FNR "|" kind
      next
    }
  }
}
AWK
}

# Echo the violating hits ("<path>|<line>|<kind>" per line) under <root>, applying the
# per-arm scope above. Empty output = clean.
_b32_lint_violations() {
    local root="$1" f prog rel kind
    prog=$(_b32_lint_prog)
    for f in "$root"/bin/* "$root"/lib/*.sh "$root"/migrations/*/*.sh "$root"/scripts/*.sh "$root"/tests/*.sh; do
        [[ -f "$f" ]] || continue
        rel="${f#"$root"/}"
        while IFS='|' read -r _ line kind; do
            [[ -z "$line" ]] && continue
            # tests/: only the FI-46 assignment shape (see SCOPE above).
            [[ "$rel" == tests/* && "$kind" != "ASSIGN" ]] && continue
            printf '%s|%s|%s\n' "$rel" "$line" "$kind"
        done < <(awk "$prog" "$f")
    done
}

test_invariant_no_heredoc_inside_command_substitution() {
    # 1. The live tree must be clean.
    local v; v=$(_b32_lint_violations "$REPO_ROOT")
    [[ -z "$v" ]] || { fail "INV-B32: a heredoc is opened inside a command substitution. Bash 3.2 (macOS stock /bin/bash) cannot parse it, so the whole FILE aborts — a run that reports 0 failed and no Results: line (FI-46). Move the body into its own function and call it as \$(_fn); the shape is at bin/cco:_cco_usage_text:"$'\n'"$v"; return 1; }

    # 2. Discrimination, per arm. A static invariant cannot "fail on a reverted tree",
    #    so the guard must prove it catches the real shape. The plants are assembled
    #    from a variable so THIS file — which the lint scans — never carries the literal
    #    idiom on a code line.
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    mkdir -p "$tmp/bin" "$tmp/lib" "$tmp/tests" "$tmp/migrations/project"
    local hd='<<'
    #    2a. lib/: the unconditional arm — an ARGUMENT-position heredoc is enough.
    printf '\n_b32_probe_arg() {\n    echo "$(cat %s%s\nBEGIN { print "'"'"'" }\nAWK\n)"\n}\n' \
        "$hd" "'AWK'" > "$tmp/lib/probe.sh"
    #    2b. tests/: the FI-46 assignment shape, which is the one that shipped.
    printf '\ntest_b32_probe_assign() {\n    local p; p=$(cat %s%s\nBEGIN { print "(" }\nAWK\n)\n    echo "$p"\n}\n' \
        "$hd" "'AWK'" > "$tmp/tests/test_probe.sh"
    local planted; planted=$(_b32_lint_violations "$tmp")
    [[ "$planted" == *"lib/probe.sh|"*"|ARG"* ]] \
        || { fail "INV-B32 does NOT discriminate: a planted argument-position heredoc in lib/ went uncaught:"$'\n'"${planted:-<no hits>}"; return 1; }
    [[ "$planted" == *"tests/test_probe.sh|"*"|ASSIGN"* ]] \
        || { fail "INV-B32 does NOT discriminate: a planted assignment heredoc in tests/ went uncaught — this is the exact shape of the shipped defect (FI-46):"$'\n'"${planted:-<no hits>}"; return 1; }

    # 3. Over-reach, on the shapes that are legitimate and MUST stay silent: the
    #    sanctioned $(_fn) indirection, the rule quoted in a comment (bin/cco:182 does
    #    exactly this), an arithmetic left-shift, a heredoc opened only after the
    #    substitution closed, and — tests/ only — the 180 argument-position fixtures.
    rm -f "$tmp"/lib/*.sh "$tmp"/tests/*.sh
    {
        printf '#!/usr/bin/env bash\n'
        printf '# the rule, quoted verbatim: never write _body=$(cat %s%s … )\n' "$hd" "'EOF'"
        printf '_prog() {\n    cat %s%s\nBEGIN { print "(" }\nAWK\n}\n' "$hd" "'AWK'"
        printf '_use() {\n    local p; p=$(_prog)\n    local n=$((1 %s 3))\n    local x; x=$(echo hi); cat %sEOF\nbody\nEOF\n}\n' "$hd" "$hd"
    } > "$tmp/lib/legit.sh"
    printf 'test_fixture() {\n    create_project "$d" "p" "$(cat %sYAML\nname: p\nYAML\n)"\n}\n' "$hd" > "$tmp/tests/test_legit.sh"
    local overreach; overreach=$(_b32_lint_violations "$tmp")
    [[ -z "$overreach" ]] \
        || { fail "INV-B32 over-reaches: a legitimate shape (the \$(_fn) indirection, the rule in a comment, an arithmetic shift, a heredoc opened after the substitution closed, or a tests/ argument-position fixture) was flagged:"$'\n'"$overreach"; return 1; }
    return 0
}
