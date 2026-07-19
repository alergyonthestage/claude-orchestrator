#!/usr/bin/env bash
# tests/test_config_editor.sh — config-editor built-in (ADR-0027 D1).
#
# config-editor is a reserved-name built-in (the tutorial model): `cco start
# config-editor` materializes internal/config-editor/ at runtime and mounts the
# personal store ~/.cco rw. Its scope is minimum-privilege by cwd/flag (ADR-0044
# §3, reconciled with the ADR-0046 ladder): bare inside a project → edit-global
# (~/.cco + that project's <repo>/.cco); bare outside any project → edit-global
# (~/.cco only); `--all` / `--cco-access edit-all` → edit-all (every project's
# .cco); `--project <name>` → edit-global targeting that project + its repos.
# (edit-project (none,rw,none) can no longer write ~/.cco, so the preset uses
# edit-global (rw,rw,none); an explicit --cco-access edit-project still works with
# a target.) Tests that assert a scope therefore cd into
# a neutral dir (global) or a project dir (cwd-project) for determinism — the
# suite runs from the repo root, which is itself a project. Host paths are
# launcher-injected into a generated runtime project.yml, never committed (AD3/G8).

# ── Global mode ───────────────────────────────────────────────────────

test_config_editor_mounts_cco_config_rw() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    cd "$tmpdir"   # neutral cwd → global mode (~/.cco only)
    run_cco start config-editor --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    # ~/.cco mounted read-write at /workspace/cco-config.
    assert_file_contains "$compose" "$HOME/.cco:/workspace/cco-config" || return 1
    assert_file_not_contains "$compose" "$HOME/.cco:/workspace/cco-config:ro" || return 1
}

test_config_editor_mounts_docs_readonly() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    cd "$tmpdir"
    run_cco start config-editor --dry-run --dump
    assert_file_contains "$DRY_RUN_DIR/.cco/docker-compose.yml" ":/workspace/cco-docs:ro"
}

# H4 (26-06-2026 migration review): the config-editor's internal mount names go
# through the in-process session override, not the persistent user-facing index.
test_config_editor_does_not_pollute_index() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    cd "$tmpdir"
    run_cco start config-editor --dry-run --dump
    local index="$CCO_STATE_HOME/index"
    if [[ -f "$index" ]]; then
        grep -qE '^[[:space:]]*cco-config:' "$index" \
            && fail "config-editor must not write 'cco-config' into the persistent index (H4)" || true
        grep -qE '^[[:space:]]*cco-docs:' "$index" \
            && fail "config-editor must not write 'cco-docs' into the persistent index (H4)" || true
    fi
}

test_config_editor_project_name_in_compose() {
    # The generated runtime project.yml names the session config-editor.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    cd "$tmpdir"
    run_cco start config-editor --dry-run --dump
    assert_file_contains "$DRY_RUN_DIR/.cco/docker-compose.yml" "container_name: cc-config-editor"
}

test_config_editor_no_project_overlay_in_global_mode() {
    # Global mode (bare, outside any project) mounts no <name>-config target.
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "proj-a" "$(minimal_project_yml proj-a)"
    cd "$tmpdir"   # outside any project → global mode
    run_cco start config-editor --dry-run --dump
    # No project config overlay is mounted (only ~/.cco).
    assert_file_not_contains "$DRY_RUN_DIR/.cco/docker-compose.yml" ":/workspace/proj-a-config"
}

# ── Project mode ──────────────────────────────────────────────────────

test_config_editor_project_mode_mounts_target_cco() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "myproj" "$(minimal_project_yml myproj)"
    run_cco start config-editor --project myproj --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    # The target project's committed .cco mounted rw at /workspace/myproj-config.
    assert_file_contains "$compose" "$tmpdir/repos/myproj/.cco:/workspace/myproj-config" || return 1
    # RC-1 T1b: the fixed-string form of this assertion was a FALSE GREEN — the
    # self-match overlay reads `…/.cco/.:/workspace/myproj-config/.:ro`, which the
    # literal `…-config:ro` never matched. Match the DESTINATION with an optional
    # `/.` so any :ro bind over the target root fails the test.
    if grep -qE ':/workspace/myproj-config(/\.)?:ro"' "$compose"; then
        fail "target .cco must not be re-overlaid :ro at Pc=rw: $(grep -nE ':/workspace/myproj-config(/\.)?:ro"' "$compose")"
    fi
    # ~/.cco is still mounted (global store always available in config-editor).
    assert_file_contains "$compose" "$HOME/.cco:/workspace/cco-config" || return 1
}

