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
