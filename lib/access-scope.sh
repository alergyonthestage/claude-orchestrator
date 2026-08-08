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
#   project · pack · llms · path → PROJECT class  (at project scope: the current
#                                            project + its referenced resources; a
#                                            `path`-index row rides its EFFECTIVE
#                                            owner — current → Pc, else/unattributable
#                                            → Po, RC-4)
#   template · remote     → GLOBAL class   (visible only at global scope / higher)
# read-global ≠ read-all: the SOLE difference is other-project visibility (the
# `project` AND `path` kinds); packs/llms/templates/remotes are fully visible at
# `global`. RC-4 keeps this true by construction: an unattributable path row is
# classified as other-project (rides Po), so it too needs read-all, never read-global.
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
#   _env_note_hidden(), _env_note_seen(), _env_flush_hidden_notice(),
#   _env_require_visible(), _env_widening_clause(), _env_kind_widening(),
#   _env_member_state(), _env_project_state(), _env_unavailable[_warn]()
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

# Reverse of _cco_preset_triple: a resolved "G Pc Po" triple → its preset NAME, or
# empty when the triple is asymmetric (granular-only, e.g. config-editor project
# mode `ro rw none`). Lets whoami name a session by its preset when one applies and
# fall back to "custom" otherwise, so the level line never byte-duplicates the
# granular form (R2). Whitespace-tolerant on the input.
_cco_triple_preset() {
    case "$(printf '%s' "$*" | tr -s ' ')" in
        'none none none') printf 'none' ;;
        'none ro none')   printf 'read-project' ;;
        'ro ro none')     printf 'read-global' ;;
        'ro ro ro')       printf 'read-all' ;;
        'none rw none')   printf 'edit-project' ;;
        'rw rw none')     printf 'edit-global' ;;
        'rw rw rw')       printf 'edit-all' ;;
        *)                return 1 ;;
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

# _cco_promote_triple <g> <pc> <po> [has_current_project] — auto-promote unspecified
# axes (EMPTY args) to the invariant floor (ADR-0046 §2) and REJECT an explicit triple
# that violates an invariant (die, exit 1, naming it). Emits the resolved "G Pc Po".
# Floors: Po→none, Pc→max(ro,Po) (INV-2 + INV-4), G→none. The floors never introduce a
# violation, so a surviving one is an explicit contradiction (e.g. current=ro,others=rw).
#
# INV-2 (project floor Pc≥ro) is CONDITIONAL (refinement 2026-07-11, refines ADR-0046
# §2): it holds only when the session HAS a current project in scope.
# <has_current_project> (default `true`) is that session signal — FAIL-CLOSED: a normal
# `cco start <project>` always has one, so the strict floor stands and an explicit
# `current=none` there is still rejected. A PROJECT-LESS session (config-editor global
# mode; future: cco new) passes `false`, so an unspecified Pc floors to `none` (the
# honest value — Pc has no referent, nothing is mounted for it) instead of `ro`, and no
# floor die fires. INV-4 (Po≤Pc) still holds (a project-less `others=ro` is rejected,
# which also enforces INV-3 Po≠none⇒Pc≠none).
_cco_promote_triple() {
    local g="$1" pc="$2" po="$3" has_project="${4:-true}"
    [[ -z "$po" ]] && po="none"
    if [[ -z "$pc" ]]; then
        if   [[ "$(_cco_axis_rank "$po")" -ge 1 ]]; then pc="$po"
        elif [[ "$has_project" == "true" ]];        then pc="ro"
        else                                             pc="none"
        fi
    fi
    [[ -z "$g" ]] && g="none"
    if [[ "$has_project" == "true" ]]; then
        [[ "$(_cco_axis_rank "$pc")" -ge 1 ]] \
            || die "Invalid cco_access: 'current' (Pc) must be at least 'ro' while cco is enabled with a current project (INV-2 project floor)."
    fi
    [[ "$(_cco_axis_rank "$po")" -le "$(_cco_axis_rank "$pc")" ]] \
        || die "Invalid cco_access: 'others' (Po='$po') cannot exceed 'current' (Pc='$pc') — no broader access to other projects than your own (INV-4)."
    printf '%s %s %s' "$g" "$pc" "$po"
}

# _cco_resolve_access <intent> [has_current_project] — resolve a SCALAR access intent
# to the triple "G Pc Po". <intent> is EITHER a preset name (ladder lookup §3) OR a
# granular CSV "global=…,current=…,others=…" (§5). Dies on an unknown preset / bad
# granular token / invariant violation. The single entry point for scalar sources (the
# CLI --cco-access flag, a scalar project.yml/access.yml value). <has_current_project>
# (default `true`) is threaded to _cco_promote_triple for the conditional INV-2 floor
# (project-less sessions pass `false`); presets bypass promotion, so their fixed triples
# are unaffected. The project.yml MAP form is fed to _cco_promote_triple directly by the
# caller (axes already split).
_cco_resolve_access() {
    local intent="$1" has_project="${2:-true}" parsed g pc po
    if parsed=$(_cco_parse_granular "$intent"); then
        IFS='|' read -r g pc po <<< "$parsed"
        _cco_promote_triple "$g" "$pc" "$po" "$has_project"
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

# ── The (Cr, Cp, Cg, Co) claude_access authoring triple (ADR-0049) ────
# Axis B (claude_access) governs the three `.claude` AUTHORING trees, modelled —
# symmetrically with the cco (G,Pc,Po) triple above — as FOUR per-tree axes on the
# lattice `ro < rw` (there is NO `none`/invisible value: Claude Code must READ its
# own config to function). The canonical order is "Cr Cp Cg Co":
#   Cr — B1 <repo>/.claude   (repo-native)           — the EXTRA axis, no cco
#        counterpart, default `ro` ALWAYS (a session should not rewrite the config
#        that governs its own behaviour unless explicitly permitted). This is why
#        Axis B stays a SEPARATE knob, not folded into cco_access.
#   Cp — B2 <repo>/.cco/claude (→ /workspace/.claude) — mirrors cco Pc.
#   Cg — B3 ~/.cco/.claude                            — mirrors cco G.
#   Co — other projects' .cco/claude                  — mirrors cco Po.
# When unspecified each of Cp/Cg/Co DERIVES from the resolved cco triple (§2), so
# the default claude_access is never MORE permissive than the cco intent (P1). The
# enum none|repo|all lives on as PRESET SUGAR (§3) — fixed triples that do NOT
# derive. Presets/granular map share the SAME grammar as cco. Unlike Axis A there
# are NO invariant floors (INV-2/3/4) — every {ro,rw}^4 combination is legal.

# A cco axis value (none|ro|rw) collapsed onto the claude lattice: rw→rw, else ro
# (a not-writable tree is still READABLE, so cco `none` maps to `ro`, §2).
_claude_from_cco_axis() { case "$1" in rw) printf 'rw' ;; *) printf 'ro' ;; esac; }

# Rank on the ADR-0057 D1 lattice `ro < ask < rw`. The SINGLE ordering source for
# Axis B — every "more permissive than" comparison goes through it, so adding a
# future value is one edit here rather than N scattered string tests. An unknown
# token ranks 0 (fail-closed: it can never read as MORE permissive).
_claude_axis_rank() { case "$1" in rw) printf '2' ;; ask) printf '1' ;; *) printf '0' ;; esac; }