# WS-A: the cco-config (~/.cco) mount readonly FOLLOWS the resolved G. Project mode is
# (ro,rw,none) → the personal store is READ-ONLY (reference it, don't write it) on BOTH
# the workspace mount and the operator bucket; --cco-access edit-global (G=rw) makes it
# writable again. Also A-V3: claude follows G → global .cco/.claude (B3) is ro in project
# mode, rw under edit-global.
test_config_editor_project_mode_store_readonly() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "myproj" "$(minimal_project_yml myproj)"
    run_cco start config-editor --project myproj --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    # G=ro → personal store read-only on BOTH mounts; the wholesale :ro operator bucket
    # also covers ~/.cco/.claude (B3), so global .cco authoring is not writable either
    # (A-V3: claude follows G → repo in project mode). No separate .claude re-overlay is
    # needed here (that only fires when the store is rw but claude!=all — impossible for
    # config-editor now that claude follows G).
    assert_file_contains "$compose" "$HOME/.cco:/workspace/cco-config:ro" || return 1
    assert_file_contains "$compose" "$HOME/.cco:/home/claude/.cco:ro" || return 1
    # edit-global widens G→rw → store writable again on both mounts, no :ro.
    run_cco start config-editor --project myproj --cco-access edit-global --dry-run --dump
    compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_not_contains "$compose" "$HOME/.cco:/workspace/cco-config:ro" || return 1
    assert_file_not_contains "$compose" "$HOME/.cco:/home/claude/.cco:ro" || return 1
}

# D9 / ADR-0044 §3: the config-editor's editable targets must be surfaced to the
# session (env CCO_CONFIG_TARGETS + the ADR-0047 R2 descriptor) so the in-container
# ownership predicate (_env_is_current_project) classifies them as "current" (Pc).
# Regression guard for the _ce_targets variable-scope bug (was local to
# _start_resolve_project → invisible to compose-gen → CCO_CONFIG_TARGETS silently
# empty → B5 could not tag/show a config-editor target).
test_config_editor_project_mode_emits_config_targets() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "myproj" "$(minimal_project_yml myproj)"
    run_cco start config-editor --project myproj --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_contains "$compose" "CCO_CONFIG_TARGETS=myproj" || return 1
}

# Global mode (bare, outside any project) has NO editable project targets, so no
# CCO_CONFIG_TARGETS is emitted (an empty CSV would be misleading).
test_config_editor_global_mode_emits_no_config_targets() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    cd "$tmpdir"   # outside any project → global mode
    run_cco start config-editor --dry-run --dump
    assert_file_not_contains "$DRY_RUN_DIR/.cco/docker-compose.yml" "CCO_CONFIG_TARGETS="
}

test_config_editor_project_mode_unknown_target_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    run_cco start config-editor --project ghost --dry-run --dump || true
    assert_output_contains "not resolvable"
}

# ── Reserved name ─────────────────────────────────────────────────────

test_config_editor_name_reserved_for_init() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local repo="$tmpdir/somerepo"; mkdir -p "$repo"
    local prev; prev="$(pwd)"
    cd "$repo" || return 1
    run_cco init --name config-editor || true
    cd "$prev" || return 1
    assert_output_contains "reserved"
}

# ── Preset + wrapped-cco (ADR-0036 step 5) ────────────────────────────

