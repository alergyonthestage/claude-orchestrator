#!/usr/bin/env bash
# tests/test_dev_protection.sh — developer execution mode: PROTECTION (A10.2, wave 1)
#
# Contract source: ADR-0060 D4 (its nine numbered points), D5, D6 + the living
# design `docs/maintainers/engineering/design/dev-execution-mode.md` §2 (R3/R4/R5)
# and §5 — 5.0 (where the store lives), 5.0b (no-op vs failure), 5.1 (restore),
# 5.2 (the <repo>/.cco guard). Every assertion below is derived from those
# documents, never from the code: A10.2 was written from the design while the
# implementation was being written independently.
#
# What wave 1 owns — and only this:
#   - the unconditional pre-verb snapshot of ~/.cco into its own store   (§5, D4.1-5)
#   - `cco dev restore`                                                  (§5.1, D4.6)
#   - the `<repo>/.cco` restorability guard, and `cco project save`'s
#     exemption from it                                                  (§5.2, D4.8)
#   - the migration routing away from the real CONFIG                    (D5)
# `cco dev seed|list|reset`, the fixtures (§7), `project.dev.yml` (§7.1), the
# `cco start` build-ref warn (§6.2) and `clean --images` (§8) are NOT asserted here.
#
# ── Oracles, and why the obvious ones are refused ────────────────────
#   * The snapshot is read through PLAIN git against the store's GIT_DIR — never
#     through `cco config history`, which reads ~/.cco/.git and by D4.2 must not
#     see this store at all.
#   * "Was the snapshot taken BEFORE the verb" is answered by CONTENT, not by
#     message ordering: a verb that writes into ~/.cco runs, and its own output
#     file must be ABSENT from the commit that the same run produced. Interleaving
#     two streams would answer a question about buffering instead.
#   * The exclusions are asserted on the FIRST commit's CONTENTS — the design flags
#     the alternative as a false pass in waiting: "a test asserting the exclusions
#     exist would pass on a store whose first commit already contained secrets.env".
#     Every exclusion row here reads the ROOT commit (`rev-list --max-parents=0`)
#     of a store that has more than one, so a late-written info/exclude cannot hide.
#   * A guard is measured by NEUTRALISING it: every refusal row is paired with a
#     control that must PROCEED (a clean committed unit, and the same unit without
#     `--dev`), because "refuse everything" passes any refusal-only test.
#   * `docker run` is never used (in-session it returns rc 0 with empty stdout,
#     FI-82) and no test here needs a daemon.
#
# ── Environment traps this file is written against ───────────────────
#   * This suite runs INSIDE cco's own self-dev container, so `/.dockerenv` exists
#     and `--dev` would take its in-container refusal (§6.1). Host mode is FORCED
#     with CCO_IN_CONTAINER=0 in `_dp_env`; without it every test here would refuse
#     in the container and pass on a real host.
#   * `setup_cco_env` exports absolute CCO_{STATE,DATA,CACHE}_HOME, and
#     `_cco_apply_dev_sandbox` never clobbers an explicit override — so the BUCKETS
#     do not move under `--dev` here. That is deliberate: the fixtures' index seeds
#     stay visible, and the snapshot store (which is NOT a bucket, §5.0) is the only
#     thing this file measures under the dev root.
#   * `_cco_config_dir` CREATES ~/.cco. §5.0b's first row is therefore only
#     reachable while the step probes existence itself; the row is asserted on what
#     the user sees (a note, no store, the verb still ran), never on that call.
#   * A worktree's `.git` is a regular FILE, not a directory (ADR-0060 A5) — §5.2's
#     "not a git work tree" and "never committed" rows are built with a real
#     `git worktree add` so a `-d .git` probe is visible as a misclassification.
#
# ⚠ tests/test_dev_sandbox.sh is NOT touched: design §9 pins
# `test_dev_sandbox_config_stays_shared` as the check that the CONFIG default did
# not move, and this design does not fork CONFIG.

# ── Fixtures ─────────────────────────────────────────────────────────

# The standard env for a dev-mode run: the suite's decentralized fixture env, host
# mode forced, and an identity-matching dev target so `--dev` ENGAGES IN PLACE
# (design §3.3) instead of exec'ing somewhere. Every dev knob this file does not
# set explicitly is cleared, so no row inherits a previous one's dev root.
_dp_env() {
    setup_cco_env "$1"
    export CCO_IN_CONTAINER=0
    export CCO_DEV_REPO="$REPO_ROOT"
    unset CCO_DEV CCO_DEV_ROOT CCO_DEV_SANDBOX CCO_DEV_SANDBOX_SEED \
          CCO_DEV_SANDBOX_ROOT CCO_DEV_DISPATCHED CCO_CONFIG_HOME 2>/dev/null || true
}

# The dev root, as the DESIGN spells it (§5.0): CCO_DEV_ROOT is the preferred name,
# CCO_DEV_SANDBOX_ROOT the superseded alias, and the default path does not move.
_dp_dev_root() {
    printf '%s' "${CCO_DEV_ROOT:-${CCO_DEV_SANDBOX_ROOT:-$HOME/.cco-devsandbox}}"
}
# §5.0: a SIBLING of the three redirected buckets, never a child of state/.
_dp_store() { printf '%s' "$(_dp_dev_root)/snapshots/config.git"; }

