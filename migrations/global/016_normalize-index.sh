#!/usr/bin/env bash
# Migration 016: normalize the STATE path index to absolute paths only (S1).
#
# Earlier `cco init --migrate` runs wrote non-normalized values into the
# machine-local index: a ~/… repo path (the repos branch did not expand it,
# unlike the mounts branch) and, for some legacy layouts, a bare `@local`
# marker. Those poison every index reader — by-name `cco resolve` (`-f` on an
# unexpanded ~), false AD5 conflicts (string compare of ~/x vs /home/me/x), and
# `cco path list` (raw @local). The write boundary now normalizes
# (_index_set_path / _index_path_conflicts in lib/index.sh), but entries written
# BEFORE the fix stay dirty; this one-shot pass cleans them.
#
# Idempotent: a clean (all-absolute) index is rewritten to itself with no net
# change. A value that cannot be made absolute (relative / empty / a bare @local
# with no recovery) is DROPPED — it self-heals on the next `cco resolve --scan`.
# The projects: membership section is left untouched.

MIGRATION_ID=16
MIGRATION_DESC="Normalize STATE path index to absolute paths (drop stale ~/@local)"

# $1 = the global .claude dir (unused; the index lives in STATE via _index_file).
migrate() {
    local f; f=$(_index_file)
    [[ -f "$f" ]] || return 0

    # _index_list_paths dumps the whole paths: section into the pipe up front, so
    # rewriting $f inside the loop (atomic mktemp+mv per entry) is safe.
    local line name val
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        name="${line%%=*}"; val="${line#*=}"
        [[ -z "$name" ]] && continue
        # Re-write through the normalizing boundary: _index_set_path expands
        # ~/$HOME and refuses a non-absolute value (return 1), in which case the
        # prior _index_remove_path has already dropped the stale entry.
        _index_remove_path "$name"
        if ! _index_set_path "$name" "$val"; then
            warn "index: dropped non-absolute entry '$name'=\"$val\" — run 'cco resolve --scan <dir>' to rebind"
        fi
    done < <(_index_list_paths)
    return 0
}