# config-editor (bare, outside any project → global mode, ADR-0044 §3) resolves to
# claude=all / cco=edit-global and gets the operator env + the ~/.cco operator
# bucket mount (wrapped-cco).
test_config_editor_preset_emits_operator() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    cd "$tmpdir"   # outside any project → global mode (rw,none,none): edit ~/.cco only
    run_cco start config-editor --dry-run
    assert_output_contains "claude=repo=ro,current=ro,global=rw,others=ro cco=global=rw,current=none,others=none"
    run_cco start config-editor --dry-run --dump
    assert_file_contains "$DRY_RUN_DIR/.cco/docker-compose.yml" "CCO_CONTAINER_OPERATOR=1" || return 1
    assert_file_contains "$DRY_RUN_DIR/.cco/docker-compose.yml" "CCO_CCO_ACCESS=global=rw,current=none,others=none" || return 1
    # ~/.cco also mounted at the operator path for in-container cco resolution.
    assert_file_contains "$DRY_RUN_DIR/.cco/docker-compose.yml" "$HOME/.cco:/home/claude/.cco" || return 1
}

# A global ~/.cco/access.yml must NOT neuter the config-editor preset.
test_config_editor_global_access_does_not_override_preset() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    printf 'cco: none\nclaude: none\n' > "$HOME/.cco/access.yml"
    cd "$tmpdir"
    run_cco start config-editor --dry-run
    assert_output_contains "claude=repo=ro,current=ro,global=rw,others=ro cco=global=rw,current=none,others=none"
}

# An explicit CLI flag CAN narrow the preset default. Narrowing to a read level is
# coherent (no target needed), so it does not trip the F4 edit-project guard. The
# config-editor G>=ro clamp raises read-project (G=none) to read-global (G=ro) — the
# authoring tool must always SEE the store (WS-A / ADR-0044 §2 analogy).
test_config_editor_cli_narrows_preset() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    cd "$tmpdir"
    run_cco start config-editor --cco-access read-project --dry-run
    assert_output_contains "cco=read-global"
}

# F4: an explicit --cco-access edit-project OUTSIDE any project (no --project) leaves
# the session with nothing to edit (G=none rules out ~/.cco, no <repo>/.cco mounted).
# The guard must fail loud with actionable guidance, not launch an inert session.
test_config_editor_edit_project_outside_project_dies() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    cd "$tmpdir"   # outside any project
    run_cco start config-editor --cco-access edit-project --dry-run
    local rc=$?
    [[ $rc -ne 0 ]] || fail "expected config-editor --cco-access edit-project to fail outside a project"
    assert_output_contains "needs a project to edit"
}

# Positive regression: --cco-access edit-project WITH a resolvable --project target is
# coherent (the project is mounted) → the guard does not fire.
test_config_editor_edit_project_with_project_ok() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "myproj" "$(minimal_project_yml myproj)"
    cd "$tmpdir"
    # edit-project (none,rw,none) is clamped to (ro,rw,none) by the config-editor
    # G>=ro floor; the target is mounted so the guard does not fire.
    run_cco start config-editor --project myproj --cco-access edit-project --dry-run
    assert_output_contains "cco=global=ro,current=rw,others=none"
}

# Real secrets masked on the personal store + target config mounts.
test_config_editor_masks_secrets_on_config_mounts() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    printf 'G=1\n' > "$HOME/.cco/secrets.env"
    create_project "$tmpdir" "myproj" "$(minimal_project_yml myproj)"
    printf 'S=1\n' > "$tmpdir/repos/myproj/.cco/secrets.env"
    run_cco start config-editor --project myproj --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_contains "$compose" "secret-mask:/workspace/cco-config/secrets.env:ro" || return 1
    assert_file_contains "$compose" "secret-mask:/workspace/myproj-config/secrets.env:ro" || return 1
    # RC-1 T7: masking runs from _op_config_masks, a branch independent of the
    # nested clamp, and emits a DEEPER child mount — so it must survive the target
    # becoming genuinely writable. Assert the writability in the same test, or this
    # stays a mask over a read-only tree and proves nothing about the fix.
    if grep -qE ':/workspace/myproj-config(/\.)?:ro"' "$compose"; then
        fail "secret masking must not depend on the target being clamped :ro"
    fi
}

# ── --all / repeatable --project scope (ADR-0036 D-α) ─────────────────

