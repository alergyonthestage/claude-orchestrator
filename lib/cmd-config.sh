#!/usr/bin/env bash
# lib/cmd-config.sh — `cco config` : version + sync the personal ~/.cco store.
#
# Domain A (design §6.1, ADR-0008): ~/.cco is the user's personal global config
# store — ALWAYS a git-versioned working tree (J0 git-inits it; ADR-0017 D4), with
# only the remote opt-in. Versioning is explicit, manual, semantic commits — NO
# auto-commit in v1. Sync transports already-made commits, never fabricates them.
#
#   cco config save [-m <msg>]   stage the allowlisted set + secret-scan + commit
#   cco config status [--full]   what save WOULD commit (ADR-0038 A1; never writes)
#   cco config history [-n N]    read that history back (ADR-0038 D2, --full for diffs)
#   cco config push              push to the (private) remote — advisory warning
#   cco config pull              fast-forward pull; non-FF -> abort + notify
#   cco config validate [--fix]  orphan-sanitization of id-keyed internal state
#                                (ADR-0021 Dec.5; detect-only, --fix prunes
#                                preview-first + confirmed, never automatic)
#
# The allowlist is a DOUBLE BARRIER (design §6.1): a whitelist .gitignore (`*` then
# `!`-re-include only authored config) AND explicit-path staging — NEVER `git add
# -A`. secrets.env stays gitignored; secrets.env.example is committed. A 2-pass
# secret scan (filename + content, *.example exempt) refuses a leak in any staged
# file. `cco config validate` (orphan-sanitization of id-keyed internal state;
# preview-first `--fix`) is implemented here (_config_validate, ADR-0021 §5 /
# design §9 P5 — the lifecycle/delete-cascade work).
#
# Provides: cmd_config(), _config_validate(), _config_history(), _config_status()
# Dependencies: colors.sh, utils.sh, secrets.sh (_secret_scan_staged — the ONE
#   scanner both save gates share; the project twin passes a pathspec, this one
#   scans the whole store), config-read.sh (_history_/_status_ helpers for the read verbs),
#   paths.sh (_cco_{config,state,data,cache}_dir, _cco_remotes_{,token_}file),
#   index.sh (_index_list_paths/projects, _index_get_path/_index_get_project_repos,
#   _index_remove_path/_index_remove_project), tags.sh (_tags_all/_tags_forget),
#   cmd-remote.sh (_remote_token_remove)

# The allowlisted top-level entries committed from ~/.cco (design §2.3/§6.1).
# secrets.env is deliberately ABSENT (gitignored); secrets.env.example is present.
_CONFIG_ALLOWLIST=( .gitignore packs templates .claude \
                    setup.sh setup-build.sh mcp-packages.txt languages \
                    secrets.env.example )