# Plain-git readers over the store. `--git-dir` wins over any enclosing repository,
# so these are safe from a cwd anywhere (the suite runs inside the cco clone).
_dp_git()     { git --git-dir="$(_dp_store)" "$@" 2>/dev/null; }
_dp_commits() { local n; n=$(_dp_git rev-list --count HEAD) || n=0; printf '%s' "${n:-0}"; }
_dp_tree()    { _dp_git ls-tree -r --name-only "${1:-HEAD}"; }
_dp_subject() { _dp_git log -1 --format=%s "${1:-HEAD}"; }
# The FIRST commit — the one the exclusion ordering is asserted on.
_dp_root_commit() { _dp_git rev-list --max-parents=0 HEAD | head -1; }

# A realistic ~/.cco. It deliberately carries:
#   - access.yml and claude-version — the two members `_CONFIG_ALLOWLIST` omits
#     (measured: lib/cmd-config.sh:37-39), i.e. the two with no other recovery path.
#     They are what discriminates `git add -A` from an allowlist-shaped snapshot;
#   - every secret shape §5's exclusion row names, one of them NESTED, so a
#     top-level-only exclude is visible;
#   - secrets.env.example, which is NOT a secret and must survive — the control
#     against an over-broad pattern that swallows the skeleton too.
_dp_seed_config() {
    local cfg="$HOME/.cco"
    mkdir -p "$cfg/.claude/rules" "$cfg/packs/demo" "$cfg/templates/base"
    printf '# global\n'          > "$cfg/.claude/CLAUDE.md"
    printf '# style\n'           > "$cfg/.claude/rules/style.md"
    printf 'cco: read-project\n' > "$cfg/access.yml"
    printf 'latest\n'            > "$cfg/claude-version"
    printf 'name: demo\n'        > "$cfg/packs/demo/pack.yml"
    printf 'name: base\n'        > "$cfg/templates/base/template.yml"
    printf 'TOKEN=shh\n'         > "$cfg/secrets.env"
    printf 'A=1\n'               > "$cfg/other.env"
    printf 'kkk\n'               > "$cfg/id.key"
    printf 'ppp\n'               > "$cfg/cert.pem"
    printf 'NESTED=1\n'          > "$cfg/packs/demo/nested.env"
    printf 'TOKEN=\n'            > "$cfg/secrets.env.example"
}

# Run bin/cco capturing STDERR ONLY into $_DP_ERR (rc into $_DP_RC). `run_cco`
# FUSES the two streams; the note/no-note rows of §5.0b are questions about what
# was said on stderr, and a fused stream would let stdout answer them.
_dp_cco_err() {
    _DP_RC=0
    _DP_ERR=$(
        CCO_USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR" CCO_PACKS_DIR="$CCO_PACKS_DIR" \
        CCO_TEMPLATES_DIR="$CCO_TEMPLATES_DIR" CCO_LLMS_DIR="$CCO_LLMS_DIR" \
        bash "$REPO_ROOT/bin/cco" "$@" 2>&1 >/dev/null
    ) || _DP_RC=$?
}

# The `note:` lines of the last _dp_cco_err, with $HOME collapsed to `~` so two
# rows run from different throwaway homes are comparable line by line.
_dp_notes() { printf '%s\n' "$_DP_ERR" | grep -E '^note:' | sed "s|$HOME|~|g" | sort; }

# Run bin/cco from a given cwd — cwd-first unit resolution is part of §5.2's
# contract, so it cannot be faked. Sets CCO_OUTPUT; returns cco's rc.
_dp_cco_in() {
    local dir="$1"; shift
    local rc=0
    CCO_OUTPUT=$(cd "$dir" && \
        CCO_USER_CONFIG_DIR="$CCO_USER_CONFIG_DIR" CCO_PACKS_DIR="$CCO_PACKS_DIR" \
        CCO_TEMPLATES_DIR="$CCO_TEMPLATES_DIR" CCO_LLMS_DIR="$CCO_LLMS_DIR" \
        bash "$REPO_ROOT/bin/cco" "$@" 2>&1) || rc=$?
    return $rc
}

# A <repo>/.cco project unit. `unit` is the directory HOLDING .cco — which is not
# necessarily the git top level (the nested rows below depend on that).
_dp_write_unit() {
    local unit="$1" name="$2"
    mkdir -p "$unit/.cco/claude"
    printf 'name: %s\nrepos:\n  - name: self\n' "$name" > "$unit/.cco/project.yml"
    printf '# rules\n' > "$unit/.cco/claude/keep.md"
    # The D7 barrier `cco project save` requires (the scaffold's own set, mirrored
    # from tests/test_project_save.sh's `_ps_gitignore`); harmless for the other
    # writers, and load-bearing for the exemption test — an incomplete barrier makes
    # `project save` refuse for a reason that has nothing to do with D4.8.
    printf 'secrets.env\n*.env\n*.key\n*.pem\n.credentials.json\n!secrets.env.example\n' \
        > "$unit/.cco/.gitignore"
}

