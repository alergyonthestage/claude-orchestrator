#!/usr/bin/env bash
# lib/paths.sh — Framework path resolution helpers
#
# Provides: XDG 4-bucket resolver — _cco_config_dir(), _cco_data_dir(),
#           _cco_state_dir(), _cco_cache_dir() (+ _cco_in_container(),
#           _cco_resolver_guard(), _cco_first_abs(), _cco_ensure_dir());
#           legacy dual-read helpers — _cco_remotes_file(), _cco_global_meta(),
#           _cco_global_base_dir(), _cco_project_meta(), _cco_project_base_dir(),
#           _cco_project_managed(), _cco_project_compose(),
#           _cco_project_claude_state(), _cco_project_pack_manifest(),
#           _cco_project_source(), _cco_pack_source(), _cco_template_source(),
#           _cco_pack_install_tmp()
# Dependencies: colors.sh (die)
# Globals: none — the resolvers read $HOME and the CCO_*_HOME / XDG_*_HOME env

# All framework-managed files live inside per-scope .cco/ directories.
# During rollout (migration 009), helpers check the new path first and
# fall back to the old path for backward compatibility.

# ── Generic path resolution ─────────────────────────────────────────
# Resolve between new (post-migration) and old (pre-migration) paths.
# Checks for existence with the appropriate test (-f for file, -d for dir),
# returns the new path if neither exists (default for new installations).
# Usage: _cco_resolve_path <type> <new_path> <old_path>
#   type: "f" for file, "d" for directory
_cco_resolve_path() {
    local type="$1" new="$2" old="$3"
    if [[ "-${type}" == "-f" ]]; then
        if [[ -f "$new" ]]; then echo "$new"
        elif [[ -f "$old" ]]; then echo "$old"
        else echo "$new"
        fi
    else
        if [[ -d "$new" ]]; then echo "$new"
        elif [[ -d "$old" ]]; then echo "$old"
        else echo "$new"
        fi
    fi
}

# ── Top-level ────────────────────────────────────────────────────────

# Remote registry — name->url, de-tokenized, in DATA (synced, never-team; M3 /
# ADR-0016 D7). Tokens live separately in STATE (never-sync) — see below.
_cco_remotes_file() {
    printf '%s\n' "$(_cco_data_dir)/remotes"
}

# Remote auth tokens — name->token, in STATE (0600, machine-local, never-sync;
# the M3 split that keeps secrets off the synced DATA registry).
_cco_remotes_token_file() {
    printf '%s\n' "$(_cco_state_dir)/remotes-token"
}

# Personal llms store — content + its cache-state sidecar (<name>/.cco/source:
# url/variant/resolved_url/etag/downloaded) → CACHE: re-fetchable from the
# coordinate, deduped per machine by name, never synced (F1; design §2.2 line
# 201, ADR-0016 D2/D7). NOT in the `cco config` allowlist — it must not be
# versioned config. bin/cco sets LLMS_DIR from this (CCO_LLMS_DIR override wins).
_cco_llms_dir() {
    printf '%s\n' "$(_cco_cache_dir)/llms"
}

# Claude Code native-install home → CACHE (ADR-0039). The image no longer bakes
# the binary (npm + DISABLE_AUTOUPDATER retired); the entrypoint installs it at
# first start via the official `install.sh`. `bin/` and `share/` are bind-mounted
# into the container at /home/claude/.local/{bin,share/claude}, so the binary and
# its state survive restarts and auto-update IN PLACE (no rebuild). CACHE because
# it is fully re-fetchable from install.sh — and `cco clean` never scans CACHE, so
# the install survives `cco clean --all` (decision 3). `cco build --no-cache` wipes
# this dir to force a fresh install on next start (decision 4).
_cco_claude_install_dir() {
    printf '%s\n' "$(_cco_cache_dir)/claude-install"
}

# ── Global .cco/meta decompose homes (ADR-0013 D4 / ADR-0025) ───────
# The legacy global `.cco/meta` grab-bag splits by sync-profile:
#  - languages → CONFIG `~/.cco/languages` (the one config datum; regenerates
#    language.md). User-authored, versioned.
#  - changelog markers → STATE top-level `last_seen`/`last_read` (machine-local).
#  - schema/policies/flags + the hash `manifest:` block → the global STATE
#    `/update/meta` (the helpers above) — NOT dropped (the hash manifest is the
#    load-bearing 3-way-merge change manifest; only the separate `manifest.yml`
#    and the legacy `pack-manifest` are removed).
_cco_languages_file() {
    printf '%s\n' "$(_cco_config_dir)/languages"
}

