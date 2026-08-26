#!/usr/bin/env bash
# lib/config-read.sh — the READ half of the config matrix (ADR-0038 D2/D6 + A1).
#
#   cco project history / status   <repo>/.cco  — the repo's own git, scoped to .cco/
#   cco config  history / status   ~/.cco       — the personal store's own git
#
# TWO questions, deliberately two verbs (A1 D9): `history` is what WAS saved,
# `status` is what is NOT saved yet — the distance `git log` keeps from `git status`.
#
# ONE renderer per question, shared by both stores. What differs between the stores
# is only data: the git root, the pathspec(s), and the prefix stripped from a changed
# path before it is grouped. The verb bodies stay with their stores
# (cmd-project-save.sh / cmd-config.sh) and call in here — a second renderer would
# drift in exactly the column that earns the verb.
#
# WHY A PATH FILTER AND NOT A COMMIT TRAILER (ADR-0038 D3): `git log -- <path>`
# answers "how did my config change" however the commit was made. A trailer stamped
# by this verb answers "how did THIS VERB change my config" — measured on this repo,
# that is 0 of the 5 real config commits. Config edited by hand, by another session
# or by `cco sync` is the normal case.
#
# Provides: _history_parse_args(), _history_render(), _history_has_commits(),
#   _history_group_label(), _status_parse_args(), _status_changed(), _status_paths(),
#   _status_render()
# Dependencies: colors.sh (die), secrets.sh (_secret_match_filename/_secret_match_content —
#   `--full` must not print the contents of a file it just called secret-like)

# The default number of commits shown (ADR-0038 Open / design §7). Fits a terminal
# without scrolling and is what `-n` exists to change.
_HISTORY_DEFAULT_N=10

# Parse the surface both history verbs share: `-n <count>` and `--full`.
# Sets _HISTORY_N, _HISTORY_FULL and _HISTORY_HELP; the caller prints its own
# usage when _HISTORY_HELP is true (each verb names its own store).
# Usage: _history_parse_args <verb-label> [args...]
_history_parse_args() {
    local verb="$1"; shift
    _HISTORY_N="$_HISTORY_DEFAULT_N"
    _HISTORY_FULL=false
    _HISTORY_HELP=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) _HISTORY_HELP=true; shift ;;
            -n|--max-count)
                [[ $# -lt 2 ]] && die "-n requires a count."
                case "$2" in
                    ''|*[!0-9]*|0) die "-n takes a positive integer, got '$2'." ;;
                esac
                _HISTORY_N="$2"; shift 2 ;;
            --full) _HISTORY_FULL=true; shift ;;
            -*) die "Unknown option: $1. Run 'cco $verb history --help'." ;;
            *)  die "Unexpected argument: $1. 'cco $verb history' takes options only." ;;
        esac
    done
    return 0
}