test_config_editor_all_mounts_every_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "proj-a" "$(minimal_project_yml proj-a)"
    create_project "$tmpdir" "proj-b" "$(minimal_project_yml proj-b)"
    # --all is the explicit broad widener → edit-all (ADR-0044 §3).
    run_cco start config-editor --all --dry-run
    assert_output_contains "cco=edit-all" || return 1
    run_cco start config-editor --all --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_contains "$compose" ":/workspace/proj-a-config" || return 1
    assert_file_contains "$compose" ":/workspace/proj-b-config" || return 1
}

test_config_editor_repeatable_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "proj-a" "$(minimal_project_yml proj-a)"
    create_project "$tmpdir" "proj-b" "$(minimal_project_yml proj-b)"
    create_project "$tmpdir" "proj-c" "$(minimal_project_yml proj-c)"
    run_cco start config-editor --project proj-a --project proj-c --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_contains "$compose" ":/workspace/proj-a-config" || return 1
    assert_file_contains "$compose" ":/workspace/proj-c-config" || return 1
    assert_file_not_contains "$compose" ":/workspace/proj-b-config" || return 1
}

# Only <repo>/.cco is mounted, never a full code repo.
test_config_editor_all_mounts_only_cco() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "proj-a" "$(minimal_project_yml proj-a)"
    run_cco start config-editor --all --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    # target mounts always end in /.cco (source) → /workspace/<name>-config.
    assert_file_contains "$compose" "/.cco:/workspace/proj-a-config" || return 1
}

# ── Minimum-privilege-by-default UX (ADR-0044 §3) ─────────────────────

# Bare `config-editor` OUTSIDE any project → global mode: (rw,none,none), edit ~/.cco
# ONLY, NO project overlays (project-less → Pc honestly none). --all is the explicit
# widener (not the default).
test_config_editor_bare_outside_project_is_global() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "proj-a" "$(minimal_project_yml proj-a)"
    create_project "$tmpdir" "proj-b" "$(minimal_project_yml proj-b)"
    cd "$tmpdir"   # outside any project
    run_cco start config-editor --dry-run
    assert_output_contains "cco=global=rw,current=none,others=none" || return 1
    run_cco start config-editor --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_not_contains "$compose" ":/workspace/proj-a-config" || return 1
    assert_file_not_contains "$compose" ":/workspace/proj-b-config" || return 1
}

# Bare `config-editor` INSIDE a project → cwd-scoped project mode: (ro,rw,none) — edit
# that project's .cco + its repos, READ the whole store to reference, NOT other projects
# (WS-A: project mode is min-privilege (ro,rw,none), not edit-global; --cco-access
# edit-global widens to write ~/.cco).
test_config_editor_bare_in_project_is_cwd_scoped() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "myproj" "$(minimal_project_yml myproj)"
    create_project "$tmpdir" "other" "$(minimal_project_yml other)"
    cd "$tmpdir/repos/myproj"   # inside myproj's repo
    run_cco start config-editor --dry-run
    assert_output_contains "cco=global=ro,current=rw,others=none" || return 1
    run_cco start config-editor --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_contains "$compose" ":/workspace/myproj-config" || return 1
    assert_file_not_contains "$compose" ":/workspace/other-config" || return 1
}

# --project narrows AND mounts that project's repos (repo-aware config authoring).
test_config_editor_project_mounts_repos() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "myproj" "$(minimal_project_yml myproj)"
    create_project "$tmpdir" "other" "$(minimal_project_yml other)"
    run_cco start config-editor --project myproj --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    # myproj's config + its repo (dummy-repo) mounted; other narrowed out.
    assert_file_contains "$compose" ":/workspace/myproj-config" || return 1
    assert_file_contains "$compose" "$CCO_DUMMY_REPO:/workspace/dummy-repo" || return 1
    assert_file_not_contains "$compose" ":/workspace/other-config" || return 1
}

# --repo mounts a single resolvable repo on top of the current scope.
test_config_editor_repo_flag_mounts_one_repo() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    cd "$tmpdir"
    run_cco start config-editor --repo dummy-repo --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_contains "$compose" "$CCO_DUMMY_REPO:/workspace/dummy-repo" || return 1
}

