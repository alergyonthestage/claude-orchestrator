#!/usr/bin/env bash
# lib/cmd-sync.sh — cco sync (sync = copy; design §4).
#
# Converge a project's per-repo .cco/ config on ONE machine by COPYING a
# source repo's committed synced set into target repos. There is NO merge
# engine, no 3-way sync-base, no commit-time, no network — just a filesystem
# copy (AD7). Divergence is allowed and visible; the user picks the source.
#
# Synced set (§4.1, ADR-0024 D6): the whole committed .cco/ minus the gitignored
# secrets.env (project.yml, claude/**, mcp.json, setup.sh, mcp-packages.txt,
# secrets.env.example; authored packs/ join in P4). NEVER secrets.env, the
# repo-root .claude/, or system dirs. Single-sourced in _sync_synced_files
# (lib/sync-meta.sh), shared with the fingerprint.
#
# D2 clobber-guard (ADR-0024): a target repo that HOSTS a different project
# (its .cco/project.yml `name` != the source project) is skipped with a warning,
# never overwritten — no override. A repo hosts at most one project (= one dev
# scope); it may be REFERENCED by N others (resolved via the index, never synced).
#
# Command forms (§4.2; positional = TARGET, --from = SOURCE, default source = cwd):
#   cco sync                      source = cwd repo,  targets = all other members
#   cco sync <repo>               source = cwd repo,  target  = <repo>
#   cco sync --from <repo>        source = <repo>,    targets = all other members
#   cco sync <repoA> --from <repoB>  source = <repoB>, target = <repoA>
# Flags: --dry-run (preview), --auto-approve (skip confirm), --check (exit-code
# only — 0 in sync, 1 if any target differs; for the user's own CI/hooks).
#
# After a real sync cco records the §4.6 fingerprint on every touched repo
# (target + source), prints which repos changed, and runs the non-blocking
# reminder aggregator (commit your .cco with normal git). H1: the aggregator
# only sees already-resolved repo roots.
#
# Provides: cmd_sync()
# Dependencies: colors.sh, utils.sh, index.sh (_index_get_path), yaml.sh
#   (yml_get_repo_coords), sync-meta.sh (_sync_synced_files/_sync_record),
#   reminders.sh (_emit_config_reminders), cmd-resolve.sh
#   (_resolve_find_unit_dir/_resolve_scan_match_name)

# Canonical absolute path (resolve symlinks) of an existing dir; pass-through
# otherwise. Used to compare source vs target identity.
_sync_canon() {
    local p="$1"
    if [[ -d "$p" ]]; then ( cd "$p" && pwd -P ); else printf '%s\n' "$p"; fi
}

# Print a unified diff of the synced set (incoming = source over current =
# target). Returns 0 if a copy WOULD change the target (additions or content
# differences), 1 if the target already matches the source set. Target-only
# extra files are not reported — `cco sync` copies, it does not delete.
# Usage: _sync_compute_diff <src_cco> <tgt_cco>
_sync_compute_diff() {
    local src_cco="$1" tgt_cco="$2" rel changed=1
    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        if [[ ! -e "$tgt_cco/$rel" ]]; then
            changed=0
            diff -u -L "current: (absent)" -L "incoming: $rel" /dev/null "$src_cco/$rel" 2>/dev/null || true
        elif ! diff -q "$src_cco/$rel" "$tgt_cco/$rel" >/dev/null 2>&1; then
            changed=0
            diff -u -L "current: $rel" -L "incoming: $rel" "$tgt_cco/$rel" "$src_cco/$rel" 2>/dev/null || true
        fi
    done < <(_sync_synced_files "$src_cco")
    return $changed
}

# Copy the source synced set into the target .cco/ (add/overwrite; never delete
# target-only files). Usage: _sync_copy <src_cco> <tgt_cco>
_sync_copy() {
    local src_cco="$1" tgt_cco="$2" rel
    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        mkdir -p "$tgt_cco/$(dirname "$rel")"
        cp "$src_cco/$rel" "$tgt_cco/$rel"
    done < <(_sync_synced_files "$src_cco")
}

cmd_sync() {
    local from="" target_name="" dry_run=false auto=false check=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                cat <<'EOF'
Usage: cco sync [target-repo] [--from <source-repo>] [options]

Copy a source repo's committed .cco/ config (project.yml + claude/**
[+ secrets.env.example]) into target repos on this machine. Filesystem copy —
no merge, no network. Commit each changed repo with your normal git flow.

Forms (positional = target, --from = source, default source = the cwd repo):
  cco sync                        cwd repo -> all other project members
  cco sync <repo>                 cwd repo -> only <repo>
  cco sync --from <repo>          <repo>   -> all other project members
  cco sync <repoA> --from <repoB> <repoB>  -> only <repoA>

Options:
  --from <repo>     Use <repo> as the source instead of the cwd repo
  --dry-run         Show what would change; copy nothing
  --auto-approve    Apply without the per-target confirmation prompt
  --check           Exit-code only: 0 if every target is in sync, 1 otherwise
