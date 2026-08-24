#!/usr/bin/env bash
# tests/test_project_save.sh — `cco project save` + the two `history` verbs
# (ADR-0038, design "Project config versioning and the history surface" §6).
#
# Derived from the CONTRACT in that design (T1…T17), not from the implementation:
# what is asserted is what the verbs promise the user, never how they get there.
#
# The one asymmetry every test here exists to protect: <repo>/.cco is a subtree of
# a repository cco does NOT own. So the verb must leave everything outside .cco/
# exactly as it found it — dirty, staged, or untouched — and must refuse rather
# than author a file in someone else's repo.

# The .cco/.gitignore cco's own scaffold writes (_cco_write_project_gitignore).
# The D7 barrier requires it, so a seeded repo carries it unless a test is
# specifically about its absence.
_ps_gitignore() {
    printf 'secrets.env\n*.env\n*.key\n*.pem\n.credentials.json\n!secrets.env.example\n' \
        > "$1/.cco/.gitignore"
}

# Seed a git repo holding a committable <repo>/.cco/ plus one file OUTSIDE it.
# Echoes nothing; the caller knows the path it asked for.
# Usage: _ps_repo <root> <project-name> <repo-name> [<extra-repo-name>...]
_ps_repo() {
    local root="$1" project="$2"; shift 2
    mkdir -p "$root/.cco/claude/rules"
    {
        printf 'name: %s\nrepos:\n' "$project"
        local n
        for n in "$@"; do printf '  - name: %s\n' "$n"; done
    } > "$root/.cco/project.yml"
    _ps_gitignore "$root"
    printf '# style\n' > "$root/.cco/claude/rules/style.md"
    printf 'code\n'    > "$root/src.txt"          # OUTSIDE .cco — must never be committed
    git init -q "$root" 2>/dev/null
}

# Run bin/cco with a working directory (cwd-first resolution is part of the
# contract, so it cannot be faked). Sets CCO_OUTPUT; returns cco's exit code.
# Usage: _ps_cco_in <dir> <argv...>
_ps_cco_in() {
    local dir="$1"; shift
    local rc=0
    CCO_OUTPUT=$(cd "$dir" && bash "$REPO_ROOT/bin/cco" "$@" 2>&1) || rc=$?
    return $rc
}

# The paths in HEAD's commit, one per line.
_ps_head_files() { git -C "$1" show --name-only --format= HEAD 2>/dev/null; }

# ── T1 — only .cco/** is committed ───────────────────────────────────

test_project_save_commits_only_cco() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app

    _ps_cco_in "$r" project save -m "initial" || return 1
    assert_output_contains "saved app/.cco" || return 1

    local files; files=$(_ps_head_files "$r")
    echo "$files" | grep -qF ".cco/project.yml" || { fail "project.yml must be committed"; return 1; }
    echo "$files" | grep -qF ".cco/claude/rules/style.md" || { fail "the claude tree must be committed"; return 1; }
    if echo "$files" | grep -qF "src.txt"; then
        fail "a file outside .cco/ must never be committed (never git add -A)"; return 1
    fi
}

# The sharper half of T1, and the reason the commit carries a pathspec: a file the
# user had ALREADY STAGED before running the verb must be neither committed nor
# unstaged. Committing it would put unrelated work in the config commit; unstaging
# it would silently discard the user's own staging.
test_project_save_leaves_a_pre_staged_file_alone() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    _ps_cco_in "$r" project save -m "initial" || return 1

    printf 'more code\n' >> "$r/src.txt"
    git -C "$r" add -- src.txt
    printf '# more\n' >> "$r/.cco/claude/rules/style.md"

    _ps_cco_in "$r" project save -m "second" || return 1
    if _ps_head_files "$r" | grep -qF "src.txt"; then
        fail "a PRE-STAGED file outside .cco/ must not be swept into the config commit"; return 1
    fi
    git -C "$r" diff --cached --name-only | grep -qF "src.txt" \
        || { fail "the user's own staged file must still be staged after the save"; return 1; }
}

# ── T2 — nothing to save ─────────────────────────────────────────────

