#!/usr/bin/env bash
# lib/agents.sh — the teammate coordination guarantee (ADR-0058)
#
# Provides: _cco_coordination_tools(), _agents_norm_init(), _agent_src(),
#           _emit_agent_dir_overlays(), _agents_report_flush(),
#           _agents_guarantee_line()
# Dependencies: colors.sh, utils.sh
# Globals: _CCO_AGN_DIR, _CCO_AGN_REPORT (set by _agents_norm_init)
#
# ── Why this module exists ───────────────────────────────────────────
# cco enables agent teams at the MANAGED layer, where the user cannot turn them
# off. That changes the contract of the `Agent` tool: a teammate is a separate
# process whose deliverable reaches the lead ONLY through `SendMessage`. An agent
# definition that declares a `tools:` allowlist without it therefore does its work,
# shows it in the pane, and throws it away — measured at 0 deliverables out of 17
# teammates, across two Claude Code versions (analysis-002).
#
# The upstream documentation states the opposite ("Team coordination tools such as
# SendMessage and the task management tools are always available to a teammate even
# when tools restricts other tools"). It is false in 2.1.220 and 2.1.226, so cco
# cannot ship on it — P1: what cco enables, cco makes work.
#
# ⚠ NO prompt-level remedy is possible: an agent ORDERED to call `SendMessage`
# tried and got "No such tool available". Instructing the agent better is inert on
# a restricted toolset. Do not re-propose it (ADR-0058, Alternatives).
#
# ── What it does ─────────────────────────────────────────────────────
# At `cco start`, every agent definition about to be mounted is read; one missing a
# member of the guaranteed set is mounted from a NORMALIZED COPY carrying it. The
# committed file is never modified (P3) — this is a pure projection, exactly like
# the managed-settings and class overlays: same file, different view, decided at
# start time.
#
# Three cases deliberately keep the pre-fix behaviour, and D6's warning is the
# WHOLE remedy for each — which is why the report below names the file, never just
# the condition:
#   D10 — the tree is mounted rw: the user is AUTHORING the definition, so a
#         projection would make them edit an overlay or read content that is not
#         their file. Warn, never rewrite.
#   D11 — the definition does not parse: cco does not make a session unstartable
#         over a stray character in someone's markdown. Pass through, warn.
#   A3  — a member is named in `disallowedTools:`: that is a DECISION, not the
#         side effect an omitted allowlist entry is. Honour it, warn. (Also the
#         only honest option: "a tool listed in both is removed" upstream, so
#         adding it to `tools:` would be a silent no-op.)

# ── D2 — the guaranteed set, defined exactly once (P4) ───────────────
# Not `SendMessage` alone. A remedy that enumerates one name is a partial remedy
# that still fails:
#   SendMessage                          the return channel itself
#   TaskCreate/TaskUpdate/TaskList/TaskGet
#                                        the documented "teammates sometimes fail
#                                        to mark tasks as completed, which blocks
#                                        dependent tasks" becomes an ALWAYS when
#                                        the tools are absent
#   ToolSearch                           `SendMessage` is a DEFERRED tool in
#                                        current builds — granting the name
#                                        without the discovery path grants a tool
#                                        the agent cannot find (measured)
# Every consumer reads the set from here: the normalizer, `cco whoami`, the tests.
_cco_coordination_tools() {
    printf '%s\n' SendMessage TaskCreate TaskUpdate TaskList TaskGet ToolSearch
}

# Comma-joined form of the set, for awk and for messages.
_cco_coordination_tools_csv() {
    _cco_coordination_tools | tr '\n' ',' | sed 's/,$//'
}

