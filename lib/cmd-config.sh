#!/usr/bin/env bash
# lib/cmd-config.sh — `cco config` : version + sync the personal ~/.cco store.
#
# Domain A (design §6.1, ADR-0008): ~/.cco is the user's personal global config
# store — ALWAYS a git-versioned working tree (J0 git-inits it; ADR-0017 D4), with
# only the remote opt-in. Versioning is explicit, manual, semantic commits — NO
# auto-commit in v1. Sync transports already-made commits, never fabricates them.
#
#   cco config save [-m <msg>]   stage the allowlisted set + secret-scan + commit
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
# file. `cco config validate` (orphan-sanitization) is deferred to Phase 5 (the
# lifecycle/delete-cascade work, ADR-0021 §5 / design §9 P5).
#
# Provides: cmd_config(), _config_validate()
# Dependencies: colors.sh, utils.sh, secrets.sh (_secret_match_*),
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
    local cfg="$1" gi="$cfg/.gitignore"
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

# 2-pass secret scan over the currently STAGED files (filename + content); *.example
# is exempt (FR-S3). Echoes the offending path on the first hit, returns 1 (block).
_config_scan_staged() {
    local cfg="$1" f hit
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        [[ "$f" == *.example ]] && continue
        if hit=$(_secret_match_filename "$f" 2>/dev/null) && [[ -n "$hit" ]]; then
            printf '%s\t(filename matches %s)\n' "$f" "$hit"; return 1
        fi
        if [[ -f "$cfg/$f" ]] && hit=$(_secret_match_content "$cfg/$f" 2>/dev/null) && [[ -n "$hit" ]]; then
            printf '%s\t(content matches at line %s)\n' "$f" "${hit%%:*}"; return 1
        fi
    done < <(git -C "$cfg" diff --cached --name-only 2>/dev/null)
    return 0
}

_config_save() {
    local msg=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--message) [[ $# -lt 2 ]] && die "-m requires a commit message."; msg="$2"; shift 2 ;;
            -*) die "Unknown option: $1. Run 'cco config --help'." ;;
            *)  die "Unexpected argument: $1." ;;
        esac
    done

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
    if ! leak=$(_config_scan_staged "$cfg"); then
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
    local state data cache
    state=$(_cco_state_dir); data=$(_cco_data_dir); cache=$(_cco_cache_dir)

    # STATE index — path entries whose target dir is gone.
    local name path
    while IFS='=' read -r name path; do
        [[ -z "$name" ]] && continue
        [[ -d "$path" ]] || _cv_add local idx_path "$name" "" "index path '$name' -> $path (missing)"
    done < <(_index_list_paths)

    # STATE index — project memberships with no resolvable member.
    local proj members m mp any
    while IFS='=' read -r proj members; do
        [[ -z "$proj" ]] && continue
        any=false
        for m in $members; do
            mp=$(_index_get_path "$m")
            [[ -n "$mp" && -d "$mp" ]] && { any=true; break; }
        done
        $any || _cv_add local idx_proj "$proj" "" "index project '$proj' (no resolvable member)"
    done < <(_index_list_projects)

    # STATE per-id dirs (update meta/base, session, memory).
    _cv_scan_dirs "$state/projects"  project  local "STATE"
    _cv_scan_dirs "$state/packs"     pack     local "STATE"
    _cv_scan_dirs "$state/templates" template local "STATE"

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

# Execute one orphan record's prune.
_cv_prune_record() {
    local class op a b label
    IFS=$'\t' read -r class op a b label <<<"$1"
    case "$op" in
        idx_path) _index_remove_path "$a" ;;
        idx_proj) _index_remove_project "$a" ;;
        rmdir)    rm -rf "$a" ;;
        token)    _remote_token_remove "$a" || true ;;
        tag)      _tags_forget "$a" "$b" ;;
    esac
}

# Confirm a prune phase. --yes/-y (force=true) is an explicit confirmation;
# otherwise prompt on a TTY, and refuse (skip) when non-interactive.
_cv_confirm() {
    local force="$1" prompt="$2" reply
    [[ "$force" == true ]] && return 0
    if [[ ! -t 0 ]]; then
        warn "Non-interactive — skipping ($prompt). Re-run interactively or pass -y."
        return 1
    fi
    printf '%s [y/N] ' "$prompt" >&2
    read -r reply
    [[ "$reply" =~ ^[Yy]$ ]]
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

Detect (and optionally prune) orphaned internal bookkeeping — index/tags/source/
STATE/CACHE/token entries with no resolvable backing resource. Read-only by
default; never automatic.

Options:
  --dry-run    Report orphans without changing anything (the default)
  --fix        Prune orphans, preview-first and with confirmation
  -y, --yes    With --fix: confirm non-interactively (covers both phases)

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

    local -a _CV_RECS=()
    _cv_detect

    if [[ ${#_CV_RECS[@]} -eq 0 ]]; then
        ok "No orphaned internal state — bookkeeping is clean."
        return 0
    fi

    # Split by bucket sync-class for the report and the staged prune.
    local rec class
    local -a local_recs=() data_recs=()
    for rec in "${_CV_RECS[@]}"; do
        class="${rec%%$'\t'*}"
        if [[ "$class" == data ]]; then data_recs+=("$rec"); else local_recs+=("$rec"); fi
    done

    local label
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

    if [[ "$mode" != fix ]]; then
        info "Run 'cco config validate --fix' to prune (preview-first, with confirmation)."
        return 0
    fi

    if [[ ${#local_recs[@]} -gt 0 ]]; then
        if _cv_confirm "$force" "Prune ${#local_recs[@]} machine-local orphan(s)?"; then
            for rec in "${local_recs[@]}"; do _cv_prune_record "$rec"; done
            ok "Pruned ${#local_recs[@]} machine-local orphan(s)."
        else
            info "Skipped machine-local orphans."
        fi
    fi
    if [[ ${#data_recs[@]} -gt 0 ]]; then
        warn "The next prune touches SYNCED DATA — it propagates to your other machines."
        if _cv_confirm "$force" "Prune ${#data_recs[@]} synced (DATA) orphan(s)?"; then
            for rec in "${data_recs[@]}"; do _cv_prune_record "$rec"; done
            ok "Pruned ${#data_recs[@]} synced (DATA) orphan(s)."
        else
            info "Skipped synced (DATA) orphans."
        fi
    fi
    return 0
}

cmd_config() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        ""|--help|help)
            cat <<'EOF'
Usage: cco config <save|push|pull|validate> [options]

Version and sync your personal ~/.cco global config store (packs, templates,
global .claude config). Explicit, manual commits — cco never auto-commits.

Commands:
  save [-m <msg>]         Stage the allowlisted config + secret-scan + commit
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
        push) _config_push "$@" ;;
        pull) _config_pull "$@" ;;
        validate) _config_validate "$@" ;;
        *) die "Unknown 'cco config' command: $sub. Use save, push, pull, or validate." ;;
    esac
}