test_project_save_nothing_to_save() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    _ps_cco_in "$r" project save -m "initial" || return 1
    local before; before=$(git -C "$r" rev-parse HEAD)

    _ps_cco_in "$r" project save || return 1
    assert_output_contains "already up to date" || return 1
    assert_equals "$before" "$(git -C "$r" rev-parse HEAD)" "no commit may be created" || return 1
}

# ── T3 — a staged secret refuses AND unstages ────────────────────────

test_project_save_blocks_secret_content_and_resets() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    _ps_cco_in "$r" project save -m "initial" || return 1

    printf 'api_key=sk-ant-0123456789abcdef0123\n' >> "$r/.cco/claude/rules/style.md"
    local rc=0; _ps_cco_in "$r" project save -m "leak" || rc=$?
    assert_rc 1 "$rc" "a staged secret must refuse the save" || return 1
    assert_output_contains "refusing to save" || return 1

    # The staged set must be RESET, not left staged for the next unrelated commit
    # to pick up — a refusal that leaves the leak staged has made things worse.
    local staged; staged=$(git -C "$r" diff --cached --name-only)
    assert_empty "$staged" "the refusal must leave nothing staged" || return 1
}

# The scan is scoped to .cco/: a secret the user staged ELSEWHERE is not this
# verb's business, and refusing over a file it was never going to commit would be
# a false refusal.
test_project_save_ignores_a_secret_staged_outside_cco() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    _ps_cco_in "$r" project save -m "initial" || return 1

    printf 'api_key=sk-ant-0123456789abcdef0123\n' > "$r/leak.txt"
    git -C "$r" add -f -- leak.txt
    printf '# more\n' >> "$r/.cco/claude/rules/style.md"

    _ps_cco_in "$r" project save -m "second" || return 1
    assert_output_contains "saved app/.cco" || return 1
    if _ps_head_files "$r" | grep -qF "leak.txt"; then
        fail "the out-of-scope file must not be committed either"; return 1
    fi
}

# The refusal's reset is SCOPED too. A bare `git reset` would clear the whole
# index — silently discarding staging the user did themselves, as the side effect
# of a verb that refused to do anything. The twin can afford the bare form; here
# it destroys work in a repo cco does not own.
test_project_save_refusal_keeps_the_users_own_staging() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    _ps_cco_in "$r" project save -m "initial" || return 1

    printf 'more code\n' >> "$r/src.txt"
    git -C "$r" add -- src.txt                                    # the user's own staging
    printf 'api_key=sk-ant-0123456789abcdef0123\n' >> "$r/.cco/claude/rules/style.md"

    local rc=0; _ps_cco_in "$r" project save -m "leak" || rc=$?
    assert_rc 1 "$rc" "the staged secret must refuse the save" || return 1
    git -C "$r" diff --cached --name-only | grep -qF "src.txt" \
        || { fail "the refusal must not unstage the user's unrelated work"; return 1; }
}

# ── T4 — *.example is exempt ─────────────────────────────────────────

test_project_save_example_is_exempt() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    printf 'TOKEN=sk-ant-0123456789abcdef0123\n' > "$r/.cco/secrets.env.example"
    printf 'TOKEN=realvalue\n'                   > "$r/.cco/secrets.env"

    _ps_cco_in "$r" project save -m "with skeleton" || return 1
    local files; files=$(_ps_head_files "$r")
    echo "$files" | grep -qF ".cco/secrets.env.example" \
        || { fail "the *.example skeleton must commit despite its secret-shaped value"; return 1; }
    if echo "$files" | grep -qx ".cco/secrets.env"; then
        fail "the real secrets.env must never be committed"; return 1
    fi
}

# ── T5 — a missing .cco/.gitignore refuses, and cco writes nothing ───

