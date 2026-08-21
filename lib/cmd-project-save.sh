#!/usr/bin/env bash
# lib/cmd-project-save.sh — `cco project save` + `cco project history` (ADR-0038).
#
# The PROJECT column of the config 2x2: `<repo>/.cco/` is versioned by the repo's
# own git, so this is the twin of `cco config save` for a store cco does NOT own.
#
#   cco project save [-m <msg>]        stage .cco/** + secret-scan + commit
#   cco project history [-n N] [--full]  read that history back
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
# Provides: cmd_project_save(), cmd_project_history()
# Dependencies: colors.sh (ok/info/note/die), cmd-resolve.sh (_resolve_find_unit_dir),
#   secrets.sh (_secret_scan_staged, _SECRET_PROJECT_GITIGNORE_CLASSES,
#   _secret_gitignore_probe), config-history.sh (_history_*),
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

# D7 barrier — the FIRST of the two, and the one that must hold before anything is
# staged. `<repo>/.cco/.gitignore` must exist AND must actually ignore each secret
# class cco's own scaffold declares.
#
# Coverage is measured by ASKING GIT (`git check-ignore`), not by grepping the file
# for a literal: a rule that matches is what protects the user, however it is
# spelled and wherever in the repo's ignore chain it lives.
_project_save_assert_gitignore() {
    local root="$1"
    local repo; repo=$(basename "$root")
    local gi="$root/.cco/.gitignore"

    if [[ ! -f "$gi" ]]; then
        error "refusing to save — $repo/.cco/.gitignore is missing."
        echo "  Without it, a secret dropped under .cco/ would be committed. Create it with:" >&2
        _project_save_gitignore_lines >&2
        die "cco does not write that file for you — it is a versioned file in YOUR repository (ADR-0038 D7)."
    fi

    local cls probe missing=""
    for cls in "${_SECRET_PROJECT_GITIGNORE_CLASSES[@]}"; do
        probe=$(_secret_gitignore_probe "$cls")
        git -C "$root" check-ignore -q ".cco/$probe" 2>/dev/null && continue
        missing="${missing}${missing:+, }$cls"
    done
    [[ -z "$missing" ]] && return 0

    error "refusing to save — $repo/.cco/.gitignore does not ignore: $missing"
    echo "  Add the missing lines to $repo/.cco/.gitignore, then retry:" >&2
    _project_save_gitignore_lines >&2
    die "cco does not edit that file for you — it is a versioned file in YOUR repository (ADR-0038 D7)."
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

# D4 — after the commit, report what this invocation did NOT cover. Two INDEPENDENT
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
_project_save_report_members() {
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

    _project_save_report_members "$root"
    return 0
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
