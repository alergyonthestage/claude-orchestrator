#!/usr/bin/env bash
# lib/access-scope.sh — unified CLI environment & access-scope layer (ADR-0043).
#
# The CLI is dual-context (host + in-container wrapped-cco). §4 of the CLI
# environment-awareness design governs VERB GATING (whether a verb runs in a
# container — the operator shim). This module owns the ORTHOGONAL second
# dimension: OUTPUT SCOPING — what a *permitted* read verb SHOWS under the
# session's access scope. Every read verb consults this single layer so each
# command implements only its own differentiation logic, and a future
# permission/environment is added in one place (INV-E).
#
# Scope taxonomy (reuses the shim's classes — one model for gating AND output):
#   project · pack · llms → PROJECT class  (visible at read-project: the current
#                                            project + its referenced resources)
#   template · remote     → GLOBAL class   (visible only at read-global / higher)
#
# Invariants (ADR-0043 §2):
#   INV-A host-open  — scoping engages ONLY under _cco_container_operator; on the
#                      host every resource is always visible.
#   INV-B hidden ≠ absent — a filtered command emits ONE standardized count-only
#                      notice telling the agent how to widen.
#   INV-C stderr     — the notice goes to stderr; stdout stays machine-readable.
#   INV-D index-complete — the STATE index stays the full internal map; scoping
#                      is a presentation filter, never an index mutation.
#   INV-E single-source — context + permission resolution live here; a command
#                      never re-derives context ad hoc.
#
# Membership signals (all set by `cco start`, ADR-0042/0043):
#   PROJECT_NAME        — the current project (project-class `project` kind).
#   CCO_PROJECT_PACKS   — comma-joined names of packs referenced by the project.
#   CCO_PROJECT_LLMS    — comma-joined names of llms referenced by the project
#                         (project.yml ∪ referenced packs).
# CCO_PROJECT_PACKS/LLMS make pack/llms scoping intentional rather than a mere
# side-effect of the read-project mount narrowing (packs) or absent for the
# fully-mounted CACHE llms — computed once host-side (INV-E).
#
# Provides: _env_context(), _env_access(), _env_read_rank(),
#   _env_current_project(), _env_scope_class(), _env_in_scope(),
#   _env_note_hidden(), _env_flush_hidden_notice(), _env_require_visible()
# Dependencies: colors.sh (die), paths.sh (_cco_container_operator)

# Execution context: `operator` (wrapped-cco in a container) | `host`.
_env_context() {
    if _cco_container_operator; then printf 'operator'; else printf 'host'; fi
}

# Resolved cco access scope in-container; `unrestricted` on the host (INV-A).
# Normalizes the pre-ADR-0042 bare `read` alias to `read-all`.
_env_access() {
    if _cco_container_operator; then
        local lvl="${CCO_CCO_ACCESS:-read-project}"
        [[ "$lvl" == "read" ]] && lvl="read-all"
        printf '%s' "$lvl"
    else
        printf 'unrestricted'
    fi
}

# ── Pure level→scope maps (ADR-0043 symmetric model) ─────────────────
# The SINGLE source of truth for the read/write scope a `cco_access` level grants,
# consumed by three sites (INV-E): host mount-generation (cmd-start.sh), the
# in-container operator shim (bin/cco), and this output layer. They take a level
# STRING and are env-independent — no _cco_container_operator dependency — so
# cmd-start can map a resolved level to mount policy host-side. Read and write are
# symmetric on {project, global, all}: edit-project reads at project scope (not
# "everything"), edit-global at global, edit-all at all — mirroring the write side.
# The bare pre-ADR-0042 `read` alias normalizes to read-all.
_cco_level_read_scope() {   # <level> → none|project|global|all
    local lvl="$1"; [[ "$lvl" == "read" ]] && lvl="read-all"
    case "$lvl" in
        none)                      printf 'none' ;;
        read-project|edit-project) printf 'project' ;;
        read-global|edit-global)   printf 'global' ;;
        read-all|edit-all)         printf 'all' ;;
        *)                         printf 'project' ;;   # default-deny narrowest
    esac
}
_cco_level_write_scope() {  # <level> → none|project|global|all
    local lvl="$1"; [[ "$lvl" == "read" ]] && lvl="read-all"
    case "$lvl" in
        edit-project) printf 'project' ;;
        edit-global)  printf 'global' ;;
        edit-all)     printf 'all' ;;
        *)            printf 'none' ;;   # every read level + unknown → no write
    esac
}
# _cco_write_scope_satisfies <have> <need> → 0 when a session with write_scope
# <have> may write a tree that requires <need>. `all` grants everything; otherwise
# the scopes must match exactly — edit-global does NOT write project config and
# edit-project does NOT write the global store (least-privilege, asymmetry-free).
_cco_write_scope_satisfies() {
    local have="$1" need="$2"
    [[ "$have" == "all" ]] && return 0
    [[ "$have" == "$need" ]] && return 0
    return 1
}