# ── The resource-class dimension (ADR-0057 D2) ───────────────────────
# Beside the per-tree axes, Axis B carries the authoring CONTENT KINDS under an
# `entries` sub-section. Named `entries`, deliberately NOT `resources`: in cco a
# *resource* is a pack/template/llms/project and the cross-cutting taxonomy is
# about to fix that word — a lexical collision planted here would be paid there.
#
# THE DECLARED SET IS THIS LIST AND NOTHING ELSE. D3's fail-closed corollary hangs
# off it: an entry of a tree that is NOT a declared class treats a tree-level `ask`
# as `ro`, because `ask` without an emitted permission rule would be a SILENT rw
# mount. A future class (`commands/`, FI-29) is governed the day it is added here
# and not one start before — "a named list is a lower bound", applied before it
# bites rather than after.
#
# `settings.json` and hooks are deliberately ABSENT (D4): they ARE the enforcement
# plane, so `ask` is never legal on them at any level. That exclusion is data — the
# absence from this list — not a branch.
_claude_classes() { printf 'claude_md rules agents skills'; }

# The class → filesystem entry name inside a `.claude` tree. The mount emitter maps
# a tree entry back to its class through this; an entry with no class here is
# unclassified and takes the fail-closed treatment above.
_claude_class_entry() {
    case "$1" in
        claude_md) printf 'CLAUDE.md' ;;
        rules)     printf 'rules' ;;
        agents)    printf 'agents' ;;
        skills)    printf 'skills' ;;
        *)         return 1 ;;
    esac
}

# Reverse of _claude_class_entry: a `.claude` tree entry name → its class, or 1
# when the entry is not a declared class (the fail-closed path).
_claude_entry_class() {
    case "$1" in
        CLAUDE.md) printf 'claude_md' ;;
        rules)     printf 'rules' ;;
        agents)    printf 'agents' ;;
        skills)    printf 'skills' ;;
        *)         return 1 ;;
    esac
}

# D7 defaults, derived (not a preset) so they compose with the cco-derived tree
# axes. `claude_md` is `ask` because P5's maintainership criterion says the SESSION
# is the file's maintainer — it goes stale as a consequence of the work the session
# is doing — and the block always lands mid-task, where the only other remedy is a
# restart. The other three are `ro`: they encode user intent that does not age with
# the code, so the edit is deliberate and belongs to a config-editor session.
_claude_class_default() {
    case "$1" in
        claude_md) printf 'ask' ;;
        *)         printf 'ro' ;;
    esac
}

# Preset name → its FIXED claude axes "Cr Cp Cg Co Emd Erules Eagents Eskills"
# (ADR-0049 §3 + ADR-0057 D11). Presets do not derive from cco, and D11 makes
# declaring their position on the class dimension MANDATORY rather than cosmetic:
# §3 states that a preset fixes ALL axes, so leaving `entries` unstated would leave
# resolution undefined. `repo`/`all` reach `rw` on every class by D3's max() — they
# are written out rather than computed so the table is readable as data.
# No new preset in v1 (YAGNI): the default already produces the `ask` shape and
# "ask everywhere" is two keys (`repo=ask,current=ask`).
# Returns 1 for a non-preset token (the caller then tries the granular parse).
_claude_preset_triple() {
    case "$1" in
        none) printf 'ro ro ro ro ro ro ro ro' ;;   # lock all .claude authoring
        repo) printf 'rw rw ro ro rw rw rw rw' ;;   # author the local trees (repo-native + current project)
        all)  printf 'rw rw rw rw rw rw rw rw' ;;   # author every .claude tree
        *)    return 1 ;;
    esac
}

# Reverse of _claude_preset_triple: a resolved "Cr Cp Cg Co Emd Erules Eagents
# Eskills" tuple → its preset NAME, or empty (return 1) when no preset describes it
# (e.g. config-editor project mode, or the DEFAULT session). Lets whoami and the
# labels name a session by its preset when one applies. Whitespace-tolerant.
#
# ⚠ It compares RESOLVED MATRICES, not raw tuples, and both dimensions — never the
# trees alone. Two things follow, and both matter:
#
#   · The default session's trees are `ro ro ro ro`, identical to preset `none`'s,
#     while its `claude_md` is `ask`. Their matrices differ, so it is not labelled
#     "none" — reporting a locked session that is not locked would be worse than a
#     long label.
#   · Conversely `repo=rw,current=rw,global=rw,others=rw` with the DEFAULT classes
#     resolves, cell for cell, to preset `all`'s matrix (a rw tree absorbs `ask`,
#     D3). It IS `all`, and says so. Comparing raw tuples would have called two
#     identical sessions by two different names.
_claude_triple_preset() {
    # Unquoted on purpose: it accepts BOTH call shapes — eight separate axes, and a
    # single pre-joined "Cr Cp … Eskills" string (what the tests and messages pass).
    # ${n:-} keeps `set -u` out of it when the caller used the joined form.
    local want; want=$(_claude_matrix ${1:-} ${2:-} ${3:-} ${4:-} ${5:-} ${6:-} ${7:-} ${8:-})
    local p
    for p in none repo all; do
        [[ "$want" == "$(_claude_matrix $(_claude_preset_triple "$p"))" ]] && { printf '%s' "$p"; return 0; }
    done
    return 1
}

# _claude_validate_mode <value> <key> <allow_ask:true|false> — the SINGLE lattice
# validator for Axis B, shared by the CSV parse and the MAP form so a project.yml
# map and a CLI flag reject the same tokens with the same words. <allow_ask> is
# false for the two-valued axes (D5: `Cg`/`Co` never accept `ask`) — refusing it
# loudly is deliberate, because silently clamping would hide a real intent.
_claude_validate_mode() {
    local v="$1" k="$2" allow_ask="$3" expected="ro|rw"
    [[ "$allow_ask" == "true" ]] && expected="ro|ask|rw"
    case "$v" in
        ro|rw) return 0 ;;
        ask)   [[ "$allow_ask" == "true" ]] && return 0
               die "Invalid claude_access value 'ask' for '$k': the global store and other projects' config are two-valued (ro|rw). Neither goes stale as a consequence of this session's work, and neither has a git backstop the prompt could hand you (ADR-0057 D5)." ;;
        *)     die "Invalid claude_access value '$v' for '$k' (expected $expected)." ;;
    esac
}

# _claude_parse_granular <csv> — parse the granular form "repo=ro,current=ask,
# global=ro,others=rw,entries.claude_md=ask" (order-free, partial, spaces
# tolerated) into "Cr|Cp|Cg|Co|Emd|Erules|Eagents|Eskills" with an EMPTY field for
# each unspecified axis (the caller derives it from cco / the class defaults).
# Pipe-delimited (not space) so `IFS='|' read` preserves empty/leading fields.
# Dies on an unknown key or an out-of-lattice value. Returns 1 when <csv> carries
# no '=' (not a granular form — the caller treats it as a preset scalar).
#
# The class dimension keeps the SAME flat key=value grammar through a DOTTED key
# (ADR-0057 D2), so ADR-0049 §3's "one grammar in every source" survives the second
# dimension: `--claude-access current=ro,entries.claude_md=ask`.
_claude_parse_granular() {
    local csv="${1// /}" cr="" cp="" cg="" co="" emd="" eru="" eag="" esk="" tok k v
    case "$csv" in *"="*) : ;; *) return 1 ;; esac
    local IFS=','
    for tok in $csv; do
        [[ -z "$tok" ]] && continue
        k="${tok%%=*}"; v="${tok#*=}"
        case "$k" in
            repo)                _claude_validate_mode "$v" "$k" true;  cr="$v" ;;
            current)             _claude_validate_mode "$v" "$k" true;  cp="$v" ;;
            global)              _claude_validate_mode "$v" "$k" false; cg="$v" ;;
            others)              _claude_validate_mode "$v" "$k" false; co="$v" ;;
            entries.claude_md)   _claude_validate_mode "$v" "$k" true;  emd="$v" ;;
            entries.rules)       _claude_validate_mode "$v" "$k" true;  eru="$v" ;;
            entries.agents)      _claude_validate_mode "$v" "$k" true;  eag="$v" ;;
            entries.skills)      _claude_validate_mode "$v" "$k" true;  esk="$v" ;;
            entries.*)           die "Unknown claude_access entry class '${k#entries.}' (declared classes: $(_claude_classes)). settings.json and hooks are deliberately NOT classes — they are the enforcement plane itself (ADR-0057 D4)." ;;
            *)                   die "Unknown claude_access key '$k' (expected repo|current|global|others or entries.<class>)." ;;
        esac
    done
    printf '%s|%s|%s|%s|%s|%s|%s|%s' "$cr" "$cp" "$cg" "$co" "$emd" "$eru" "$eag" "$esk"
}