test_project_save_missing_gitignore_refuses_and_creates_nothing() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    rm -f "$r/.cco/.gitignore"

    local rc=0; _ps_cco_in "$r" project save -m "x" || rc=$?
    assert_rc 1 "$rc" "a missing .gitignore must refuse the save" || return 1
    assert_output_contains ".gitignore is missing" || return 1
    assert_output_contains "secrets.env" || return 1     # the refusal names the fix
    # D7 / P-C: cco does not author a versioned file in the user's repository.
    assert_file_not_exists "$r/.cco/.gitignore" || return 1
    assert_equals "" "$(git -C "$r" log --oneline 2>/dev/null)" "nothing may be committed" || return 1
}

# ── T6 — the check is on COVERAGE, not existence ─────────────────────

test_project_save_gitignore_missing_a_class_refuses() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    # Present, and covers everything EXCEPT *.key.
    printf 'secrets.env\n*.env\n*.pem\n.credentials.json\n' > "$r/.cco/.gitignore"

    local rc=0; _ps_cco_in "$r" project save -m "x" || rc=$?
    assert_rc 1 "$rc" "an insufficient .gitignore must refuse the save" || return 1
    assert_output_contains "does not ignore" || return 1
    assert_output_contains "*.key" || return 1
}

# Coverage is measured by ASKING GIT, so a rule that protects the user counts
# however it is spelled — a directory-wide pattern is not a missing barrier.
test_project_save_accepts_an_equivalent_gitignore_spelling() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    printf '*.env\n*.key\n*.pem\n.credentials.json\nsecrets.*\n!secrets.env.example\n' \
        > "$r/.cco/.gitignore"

    _ps_cco_in "$r" project save -m "x" || return 1
    assert_output_contains "saved app/.cco" || return 1
}

# ── T7 — not a git work tree ─────────────────────────────────────────

test_project_save_non_git_repo_refuses_without_init() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"
    mkdir -p "$r/.cco"
    printf 'name: demo\nrepos:\n  - name: app\n' > "$r/.cco/project.yml"
    _ps_gitignore "$r"

    local rc=0; _ps_cco_in "$r" project save -m "x" || rc=$?
    assert_rc 1 "$rc" "a non-git repo must refuse the save" || return 1
    assert_output_contains "not a git repository" || return 1
    # cco does not git-init a repository it does not own.
    assert_dir_not_exists "$r/.git" || return 1
}

# ── T8 — the commit message ──────────────────────────────────────────

test_project_save_message_honoured_and_defaulted() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app

    _ps_cco_in "$r" project save -m "tighten the rules" || return 1
    assert_equals "tighten the rules" "$(git -C "$r" log -1 --format=%s)" "-m must be honoured" || return 1

    printf '# more\n' >> "$r/.cco/claude/rules/style.md"
    _ps_cco_in "$r" project save || return 1
    assert_equals "project config update" "$(git -C "$r" log -1 --format=%s)" \
        "an absent -m must use the default message" || return 1
}

# ── T9 — cwd-first, from a subdirectory ──────────────────────────────

test_project_save_resolves_cwd_first_from_a_subdirectory() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    mkdir -p "$r/src/deep/nested"

    _ps_cco_in "$r/src/deep/nested" project save -m "from below" || return 1
    assert_output_contains "saved app/.cco" || return 1
    assert_equals "from below" "$(git -C "$r" log -1 --format=%s)" \
        "the save must land in the repo ROOT, not the cwd" || return 1
}

# ── T10 / T11 / T12 — the multi-repo report (D4) ─────────────────────
#
# A member repo can be committed and divergent, or identical and uncommitted.
# The two are independent facts and the report must keep them apart — that is
# exactly what D4 asks for, and a single merged line would lose it.

# Seed a two-repo project and register both in the index, so _effective_repo_mounts
# resolves them (Invariant H1: the report reads resolved roots, it never resolves).
_ps_two_repo_project() {
    local tmp="$1"
    _ps_repo "$tmp/dev/app"  demo app tools
    _ps_repo "$tmp/dev/tools" demo app tools
    run_cco resolve --scan "$tmp/dev" >/dev/null 2>&1 || return 1
    return 0
}

test_project_save_names_another_repo_with_uncommitted_cco() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _ps_two_repo_project "$tmp" || return 1

    _ps_cco_in "$tmp/dev/app" project save -m "app config" || return 1
    assert_output_contains "saved app/.cco" || return 1
    assert_output_contains "tools" || return 1
    assert_output_contains "cco project save" || return 1
}

