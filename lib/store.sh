#!/usr/bin/env bash
# lib/store.sh — the ONLY module that reaches the ADR-0047-confined internal-store
# buckets (DATA registries, STATE index sidecars, CACHE llms) for the destructive
# and re-key cascades, OUTSIDE the primitive layers (paths / index / tags / sync-meta).
#
# RC-3 (05-store-write-path.md). The internal store lives under a cco-svc-owned
# 0700 root the `claude` uid cannot traverse (ADR-0047 §2); the only crossing is the
# setuid helper, reached from bin/cco's `__store` re-entry. A command body must NEVER
# `rm`/`mv` a confined path itself, nor evaluate an existence/writability predicate on
# one (behind an opaque parent every such predicate silently reads FALSE — §1.3): it
# asks this module for a PLAN, computed on the side of the boundary where the answer
# is knowable, then applies a named whole-cascade op. A store write that cannot
# complete is an ERROR (exit 1), never a false ✓ (INV-S3).
#
# Two crossings, each all-or-nothing:
#   _store_check <op> args…   — crossing #1, READ ONLY: dies (exit 1) on an
#                               unreachable/unwritable store BEFORE any mutation; exposes
#                               present/collision/refs for the caller (fail-closed, INV-S4).
#   _store_apply <op> args…   — crossing #2, MUTATE: dies (exit 1) on any failure (INV-S3).
#
# Both resolve the boundary identically: in a container-operator session (and not
# already elevated) they re-exec through the setuid helper as `cco __store store-op
# <mode> <op> args…`; on the host, or once elevated, they run in-process. The helper
# injects CCO_STORE_ELEVATED=1, so the recursion terminates by construction.
#
# Op catalogue (cycle 1) — named cascades, NEVER raw paths (INV-S1). Every op takes a
# kind from a fixed whitelist and logical names validated fail-closed; this module
# composes every path itself from the bucket resolvers:
#   sidecar-purge <kind> <name>      DATA/<kind>/<name>, STATE/<kind>/<name>, tags
#   sidecar-rekey <kind> <old> <new> same, moved (+ unmounted-project census for packs)
#   llms-purge    <name>             CACHE/llms/<name>, tags
#   llms-rekey    <old> <new>        same, moved
#   remote-put    <name> <url>       DATA/remotes
#   remote-drop   <name>             DATA/remotes, STATE/remotes-token
#   remote-rekey  <old> <new>        DATA/remotes, STATE/remotes-token
#   kind ∈ packs|templates ; every op writes the `global` tree (~/.cco personal store).
#
# bash 3.2: the catalogue and the tree map are `case` statements (no associative
# arrays); no `mapfile`. Dependencies (all resolved at call time): colors.sh (die),
# utils.sh (_peel_tab), paths.sh (bucket resolvers + _cco_container_operator),
# tags.sh (_tags_forget/_tags_rename), cmd-remote.sh (remote_get_url/_remote_token_*),
# index.sh (_index_list_projects).

_CCO_STORE_HELPER="/usr/local/bin/cco-svc-helper"

# ── INV-S1: fail-closed argument validation (NO argv path reaches the store) ──

# A logical resource name: starts alphanumeric, then [A-Za-z0-9._-] only, and never
# contains a path separator or `..`. The explicit */* and *..* rejection is the
# traversal guard (`../../state/cco` etc. never compose a store location).
_store_valid_name() {
    case "$1" in
        ''|*..*|*/*) return 1 ;;
        [A-Za-z0-9]*) [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ;;
        *) return 1 ;;
    esac
}

# The two sidecar kinds. A store op never takes an arbitrary kind.
_store_valid_kind() { [[ "$1" == packs || "$1" == templates ]]; }

# A remote url is registry CONTENT, not a path used to compose a store location, so
# it is not name-shaped; it must merely be non-empty, look like a url/path, and carry
# no newline (which would inject a second registry line).
_store_valid_url() {
    local u="$1"
    [[ -n "$u" ]] || return 1
    case "$u" in *$'\n'*|*$'\r'*) return 1 ;; esac
    [[ "$u" == *:* || "$u" == */* ]] || return 1
    return 0
}

