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
#
# The allowlist is a DOUBLE BARRIER (design §6.1): a whitelist .gitignore (`*` then
# `!`-re-include only authored config) AND explicit-path staging — NEVER `git add
# -A`. secrets.env stays gitignored; secrets.env.example is committed. A 2-pass
# secret scan (filename + content, *.example exempt) refuses a leak in any staged
# file. `cco config validate` (orphan-sanitization) is deferred to Phase 5 (the
# lifecycle/delete-cascade work, ADR-0021 §5 / design §9 P5).
#
# Provides: cmd_config()
# Dependencies: colors.sh, utils.sh, paths.sh (_cco_config_dir), secrets.sh
#   (_secret_match_filename/_secret_match_content)

# The allowlisted top-level entries committed from ~/.cco (design §2.3/§6.1).
# secrets.env is deliberately ABSENT (gitignored); secrets.env.example is present.
_CONFIG_ALLOWLIST=( .gitignore packs templates global/.claude \
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
!global/
!global/.claude/
!global/.claude/**
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

cmd_config() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        ""|--help|help)
            cat <<'EOF'
Usage: cco config <save|push|pull> [options]

Version and sync your personal ~/.cco global config store (packs, templates,
global .claude config). Explicit, manual commits — cco never auto-commits.

Commands:
  save [-m <msg>]   Stage the allowlisted config + secret-scan + commit
  push              Push to your (private) remote
  pull              Fast-forward pull from your remote (non-FF aborts)

~/.cco is always git-versioned; only the remote is opt-in. Add one with:
  git -C ~/.cco remote add origin <your-private-repo-url>
EOF
            return 0
            ;;
        save) _config_save "$@" ;;
        push) _config_push "$@" ;;
        pull) _config_pull "$@" ;;
        validate)
            die "'cco config validate' (orphan cleanup) is not available yet — it ships in a later release."
            ;;
        *) die "Unknown 'cco config' command: $sub. Use save, push, or pull." ;;
    esac
}