# _claude_derive_triple <cr> <cp> <cg> <co> <cco_g> <cco_pc> <cco_po>
#                       [<emd> <erules> <eagents> <eskills>] — fill each EMPTY axis
# from its default and emit the resolved eight-tuple "Cr Cp Cg Co Emd Erules
# Eagents Eskills".
#
# Tree axes (ADR-0049 §2): Cr→ro (ALWAYS — never derived up), Cp→collapse(Pc),
# Cg→collapse(G), Co→collapse(Po). Class axes (ADR-0057 D7): each → its
# _claude_class_default. Explicit axes pass through untouched, validated on the
# lattice their key allows — this is the single validator for the project.yml /
# access.yml MAP form, whose axes bypass the granular CSV parse.
#
# The all-empty call yields the pure DERIVED default used when claude_access is
# entirely unspecified: it is a derivation, not a preset (ADR-0049 §3), which is
# exactly what lets the class defaults compose with cco-derived tree axes instead
# of overriding them. No invariant floors (Axis B has none).
_claude_derive_triple() {
    local cr="$1" cp="$2" cg="$3" co="$4" g="$5" pc="$6" po="$7"
    local emd="${8:-}" eru="${9:-}" eag="${10:-}" esk="${11:-}"
    [[ -n "$cr" ]]  && _claude_validate_mode "$cr"  "repo"              true
    [[ -n "$cp" ]]  && _claude_validate_mode "$cp"  "current"           true
    [[ -n "$cg" ]]  && _claude_validate_mode "$cg"  "global"            false
    [[ -n "$co" ]]  && _claude_validate_mode "$co"  "others"            false
    [[ -n "$emd" ]] && _claude_validate_mode "$emd" "entries.claude_md" true
    [[ -n "$eru" ]] && _claude_validate_mode "$eru" "entries.rules"     true
    [[ -n "$eag" ]] && _claude_validate_mode "$eag" "entries.agents"    true
    [[ -n "$esk" ]] && _claude_validate_mode "$esk" "entries.skills"    true
    [[ -z "$cr" ]]  && cr="ro"
    [[ -z "$cp" ]]  && cp="$(_claude_from_cco_axis "$pc")"
    [[ -z "$cg" ]]  && cg="$(_claude_from_cco_axis "$g")"
    [[ -z "$co" ]]  && co="$(_claude_from_cco_axis "$po")"
    [[ -z "$emd" ]] && emd="$(_claude_class_default claude_md)"
    [[ -z "$eru" ]] && eru="$(_claude_class_default rules)"
    [[ -z "$eag" ]] && eag="$(_claude_class_default agents)"
    [[ -z "$esk" ]] && esk="$(_claude_class_default skills)"
    printf '%s %s %s %s %s %s %s %s' "$cr" "$cp" "$cg" "$co" "$emd" "$eru" "$eag" "$esk"
}

# _claude_resolve_access <intent> <cco_g> <cco_pc> <cco_po> — resolve a SCALAR
# claude intent to the triple "Cr Cp Cg Co". <intent> is EITHER a preset name
# (fixed triple, §3) OR a granular CSV "repo=…,current=…,global=…,others=…" whose
# omitted axes derive from cco (§2). Dies on an unknown preset / bad granular
# token. The single entry point for scalar sources (the CLI --claude-access flag, a
# scalar project.yml/access.yml value). The project.yml/access.yml MAP form is fed
# to _claude_derive_triple directly by the caller (axes already split).
_claude_resolve_access() {
    local intent="$1" g="$2" pc="$3" po="$4" parsed cr cp cg co emd eru eag esk
    if parsed=$(_claude_parse_granular "$intent"); then
        IFS='|' read -r cr cp cg co emd eru eag esk <<< "$parsed"
        _claude_derive_triple "$cr" "$cp" "$cg" "$co" "$g" "$pc" "$po" "$emd" "$eru" "$eag" "$esk"
        return
    fi
    _claude_preset_triple "$intent" && return 0
    die "Invalid claude_access '$intent' (expected a preset name none|repo|all or granular repo=…,current=…,global=…,others=…,entries.<class>=…)."
}

# _claude_triple_label <cr> <cp> <cg> <co> <emd> <erules> <eagents> <eskills> —
# the human/display label for a resolved Axis-B tuple: the preset name when the
# FULL tuple matches one, else the granular form, which is verbatim what you would
# type on `--claude-access` to reproduce it. Used for messages/whoami/env
# transport; the tuple stays the authoritative machine value.
#
# The granular form always spells out the four trees, and then names each class
# that CHANGES SOMETHING — one whose cell differs from its tree's unclassified
# fallback on `repo` or `current`. Both halves of that rule are load-bearing:
#
#   · A class at its tree's own mode adds nothing, and this string is read by a
#     human in the session summary. Printing all four every time turned a one-line
#     summary into 130 characters of mostly-noise.
#   · A class that does change something is never omitted — `claude_md: ask` is the
#     single cell deciding whether this session can write a CLAUDE.md at all, so a
#     label that hid it would understate the session's own reach. The DEFAULT
#     session therefore reads `…,others=ro,entries.claude_md=ask`, which is both
#     short and true.
_claude_triple_label() {
    _claude_triple_preset "$1 $2 $3 $4 $5 $6 $7 $8" && return 0
    local out matrix cls val tree
    out=$(printf 'repo=%s,current=%s,global=%s,others=%s' "$1" "$2" "$3" "$4")
    matrix=$(_claude_matrix "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8")
    for cls in $(_claude_classes); do
        case "$cls" in
            claude_md) val="$5" ;; rules) val="$6" ;;
            agents)    val="$7" ;; skills) val="$8" ;;
        esac
        for tree in repo current; do
            if [[ "$(_claude_matrix_get "$matrix" "$tree" "$cls")" \
               != "$(_claude_matrix_get "$matrix" "$tree" '*')" ]]; then
                out="$out,entries.$cls=$val"
                break
            fi
        done
    done
    printf '%s' "$out"
}