# Read scope for the current session: project|global|all in operator mode; `all`
# on the host (INV-A — the host sees everything). Replaces the old opaque rank as
# the named source; _env_read_rank derives from it for callers wanting an ordinal.
_env_read_scope() {
    _cco_container_operator || { printf 'all'; return 0; }
    _cco_level_read_scope "$(_env_access)"
}

# Read-scope rank, symmetric with the shim (project<global<all). Host → 99
# (unrestricted); none → 0. Thin ordinal shim over _env_read_scope for callers
# that compare tiers. Drives _env_in_scope's fast path (rank>=2 sees everything
# except other-project `project` rows, handled in _env_in_scope).
_env_read_rank() {
    _cco_container_operator || { printf '99'; return 0; }
    case "$(_env_read_scope)" in
        none)    printf '0' ;;
        project) printf '1' ;;
        global)  printf '2' ;;
        all)     printf '3' ;;
        *)       printf '1' ;;
    esac
}

# The current session's project (empty on the host).
_env_current_project() { printf '%s' "${PROJECT_NAME:-}"; }

# Scope class for a resource kind: project | global. Unknown kinds default to
# the narrower `project` class (default-deny).
_env_scope_class() {
    case "$1" in
        project|pack|llms) printf 'project' ;;
        template|remote)   printf 'global' ;;
        *)                 printf 'project' ;;
    esac
}

# True (0) when <needle> is a member of the comma-joined list <csv>. Tolerates
# spaces around values ("a, b" → "a,b") and does NOT word-split/glob the list
# (a bare `for x in $csv` would glob-expand a value like `*`). Resource names are
# slugs, so <needle> is safe as a literal in the case pattern.
_env_csv_has() {
    local needle="$1" csv="${2// /}"
    case ",${csv}," in *",${needle},"*) return 0 ;; esac
    return 1
}

# _env_in_scope <kind> <name> [owner_project] → 0 visible / 1 hidden.
# Host → always visible (INV-A). Operator, by read_scope (ADR-0043 symmetric):
#   all     → everything visible.
#   global  → all packs/llms/templates/remotes visible; the `project` kind only
#             the current project (other projects need read-all — the SOLE
#             global-vs-all difference).
#   project → project-class resources (project/pack/llms) visible only when they
#             belong to the current project (via PROJECT_NAME / CCO_PROJECT_PACKS /
#             CCO_PROJECT_LLMS, or an explicit owner_project); global-class
#             resources (template/remote) hidden.
#   none    → hidden (cco is refused wholesale before here anyway — R6).
_env_in_scope() {
    local kind="$1" name="$2" owner="${3:-}"
    _cco_container_operator || return 0
    local scope; scope=$(_env_read_scope)
    local cur; cur=$(_env_current_project)
    case "$scope" in
        all)  return 0 ;;
        none) return 1 ;;
        global)
            # Everything global except OTHER projects (project kind is per-project).
            [[ "$kind" != "project" ]] && return 0
            [[ -n "$cur" && "$name" == "$cur" ]] && return 0
            return 1 ;;
    esac
    # scope == project: only the current project's own resources.
    [[ "$(_env_scope_class "$kind")" == "global" ]] && return 1
    case "$kind" in
        project) [[ -n "$cur" && "$name" == "$cur" ]] && return 0 ;;
        pack)    _env_csv_has "$name" "${CCO_PROJECT_PACKS:-}" && return 0 ;;
        llms)    _env_csv_has "$name" "${CCO_PROJECT_LLMS:-}"  && return 0 ;;
        *)       [[ -n "$owner" && "$owner" == "$cur" ]] && return 0 ;;
    esac
    # An owner-tagged project-class resource is visible iff owned by the project.
    [[ -n "$owner" && "$owner" == "$cur" ]] && return 0
    return 1
}