# The whole-cascade validator: op known, correct arity, every name valid. Fail-closed
# — anything unrecognised returns non-zero. Runs FIRST in the elevated store-op arm
# (before the gate, so a malformed op cannot even select a target tree) AND as the
# first statement of _store_probe/_store_dispatch (the host in-process path).
# Usage: _store_validate_args <op> [args…]
_store_validate_args() {
    local op="$1"; shift
    case "$op" in
        sidecar-purge)
            [[ $# -eq 2 ]] || return 1
            _store_valid_kind "$1" || return 1
            _store_valid_name "$2" || return 1 ;;
        sidecar-rekey)
            [[ $# -eq 3 ]] || return 1
            _store_valid_kind "$1" || return 1
            { _store_valid_name "$2" && _store_valid_name "$3"; } || return 1 ;;
        llms-purge|remote-drop)
            [[ $# -eq 1 ]] || return 1
            _store_valid_name "$1" || return 1 ;;
        llms-rekey|remote-rekey)
            [[ $# -eq 2 ]] || return 1
            { _store_valid_name "$1" && _store_valid_name "$2"; } || return 1 ;;
        remote-put)
            [[ $# -eq 2 ]] || return 1
            _store_valid_name "$1" || return 1
            _store_valid_url "$2"  || return 1 ;;
        *) return 1 ;;
    esac
    return 0
}

# _store_target_tree <op> — the (G,Pc,Po) axis the op writes; ONE source read by both
# the elevated gate (INV-S2) and the claude-side UX check. Every cycle-1 op writes the
# personal store (~/.cco) → `global` (G=rw).
_store_target_tree() {
    case "$1" in
        sidecar-purge|sidecar-rekey|llms-purge|llms-rekey|remote-put|remote-drop|remote-rekey)
            printf 'global' ;;
        *) return 1 ;;
    esac
}

# ── The plan (crossing #1, read only) ────────────────────────────────

# The bucket ROOT dirs an op writes — the units whose reachability + writability the
# plan probes. Probing the root is what makes a `chmod` on the bucket parent (the
# ADR-0047 boundary model, §6.1) observable: tags.yml lives in the DATA root, and an
# unwritable/opaque root compromises the whole cascade.
_store_op_buckets() {
    case "$1" in
        sidecar-purge|sidecar-rekey) _cco_data_dir; _cco_state_dir ;;
        llms-purge|llms-rekey)       _cco_llms_dir ;;
        remote-put)                  _cco_data_dir ;;
        remote-drop|remote-rekey)    _cco_data_dir; _cco_state_dir ;;
    esac
}

# True iff the remotes registry already carries an entry for <name>.
_store_remote_has() {
    local name="$1" rf; rf=$(_cco_remotes_file)
    [[ -f "$rf" ]] && grep -q "^${name}=" "$rf" 2>/dev/null
}

# Count the indexed projects NOT mounted in this session (§3.5). An unmounted project's
# committed .cco/project.yml cannot be inspected or rewritten in-container, so a pack it
# references would drift under a rename — the E6B-04 half-apply. This is a CONSERVATIVE
# superset of "affected but unmounted" (we cannot read an unmounted project.yml to know
# whether it references the pack), erring toward refusal for the data-loss-shaped case.
# On the host (never operator) the fan-out sees every resolved project, so the count is
# 0 and the existing unresolved-member guard governs correctness.
_store_unmounted_project_count() {
    _cco_container_operator || { printf '0'; return 0; }
    local mounted=",${PROJECT_NAME:-},${CCO_CONFIG_TARGETS:-}," n=0 p
    while IFS='=' read -r p _; do
        [[ -z "$p" || "$p" == _template ]] && continue
        case "$mounted" in *",${p},"*) continue ;; esac
        n=$((n + 1))
    done < <(_index_list_projects 2>/dev/null)
    printf '%s' "$n"
}