# Claude Code channel/version preference → CONFIG `~/.cco/claude-version`
# (ADR-0039 / decision 1). A single user-authored, git-versioned datum holding a
# release channel (`latest` — the default — or `stable`) or a pinned `x.y.z`. Read
# at `cco start`/`cco build` and forwarded to the entrypoint installer as
# CLAUDE_CODE_VERSION. `cco build --claude-version` remains the one-off override.
_cco_claude_version_file() {
    printf '%s\n' "$(_cco_config_dir)/claude-version"
}

# Echo the effective channel/version preference, defaulting to `latest` when the
# file is absent or blank. First non-comment, non-empty line wins.
_cco_claude_version_pref() {
    local f; f=$(_cco_claude_version_file)
    local val=""
    if [[ -f "$f" ]]; then
        val=$(grep -vE '^\s*(#|$)' "$f" 2>/dev/null | head -n1 | tr -d '[:space:]')
    fi
    printf '%s\n' "${val:-latest}"
}

_cco_last_seen_file() {
    printf '%s\n' "$(_cco_state_dir)/last_seen"
}

_cco_last_read_file() {
    printf '%s\n' "$(_cco_state_dir)/last_read"
}

# ── Update-engine artifact homes → STATE (H6 / ADR-0016 D5) ─────────
# The 3-way-merge ancestors (`base/`) and the per-file hash manifest + schema
# meta (`meta`) are machine-local INTERNAL state — never config (P6). They live
# under STATE keyed by identity, NOT inside the committed/published config
# buckets: <state>/cco/{global,projects/<id>,packs/<name>}/update/{meta,base}.
# Only the PATHS move here (P2); the merge LOGIC (update-merge.sh) is unchanged.