test_config_editor_repo_flag_unknown_fails() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    cd "$tmpdir"
    run_cco start config-editor --repo ghost-repo --dry-run --dump || true
    assert_output_contains "not resolvable"
}

# ── RC-1: the nested-config clamp must not swallow the mount ROOT ─────
#
# The lane's mount-generation rule (01-test-lane.md §3.6): every mount-generation
# fix asserts BOTH the line that must appear AND the line that must not. RC-1 is a
# SPURIOUS :ro line — the correct rw bind for the target's .cco is emitted today and
# then clobbered by a second bind one line below it — so a presence-only assertion
# passes with the bug in place.

# T1 (defect a). _find_nested_config_dirs used to return its own search root as
# rel ".", and a config-editor target's mount SOURCE is a .cco directory, so the
# `.cco carries a project.yml` qualification resolved against `<repo>/.cco/./project.yml`
# and re-bound the whole editing target :ro. Docker orders binds by destination
# depth, so the `/.` child won and criterion D failed in 2 of 3 modes.
test_config_editor_project_mode_target_not_self_clamped() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "cave" "$(minimal_project_yml cave)"
    cd "$tmpdir"   # neutral cwd: the target comes from --project, not from cwd
    run_cco start config-editor --project cave --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    # The line that MUST appear — present today, which is exactly why it cannot be
    # the only assertion.
    assert_file_contains "$compose" "$tmpdir/repos/cave/.cco:/workspace/cave-config" || return 1
    # The line that must NOT appear: the self-match overlay.
    assert_file_not_contains "$compose" "$tmpdir/repos/cave/.cco/.:/workspace/cave-config/.:ro" || return 1
    # Nothing under the target may be :ro except the secret masks (a deliberate,
    # deeper child mount that must keep winning — see the masking test).
    local _bad
    _bad=$(grep -E ':/workspace/cave-config[^"]*:ro"' "$compose" | grep -v 'secret-mask' || true)
    [[ -z "$_bad" ]] || fail "unexpected :ro bind under a writable target: $_bad"
    return 0
}

# T6 (defect a, --all). E6B measured 7/7 targets read-only in --all mode.
test_config_editor_all_mode_targets_writable() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "proj-a" "$(minimal_project_yml proj-a)"
    create_project "$tmpdir" "proj-b" "$(minimal_project_yml proj-b)"
    cd "$tmpdir"
    run_cco start config-editor --all --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_contains "$compose" "$tmpdir/repos/proj-a/.cco:/workspace/proj-a-config" || return 1
    assert_file_contains "$compose" "$tmpdir/repos/proj-b/.cco:/workspace/proj-b-config" || return 1
    assert_file_not_contains "$compose" "$tmpdir/repos/proj-a/.cco/.:/workspace/proj-a-config/.:ro" || return 1
    assert_file_not_contains "$compose" "$tmpdir/repos/proj-b/.cco/.:/workspace/proj-b-config/.:ro" || return 1
    return 0
}

# T15 (§3.5, the escalation guard). The self-clamp T1 removes was, accidentally,
# the ONLY physical enforcement of Pc=ro on a config-editor target — the generated
# mount hardcoded `readonly: false`. Removing it without deriving the root flag from
# Pc would ship a privilege ESCALATION inside a privilege-correctness fix. Pc=ro is
# reachable: not as a preset, but the granular --cco-access form is a shipped surface
# and the ADR-0048 conditional INV-2 floor only guarantees Pc >= ro.
#
# BOTH assertions matter: the first is the property, the second proves it is
# delivered by `readonly:` and not by the accident being removed.
test_config_editor_target_readonly_follows_pc() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "myproj" "$(minimal_project_yml myproj)"
    cd "$tmpdir"
    run_cco start config-editor --project myproj \
        --cco-access global=rw,current=ro,others=none --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    # Pc=ro → the target mount ROOT is honestly read-only …
    assert_file_contains "$compose" "$tmpdir/repos/myproj/.cco:/workspace/myproj-config:ro" || return 1
    # … and it is the mount's own readonly: flag that says so, not the self-clamp.
    assert_file_not_contains "$compose" "$tmpdir/repos/myproj/.cco/.:/workspace/myproj-config/.:ro" || return 1
    # The counterweight, in the same test so the property is asserted in BOTH
    # directions: at Pc=rw (every shipped config-editor mode) the same resolver
    # leaves the target writable. Without it, "follows Pc" would also be satisfied
    # by pinning every target :ro.
    run_cco start config-editor --all --dry-run --dump
    compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_contains "$compose" "$tmpdir/repos/myproj/.cco:/workspace/myproj-config" || return 1
    assert_file_not_contains "$compose" "$tmpdir/repos/myproj/.cco:/workspace/myproj-config:ro" || return 1
    return 0
}