# _store_probe <op> args… — the elevated (or host in-process) plan. Emits tab-separated
# verdict lines and MUTATES NOTHING. NEVER dies (it is consumed via $(…)); a malformed
# op or an unreachable store is reported, not fatal — _store_check does the dying.
#   reach     reachable|unreachable
#   write     writable|unwritable        (only when reachable)
#   present   yes|no                      (llms/remote: does the subject exist)
#   collision yes|no                      (rekey ops: does the NEW name exist)
#   refs      <n>                         (sidecar-rekey packs: unmounted-project count)
_store_probe() {
    local op="$1"; shift
    _store_validate_args "$op" "$@" || { printf 'reach\tunreachable\n'; return 2; }

    local d t
    while IFS= read -r d; do
        [[ -z "$d" || ! -d "$d" ]] && continue
        if [[ ! -r "$d" || ! -x "$d" ]]; then printf 'reach\tunreachable\n'; return 0; fi
    done < <(_store_op_buckets "$op")
    printf 'reach\treachable\n'
    while IFS= read -r d; do
        [[ -z "$d" || ! -d "$d" ]] && continue
        t=$(mktemp "$d/.cco-stwtest.XXXXXX" 2>/dev/null) || { printf 'write\tunwritable\n'; return 0; }
        rm -f "$t" 2>/dev/null || true
    done < <(_store_op_buckets "$op")
    printf 'write\twritable\n'

    local ld; ld=$(_cco_llms_dir)
    case "$op" in
        llms-purge)
            [[ -d "$ld/$1" ]] && printf 'present\tyes\n' || printf 'present\tno\n' ;;
        llms-rekey)
            [[ -d "$ld/$1" ]] && printf 'present\tyes\n' || printf 'present\tno\n'
            [[ -d "$ld/$2" ]] && printf 'collision\tyes\n' || printf 'collision\tno\n' ;;
        remote-put)
            _store_remote_has "$1" && printf 'present\tyes\n' || printf 'present\tno\n' ;;
        remote-drop)
            _store_remote_has "$1" && printf 'present\tyes\n' || printf 'present\tno\n' ;;
        remote-rekey)
            _store_remote_has "$1" && printf 'present\tyes\n' || printf 'present\tno\n'
            _store_remote_has "$2" && printf 'collision\tyes\n' || printf 'collision\tno\n' ;;
    esac
    if [[ "$op" == sidecar-rekey && "$1" == packs ]]; then
        printf 'refs\t%s\n' "$(_store_unmounted_project_count)"
    fi
    return 0
}

# _store_plan <op> args… — crossing #1. Echoes the plan for _store_check to parse.
# NEVER dies (consumed via $(…)); returns non-zero and lets the caller do the dying.
_store_plan() {
    local op="$1"; shift
    if [[ "${CCO_STORE_ELEVATED:-}" != "1" ]] && _cco_container_operator \
       && [[ -x "$_CCO_STORE_HELPER" ]]; then
        "$_CCO_STORE_HELPER" store-op plan "$op" "$@"
        return $?
    fi
    _store_probe "$op" "$@"
}

# _store_check <op> args… — the fail-closed pre-flight (05 §3.4 Phase 0; the design's
# _store_require_plan). Runs the plan on the privileged side, then dies (exit 1) on an
# unreachable/unwritable store BEFORE any mutation, and exposes the verdict to the
# caller via _STORE_PRESENT / _STORE_COLLISION / _STORE_REFS. This is the ONLY place a
# store predicate is turned into a decision, and it runs OUTSIDE any command
# substitution so `die` exits the process (INV-S6). Usage: _store_check <op> args…
_store_check() {
    local op="$1"; shift
    _STORE_PRESENT=no; _STORE_COLLISION=no; _STORE_REFS=0
    local plan tag a line
    plan=$(_store_plan "$op" "$@") \
        || die "Cannot inspect the internal store for '$op' — the store pre-flight failed. Run the command on your host; nothing was changed."
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        _peel_tab "$line" tag a
        case "$tag" in
            reach)     [[ "$a" == unreachable ]] \
                && die "Cannot update the internal store for '$op' — the store is not reachable in this session (the ADR-0047 boundary is opaque here). Run the command on your host; nothing was changed." ;;
            write)     [[ "$a" == unwritable ]] \
                && die "Cannot update the internal store for '$op' — the store is not writable in this session. Run the command on your host; nothing was changed." ;;
            present)   [[ "$a" == yes ]] && _STORE_PRESENT=yes ;;
            collision) [[ "$a" == yes ]] && _STORE_COLLISION=yes ;;
            refs)      _STORE_REFS="$a" ;;
        esac
    done <<< "$plan"
    return 0
}

# ── The apply (crossing #2, mutate) ──────────────────────────────────

# _store_apply <op> args… — crossing #2. RUN (never exec): the caller must survive to
# finish its claude-side work and report. Dies (exit 1) on any failure — a store write
# that cannot complete is an error, never a false ✓ (INV-S3). Emits status, not stdout;
# NEVER used inside $(…). Usage: _store_apply <op> args…
_store_apply() {
    local op="$1"; shift
    _store_validate_args "$op" "$@" || die "Internal: invalid store op '$op'."   # UX; authoritative gate is elevated
    if [[ "${CCO_STORE_ELEVATED:-}" != "1" ]] && _cco_container_operator \
       && [[ -x "$_CCO_STORE_HELPER" ]]; then
        "$_CCO_STORE_HELPER" store-op apply "$op" "$@" \
            || die "Store update failed ($op) — see the error above. Re-run after resolving the cause."
        return 0
    fi
    _store_dispatch "$op" "$@" \
        || die "Store update failed ($op) — see the error above. Re-run after resolving the cause."
    return 0
}

