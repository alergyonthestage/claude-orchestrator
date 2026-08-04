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
#
# Per-project scoping (ADR-0051): the index is now v2 (nested project_paths + an
# unscoped bucket). A still-v1 index is first upgraded transparently (re-homing
# each global name under every project that lists it as a member), then every
# stored value is normalized in its own scope.

MIGRATION_ID=16
MIGRATION_DESC="Normalize STATE path index to absolute paths (drop stale ~/@local)"

# $1 = the global .claude dir (unused; the index lives in STATE via _index_file).
migrate() {
    local f; f=$(_index_file)
    [[ -f "$f" ]] || return 0

    # Upgrade a legacy v1 (global-flat) index to v2 first (verbatim re-home).
    _index_migrate_if_needed

    # Normalize every per-project binding. Snapshot the dump up front so the
    # in-loop rewrites (atomic mktemp+mv per entry) don't perturb the iteration.
    local dump proj name val
    dump=$(_index_pp_dump_all)
    while IFS=$'\t' read -r proj name val; do
        [[ -z "$name" ]] && continue
        if _index_normalize_path "$val" >/dev/null; then
            _index_set_path "$proj" "$name" "$val"   # rewrites normalized (no-op if clean)
        else
            _index_remove_path "$proj" "$name"
            warn "index: dropped non-absolute entry '[$proj] $name'=\"$val\" — run 'cco resolve --scan <dir>' to rebind"
        fi
    done <<< "$dump"

    # Normalize the unscoped (project-less) bucket the same way.
    local udump
    udump=$(_index_section_dump unscoped)
    while IFS='=' read -r name val; do
        [[ -z "$name" ]] && continue
        if _index_normalize_path "$val" >/dev/null; then
            _index_set_unscoped "$name" "$val"
        else
            _index_remove_path "" "$name"
            warn "index: dropped non-absolute unscoped entry '$name'=\"$val\" — run 'cco resolve --scan <dir>' to rebind"
        fi
    done <<< "$udump"
    return 0
}