# git init + commit everything under <gitroot>. Identity comes from the redirected
# HOME's .gitconfig (setup_cco_env writes one), as the rest of the suite does.
_dp_git_commit_all() {
    local root="$1" msg="${2:-seed}"
    git -C "$root" add -A >/dev/null 2>&1
    git -C "$root" commit -qm "$msg" >/dev/null 2>&1
}
_dp_git_repo() { git init -q "$1" >/dev/null 2>&1; }

# The five §5.2 shapes plus their two controls, each built as a repo whose UNIT dir
# is echoed by the caller's own knowledge of the layout. `state` is one of:
#   clean   — a git repo, .cco committed and clean            (control: PROCEED)
#   dirty   — committed, then .cco modified                   (refuse: condition 3)
#   never   — a git repo with other commits, .cco never added (refuse: condition 2)
#   ignored — .cco covered by the repo's .gitignore           (refuse: condition 2)
#   nogit   — a plain directory                               (refuse: condition 1)
# Usage: _dp_unit <root> <name> <state>   → the unit dir is "$root"
_dp_unit() {
    local root="$1" name="$2" state="$3"
    mkdir -p "$root"
    case "$state" in
        nogit)
            _dp_write_unit "$root" "$name" ;;
        never)
            _dp_git_repo "$root"
            printf 'code\n' > "$root/src.txt"
            _dp_git_commit_all "$root" "code only"
            _dp_write_unit "$root" "$name" ;;
        ignored)
            _dp_git_repo "$root"
            printf 'code\n' > "$root/src.txt"
            printf '.cco/\n' > "$root/.gitignore"
            _dp_write_unit "$root" "$name"
            _dp_git_commit_all "$root" "code + ignore" ;;
        clean)
            _dp_git_repo "$root"
            printf 'code\n' > "$root/src.txt"
            _dp_write_unit "$root" "$name"
            _dp_git_commit_all "$root" "config + code" ;;
        dirty)
            _dp_git_repo "$root"
            printf 'code\n' > "$root/src.txt"
            _dp_write_unit "$root" "$name"
            _dp_git_commit_all "$root" "config + code"
            printf '# edited after the commit\n' >> "$root/.cco/project.yml" ;;
        *) return 1 ;;
    esac
    return 0
}

# `cco project add` — the writer driven by most §5.2 rows. Chosen because it is
# cwd-first, needs no daemon and no index write, and its effect on <repo>/.cco is a
# single observable line in project.yml. Returns cco's rc; CCO_OUTPUT is set.
_dp_writer_add() { _dp_cco_in "$1" --dev project add repo probe --url https://ex.com/p.git; }
# Did that writer actually write?
_dp_add_landed() { grep -q 'name: probe' "$1/.cco/project.yml" 2>/dev/null; }

# ── §5 — the snapshot store ──────────────────────────────────────────

# D4.1 / §5's Trigger row: "the step is UNCONDITIONAL — it runs at every
# `cco --dev` engage, before the verb, WHATEVER THE VERB IS. Never a list of verbs."
#
# ⚠ Every verb here is one no config-writing allowlist would ever contain, which is
# the whole point: a test that only exercised a config-writing verb would pass on an
# implementation keyed to a verb list — exactly the defect D4.1 exists to prevent
# ("a named list of config-writing verbs is a lower bound — a class this repo has
# paid for four times").
#
# ⚠ Reported as a TABLE, every row, never fail-fast: the evidence wanted is "the
# step fired for all of these", and a stop-at-first-failure test cannot show which
# verbs an allowlist happened to include.
test_dev_snapshot_fires_for_every_verb_not_a_list() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _dp_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _dp_seed_config

    local bad="" verb n before after
    # Each row CHANGES ~/.cco first, so the commit is due (§5's Trigger row makes the
    # commit conditional on `git status --porcelain`, and only on that).
    for verb in "--version" "whoami" "list"; do
        printf '%s\n' "$verb" > "$HOME/.cco/marker"
        before=$(_dp_commits)
        run_cco --dev "$verb" || true
        after=$(_dp_commits)
        [[ "$after" -eq $(( before + 1 )) ]] \
            || { bad+="  $verb: expected one new snapshot commit, went $before -> $after"$'\n'; continue; }
        # §5's Message row: `dev snapshot before: cco <argv>` — so `cco dev list`
        # reads as a log of what was ABOUT to run.
        n=$(_dp_subject)
        [[ "$n" == *"$verb"* ]] \
            || bad+="  $verb: the snapshot commit must name the argv it ran before, got: '$n'"$'\n'
    done
    [[ -z "$bad" ]] || fail "the snapshot step is not unconditional:"$'\n'"$bad"
}

# §5's Trigger row, the ordering half: "it runs ... BEFORE the verb". Answered by
# CONTENT, not by message order — `cco pack create` writes into ~/.cco/packs, so the
# snapshot that the SAME run produced must not contain what that run created.
#
# The positive control (packs/demo, seeded before the run) is load-bearing: without
# it, a snapshot that captured NOTHING at all would satisfy the negative assertion.
test_dev_snapshot_is_taken_before_the_verb() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _dp_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _dp_seed_config

    local rc=0
    run_cco --dev pack create dp-probe || rc=$?
    [[ "$rc" -eq 0 ]] || fail "cco --dev pack create failed (rc=$rc): $CCO_OUTPUT"
    assert_file_exists "$CCO_PACKS_DIR/dp-probe/pack.yml" \
        "precondition: the verb must have run and written into ~/.cco" || return 1

    local tree; tree=$(_dp_tree)
    [[ "$tree" == *"packs/demo/pack.yml"* ]] \
        || fail "control: the snapshot must have captured the PRE-verb tree, got: $tree"
    [[ "$tree" != *"dp-probe"* ]] \
        || fail "the snapshot must be taken BEFORE the verb — it captured what the verb wrote: $tree"
}