# Record one hidden-by-scope resource of <kind>. Per-kind counters live in
# indirect vars (_ENV_HID_<kind>) — bash 3.2 has no associative arrays. State is
# per-process (each cco invocation is fresh), so no reset is needed on entry.
_env_note_hidden() {
    local kind="$1"
    local var="_ENV_HID_${kind}" cur
    cur="${!var:-0}"
    printf -v "$var" '%d' "$(( cur + 1 ))"
    _ENV_HIDDEN_ANY=1
}

# Emit the single standardized "hidden by scope" notice to stderr (INV-B/C).
# Count-only — never leaks hidden names. Idempotent + no-op when nothing hidden.
_env_flush_hidden_notice() {
    [[ "${_ENV_HIDDEN_ANY:-}" == "1" ]] || return 0
    local kind var c label msg=""
    for kind in project pack llms template remote; do
        var="_ENV_HID_${kind}"; c="${!var:-0}"
        [[ "$c" -gt 0 ]] || continue
        # "llms" is already plural; the others take a trailing 's' when >1.
        case "$kind" in
            llms) label="llms" ;;
            *)    label="$kind"; [[ "$c" -gt 1 ]] && label="${kind}s" ;;
        esac
        msg="${msg}${msg:+, }${c} ${label}"
    done
    if [[ -n "$msg" ]]; then
        printf 'note: %s hidden by access scope (cco_access=%s) — start a read-global session or run cco on your host to see everything.\n' \
            "$msg" "$(_env_access)" >&2
    fi
    # Idempotent: clear so a second flush in the same process is a no-op.
    _ENV_HIDDEN_ANY=0
    for kind in project pack llms template remote; do printf -v "_ENV_HID_${kind}" '%d' 0; done
}

# _env_require_visible <kind> <name> [owner] — gate for show/detail verbs. When
# the resource is out of scope, die with a clear scope message instead of a raw
# filesystem "not found" (the point-3 robustness requirement becomes a layer
# property). No-op (returns 0) on the host and when in scope.
_env_require_visible() {
    local kind="$1" name="$2" owner="${3:-}"
    _env_in_scope "$kind" "$name" "$owner" && return 0
    # A named-but-hidden resource is a policy refusal, not an error (D8/C3 → exit 2).
    if [[ "$(_env_scope_class "$kind")" == "global" ]]; then
        refuse "'$kind $name' is not available at this access scope (cco_access=$(_env_access)) — '$kind' is a personal-global resource; start a read-global session or run cco on your host."
    fi
    refuse "'$kind $name' is not available at this access scope (cco_access=$(_env_access)) — it is outside this session's project ('$(_env_current_project)'); start a read-global/read-all session or run cco on your host."
}

# _env_require_kind_visible <kind> — gate a WHOLE-kind listing (bare `cco list
# <kind>`, R3). Project-class kinds (project/pack/llms) always pass: their listers
# filter rows individually via _env_in_scope and flush the count-only notice
# (graceful degrade, exit 0). A global-class kind (template/remote) is wholly out
# of reach below read-global → refuse (exit 2, D8), matching the shim's
# `cco <kind> list` gate. No-op (returns 0) on the host and at global/all.
_env_require_kind_visible() {
    local kind="$1"
    _cco_container_operator || return 0
    [[ "$(_env_scope_class "$kind")" == "project" ]] && return 0
    case "$(_env_read_scope)" in global|all) return 0 ;; esac
    refuse "'cco list $kind' is not available at this access scope (cco_access=$(_env_access)) — '$kind' is a personal-global resource; start a read-global session or run cco on your host."
}