EOF
                return 0
                ;;
            --from)
                [[ $# -lt 2 ]] && die "--from requires a <repo> name."
                from="$2"; shift 2
                ;;
            --dry-run)     dry_run=true; shift ;;
            --auto-approve) auto=true; shift ;;
            --check)       check=true; shift ;;
            -*) die "Unknown option: $1. Run 'cco sync --help'." ;;
            *)
                if [[ -z "$target_name" ]]; then
                    target_name="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    # ── Resolve the source repo ──────────────────────────────────────
    local src_root src_name=""
    if [[ -n "$from" ]]; then
        src_root=$(_index_get_path "$from")
        [[ -n "$src_root" ]] || die "source repo '$from' is unresolved on this machine — run 'cco resolve' first."
        src_name="$from"
    else
        src_root=$(_resolve_find_unit_dir) \
            || die "Run 'cco sync' from a repo containing .cco/project.yml, or pass --from <repo>."
    fi
    local project_yml="$src_root/.cco/project.yml"
    [[ -f "$project_yml" ]] || die "source repo has no .cco/project.yml: $src_root"
    [[ -d "$src_root/.cco" ]] || die "source repo has no .cco/: $src_root"

    # Source project identity — the discriminator for the D2 clobber-guard (ADR-0024).
    local src_proj; src_proj=$(yml_get "$project_yml" name 2>/dev/null) || src_proj=""

    # Best-effort source logical name (to exclude it from the all-members set).
    [[ -z "$src_name" ]] && { src_name=$(_resolve_scan_match_name "$src_root" "$project_yml") || src_name=""; }
    local src_canon; src_canon=$(_sync_canon "$src_root")

    # ── Collect targets (resolved paths via the index) ───────────────
    local -a targets=()
    if [[ -n "$target_name" ]]; then
        local tp; tp=$(_index_get_path "$target_name")
        [[ -n "$tp" ]] || die "target repo '$target_name' is unresolved on this machine — run 'cco resolve' first."
        targets+=("$tp")
    else
        local _ln name path canon
        while IFS= read -r _ln; do
            [[ -z "$_ln" ]] && continue
            name="${_ln%%$'\t'*}"
            [[ -z "$name" ]] && continue
            [[ -n "$src_name" && "$name" == "$src_name" ]] && continue
            path=$(_index_get_path "$name")
            if [[ -z "$path" ]]; then
                warn "member '$name' is unresolved — skipping (run 'cco resolve')"
                continue
            fi
            canon=$(_sync_canon "$path")
            [[ "$canon" == "$src_canon" ]] && continue   # never sync onto the source
            targets+=("$path")
        done < <(yml_get_repo_coords "$project_yml" 2>/dev/null)
    fi

    if [[ ${#targets[@]} -eq 0 ]]; then
        info "no target repos to sync${target_name:+ (}${target_name:+$target_name}${target_name:+)} — nothing to do"
        return 0
    fi

    # ── Per-target diff + (copy) ─────────────────────────────────────
    local src_cco="$src_root/.cco"
    local -a copied=()
    local any_out_of_sync=false
    local tgt tgt_cco tgt_proj diff_out rc reply

    for tgt in "${targets[@]}"; do
        tgt_cco="$tgt/.cco"

        # D2 clobber-guard (ADR-0024): NEVER overwrite a repo that HOSTS a
        # different project. Skip + warn; no override (to re-home a repo, de-init
        # its .cco/ then sync, or re-init with --sync). A code-only target (no
        # project.yml) or a same-name member proceeds normally.
        if [[ -f "$tgt_cco/project.yml" ]]; then
            tgt_proj=$(yml_get "$tgt_cco/project.yml" name 2>/dev/null) || tgt_proj=""
            if [[ -n "$tgt_proj" && -n "$src_proj" && "$tgt_proj" != "$src_proj" ]]; then
                $check || warn "skipping $(basename "$tgt"): hosts project '$tgt_proj' (source is '$src_proj') — not overwriting (ADR-0024 D2)"
                continue
            fi
        fi

        diff_out=$(_sync_compute_diff "$src_cco" "$tgt_cco"); rc=$?

        if [[ $rc -ne 0 ]]; then
            $check || info "$(basename "$tgt"): already in sync"
            continue
        fi
        any_out_of_sync=true

        if $check; then
            echo "out of sync: $(basename "$tgt")"
            continue
        fi

        echo ""
        echo "── $(basename "$tgt") ── changes to apply (incoming = $(basename "$src_root")):"
        printf '%s\n' "$diff_out"
        echo ""

        if $dry_run; then
            continue
        fi

        if ! $auto; then
            if [[ ! -t 0 ]]; then
                die "non-interactive: pass --auto-approve to sync without confirmation."
            fi
            printf "  Apply to %s? [y/N]: " "$(basename "$tgt")" >&2
            read -r reply < /dev/tty
            [[ "$reply" =~ ^[Yy] ]] || { info "skipped $(basename "$tgt")"; continue; }
        fi

        _sync_copy "$src_cco" "$tgt_cco"
        _sync_record "$tgt"
        copied+=("$(basename "$tgt")")
    done

    # ── Outcome ──────────────────────────────────────────────────────
    if $check; then
        $any_out_of_sync && return 1
        info "all targets in sync"
        return 0
    fi

    if $dry_run; then
        $any_out_of_sync || info "all targets already in sync"
        return 0
    fi

    if [[ ${#copied[@]} -eq 0 ]]; then
        info "nothing copied — targets already in sync or skipped"
        return 0
    fi

    _sync_record "$src_root"
    ok "synced from $(basename "$src_root") -> ${copied[*]}"
    info "commit the updated .cco/ in each changed repo with your normal git flow"

    # Non-blocking reminders over the (resolved) source + targets (H1).
    _emit_config_reminders "$src_root" "${targets[@]}"
    return 0
}
