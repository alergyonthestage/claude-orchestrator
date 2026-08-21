#!/usr/bin/env bash
# lib/config-history.sh — the READ half of the config 2x2 (ADR-0038 D2/D6).
#
#   cco project history   <repo>/.cco  — the repo's own git, path-filtered to .cco/
#   cco config  history   ~/.cco       — the personal store's own git, unfiltered
#
# ONE renderer for both. What differs between the two stores is only data: the git
# root, the pathspec, and the prefix stripped from a changed path before it is
# grouped. The verb bodies stay with their stores (cmd-project-save.sh /
# cmd-config.sh) and call in here — a second renderer would drift in exactly the
# column that earns the verb.
#
# WHY A PATH FILTER AND NOT A COMMIT TRAILER (ADR-0038 D3): `git log -- <path>`
# answers "how did my config change" however the commit was made. A trailer stamped
# by this verb answers "how did THIS VERB change my config" — measured on this repo,
# that is 0 of the 5 real config commits. Config edited by hand, by another session
# or by `cco sync` is the normal case.
#
# Provides: _history_parse_args(), _history_render(), _history_has_commits(),
#   _history_group_label()
# Dependencies: colors.sh (die)

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