# Write the whitelist .gitignore (first barrier) if it is missing. Idempotent —
# never clobbers a user-edited one.
_config_ensure_gitignore() {
    local cfg="$1"
    local gi="$cfg/.gitignore"   # separate: `local` expands all its args first (INV-LOCAL)
    [[ -f "$gi" ]] && return 0
    cat > "$gi" <<'EOF'
# cco ~/.cco allowlist — commit ONLY authored config (the first of the
# double-barrier; `cco config save` also stages explicit paths, never `git add -A`).
# secrets.env stays ignored; secrets.env.example (skeleton) is committed.
*
!.gitignore
!packs/
!packs/**
!templates/
!templates/**
!.claude/
!.claude/**
!setup.sh
!setup-build.sh
!mcp-packages.txt
!languages
!secrets.env.example
EOF
}

_config_save_usage() {
    cat <<'EOF'
Usage: cco config save [-m <message>]

Commit your personal ~/.cco store — the allowlisted config only — with a secret
scan. Explicit and manual: cco never auto-commits.

Options:
  -m, --message <msg>    Commit message (default: "config update")

Only the allowlisted entries are staged (.claude, packs, templates, setup files,
the secrets skeleton) — never `git add -A`, so a stray file in ~/.cco is left
alone. Your real secrets.env stays gitignored. Preview it with 'cco config
status'; read it back with 'cco config history'. The project twin is
'cco project save'.
EOF
}

_config_save() {
    local msg=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            # ⚠ Not optional politeness. Every other verb in this matrix answers
            # `--help`, and the house gate probe (assert_gate_allows) DRIVES
            # `<verb> --help` — so without this arm the verb could not be probed
            # at all, and P-B's "the two stores must not drift into different
            # spellings" was visibly broken inside the reviewed surface.
            --help|-h) _config_save_usage; return 0 ;;
            -m|--message) [[ $# -lt 2 ]] && die "-m requires a commit message."; msg="$2"; shift 2 ;;
            -*) die "Unknown option: $1. Run 'cco config save --help'." ;;
            *)  die "Unexpected argument: $1. 'cco config save' takes options only." ;;
        esac
    done

    # Graceful ro-mount guard (CLI-surface review): the shim's write axis is flat
    # (any edit level passes), but the ~/.cco mount is rw only at edit-global/
    # edit-all — at edit-project it is read-only. Without this, `git add`/`git
    # init` fail silently on the ro tree and save reports a misleading "already up
    # to date" (or a raw git error). Emit a clear, actionable message instead.
    if _cco_container_operator; then
        case "$(_env_access)" in
            edit-global|edit-all) : ;;   # ~/.cco mounted rw
            *) die "'cco config save' versions your personal ~/.cco store, which is read-only at cco_access=$(_env_access). Start the session with --cco-access edit-global (or edit-all), or run 'cco config save' on your host." ;;
        esac
    fi

    local cfg; cfg=$(_cco_config_dir)
    [[ -d "$cfg/.git" ]] || git -C "$cfg" init -q >/dev/null 2>&1 || die "Could not initialize ~/.cco as a git repo."
    _config_ensure_gitignore "$cfg"

    # Second barrier: stage ONLY the allowlisted paths that exist — never `git add -A`.
    local entry staged=false
    for entry in "${_CONFIG_ALLOWLIST[@]}"; do
        [[ -e "$cfg/$entry" ]] || continue
        git -C "$cfg" add -- "$entry" 2>/dev/null && staged=true
    done

    if git -C "$cfg" diff --cached --quiet 2>/dev/null; then
        info "~/.cco is already up to date — nothing to save"
        return 0
    fi

    # Secret scan the staged set; abort (and unstage) on a leak.
    local leak
    if ! leak=$(_secret_scan_staged "$cfg"); then
        git -C "$cfg" reset -q >/dev/null 2>&1 || true
        error "refusing to save — a secret-like file is staged:"
        printf '  %s\n' "$leak" >&2
        die "Move the secret into ~/.cco/secrets.env (gitignored) and try again."
    fi

    [[ -z "$msg" ]] && msg="config update"
    git -C "$cfg" commit -q -m "$msg" >/dev/null 2>&1 || die "git commit failed in ~/.cco."
    local sha; sha=$(git -C "$cfg" rev-parse --short HEAD 2>/dev/null)
    ok "saved ~/.cco @ ${sha} — ${msg}"
}

_config_status_usage() {
    cat <<'EOF'
Usage: cco config status [--full]

Show what 'cco config save' would commit from your personal ~/.cco store. Nothing
is written, staged or changed.

Options:
      --full             Also show the diff of each change

Each line is a file and its fate in that commit: M modified, A new, D deleted.
Only the allowlisted config is listed — a stray file in ~/.cco is not shown,
because save would not commit it either. What was already saved is
'cco config history'.
EOF
}

# The preview for the PERSONAL store (ADR-0038 A1). Its pathspecs are the allowlist,
# not the whole tree — A1 D11: a preview is worth having only if it reproduces its
# own save's rule about what gets committed, and `_config_save` stages
# `_CONFIG_ALLOWLIST` and nothing else. A plain `git status` on ~/.cco would name
# files this verb's twin would never commit.
_config_status() {
    _status_parse_args config "$@"
    if [[ "$_STATUS_HELP" == true ]]; then _config_status_usage; return 0; fi

    local cfg; cfg=$(_cco_config_dir)
    # ⚠ Not reachable from the host: J0 (_cco_first_run, lib/migrate.sh) git-inits
    # ~/.cco on EVERY host command, so a store without .git cannot survive to here.
    # Kept for the container, where the store is a MOUNT and may arrive without one —
    # and because the alternative is worse: _status_changed on a non-git tree returns
    # nothing, which would render as "clean", and "clean" claims the config is saved.
    # The host suite therefore covers the never-saved state, not this branch.
    if [[ ! -d "$cfg/.git" ]]; then
        printf '~/.cco is not versioned yet — %s records its first version\n' "'cco config save'"
        return 0
    fi

    # Exactly the set `_config_save` stages: allowlisted AND present.
    local -a specs=(); local entry
    for entry in "${_CONFIG_ALLOWLIST[@]}"; do
        [[ -e "$cfg/$entry" ]] && specs+=("$entry")
    done
    if [[ ${#specs[@]} -eq 0 ]]; then
        printf '~/.cco holds no config to save yet\n'
        return 0
    fi

    local changed; changed=$(_status_changed "$cfg" "" ${specs[@]+"${specs[@]}"})
    if [[ -z "$changed" ]]; then
        local last; last=$(_status_last_saved "$cfg")
        if [[ -n "$last" ]]; then
            printf '~/.cco is clean — nothing to save (last saved %s)\n' "$last"
        else
            printf '~/.cco is clean, and has never been committed — %s records its first version\n' "'cco config save'"
        fi
        return 0
    fi

    # D14 (A2) — preview the refusal path this store HAS. `_config_save`'s first
    # barrier writes itself, so the scan is its only way to refuse; leaving it
    # unpreviewed here would rebuild, on the personal store, exactly the gap A1 D9
    # refused to leave open on one store and not the other.
    #
    # ⚠ The scan gate reads the index, and a read verb may not write to it — so it
    # is asked of the set computed above, never of a staged one.
    local leak=""
    leak=$(printf '%s\n' "$changed" | _status_paths "" | _secret_scan_paths "$cfg") || true

    local n; n=$(printf '%s\n' "$changed" | grep -c .)
    if [[ -n "$leak" ]]; then
        printf '~/.cco — %s file(s) to save, but %s would refuse:\n' "$n" "'cco config save'"
        printf '  a secret-like file would be staged:\n'
        printf '    %s\n' "$leak"
        printf '  Move the secret into ~/.cco/secrets.env (gitignored) and try again.\n'
        printf '\n'
    else
        printf '~/.cco — %s file(s) to save:\n' "$n"
    fi
    printf '%s\n' "$changed" | _status_render "$cfg" "" "$_STATUS_FULL"
    [[ -z "$leak" ]] && printf '\n  → cco config save\n'
    return 0
}

_config_history_usage() {
    cat <<'EOF'
Usage: cco config history [-n <count>] [--full]

Show how your personal ~/.cco store changed over time — you never need to know
where it lives or what git command reads it.

Options:
  -n, --max-count <n>    How many commits to show (default: 10)
      --full             Also show each commit's diff

Each line reports the date, the commit, the author, the message, and which parts
of the config changed. The project twin is 'cco project history'.
EOF
}

# The read half for the PERSONAL store (ADR-0038 D2). No pathspec and no strip
# prefix: the whole of ~/.cco *is* the config, unlike <repo>/.cco which is a
# subtree of a repo full of unrelated commits.
#
# This is the side the user is least able to construct the git command for — the
# store's path is not one they would guess — which is why D2 added the verb for
# BOTH stores rather than only the project one.
_config_history() {
    _history_parse_args config "$@"
    if [[ "$_HISTORY_HELP" == true ]]; then _config_history_usage; return 0; fi

    local cfg; cfg=$(_cco_config_dir)
    # Never a die on an absent history (design §3.3): a store not yet versioned is
    # a normal state, and `cco config save` is what git-inits it.
    if [[ ! -d "$cfg/.git" ]] || ! _history_has_commits "$cfg"; then
        info "~/.cco has no saved history yet — run 'cco config save' to record its first version"
        return 0
    fi
    _history_render "$cfg" "" "" "$_HISTORY_N" "$_HISTORY_FULL"
}

# True iff ~/.cco has a remote named origin.
_config_has_origin() { git -C "$1" remote get-url origin >/dev/null 2>&1; }

_config_push() {
    local cfg; cfg=$(_cco_config_dir)
    [[ -d "$cfg/.git" ]] || die "~/.cco is not versioned yet — run 'cco config save' first."
    if ! _config_has_origin "$cfg"; then
        error "no remote configured for ~/.cco."
        echo "  Add a PRIVATE remote, then retry:" >&2
        echo "    git -C ~/.cco remote add origin <your-private-repo-url>" >&2
        die "A remote is required to push."
    fi
    # Advisory (ADR-0017 D4): cco does not enforce privacy — it warns.
    warn "~/.cco holds your personal config — push only to a PRIVATE remote (cco does not enforce this)"
    local branch; branch=$(git -C "$cfg" rev-parse --abbrev-ref HEAD 2>/dev/null)
    git -C "$cfg" push -u origin "$branch" 2>&1 || die "git push failed — resolve it in ~/.cco and retry."
    ok "pushed ~/.cco to origin/${branch}"
}

_config_pull() {
    local cfg; cfg=$(_cco_config_dir)
    [[ -d "$cfg/.git" ]] || die "~/.cco is not versioned yet — nothing to pull."
    _config_has_origin "$cfg" || die "no remote configured for ~/.cco (see 'cco config push --help')."
    # Fast-forward only (ADR-0008): a non-FF pull means a real divergence the user
    # must reconcile in their editor — cco never auto-merges/auto-commits.
    if ! git -C "$cfg" pull --ff-only origin 2>/dev/null; then
        error "pull is not a fast-forward — your local ~/.cco has diverged from the remote."
        echo "  Reconcile it in your editor, then retry:" >&2
        echo "    cd ~/.cco && git pull   # resolve conflicts, commit" >&2
        die "Aborted — cco does not auto-merge config."
    fi
    ok "~/.cco is up to date with origin"
}

# ── cco config validate — orphan sanitization (ADR-0021 Dec.5) ─────────────
#
# Detects internal, id-keyed bookkeeping with no resolvable backing resource and
# (only on --fix, preview-first + confirmed) prunes it. Never automatic. Prune
# aggressiveness follows the bucket sync-class (ADR-0016): STATE/CACHE are
# machine-local + regenerable (rebuildable via `cco resolve --scan`), so they are
# pruned under the main confirmation; DATA (tags/source) is Axis-1-synced, so a
# wrong prune PROPAGATES across the user's machines — it is pruned only under a
# second, explicit confirmation, and a non-resolving DATA resource may simply
# live on another machine rather than be deleted (warn-never-hide, ADR-0019).

# Resolution predicates: does the backing resource still exist on this machine?
_cv_pack_resolves()     { [[ -d "$PACKS_DIR/$1" ]]; }
_cv_template_resolves() { [[ -d "$TEMPLATES_DIR/project/$1" || -d "$TEMPLATES_DIR/pack/$1" ]]; }
_cv_project_tracked()   { [[ -n "$(_index_get_project_repos "$1")" ]]; }

# Dispatch by resource type (singular) / tags kind (plural).
_cv_type_resolves() {
    case "$1" in
        pack)     _cv_pack_resolves "$2" ;;
        template) _cv_template_resolves "$2" ;;
        project)  _cv_project_tracked "$2" ;;
        packs)     _cv_pack_resolves "$2" ;;
        templates) _cv_template_resolves "$2" ;;
        projects)  _cv_project_tracked "$2" ;;
        *) return 0 ;;
    esac
}

# Append an orphan record: <class>\t<op>\t<arg1>\t<arg2>\t<label>.
# class = local (STATE/CACHE) | data (synced); op = idx_path|idx_proj|rmdir|token|tag.
_cv_add() { _CV_RECS+=( "$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\t'"$5" ); }

# Append a MALFORMED index record (ADR-0052 §5, WS-5): reported in its own lane,
# NEVER pruned — format repair is the user's call. Carries a label only.
_cv_mal() { _CV_MALFORMED+=( "$1" ); }

# Append a mis-scoped extra_mount to RE-HOME (ADR-0052 §4, WS-4 / FI-23): its own
# lane, but stored in the 5-field _cv_add shape so _cv_prune_record executes it via
# the fi23_rehome arm. a=name, b=project; the path is re-derived from unscoped at
# apply time so it never goes stale between detect and --fix. class = local (the
# STATE index is machine-local, rebuildable). Usage: _cv_rehome_add <name> <project> <label>
_cv_rehome_add() { _CV_REHOME+=( "local"$'\t'"fi23_rehome"$'\t'"$1"$'\t'"$2"$'\t'"$3" ); }

# Append a NON-CANONICAL index record to RE-KEY (ADR-0053 D5): an absolute,
# existing path whose stored spelling differs from its canonical form (an
# unresolved symlink like /var vs /private/var, or a trailing /.). Unlike a
# MALFORMED (non-absolute) record it IS --fix-able: re-keying is a mechanical
# re-spelling of the SAME resource, so a-name / b-project drive the fixed key while
# the value is re-derived and re-canonicalized at apply time (idx_recanon arm) —
# never stale. b="" targets the unscoped bucket. class = local (machine-local
# index). Usage: _cv_noncanon_add <name> <project> <label>
_cv_noncanon_add() { _CV_NONCANON+=( "local"$'\t'"idx_recanon"$'\t'"$1"$'\t'"$2"$'\t'"$3" ); }

# Flag each per-id dir under <parent> whose <rtype> resource no longer resolves.
_cv_scan_dirs() {
    local parent="$1" rtype="$2" class="$3" blabel="$4" d nm note
    [[ -d "$parent" ]] || return 0
    for d in "$parent"/*/; do
        [[ -d "$d" ]] || continue
        nm=$(basename "$d")
        _cv_type_resolves "$rtype" "$nm" && continue
        note=""
        # M5: a half-migrated project (memory copied but index not yet registered)
        # looks like an orphan — make the prune label warn that real session memory
        # would be deleted, so the user can confirm informed (warn-never-hide §9 P5).
        if [[ "$rtype" == "project" ]] \
            && [[ -n "$(find "$d" -path '*/memory/*' -type f -print -quit 2>/dev/null)" ]]; then
            note=" (contains migrated memory — confirm 'cco init --migrate $nm' is not mid-run before pruning)"
        fi
        _cv_add "$class" rmdir "${d%/}" "" "$blabel $rtype '$nm'$note"
    done
}