# _claude_discordant <cr> <cp> <cg> <co> <cco_g> <cco_pc> <cco_po> → 0 when the
# resolved Axis B grants MORE write than the cco-concordant default on a tree that
# lives INSIDE .cco config (Cp vs Pc, Cg vs G, Co vs Po) — the P2 discordance-warn
# predicate (ADR-0049 §4). On the {ro,rw} lattice "more permissive" means the claude
# axis is `rw` while the concordant default (collapse of the cco axis) is `ro`. Cr
# (B1 repo-native) NEVER warns — no cco counterpart. A tighter-than-cco Axis B never
# warns. Emits nothing; the caller decides how to warn.
_claude_discordant() {
    local cp="$2" cg="$3" co="$4" g="$5" pc="$6" po="$7"
    local emd="${8:-}" eru="${9:-}" eag="${10:-}" esk="${11:-}"
    # Tree axes, compared by RANK so `ask` counts as more permissive than `ro` — a
    # tree-level `ask` is an explicit widening and deserves the same note `rw` gets.
    [[ "$(_claude_axis_rank "$cp")" -gt "$(_claude_axis_rank "$(_claude_from_cco_axis "$pc")")" ]] && return 0
    [[ "$(_claude_axis_rank "$cg")" -gt "$(_claude_axis_rank "$(_claude_from_cco_axis "$g")")"  ]] && return 0
    [[ "$(_claude_axis_rank "$co")" -gt "$(_claude_axis_rank "$(_claude_from_cco_axis "$po")")" ]] && return 0
    # Class axes (ADR-0057 D12): the comparison base is the DERIVED DEFAULT, not the
    # bare tree axis. With `claude_md: ask` inside that default, comparing a class
    # against its tree would warn on EVERY session — the letter of ADR-0049 §4
    # applied to a model it predates. One line here, one bug not shipped.
    [[ -n "$emd" && "$(_claude_axis_rank "$emd")" -gt "$(_claude_axis_rank "$(_claude_class_default claude_md)")" ]] && return 0
    [[ -n "$eru" && "$(_claude_axis_rank "$eru")" -gt "$(_claude_axis_rank "$(_claude_class_default rules)")"     ]] && return 0
    [[ -n "$eag" && "$(_claude_axis_rank "$eag")" -gt "$(_claude_axis_rank "$(_claude_class_default agents)")"    ]] && return 0
    [[ -n "$esk" && "$(_claude_axis_rank "$esk")" -gt "$(_claude_axis_rank "$(_claude_class_default skills)")"    ]] && return 0
    return 1
}

# ── The resolved access matrix (ADR-0057 D3 + D10, INV-P) ────────────
# THE SINGLE PRODUCER. Everything the two emitters need is computed here, once, and
# no consumer re-derives it: the mount emitter reads only the ro/rw projection
# (`ask ⇒ rw`), the permissions emitter only the `ask` cells. INV-P is the static
# lint that keeps that true rather than merely intended — a policy expressed in a
# mount and contradicted by a rule is indistinguishable, from inside a session,
# from a bug.
#
# The cell rule is `effective(class, tree) = max(axis(tree), value(class))` applied
# ONLY where the class dimension reaches, with the two exclusions as DATA rather
# than branches:
#   · The class dimension's REACH is `{Cr, Cp}` (D2, stated in the grammar block
#     itself: *"reach: {Cr, Cp} only"*). On `global`/`others` a class value is inert
#     — the cell IS the tree axis. That is the whole of D5: those two trees are
#     two-valued because neither can go stale as a consequence of this session's
#     work and neither has a git backstop. Applying max() there would let the
#     class dimension GRANT what the tree axis denied — preset `repo`, whose
#     `entries` are all `rw` by D11, would silently mount `~/.cco/.claude` rw
#     while ADR-0049 §3 fixes its `Cg` at `ro`. Fail-closed: a class may refine a
#     tree it reaches, never widen one it does not.
#   · `settings.json` and hooks are absent from _claude_classes (D4), so they never
#     produce a cell at all and take the unclassified treatment below.
#
# ⚠ The fail-closed corollary (D3) lives in _claude_tree_unclassified, not here: an
# entry that is NOT a declared class treats a tree-level `ask` as `ro`. Without it a
# tree-level `ask` would hand a future class (`commands/`, FI-29) a `rw` mount with
# no rule emitted — a SILENT rw.

# Whether the class dimension REACHES a tree at all (ADR-0057 D2). `repo`/`current`
# yes; `global`/`others` no — which is also why they are the two-valued ones that
# refuse `ask` at parse time (D5). Data, consulted by the cell rule — not a branch
# inside it.
_claude_tree_in_class_reach() {
    case "$1" in repo|current) return 0 ;; *) return 1 ;; esac
}

# One cell: <tree> <tree_axis> <class_mode> → ro|ask|rw.
_claude_cell() {
    # SEPARATE statement (INV-LOCAL): `local a="$2" out="$a"` expands the RHS BEFORE
    # the assignment, so `out` would take the CALLER's `axis`. Here that caller is
    # _claude_matrix, which HAS a local named `axis` holding the same value — so the
    # bug would have been invisible until the second caller.
    local tree="$1" axis="$2" cls="$3" out
    out="$axis"
    if _claude_tree_in_class_reach "$tree" \
       && [[ "$(_claude_axis_rank "$cls")" -gt "$(_claude_axis_rank "$axis")" ]]; then
        out="$cls"
    fi
    # Belt-and-braces: an out-of-reach tree can never hold `ask` (the parser refuses
    # it on global/others, the cco collapse only ever yields ro/rw, and no preset
    # sets it), but if one ever did it must read as `ro` — never as a gate cco has
    # no plane to enforce there.
    if [[ "$out" == "ask" ]] && ! _claude_tree_in_class_reach "$tree"; then out="ro"; fi
    printf '%s' "$out"
}

# The mode an UNCLASSIFIED entry of a tree gets: the tree axis, with `ask` clamped
# to `ro`. This IS the fail-closed corollary — the one place it is expressed.
_claude_tree_unclassified() {
    case "$1" in ask) printf 'ro' ;; *) printf '%s' "$1" ;; esac
}

# _claude_matrix <cr> <cp> <cg> <co> <emd> <erules> <eagents> <eskills> — emit the
# resolved matrix, one "<tree> <class> <mode>" per line, trees in the canonical
# order repo·current·global·others and classes in _claude_classes order. Plus one
# "<tree> * <mode>" row per tree carrying the unclassified fallback, so a consumer
# that meets an entry with no class has somewhere to read its mode from instead of
# re-deriving one.
_claude_matrix() {
    local cr="$1" cp="$2" cg="$3" co="$4" emd="$5" eru="$6" eag="$7" esk="$8"
    local tree axis cls val
    for tree in repo current global others; do
        case "$tree" in
            repo)    axis="$cr" ;;
            current) axis="$cp" ;;
            global)  axis="$cg" ;;
            others)  axis="$co" ;;
        esac
        for cls in $(_claude_classes); do
            case "$cls" in
                claude_md) val="$emd" ;;
                rules)     val="$eru" ;;
                agents)    val="$eag" ;;
                skills)    val="$esk" ;;
            esac
            printf '%s %s %s\n' "$tree" "$cls" "$(_claude_cell "$tree" "$axis" "$val")"
        done
        printf '%s * %s\n' "$tree" "$(_claude_tree_unclassified "$axis")"
    done
}

# _claude_matrix_get <matrix> <tree> <class> → the cell's mode. <class> may be '*'
# for the unclassified fallback. Dies on a lookup the matrix does not carry: a
# missing cell means the producer and the consumer disagree about the class set,
# which is precisely what INV-P exists to prevent — failing loudly beats defaulting.
_claude_matrix_get() {
    local matrix="$1" tree="$2" cls="$3" t c m
    while read -r t c m; do
        [[ "$t" == "$tree" && "$c" == "$cls" ]] && { printf '%s' "$m"; return 0; }
    done <<< "$matrix"
    die "Internal: no access-matrix cell for tree '$tree' class '$cls' (ADR-0057 D10 / INV-P)."
}

