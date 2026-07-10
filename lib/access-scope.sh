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
# Scope model (ADR-0043, symmetric with the write side on {project, global, all}).
# Each level READS at its matching scope — edit-project reads at PROJECT scope (not
# "everything"), edit-global at global, edit-all at all — via the pure level→scope
# maps below (_cco_level_read_scope / _cco_level_write_scope), the single source for
# host mount-gen, the operator shim, and this output layer.
# Scope classes (reuses the shim's classes — one model for gating AND output):
#   project · pack · llms → PROJECT class  (at project scope: the current project +
#                                            its referenced resources)
#   template · remote     → GLOBAL class   (visible only at global scope / higher)
# read-global ≠ read-all: the SOLE difference is other-project visibility (the
# `project` kind); packs/llms/templates/remotes are fully visible at `global`.
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

# ── The (G, Pc, Po) access triple (ADR-0046) ─────────────────────────
# ADR-0046 refactors the opaque cco_access level into three INDEPENDENT resource
# axes, each on the lattice none < ro < rw (rw ⇒ ro ⇒ none):
#   G  — the global store ~/.cco (UNreferenced packs/templates/llms/remotes + the
#        DATA registries). The current project's REFERENCED globals ride with Pc
#        (the referenced-subset invariant, §1) — G governs only the rest.
#   Pc — the current project's config.
#   Po — OTHER projects' config.
# A session's access is the triple `(G, Pc, Po)` — the single source every
# consumer derives from (INV-E): read-visibility per kind and write-authority per
# tree (§7). Presets are sugar for the SYMMETRIC triples (§3); the asymmetric
# intents (cases 6 & 7) are granular-only. This subsumes the old {project,global,
# all} ordinal, which conflated G (referenced-vs-whole) with Po (other-projects).

# Lattice rank of an axis value (none<ro<rw). Unknown → 0 (default-deny).
_cco_axis_rank() { case "$1" in rw) printf 2 ;; ro) printf 1 ;; *) printf 0 ;; esac; }

# Preset name → its symmetric-ladder triple "G Pc Po" (ADR-0046 §3). The bare
# pre-ADR-0042 `read` alias normalizes to read-all. Returns 1 for a non-preset
# token (the caller then tries the granular parse).
_cco_preset_triple() {
    local p="$1"; [[ "$p" == "read" ]] && p="read-all"
    case "$p" in
        none)         printf 'none none none' ;;
        read-project) printf 'none ro none' ;;
        read-global)  printf 'ro ro none' ;;
        read-all)     printf 'ro ro ro' ;;
        edit-project) printf 'none rw none' ;;
        edit-global)  printf 'rw rw none' ;;   # §3: REDEFINED — Pc gains rw
        edit-all)     printf 'rw rw rw' ;;
        *)            return 1 ;;
    esac
}

# _cco_parse_granular <csv> — parse the granular form "global=ro,current=rw,
# others=none" (order-free, partial, spaces tolerated) into "G|Pc|Po" with an
# EMPTY field for each unspecified axis (the caller auto-promotes). Pipe-delimited
# (not space) so `IFS='|' read` preserves empty/leading fields — a space-joined
# form would let `read` collapse a leading empty axis. Dies on an unknown key or
# an out-of-lattice value. Returns 1 when <csv> carries no '=' (not a granular
# form — the caller treats it as a preset scalar).
_cco_parse_granular() {
    local csv="${1// /}" g="" pc="" po="" tok k v
    case "$csv" in *"="*) : ;; *) return 1 ;; esac
    local IFS=','
    for tok in $csv; do
        [[ -z "$tok" ]] && continue
        k="${tok%%=*}"; v="${tok#*=}"
        case "$v" in none|ro|rw) : ;; *) die "Invalid cco_access value '$v' for '$k' (expected none|ro|rw)." ;; esac
        case "$k" in
            global)  g="$v" ;;
            current) pc="$v" ;;
            others)  po="$v" ;;
            *)       die "Unknown cco_access key '$k' (expected global|current|others)." ;;
        esac
    done
    printf '%s|%s|%s' "$g" "$pc" "$po"
}