# ── Session wiring ───────────────────────────────────────────────────
# <work_dir> holds the normalized copies AND the report. Real start puts it in
# session STATE; a dry-run puts it under the dump dir, so `--dry-run --dump` shows
# the normalized set instead of paths that do not exist (ADR-0058 Consequences:
# not doing so reproduces the "artefact differs from what runs" hazard the whole
# design exists to keep honest).
#
# The report is a FILE, not a shell variable, because the pack producer runs inside
# `$( )` — a subshell, whose variables are gone by the time the caller could read
# them. Records are single short append-writes.
#
# Rebuilt from scratch at every start, like the `.claude` view and for the same
# reason: a removed pack, or an agent whose `tools:` line the user has since fixed,
# must leave no stale copy behind for a `--dry-run` to display as current.
_agents_norm_init() {
    local work_dir="$1"
    _CCO_AGN_DIR="$work_dir"
    _CCO_AGN_REPORT="$work_dir/report"
    rm -rf "$work_dir" 2>/dev/null
    mkdir -p "$work_dir" 2>/dev/null || return 1
    : > "$_CCO_AGN_REPORT" 2>/dev/null || return 1
    return 0
}

# True when the normalizer is wired up. Everything below degrades to a no-op
# (mount the original, warn nothing) when it is not — a caller that forgot to
# initialise must not lose the mount.
_agents_norm_ready() {
    [[ -n "${_CCO_AGN_DIR:-}" && -n "${_CCO_AGN_REPORT:-}" && -d "${_CCO_AGN_DIR:-}" ]]
}

# Append one record: <kind> <TAB> <target> <TAB> <source> <TAB> <detail>
# kind ∈ mount | normalized | excluded | unparsable | rw-skipped
_agents_record() {
    _agents_norm_ready || return 0
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$_CCO_AGN_REPORT" 2>/dev/null || true
}

# True when this container target already has a mount line. The dir-overlay pass
# runs AFTER the per-file producers, and a duplicate target is a compose error
# ("duplicate mount point"), not a last-one-wins.
_agents_target_seen() {
    _agents_norm_ready || return 1
    grep -qF "$(printf '\t%s\t' "$1")" "$_CCO_AGN_REPORT" 2>/dev/null
}

# ── The parser ───────────────────────────────────────────────────────
# Prints ONE line: <verdict> <TAB> <missing_csv> <TAB> <excluded_csv> <TAB> <reason>
#   inherit     — no `tools:` key: the definition inherits every tool, nothing to do
#   ok          — every member already present
#   missing     — members to add (missing_csv), possibly alongside excluded ones
#   excluded    — the only absentees are explicitly denied (A3)
#   unparsable  — D11: pass through and name the file
#
# Only the INLINE form (`tools: A, B, C`) is normalized — it is the form the
# official reference documents. A block-form list is reported unparsable rather
# than guessed at: rewriting `tools:` when the values live on following lines
# would leave the list orphaned, i.e. cco would CORRUPT a definition that was
# merely unusual. D11 exists for exactly this trade.
_agent_scan() {
    local file="$1"
    [[ -f "$file" ]] || { printf 'unparsable\t\t\tnot a readable file\n'; return 0; }
    awk -v set="$(_cco_coordination_tools_csv)" '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        function has(list, item,   n, a, i) {
            n = split(list, a, ",")
            for (i = 1; i <= n; i++) if (trim(a[i]) == item) return 1
            return 0
        }
        BEGIN { fm = 0; closed = 0; t_seen = 0; d_seen = 0; t = ""; d = "" }
        NR == 1 {
            if ($0 !~ /^---[[:space:]]*$/) {
                printf "unparsable\t\t\tno YAML frontmatter\n"; bail = 1; exit
            }
            fm = 1; next
        }
        fm == 1 && /^(---|\.\.\.)[[:space:]]*$/ { closed = 1; fm = 0; next }
        fm == 1 && /^tools:/ { t_seen = 1; t = substr($0, index($0, ":") + 1); next }
        fm == 1 && /^disallowedTools:/ { d_seen = 1; d = substr($0, index($0, ":") + 1); next }
        END {
            if (bail) exit
            if (!closed) { printf "unparsable\t\t\tunterminated YAML frontmatter\n"; exit }
            if (!t_seen) { printf "inherit\t\t\t\n"; exit }
            if (trim(t) == "") {
                printf "unparsable\t\t\t`tools:` is a block list; cco normalizes the inline form only\n"; exit
            }
            if (d_seen && trim(d) == "") {
                printf "unparsable\t\t\t`disallowedTools:` is a block list; cco normalizes the inline form only\n"; exit
            }
            n = split(set, S, ",")
            missing = ""; excluded = ""
            for (i = 1; i <= n; i++) {
                m = trim(S[i])
                if (m == "") continue
                if (d_seen && has(d, m)) { excluded = excluded (excluded == "" ? "" : ",") m; continue }
                if (!has(t, m)) missing = missing (missing == "" ? "" : ",") m
            }
            if (missing != "")       printf "missing\t%s\t%s\t\n", missing, excluded
            else if (excluded != "") printf "excluded\t\t%s\t\n", excluded
            else                     printf "ok\t\t\t\n"
        }
    ' "$file"
}