# _claude_matrix_mount_mode <matrix> <tree> <class> → the MOUNT projection of a
# cell: "" (rw, compose's default) or "ro". `ask` projects to rw — it needs the
# mount writable, which is the whole trade it makes (a boundary for a gate).
# The mount emitter consumes ONLY this; it never sees the word `ask`.
_claude_matrix_mount_mode() {
    case "$(_claude_matrix_get "$1" "$2" "$3")" in
        ro) printf 'ro' ;;
        *)  printf '' ;;
    esac
}

# _claude_matrix_asks <matrix> <class> → 0 when ANY tree resolves <class> to `ask`.
# The permissions emitter consumes ONLY this: a rule's reach is a glob spanning
# whole trees (D8), so what it needs is "does this class need a gate anywhere",
# never a per-tree answer.
_claude_matrix_asks() {
    local matrix="$1" cls="$2" t c m
    while read -r t c m; do
        [[ "$c" == "$cls" && "$m" == "ask" ]] && return 0
    done <<< "$matrix"
    return 1
}

# _claude_matrix_overreach <matrix> → the in-workspace trees whose `claude_md`
# resolved `rw` while the class still needs a gate somewhere, comma-separated in
# canonical tree order; EMPTY when there is no divergence.
#
# FI-52, accepted rather than fixed (2026-08-06, option 1+4). D8 governs `claude_md`
# with ONE glob over all of /workspace — the file set is unbounded, so enumeration
# cannot win — and a glob has no notion of a tree. It therefore also gates trees D3
# resolved `rw`, where the ADR itself calls a prompt noise. The mount says *write
# freely*, the rule says *ask*, and from INSIDE a session those two are
# indistinguishable from a bug: that is what this exists to say out loud. It changes
# no behaviour; the caller only prints.
#
# `global` is excluded because ~/.claude is outside /workspace, so no glob reaches
# it — the same reason D8 can leave it untouched.
_claude_matrix_overreach() {
    local matrix="$1" tree out=""
    _claude_matrix_asks "$matrix" claude_md || { printf ''; return 0; }
    for tree in repo current others; do
        if [[ "$(_claude_matrix_get "$matrix" "$tree" claude_md)" == "rw" ]]; then
            out="${out:+$out,}$tree"
        fi
    done
    printf '%s' "$out"
    return 0
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
        project|pack|llms|path) printf 'project' ;;
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

# _env_owner_in_scope <owner> → 0 visible / 1 hidden. The SINGLE ownership→
# visibility rule (ADR-0046 §7): a CURRENT owner rides Pc, ANY other owner rides
# Po, and an EMPTY/unattributable owner is conservatively CLASSIFIED as `other` —
# it can never be vouched for by Pc, but it is legitimately visible once the
# session may see other projects at all (Po ≥ ro). Callers resolve EFFECTIVE
# ownership BEFORE calling (the unscoped-bucket claim check, cmd-resolve.sh); this
# decides policy, not attribution. Caller must already have passed the INV-A host
# check. Keeps ADR-0043 §1's "SOLE difference" invariant true by construction: an
# unattributable row is classified as other-project data (RC-4 / 06 §3.3, §4.1).
_env_owner_in_scope() {
    local owner="$1" g pc po
    read -r g pc po <<< "$(_env_triple)"
    if [[ -n "$owner" ]] && _env_is_current_project "$owner"; then
        [[ "$(_cco_axis_rank "$pc")" -ge 1 ]] && return 0
    fi
    [[ "$(_cco_axis_rank "$po")" -ge 1 ]] && return 0
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
            # Ownership→visibility via the single layer predicate (RC-4): current
            # owner rides Pc, any other rides Po. Config-editor-aware inside
            # _env_owner_in_scope (_env_is_current_project = PROJECT_NAME ∪
            # CCO_CONFIG_TARGETS), the SAME predicate the B5 tag gate and path-list
            # scoping use — so a config-editor target project is Pc, not Po.
            # Behaviour-preserving: this branch was that predicate inlined.
            _env_owner_in_scope "$name" && return 0 ;;
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
        path)
            # Index binding (name→host-path). Visibility follows its EFFECTIVE
            # owner, resolved by the caller (the unscoped-bucket claim check in
            # cmd_path list). An EMPTY owner is conservatively classified as
            # other-project (rides Po) and is therefore NEVER exempt from scoping —
            # this is the ONE call WITHOUT the `-n owner` guard, and it is the RC-4
            # reversal ADR-0043 §4 mandated (previously owner-less rows were shown
            # unconditionally, leaking other projects' names/host paths at Po=none).
            _env_owner_in_scope "$owner" && return 0 ;;
        *)
            # Owner-tagged project-class resource: current owner → Pc, else Po
            # (config-editor-aware, via _env_owner_in_scope). The `-n owner` guard
            # keeps a genuinely UNKNOWN kind with no owner default-deny (A3): the
            # new permissiveness is opted into by naming a kind (project/path),
            # never inherited by a future kind that forgets to register.
            if [[ -n "$owner" ]]; then
                _env_owner_in_scope "$owner" && return 0
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

# True when at least one resource was hidden by scope in this invocation, i.e.
# _env_flush_hidden_notice is going to speak. Lets a caller whose listing came
# out EMPTY tell "empty because everything is out of scope" (the notice covers
# it) from "empty because there is nothing" (the caller's own sentence), without
# reading the layer's private counters — INV-E keeps the policy in the layer.
_env_has_hidden() { [[ "${_ENV_HIDDEN_ANY:-}" == "1" ]]; }

# ── D3: the widening offered is a function of what is hidden ─────────
# ADR-0056 D3. ONE builder, every call site — the aggregate notice, the
# per-resource refusal (_env_require_visible), the per-resource warn
# (_env_unavailable_warn) and `cco path list`'s entry notice. They previously
# shared the INTENT and each spelled its own string, which is precisely how the
# `read-global`-for-a-project remedy reached four sites and was found
# independently by all four review sessions. They now share the IMPLEMENTATION.
#
#   projects only    → read-all ALONE. read-global's SOLE difference from
#                      read-all is that other projects stay hidden (this file's
#                      header), so naming it would offer a remedy that reveals
#                      NOTHING of what was hidden — worse than offering none.
#   store kinds only → read-global (packs/llms/templates/remotes ride G).
#   mixed            → both, with read-all attached to the projects clause.
#
# A `path` row rides Po exactly as a project does (RC-4), so it counts on the
# projects side. Usage: _env_widening_clause <n_projects_hidden> <n_store_hidden>
_env_widening_clause() {
    local np="${1:-0}" ns="${2:-0}"
    if [[ "$np" -gt 0 && "$ns" -eq 0 ]]; then
        printf 'start a read-all session (other projects need Po≥ro)'
    elif [[ "$np" -eq 0 && "$ns" -gt 0 ]]; then
        printf 'start a read-global session'
    else
        printf 'start a read-global session (read-all to also see other projects)'
    fi
}

# The same rule for a SINGLE named resource, expressed through the same builder
# (D1: one owner, one implementation): `project`/`path` are the projects-only
# case, every other kind is the store-kinds-only case.
# Usage: _env_kind_widening <kind>
_env_kind_widening() {
    case "$1" in
        project|path) _env_widening_clause 1 0 ;;
        *)            _env_widening_clause 0 1 ;;
    esac
}