# §5's Scope row: "`git add -A` — NOT `_CONFIG_ALLOWLIST`, which omits access.yml
# and claude-version, the two members with no other recovery path" (D4.3).
#
# ⚠ Those two ARE the discriminating members. Measured against the shipped
# allowlist (lib/cmd-config.sh:37-39 = .gitignore packs templates .claude setup.sh
# setup-build.sh mcp-packages.txt languages secrets.env.example): an
# allowlist-shaped snapshot passes any test that only checks project-ish content,
# so the four allowlisted rows below are the control and the two omitted ones are
# the measurement. Every row is reported.
test_dev_snapshot_scope_is_the_whole_tree_not_the_allowlist() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _dp_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _dp_seed_config

    run_cco --dev whoami || true
    local tree; tree=$(_dp_tree)
    [[ -n "$tree" ]] || fail "no snapshot was taken at all — nothing to measure"

    local bad="" row path why
    for row in "access.yml:OMITTED by _CONFIG_ALLOWLIST — no other recovery path (D4.3)" \
               "claude-version:OMITTED by _CONFIG_ALLOWLIST — no other recovery path (D4.3)" \
               ".claude/CLAUDE.md:allowlisted — the control" \
               ".claude/rules/style.md:allowlisted — the control" \
               "packs/demo/pack.yml:allowlisted — the control" \
               "templates/base/template.yml:allowlisted — the control"; do
        path="${row%%:*}"; why="${row#*:}"
        printf '%s\n' "$tree" | grep -qxF "$path" \
            || bad+="  missing from the snapshot: $path — $why"$'\n'
    done
    [[ -z "$bad" ]] || fail "the snapshot is not the whole tree:"$'\n'"$bad"$'\n'"tree was:"$'\n'"$tree"
}

# 🔴 §5.0b's ordering ruling, and the false pass it names: "`\$GIT_DIR/info/exclude`
# must be written at store init, BEFORE the first `git add -A`. A test that asserts
# the exclusions EXIST would pass on a store whose first commit already contained
# secrets.env."
#
# So this reads the ROOT commit — `rev-list --max-parents=0` — of a store that has
# TWO commits, never HEAD and never the exclude file. An implementation that writes
# info/exclude after its first commit is green on HEAD and red here.
#
# secrets.env.example is the over-broad-pattern control: it is not a secret and must
# survive, in the root commit as in every later one.
test_dev_snapshot_first_commit_already_excludes_secrets() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _dp_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _dp_seed_config

    run_cco --dev whoami || true                       # commit 1 — the root commit
    printf 'second\n' > "$HOME/.cco/marker"
    run_cco --dev whoami || true                       # commit 2 — so root != HEAD

    [[ "$(_dp_commits)" -ge 2 ]] \
        || fail "precondition: two changed runs must produce two commits, got $(_dp_commits)"
    local root; root=$(_dp_root_commit)
    [[ -n "$root" ]] || fail "could not resolve the store's first commit"
    local tree; tree=$(_dp_tree "$root")

    local bad="" row path verdict
    for row in "secrets.env:out"            "other.env:out" \
               "id.key:out"                 "cert.pem:out" \
               "packs/demo/nested.env:out"  "secrets.env.example:in" \
               "access.yml:in"; do
        path="${row%%:*}"; verdict="${row#*:}"
        if printf '%s\n' "$tree" | grep -qxF "$path"; then
            [[ "$verdict" == "in" ]] \
                || bad+="  $path is IN the FIRST commit — the exclusions were written too late (§5.0b)"$'\n'
        else
            [[ "$verdict" == "out" ]] \
                || bad+="  $path is missing from the first commit — the exclusion is over-broad"$'\n'
        fi
    done
    [[ -z "$bad" ]] || fail "the first commit's contents are wrong:"$'\n'"$bad"$'\n'"first commit held:"$'\n'"$tree"
}