test_project_save_reports_divergent_content_separately() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _ps_two_repo_project "$tmp" || return 1
    # tools is COMMITTED (so it is not "uncommitted") but its config DIFFERS.
    printf '# tools-only rule\n' > "$tmp/dev/tools/.cco/claude/rules/style.md"
    _ps_cco_in "$tmp/dev/tools" project save -m "tools config" || return 1

    _ps_cco_in "$tmp/dev/app" project save -m "app config" || return 1
    assert_output_contains "divergent .cco" || return 1
    assert_output_contains "cco sync" || return 1
    # The committed member must NOT be reported as uncommitted — the two facts
    # are separate, and conflating them is the failure D4 names.
    assert_output_not_contains "tools also has an uncommitted" || return 1
}

# The report is a `note`, never a `warn` (design §2.6): a `warn` escalates the
# `cco start` pause, which would make every multi-repo project stop at launch over
# a save-time observation.
test_project_save_report_is_a_note_not_a_warn() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    _ps_two_repo_project "$tmp" || return 1

    _ps_cco_in "$tmp/dev/app" project save -m "app config" || return 1
    assert_output_contains "note:" || return 1
    assert_output_not_contains "⚠" || return 1
}

# ── T13 — the history is PATH-FILTERED, not trailer-marked (D3) ──────

test_project_history_finds_a_hand_made_commit() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    # A commit made BY HAND, touching config AND code together — the normal case,
    # and the one a `Cco-Save:` trailer would be blind to.
    git -C "$r" add -A
    git -C "$r" commit -q -m "hand-made: config and code together"

    _ps_cco_in "$r" project history || return 1
    assert_output_contains "hand-made: config and code together" || return 1
}

# ── T14 — the changed-parts column groups correctly ──────────────────

test_project_history_groups_changed_parts() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    printf '# another\n' > "$r/.cco/claude/rules/naming.md"
    _ps_cco_in "$r" project save -m "rules" || return 1

    _ps_cco_in "$r" project history || return 1
    # The overlay dir collapses to its group — two rule files are one answer.
    assert_output_contains "claude/rules" || return 1
    assert_output_not_contains "style.md" || return 1
    # A file that is not part of a group reports as itself.
    assert_output_contains "project.yml" || return 1
}

# ── T15 — -n limits, --full adds the diff ────────────────────────────

test_project_history_limit_and_full() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    _ps_cco_in "$r" project save -m "first"  || return 1
    printf '# more\n' >> "$r/.cco/claude/rules/style.md"
    _ps_cco_in "$r" project save -m "second" || return 1

    _ps_cco_in "$r" project history -n 1 || return 1
    assert_output_contains "second" || return 1
    assert_output_not_contains "first" || return 1

    _ps_cco_in "$r" project history -n 1 --full || return 1
    assert_output_contains "diff --git" || return 1
}

# ── T16 / T17 — degradation: never a die on an absent history ────────

test_project_history_without_config_commits_degrades() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    # A repo with commits, but none touching .cco/ — a normal state, not an error.
    git -C "$r" add -- src.txt
    git -C "$r" commit -q -m "code only"

    _ps_cco_in "$r" project history || return 1     # rc 0 is the assertion
    assert_output_contains "never been committed" || return 1
    assert_output_contains "cco project save" || return 1
}

test_config_history_on_an_unversioned_store_degrades() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    # ~/.cco exists but was never git-inited — `cco config save` is what does that.
    mkdir -p "$HOME/.cco/.claude"

    run_cco config history || return 1              # rc 0 is the assertion
    assert_output_contains "no saved history yet" || return 1
    assert_output_contains "cco config save" || return 1
}

test_config_history_lists_the_personal_store() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$HOME/.cco/.claude"
    printf '# global\n' > "$HOME/.cco/.claude/CLAUDE.md"
    run_cco config save -m "first global" || return 1

    run_cco config history || return 1
    assert_output_contains "first global" || return 1
    assert_output_contains ".claude/CLAUDE.md" || return 1
}