# Emit the standardized scope notices to stderr (INV-B/C). Count-only — never
# leaks names. Idempotent + no-op when nothing was noted. Two independent notices,
# each gated on its own flag so a caller that noted ONLY unmounted members still
# gets the second sentence: the "hidden by scope" notice (unchanged wording) and
# the RC-2 "not mounted in this session" notice (D-M2). The latter must NOT say
# "run cco resolve" — that string is what made today's output a lie.
# ── D5: you cannot count what you cannot enumerate ───────────────────
# ADR-0056 D5. INV-B requires a COUNT-only notice precisely so an agent can tell
# hidden from absent — but a store-resident kind is counted by ENUMERATING it and
# noting the rows scope hides. At G=none `~/.cco` is not mounted at all, so the
# enumeration loop never iterates: zero rows, zero _env_note_hidden calls, and the
# notice stays silent about resources that certainly exist. (`llms` behaves only
# because it enumerates from CACHE, which is mounted regardless of G.)
#
# ⚠ The session reports diagnosed this as "packs are not wired into the scope
# layer". They ARE wired — cmd-pack.sh:116 notes and :134 flushes. The cause is the
# absent mount, and the ADR records the correction because a wrong root cause
# survives longer than a wrong fix.
#
# So the count is a HOST-SIDE fact, computed by `cco start` where enumeration is
# possible and injected as a session signal — the pattern CCO_PROJECT_PACKS /
# CCO_PROJECT_LLMS already establishes ("computed once host-side (INV-E)", above).
# An elevated `store-op count` was REJECTED (A1): it would widen ADR-0047's
# privileged surface for a cosmetic datum. Dropping the count was REJECTED (A2):
# that answers the finding by deleting the requirement.
#
# ⚠ CONSEQUENCE, recorded rather than discovered later: this is a SNAPSHOT AT
# SESSION START. A pack installed from the host mid-session is not reflected. That
# is accepted — the session could not see that pack anyway, and INV-D already
# frames scoping as a presentation filter over a host-owned truth.
#
# Format: CCO_STORE_TOTALS="pack=7,template=3,llms=5,remote=2" (absent → no
# supplement, so a host run and a pre-ADR-0056 container degrade to the old
# behaviour rather than inventing a number).
#
# ⚠ THE SUPPLEMENT IS PER-INVOCATION, NOT PER-SESSION (ratified 2026-07-30, after the
# post-build probe finally made D5 live — the signal had never crossed the ADR-0047
# boundary, so none of this ran in production). A total is a fact about the STORE; a
# notice is a sentence about WHAT THIS VERB JUST SHOWED. Supplementing every store kind
# on every flush conflated the two and put a false clause in every read verb's notice:
# `cco list llms` — which shows both of this project's llms — announced "6 packs
# hidden", while `cco list packs` announced "5 packs, 2 llms hidden" though those 2 llms
# are exactly the ones it is not hiding. Worse, the same session answered 6 or 5 to the
# same question depending on which verb was asked, because the number is
# total-minus-enumerated and a verb that lists llms enumerates no packs at all.
#
# So a verb must DECLARE the kinds it enumerates exhaustively (_env_store_subject), and
# only those are supplemented. Not declaring means no supplement: silence is honest,
# a fabricated count is not. Rejected alternative: supplement only kinds with seen>0 —
# it needs no declaration anywhere, but it goes silent exactly when nothing was
# enumerable (a project referencing no packs, a fully absent mount), which is R-B
# returning through the back door.
_ENV_STORE_KINDS="pack template llms remote"

# Kinds the "not mounted in this session" notice can carry (see the flush below):
# whole resources PLUS a project's parts, which `project show` classifies per row.
_ENV_UNM_KINDS="project repo extra_mount pack llms template remote"

# Kinds the "hidden by access scope" notice can carry. `path` (an index binding)
# is here because `cco path list` now routes through the shared notice instead of
# spelling its own — see _env_widening_clause: a path row rides Po exactly as a
# project does, so it counts on the PROJECTS side of the widening, never the store
# side (offering read-global for a hidden path row would reveal nothing).
_ENV_HID_KINDS="project path pack llms template remote"

# Host-side total for <kind> from the session signal; empty when unknown.
_env_store_total() {
    local kind="$1" tot="${CCO_STORE_TOTALS:-}" tok
    [[ -n "$tot" ]] || return 1
    local IFS=','
    for tok in $tot; do
        tok="${tok// /}"
        [[ "${tok%%=*}" == "$kind" ]] || continue
        tok="${tok#*=}"
        case "$tok" in ''|*[!0-9]*) return 1 ;; esac
        printf '%s' "$tok"; return 0
    done
    return 1
}

# Record one ENUMERATED resource of <kind> — every row the lister actually saw,
# whether it went on to be shown or noted hidden. The difference between this and
# the host-side total is what the mount could not show at all (D5). Mirrors
# _env_note_hidden's bash-3.2 indirect counters. Usage: _env_note_seen <kind>
_env_note_seen() {
    local kind="$1"
    local var="_ENV_SEEN_${kind}" cur
    cur="${!var:-0}"
    printf -v "$var" '%d' "$(( cur + 1 ))"
}

# Declare the store kinds THIS invocation enumerates exhaustively — the only kinds
# whose host-total supplement it may speak about (ratified 2026-07-30, after the
# post-build probe; see the block above). Additive, so a verb listing several kinds
# declares them all. Usage: _env_store_subject <kind>…
#
# ⚠ DECLARING IS THE OPT-IN. A verb that does not declare gets NO supplement, which
# is the honest default: it cannot enumerate a kind's full store, so it has no basis
# for a claim about that kind. The cost of the reverse default was measured — see the
# block above — and it was a false sentence in every read verb's notice.
_env_store_subject() {
    _ENV_SUBJECT_KINDS="${_ENV_SUBJECT_KINDS:-} $* "
}

# Fold the unenumerable remainder into the hidden counters, just before the notice
# is built. Operator-only (INV-A: the host is never scoped and always enumerates).
# Per kind: supplement = max(0, host_total - enumerated), so it is correct for a
# fully absent mount (enumerated 0 → the whole total), for the read-project
# NARROWED pack mount (enumerated = the referenced subset → the rest), and for a
# fully mounted store (enumerated = total → 0, and the existing per-row notes stand
# alone). Never double-counts: rows the loop DID see are already counted by
# _env_note_hidden if scope hid them.
#
# ⚠ ONCE per invocation. _env_flush_hidden_notice is idempotent and several verbs
# call it on more than one path (`cco list`'s empty and non-empty arms, `llms …
# --project`'s conditional flush). The per-row counters are zeroed after each
# flush, but `seen` and the host total are NOT per-flush facts — re-deriving the
# supplement on a second call would re-add it and print the notice twice.
_env_apply_store_supplement() {
    _cco_container_operator || return 0
    [[ -n "${CCO_STORE_TOTALS:-}" ]] || return 0
    [[ "${_ENV_SUPPL_DONE:-}" == "1" ]] && return 0
    _ENV_SUPPL_DONE=1
    # No declared subject → no supplement. See _env_store_subject.
    [[ -n "${_ENV_SUBJECT_KINDS:-}" ]] || return 0
    local kind total seen svar n i
    for kind in $_ENV_STORE_KINDS; do
        # Only kinds THIS invocation enumerates exhaustively (D5 scoping).
        case "${_ENV_SUBJECT_KINDS}" in *" $kind "*) ;; *) continue ;; esac
        total=$(_env_store_total "$kind") || continue
        svar="_ENV_SEEN_${kind}"; seen="${!svar:-0}"
        n=$(( total - seen ))
        [[ "$n" -gt 0 ]] || continue
        i=0
        while [[ "$i" -lt "$n" ]]; do _env_note_hidden "$kind"; i=$(( i + 1 )); done
    done
}

