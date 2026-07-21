#!/usr/bin/env bash
# lib/cmd-join.sh — `cco join <project> [--sync] [--name <name>]` (ADR-0034).
#
# Journey E: add the CURRENT repo as a new MEMBER of an existing project defined
# in another repo. It embeds the joining repo's machine-agnostic coordinate
# (name + url derived from `git remote get-url origin`, ADR-0017 D1/D2) into the
# project's `repos[]` and registers the name→path binding in the machine-local
# index. With --sync the joining repo also RECEIVES the project's <repo>/.cco/
# (Case B); without it the repo stays a code-only member (Case A).
#
# Which member project.yml gets the repos[] edit (ADR-0034, the same multi-repo
# same-id pattern as `cco project rename`):
#   - OWNED members in sync (status synced) are edited automatically. Adding a
#     name to repos[] edits a NON-discriminator field (the sync guard keys on
#     `name:`, ADR-0024 D2), so a partial edit is NOT permanent divergence — it
#     converges to the other members on the next `cco sync`. Hence join is NOT
#     strict like rename (which rewrites `name:` itself).
#   - if any owned member is DIVERGENT (Case C, hand-edited .cco/), join PROMPTS
#     which member's project.yml to update (or all) — the maintainer ruling.
#   - foreign / code-only / unresolved members are never edited (no reachable or
#     owned .cco/ to write); they converge later via `cco sync`.
# The machine-local index edits apply together; the cross-repo project.yml edits
# live in separate git trees and cannot be transactional, so the user is warned
# to commit + push + `cco sync` each changed repo (P17 delegate-to-git).
#
# Journey C (register an already-committed .cco/ on this machine) is REMOVED — it
# is fully covered by `cco start` (cwd-first) and `cco resolve --scan`.
#
# Provides: cmd_join()
# Dependencies: colors.sh, utils.sh (_cco_valid_project_name), paths.sh
#   (_cco_project_id), index.sh (_index_get_project_repos/_index_set_project_repos/
#   _index_set_path/_project_iter_members), cmd-project-add.sh (_yml_append_coord/
#   _yml_section_has_name), cmd-sync.sh (cmd_sync, for --sync + its D2 clobber-guard)