# Populate _CV_RECS with every detected orphan across the four buckets.
_cv_detect() {
    _CV_RECS=()
    _CV_MALFORMED=()   # WS-5: malformed index records (reported, never pruned)
    _CV_REHOME=()      # WS-4/FI-23: mis-scoped extra_mounts to re-home
    _CV_NONCANON=()    # FI-27/ADR-0053: non-canonical index paths to re-key (--fix)
    # Read-path honesty (v3 R3 / S4). `config validate` is the verb a user runs to
    # ASK whether the store is healthy, so an unreadable index returning "no
    # orphans" is the most damaging instance of the class — a false clean bill of
    # health on exactly the question asked. Fail loud instead (exit 1).
    _index_assert_readable
    local state shared data cache
    state=$(_cco_state_dir); data=$(_cco_data_dir); cache=$(_cco_cache_dir)
    # The pack/template sidecars live in the shareable sub-bucket, not the STATE
    # root (v3 R1) — scanning the root here would silently find no sidecar orphan.
    shared=$(_cco_state_shared_dir)

    # STATE index — per-project path entries. A non-absolute value is MALFORMED
    # (a stale ~/@local spelling or a hand-edit), not an orphan: it goes to a
    # separate lane and is NEVER pruned (format repair is the user's call — ADR-0052
    # §5, generalising the `cco path list` precedent at cmd-resolve.sh:895), so
    # --fix can never delete a binding a `cco resolve --scan` could recover. An
    # absolute value whose target dir is gone is a genuine orphan; the record
    # carries the OWNING project (field b) so the prune re-keys the right scope
    # (ADR-0051), an empty project = the unscoped bucket.
    # A non-canonical value (absolute + existing, but an unresolved symlink or a
    # trailing /. — ADR-0053) is neither malformed nor orphaned: it is the SAME
    # resource under a stale spelling, so it goes to the re-key lane (--fix-able).
    # Detected only when the path exists (a missing path is an orphan; a
    # non-existent one cannot have its symlinks resolved).
    local pproj name path _canon
    while IFS=$'\t' read -r pproj name path; do
        [[ -z "$name" ]] && continue
        if ! _index_normalize_path "$path" >/dev/null 2>&1; then
            _cv_mal "index path '[$pproj] $name' -> $path (non-absolute)"
        elif [[ ! -d "$path" ]]; then
            _cv_add local idx_path "$name" "$pproj" "index path '[$pproj] $name' -> $path (missing)"
        else
            _canon=$(_index_canonicalize_path "$path" 2>/dev/null)
            [[ -n "$_canon" && "$_canon" != "$path" ]] \
                && _cv_noncanon_add "$name" "$pproj" "index path '[$pproj] $name' -> $path (non-canonical → $_canon)"
        fi
    done < <(_index_pp_dump_all)
    while IFS='=' read -r name path; do
        [[ -z "$name" ]] && continue
        if ! _index_normalize_path "$path" >/dev/null 2>&1; then
            _cv_mal "index path '$name' (unscoped) -> $path (non-absolute)"
        elif [[ ! -d "$path" ]]; then
            _cv_add local idx_path "$name" "" "index path '$name' (unscoped) -> $path (missing)"
        else
            _canon=$(_index_canonicalize_path "$path" 2>/dev/null)
            [[ -n "$_canon" && "$_canon" != "$path" ]] \
                && _cv_noncanon_add "$name" "" "index path '$name' (unscoped) -> $path (non-canonical → $_canon)"
        fi
    done < <(_index_section_dump unscoped)

    # STATE index — project memberships with no resolvable member.
    local proj members m mp any
    while IFS='=' read -r proj members; do
        [[ -z "$proj" ]] && continue
        any=false
        for m in $members; do
            mp=$(_index_get_path "$proj" "$m")
            [[ -n "$mp" && -d "$mp" ]] && { any=true; break; }
        done
        $any || _cv_add local idx_proj "$proj" "" "index project '$proj' (no resolvable member)"
    done < <(_index_list_projects)

    # STATE index — extra_mounts a project declares but the index still parks in
    # unscoped: (a legacy v1→v2 migration that predates the WS-4 re-home). Its own
    # lane (_CV_REHOME): re-homing MOVES the binding, it never deletes.
    _cv_detect_fi23_residue

    # STATE per-id dirs (update meta/base, session, memory).
    _cv_scan_dirs "$state/projects"   project  local "STATE"
    _cv_scan_dirs "$shared/packs"     pack     local "STATE"
    _cv_scan_dirs "$shared/templates" template local "STATE"

    # CACHE per-id dirs (managed runtime overlays — projects only).
    _cv_scan_dirs "$cache/projects"  project  local "CACHE"

    # STATE remote token with no matching DATA url registry entry.
    local rf tf tname
    rf=$(_cco_remotes_file); tf=$(_cco_remotes_token_file)
    if [[ -f "$tf" ]]; then
        while IFS='=' read -r tname _; do
            [[ -z "$tname" ]] && continue
            if [[ ! -f "$rf" ]] || ! grep -q "^${tname}=" "$rf" 2>/dev/null; then
                _cv_add local token "$tname" "" "STATE remote token '$tname' (no registered remote)"
            fi
        done < "$tf"
    fi

    # DATA tags.yml — bindings whose resource is gone (synced).
    local kind tnm _t
    while IFS=$'\t' read -r kind tnm _t; do
        [[ -z "$kind" ]] && continue
        _cv_type_resolves "$kind" "$tnm" || _cv_add data tag "$kind" "$tnm" "DATA tag $kind/$tnm"
    done < <(_tags_all)

    # DATA install-provenance dirs (synced).
    _cv_scan_dirs "$data/packs"     pack     data "DATA source"
    _cv_scan_dirs "$data/templates" template data "DATA source"
    _cv_scan_dirs "$data/projects"  project  data "DATA source"
}