_env_flush_hidden_notice() {
    local kind var c label
    # D5: fold in what this session could not enumerate BEFORE building the
    # message — at G=none nothing was noted, and the supplement is exactly what
    # makes the notice speak at all.
    _env_apply_store_supplement
    # ── hidden by access scope (unchanged) ──────────────────────────────
    if [[ "${_ENV_HIDDEN_ANY:-}" == "1" ]]; then
        local msg=""
        for kind in $_ENV_HID_KINDS; do
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
            # The widening comes from the SHARED builder (D3) — this site used to
            # spell it inline, and the two per-resource sites spelled it again and
            # differently. See _env_widening_clause for the rule.
            local widen
            widen=$(_env_widening_clause \
                "$(( ${_ENV_HID_project:-0} + ${_ENV_HID_path:-0} ))" \
                "$(( ${_ENV_HID_pack:-0} + ${_ENV_HID_llms:-0} \
                   + ${_ENV_HID_template:-0} + ${_ENV_HID_remote:-0} ))")
            printf 'note: %s hidden by access scope (cco_access=%s) — %s or run cco on your host.\n' \
                "$msg" "$(_env_access)" "$widen" >&2
        fi
        _ENV_HIDDEN_ANY=0
        for kind in $_ENV_HID_KINDS; do printf -v "_ENV_HID_${kind}" '%d' 0; done
    fi
    # ── not mounted in this session (RC-2 / D-M2) ───────────────────────
    if [[ "${_ENV_UNMOUNTED_ANY:-}" == "1" ]]; then
        local umsg=""
        # ⚠ WIDER than the hidden-by-scope list above, and deliberately so. Scope
        # hides whole RESOURCES (project/pack/llms/template/remote); "not mounted"
        # also applies to a project's PARTS — a member repo, an extra_mount — which
        # `project show` classifies per row (D7 / D-V31-3). A kind missing from this
        # list would set _ENV_UNMOUNTED_ANY, contribute nothing to umsg, and the
        # notice would silently vanish: counted, then dropped, which is the exact
        # failure INV-B exists to prevent.
        for kind in $_ENV_UNM_KINDS; do
            var="_ENV_UNM_${kind}"; c="${!var:-0}"
            [[ "$c" -gt 0 ]] || continue
            case "$kind" in
                llms) label="llms" ;;
                *)    label="$kind"; [[ "$c" -gt 1 ]] && label="${kind}s" ;;
            esac
            umsg="${umsg}${umsg:+, }${c} ${label}"
        done
        if [[ -n "$umsg" ]]; then
            printf 'note: %s not mounted in this session — they exist on this machine but are not bound into this container; run cco on your host to act on them.\n' \
                "$umsg" >&2
        fi
        _ENV_UNMOUNTED_ANY=0
        for kind in $_ENV_UNM_KINDS; do printf -v "_ENV_UNM_${kind}" '%d' 0; done
    fi
}

# Record one "not mounted in this session" resource of <kind> (INV-B: a skipped
# member is COUNTED, never silently dropped). Mirrors _env_note_hidden's bash-3.2
# indirect counters (_ENV_UNM_<kind>); folded into the SAME flush so INV-C's single
# standardized notice still holds. Usage: _env_note_unmounted <kind>
_env_note_unmounted() {
    local kind="$1"
    local var="_ENV_UNM_${kind}" cur
    cur="${!var:-0}"
    printf -v "$var" '%d' "$(( cur + 1 ))"
    _ENV_UNMOUNTED_ANY=1
}

# _env_require_visible <kind> <name> [owner] — gate for show/detail verbs. When
# the resource is out of scope, die with a clear scope message instead of a raw
# filesystem "not found" (the point-3 robustness requirement becomes a layer
# property). No-op (returns 0) on the host and when in scope.
_env_require_visible() {
    local kind="$1" name="$2" owner="${3:-}"
    _env_in_scope "$kind" "$name" "$owner" && return 0
    # A named-but-hidden resource is a policy refusal, not an error (D8/C3 → exit 2).
    #
    # ⚠ NON-DISCLOSING (ADR-0056 D4, ratifying D-V31-1). Both arms below used to
    # assert that the resource EXISTS, and the project arm additionally asserted
    # WHERE it is ("it is outside this session's project ('X')"). Below read scope
    # `all` that is exactly the disclosure ADR-0043's scoping exists to prevent —
    # it turned `project show` into an existence oracle across the scope boundary
    # (W3-F05). The sentence now asserts NOTHING about existence or location: it
    # reports only what this session can offer, which is all it honestly knows.
    # The widening comes from the shared D3 builder, so this site can no longer
    # drift from the aggregate notice — it named read-global for a PROJECT, a
    # level whose sole difference from read-all is that projects stay hidden.
    #
    # ⚠ The RESERVED FRAGMENT "not available at this access scope" is deliberately
    # preserved — it is the shared vocabulary INV-ENV budgets and the managed rule
    # quotes. What D4 removes is the CLAUSE that followed it, not the sentence:
    # naming the resource the caller just typed discloses nothing, whereas
    # asserting that it exists and where it lives discloses both.
    if [[ "$(_env_scope_class "$kind")" == "global" ]]; then
        refuse "'$kind $name' is not available at this access scope (cco_access=$(_env_access)) — '$kind' is a personal-global resource; $(_env_kind_widening "$kind"), or run cco on your host."
    fi
    refuse "'$kind $name' is not available at this access scope (cco_access=$(_env_access)) — $(_env_kind_widening "$kind"), or run cco on your host."
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

# ── The three availability states (D-M2 / RC-2, 04-host-path-class.md §3.1) ──
# The model shipped with two outcomes (visible / out of scope) against three
# realities, and each verb invented its own third answer. There is now ONE
# vocabulary, one shared resolver and one remedy string per state. A path read
# from the STATE index is a HOST path (INV-F): in operator mode it must NEVER be
# existence-tested — availability is decided by (i) does the index hold a binding
# and (ii) is a tree present at the PROBE path, deliberately not the host path.
#
# | state       | truth test                       | remedy                | exit |
# | here        | tree exists at the probe path    | —                     | 0    |
# | not-mounted | binding exists, probe absent     | start a session / host| 2/0  |
# | unresolved  | no binding, or host path absent  | cco resolve <name>*   | 1    |
# | unknown     | not in the index (scope=all only)| check the name        | 1    |
# | out-of-scope| the scope layer hides it         | widen --cco-access    | 2    |
#
# * host-qualified in a session (D2) — `cco resolve` is host-only there.
#
# INV-AVAIL (ADR-0056 D1) — no verb computes an availability or scope-widening
# answer for itself. Every such answer is produced HERE, which owns (a) the
# classification, (b) the sentence, (c) the remedy and (d) the exit code. Same
# shape as INV-S6, whose CLASS lint has held. Enforced by INV-ENV (one spelling
# per state) + INV-AVAIL (the predicate half + the badge/remedy strings) in
# tests/test_invariants.sh.

# _env_member_state <name> <index_host_path> [<declared_target>]
#   → here | not-mounted | unresolved
# PURE: takes what the caller already holds, so it adds no dependency on index.sh
# (loaded AFTER this module). This function IS invariant INV-F.
_env_member_state() {
    local name="$1" host_path="$2" target="${3:-}" probe
    [[ -n "$host_path" ]] || { printf 'unresolved'; return 0; }     # no binding (INV-F.1)
    probe=$(_cco_member_probe_path "$name" "$host_path" "$target")
    [[ -n "$probe" && -d "$probe" ]] && { printf 'here'; return 0; }
    if _cco_container_operator; then printf 'not-mounted'; else printf 'unresolved'; fi
}

# _env_project_state <name> → out-of-scope | here | not-mounted | unknown | unresolved
# Resolves through the operator-aware _resolve_project_yml (never the host-only
# _resolve_unit_dir_for_project — INV-F.3), defined later in load order and bound
# at call time — the same pattern _env_require_visible already uses.
#
# ── D4: the `unknown` arm, materialised ONLY at read scope `all` ──────
# ADR-0056 D4 ratifies D-V31-1 by settling two findings that are both right on
# DIFFERENT axes, using the axis ADR-0043 already defines (_cco_level_read_scope):
#   • at read scope `all` NOTHING can be hidden by construction, so answering a
#     typo with the not-mounted sentence — "it exists on this machine, but its
#     files are not bound into this container" — is simply FALSE. The arm is safe
#     AND owed here: no oracle is created, because the session would see the
#     resource anyway. Truth source: _index_list_projects.
#   • below `all` the arm is REFUSED (alternative A5, rejected): distinguishing
#     "hidden" from "absent" there is exactly the existence oracle across the
#     scope boundary that W3-F05 named. Those scopes get the non-disclosing
#     out-of-scope sentence instead, which asserts nothing.
# The arm is operator-gated as well as scope-gated: the wrong answer it replaces
# ("it exists on this machine") is the not-mounted sentence, which only a session
# can produce. On the host the existing `unresolved` wording stands — it already
# claims no more than "not resolved on this machine".
_env_project_state() {
    local name="$1"
    _env_in_scope project "$name" || { printf 'out-of-scope'; return 0; }
    if _resolve_project_yml "$name" >/dev/null 2>&1; then printf 'here'; return 0; fi
    if _cco_container_operator; then
        if [[ "$(_env_read_scope)" == "all" ]] && ! _env_project_registered "$name"; then
            printf 'unknown'; return 0
        fi
        printf 'not-mounted'; return 0
    fi
    printf 'unresolved'
}

# Is <name> registered in the machine-local index? The truth source D4 names
# (_index_list_projects, whose rows are `name=…`). Defined in index.sh, which
# loads AFTER this module, so the call is bound at call time — the same late
# binding _env_project_state already relies on for _resolve_project_yml. A
# missing/unreadable enumerator must never MANUFACTURE an `unknown` verdict, so
# any failure to enumerate returns 0 ("assume registered") and the caller falls
# through to the conservative not-mounted arm.
_env_project_registered() {
    local name="$1" row
    command -v _index_list_projects >/dev/null 2>&1 || return 0
    while IFS='=' read -r row _; do
        [[ "$row" == "$name" ]] && return 0
    done < <(_index_list_projects 2>/dev/null)
    return 1
}

# The single BADGE per state, for table/card renderings that show a state beside a
# row rather than failing on it (`project show`'s repos and extra_mounts). Same
# reason the sentence lives here (D1): the badge vocabulary is part of the answer,
# and `[missing]` — the string this replaces — was a fourth spelling of a state the
# classifier already had a name for. `here` deliberately renders EMPTY: a member
# that is present needs no badge. Colour stays with the caller (this module has no
# colour dependency), so a caller wraps it; the WORDS come from here.
# Usage: _env_state_badge <here|not-mounted|unresolved|unknown|out-of-scope>
_env_state_badge() {
    case "$1" in
        here)         printf '' ;;
        not-mounted)  printf '[not mounted in this session]' ;;
        out-of-scope) printf '[hidden by access scope]' ;;
        unknown)      printf '[not registered]' ;;
        *)            printf '[unresolved]' ;;
    esac
}