# _store_dispatch <op> args… — elevated (or host in-process) MUTATION. Re-validates
# (INV-S1), then runs the named cascade. Returns non-zero on the FIRST failed step
# (INV-S3): every rm/mv/redirect is status-checked. Composes every path internally.
_store_dispatch() {
    local op="$1"; shift
    _store_validate_args "$op" "$@" || { error "Invalid store op '$op'."; return 2; }
    case "$op" in
        sidecar-purge) _store_do_sidecar_purge "$@" ;;
        sidecar-rekey) _store_do_sidecar_rekey "$@" ;;
        llms-purge)    _store_do_llms_purge "$@" ;;
        llms-rekey)    _store_do_llms_rekey "$@" ;;
        remote-put)    _store_do_remote_put "$@" ;;
        remote-drop)   _store_do_remote_drop "$@" ;;
        remote-rekey)  _store_do_remote_rekey "$@" ;;
        *) return 2 ;;
    esac
}

_store_do_sidecar_purge() {
    local kind="$1" name="$2" d s
    d="$(_cco_data_dir)/$kind/$name"
    s="$(_cco_state_dir)/$kind/$name"
    rm -rf "$d" || return 1
    rm -rf "$s" || return 1
    _tags_forget "$kind" "$name" || return 1
    return 0
}

_store_do_sidecar_rekey() {
    local kind="$1" old="$2" new="$3" dr sr
    dr=$(_cco_data_dir); sr=$(_cco_state_dir)
    if [[ -d "$dr/$kind/$old" ]]; then mv "$dr/$kind/$old" "$dr/$kind/$new" || return 1; fi
    if [[ -d "$sr/$kind/$old" ]]; then mv "$sr/$kind/$old" "$sr/$kind/$new" || return 1; fi
    _tags_rename "$kind" "$old" "$new" || return 1
    return 0
}

_store_do_llms_purge() {
    local name="$1" d
    d="$(_cco_llms_dir)/$name"
    rm -rf "$d" || return 1
    _tags_forget llms "$name" || return 1
    return 0
}

_store_do_llms_rekey() {
    local old="$1" new="$2" ld
    ld=$(_cco_llms_dir)
    mv "$ld/$old" "$ld/$new" || return 1
    _tags_rename llms "$old" "$new" || return 1
    return 0
}

_store_do_remote_put() {
    local name="$1" url="$2" rf
    rf=$(_cco_remotes_file)
    if [[ ! -f "$rf" ]]; then
        mkdir -p "$(dirname "$rf")" || return 1
        printf '# CCO sharing-repo remotes — name=url (DATA, de-tokenized; tokens in STATE)\n' > "$rf" || return 1
    fi
    printf '%s=%s\n' "$name" "$url" >> "$rf" || return 1
    return 0
}

_store_do_remote_drop() {
    local name="$1" rf tmp grc
    rf=$(_cco_remotes_file)
    if [[ -f "$rf" ]]; then
        tmp=$(mktemp "$rf.XXXXXX") || return 1
        grep -v "^${name}=" "$rf" > "$tmp"; grc=$?
        [[ $grc -le 1 ]] || { rm -f "$tmp" 2>/dev/null; return 1; }   # 0/1 = printed/empty; 2 = error
        mv "$tmp" "$rf" || { rm -f "$tmp" 2>/dev/null; return 1; }
    fi
    _remote_token_remove "$name" 2>/dev/null || true   # an absent token is a valid no-op
    return 0
}

_store_do_remote_rekey() {
    local old="$1" new="$2" rf tmp url grc tok
    rf=$(_cco_remotes_file)
    [[ -f "$rf" ]] || return 1
    url=$(remote_get_url "$old") || url=""
    tmp=$(mktemp "$rf.XXXXXX") || return 1
    grep -v "^${old}=" "$rf" > "$tmp"; grc=$?
    [[ $grc -le 1 ]] || { rm -f "$tmp" 2>/dev/null; return 1; }
    printf '%s=%s\n' "$new" "$url" >> "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
    mv "$tmp" "$rf" || { rm -f "$tmp" 2>/dev/null; return 1; }
    if remote_get_token "$old" >/dev/null 2>&1; then
        tok=$(remote_get_token "$old")
        _remote_token_set "$new" "$tok" || return 1
        _remote_token_remove "$old" 2>/dev/null || true
    fi
    return 0
}