# Collapse a config-relative path to the config PART it belongs to (D6). This
# column is what earns the verb over `git log --oneline`: it answers the question
# the user actually asked without sending them back to git.
#
# Grouped: the multi-file overlay dirs one level down (claude/rules, .claude/agents,
# packs/<name>, templates/<name>, …) — listing them file by file would bury the
# answer. Everything else reports as its own config-relative path, which says
# WHERE it is as well as what it is called.
# Usage: _history_group_label <config-relative-path>
_history_group_label() {
    local rel="$1" s1 rest
    s1="${rel%%/*}"
    case "$s1" in
        claude|.claude|packs|templates) : ;;
        *) printf '%s\n' "$rel"; return 0 ;;
    esac
    rest="${rel#*/}"
    # Only ONE segment left ⇒ a file directly under the dir (claude/CLAUDE.md):
    # it is not a group, so it reports as itself.
    [[ "$rest" == "$rel" || "$rest" != */* ]] && { printf '%s\n' "$rel"; return 0; }
    printf '%s/%s\n' "$s1" "${rest%%/*}"
}

# True (exit 0) iff <root>'s git history holds at least one commit touching
# <pathspec> (whole repo when empty). The degradation branch of both verbs keys
# off this — an absent history is a normal state, never a die (design §3.3).
# Usage: _history_has_commits <git_root> [<pathspec>]
_history_has_commits() {
    local root="$1" spec="${2:-}" out
    local -a sel=()
    [[ -n "$spec" ]] && sel=( -- "$spec" )
    out=$(git -C "$root" log -n 1 --format=%h ${sel[@]+"${sel[@]}"} 2>/dev/null) || out=""
    [[ -n "$out" ]]
}

# The changed-parts column for ONE commit: its changed paths under <pathspec>,
# stripped of <strip> and collapsed to groups, de-duplicated, in first-seen order.
# Echoes an em dash when the commit touches nothing under the filter (a merge
# commit shows no names by default) — never an empty column.
# Usage: _history_parts <git_root> <sha> <pathspec> <strip-prefix>
_history_parts() {
    local root="$1" sha="$2" spec="$3" strip="$4"
    local -a sel=()
    [[ -n "$spec" ]] && sel=( -- "$spec" )
    local p rel lbl seen=" " out=""
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        rel="$p"
        [[ -n "$strip" ]] && rel="${p#"$strip"}"
        lbl=$(_history_group_label "$rel")
        [[ "$seen" == *" $lbl "* ]] && continue
        seen="$seen$lbl "
        out="${out}${out:+, }$lbl"
    done < <(git -C "$root" show --format= --name-only "$sha" ${sel[@]+"${sel[@]}"} 2>/dev/null)
    printf '%s\n' "${out:-—}"
}

# Render the compact listing to STDOUT — it is data, so it pipes; the info/ok/note
# lines around it are stderr like everywhere else in the CLI.
#
# One line per commit (D6): date · short sha · author · subject · changed parts.
# With <full> true, each line is followed by that commit's diff, path-filtered the
# same way — `--full` adds the diff, it does not widen the filter.
# Usage: _history_render <git_root> <pathspec> <strip-prefix> <count> <full:true|false>
_history_render() {
    local root="$1" spec="$2" strip="$3" n="$4" full="$5"
    local -a sel=()
    [[ -n "$spec" ]] && sel=( -- "$spec" )
    local sha date author subj
    while IFS=$'\t' read -r sha date author subj; do
        [[ -z "$sha" ]] && continue
        printf '%s  %-9s  %-16.16s  %-44s  %s\n' \
            "$date" "$sha" "$author" "$subj" "$(_history_parts "$root" "$sha" "$spec" "$strip")"
        if [[ "$full" == true ]]; then
            git -C "$root" show --format= --patch "$sha" ${sel[@]+"${sel[@]}"} 2>/dev/null
            printf '\n'
        fi
    done < <(git -C "$root" log -n "$n" --date=short \
                 --format='%h%x09%ad%x09%an%x09%s' ${sel[@]+"${sel[@]}"} 2>/dev/null)
    return 0
}

# ── The `status` half (ADR-0038 Amendment A1) ────────────────────────
#
# `history` answers what WAS saved; `status` answers what is NOT saved yet. The
# preview is only worth having if it reproduces the save's OWN rule about what gets
# committed (A1 D11) — which differs per store, and is passed in as pathspecs:
#
#   project  →  `.cco`                (everything under it that git does not ignore)
#   config   →  the _CONFIG_ALLOWLIST entries that exist
#
# A plain `git status` on either root would name files neither verb would commit.
# That is the failure this shape exists to prevent — the same class as the design's
# warning against `_sync_synced_files`: the *nearly* right list is the dangerous one.

# Parse the `status` surface: `--full` only. Sets _STATUS_FULL and _STATUS_HELP.
# Usage: _status_parse_args <verb-label> [args...]
_status_parse_args() {
    local verb="$1"; shift
    _STATUS_FULL=false
    _STATUS_HELP=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) _STATUS_HELP=true; shift ;;
            --full) _STATUS_FULL=true; shift ;;
            -*) die "Unknown option: $1. Run 'cco $verb status --help'." ;;
            *)  die "Unexpected argument: $1. 'cco $verb status' takes options only." ;;
        esac
    done
    return 0
}

# Echo "<mark>\t<config-relative-path>" for every change the matching `save` would
# commit — gitignored files excluded by git itself, everything outside the
# pathspecs excluded by the pathspecs.
#
# `-z` (not the default quoting) so a path with a space or a non-ASCII character is
# read whole; `--no-renames` so every record is the two-char code plus one path.
# Usage: _status_changed <git_root> <strip-prefix> [<pathspec>...]
_status_changed() {
    local root="$1" strip="$2"; shift 2
    local -a sel=()
    [[ $# -gt 0 ]] && sel=( -- "$@" )
    local rec xy p mark
    while IFS= read -r -d '' rec; do
        [[ -z "$rec" ]] && continue
        xy="${rec:0:2}"
        p="${rec:3}"
        [[ -z "$p" ]] && continue
        # One meaning per record: what this file's fate is in the commit `save`
        # would make. The index/worktree split the two-char code carries is not the
        # user's question here — "will it be committed, and as what" is.
        case "$xy" in
            '??') mark=A ;;
            *D*)  mark=D ;;
            A*)   mark=A ;;
            *)    mark=M ;;
        esac
        [[ -n "$strip" ]] && p="${p#"$strip"}"
        printf '%s\t%s\n' "$mark" "$p"
    done < <(git -C "$root" status --porcelain -z -uall --no-renames ${sel[@]+"${sel[@]}"} 2>/dev/null)
}

# The paths of a `_status_changed` set, restored to <git_root>-relative form — the
# shape `_secret_scan_paths` reads. This is what lets `status` preview the SECOND
# refusal path (ADR-0038 A2 D14) without staging: the scan gate reads the index, and
# §5b.4 forbids this verb from writing to it, so the preview asks the same question
# of the set it just computed.
#
# ⚠ DELETIONS ARE DROPPED, and the reason is the refusal's, not this verb's
# (ADR-0038 A4 D21): `save`'s scan skips them with `--diff-filter=d`, because a
# path being removed carries no content into the commit — so a preview that kept
# them would announce a refusal that will not happen. The listing above still
# SHOWS the deletion as `D <file>`; what is filtered is only the set handed to the
# scan. Same set on both sides is the D11 rule, in whichever direction it moves.
# Usage: _status_paths <strip-prefix>   [stdin: changed lines]
_status_paths() {
    local strip="$1" mark rel
    while IFS=$'\t' read -r mark rel; do
        [[ -z "$mark" ]] && continue
        [[ "$mark" == D ]] && continue
        printf '%s%s\n' "$strip" "$rel"
    done
    return 0
}

# Render the changed set to STDOUT (it is data, so it pipes). With <full> true each
# entry is followed by its diff — including NEW files, which `git diff HEAD` cannot
# show: those are diffed against /dev/null with `--no-index`, so nothing has to be
# staged. A read verb never touches the index, so `--intent-to-add` is not an option
# here however convenient it looks.
# Usage: _status_render <git_root> <strip-prefix> <full:true|false>   [stdin: changed lines]
_status_render() {
    local root="$1" strip="$2" full="$3"
    local mark rel path hit
    while IFS=$'\t' read -r mark rel; do
        [[ -z "$mark" ]] && continue
        printf '  %s  %s\n' "$mark" "$rel"
        [[ "$full" == true ]] || continue
        path="${strip}${rel}"
        # ⚠ A preview that names a file "secret-like" and then prints its contents
        # four lines below has told the user nothing it did not also publish (A2
        # review, measured on a `.cco/.netrc`: the password appeared in the diff).
        # A NEW file is diffed against /dev/null, so `--full` renders it whole.
        #
        # The question is asked per file rather than reused from the scan, because
        # the scan stops at its FIRST hit while every listed file is rendered here.
        # `*.example` is exempt on the same terms as the scan (FR-S3): a skeleton
        # exists to be read, and withholding its diff would hide the one file whose
        # whole purpose is to be committed and inspected.
        if [[ "$rel" != *.example ]]; then
            if hit=$(_secret_match_filename "$path" 2>/dev/null) && [[ -n "$hit" ]]; then
                printf '      diff withheld — %s matches the secret pattern %s\n' "$rel" "$hit"
                continue
            fi
            if [[ -f "$root/$path" ]] && hit=$(_secret_match_content "$root/$path" 2>/dev/null) && [[ -n "$hit" ]]; then
                printf '      diff withheld — %s matches a secret content pattern at line %s\n' "$rel" "${hit%%:*}"
                continue
            fi
        fi
        if git -C "$root" cat-file -e "HEAD:$path" 2>/dev/null; then
            git -C "$root" diff HEAD -- "$path" 2>/dev/null
        else
            git -C "$root" diff --no-index -- /dev/null "$path" 2>/dev/null || true
        fi
    done
    return 0
}

# The one-line "last saved" tail for a clean store — it is what makes `status` a
# complete answer rather than a bare "nothing to do", and it is the natural handoff
# to `history`. Echoes empty when there is no history to name.
# Usage: _status_last_saved <git_root> [<pathspec>]
_status_last_saved() {
    local root="$1" spec="${2:-}"
    local -a sel=()
    [[ -n "$spec" ]] && sel=( -- "$spec" )
    git -C "$root" log -n 1 --date=short --format='%ad %h %s' ${sel[@]+"${sel[@]}"} 2>/dev/null || printf ''
}