# Project identity <id> = the project.yml `name:` (the index `projects:` key),
# NOT the repo-directory basename (ADR-0024 D1 / design §2.2 pin). `name` is
# enforced unique. Reads the hosted project.yml (new `.cco/` layout or legacy
# root); falls back to the dir basename when no name is recorded.
_cco_project_id() {
    local dir="$1" yml name=""
    for yml in "$dir/.cco/project.yml" "$dir/project.yml"; do
        if [[ -f "$yml" ]]; then
            name=$(awk -F': *' '/^name:/{v=$2; gsub(/["'\''"]/,"",v); gsub(/[ \t\r]+$/,"",v); print v; exit}' "$yml")
            [[ -n "$name" ]] && break
        fi
    done
    [[ -z "$name" ]] && name=$(basename "$dir")
    printf '%s' "$name"
}

# ── Global scope ─────────────────────────────────────────────────────

_cco_global_meta() {
    printf '%s\n' "$(_cco_state_dir)/global/update/meta"
}

_cco_global_base_dir() {
    printf '%s\n' "$(_cco_state_dir)/global/update/base"
}

# ── Project scope ($1 = project_dir) ────────────────────────────────

_cco_project_meta() {
    printf '%s\n' "$(_cco_state_dir)/projects/$(_cco_project_id "$1")/update/meta"
}

_cco_project_base_dir() {
    printf '%s\n' "$(_cco_state_dir)/projects/$(_cco_project_id "$1")/update/base"
}

# M10: _cco_project_managed and _cco_project_compose were removed — dead helpers
# with no callers that returned repo-local paths no current code writes (compose →
# STATE, managed → CACHE via _cco_project_cache_managed). _cco_project_claude_state
# below is kept: it is still read by the legacy memory→claude-state internal
# migration (secrets.sh) which operates on the OLD repo-local layout.
_cco_project_claude_state() {
    _cco_resolve_path d "$1/.cco/claude-state" "$1/claude-state"
}

# Managed runtime overlays (browser.json / .browser-port / github.json /
# policy.json) are GENERATED per session into CACHE and overlaid :ro (ADR-0005,
# Commit B/T8). They are regenerable machine-local state — never committed config
# (AD3/G8) — and the committed <repo>/.cco is mounted :ro in the container
# (ADR-0027 D3), so runtime state cannot live there. cmd-start writes them to
# `<cache>/cco/projects/<name>/managed/`; the readers (stop/chrome/start
# port-collection) resolve the same path through this helper.
# NOTE: $1 is the project NAME (the `<id>` = project.yml `name:` = index key),
# NOT a repo directory — unlike the resolve-path helpers above.
_cco_project_cache_managed() {
    printf '%s\n' "$(_cco_cache_dir)/projects/$1/managed"
}

# Session-scoped machine-local state for a project (ADR-0009 / design §2.2):
# auto-memory + session transcripts, mounted into the container by cmd-start and
# hydrated by `cco init --migrate`. Both memory and transcripts live under the
# `session/` subtree in STATE, so the runtime mount source and the migrate
# destination stay in sync — the canonical home that fixes the H7 drift (migrate
# had written projects/<id>/memory while cmd-start mounts projects/<id>/session/*).
# Migration wires both: memory via _cco_project_session_memory, transcripts via
# _cco_project_session_transcripts (migrate.sh, after index registration / M5).
# $1 = project NAME (the <id> = project.yml name: = index key), NOT a repo dir —
# matching _cco_project_cache_managed.
_cco_project_session_dir() {
    printf '%s\n' "$(_cco_state_dir)/projects/$1/session"
}
_cco_project_session_memory() {
    printf '%s\n' "$(_cco_state_dir)/projects/$1/session/memory"
}
_cco_project_session_transcripts() {
    printf '%s\n' "$(_cco_state_dir)/projects/$1/session/claude-state"
}

# Note: pack-manifest lives inside .claude/, not project root
_cco_project_pack_manifest() {
    _cco_resolve_path f "$1/.claude/.cco/pack-manifest" "$1/.claude/.pack-manifest"
}

# ── Pack scope ($1 = pack_dir) ──────────────────────────────────────

# Install-provenance `source` → DATA, identity-keyed (ADR-0022 D1 / ADR-0016 D5).
# The file holds the machine-agnostic upstream coordinate only (`url`/`ref`/
# `resource`); machine-local bookkeeping (`commit`/`installed`/`updated`) lives in
# the STATE `/update` meta. (llms content + its cache-state sidecar live in CACHE
# via _cco_llms_dir — F1 / ADR-0016 D2/D7.) Pack identity <name> = the flat-store
# dir basename.
_cco_pack_source() {
    printf '%s\n' "$(_cco_data_dir)/packs/$(basename "$1")/source"
}

# Pack-scoped merge artifacts → STATE, keyed by pack name (= the flat-store dir
# basename). <state>/cco/packs/<name>/update/{meta,base}.
_cco_pack_meta() {
    printf '%s\n' "$(_cco_state_dir)/packs/$(basename "$1")/update/meta"
}

_cco_pack_base_dir() {
    printf '%s\n' "$(_cco_state_dir)/packs/$(basename "$1")/update/base"
}

# Project install-provenance `source` → DATA, keyed by project identity (the
# project.yml `name:`, ADR-0024 D1). Same coordinate-only contract as packs.
_cco_project_source() {
    printf '%s\n' "$(_cco_data_dir)/projects/$(_cco_project_id "$1")/source"
}

# Template install-provenance `source` → DATA, keyed by template dir basename.
# (New in P4 — templates join the coordinate model; ADR-0022 D1.)
_cco_template_source() {
    printf '%s\n' "$(_cco_data_dir)/templates/$(basename "$1")/source"
}

# Template-scoped install meta → STATE, keyed by template dir basename. Mirrors
# `_cco_pack_meta`: holds the machine-local `installed_commit` (+ install/update
# dates) the `cco update --check` advancement test reads (ADR-0022 D1/D6, P5-5).
_cco_template_meta() {
    printf '%s\n' "$(_cco_state_dir)/templates/$(basename "$1")/update/meta"
}

# Template-scoped merge artifacts → STATE, keyed by template name (the flat-store
# basename, matching the flat sharing-repo templates/<name>/). Mirrors the pack
# form; the sync-before-publish merge ancestor (ADR-0022 D5). Never-sync.
_cco_template_base_dir() {
    printf '%s\n' "$(_cco_state_dir)/templates/$(basename "$1")/update/base"
}

_cco_pack_install_tmp() {
    _cco_resolve_path d "$1/.cco/install-tmp" "$1/.cco-install-tmp"
}

# ── XDG 4-bucket resolver (ADR-0007 / ADR-0015) ─────────────────────
# The decentralized-config destination buckets. Resolved HOST-SIDE only:
# the index stores host-absolute paths that get bind-mounted to fixed
# container paths, so the two namespaces must never be conflated.
#
#   CONFIG  ~/.cco                          dotdir; user-authored, git-versioned (no override)
#   DATA    $CCO_DATA_HOME  → $XDG_DATA_HOME/cco  → ~/.local/share/cco
#   STATE   $CCO_STATE_HOME → $XDG_STATE_HOME/cco → ~/.local/state/cco
#   CACHE   $CCO_CACHE_HOME → $XDG_CACHE_HOME/cco → ~/.cache/cco
#
# Precedence per bucket: the cco-specific override ($CCO_*_HOME — the cco dir
# itself) ranks above $XDG_*_HOME/cco, which ranks above the default. An
# override that is unset, empty, or non-absolute is treated as absent.

# True (0) when running inside a session container — see the guard below.
# cco is Docker-native (it drives `docker compose`), so /.dockerenv — injected by
# the Docker daemon into every container regardless of image — is the authoritative
# signal. CCO_IN_CONTAINER is an explicit override for deterministic tests/dev (and a
# forward seam: a future non-Docker runtime could export it from its entrypoint).
# The old HOME=/home/claude heuristic was DROPPED (L6): it false-positived for a real
# HOST user named `claude`, and its "stripped image" rationale was wrong — /.dockerenv
# is daemon-injected, not part of the image, so it cannot be stripped.
_cco_in_container() {
    [[ "${CCO_IN_CONTAINER:-}" == "1" ]] && return 0
    [[ -f /.dockerenv ]] && return 0
    return 1
}

# Anti-in-container guard (H4, ADR-0007 Robustness). cco resolves host paths
# host-side only; a hook or agent that invokes cco from inside a session
# container must not create/read state under the container's home. The escape
# hatch CCO_ALLOW_HOST_RESOLVE=1 is for the test suite / a knowing developer
# only — real hooks/agents never set it, so the guard still protects them.
# NOTE: when a resolver is called via $(...), die() exits only that subshell;
# in genuine host use the guard never fires, and in tests the hatch bypasses it.
_cco_resolver_guard() {
    [[ "${CCO_ALLOW_HOST_RESOLVE:-}" == "1" ]] && return 0
    if _cco_in_container; then
        die "cco refuses to resolve host paths inside a container (anti-in-container guard, ADR-0007). cco runs host-side only; set CCO_ALLOW_HOST_RESOLVE=1 only for tests/dev."
    fi
}

# Echo the first argument that is a non-empty, absolute path; else return 1.
_cco_first_abs() {
    local c
    for c in "$@"; do
        [[ -n "$c" && "$c" == /* ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

# Create a bucket dir if missing, mode 0700, without disturbing existing perms.
_cco_ensure_dir() {
    local d="$1"
    [[ -d "$d" ]] && return 0
    ( umask 077; mkdir -p "$d" )
}

# CONFIG — ~/.cco (user-authored, git-versioned; deliberately not under XDG).
_cco_config_dir() {
    _cco_resolver_guard
    local base="$HOME/.cco"
    _cco_ensure_dir "$base"
    printf '%s\n' "$base"
}

# Global (user) Claude config home — ~/.cco/.claude (ADR-0028: flat under the
# config home, no `global/` wrapper). Single source of truth for the global
# `.claude` destination; replaces the retired GLOBAL_DIR / CCO_GLOBAL_DIR. Does
# NOT create `.claude` itself (only ~/.cco via _cco_config_dir), so callers and
# migration 015 can test its presence to decide fresh-seed vs migrate.
_cco_global_claude_dir() {
    printf '%s\n' "$(_cco_config_dir)/.claude"
}

# DATA — internal-but-synced (required, never-team).
_cco_data_dir() {
    _cco_resolver_guard
    local base
    base=$(_cco_first_abs \
        "${CCO_DATA_HOME:-}" \
        "${XDG_DATA_HOME:+${XDG_DATA_HOME%/}/cco}" \
        "$HOME/.local/share/cco")
    _cco_ensure_dir "$base"
    printf '%s\n' "$base"
}

# STATE — machine-local, non-portable (never-sync).
_cco_state_dir() {
    _cco_resolver_guard
    local base
    base=$(_cco_first_abs \
        "${CCO_STATE_HOME:-}" \
        "${XDG_STATE_HOME:+${XDG_STATE_HOME%/}/cco}" \
        "$HOME/.local/state/cco")
    _cco_ensure_dir "$base"
    printf '%s\n' "$base"
}

# CACHE — regenerable (never-sync).
_cco_cache_dir() {
    _cco_resolver_guard
    local base
    base=$(_cco_first_abs \
        "${CCO_CACHE_HOME:-}" \
        "${XDG_CACHE_HOME:+${XDG_CACHE_HOME%/}/cco}" \
        "$HOME/.cache/cco")
    _cco_ensure_dir "$base"
    printf '%s\n' "$base"
}