# Write the normalized copy of <src> carrying <add_csv>, to stdout-named path.
# The copy's name is derived from the source path with cksum, so it is stable
# across subshells (no shared counter exists) and two same-named agents from
# different trees cannot collide.
_agent_write_normalized() {
    local src="$1" add="$2" key out
    key=$(printf '%s' "$src" | cksum | awk '{print $1}')
    out="${_CCO_AGN_DIR}/${key}-$(basename "$src")"
    awk -v add="$add" '
        BEGIN { fm = 0; done = 0 }
        NR == 1 { print; fm = 1; next }
        fm == 1 && /^(---|\.\.\.)[[:space:]]*$/ { fm = 0; print; next }
        fm == 1 && /^tools:/ && !done {
            line = $0
            sub(/[[:space:]]+$/, "", line)
            sub(/,$/, "", line)
            gsub(/,/, ", ", add)
            print line ", " add
            done = 1
            next
        }
        { print }
    ' "$src" > "$out" 2>/dev/null || return 1
    [[ -s "$out" ]] || return 1
    printf '%s' "$out"
}

# ── Entry point 1: a single-FILE agent mount ─────────────────────────
# Prints the host path to mount for <src>. Returns the source unchanged unless a
# normalized copy is both needed and allowed. Every producer of a per-file agent
# mount routes its source through here (D5) — and the INV-AGN lint keeps it that
# way, because normalizing at one producer ships a fix that misses the very agents
# that motivated it.
#
# <target> is the CONTAINER path: the guarantee applies to a `.claude/agents/`
# mount wherever it lands, so anything else passes straight through and the call
# is safe to wrap around any `_compose_vol` source.
#
# <mode> is the mount mode this line will carry, and it is what D10 turns on: a rw
# mount means the user is authoring, so cco warns instead of projecting. Reading
# the MODE rather than a tree name is deliberate — a pack agent is mounted :ro into
# a tree whose cell may be rw, and it is the file the agent actually reads that D10
# is about.
# Usage: _compose_vol "$(_agent_src "$src" "$tgt" "$mode")" "$tgt" "$mode"
_agent_src() {
    local src="$1" tgt="$2" mode="${3:-}"
    case "$tgt" in
        */.claude/agents/*) ;;
        *) printf '%s' "$src"; return 0 ;;
    esac
    if ! _agents_norm_ready; then printf '%s' "$src"; return 0; fi

    local rec verdict missing excluded reason out
    rec=$(_agent_scan "$src")
    _peel_tab "$rec" verdict missing excluded reason

    case "$verdict" in
        missing)
            if [[ "$mode" == "rw" ]]; then
                _agents_record rw-skipped "$tgt" "$src" "$missing"
                printf '%s' "$src"; return 0
            fi
            if out=$(_agent_write_normalized "$src" "$missing") && [[ -n "$out" ]]; then
                [[ -n "$excluded" ]] && _agents_record excluded "$tgt" "$src" "$excluded"
                _agents_record normalized "$tgt" "$src" "$missing"
                printf '%s' "$out"; return 0
            fi
            # Could not write the copy — mount the original rather than lose the
            # agent, and say so. Same posture as D11: never break the session.
            _agents_record unparsable "$tgt" "$src" "could not write the normalized copy"
            printf '%s' "$src"; return 0
            ;;
        excluded)   _agents_record excluded "$tgt" "$src" "$excluded" ;;
        unparsable) _agents_record unparsable "$tgt" "$src" "$reason" ;;
        *)          _agents_record mount "$tgt" "$src" "$verdict" ;;
    esac
    printf '%s' "$src"
}

# ── Entry point 2: a DIRECTORY agent mount ───────────────────────────
# Where a tree is bound as a whole directory (the global tree, a repo-native
# `.claude`, the committed project tree with no injected children) the individual
# definitions get no mount line of their own. The normalized copies are therefore
# emitted as CHILD binds over the tree — Docker applies the deeper child after the
# parent, the same mechanism the class overlays use.
#
# INV-MP holds by construction: the mountpoint is the user's own file inside the
# parent, so it exists. A target already emitted by _agent_src is skipped — a
# duplicate mount point is a compose error, not a last-one-wins.
# Args: <host_agents_dir> <container_agents_dir> <mode>
_emit_agent_dir_overlays() {
    local hdir="$1" ctgt="$2" mode="${3:-}"
    [[ -d "$hdir" ]] || return 0
    _agents_norm_ready || return 0
    local f base out
    for f in "$hdir"/*.md; do
        [[ -f "$f" ]] || continue
        base="${f##*/}"
        _agents_target_seen "$ctgt/$base" && continue
        out=$(_agent_src "$f" "$ctgt/$base" "$mode")
        [[ "$out" != "$f" ]] && _compose_vol "$out" "$ctgt/$base" "ro"
    done
    return 0
}