# FI-23 residue detection (ADR-0052 §4, WS-4). An extra_mount a project.yml
# declares but the index still binds in the unscoped bucket is a mis-scoped
# residue from a pre-WS-4 v1→v2 migration. Re-homing it under the declaring
# project restores ADR-0051 D2 (no global-default layer for generic labels).
# Host-only + resolver-dependent (needs project.yml on disk), same guard shape as
# the index-side enrichment — a clean no-op in a session or an isolated unit env.
# Record args: a=name, b=project; the path is re-derived from unscoped at apply
# time so it never goes stale between detect and --fix.
_cv_detect_fi23_residue() {
    ! _cco_container_operator || return 0
    command -v _resolve_project_yml >/dev/null 2>&1 || return 0
    command -v yml_get_mount_coords >/dev/null 2>&1 || return 0
    local project members yml mname rest
    while IFS='=' read -r project members; do
        [[ -z "$project" ]] && continue
        yml=$(_resolve_project_yml "$project" 2>/dev/null) || continue
        [[ -f "$yml" ]] || continue
        while IFS=$'\t' read -r mname rest; do
            [[ -z "$mname" ]] && continue
            [[ -n "$(_index_section_get unscoped "$mname")" ]] || continue   # not parked unscoped
            [[ -n "$(_index_pp_get "$project" "$mname")" ]] && continue       # already project-scoped
            _cv_rehome_add "$mname" "$project" "extra_mount '$mname' -> [$project] (currently unscoped)"
        done < <(yml_get_mount_coords "$yml")
    done < <(_index_list_projects)
}