# _cco_promote_triple <g> <pc> <po> — auto-promote unspecified axes (EMPTY args)
# to the invariant floor (ADR-0046 §2) and REJECT an explicit triple that violates
# an invariant (die, exit 1, naming it). Emits the resolved "G Pc Po". Granular
# access always means cco is enabled (permission > none), so INV-2's project floor
# (Pc≥ro) applies. Floors: Po→none, Pc→max(ro,Po) (INV-2 + INV-4), G→none. The
# floors never introduce a violation, so a surviving one is an explicit
# contradiction (e.g. current=ro,others=rw).
_cco_promote_triple() {
    local g="$1" pc="$2" po="$3"
    [[ -z "$po" ]] && po="none"
    if [[ -z "$pc" ]]; then
        if [[ "$(_cco_axis_rank "$po")" -ge 1 ]]; then pc="$po"; else pc="ro"; fi
    fi
    [[ -z "$g" ]] && g="none"
    [[ "$(_cco_axis_rank "$pc")" -ge 1 ]] \
        || die "Invalid cco_access: 'current' (Pc) must be at least 'ro' while cco is enabled (INV-2 project floor)."
    [[ "$(_cco_axis_rank "$po")" -le "$(_cco_axis_rank "$pc")" ]] \
        || die "Invalid cco_access: 'others' (Po='$po') cannot exceed 'current' (Pc='$pc') — no broader access to other projects than your own (INV-4)."
    printf '%s %s %s' "$g" "$pc" "$po"
}

# _cco_resolve_access <intent> — resolve a SCALAR access intent to the triple
# "G Pc Po". <intent> is EITHER a preset name (ladder lookup §3) OR a granular CSV
# "global=…,current=…,others=…" (§5). Dies on an unknown preset / bad granular
# token / invariant violation. The single entry point for scalar sources (the CLI
# --cco-access flag, a scalar project.yml/access.yml value). The project.yml MAP
# form is fed to _cco_promote_triple directly by the caller (axes already split).
_cco_resolve_access() {
    local intent="$1" parsed g pc po
    if parsed=$(_cco_parse_granular "$intent"); then
        IFS='|' read -r g pc po <<< "$parsed"
        _cco_promote_triple "$g" "$pc" "$po"
        return
    fi
    _cco_preset_triple "$intent" && return 0
    die "Invalid cco_access '$intent' (expected a preset name or granular global=…,current=…,others=…)."
}

# _cco_triple_label <g> <pc> <po> — the human/display label for a resolved triple:
# the preset name when it matches a symmetric-ladder point, else the granular
# "global=…,current=…,others=…" form. Used for messages and env transport; the
# triple stays the authoritative machine value.
_cco_triple_label() {
    local t="$1 $2 $3"
    case "$t" in
        "none none none") printf 'none' ;;
        "none ro none")   printf 'read-project' ;;
        "ro ro none")     printf 'read-global' ;;
        "ro ro ro")       printf 'read-all' ;;
        "none rw none")   printf 'edit-project' ;;
        "rw rw none")     printf 'edit-global' ;;
        "rw rw rw")       printf 'edit-all' ;;
        *)                printf 'global=%s,current=%s,others=%s' "$1" "$2" "$3" ;;
    esac
}

# _cco_triple_write_satisfies <g> <pc> <po> <target: project|global|all> → 0 when
# the triple grants a write to the named target TREE (ADR-0046 §7 write-authority):
# project → Pc=rw, global → G=rw, all (cross-project) → Po=rw. Replaces the old
# _cco_write_scope_satisfies ordinal (below) with the per-axis lattice compare.
_cco_triple_write_satisfies() {
    local g="$1" pc="$2" po="$3" need="$4"
    case "$need" in
        project) [[ "$(_cco_axis_rank "$pc")" -ge 2 ]] && return 0 ;;
        global)  [[ "$(_cco_axis_rank "$g")"  -ge 2 ]] && return 0 ;;
        all)     [[ "$(_cco_axis_rank "$po")" -ge 2 ]] && return 0 ;;
    esac
    return 1
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

