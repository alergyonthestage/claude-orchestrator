#!/usr/bin/env bash
# lib/cmd-project-save.sh — `cco project save` + `cco project history` (ADR-0038).
#
# The PROJECT column of the config 2x2: `<repo>/.cco/` is versioned by the repo's
# own git, so this is the twin of `cco config save` for a store cco does NOT own.
#
#   cco project save [-m <msg>]          stage .cco/** + secret-scan + commit
#   cco project status [--full]          what save WOULD commit, and would it succeed
#   cco project history [-n N] [--full]  what was saved before
#
# EVERY DIFFERENCE FROM THE TWIN DESCENDS FROM ONE FACT: `~/.cco` is a git repo cco
# created and owns; `<repo>/.cco/` is a subtree of the USER's repository (P-C).
# Concretely, and none of these is a style choice:
#
#   - Staging is `git add -- .cco` and the commit carries the same pathspec, so a
#     dirty — or already STAGED — working tree outside .cco/ is neither committed
#     nor disturbed. The twin can omit the pathspec; here it is the contract (T1).
#   - The secret-scan reset is `git reset -q -- .cco`, never the twin's bare
#     `git reset`: unstaging the user's unrelated work would be a destructive side
#     effect of a verb that refused to do anything.
#   - A missing/insufficient `.cco/.gitignore` REFUSES and names the fix; cco never
#     authors it (D7). The twin's `_config_ensure_gitignore` writes one because it
#     owns the tree — here the file would land in the user's repo, inside the very
#     commit they asked for.
#   - There is NO ro-mount guard mirroring `_config_save`'s. ⚠ It was MEASURED that
#     `git add -- .cco/` on a read-only `.cco` bind returns 0: git reads the
#     worktree and writes to `.git/`, which is rw — the bind is a read-only CHILD
#     mount inside a read-write repo. The twin's guard exists because `~/.cco`
#     contains its OWN `.git`, and that reason does not transfer. The `edit-project+`
#     gate on this verb is therefore POLICY, enforced at the shim (ADR-0038 D8) —
#     do not "fix" it by reasoning from the mount table, which permits the write.
#
# Provides: cmd_project_save(), cmd_project_status(), cmd_project_history()
# Dependencies: colors.sh (ok/info/note/die), cmd-resolve.sh (_resolve_find_unit_dir),
#   secrets.sh (_secret_scan_staged, _SECRET_PROJECT_GITIGNORE_CLASSES,
#   _secret_gitignore_probe), config-read.sh (_history_/_status_ helpers),
#   reminders.sh (_reminder_git_dirty, _reminder_roots_divergent),
#   local-paths.sh (_effective_repo_mounts)

# The commit message when `-m` is absent (ADR-0038 Open / design §7). It lands in
# the USER's git log among their code commits, so it says which config it was —
# the twin's bare "config update" would be ambiguous there.
_PROJECT_SAVE_DEFAULT_MSG="project config update"

# Resolve the repo this invocation acts on: cwd-first, the nearest ancestor holding
# .cco/project.yml — the same anchor `cco project add` uses. Echoes the root, or
# empty when there is none.
#
# ⚠ It does NOT die: a `die` inside `$( )` exits only the subshell, so the caller
# would carry on with an empty value and the EXIT trap would misreport the run as a
# crash (FI-62, paid for twice already). Callers test the result and die themselves.
_project_unit_root() {
    _resolve_find_unit_dir 2>/dev/null || printf ''
}