# ── `status` (ADR-0038 Amendment A1) ─────────────────────────────────
#
# The preview's whole value is that it reproduces its own save's rule about what
# gets committed (A1 D11). A test that only checked "it lists changed files" would
# pass on a plain `git status` — which names files neither verb would commit.

test_project_status_lists_exactly_what_save_would_commit() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    _ps_cco_in "$r" project save -m "initial" || return 1

    printf 'description: x\n' >> "$r/.cco/project.yml"       # M
    printf '# new\n'   > "$r/.cco/claude/rules/naming.md"    # A
    rm "$r/.cco/claude/rules/style.md"                       # D
    printf 'TOKEN=real\n' > "$r/.cco/secrets.env"            # gitignored — save skips it
    printf 'more code\n' >> "$r/src.txt"                     # outside .cco — save skips it

    # NOTE: project.yml is the cwd-first ANCHOR (_resolve_find_unit_dir keys on it),
    # so it is deliberately the MODIFIED file here, never the deleted one — deleting
    # it makes the repo unresolvable, which is a different verb's contract.
    _ps_cco_in "$r" project status || return 1
    assert_output_contains "M  project.yml"            || return 1
    assert_output_contains "A  claude/rules/naming.md" || return 1
    assert_output_contains "D  claude/rules/style.md"  || return 1
    # The two exclusions are the point: both would be listed by a bare `git status`.
    assert_output_not_contains "secrets.env" || return 1
    assert_output_not_contains "src.txt"     || return 1
}

# A read verb that writes is not a preview. Nothing may move — not HEAD, not the
# index, not the working tree.
test_project_status_changes_nothing() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    _ps_cco_in "$r" project save -m "initial" || return 1
    printf '# more\n' >> "$r/.cco/claude/rules/style.md"
    git -C "$r" add -- src.txt                      # the user's own staging must survive too

    local head_before porcelain_before
    head_before=$(git -C "$r" rev-parse HEAD)
    porcelain_before=$(git -C "$r" status --porcelain)

    _ps_cco_in "$r" project status --full || return 1

    assert_equals "$head_before" "$(git -C "$r" rev-parse HEAD)" "status must create no commit" || return 1
    assert_equals "$porcelain_before" "$(git -C "$r" status --porcelain)" \
        "status must leave the index and working tree untouched" || return 1
}

test_project_status_clean_names_the_last_save() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    _ps_cco_in "$r" project save -m "tighten the rules" || return 1

    _ps_cco_in "$r" project status || return 1
    assert_output_contains "is clean" || return 1
    assert_output_contains "tighten the rules" || return 1
}

test_project_status_never_committed() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app

    _ps_cco_in "$r" project status || return 1
    assert_output_contains "project.yml" || return 1
    assert_output_contains "cco project save" || return 1
}

# A1 D10 — the barrier is REPORTED, never enforced. `save` refuses on it (T5/T6);
# `status` must still answer, at rc 0, in the same words. A preview that dies is one
# nobody can use to find out why their save would die.
test_project_status_reports_the_barrier_without_refusing() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    printf 'secrets.env\n*.env\n*.pem\n.credentials.json\n' > "$r/.cco/.gitignore"   # no *.key

    _ps_cco_in "$r" project status || return 1      # rc 0 IS the assertion
    assert_output_contains "would refuse" || return 1
    assert_output_contains "*.key" || return 1
    # It still answers the question that was asked.
    assert_output_contains "project.yml" || return 1
    # And it does not author the file it is complaining about (P-C).
    assert_file_not_contains "$r/.cco/.gitignore" "*.key" || return 1
}

test_project_status_missing_gitignore_is_reported_not_fatal() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    rm -f "$r/.cco/.gitignore"

    _ps_cco_in "$r" project status || return 1      # rc 0 IS the assertion
    assert_output_contains "is missing" || return 1
    assert_file_not_exists "$r/.cco/.gitignore" || return 1
}

