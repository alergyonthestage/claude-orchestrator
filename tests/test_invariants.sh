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