_project_save_usage() {
    cat <<'EOF'
Usage: cco project save [-m <message>]

Commit this repo's <repo>/.cco/ config — and nothing else — with a secret scan.
Run it from anywhere inside the repo; cco finds the root that holds .cco/.

Options:
  -m, --message <msg>    Commit message (default: "project config update")

Only .cco/** is staged and committed: whatever else is dirty or already staged in
your working tree is left exactly as it was. A secret-like file under .cco/ is
refused, not committed. Read the history back with 'cco project history'.
EOF
}

_project_history_usage() {
    cat <<'EOF'
Usage: cco project history [-n <count>] [--full]

Show how this repo's <repo>/.cco/ config changed over time — every commit that
touched it, including commits that also touched code and commits made by hand.

Options:
  -n, --max-count <n>    How many commits to show (default: 10)
      --full             Also show each commit's diff

Each line reports the date, the commit, the author, the message, and which parts
of the config changed. The personal store's twin is 'cco config history'.
EOF
}

# D7 barrier, as a PURE QUESTION with no verdict attached. Echoes:
#   ""              the barrier holds
#   "missing"       there is no `<repo>/.cco/.gitignore` at all
#   "vacuous"       every probe passes only because .cco/ is wholly ignored (A2 D15)
#   "<cls>, <cls>"  it exists but does not ignore these classes
#
# `save` turns this into a refusal (D7); `status` into a report (A1 D10) — one rule,
# two levels, the same split `_reminder_roots_divergent` makes. A second copy of the
# check inside `status` would be exactly the drift this unit keeps closing elsewhere.
#
# Coverage is measured by ASKING GIT (`git check-ignore`), not by grepping the file
# for a literal: a rule that matches is what protects the user, however it is
# spelled and wherever in the repo's ignore chain it lives.
#
# 🔴 `--no-index` IS NOT OPTIONAL AND IS NOT A LOOSENING (Amendment A2, D13). Without
# it git consults the INDEX before the ignore chain, so a file the user committed
# before adding the rule reports as *not ignored* — and the refusal then prints, as
# its remedy, a line that is ALREADY IN THE FILE. The save is refused permanently and
# the instruction cannot be followed. The question this barrier asks is *does a rule
# exist*, and the index is not part of the ignore chain.
#
# 🔴 A pass is VOID when it was bought by an unrelated rule (D15). If the repository's
# root .gitignore ignores `.cco/` entirely, all four class probes report *ignored*
# and the barrier passes — while `git add -- .cco` stages nothing and the config is
# never saved, silently. The discriminator is a NON-SECRET path: `.cco/project.yml`
# is ignored too only in that state, never by a .gitignore that merely protects.
_project_gitignore_gaps() {
    local root="$1"
    [[ -f "$root/.cco/.gitignore" ]] || { printf 'missing\n'; return 0; }
    local cls probe missing=""
    for cls in "${_SECRET_PROJECT_GITIGNORE_CLASSES[@]}"; do
        probe=$(_secret_gitignore_probe "$cls")
        git -C "$root" check-ignore -q --no-index ".cco/$probe" 2>/dev/null && continue
        missing="${missing}${missing:+, }$cls"
    done
    if [[ -z "$missing" ]] \
       && git -C "$root" check-ignore -q --no-index ".cco/project.yml" 2>/dev/null; then
        printf 'vacuous\n'; return 0
    fi
    printf '%s\n' "$missing"
}

# The vacuous-coverage remedy, printed from ONE place so `save`'s refusal and
# `status`'s report can never name a different fix (D11).
_project_gitignore_vacuous_lines() {
    local repo="$1"
    printf '  Remove the rule that ignores .cco/ from %s/.gitignore — the repository ROOT one, not the config'"'"'s own.\n' "$repo"
    printf '  %s/.cco/.gitignore is what keeps secrets out of the commit, and it stays exactly as it is.\n' "$repo"
}

# The save-side verdict on that question: refuse, and name the fix (D7). Runs BEFORE
# anything is staged — it is what makes the save safe to run at all.
_project_save_assert_gitignore() {
    local root="$1" gaps
    gaps=$(_project_gitignore_gaps "$root")
    [[ -z "$gaps" ]] && return 0
    local repo; repo=$(basename "$root")

    # D15 — the fix is in a DIFFERENT file from the other two branches, and the
    # class list below would name the wrong one. Left to the old code path this
    # state does not refuse at all: it reports "nothing to save" at rc 0.
    if [[ "$gaps" == vacuous ]]; then
        error "refusing to save — $repo/.gitignore ignores .cco/ entirely, so this save would commit nothing at all."
        _project_gitignore_vacuous_lines "$repo" >&2
        die "The .cco/.gitignore coverage check passes here only because the whole directory is ignored, and that is not protection (ADR-0038 D15)."
    fi

    if [[ "$gaps" == missing ]]; then
        error "refusing to save — $repo/.cco/.gitignore is missing."
        echo "  Without it, a secret dropped under .cco/ would be committed. Create it with:" >&2
    else
        error "refusing to save — $repo/.cco/.gitignore does not ignore: $gaps"
        echo "  Add the missing lines to $repo/.cco/.gitignore, then retry:" >&2
    fi
    _project_save_gitignore_lines >&2
    die "cco does not write that file for you — it is a versioned file in YOUR repository (ADR-0038 D7)."
}

# The lines the refusal above tells the user to add — printed from the SAME array
# the coverage check reads, so the remedy can never name a different set than the
# one that refused.
_project_save_gitignore_lines() {
    local cls
    for cls in "${_SECRET_PROJECT_GITIGNORE_CLASSES[@]}"; do
        printf '    %s\n' "$cls"
    done
    printf '    !secrets.env.example\n'
}

# The other half of D13: the files `--no-index` deliberately stops refusing over.
# Echoes one <root>-relative path per line for every TRACKED file under .cco/ that
# an ignore rule covers — the state a user reaches by committing their config
# before adding the rule. Empty when there is none.
#
# ⚠ `check-ignore --stdin` exits 1 when NOTHING matches, which under `set -o
# pipefail` fails the whole pipeline. That is the ordinary case, not an error.
_project_tracked_ignored() {
    local root="$1"
    git -C "$root" ls-files -z -- .cco 2>/dev/null \
        | git -C "$root" check-ignore -z --no-index --stdin 2>/dev/null \
        | tr '\0' '\n' || true
    return 0
}

# That state as TEXT, with no presentation attached — empty when there is none.
# The finding is one; how it is delivered is not: `save` emits it as a `note`
# (design §2.6), `status` prints it into its own answer on stdout, because §5b.5
# keeps facts about THIS repo in the answer and only cross-repo ones on stderr.
# Same one-rule-two-levels split `_project_gitignore_gaps` already makes — a second
# copy of the wording is the drift this unit keeps closing.
#
# It reports that state and ONLY that state — the save proceeds (D13). It is not the
# event that exposes the file: it is already in the repository's history, and the
# floor still holds where it can act, because a tracked file that is also MODIFIED
# gets staged and the 2-pass scan refuses it.
#
# ⚠ The wording must not imply that untracking cleans the past, or it trades one
# false belief for another: `git rm --cached` stops future commits, it does not
# rewrite the ones already made.
_project_tracked_ignored_message() {
    local root="$1" repo="$2"
    local -a tracked=(); local p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        tracked+=("$p")
    done < <(_project_tracked_ignored "$root")
    [[ ${#tracked[@]} -eq 0 ]] && return 0

    local tail_msg="'git rm --cached' stops future commits from carrying it, but it does not rewrite the commits already made."
    if [[ ${#tracked[@]} -eq 1 ]]; then
        printf '%s\n' "$repo/${tracked[0]} is tracked even though a .gitignore rule covers it — it is already in this repo's history. $tail_msg"
    else
        local list=""; local t
        for t in "${tracked[@]}"; do list="${list}${list:+, }$t"; done
        printf '%s\n' "${#tracked[@]} tracked files under $repo/.cco are covered by a .gitignore rule ($list) — they are already in this repo's history. $tail_msg"
    fi
    return 0
}

# The save-side delivery. ⚠ Level `note`, never `warn` (design §2.6): a `warn` gates
# a launch. And no confirmation prompt — a tracked file STAYS tracked until the user
# acts, so a prompt would fire on every save forever, which is how a real refusal is
# trained into reflex.
_project_report_tracked_ignored() {
    local msg; msg=$(_project_tracked_ignored_message "$1" "$2")
    [[ -n "$msg" ]] && note "$msg"
    return 0
}

# D4 — report what this invocation did NOT cover. Shared by `save` (after the
# commit) and by `status` (as part of the preview, where it arguably matters more:
# that is the moment before you decide). Two INDEPENDENT
# facts, deliberately reported apart: a member repo can be committed and divergent
# (someone committed a different config there), or identical and uncommitted. A
# single merged line would hide exactly the distinction the user needs.
#
# ⚠ Invariant H1: computed only from ALREADY-RESOLVED roots. `_effective_repo_mounts`
# reads the index (and, in a session, the mounts) — it never resolves. Outside a
# resolved project it yields nothing and this section degrades to silence.
#
# ⚠ Level is `note`, never `warn` (design §2.6). A `warn` escalates the `cco start`
# pause; nothing reported here should make a multi-repo project stop at every launch.
_project_config_report_members() {
    local root="$1"
    local yml="$root/.cco/project.yml"
    [[ -f "$yml" ]] || return 0

    local -a roots=()
    local _name _path
    while IFS=$'\t' read -r _name _path; do
        [[ -z "$_path" ]] && continue
        roots+=("$_path")
    done < <(_effective_repo_mounts "$yml" 2>/dev/null)
    [[ ${#roots[@]} -le 1 ]] && return 0

    # (1) Other members whose own .cco/ is uncommitted — this verb committed one repo.
    local r dirty="" ndirty=0
    for r in "${roots[@]}"; do
        [[ "$r" == "$root" ]] && continue
        [[ -d "$r/.cco" ]] || continue
        if _reminder_git_dirty "$r" ".cco"; then
            dirty="${dirty}${dirty:+, }$(basename "$r")"
            ndirty=$(( ndirty + 1 ))
        fi
    done
    if [[ $ndirty -eq 1 ]]; then
        note "$dirty also has an uncommitted .cco → run 'cco project save' there too"
    elif [[ $ndirty -gt 1 ]]; then
        note "$ndirty other repos have an uncommitted .cco ($dirty) → run 'cco project save' in each"
    fi

    # (2) Divergent CONTENT across the members — a different question, and one
    #     'cco project save' cannot answer: committing everywhere would just record
    #     the divergence. `cco sync` is what converges it.
    if _reminder_roots_divergent "${roots[@]}"; then
        note "this project's repos carry divergent .cco content → cco sync"
    fi
    return 0
}

cmd_project_save() {
    local msg=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) _project_save_usage; return 0 ;;
            -m|--message) [[ $# -lt 2 ]] && die "-m requires a commit message."; msg="$2"; shift 2 ;;
            -*) die "Unknown option: $1. Run 'cco project save --help'." ;;
            *)  die "Unexpected argument: $1. 'cco project save' takes no positional arguments — it saves the repo you run it from." ;;
        esac
    done

    local root; root=$(_project_unit_root)
    [[ -n "$root" ]] || die "not inside a cco project — 'cco project save' commits the <repo>/.cco/ of the repo you run it from. cd into a repo that has .cco/project.yml, or run 'cco init' to scaffold one."
    local repo; repo=$(basename "$root")

    git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "$repo is not a git repository, so its .cco/ cannot be versioned. cco does not 'git init' a repository it does not own — run 'git init' in $root yourself, then retry."

    _project_save_assert_gitignore "$root"
    # Reported BEFORE the "nothing to save" exit below: it is a standing state of
    # the repository, true whether or not this invocation has anything to commit.
    _project_report_tracked_ignored "$root" "$repo"

    # Explicit, path-scoped staging — NEVER `git add -A`. A `.cco/` whose every file
    # is ignored makes `git add` exit 1 with an advice block; that is not an error
    # here, it is the "nothing to save" case the next test reports properly.
    git -C "$root" add -- .cco >/dev/null 2>&1 || true

    if git -C "$root" diff --cached --quiet -- .cco 2>/dev/null; then
        info "$repo/.cco is already up to date — nothing to save"
        return 0
    fi

    # Second barrier: the 2-pass scan, always, over the staged set — scoped to .cco/
    # so a secret staged elsewhere in the user's tree neither refuses this save nor
    # gets reported as if this verb were about to commit it.
    local leak
    if ! leak=$(_secret_scan_staged "$root" ".cco"); then
        git -C "$root" reset -q -- .cco >/dev/null 2>&1 || true
        error "refusing to save — a secret-like file is staged under $repo/.cco:"
        printf '  %s\n' "$leak" >&2
        die "Move the secret into $repo/.cco/secrets.env (gitignored) and try again."
    fi

    [[ -z "$msg" ]] && msg="$_PROJECT_SAVE_DEFAULT_MSG"
    # The pathspec on the COMMIT is what keeps an unrelated pre-staged file out of
    # it (measured): it stays staged and uncommitted, exactly as the user left it.
    git -C "$root" commit -q -m "$msg" -- .cco >/dev/null 2>&1 \
        || die "git commit failed in $root — resolve it there and retry."
    local sha; sha=$(git -C "$root" rev-parse --short HEAD 2>/dev/null)
    ok "saved $repo/.cco @ ${sha} — ${msg}"

    _project_config_report_members "$root"
    return 0
}

_project_status_usage() {
    cat <<'EOF'
Usage: cco project status [--full]

Show what 'cco project save' would commit from this repo's <repo>/.cco/ — and
whether it would succeed. Nothing is written, staged or changed.

Options:
      --full             Also show the diff of each change

Each line is a file and its fate in that commit: M modified, A new, D deleted.
Files git ignores are excluded, because save would not commit them either.
What was already saved is 'cco project history'.
EOF
}

# `status` answers a different question from `history` — what is NOT saved yet,
# rather than what was. Everything it prints is the ANSWER, so it goes to stdout and
# pipes; only the cross-repo facts, which are about OTHER repos, stay `note`.
#
# ⚠ It never refuses and never dies on a config problem (A1 D10). A preview that
# dies is one nobody can use to find out why their save would die — so the D7
# barrier is REPORTED here, in the same words `save` refuses with, and the file list
# is still printed underneath so one invocation answers both halves.
cmd_project_status() {
    _status_parse_args project "$@"
    if [[ "$_STATUS_HELP" == true ]]; then _project_status_usage; return 0; fi

    local root; root=$(_project_unit_root)
    [[ -n "$root" ]] || die "not inside a cco project — 'cco project status' reads the <repo>/.cco/ of the repo you run it from. cd into a repo that has .cco/project.yml."
    local repo; repo=$(basename "$root")

    if ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf '%s/.cco cannot be versioned yet — %s is not a git repository. Run '"'"'git init'"'"' there, then '"'"'cco project save'"'"'.\n' "$repo" "$repo"
        return 0
    fi

    local changed; changed=$(_status_changed "$root" ".cco/" ".cco")
    local gaps; gaps=$(_project_gitignore_gaps "$root")

    # D15 — answered FIRST, because in this state git reports nothing changed
    # (everything under .cco/ is ignored) and the clean branch below would print
    # "is clean", affirming exactly the silent failure the barrier just caught.
    # AT5: it must never say clean here.
    if [[ "$gaps" == vacuous ]]; then
        printf '%s/.cco — %s would refuse, and nothing at all would be committed:\n' \
            "$repo" "'cco project save'"
        _project_status_report_gaps "$repo" "$gaps"
        _project_config_report_members "$root"
        return 0
    fi

    # D13's tracked-file finding, in the surface the user reads BEFORE deciding.
    # Computed after the vacuous return above on purpose: there every file under
    # .cco/ probes as ignored, so the list would name the whole config — noise
    # manufactured by the broken root rule, not a finding about these files.
    #
    # ⚠ stdout, not `note`: §5b.5 keeps facts about THIS repo inside the answer and
    # sends only the cross-repo ones to stderr. Same finding as `save`'s, same
    # words, different level — which is the split this verb makes everywhere.
    local tracked_msg; tracked_msg=$(_project_tracked_ignored_message "$root" "$repo")

    if [[ -z "$changed" ]]; then
        local last; last=$(_status_last_saved "$root" ".cco")
        if [[ -n "$last" ]]; then
            printf '%s/.cco is clean — nothing to save (last saved %s)\n' "$repo" "$last"
        else
            printf '%s/.cco is clean, and has never been committed — %s records its first version\n' \
                "$repo" "'cco project save'"
        fi
        # Still worth saying: a barrier that is already broken will refuse the FIRST
        # save the user makes, and the clean case is when they can fix it for free.
        [[ -n "$gaps" ]] && _project_status_report_gaps "$repo" "$gaps"
        [[ -n "$tracked_msg" ]] && printf '  %s\n' "$tracked_msg"
        _project_config_report_members "$root"
        return 0
    fi

    # D14 — the SECOND refusal path, previewed over the very set listed below. A1
    # anticipated only the barrier, so a `.cco/.netrc` rendered as `A .netrc`
    # followed by `→ cco project save` — a preview promising a save that refuses.
    local leak=""
    leak=$(printf '%s\n' "$changed" | _status_paths ".cco/" | _secret_scan_paths "$root") || true

    local n; n=$(printf '%s\n' "$changed" | grep -c .)
    if [[ -n "$gaps" || -n "$leak" ]]; then
        printf '%s/.cco — %s file(s) to save, but %s would refuse:\n' "$repo" "$n" "'cco project save'"
        [[ -n "$gaps" ]] && _project_status_report_gaps "$repo" "$gaps"
        [[ -n "$leak" ]] && _project_status_report_leak "$repo" "$leak"
        printf '\n'
    else
        printf '%s/.cco — %s file(s) to save:\n' "$repo" "$n"
    fi

    printf '%s\n' "$changed" | _status_render "$root" ".cco/" "$_STATUS_FULL"

    # Below the list, not above it: it is a standing property of the repository,
    # not a verdict on this save — and unlike the two reports above it changes
    # nothing about whether the save succeeds.
    [[ -n "$tracked_msg" ]] && printf '\n  %s\n' "$tracked_msg"

    if [[ -z "$gaps" && -z "$leak" ]]; then
        printf '\n  → cco project save\n'
    fi
    _project_config_report_members "$root"
    return 0
}

# The scan report, in the refusal's own words (D14 / §5b.3) — same finding, same
# remedy, rc 0. A preview that paraphrased would send the user hunting for a
# message that does not exist.
_project_status_report_leak() {
    local repo="$1" leak="$2"
    printf '  a secret-like file would be staged under %s/.cco:\n' "$repo"
    printf '    %s\n' "$leak"
    printf '  Move the secret into %s/.cco/secrets.env (gitignored) and try again.\n' "$repo"
}

# The barrier report, in the SAME words `save` refuses with — a preview that
# paraphrased the refusal would send the user looking for a different message.
_project_status_report_gaps() {
    local repo="$1" gaps="$2"
    if [[ "$gaps" == vacuous ]]; then
        printf '  %s/.gitignore ignores .cco/ entirely, so every coverage probe passes for a reason that has nothing to do with protection.\n' "$repo"
        _project_gitignore_vacuous_lines "$repo"
        return 0
    fi
    if [[ "$gaps" == missing ]]; then
        printf '  %s/.cco/.gitignore is missing — without it a secret dropped under .cco/ would be committed.\n' "$repo"
    else
        printf '  %s/.cco/.gitignore does not ignore: %s\n' "$repo" "$gaps"
    fi
    printf '  Add these lines to %s/.cco/.gitignore (cco does not write that file for you — it is yours):\n' "$repo"
    _project_save_gitignore_lines
}

cmd_project_history() {
    _history_parse_args project "$@"
    if [[ "$_HISTORY_HELP" == true ]]; then _project_history_usage; return 0; fi

    local root; root=$(_project_unit_root)
    [[ -n "$root" ]] || die "not inside a cco project — 'cco project history' reads the <repo>/.cco/ of the repo you run it from. cd into a repo that has .cco/project.yml."
    local repo; repo=$(basename "$root")

    # An absent history is a normal state, never a die (design §3.3) — a project
    # that has not committed its config yet, or a repo not under git at all, gets
    # told what to run, at rc 0.
    if ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        info "$repo is not a git repository, so its .cco/ has no history yet — 'git init' it, then 'cco project save'"
        return 0
    fi
    if ! _history_has_commits "$root" ".cco"; then
        info "$repo/.cco has never been committed — run 'cco project save' to record its first version"
        return 0
    fi

    _history_render "$root" ".cco" ".cco/" "$_HISTORY_N" "$_HISTORY_FULL"
}