# --full must cover NEW files too. `git diff HEAD` cannot show an untracked file,
# and staging it to make it visible is exactly what a read verb may not do.
test_project_status_full_diffs_new_files_too() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    _ps_cco_in "$r" project save -m "initial" || return 1
    printf '# brand new\n' > "$r/.cco/claude/rules/naming.md"

    _ps_cco_in "$r" project status --full || return 1
    assert_output_contains "brand new" || return 1
    assert_output_contains "diff --git" || return 1
}

# ── `cco config status` — the other half of D11 ──────────────────────

test_config_status_lists_only_the_allowlist() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$HOME/.cco/.claude"
    printf '# global\n' > "$HOME/.cco/.claude/CLAUDE.md"
    run_cco config save -m "first" || return 1

    printf '# edited\n' >> "$HOME/.cco/.claude/CLAUDE.md"   # allowlisted
    printf 'junk\n'      > "$HOME/.cco/scratch.txt"         # NOT allowlisted

    run_cco config status || return 1
    assert_output_contains ".claude/CLAUDE.md" || return 1
    # `config save` would never commit it, so the preview must not promise it.
    assert_output_not_contains "scratch.txt" || return 1
}

# A store that has never been saved. ⚠ NOT the `-d .git` branch: J0
# (_cco_first_run, lib/migrate.sh) git-inits ~/.cco on every host command, so that
# branch is unreachable from the host suite by construction — it exists for a
# container where the store is mounted without its .git. What IS reachable, and what
# the user actually meets, is a git tree with no commits.
test_config_status_on_a_never_saved_store() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$HOME/.cco/.claude"
    printf '# global\n' > "$HOME/.cco/.claude/CLAUDE.md"
    printf 'junk\n'      > "$HOME/.cco/scratch.txt"

    run_cco config status || return 1               # rc 0 IS the assertion
    assert_output_contains ".claude/CLAUDE.md" || return 1
    assert_output_contains "cco config save" || return 1
    # ⚠ This is where the allowlist pathspec is LOAD-BEARING and the sibling test
    # above cannot see it. Once `config save` has run, its whitelist .gitignore
    # (`*` then `!`-re-include) excludes a stray file by itself, so dropping the
    # pathspec changes nothing there. Before the first save that barrier does not
    # exist yet — and a preview that promised to commit scratch.txt would be lying
    # about the very command it previews (A1 D11).
    assert_output_not_contains "scratch.txt" || return 1
}

test_config_status_clean_after_save() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$HOME/.cco/.claude"
    printf '# global\n' > "$HOME/.cco/.claude/CLAUDE.md"
    run_cco config save -m "first global" || return 1

    run_cco config status || return 1
    assert_output_contains "is clean" || return 1
    assert_output_contains "first global" || return 1
}

# ── Amendment A2 — the barrier's predicate (design §6.2c, AT1…AT9) ───
#
# A2 corrects D7 itself, not the build: `git check-ignore` answers "would git
# ignore this path right now", D7 asks "does a rule protect this class". The two
# diverge in two states, in OPPOSITE directions — a false refusal when the file is
# tracked, a false PASS when the root .gitignore swallows .cco/ whole. Both are
# asserted here, because fixing only the one that annoys leaves the one that
# silently loses the user's config.

# Commit <repo>/.cco INCLUDING a secrets.env the rule covers — the state a user
# reaches by committing their config before adding the ignore rule. `-f` is what
# makes it tracked despite the rule, exactly as a hand-made commit would.
_ps_track_ignored_secret() {
    local root="$1"
    printf 'TOKEN=realvalue\n' > "$root/.cco/secrets.env"
    git -C "$root" add -f -- .cco >/dev/null 2>&1
    git -C "$root" commit -q -m "config committed by hand, secrets.env included" >/dev/null 2>&1
}

# AT1 — a TRACKED file the rule covers must not refuse the save (D13). Without
# `--no-index` git consults the index first, reports it as not-ignored, and the
# refusal prints as its remedy a line that is already in the file: unfollowable,
# and permanent.
test_project_save_tracked_ignored_file_does_not_refuse() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    _ps_track_ignored_secret "$r"
    printf '# more\n' >> "$r/.cco/claude/rules/style.md"

    _ps_cco_in "$r" project save -m "tweak the rules" || return 1   # rc 0 IS the assertion
    assert_output_contains "saved app/.cco" || return 1
    # It is reported — at `note`, and the save proceeds.
    assert_output_contains "note:" || return 1
    assert_output_contains "secrets.env" || return 1
}