# D4.2 / §5's "Never ~/.cco/.git" row. `cco config save`'s contract is explicit —
# "cco never auto-commits" — so a dev run must leave the user's OWN config history
# byte-identical, and `_config_push` (which operates on `$cfg/.git`) must still see
# an unversioned ~/.cco when the only git store in play is the snapshot's.
#
# Both halves are asserted on the real thing rather than on the store's path alone:
# the user repo's HEAD sha and its dirty set, before and after.
test_dev_snapshot_never_touches_the_users_own_config_repo() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _dp_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _dp_seed_config
    # ~/.cco as the user's own versioned store, with one commit and something dirty.
    _dp_git_repo "$HOME/.cco"
    _dp_git_commit_all "$HOME/.cco" "config save"
    printf 'dirty\n' > "$HOME/.cco/access.yml"

    local head_before dirty_before head_after dirty_after
    head_before=$(git -C "$HOME/.cco" rev-parse HEAD 2>/dev/null)
    dirty_before=$(git -C "$HOME/.cco" status --porcelain 2>/dev/null | sort)
    [[ -n "$head_before" && -n "$dirty_before" ]] \
        || fail "precondition: ~/.cco must be a git repo with one commit and a dirty file"

    run_cco --dev whoami || true

    head_after=$(git -C "$HOME/.cco" rev-parse HEAD 2>/dev/null)
    dirty_after=$(git -C "$HOME/.cco" status --porcelain 2>/dev/null | sort)
    assert_equals "$head_before" "$head_after" \
        "a dev run must never commit into ~/.cco/.git (D4.2)" || return 1
    assert_equals "$dirty_before" "$dirty_after" \
        "a dev run must not stage or clean the user's own config working tree (D4.2)" || return 1
    assert_equals "1" "$(git -C "$HOME/.cco" rev-list --count HEAD 2>/dev/null)" \
        "'cco config history' must be unpolluted — no automatic commit (D4.2)" || return 1
    # And the snapshot really was taken — otherwise the three assertions above are
    # satisfied by an implementation that does nothing at all.
    [[ "$(_dp_commits)" -ge 1 ]] \
        || fail "control: the run must still have taken its own snapshot, got $(_dp_commits) commits"
}

# §5.0 / D4.2, the store's own address:
#   - `<dev-root>/snapshots/config.git`, a SIBLING of the three redirected buckets;
#   - never inside `state/` — "the one-shot seed copies over it" is the measured
#     reason, so a store under state/ is both indistinguishable from copied real
#     STATE and entangled with `_cco_dev_sandbox_seed`'s one-shot guard;
#   - never under ~/.cco, which is what makes it STRUCTURALLY unpushable:
#     `_config_push` (lib/cmd-config.sh:283) dies on `[[ -d "$cfg/.git" ]]` and
#     cannot reach any other GIT_DIR.
test_dev_snapshot_store_lives_outside_config_and_outside_state() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _dp_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _dp_seed_config

    run_cco --dev whoami || true

    assert_dir_exists "$(_dp_store)" \
        "the store lives at <dev-root>/snapshots/config.git (§5.0)" || return 1
    assert_dir_not_exists "$(_dp_dev_root)/state/snapshots" \
        "the store is a SIBLING of the buckets, never a child of state/ (§5.0)" || return 1
    # ⚠ The trailing slash is load-bearing: `$HOME/.cco` is a PREFIX of
    # `$HOME/.cco-devsandbox`, so a bare prefix test calls the correct default
    # location a violation (measured against a reference implementation).
    [[ "$(_dp_store)/" != "$HOME/.cco/"* ]] \
        || fail "the store must not live under ~/.cco — that is what makes it unpushable (D4.2)"
    # ⚠ ~/.cco/.git legitimately EXISTS on any machine: `_cco_bootstrap_roots`
    # (lib/migrate.sh:67) git-inits it on first run. So its ABSENCE is not the
    # contract and asserting it would fail against shipped behaviour. The contract
    # is that nothing auto-commits into it — `cco config save` promises "cco never
    # auto-commits" and bootstrap only inits — so any commit there is the pollution
    # of `cco config history` D4.2 forbids.
    local user_commits
    user_commits=$(git --git-dir="$HOME/.cco/.git" rev-list --count --all 2>/dev/null || echo 0)
    assert_equals "0" "${user_commits:-0}" \
        "the snapshot must never commit into ~/.cco/.git (D4.2)" || return 1

    # The behavioural half of "structurally unpushable": `cco config push` reads
    # $cfg/.git and must still find ~/.cco unversioned after the snapshot exists.
    local rc=0
    run_cco config push || rc=$?
    [[ "$rc" -ne 0 ]] \
        || fail "config push must not succeed off the snapshot store: $CCO_OUTPUT"
    assert_output_not_contains "$(_dp_store)" \
        "the push path must not be able to see the snapshot store (D4.2)" || return 1
}

