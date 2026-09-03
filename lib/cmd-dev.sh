#!/usr/bin/env bash
# lib/cmd-dev.sh — `cco dev` : manage developer execution environments (ADR-0060 D6/§8)
#
# The mode is the CONTEXT, not a flag on every verb: `cco --dev clean` cleans the dev
# environment, `cco clean` the real one. `cco dev` is the one verb that OWNS the dev
# environment rather than acting inside it, which is why its subcommands resolve the
# dev root WITHOUT engaging dev mode — they work from an ordinary shell.
#
#   cco dev restore [<ref>] [--clean] [--dry-run]   restore ~/.cco from a snapshot
#
# A10.2 wave 2 adds `seed · reset · list · config … · project …`; each is named in the
# dispatcher below so `cco dev seed` says "not yet" instead of "unknown command".
#
# Provides: cmd_dev()
# Dependencies: colors.sh, dev.sh (the snapshot store), paths.sh (_cco_dev_root,
#   _cco_config_dir_path)
# Globals: (none)

_dev_usage() {
    cat <<'EOF'
Usage: cco dev <command> [options]

Manage developer execution environments (cco --dev). These commands act ON the dev
environment, so they run from an ordinary shell — they do not engage dev mode.

Commands:
  restore [<ref>]        Restore ~/.cco from a pre-run snapshot (default: HEAD)

Options for 'restore':
  --clean                Also DELETE files created since the snapshot
                         (without it they are reported and left in place)
  --dry-run              Show what would change; write nothing

Dev mode never forks your configuration — it is the input under test, not the target
(ADR-0060 D4). Every 'cco --dev <verb>' snapshots ~/.cco first, so a bad write is
restorable. Your project config <repo>/.cco is protected by your own repo git
instead: a dev-mode writer that could destroy uncommitted content there refuses.

Read the snapshot log with:
  git --git-dir=<dev-root>/snapshots/config.git log --oneline
EOF
}

