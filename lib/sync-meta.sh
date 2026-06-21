#!/usr/bin/env bash
# lib/sync-meta.sh — per-machine sync-state bookkeeping (STATE; design §4.6 /
# ADR-0022 F39).
#
# `cco sync` is a filesystem copy, not a merge engine — there is NO 3-way
# sync-base here. This module records only a lightweight, per-machine,
# never-committed signal: a last-synced FINGERPRINT per repo, so cco can tell a
# repo a developer edited locally since the last sync apart from one that merely
# received a sync.
#
# Fingerprint contract (F39, the load-bearing semantics):
#   - The hash is taken over the EXACT synced set of §4.1: project.yml +
#     claude/** [+ secrets.env.example]; NEVER secrets.env, the repo-root
#     .claude/, or system dirs. One definition feeds both write and compare.
#   - The hashed material is machine-AGNOSTIC: file content keyed by its
#     relative path inside .cco/, never an absolute path — so two repos with
#     identical synced content fingerprint identically.
#   - Divergence is LAZY / read-time: a repo is "edited locally since the last
#     sync" iff its current synced-set hash != its stored fingerprint
#     (recomputed on read; no eager clear, no event hook).
#   - NO stored fingerprint => pristine (code-only / fresh machine /
#     never-synced); never divergent.
#
# The store is keyed by the repo ROOT absolute path on this machine (the synced
# set lives in <repo-root>/.cco/). `cco sync` writes the fingerprint (a) after a
# target successfully receives a sync and (b) for the source at the same sync.
#
# Provides: _sync_meta_file(), _sync_synced_files(), _sync_fingerprint_compute(),
#   _sync_fingerprint_get(), _sync_fingerprint_set(), _sync_fingerprint_clear(),
#   _sync_is_divergent(), _sync_record()
# Dependencies: paths.sh (_cco_state_dir). Hash via shasum/sha256sum/cksum.

# Absolute path to the sync-meta store (STATE; host-side guard via resolver).
# Lines are "<repo-root-abs>\t<fingerprint>".
_sync_meta_file() {
    printf '%s\n' "$(_cco_state_dir)/sync-meta"
}

# Hash stdin → a hex digest, using the first available portable tool. shasum is
# present on macOS and most Linux (Perl Digest::SHA); sha256sum on Linux; cksum
# is the POSIX last resort.
_sync_hash_stdin() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        cksum | awk '{print $1 "-" $2}'
    fi
}

# Emit "<label> <content-hash>" for one file (label = its .cco-relative path).
_sync_hash_file() {
    local file="$1" label="$2" h
    h=$(_sync_hash_stdin < "$file")
    printf '%s %s\n' "$label" "$h"
}

# Echo the synced set of a <cco_dir> as .cco-relative paths (§4.1): project.yml,
# secrets.env.example (if present), and every file under claude/. NEVER
# secrets.env, the repo-root .claude/, or system dirs. This is the SINGLE
# definition of the synced set — both the fingerprint (below) and `cco sync`'s
# diff/copy consume it, so write and compare can never drift apart.
# Usage: _sync_synced_files <cco_dir>
_sync_synced_files() {
    local cco="$1"
    [[ -f "$cco/project.yml" ]]         && echo "project.yml"
    [[ -f "$cco/secrets.env.example" ]] && echo "secrets.env.example"
    if [[ -d "$cco/claude" ]]; then
        ( cd "$cco" && find claude -type f 2>/dev/null | LC_ALL=C sort )
    fi
}

# Compute the fingerprint of a repo's synced set (§4.1). Echoes the digest, or
# empty if the repo has no .cco/. Deterministic and machine-agnostic: each file
# contributes "<rel-path> <content-hash>", the list is sorted, and the whole
# stream is hashed.
# Usage: _sync_fingerprint_compute <repo_root>
_sync_fingerprint_compute() {
    local repo_root="$1" cco="$1/.cco" rel
    [[ -d "$cco" ]] || { printf '%s\n' ""; return 0; }

    {
        while IFS= read -r rel; do
            [[ -z "$rel" ]] && continue
            _sync_hash_file "$cco/$rel" "$rel"
        done < <(_sync_synced_files "$cco")
    } | LC_ALL=C sort | _sync_hash_stdin
}

# Stored fingerprint for <repo_root>, or empty.
_sync_fingerprint_get() {
    local key="$1" f
    f=$(_sync_meta_file)
    [[ -f "$f" ]] || return 0
    awk -F'\t' -v k="$key" '$1 == k { print $2; exit }' "$f"
}

# Upsert <repo_root> -> <fingerprint> (atomic mktemp+mv, the index.sh convention).
_sync_fingerprint_set() {
    local key="$1" val="$2" f
    f=$(_sync_meta_file)

    local tmpf=""
    # shellcheck disable=SC2064
    trap 'rm -f ${tmpf:+"$tmpf"}' RETURN
    tmpf=$(mktemp "${f}.XXXXXX")

    {
        [[ -f "$f" ]] && awk -F'\t' -v k="$key" '$1 != k' "$f"
        printf '%s\t%s\n' "$key" "$val"
    } > "$tmpf" && mv "$tmpf" "$f"
}

# Remove the fingerprint for <repo_root> (no-op if absent).
_sync_fingerprint_clear() {
    local key="$1" f
    f=$(_sync_meta_file)
    [[ -f "$f" ]] || return 0

    local tmpf=""
    # shellcheck disable=SC2064
    trap 'rm -f ${tmpf:+"$tmpf"}' RETURN
    tmpf=$(mktemp "${f}.XXXXXX")

    awk -F'\t' -v k="$key" '$1 != k' "$f" > "$tmpf" && mv "$tmpf" "$f"
}

# Record a fresh fingerprint for <repo_root> (call after a successful sync, on
# both the target and the source side). No-op for a repo without .cco/.
_sync_record() {
    local repo_root="$1" fp
    fp=$(_sync_fingerprint_compute "$repo_root")
    [[ -z "$fp" ]] && return 0
    _sync_fingerprint_set "$repo_root" "$fp"
}

# True (exit 0) iff <repo_root> has been edited locally since its last recorded
# sync: a stored fingerprint exists AND the current synced-set hash differs from
# it. No stored fingerprint => pristine => not divergent (exit 1).
# Usage: _sync_is_divergent <repo_root>
_sync_is_divergent() {
    local repo_root="$1" stored current
    stored=$(_sync_fingerprint_get "$repo_root")
    [[ -z "$stored" ]] && return 1
    current=$(_sync_fingerprint_compute "$repo_root")
    [[ "$current" != "$stored" ]]
}