# The resolved (G,Pc,Po) triple for THIS session as "G Pc Po". Host → "rw rw rw"
# (INV-A — everything open). Operator: from CCO_ACCESS_TRIPLE (authoritative, set
# host-side by `cco start`) or, for a preset-only launch / back-compat, derived
# from the CCO_CCO_ACCESS preset. Unknown → the read-project floor. This is the
# in-container read of the single source (INV-E); every scope decision derives
# from it per axis (ADR-0046 §7), never from the old {project,global,all} ordinal.
_env_triple() {
    _cco_container_operator || { printf 'rw rw rw'; return 0; }
    local t="${CCO_ACCESS_TRIPLE:-}"
    if [[ -n "$t" ]]; then printf '%s' "${t//,/ }"; return 0; fi
    _cco_preset_triple "${CCO_CCO_ACCESS:-read-project}" || printf 'none ro none'
}

# One axis of the session triple: G|Pc|Po → none|ro|rw.
_env_axis() {
    local g pc po; read -r g pc po <<< "$(_env_triple)"
    case "$1" in G) printf '%s' "$g" ;; Pc) printf '%s' "$pc" ;; Po) printf '%s' "$po" ;; esac
}

# Read scope for the current session as the back-compat ordinal project|global|all
# (`all` on the host, INV-A). Derived FROM the triple (Po≥ro→all, else G≥ro→global,
# else Pc≥ro→project, else none) for the few callers that still compare tiers
# (e.g. cmd-resolve path scoping at rank 1). Scope decisions that must honour the
# G/Po independence (template/remote visibility, other-project rows) key off the
# axes directly, NOT this lossy ordinal.
_env_read_scope() {
    _cco_container_operator || { printf 'all'; return 0; }
    local g pc po; read -r g pc po <<< "$(_env_triple)"
    if   [[ "$(_cco_axis_rank "$po")" -ge 1 ]]; then printf 'all'
    elif [[ "$(_cco_axis_rank "$g")"  -ge 1 ]]; then printf 'global'
    elif [[ "$(_cco_axis_rank "$pc")" -ge 1 ]]; then printf 'project'
    else printf 'none'; fi
}