# AT2 — the note must not trade one false belief for another. `git rm --cached`
# stops future commits; it does NOT rewrite the ones already made, and a note that
# implied otherwise would be the defect it replaced.
test_project_save_tracked_note_does_not_promise_a_clean_past() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    _ps_track_ignored_secret "$r"
    printf '# more\n' >> "$r/.cco/claude/rules/style.md"

    _ps_cco_in "$r" project save -m "tweak" || return 1
    assert_output_contains "already in" || return 1
    assert_output_contains "history" || return 1
    assert_output_contains "git rm --cached" || return 1
    assert_output_contains "does not rewrite" || return 1
}

# AT3 — the floor D13 leans on. Tracked AND MODIFIED stages, so the scan sees it
# and refuses: no NEW secret content passes. Without this test D13's rationale is
# an assertion nothing measures.
test_project_save_tracked_and_modified_secret_still_refuses() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    _ps_track_ignored_secret "$r"
    printf 'TOKEN=a-brand-new-value\n' > "$r/.cco/secrets.env"      # tracked AND modified

    local rc=0; _ps_cco_in "$r" project save -m "x" || rc=$?
    assert_rc 1 "$rc" "a tracked-and-modified secret must still refuse" || return 1
    assert_output_contains "refusing to save" || return 1
    assert_output_contains "secrets.env" || return 1
    assert_empty "$(git -C "$r" diff --cached --name-only -- .cco)" \
        "the refusal must leave nothing staged under .cco" || return 1
}

# AT4 — the false PASS (D15). A root .gitignore that swallows .cco/ makes every
# probe report "ignored", the barrier passes, `git add` stages nothing, and the
# verb says "nothing to save" at rc 0. The config is never saved and both verbs
# affirm success — silent, total, indistinguishable from working.
test_project_save_refuses_when_root_gitignore_swallows_cco() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    printf '.cco/\n' > "$r/.gitignore"

    local rc=0; _ps_cco_in "$r" project save -m "x" || rc=$?
    assert_rc 1 "$rc" "a vacuously satisfied barrier must refuse, not report success" || return 1
    assert_output_not_contains "nothing to save" || return 1
    # The fix is in the ROOT .gitignore, and the refusal must name that file.
    assert_output_contains "app/.gitignore" || return 1
    assert_output_contains "ignores .cco/" || return 1
    assert_equals "" "$(git -C "$r" log --oneline 2>/dev/null)" "nothing may be committed" || return 1
}

# AT5 — `status` in the AT4 state. D10 is unchanged: report, never enforce, rc 0.
# And it must never say "clean" — "clean" claims the config is saved, which is the
# precise falsehood D15 exists to stop.
test_project_status_reports_the_vacuous_barrier_and_never_says_clean() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    printf '.cco/\n' > "$r/.gitignore"

    _ps_cco_in "$r" project status || return 1      # rc 0 IS the assertion
    assert_output_contains "app/.gitignore" || return 1
    assert_output_contains "ignores .cco/" || return 1
    assert_output_not_contains "is clean" || return 1
}

# AT6 — `status` previews the SECOND refusal path too (D14). A .cco/.netrc is not
# in the gitignore floor, so the barrier passes and A1's status closed with
# "→ cco project save" — promising a save that then refuses on the scan.
test_project_status_previews_the_secret_scan_refusal() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    printf 'machine example.com login u password p\n' > "$r/.cco/.netrc"

    _ps_cco_in "$r" project status || return 1      # rc 0 IS the assertion
    assert_output_contains "would refuse" || return 1
    assert_output_contains ".netrc" || return 1
    # D14: it still lists the set it would commit — one invocation, both halves.
    assert_output_contains "project.yml" || return 1
    # A preview that promises a save that will fail is the defect A2 names.
    assert_output_not_contains "→ cco project save" || return 1
}