# Execute one orphan record's prune.
_cv_prune_record() {
    local class op a b label
    # Peel by hand, never `IFS=$'\t' read`: the idx_path record's owning-project
    # field (b) is EMPTY for an unscoped binding, and TAB is IFS-whitespace, so
    # `read` would collapse the empty middle field and shift `label` into `b` —
    # making `_index_remove_path "<label>" "<name>"` a no-op (label ≠ a project).
    _peel_tab "$1" class op a b label
    # Returns non-zero if the prune did NOT happen, so the caller can withhold its
    # success tick (S2b-P). Only the `token` arm can currently report a failed
    # write — its primitive is the one this stage fixed; the other arms are still
    # bare and are closed with their own primitives in the rest of S2b.
    case "$op" in
        idx_path) _index_remove_path "$b" "$a" ;;   # b = owning project ("" = unscoped)
        idx_proj) _index_remove_project "$a" ;;
        # Re-home a mis-scoped extra_mount under its declaring project (b),
        # re-deriving the path from unscoped (a=name). A data-preserving MOVE: bind
        # under the project, then drop the stale unscoped entry. The tail `&&`
        # propagates a failed sub-write as this record's status (S2b-P).
        fi23_rehome)
            local _rp; _rp=$(_index_section_get unscoped "$a")
            [[ -n "$_rp" ]] || return 0             # already re-homed / gone
            _index_pp_set "$b" "$a" "$_rp" && _index_section_remove unscoped "$a"
            ;;
        # Re-key a non-canonical index path (ADR-0053 D5): re-derive the CURRENT
        # stored value (never stale) and re-write it through the canonicalizing
        # writer, which re-spells it to its physical/lexical canonical form. A pure
        # value rewrite under a fixed key — it cannot violate AD5′ (same path under
        # different names is legal), so no keep-both is needed. A value that
        # vanished between detect and apply is a clean no-op.
        idx_recanon)
            local _cv
            if [[ -n "$b" ]]; then
                _cv=$(_index_pp_get "$b" "$a")
                [[ -n "$_cv" ]] || return 0
                _index_pp_set "$b" "$a" "$_cv"
            else
                _cv=$(_index_section_get unscoped "$a")
                [[ -n "$_cv" ]] || return 0
                _index_set_unscoped "$a" "$_cv"
            fi
            ;;
        rmdir)    rm -rf "$a" ;;
        # rc 1 = already gone, which for a PRUNE is the desired end state; rc ≥2 =
        # the token store could not be written and the orphan survives. `|| true`
        # reported both as pruned.
        token)    local trc=0; _remote_token_remove "$a" || trc=$?; [[ $trc -le 1 ]] ;;
        tag)      _tags_forget "$a" "$b" ;;
    esac
}