# ── RC-1 defect (b): the extra_mount clamp must read the session triple ──
#
# At the DEFAULT config_access_policy the branch hard-coded both modes, so a
# framework-synthetic config mount was pinned :ro no matter what the session
# resolved. Its two sibling call sites in the same function do consult the triple
# — the repo branch via _committed_ro, the operator bucket via _b3_auth_mode —
# which is how one host tree ended up with two container views in opposite modes
# (~/.cco/.claude rw at /home/claude/.cco/.claude, :ro at
# /workspace/cco-config/.claude). That is E6B-02's contradiction table.
#
# ~/.cco/.claude is a GENUINE nested dir at depth 1, not a self-match, so the
# -mindepth 1 fix alone does not reach it.

# T2 — the store's own .claude authoring tree, global mode (G=rw, Cg=rw).
test_config_editor_global_mode_store_claude_writable() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    mkdir -p "$HOME/.cco/.claude"
    cd "$tmpdir"   # neutral cwd → global mode (rw,none,none)
    run_cco start config-editor --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    # The line that MUST appear: the store itself, writable.
    assert_file_contains "$compose" "$HOME/.cco:/workspace/cco-config" || return 1
    assert_file_not_contains "$compose" "$HOME/.cco:/workspace/cco-config:ro" || return 1
    # The line that must NOT appear: the clamp over its .claude, at Cg=rw.
    assert_file_not_contains "$compose" "$HOME/.cco/.claude:/workspace/cco-config/.claude:ro" || return 1
    return 0
}

# T3 — the same defect on the store's TEMPLATE .claude trees. No e2e session
# reported this one: config-editor could not author project-template Claude
# content at G=rw either. Same root, same fix.
test_config_editor_global_mode_store_template_claude_writable() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local tpl="$HOME/.cco/templates/project/base/.claude"; mkdir -p "$tpl"
    cd "$tmpdir"
    run_cco start config-editor --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    assert_file_contains "$compose" "$HOME/.cco:/workspace/cco-config" || return 1
    assert_file_not_contains "$compose" \
        "$tpl:/workspace/cco-config/templates/project/base/.claude:ro" || return 1
    return 0
}

# T4 — the two defects together, and the strongest regression guard in the set:
# --cco-access edit-global with a named target is the only SHIPPED configuration
# where G=rw and Pc=rw coexist, so both the store tree and the target tree must be
# physically writable at once.
test_config_editor_edit_global_project_mode_both_trees_writable() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    mkdir -p "$HOME/.cco/.claude"
    create_project "$tmpdir" "myproj" "$(minimal_project_yml myproj)"
    mkdir -p "$tmpdir/repos/myproj/.cco/claude"
    cd "$tmpdir"
    run_cco start config-editor --project myproj --cco-access edit-global --dry-run --dump
    local compose="$DRY_RUN_DIR/.cco/docker-compose.yml"
    # (b) the store's .claude, at Cg=rw.
    assert_file_contains "$compose" "$HOME/.cco:/workspace/cco-config" || return 1
    assert_file_not_contains "$compose" "$HOME/.cco/.claude:/workspace/cco-config/.claude:ro" || return 1
    # (a) the target's committed .cco, at Pc=rw.
    assert_file_contains "$compose" "$tmpdir/repos/myproj/.cco:/workspace/myproj-config" || return 1
    assert_file_not_contains "$compose" "$tmpdir/repos/myproj/.cco/.:/workspace/myproj-config/.:ro" || return 1
    return 0
}