# §5.0's env spelling: CCO_DEV_ROOT is the preferred name, CCO_DEV_SANDBOX_ROOT the
# superseded alias, and ⚠ "the default path does not move" — renaming
# ~/.cco-devsandbox would strand every sandbox that already exists.
# Reported as a table: the evidence wanted is "the preferred name works AND the
# alias still does AND the default is where it always was".
test_dev_snapshot_store_follows_the_dev_root_spellings() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local bad="" row label expect

    # 1. default
    _dp_env "$tmpdir/default"; setup_global_from_defaults "$tmpdir/default"; _dp_seed_config
    run_cco --dev whoami || true
    [[ -d "$HOME/.cco-devsandbox/snapshots/config.git" ]] \
        || bad+="  default: the store must stay under ~/.cco-devsandbox (§5.0: the default does not move)"$'\n'

    # 2. the preferred name
    _dp_env "$tmpdir/preferred"; setup_global_from_defaults "$tmpdir/preferred"; _dp_seed_config
    export CCO_DEV_ROOT="$tmpdir/preferred/altroot"
    run_cco --dev whoami || true
    [[ -d "$tmpdir/preferred/altroot/snapshots/config.git" ]] \
        || bad+="  CCO_DEV_ROOT: the preferred spelling must relocate the store (§5.0)"$'\n'
    [[ ! -d "$HOME/.cco-devsandbox/snapshots/config.git" ]] \
        || bad+="  CCO_DEV_ROOT: a store was ALSO written to the default root"$'\n'
    unset CCO_DEV_ROOT

    # 3. the superseded alias
    _dp_env "$tmpdir/alias"; setup_global_from_defaults "$tmpdir/alias"; _dp_seed_config
    export CCO_DEV_SANDBOX_ROOT="$tmpdir/alias/altroot"
    run_cco --dev whoami || true
    [[ -d "$tmpdir/alias/altroot/snapshots/config.git" ]] \
        || bad+="  CCO_DEV_SANDBOX_ROOT: the superseded alias must still work (§5.0)"$'\n'
    unset CCO_DEV_SANDBOX_ROOT

    [[ -z "$bad" ]] || fail "the store does not follow the dev-root spellings:"$'\n'"$bad"
}

# §5.0b, all three rows, ⚠ REPORTED TOGETHER. The evidence wanted is "this row
# behaves differently from the others" — an absent ~/.cco is a no-op with a note, a
# broken store is FATAL, an unchanged tree is a silent success — and a fail-fast
# test structurally cannot show that one row moved while the others did not.
#
# 🔴 Row B is D4.4's amendment, and it is the one an implementation is most likely to
# get wrong in the safe-looking direction: `_cco_dev_sandbox_seed` WARNS on a partial
# seed, and this step must DIE. "A partial seed is a convenience, a missing restore
# point IS the protection." The row is measured by whether the VERB RAN, not by the
# message: a `warn`-shaped implementation still creates the pack.
#
# Row A vs row C's message contract is asserted DIFFERENTIALLY — row A must say
# something on stderr that row C does not — so it measures "a note here, silence
# there" without pinning either wording. A wording match would go green on the
# banners `--dev` already prints.
test_dev_snapshot_noop_die_and_silent_success_rows() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local bad="" notes_a notes_c

    # ── Row A: ~/.cco does not exist ⇒ no-op + note, NOT a failure ────
    _dp_env "$tmpdir/a"
    rm -rf "$HOME/.cco"                       # setup_cco_env creates packs/ under it
    _dp_cco_err --dev whoami
    [[ "$_DP_RC" -eq 0 ]] \
        || bad+="  A (~/.cco absent): must be a no-op, not a failure — got rc=$_DP_RC: $_DP_ERR"$'\n'
    [[ ! -d "$(_dp_store)" ]] \
        || bad+="  A (~/.cco absent): no snapshot store may be created — there is nothing to protect"$'\n'
    notes_a=$(_dp_notes)

    # ── Row C: ~/.cco exists, tree unchanged ⇒ no commit, no message ──
    _dp_env "$tmpdir/c"; setup_global_from_defaults "$tmpdir/c"; _dp_seed_config
    run_cco --dev whoami || true                                  # first run: commits
    local first; first=$(_dp_commits)
    [[ "$first" -ge 1 ]] \
        || bad+="  C: precondition failed — the first changed run took no snapshot"$'\n'
    _dp_cco_err --dev whoami                                      # second: unchanged
    [[ "$_DP_RC" -eq 0 ]] \
        || bad+="  C (unchanged): the step succeeded, so the run must not fail — got rc=$_DP_RC: $_DP_ERR"$'\n'
    [[ "$(_dp_commits)" -eq "$first" ]] \
        || bad+="  C (unchanged): an unchanged tree must not add a commit — went $first -> $(_dp_commits)"$'\n'
    notes_c=$(_dp_notes)

    # A said something about the skipped snapshot that C did not. Wording-free.
    if [[ -n "$notes_a" || -n "$notes_c" ]]; then
        [[ -n "$(comm -23 <(printf '%s\n' "$notes_a") <(printf '%s\n' "$notes_c"))" ]] \
            || bad+="  A vs C: an absent ~/.cco must NOTE the no-op; an unchanged tree must say nothing. Both runs said the same thing:"$'\n'"$notes_a"$'\n'
    else
        bad+="  A vs C: neither run said anything on stderr — the row-A note is missing"$'\n'
    fi

    # ── Row B: the store cannot be initialised ⇒ DIE, and the verb does not run ──
    _dp_env "$tmpdir/b"; setup_global_from_defaults "$tmpdir/b"; _dp_seed_config
    mkdir -p "$(_dp_dev_root)"
    : > "$(_dp_dev_root)/snapshots"          # a FILE where the store's parent must be
    local rc=0
    run_cco --dev pack create dp-notrun || rc=$?
    [[ "$rc" -ne 0 ]] \
        || bad+="  B (store un-initialisable): a failed snapshot is FATAL (D4.4) — got rc=0: $CCO_OUTPUT"$'\n'
    [[ ! -d "$CCO_PACKS_DIR/dp-notrun" ]] \
        || bad+="  B: the run must DIE BEFORE the verb — the pack was created anyway (a warn-shaped snapshot)"$'\n'
    [[ -n "${CCO_OUTPUT:-}" ]] \
        || bad+="  B: a fatal snapshot must say why — it exited silently"$'\n'

    [[ -z "$bad" ]] || fail "§5.0b's rows do not behave as ruled:"$'\n'"$bad"
}