cmd_join() {
    local project="" do_sync=false name_override=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sync) do_sync=true; shift ;;
            --name) [[ $# -lt 2 ]] && die "--name requires a value"; name_override="$2"; shift 2 ;;
            --help|-h)
                cat <<'EOF'
Usage: cco join <project> [--sync] [--name <name>]

Add the current repo to <project> (defined in another repo) as a MEMBER: embed
its coordinate into the project's repos[] and bind its path in the index.

Arguments:
  project          Name of an existing project registered on this machine

Options:
  --name <name>    Logical member name for this repo (default: the dir basename;
                   prompted interactively, falls back to basename non-interactively)
  --sync           Also copy the project's <repo>/.cco/ into this repo (Case B).
                   Skipped + warned if this repo already hosts a different project
                   (the ADR-0024 D2 clobber-guard). Without it the repo stays a
                   code-only member (Case A).

The coordinate url is derived from 'git remote get-url origin'. The repos[] edit
is applied to the project's in-sync member repos; a divergent project prompts
which member's project.yml to update. Commit + push the changed project.yml in
each member, then run 'cco sync'.
EOF
                return 0
                ;;
            -*) die "Unknown option: $1. Run 'cco join --help'." ;;
            *)  if [[ -z "$project" ]]; then project="$1"; shift
                else die "Unexpected argument: $1"; fi ;;
        esac
    done
    [[ -z "$project" ]] && die "Usage: cco join <project> [--sync] [--name <name>]"

    local repo; repo="$(pwd -P)"

    # ── The project must already be registered here (defined elsewhere) ───
    local members; members=$(_index_get_project_repos "$project")
    [[ -n "$members" ]] || die "No project named '$project' is registered on this machine. Discover it with 'cco resolve --scan <dir>', or check the name with 'cco list projects'."

    # ── This repo must not already BE the project (it would be the host) ──
    local hosted; hosted=$(_cco_project_id "$repo" 2>/dev/null)
    [[ "$hosted" == "$project" ]] && die "This repo already hosts '$project' — it is the project, not a new member."

    # ── Member name: --name > interactive prompt (default basename) > basename
    local repo_name="$name_override" default_name; default_name=$(basename "$repo")
    if [[ -z "$repo_name" ]]; then
        if [[ -t 0 ]]; then
            printf "Member name for this repo [%s]: " "$default_name" >&2
            read -r repo_name
            [[ -z "$repo_name" ]] && repo_name="$default_name"
        else
            repo_name="$default_name"
        fi
    fi
    _cco_valid_project_name "$repo_name" \
        || die "Invalid member name '$repo_name' — lowercase letters, numbers, and hyphens only (starting alphanumeric)."

    # ── Uniqueness: not already a member of this project ─────────────────
    local m
    for m in $members; do
        [[ "$m" == "$repo_name" ]] && die "'$repo_name' is already a member of '$project'. Choose a different --name."
    done

    # ── Derive the joining repo's coordinate url from origin (ADR-0017) ───
    local url=""
    if git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        url=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
        [[ -n "$url" ]] && info "derived url from origin: $url"
    fi
    [[ -z "$url" ]] && warn "no 'origin' remote — joining without a url coordinate (set it later in project.yml)."

    # ── Collect owned members (which project.yml files can carry the edit) ─
    local -a owned_names=() owned_dirs=() owned_status=()
    local m_name m_path m_status divergent=false
    while IFS=$'\t' read -r m_name m_path m_status; do
        [[ -z "$m_name" ]] && continue
        case "$m_status" in
            synced)    owned_names+=("$m_name"); owned_dirs+=("$m_path"); owned_status+=("synced") ;;
            divergent) owned_names+=("$m_name"); owned_dirs+=("$m_path"); owned_status+=("divergent"); divergent=true ;;
        esac
    done < <(_project_iter_members "$project")

    if [[ ${#owned_dirs[@]} -eq 0 ]]; then
        die "No member repo of '$project' with a committed .cco/ is resolved here — run 'cco resolve' to bring one onto this machine, then 'cco join' again."
    fi

    # ── Choose which member project.yml to edit (Case B vs Case C) ───────
    local -a target_dirs=()
    local source_name="${owned_names[0]}"   # default --sync source = first owned
    if [[ "$divergent" != true ]]; then
        target_dirs=( "${owned_dirs[@]}" )            # Case B: all in-sync members
    else
        # Case C — divergent members exist; the maintainer ruling is to PROMPT.
        if [[ ! -t 0 ]]; then
            die "Project '$project' has divergent members (their .cco/ differ). Re-run 'cco join' interactively to choose which to update, or converge them first with 'cco sync'."
        fi
        echo "Project '$project' has members with divergent .cco/. Pick the project.yml to update:" >&2
        local i
        for i in "${!owned_names[@]}"; do
            printf "  %d) %s  [%s]  %s\n" "$((i+1))" "${owned_names[$i]}" "${owned_status[$i]}" "${owned_dirs[$i]}" >&2
        done
        printf "  a) all\nUpdate which? [a]: " >&2
        local choice; read -r choice
        choice="${choice:-a}"
        if [[ "$choice" == "a" || "$choice" == "A" ]]; then
            target_dirs=( "${owned_dirs[@]}" )
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#owned_dirs[@]} )); then
            target_dirs=( "${owned_dirs[$((choice-1))]}" )
            source_name="${owned_names[$((choice-1))]}"
        else
            die "Invalid choice '$choice' — aborted, nothing changed."
        fi
    fi

    # ── Apply the repos[] edit to each chosen member project.yml ─────────
    local -a changed=()
    local d yml
    for d in "${target_dirs[@]}"; do
        yml="$d/.cco/project.yml"
        [[ -f "$yml" ]] || continue
        if _yml_section_has_name "$yml" repos "$repo_name"; then
            warn "skipping $yml — '$repo_name' is already in its repos[]"
            continue
        fi
        _yml_append_coord "$yml" repos "$repo_name" ${url:+"url=$url"}
        changed+=("$d")
    done

    # ── Machine-local index: membership + path (applied together) ────────
    # S2b: this is the highest-consequence site of the class. Called bare, a failed
    # write left the verb printing "✓ Joined" and then telling the user to COMMIT
    # AND PUSH a project.yml declaring a member that no index binds — the blast
    # radius leaves the machine and reaches teammates on pull. (v3's V3-01 damaged
    # one session; this damages a versioned, distributed artifact.) errexit is
    # disabled by bin/cco's `|| _cco_rc=$?` dispatch, so propagate explicitly.
    #
    # project.yml has ALREADY been rewritten in the member repos at this point, so
    # the message must say so — the recovery is a local re-bind, and the user must
    # not be left guessing whether to git-revert instead.
    if ! _index_set_project_repos "$project" $members "$repo_name" \
       || ! _index_set_path "$project" "$repo_name" "$repo"; then
        local _also=""
        [[ ${#changed[@]} -gt 0 ]] && _also=" project.yml WAS updated in ${#changed[@]} repo(s) — do NOT commit it yet."
        die "Updated project.yml for '$project', but the machine-local index could not be updated, so member '$repo_name' is not bound on this machine.${_also} Run 'cco resolve --scan $repo' to bind it, then re-check before committing."
    fi

    ok "Joined '$project' as member '$repo_name'."

    # ── Optional --sync: receive the project's .cco/ (D2 guard via cmd_sync)
    if [[ "$do_sync" == true ]]; then
        info "Syncing '$project' config into this repo from '$source_name'…"
        cmd_sync "$repo_name" --from "$source_name" --auto-approve \
            || warn "Run 'cco sync' to receive the config (or resolve the D2 clobber-guard if this repo hosts a different project)."
    fi

    # ── Delegate the cross-repo commit to git (P17) ──────────────────────
    if [[ ${#changed[@]} -gt 0 ]]; then
        warn "Commit + push the updated .cco/project.yml in each member repo, then run 'cco sync':"
        for d in "${changed[@]}"; do info "  $d"; done
    fi
}