_config_validate() {
    local mode=report force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) mode=report; shift ;;
            --fix)     mode=fix; shift ;;
            -y|--yes)  force=true; shift ;;
            --help|-h)
                cat <<'EOF'
Usage: cco config validate [--dry-run | --fix [-y]]

Detect (and optionally repair) internal bookkeeping — index/tags/source/STATE/
CACHE/token entries with no resolvable backing resource. Read-only by default;
never automatic. Four lanes:
  • orphans    — no backing resource; pruned under --fix (preview + confirm)
  • re-home    — an extra_mount the index parks in the unscoped bucket though a
                 project declares it; --fix MOVES it under that project (FI-23)
  • re-key     — an existing path stored under a non-canonical spelling (an
                 unresolved symlink, or a trailing /.); --fix RE-KEYS it to the
                 canonical form — the same resource, data-preserving (FI-27)
  • malformed  — a non-absolute index path; REPORTED, never pruned (fix by hand
                 or 'cco resolve --scan')

Options:
  --dry-run    Report findings without changing anything (the default)
  --fix        Apply prunes + re-homes, preview-first and with confirmation
  -y, --yes    With --fix: confirm non-interactively (covers every phase)

STATE/CACHE orphans are machine-local and rebuildable via 'cco resolve --scan';
DATA orphans (tags/source) are synced across your machines, so pruning them
propagates — a non-resolving resource may simply live on another machine.
EOF
                return 0
                ;;
            -*) die "Unknown option: $1" ;;
            *)  die "Unexpected argument: $1" ;;
        esac
    done

    local -a _CV_RECS=() _CV_MALFORMED=() _CV_REHOME=() _CV_NONCANON=()
    _cv_detect

    if [[ ${#_CV_RECS[@]} -eq 0 && ${#_CV_MALFORMED[@]} -eq 0 && ${#_CV_REHOME[@]} -eq 0 && ${#_CV_NONCANON[@]} -eq 0 ]]; then
        ok "No orphaned internal state — bookkeeping is clean."
        return 0
    fi

    # Split the prunable orphans by bucket sync-class for the report and the staged
    # prune (guarded: _CV_RECS may be empty while another lane is not).
    local rec label class
    local -a local_recs=() data_recs=()
    if [[ ${#_CV_RECS[@]} -gt 0 ]]; then
        for rec in "${_CV_RECS[@]}"; do
            class="${rec%%$'\t'*}"
            if [[ "$class" == data ]]; then data_recs+=("$rec"); else local_recs+=("$rec"); fi
        done
        warn "Found ${#_CV_RECS[@]} orphaned internal entr$([[ ${#_CV_RECS[@]} -eq 1 ]] && echo y || echo ies):"
        if [[ ${#local_recs[@]} -gt 0 ]]; then
            info "  Machine-local (STATE/CACHE — rebuildable via 'cco resolve --scan'):"
            for rec in "${local_recs[@]}"; do label="${rec##*$'\t'}"; info "    • $label"; done
        fi
        if [[ ${#data_recs[@]} -gt 0 ]]; then
            info "  Synced (DATA — pruning propagates across your machines; a resource may"
            info "  live on another machine rather than be deleted):"
            for rec in "${data_recs[@]}"; do label="${rec##*$'\t'}"; info "    • $label"; done
        fi
    fi

    # Mis-scoped extra_mounts to re-home (WS-4/FI-23): its own lane. A re-home MOVES
    # the binding under its declaring project — data-preserving, distinct from an
    # orphan prune — so it gets its own heading and its own confirmation.
    if [[ ${#_CV_REHOME[@]} -gt 0 ]]; then
        info "Found ${#_CV_REHOME[@]} mis-scoped extra_mount binding$([[ ${#_CV_REHOME[@]} -eq 1 ]] && echo '' || echo s) (re-home under declaring project):"
        for rec in "${_CV_REHOME[@]}"; do label="${rec##*$'\t'}"; info "    • $label"; done
    fi

    # Non-canonical index paths (FI-27/ADR-0053): an existing dir stored under a
    # stale spelling (an unresolved symlink like /var vs /private/var, or a trailing
    # /.). --fix RE-KEYS it to the canonical form — repairable, unlike a malformed
    # (non-absolute) record, because it is the same resource under a different name.
    if [[ ${#_CV_NONCANON[@]} -gt 0 ]]; then
        info "Found ${#_CV_NONCANON[@]} non-canonical index path$([[ ${#_CV_NONCANON[@]} -eq 1 ]] && echo '' || echo s) (re-key to canonical form):"
        for rec in "${_CV_NONCANON[@]}"; do label="${rec##*$'\t'}"; info "    • $label"; done
    fi

    # Malformed index records (WS-5): reported, NEVER pruned — shown in both report
    # and --fix modes, so the user knows the format needs a hand-fix or a scan.
    if [[ ${#_CV_MALFORMED[@]} -gt 0 ]]; then
        warn "Found ${#_CV_MALFORMED[@]} malformed index record$([[ ${#_CV_MALFORMED[@]} -eq 1 ]] && echo '' || echo s) — reported, never pruned:"
        for label in "${_CV_MALFORMED[@]}"; do info "    • $label"; done
        info "  A non-absolute path is a stale spelling or a hand-edit. Fix it by hand, or"
        info "  rebuild the binding with 'cco resolve --scan <dir>'; --fix will not touch these."
    fi

    if [[ "$mode" != fix ]]; then
        if [[ ${#_CV_RECS[@]} -gt 0 || ${#_CV_REHOME[@]} -gt 0 || ${#_CV_NONCANON[@]} -gt 0 ]]; then
            info "Run 'cco config validate --fix' to apply (preview-first, with confirmation)."
        fi
        return 0
    fi

    # Count what actually got pruned rather than asserting the requested total
    # (S2b-P): a record whose store write failed must not be reported as removed.
    local _failed=0 _rc=0
    if [[ ${#local_recs[@]} -gt 0 ]]; then
        if _confirm_destructive "$force" "Prune ${#local_recs[@]} machine-local orphan(s)?"; then
            _failed=0
            for rec in "${local_recs[@]}"; do _cv_prune_record "$rec" || _failed=$((_failed + 1)); done
            if [[ $_failed -gt 0 ]]; then
                warn "Pruned $(( ${#local_recs[@]} - _failed )) of ${#local_recs[@]} machine-local orphan(s) — $_failed could not be removed (the store is not writable). Re-run once that path is writable."
                _rc=1
            else
                ok "Pruned ${#local_recs[@]} machine-local orphan(s)."
            fi
        else
            info "Skipped machine-local orphans."
        fi
    fi
    if [[ ${#data_recs[@]} -gt 0 ]]; then
        warn "The next prune touches SYNCED DATA — it propagates to your other machines."
        if _confirm_destructive "$force" "Prune ${#data_recs[@]} synced (DATA) orphan(s)?"; then
            _failed=0
            for rec in "${data_recs[@]}"; do _cv_prune_record "$rec" || _failed=$((_failed + 1)); done
            if [[ $_failed -gt 0 ]]; then
                warn "Pruned $(( ${#data_recs[@]} - _failed )) of ${#data_recs[@]} synced (DATA) orphan(s) — $_failed could not be removed (the store is not writable). Re-run once that path is writable."
                _rc=1
            else
                ok "Pruned ${#data_recs[@]} synced (DATA) orphan(s)."
            fi
        else
            info "Skipped synced (DATA) orphans."
        fi
    fi
    # Re-home mis-scoped extra_mounts (WS-4/FI-23) — its own confirmation because a
    # re-home MOVES the binding rather than deleting it. Machine-local (STATE index),
    # executed via _cv_prune_record's fi23_rehome arm.
    if [[ ${#_CV_REHOME[@]} -gt 0 ]]; then
        if _confirm_destructive "$force" "Re-home ${#_CV_REHOME[@]} mis-scoped binding(s) under their declaring project?"; then
            _failed=0
            for rec in "${_CV_REHOME[@]}"; do _cv_prune_record "$rec" || _failed=$((_failed + 1)); done
            if [[ $_failed -gt 0 ]]; then
                warn "Re-homed $(( ${#_CV_REHOME[@]} - _failed )) of ${#_CV_REHOME[@]} binding(s) — $_failed could not be written (the index is not writable). Re-run once it is writable."
                _rc=1
            else
                ok "Re-homed ${#_CV_REHOME[@]} extra_mount binding(s) under their declaring project."
            fi
        else
            info "Skipped extra_mount re-homing."
        fi
    fi
    # Re-key non-canonical index paths (FI-27/ADR-0053) — machine-local (STATE
    # index), its own confirmation. Data-preserving: it rewrites the value to its
    # canonical form under the same key (executed via idx_recanon), never deletes.
    if [[ ${#_CV_NONCANON[@]} -gt 0 ]]; then
        if _confirm_destructive "$force" "Re-key ${#_CV_NONCANON[@]} non-canonical index path(s) to canonical form?"; then
            _failed=0
            for rec in "${_CV_NONCANON[@]}"; do _cv_prune_record "$rec" || _failed=$((_failed + 1)); done
            if [[ $_failed -gt 0 ]]; then
                warn "Re-keyed $(( ${#_CV_NONCANON[@]} - _failed )) of ${#_CV_NONCANON[@]} path(s) — $_failed could not be written (the index is not writable). Re-run once it is writable."
                _rc=1
            else
                ok "Re-keyed ${#_CV_NONCANON[@]} non-canonical index path(s) to canonical form."
            fi
        else
            info "Skipped index path re-keying."
        fi
    fi
    return $_rc
}

cmd_config() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        ""|--help|-h|help)
            cat <<'EOF'
Usage: cco config <save|status|history|push|pull|validate> [options]

Version and sync your personal ~/.cco global config store (packs, templates,
global .claude config). Explicit, manual commits — cco never auto-commits.

Commands:
  save [-m <msg>]         Stage the allowlisted config + secret-scan + commit
  status [--full]         Show what save would commit (nothing is changed)
  history [-n N] [--full] Show how ~/.cco changed over time
  push                    Push to your (private) remote
  pull                    Fast-forward pull from your remote (non-FF aborts)
  validate [--dry-run | --fix [-y]]
                          Detect (and optionally prune) orphaned internal state

~/.cco is always git-versioned; only the remote is opt-in. Add one with:
  git -C ~/.cco remote add origin <your-private-repo-url>
EOF
            return 0
            ;;
        save) _config_save "$@" ;;
        status)  _config_status "$@" ;;
        history) _config_history "$@" ;;
        push) _config_push "$@" ;;
        pull) _config_pull "$@" ;;
        validate) _config_validate "$@" ;;
        *) die "Unknown 'cco config' command: $sub. Use save, status, history, push, pull, or validate." ;;
    esac
}