# The single remedy SENTENCE per state — no leading glyph, no stream — so the
# fatal _env_unavailable and the degrade-and-continue _env_unavailable_warn render
# IDENTICAL text and differ only in stream + exit (INV-E, one vocabulary). The
# not-mounted sentence deliberately never says "run cco resolve".
# Usage: _env_unavailable_sentence <not-mounted|unresolved> <kind> <name>
_env_unavailable_sentence() {
    local state="$1" kind="$2" name="$3"
    case "$state" in
        not-mounted)
            printf "%s '%s' is not mounted in this session — it exists on this machine, but its files are not bound into this container. Run cco on your host, or start a session that mounts it." \
                "$kind" "$name" ;;
        unknown)
            # D4: reached ONLY at read scope `all`, where nothing can be hidden, so
            # naming the resource absent discloses nothing the session could not
            # already see. This is the answer a typo must get instead of the
            # not-mounted sentence's false "it exists on this machine".
            printf "%s '%s' is not registered on this machine — no such %s is bound in the cco index. Check the name with 'cco list projects'." \
                "$kind" "$name" "$kind" ;;
        *)
            # "not resolved on this machine" (not "unresolved") preserves the
            # historical host wording the rename guard shipped, so its host-side
            # counterweight test stays green across the vocabulary unification.
            #
            # D2 — a remedy is a function of the PRINT SITE. `cco resolve` is
            # host-only in a session (bin/cco's operator gate refuses it at exit
            # 2), so prescribing it in-container is advice this very session will
            # reject. This generalises index.sh's existing correct branch rather
            # than inventing a rule.
            if _cco_container_operator; then
                printf "%s '%s' is not resolved on this machine — run 'cco resolve %s' on your host." \
                    "$kind" "$name" "$name"
            else
                printf "%s '%s' is not resolved on this machine — run 'cco resolve %s' first." \
                    "$kind" "$name" "$name"
            fi ;;
    esac
}

# The single remedy vocabulary for an unavailable resource — exits per D8
# (policy/session-shape → refuse 2; missing dependency → die 1). <state> must not
# be `here`. Usage: _env_unavailable <state> <kind> <name>
_env_unavailable() {
    local state="$1" kind="$2" name="$3"
    case "$state" in
        out-of-scope) _env_require_visible "$kind" "$name" ;;   # existing wording, exit 2
        not-mounted)  refuse "$(_env_unavailable_sentence not-mounted "$kind" "$name")" ;;
        # D4: a name that is registered nowhere is a NAMING error, not a session
        # shape — exit 1 with the unresolved arm, per D8's taxonomy.
        unknown)      die    "$(_env_unavailable_sentence unknown     "$kind" "$name")" ;;
        *)            die    "$(_env_unavailable_sentence unresolved  "$kind" "$name")" ;;
    esac
}

# Non-fatal sibling for degrade-and-continue callers that must keep their exit-0
# contract (`--all` sweeps, `llms … --project`). SAME sentences, `warn` instead of
# refuse/die; returns 1 so the caller can `|| continue` / `|| return`. Keeping both
# on one vocabulary is what INV-E buys. Usage: _env_unavailable_warn <state> <kind> <name>
_env_unavailable_warn() {
    local state="$1" kind="$2" name="$3"
    case "$state" in
        out-of-scope)
            # D3: the widening comes from the shared builder, not a third inline
            # spelling. This site offered "read-global/read-all" for every kind —
            # for a PROJECT, read-global reveals nothing (it is the level that
            # hides other projects), so the remedy was unfollowable.
            warn "$kind '$name' is hidden by access scope (cco_access=$(_env_access)) — $(_env_kind_widening "$kind"), or run cco on your host." ;;
        not-mounted)  warn "$(_env_unavailable_sentence not-mounted "$kind" "$name")" ;;
        unknown)      warn "$(_env_unavailable_sentence unknown     "$kind" "$name")" ;;
        *)            warn "$(_env_unavailable_sentence unresolved  "$kind" "$name")" ;;
    esac
    return 1
}