# ── D6 — the change is announced, never silent ───────────────────────
# ⚠ `warn`, never `info`: A5 (FI-55) will make `cco start` pause on its own
# warnings, and it gates on exactly this distinction. A message misclassified here
# stays invisible after A5 lands.
#
# 📌 Until A5 ships this stream is write-only — the TUI opens over it — which
# ADR-0058 A2 accepted deliberately for one release: `cco whoami` and
# `--dry-run --dump` carry the same information and are readable throughout.
_agents_report_flush() {
    _agents_norm_ready || return 0
    [[ -s "$_CCO_AGN_REPORT" ]] || return 0
    local kind tgt src detail line
    local norm="" norm_n=0 broken="" broken_n=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        _peel_tab "$line" kind tgt src detail
        case "$kind" in
            normalized)
                norm_n=$((norm_n + 1))
                norm="${norm}${norm:+, }$(basename "$src")"
                ;;
            rw-skipped)
                broken_n=$((broken_n + 1))
                broken="${broken}${broken:+; }$(basename "$src") (tree is writable — edit it there: ${detail})"
                ;;
            excluded)
                broken_n=$((broken_n + 1))
                broken="${broken}${broken:+; }$(basename "$src") (denied in disallowedTools: ${detail})"
                ;;
            unparsable)
                broken_n=$((broken_n + 1))
                broken="${broken}${broken:+; }$(basename "$src") (${detail})"
                ;;
        esac
    done < "$_CCO_AGN_REPORT"

    [[ $norm_n -gt 0 ]] && \
        warn "Agent teams: widened the declared toolset of ${norm_n} agent definition(s) for this session so teammates can deliver their work — ${norm}. Added where missing: $(_cco_coordination_tools_csv | sed 's/,/, /g'). Your files are unchanged; see 'cco whoami'."
    [[ $broken_n -gt 0 ]] && \
        warn "Agent teams: ${broken_n} agent definition(s) keep NO return channel — a teammate using one will finish its work and lose it. ${broken}. Add SendMessage (and the task tools) to their 'tools:' line, or drop the line to inherit every tool."
    return 0
}

# One line for `cco whoami` (D6/D9): the guarantee is part of the session's state,
# and — unlike the start-time stream until A5 lands — this one is readable from
# inside the session, which is where the affected user is.
_agents_guarantee_line() {
    printf 'coordination tools guaranteed to restricted agents: %s\n' "$(_cco_coordination_tools_csv | sed 's/,/, /g')"
}