# AT7 — the scan reads the STAGED set; §5b.4 forbids this verb from staging. The
# preview must therefore ask the same question of the set it computed, with no
# index write. A status that stages to find out is a read verb that writes.
test_project_status_scan_preview_stages_nothing() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app
    printf 'machine example.com login u password p\n' > "$r/.cco/.netrc"
    git -C "$r" add -- src.txt                      # the user's own staging must survive

    local porcelain_before; porcelain_before=$(git -C "$r" status --porcelain)
    _ps_cco_in "$r" project status --full || return 1
    assert_equals "$porcelain_before" "$(git -C "$r" status --porcelain)" \
        "the scan preview must not stage anything" || return 1
}

# AT8 — the compensating control §7 rests on, and nothing tested. The floor is
# DELIBERATELY narrower than _SECRET_FILENAME_PATTERNS (it is what cco's own
# scaffold writes), and what carries that choice is the claim that the 2-pass scan
# catches the rest. INV-GIF guards only scaffold ⊇ floor — the direction that would
# kill the verb, not the one that would leak.
test_project_save_scan_catches_a_class_the_gitignore_floor_omits() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    local r="$tmp/app"; _ps_repo "$r" demo app     # scaffold-conformant .gitignore
    printf 'machine example.com login u password p\n' > "$r/.cco/.netrc"

    local rc=0; _ps_cco_in "$r" project save -m "x" || rc=$?
    assert_rc 1 "$rc" ".netrc is outside the floor, so only the scan can catch it" || return 1
    assert_output_contains ".netrc" || return 1
    assert_empty "$(git -C "$r" diff --cached --name-only -- .cco)" \
        "the refusal must reset the staged set" || return 1
    assert_equals "" "$(git -C "$r" log --oneline 2>/dev/null)" "nothing may be committed" || return 1
}

# AT9 — the level stays `note`/`die` throughout. A `warn` gates a launch
# (ADR-0059 D1), so one emitted here would make every affected project pause at
# every `cco start` over a save-time observation.
test_project_save_amendment_a2_emits_no_warn() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"

    # (a) the tracked-file note
    local a="$tmp/a"; _ps_repo "$a" demo a
    _ps_track_ignored_secret "$a"
    printf '# more\n' >> "$a/.cco/claude/rules/style.md"
    _ps_cco_in "$a" project save -m "x" || return 1
    assert_output_not_contains "⚠" || return 1

    # (b) the vacuous-coverage refusal
    local b="$tmp/b"; _ps_repo "$b" demo b
    printf '.cco/\n' > "$b/.gitignore"
    _ps_cco_in "$b" project save -m "x" || true
    assert_output_not_contains "⚠" || return 1
    _ps_cco_in "$b" project status || return 1
    assert_output_not_contains "⚠" || return 1

    # (c) the scan, refused and previewed
    local c="$tmp/c"; _ps_repo "$c" demo c
    printf 'machine example.com login u password p\n' > "$c/.cco/.netrc"
    _ps_cco_in "$c" project save -m "x" || true
    assert_output_not_contains "⚠" || return 1
    _ps_cco_in "$c" project status || return 1
    assert_output_not_contains "⚠" || return 1
}

# The twin, by D9's own argument: `cco config save` has the same scan refusal and
# the same preview that did not anticipate it. A verb that exists for one store and
# not the other is the gap A1 D9 refused to leave open.
test_config_status_previews_the_secret_scan_refusal() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    setup_cco_env "$tmp"
    mkdir -p "$HOME/.cco/.claude"
    printf '# global\n' > "$HOME/.cco/.claude/CLAUDE.md"
    printf 'machine example.com login u password p\n' > "$HOME/.cco/.claude/.netrc"

    run_cco config status || return 1               # rc 0 IS the assertion
    assert_output_contains "would refuse" || return 1
    assert_output_contains ".netrc" || return 1
    assert_output_contains ".claude/CLAUDE.md" || return 1
    assert_output_not_contains "→ cco config save" || return 1
}