# ── §5.1 — cco dev restore ───────────────────────────────────────────

# §5.1: "checks out the tracked paths over ~/.cco", default `HEAD`.
#
# ⚠ An ordering trap this test pins by BEHAVIOUR rather than by mechanism: restore
# takes its own snapshot first (see the test below), so an implementation that
# resolves `HEAD` AFTER that snapshot would restore the state the user just asked
# to undo — a perfect no-op that looks like success. The assertion is therefore on
# the CONTENT: the file must hold what the pre-mutation snapshot held.
test_dev_restore_defaults_to_head_and_puts_the_files_back() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _dp_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _dp_seed_config

    run_cco --dev whoami || true                       # snapshot the good state
    [[ "$(_dp_commits)" -ge 1 ]] || fail "precondition: no snapshot was taken"

    printf 'CLOBBERED\n' > "$HOME/.cco/access.yml"     # the bad dev write
    printf 'CLOBBERED\n' > "$HOME/.cco/.claude/CLAUDE.md"
    rm -f "$HOME/.cco/claude-version"                  # …and a deletion

    local rc=0
    run_cco dev restore || rc=$?
    [[ "$rc" -eq 0 ]] || fail "cco dev restore failed (rc=$rc): $CCO_OUTPUT"

    assert_file_contains "$HOME/.cco/access.yml" "cco: read-project" \
        "restore must put a clobbered tracked file back (§5.1)" || return 1
    assert_file_contains "$HOME/.cco/.claude/CLAUDE.md" "# global" \
        "restore must reach nested tracked paths too" || return 1
    assert_file_exists "$HOME/.cco/claude-version" \
        "restore must bring back a file the dev run DELETED (§5.1)" || return 1
}

# §5.1: "files CREATED SINCE the snapshot are REPORTED, not deleted, unless
# --clean". Both halves, and the report, in one place — deleting by default and
# reporting nothing are two different defects and each must be visible.
test_dev_restore_reports_new_files_and_only_clean_removes_them() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    local bad="" rc

    # ⚠ The two halves run against SEPARATE dev environments, and that is not
    # tidiness. A restore takes its own safety snapshot first (§5.0b), so after the
    # default run below the store's HEAD is a commit that CONTAINS the new file — it
    # is tracked from then on, and a chained `--clean` would have nothing "created
    # since the snapshot" left to remove. Chaining them would measure that artefact
    # instead of the contract.

    # ── default: reported, not deleted ──
    _dp_env "$tmpdir/keep"; setup_global_from_defaults "$tmpdir/keep"; _dp_seed_config
    run_cco --dev whoami || true
    printf 'new\n' > "$HOME/.cco/appeared-since.txt"
    rc=0; run_cco dev restore || rc=$?
    [[ "$rc" -eq 0 ]] || bad+="  default: cco dev restore failed (rc=$rc): $CCO_OUTPUT"$'\n'
    [[ -f "$HOME/.cco/appeared-since.txt" ]] \
        || bad+="  default: a file created since the snapshot must be REPORTED, not deleted (§5.1)"$'\n'
    [[ "${CCO_OUTPUT:-}" == *"appeared-since.txt"* ]] \
        || bad+="  default: restore must report the files it left behind (§5.1), got: $CCO_OUTPUT"$'\n'

    # ── --clean: removed ──
    _dp_env "$tmpdir/clean"; setup_global_from_defaults "$tmpdir/clean"; _dp_seed_config
    run_cco --dev whoami || true
    printf 'new\n' > "$HOME/.cco/appeared-since.txt"
    rc=0; run_cco dev restore --clean || rc=$?
    [[ "$rc" -eq 0 ]] || bad+="  --clean: cco dev restore --clean failed (rc=$rc): $CCO_OUTPUT"$'\n'
    [[ ! -f "$HOME/.cco/appeared-since.txt" ]] \
        || bad+="  --clean: it is what removes files created since the snapshot (§5.1)"$'\n'

    [[ -z "$bad" ]] || fail "§5.1's created-since handling is wrong:"$'\n'"$bad"
}

# 🔴 A consequence of two rulings meeting, and the defect it caught in a throwaway
# reference implementation before any real code existed: a restore mutates the
# snapshot store (it must read a ref and write the tree back), and D4.4 makes the
# NEXT run's snapshot FATAL if it cannot be taken. So a restore that leaves the
# store in a state where the following `cco --dev <verb>` cannot commit turns a
# recovery into a brick.
#
# Measured shape of that defect: restoring by pointing the store's index at the
# restored ref leaves index and HEAD diverged, and the next snapshot's commit is
# empty — `git commit` exits non-zero and D4.4 turns that into a die.
test_dev_restore_leaves_the_store_usable_for_the_next_run() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _dp_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _dp_seed_config

    run_cco --dev whoami || true
    printf 'CLOBBERED\n' > "$HOME/.cco/access.yml"
    printf 'new\n' > "$HOME/.cco/appeared-since.txt"
    local rc=0
    run_cco dev restore || rc=$?
    [[ "$rc" -eq 0 ]] || fail "precondition: cco dev restore failed (rc=$rc): $CCO_OUTPUT"

    local before; before=$(_dp_commits)
    printf 'after-the-restore\n' > "$HOME/.cco/marker"
    rc=0
    run_cco --dev whoami || rc=$?
    [[ "$rc" -eq 0 ]] \
        || fail "a dev run AFTER a restore must still be able to snapshot (D4.4 makes failure fatal), rc=$rc: $CCO_OUTPUT"
    [[ "$(_dp_commits)" -eq $(( before + 1 )) ]] \
        || fail "the post-restore run must record its own snapshot, went $before -> $(_dp_commits)"
    printf '%s\n' "$(_dp_tree)" | grep -qxF "marker" \
        || fail "the post-restore snapshot must contain the change it was taken for"
}