# `cco dev restore [<ref>] [--clean] [--dry-run]` — design §5.1.
#
# Checks out the tracked paths over ~/.cco. Files CREATED since the snapshot are
# REPORTED, not deleted, unless --clean is given: a restore that silently removed
# whatever the run added would be a second destructive writer, and the point of the
# store is that nothing in dev mode destroys unnoticed.
#
# ⚠ It mutates ~/.cco, so it TAKES A SNAPSHOT FIRST — a restore is itself undoable.
# That snapshot is the reason the restore leaves the store's HEAD alone: history is
# append-only, and the revert is recorded as the next snapshot rather than by rewriting.
_dev_restore() {
    local ref="" clean=false dry_run=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --clean)     clean=true; shift ;;
            --dry-run)   dry_run=true; shift ;;
            --help|-h)   _dev_usage; return 0 ;;
            -*)          die "Unknown option: $1. Run 'cco dev restore --help' for usage." ;;
            *)
                [[ -z "$ref" ]] || die "Unexpected extra argument '$1' — 'cco dev restore' takes at most one snapshot ref."
                ref="$1"; shift ;;
        esac
    done
    [[ -n "$ref" ]] || ref="HEAD"

    local store cfg
    store=$(_cco_dev_snapshot_store)
    cfg=$(_cco_config_dir_path)
    _cco_dev_snapshot_has_commits "$store" \
        || die "No dev snapshot to restore from: $store holds no commits. A snapshot is taken at every 'cco --dev <verb>' whose ~/.cco has changed."
    [[ -d "$cfg" ]] \
        || die "$cfg does not exist, so there is nothing to restore over. Run 'cco init' first."

    local sha
    sha=$(git --git-dir="$store" rev-parse --verify -q "${ref}^{commit}") \
        || die "'$ref' is not a snapshot in $store. List them with: git --git-dir=$store log --oneline"

    # Preview through a THROWAWAY INDEX so --dry-run writes nothing at all — not even
    # the store's index. With the index holding <sha>, `diff-files` is exactly "what
    # restore would rewrite" and `ls-files --others` exactly "created since the
    # snapshot"; asked of the real index, the second is empty, because the last
    # snapshot's `git add -A` already tracked those files.
    local tmp_index restored extras
    tmp_index=$(mktemp "${TMPDIR:-/tmp}/cco-dev-index.XXXXXX") \
        || die "Could not create a temporary git index to preview the restore."
    # ⚠ No EXIT trap for the cleanup, deliberately: bin/cco's EXIT trap is the crash
    # sentinel, and a second `trap … EXIT` REPLACES it for the rest of the process.
    # The one path that can leave here without reaching the rm is the die below, and
    # it removes the file itself.
    #
    # GIT_INDEX_FILE is exported rather than prefixed onto the call: the callee is a
    # FUNCTION, and a `VAR=x fn` prefix sets the variable in the shell without
    # reliably exporting it to the `git` process the function then runs.
    export GIT_INDEX_FILE="$tmp_index"
    _dev_snap_git "$store" "$cfg" read-tree "$sha" \
        || { rm -f "$tmp_index"; unset GIT_INDEX_FILE; die "Could not read snapshot $ref out of $store."; }
    # ⚠ `update-index --refresh` FIRST, and it is load-bearing: a temp index built by
    # `read-tree` carries no stat cache, so `diff-files` reports EVERY tracked file as
    # modified and the preview would name files the restore does not touch. The
    # refresh is what compares content; its rc is non-zero exactly when something
    # differs, which is the normal case here, so it is deliberately not checked.
    _dev_snap_git "$store" "$cfg" update-index -q --refresh >/dev/null 2>&1 || true
    restored=$(_dev_snap_git "$store" "$cfg" diff-files --name-only 2>/dev/null) || restored=""
    extras=$(_dev_snap_git "$store" "$cfg" ls-files --others --exclude-standard 2>/dev/null) || extras=""
    unset GIT_INDEX_FILE
    rm -f "$tmp_index"

    local short; short=$(git --git-dir="$store" log -1 --format='%h %s' "$sha" 2>/dev/null) || short="$sha"
    info "snapshot $short"
    _dev_restore_render "$cfg" "$restored" "$extras" "$clean" "$dry_run"
    if $dry_run; then
        note "--dry-run: nothing was written"
        return 0
    fi

    # A restore is a write to ~/.cco like any other, so it gets its own restore point
    # before it runs. Taken BEFORE the read-tree below, which replaces the index.
    if $clean; then
        _cco_dev_snapshot dev restore "$ref" --clean
    else
        _cco_dev_snapshot dev restore "$ref"
    fi

    _dev_snap_git "$store" "$cfg" read-tree "$sha" \
        || die "Restore failed while loading snapshot $ref — $cfg is unchanged."
    _dev_snap_git "$store" "$cfg" checkout-index -a -f \
        || die "Restore failed while writing $cfg. It may be partially restored; re-run 'cco dev restore $ref'."
    if $clean; then
        # NEVER -x: the excluded set is the secret classes (secrets.env, *.key, …),
        # which the store deliberately never held and must not now delete.
        _dev_snap_git "$store" "$cfg" clean -qfd \
            || die "Restored $cfg, but --clean could not remove the files created since the snapshot."
    fi
    ok "restored $cfg from snapshot $short"
}

# One renderer for both the preview and the real run, so --dry-run cannot describe
# something other than what runs.
_dev_restore_render() {
    local cfg="$1" restored="$2" extras="$3" clean="$4" dry_run="$5" line
    if [[ -z "$restored" ]]; then
        info "  no tracked file under $cfg differs from this snapshot"
    else
        info "  restore $(printf '%s\n' "$restored" | grep -c .) tracked file(s):"
        while IFS= read -r line; do [[ -n "$line" ]] && info "    $line"; done <<< "$restored"
    fi
    [[ -n "$extras" ]] || return 0
    if [[ "$clean" == true ]]; then
        info "  DELETE $(printf '%s\n' "$extras" | grep -c .) file(s) created since the snapshot (--clean):"
    else
        info "  created since the snapshot — LEFT IN PLACE (pass --clean to delete):"
    fi
    while IFS= read -r line; do [[ -n "$line" ]] && info "    $line"; done <<< "$extras"
    # A note, not a warn (ADR-0059): nothing is wrong — this is the DESIGNED
    # divergence between "restore the tracked tree" and "make the tree identical".
    [[ "$clean" == true || "$dry_run" == true ]] \
        || note "$(printf '%s\n' "$extras" | grep -c .) file(s) created since the snapshot were kept — re-run with --clean to remove them"
    return 0
}

cmd_dev() {
    local sub="${1:-}"
    case "$sub" in
        ""|--help|-h|help) _dev_usage; return 0 ;;
    esac
    shift
    case "$sub" in
        restore) _dev_restore "$@" ;;
        # A10.2 wave 2 — named here so each says "not yet", never "unknown command".
        seed|reset|list|config|project)
            die "'cco dev $sub' is not implemented yet (A10.2 wave 2 — ADR-0060 §8). 'cco dev restore' is available today." ;;
        *) die "Unknown dev command: $sub. Run 'cco dev --help'." ;;
    esac
}