# Write scope as the back-compat ordinal none|project|global|all, derived from the
# triple (Po=rw→all, G=rw→global, Pc=rw→project, else none). For display/caveats
# only — precise write gating keys off the axes (_cco_triple_write_satisfies), so
# the ordinal's loss of the edit-global dual-write (Pc=rw AND G=rw) never gates.
_env_write_scope() {
    _cco_container_operator || { printf 'all'; return 0; }
    local g pc po; read -r g pc po <<< "$(_env_triple)"
    if   [[ "$(_cco_axis_rank "$po")" -ge 2 ]]; then printf 'all'
    elif [[ "$(_cco_axis_rank "$g")"  -ge 2 ]]; then printf 'global'
    elif [[ "$(_cco_axis_rank "$pc")" -ge 2 ]]; then printf 'project'
    else printf 'none'; fi
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

# _env_is_current_project <name> → 0 when <name> is a project this session owns
# as "current", 1 otherwise. Config-editor-aware (ADR-0046 §6 / A1 §4.1 B5): a
# normal session's current project is PROJECT_NAME; a config-editor session's
# PROJECT_NAME is always 'config-editor' (D9), so its editable targets are the
# CCO_CONFIG_TARGETS set instead. The ownership predicate the B5 tag gate keys
# Pc-vs-Po off of (current project → Pc, any other → Po). Empty <name> is never
# current.
_env_is_current_project() {
    local name="$1"
    [[ -z "$name" ]] && return 1
    [[ "$name" == "${PROJECT_NAME:-}" ]] && return 0
    _env_csv_has "$name" "${CCO_CONFIG_TARGETS:-}" && return 0
    return 1
}

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
# Host → always visible (INV-A). Operator: derived PER AXIS from the session triple
# (ADR-0046 §7 read-visibility), so the G/Po independence the presets bury is
# honoured (a case-6 `(none,rw,rw)` session sees other projects yet HIDES
# unreferenced globals):
#   current project           → Pc ≥ ro  (always, INV-2)
#   referenced pack/llms       → Pc ≥ ro  (rides with the project)
#   unreferenced pack/llms     → G  ≥ ro
#   template / remote          → G  ≥ ro
#   other project              → Po ≥ ro
# An owner-tagged project-class resource follows its owner (current → Pc, else Po).
_env_in_scope() {
    local kind="$1" name="$2" owner="${3:-}"
    _cco_container_operator || return 0
    local g pc po; read -r g pc po <<< "$(_env_triple)"
    case "$kind" in
        template|remote)
            [[ "$(_cco_axis_rank "$g")" -ge 1 ]] && return 0 ;;
        project)
            # "Current" ownership is config-editor-aware (_env_is_current_project =
            # PROJECT_NAME ∪ CCO_CONFIG_TARGETS), the SAME predicate the B5 tag gate
            # and path-list scoping use — so a config-editor target project is Pc,
            # not Po. Keying off bare PROJECT_NAME would hide a config-editor's own
            # edit target from `list project`/`project show` (edit-project, Po=none).
            if _env_is_current_project "$name"; then
                [[ "$(_cco_axis_rank "$pc")" -ge 1 ]] && return 0
            fi
            [[ "$(_cco_axis_rank "$po")" -ge 1 ]] && return 0 ;;
        pack)
            if _env_csv_has "$name" "${CCO_PROJECT_PACKS:-}"; then
                [[ "$(_cco_axis_rank "$pc")" -ge 1 ]] && return 0
            fi
            [[ "$(_cco_axis_rank "$g")" -ge 1 ]] && return 0 ;;   # unreferenced → G
        llms)
            if _env_csv_has "$name" "${CCO_PROJECT_LLMS:-}"; then
                [[ "$(_cco_axis_rank "$pc")" -ge 1 ]] && return 0
            fi
            [[ "$(_cco_axis_rank "$g")" -ge 1 ]] && return 0 ;;
        *)
            # Owner-tagged project-class resource: current owner → Pc, else Po.
            # Ownership is config-editor-aware (_env_is_current_project), matching
            # the `project` kind above.
            if [[ -n "$owner" ]]; then
                if _env_is_current_project "$owner"; then
                    [[ "$(_cco_axis_rank "$pc")" -ge 1 ]] && return 0
                fi
                [[ "$(_cco_axis_rank "$po")" -ge 1 ]] && return 0
            fi ;;
    esac
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
        # read-global reveals global-class resources (templates/remotes/unreferenced
        # packs/llms); OTHER projects need read-all (Po≥ro). The notice can cover
        # both kinds, so it names the correct widening for each (A1 §2.2).
        printf 'note: %s hidden by access scope (cco_access=%s) — start a read-global session (read-all to also see other projects) or run cco on your host.\n' \
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
    # global-class (template/remote): visible iff G ≥ ro (ADR-0046 §7). Keyed off
    # the axis, not the {global,all} ordinal, so a case-6 `(none,rw,rw)` session
    # (Po=rw → ordinal 'all', yet G=none) still hides templates/remotes correctly.
    [[ "$(_cco_axis_rank "$(_env_axis G)")" -ge 1 ]] && return 0
    refuse "'cco list $kind' is not available at this access scope (cco_access=$(_env_access)) — '$kind' is a personal-global resource; start a read-global session or run cco on your host."
}