# §5.1: "--dry-run is the project's existing idiom (`cco clean` has it) and makes
# the destructive preview free." A preview writes NOTHING — the clobbered file is
# still clobbered and the new file is still there — while naming what it would do.
test_dev_restore_dry_run_previews_and_writes_nothing() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _dp_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _dp_seed_config

    run_cco --dev whoami || true
    local before; before=$(_dp_commits)
    printf 'CLOBBERED\n' > "$HOME/.cco/access.yml"
    printf 'new\n' > "$HOME/.cco/appeared-since.txt"

    local rc=0
    run_cco dev restore --dry-run || rc=$?
    [[ "$rc" -eq 0 ]] || fail "cco dev restore --dry-run failed (rc=$rc): $CCO_OUTPUT"
    assert_file_contains "$HOME/.cco/access.yml" "CLOBBERED" \
        "--dry-run must not restore anything (§5.1)" || return 1
    assert_file_exists "$HOME/.cco/appeared-since.txt" \
        "--dry-run must not delete anything" || return 1
    assert_output_contains "access.yml" \
        "--dry-run must preview which files it would restore" || return 1
    # A preview is not a mutation, so it must not push a snapshot either.
    assert_equals "$before" "$(_dp_commits)" \
        "--dry-run must not take a snapshot — it changes nothing (§5.1)" || return 1
}

# §5.1: "It resolves the store from the dev root WITHOUT ENGAGING DEV MODE, so
# `cco dev restore` works from an ordinary shell", and §5.0b: the `cco dev <sub>`
# verbs take no snapshot — EXCEPT restore, "which mutates ~/.cco and therefore takes
# one first, so a restore is itself undoable".
#
# Both halves are load-bearing and both are asserted here because they constrain each
# other: no `--dev` on the command line, yet a new commit whose content is the
# PRE-restore (mutated) tree. Asserting only "a commit appeared" would pass on a
# snapshot taken after the checkout, which would record the restored state and undo
# nothing.
test_dev_restore_needs_no_dev_flag_and_snapshots_itself_first() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _dp_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _dp_seed_config

    run_cco --dev whoami || true
    local before; before=$(_dp_commits)
    printf 'MUTATED-BY-THE-DEV-RUN\n' > "$HOME/.cco/access.yml"

    local rc=0
    run_cco dev restore || rc=$?          # ⚠ NO --dev anywhere on this line
    [[ "$rc" -eq 0 ]] || fail "cco dev restore must work without engaging dev mode (§5.1), rc=$rc: $CCO_OUTPUT"
    [[ "$(_dp_commits)" -eq $(( before + 1 )) ]] \
        || fail "restore must take a snapshot FIRST — a restore is itself undoable (§5.0b), went $before -> $(_dp_commits)"

    # The safety snapshot holds what restore was about to overwrite.
    local saved; saved=$(_dp_git show "HEAD:access.yml")
    [[ "$saved" == *"MUTATED-BY-THE-DEV-RUN"* ]] \
        || fail "the pre-restore snapshot must record the state being undone, got: '$saved'"
    # …and the restore still happened.
    assert_file_contains "$HOME/.cco/access.yml" "cco: read-project" \
        "the restore itself must still have taken effect" || return 1
}

# §5.1: `cco dev restore [<ref>]` — an explicit ref reaches an EARLIER snapshot, not
# only the newest. Without this, "default HEAD" is indistinguishable from "HEAD only".
test_dev_restore_accepts_an_explicit_ref() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    _dp_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    _dp_seed_config

    printf 'GENERATION-1\n' > "$HOME/.cco/access.yml"
    run_cco --dev whoami || true
    local first; first=$(_dp_root_commit)
    [[ -n "$first" ]] || fail "precondition: no first snapshot to name"

    printf 'GENERATION-2\n' > "$HOME/.cco/access.yml"
    run_cco --dev whoami || true
    printf 'GENERATION-3\n' > "$HOME/.cco/access.yml"

    local rc=0
    run_cco dev restore "$first" || rc=$?
    [[ "$rc" -eq 0 ]] || fail "cco dev restore <ref> failed (rc=$rc): $CCO_OUTPUT"
    assert_file_contains "$HOME/.cco/access.yml" "GENERATION-1" \
        "an explicit ref must restore THAT snapshot, not HEAD (§5.1)" || return 1
}

