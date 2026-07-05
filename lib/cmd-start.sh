#!/usr/bin/env bash
# lib/cmd-start.sh — Start project session command
#
# Provides: _setup_internal_tutorial(), cmd_start()
# Dependencies: colors.sh, utils.sh, yaml.sh, secrets.sh, session-context.sh, packs.sh, paths.sh
# Globals: IMAGE_NAME, REPO_ROOT (projects via the STATE index, P5). The internal
# tutorial/config-editor runtime lives in machine-local STATE via
# _cco_internal_runtime_dir() — NOT under the framework tree, which may be
# read-only on an npm install (ADR-0037 D5).

# ── Internal Tutorial Setup ──────────────────────────────────────────
# Prepares the runtime directory for the internal tutorial project.
# Content (.claude/, project.yml) is refreshed from internal/tutorial/ every start.
# Session transcripts/memory live in machine-local STATE (keyed by the internal
# project name, mounted via _cco_project_session_*), not in the runtime dir.
_setup_internal_tutorial() {
    local source_dir="$REPO_ROOT/internal/tutorial"
    local runtime_dir="$(_cco_internal_runtime_dir)/tutorial"

    [[ ! -d "$source_dir" ]] && die "Internal tutorial not found at $source_dir"

    # Ensure the runtime dir exists (content is refreshed below; session
    # transcripts/memory live in STATE, mounted via _cco_project_session_*).
    mkdir -p "$runtime_dir"

    # Always refresh content from framework source (ensures tutorial is current).
    # cp preserves the source mode; when cco is installed via npm the framework
    # tree is read-only, so both the stale copy (must be removable) and the fresh
    # copy (must stay writable in STATE) need their write bit restored (D5).
    [[ -e "$runtime_dir/.claude" ]] && chmod -R u+w "$runtime_dir/.claude" 2>/dev/null
    rm -rf "$runtime_dir/.claude"
    cp -r "$source_dir/.claude" "$runtime_dir/.claude" \
        || die "Failed to refresh tutorial content from $source_dir. Check permissions and disk space."
    chmod -R u+w "$runtime_dir/.claude"

    # Refresh project.yml with path substitution. CCO_CONFIG_DIR = the personal
    # store ~/.cco (read-only mount); CCO_USER_CONFIG_DIR is a back-compat alias
    # that now expands to the STATE-backed internal runtime root (no longer the
    # legacy vault — ADR-0037 D5). Unused by the shipped tutorial yml.
    sed -e "s|{{CCO_REPO_ROOT}}|$REPO_ROOT|g" \
        -e "s|{{CCO_CONFIG_DIR}}|$(_cco_config_dir)|g" \
        -e "s|{{CCO_USER_CONFIG_DIR}}|$runtime_dir|g" \
        "$source_dir/project.yml" > "$runtime_dir/project.yml" \
        || die "Failed to generate tutorial project.yml"

    # The tutorial's cco-docs/cco-config mounts are name-based (like config-editor):
    # publish the host paths via the in-process session override so they resolve at
    # start without polluting the persistent user-facing index (review H4), and no
    # host path is committed (AD3/G8). Read-only mounts (the tutorial never edits).
    _CCO_MOUNT_OVERRIDE=$(printf 'cco-config\t%s\ncco-docs\t%s' "$(_cco_config_dir)" "$REPO_ROOT/docs")

    # Copy setup.sh if present
    if [[ -f "$source_dir/setup.sh" ]]; then
        cp "$source_dir/setup.sh" "$runtime_dir/setup.sh"
    fi
}

# ── Internal config-editor setup (ADR-0027 D1) ───────────────────────
# Prepares the runtime dir for the config-editor built-in. Like the tutorial,
# its .claude/ content is refreshed from internal/config-editor/ every start.
# The project.yml is GENERATED here (not committed): it mounts the personal
# store ~/.cco rw (global mode) and, in project mode, the target project's
# <repo>/.cco rw. Host paths are injected here — a runtime artifact, never
# committed, so AD3/G8 hold by construction.
# Args: <targets> <repos>
#   targets = newline-joined "name<TAB><repo>/.cco" pairs (config mounts; may be empty)
#   repos   = newline-joined repo logical names to mount as full repos (may be empty;
#             ADR-0042 §8 — only under --project/--repo, resolved via the STATE index)
_setup_internal_config_editor() {
    local targets="$1"   # newline-joined "name<TAB><repo>/.cco" pairs (may be empty)
    local repos="${2:-}" # newline-joined repo logical names (may be empty)
    local source_dir="$REPO_ROOT/internal/config-editor"
    local runtime_dir="$(_cco_internal_runtime_dir)/config-editor"

    [[ ! -d "$source_dir" ]] && die "Internal config-editor not found at $source_dir"

    mkdir -p "$runtime_dir"

    # Always refresh content from framework source (ensures it is current). cp
    # preserves the source mode; on an npm install the framework tree is read-only,
    # so restore the write bit on the stale copy (so it can be removed) and the
    # fresh copy (so it stays writable in STATE) — D5.
    [[ -e "$runtime_dir/.claude" ]] && chmod -R u+w "$runtime_dir/.claude" 2>/dev/null
    rm -rf "$runtime_dir/.claude"
    cp -r "$source_dir/.claude" "$runtime_dir/.claude" \
        || die "Failed to refresh config-editor content from $source_dir."
    chmod -R u+w "$runtime_dir/.claude"
    [[ -f "$source_dir/setup.sh" ]] && cp "$source_dir/setup.sh" "$runtime_dir/setup.sh"

    # Generate project.yml: ~/.cco rw + docs ro (+ each target's .cco rw, from the
    # resolved --all/--project/cwd scope). The personal store is mounted read-write
    # — editing it is the whole purpose of this session.
    local cfg; cfg="$(_cco_config_dir)"
    # The mount bridge resolves names via the STATE index (name → host path), but
    # these are EPHEMERAL internal names — writing them into the persistent,
    # user-facing index pollutes it permanently and clobbers any user binding of the
    # same name (review H4). Publish them instead via the in-process session override
    # (_mount_override_get), which _effective_extra_mounts consults before the index.
    # The generated project.yml only references these names; they resolve via the
    # session override at start (never the persistent index), so no host path is
    # committed (AD3/G8).
    # cco-docs mounts $REPO_ROOT/docs at /workspace/cco-docs; doc refs read
    # cco-docs/users/... . The npm package ships ONLY docs/users (ADR-0037 D3
    # `files` allowlist), so an installed user sees only user docs; a dev clone
    # additionally exposes maintainer docs (read-only, harmless — agents are
    # instructed to read cco-docs/users/...).
    _CCO_MOUNT_OVERRIDE=$(printf 'cco-config\t%s\ncco-docs\t%s' "$cfg" "$REPO_ROOT/docs")
    local _tn _tp
    while IFS=$'\t' read -r _tn _tp; do
        [[ -z "$_tn" ]] && continue
        _CCO_MOUNT_OVERRIDE+=$(printf '\n%s-config\t%s' "$_tn" "$_tp")
    done <<< "$targets"
    {
        cat <<YAML
name: config-editor
description: "Configuration editor for claude-orchestrator"
YAML
        # Repos (ADR-0042 §8): only under --project/--repo. Each name resolves to
        # its host path via the STATE index in _effective_repo_mounts (no override
        # needed — these are real user repos). Emitted only when non-empty so the
        # broad default stays repo-free (P18).
        if [[ -n "$repos" ]]; then
            echo "repos:"
            local _rn
            while IFS= read -r _rn; do
                [[ -z "$_rn" ]] && continue
                echo "  - name: ${_rn}"
            done <<< "$repos"
        fi
        cat <<YAML
extra_mounts:
  - name: cco-config
    target: /workspace/cco-config
    readonly: false
  - name: cco-docs
    target: /workspace/cco-docs
    readonly: true
YAML
        while IFS=$'\t' read -r _tn _tp; do
            [[ -z "$_tn" ]] && continue
            cat <<YAML
  - name: ${_tn}-config
    target: /workspace/${_tn}-config
    readonly: false
YAML
        done <<< "$targets"
        cat <<YAML
docker:
  mount_socket: false
  ports: []
  env: {}
auth:
  method: oauth
YAML
    } > "$runtime_dir/project.yml" || die "Failed to generate config-editor project.yml"
}

# ── Access capability model (ADR-0036 D2/D3) ─────────────────────────
# The three orthogonal session knobs, resolved per session by precedence
# (most specific wins): CLI flag > project.yml `access:` block > global
# ~/.cco/access.yml > built-in preset default. Step 2 (this) only RESOLVES +
# validates; later steps consume the resolved values to drive Axis-B/Axis-A
# mount modes (step 3) and the wrapped-cco shim (step 4). The pure helpers below
# are side-effect-free so they can be unit-tested in isolation.

# Allowed enum values per editing knob (space-separated sets).
_ACCESS_CLAUDE_VALUES="none repo all"
# Symmetric read/edit scoping (ADR-0042): read mirrors edit —
# none · read-project · read-global · read-all · edit-project · edit-global · edit-all.
# The bare `read` of ADR-0036 is kept as a back-compat ALIAS (normalized to
# read-all in _start_resolve_access, since it meant "read everything") but is not
# a first-class enum value.
_ACCESS_CCO_VALUES="none read-project read-global read-all edit-project edit-global edit-all"

# True (0) when $2 is a member of the space-separated set $1.
_access_is_member() {
    local set="$1" v="$2" x
    for x in $set; do [[ "$x" == "$v" ]] && return 0; done
    return 1
}

# Normalize a boolean-ish token to `true`/`false`. Empty stays empty (so the
# precedence chain keeps falling through); an invalid token returns 1.
_access_norm_bool() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        "")             printf '' ;;
        true|on|1|yes)  printf 'true' ;;
        false|off|0|no) printf 'false' ;;
        *)              return 1 ;;
    esac
}

# Pick the first non-empty of cli/project/global/default (the precedence chain).
# Args: <cli> <project_val> <global_val> <default>.
_access_pick() {
    if   [[ -n "$1" ]]; then printf '%s' "$1"
    elif [[ -n "$2" ]]; then printf '%s' "$2"
    elif [[ -n "$3" ]]; then printf '%s' "$3"
    else                     printf '%s' "$4"
    fi
}

# Resolve the three knobs into cmd_start's locals (claude_access, cco_access,
# show_host_paths) by precedence, validating enums. Reads project.yml `access.*`
# and the global ~/.cco/access.yml; CLI overrides arrive via cli_claude_access /
# cli_cco_access / cli_show_host_paths (empty = unset). Step-2 preset defaults are
# the normal-session values (repo / none / on); step 5 layers the built-in
# tutorial/config-editor presets on top.
_start_resolve_access() {
    # Preset defaults (D6, revised by ADR-0042): normal = repo/read-project/on
    # (was cco=none — the read-project default is what makes the on-demand
    # three-level model work: the agent can query its own environment via wrapped
    # cco, so Level A stays minimal). Built-ins are presets — config-editor =
    # all/edit-all/on, tutorial = none/read-project/on (read-only teacher). These
    # become the level-4 default of the precedence chain.
    local _preset="${session_preset:-normal}"
    local d_claude="repo" d_cco="read-project" d_shp="true"
    case "$_preset" in
        config-editor) d_claude="all";  d_cco="edit-all";     d_shp="true" ;;
        tutorial)      d_claude="none"; d_cco="read-project"; d_shp="true" ;;
    esac

    # For a built-in the precedence collapses to CLI > preset: its generated
    # project.yml has no access: block, and the global ~/.cco/access.yml governs the
    # USER's own projects, not a framework built-in (so it must not, e.g., neuter
    # config-editor to none). A user can still narrow with an explicit --cco-access.
    # A normal session uses the full CLI > project.yml access: > global > preset.
    local p_claude="" p_cco="" p_shp="" g_claude="" g_cco="" g_shp=""
    if [[ "$_preset" == "normal" ]]; then
        # access.<key> is a 2-level block (2-space indent) → yml_get auto-depth 2
        # (NOT yml_get_deep, which forces depth 3 and would miss it).
        p_claude=$(yml_get "$project_yml" "access.claude" 2>/dev/null)
        p_cco=$(yml_get "$project_yml" "access.cco" 2>/dev/null)
        p_shp=$(yml_get "$project_yml" "access.show_host_paths" 2>/dev/null)
        local gfile; gfile=$(_cco_access_file)
        if [[ -f "$gfile" ]]; then
            g_claude=$(yml_get "$gfile" "claude" 2>/dev/null)
            g_cco=$(yml_get "$gfile" "cco" 2>/dev/null)
            g_shp=$(yml_get "$gfile" "show_host_paths" 2>/dev/null)
        fi
    fi

    claude_access=$(_access_pick "$cli_claude_access" "$p_claude" "$g_claude" "$d_claude")
    cco_access=$(_access_pick "$cli_cco_access" "$p_cco" "$g_cco" "$d_cco")
    # Back-compat (ADR-0042): bare `read` predates symmetric read scoping and meant
    # "read everything" — normalize it to read-all before validation so old
    # project.yml / access.yml / --cco-access values keep working.
    [[ "$cco_access" == "read" ]] && cco_access="read-all"
    _access_is_member "$_ACCESS_CLAUDE_VALUES" "$claude_access" \
        || die "Invalid claude_access '$claude_access' (expected one of: $_ACCESS_CLAUDE_VALUES). Set --claude-access, project.yml access.claude, or ~/.cco/access.yml."
    _access_is_member "$_ACCESS_CCO_VALUES" "$cco_access" \
        || die "Invalid cco_access '$cco_access' (expected one of: $_ACCESS_CCO_VALUES). Set --cco-access, project.yml access.cco, or ~/.cco/access.yml."

    local shp_raw shp_norm
    shp_raw=$(_access_pick "$cli_show_host_paths" "$p_shp" "$g_shp" "$d_shp")
    shp_norm=$(_access_norm_bool "$shp_raw") \
        || die "Invalid show_host_paths '$shp_raw' (expected: true|false / on|off)."
    show_host_paths="$shp_norm"

    [[ "${CCO_DEBUG:-}" == "1" ]] && \
        echo "[debug] access: claude=$claude_access cco=$cco_access show_host_paths=$show_host_paths" >&2
    return 0
}

# ── Secret-file masking (ADR-0036 D4) ────────────────────────────────
# Real secret files must never reach the container on ANY .cco mount — the
# capability matrix marks them "filtered" in every column, including a normal
# session (the values already flow in as env at launch, never by reading the
# file in-container). For each secret file under a mounted config tree we overlay
# an EMPTY read-only source at its container path; Docker applies the child mount
# after its parent, so the agent sees an empty file (real values gone) while the
# committed *.example skeletons stay visible + editable and real edits still reach
# the repo. Patterns: `secrets.env` and `*.env` / `*.key` / `*.pem`, excluding
# `*.example`. Args: <host_dir> <container_target_prefix> <empty_mask_source>.
# Emits _compose_vol lines to stdout (sorted, for deterministic compose output).
_emit_secret_overlays() {
    local hdir="$1" ctgt="$2" mask="$3" f rel
    [[ -d "$hdir" ]] || return 0
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        rel="${f#"$hdir"/}"
        _compose_vol "$mask" "$ctgt/$rel" "ro"
    done < <(find "$hdir" -type f \
                \( -name 'secrets.env' -o -name '*.env' -o -name '*.key' -o -name '*.pem' \) \
                ! -name '*.example' 2>/dev/null | sort)
}

# ── cmd_start() helper functions ─────────────────────────────────────
# These functions are called from within cmd_start() and share its local
# variable scope. They must NOT redeclare variables — they read/write
# cmd_start()'s locals directly.

# Add a repo logical name to the shared _ce_repos set (newline-joined, deduped).
_ce_add_repo() {
    local rn="$1"
    [[ -z "$rn" ]] && return 0
    [[ $'\n'"$_ce_repos" == *$'\n'"${rn}"$'\n'* ]] && return 0
    _ce_repos+="${rn}"$'\n'
}

# Collect the config-editor's edit targets + repo mounts (ADR-0042 §8, use-case
# redesign of ADR-0036 D-α). Sets the shared _ce_targets (newline-joined
# "name<TAB><repo>/.cco") and _ce_repos (newline-joined repo logical names).
#
#   BROAD (default: bare `config-editor`, or `--all` alias) → every resolvable
#     project's <repo>/.cco, NO repos. Broad config editing across all projects.
#   NARROW (`--project <name>`, repeatable) → only those projects' <repo>/.cco
#     PLUS each project's resolvable repos (repo-aware config authoring). Each
#     --project MUST resolve — dies otherwise.
#   `--repo <name>` (repeatable, any mode) adds one resolvable repo to the set.
#
# Repos are an EXPLICIT opt-in (P18 refined, not broken — design §8): the broad
# default mounts no code, only <repo>/.cco config. Shares cmd_start scope; reads
# config_editor_targets / config_editor_repos.
_start_collect_config_editor_targets() {
    _ce_targets=""
    _ce_repos=""
    local name path t rn rp
    if [[ ${#config_editor_targets[@]} -gt 0 ]]; then
        # NARROW: named projects' .cco + their repos (repo-aware authoring).
        for t in "${config_editor_targets[@]}"; do
            path=$(_resolve_unit_dir_for_project "$t") \
                || die "config-editor --project '$t' is not resolvable on this machine. Run 'cco resolve' first."
            [[ -d "$path/.cco" ]] || die "config-editor --project '$t' has no <repo>/.cco to edit."
            [[ "$_ce_targets" == *"${t}"$'\t'"${path}/.cco"$'\n'* ]] \
                || _ce_targets+="${t}"$'\t'"${path}/.cco"$'\n'
            # That project's repos — conscious-skip drops any unresolved member.
            while IFS=$'\t' read -r rn rp; do
                _ce_add_repo "$rn"
            done < <(_effective_repo_mounts "$path/.cco/project.yml")
        done
    else
        # BROAD (bare / --all): every resolvable project's <repo>/.cco, no repos.
        while IFS=$'\t' read -r name path _; do
            [[ -z "$name" ]] && continue
            [[ -d "$path/.cco" ]] || continue
            _ce_targets+="${name}"$'\t'"${path}/.cco"$'\n'
        done < <(_project_foreach)
    fi
    # --repo <name>: add a single resolvable repo (fine-grained reference mount).
    for t in ${config_editor_repos[@]+"${config_editor_repos[@]}"}; do
        path=$(_index_get_path "$t")
        [[ "$path" == /* && -d "$path" ]] \
            || die "config-editor --repo '$t' is not resolvable on this machine. Run 'cco resolve' first."
        _ce_add_repo "$t"
    done
}

# Resolves the project to its decentralized config source (design §4.4, ADR-0024
# D3): cco start reads <repo>/.cco/ — cwd-first when no name is given (the project
# the repo HOSTS, by its project.yml `name`), or by-name via the STATE index
# (projects: membership -> the first member hosting .cco/project.yml). The central
# $PROJECTS_DIR layout is gone (P3 breaking cutover, AD12 — no dual-read).
# Sets: project_dir (the .cco config dir), project_yml, claude_src (committed
#   claude config tree), source_repo (the host repo), source_kind, is_internal,
#   and fills `project` when resolved cwd-first.
_start_resolve_project() {
    is_internal=false
    source_kind="cwd"

    if [[ "$project" == "tutorial" ]]; then
        # "tutorial" is a reserved name — always launches the built-in tutorial
        # (an internal project, not part of the decentralized <repo>/.cco/ model).
        # Block if the user has a real project named "tutorial" in the index.
        if _resolve_unit_dir_for_project "tutorial" >/dev/null 2>&1; then
            echo ""
            error "'tutorial' is a reserved name for the built-in tutorial."
            echo ""
            echo "  You have a project named 'tutorial'. Rename it to use the built-in"
            echo "  tutorial (edit its .cco/project.yml 'name:' and run 'cco resolve')."
            echo ""
            die "Resolve the conflict and try again."
        fi
        is_internal=true
        session_preset="tutorial"          # preset: claude_access=none, cco_access=read (D6)
        _setup_internal_tutorial
        project_dir="$(_cco_internal_runtime_dir)/tutorial"
        project_yml="$project_dir/project.yml"
        claude_src="$project_dir/.claude"
        source_repo="$project_dir"
        # Secret-mask the personal store mounted for reading (~/.cco → cco-config).
        _op_config_masks+=("$(_cco_config_dir)"$'\t'"/workspace/cco-config")
    elif [[ "$project" == "config-editor" ]]; then
        # "config-editor" is a reserved name — launches the built-in config
        # editor (ADR-0027 D1). Block a real project claiming the name.
        if _resolve_unit_dir_for_project "config-editor" >/dev/null 2>&1; then
            echo ""
            error "'config-editor' is a reserved name for the built-in config editor."
            echo ""
            echo "  You have a project named 'config-editor'. Rename it (edit its"
            echo "  .cco/project.yml 'name:' and run 'cco resolve')."
            echo ""
            die "Resolve the conflict and try again."
        fi
        is_internal=true
        session_preset="config-editor"     # preset: claude_access=all, cco_access=edit-all (D6)
        # Target scope (ADR-0042 §8): BROAD by default (bare / --all → every
        # resolvable project's <repo>/.cco, no repos); NARROW under --project
        # (repeatable → those projects' .cco + their repos); --repo adds one repo.
        # The collector sets _ce_targets (newline name<TAB>cco_path) + _ce_repos
        # (newline repo names) directly via shared scope so its die() propagates
        # (bash 3.2 has no namerefs, and a $() subshell would swallow the die).
        local _ce_targets="" _ce_repos=""
        _start_collect_config_editor_targets
        _setup_internal_config_editor "$_ce_targets" "$_ce_repos"
        project_dir="$(_cco_internal_runtime_dir)/config-editor"
        project_yml="$project_dir/project.yml"
        claude_src="$project_dir/.claude"
        source_repo="$project_dir"
        # Secret-mask the personal store (~/.cco → cco-config) + each target .cco.
        _op_config_masks+=("$(_cco_config_dir)"$'\t'"/workspace/cco-config")
        local _ct _ctn _ctp
        while IFS=$'\t' read -r _ctn _ctp; do
            [[ -z "$_ctn" ]] && continue
            _op_config_masks+=("$_ctp"$'\t'"/workspace/${_ctn}-config")
        done <<< "$_ce_targets"
    else
        local unit_dir=""
        if [[ -n "$from_repo" ]]; then
            # --from <repo>: explicit Case-C source (mirrors `cco sync --from`).
            unit_dir=$(_index_get_path "$from_repo") \
                || die "source repo '$from_repo' is unresolved on this machine — run 'cco resolve' first."
            [[ -n "$unit_dir" ]] || die "source repo '$from_repo' is unresolved on this machine — run 'cco resolve' first."
            [[ -f "$unit_dir/.cco/project.yml" ]] \
                || die "source repo '$from_repo' has no .cco/project.yml — not a config-bearing member."
            source_kind="--from"
        elif [[ -n "$project" ]]; then
            # By-name: resolve the project's host via the index membership.
            unit_dir=$(_resolve_unit_dir_for_project "$project") \
                || die "Project '$project' is not in the index on this machine yet — its config can't be located. Run 'cco resolve --scan <dir>' to discover it, or start from inside its repo."
            source_kind="name"
        else
            # cwd-first: the project THIS repo hosts (AD6 / ADR-0024 D3).
            unit_dir=$(_resolve_find_unit_dir) \
                || die "No .cco/project.yml in the current directory or its parents. Name a project ('cco start <project>') or run from a configured repo."
            project=$(yml_get "$unit_dir/.cco/project.yml" name 2>/dev/null)
            source_kind="cwd"
        fi
        project_dir="$unit_dir/.cco"
        project_yml="$project_dir/project.yml"
        claude_src="$project_dir/claude"
        source_repo="$unit_dir"
        [[ -f "$project_yml" ]] || die "No .cco/project.yml found for '${project:-cwd}' (host repo: $unit_dir)."
    fi

    if ! $dry_run; then
        check_docker
        check_image
    fi
}

# Parses project.yml values and applies CLI overrides.
# Sets: project_name, auth_method, docker_image, mount_socket, network,
#       teammate_mode, browser_enabled, browser_mode, browser_cdp_port,
#       browser_effective_port, browser_mcp_args, github_enabled,
#       github_token_env, pack_names
_start_load_config() {
    # Parse project config
    project_name=$(yml_get "$project_yml" "name")
    [[ -z "$project_name" ]] && project_name="$project"

    # Validate project name (ADR-13: secure-by-default config parsing; the shared
    # single definition = Design Invariant 10, ADR-0031 D5). Previously start used
    # a looser [a-zA-Z0-9_-] regex than init's canonical lowercase-hyphen form —
    # unifying here also closes that latent inconsistency.
    if ! _cco_valid_project_name "$project_name"; then
        die "Invalid project name '${project_name}': must be lowercase letters, numbers, and hyphens, starting alphanumeric (no spaces or special characters)"
    fi
    if [[ ${#project_name} -gt 63 ]]; then
        die "Project name '${project_name}' is too long (${#project_name} chars, max 63)"
    fi

    # Check for existing running session — by the `cco.project` label (R1); the
    # `run --rm` launch discards `container_name`, so name matching never fired.
    if ! $dry_run && _cco_session_running "$project_name"; then
        die "Project '${project_name}' already has a running session. Run 'cco stop ${project}' first."
    fi

    auth_method=$(yml_get "$project_yml" "auth.method")
    [[ -z "$auth_method" ]] && auth_method="oauth"
    $use_api_key && auth_method="api_key"
    # Validate auth method
    if [[ "$auth_method" != "oauth" && "$auth_method" != "api_key" ]]; then
        warn "Invalid auth.method '${auth_method}' — defaulting to 'oauth'. Valid values: oauth, api_key"
        auth_method="oauth"
    fi

    docker_image=$(yml_get "$project_yml" "docker.image")
    [[ -z "$docker_image" ]] && docker_image="$IMAGE_NAME"

    mount_socket=$(_parse_bool "$(yml_get "$project_yml" "docker.mount_socket")" "false")
    # --no-docker: disable Docker socket for this session only
    [[ "$opt_docker" == "off" ]] && mount_socket="false"

    network=$(yml_get "$project_yml" "docker.network")
    [[ -z "$network" ]] && network="cc-${project_name}"

    [[ -z "$teammate_mode" ]] && teammate_mode="tmux"

    # ── Browser config ───────────────────────────────────────────────────
    browser_enabled=$(_parse_bool "$(yml_get "$project_yml" "browser.enabled")" "false")

    browser_mode=$(yml_get "$project_yml" "browser.mode")
    [[ -z "$browser_mode" ]] && browser_mode="host"

    # Session-level override: --chrome / --no-chrome take priority over project.yml
    [[ "$opt_chrome" == "on"  ]] && browser_enabled="true" && browser_mode="host"
    [[ "$opt_chrome" == "off" ]] && browser_enabled="false"

    browser_cdp_port=$(yml_get "$project_yml" "browser.cdp_port")
    [[ -z "$browser_cdp_port" ]] && browser_cdp_port="9222"
    # Validate: must be numeric and in valid port range
    if [[ ! "$browser_cdp_port" =~ ^[0-9]+$ ]] || [[ "$browser_cdp_port" -lt 1 ]] || [[ "$browser_cdp_port" -gt 65535 ]]; then
        die "Invalid browser.cdp_port '${browser_cdp_port}': must be a number between 1 and 65535"
    fi

    browser_mcp_args=$(yml_get_list "$project_yml" "browser.mcp_args")

    # Resolve effective port (auto-assign if preferred port is taken)
    browser_effective_port="$browser_cdp_port"
    if [[ "$browser_enabled" == "true" && "$browser_mode" == "host" ]]; then
        browser_effective_port=$(_resolve_browser_port "$browser_cdp_port" "$project_name")
    fi

    # ── GitHub config ─────────────────────────────────────────────────────
    github_enabled=$(_parse_bool "$(yml_get "$project_yml" "github.enabled")" "false")

    github_token_env=$(yml_get "$project_yml" "github.token_env")
    [[ -z "$github_token_env" ]] && github_token_env="GITHUB_TOKEN"

    # Session-level override: --github / --no-github take priority over project.yml
    [[ "$opt_github" == "on"  ]] && github_enabled="true"
    [[ "$opt_github" == "off" ]] && github_enabled="false"

    # Parse packs early (needed both for compose and session-context generation)
    pack_names=$(yml_get_packs "$project_yml")

    # Warn if no repos defined (some projects like tutorial work without repos).
    # Schema-agnostic via the bridge (legacy path:name or new logical names).
    local repos_check
    repos_check=$(_effective_repo_mounts "$project_yml")
    [[ -z "$repos_check" ]] && warn "No repositories defined in project.yml. Work inside the container will not persist unless saved via extra_mounts."

    # ── Per-machine bucket homes (decentralized config; design §2.2) ─────
    # CONFIG (~/.cco) = user-authored global config; STATE/CACHE = this
    # project's machine-local session state and regenerable overlays, keyed
    # by project identity (ADR-0005/0007/0015/0016). Resolved host-side only.
    config_dir=$(_cco_config_dir)
    session_state_dir="$(_cco_state_dir)/projects/$project_name"
    session_cache_dir="$(_cco_cache_dir)/projects/$project_name"
    return 0
}

# Startup health checks: schema version, merge conflicts, shadowed skills.
_start_check_health() {
    # Check for available updates
    local _global_meta; _global_meta=$(_cco_global_meta)
    if [[ -f "$_global_meta" ]]; then
        local _current_schema _latest_schema
        _current_schema=$(_read_cco_meta "$_global_meta")
        _latest_schema=$(_latest_schema_version "global")
        if [[ "$_current_schema" -lt "$_latest_schema" ]]; then
            info "Updates available. Run 'cco update' to apply."
        fi
    elif [[ -d "$config_dir/.claude" ]]; then
        info "Run 'cco update' to initialize the update system."
    fi

    # Check for unresolved merge conflicts in config files
    local _conflict_files=()
    local _check_dir _check_label
    for _check_dir in "$config_dir/.claude" "$claude_src"; do
        [[ ! -d "$_check_dir" ]] && continue
        if [[ "$_check_dir" == "$config_dir/.claude" ]]; then
            _check_label="global"
        else
            _check_label="project/$project"
        fi
        while IFS= read -r _cfile; do
            [[ -z "$_cfile" ]] && continue
            local _rel="${_cfile#$_check_dir/}"
            _conflict_files+=("$_check_label/.claude/$_rel")
        done < <(grep -rl '<<<<<<<' "$_check_dir" --include='*.md' --include='*.json' 2>/dev/null || true)
    done
    if [[ ${#_conflict_files[@]} -gt 0 ]]; then
        error "Unresolved merge conflicts in config files:"
        local _cf
        for _cf in "${_conflict_files[@]}"; do
            error "  - $_cf"
        done
        die "Resolve conflict markers before starting. Run 'cco update --sync' or edit the files manually."
    fi

    # Warn about managed skills that shadow user-level copies
    if [[ -d "$config_dir/.claude/skills/init-workspace" ]]; then
        warn "init-workspace skill found in user global (~/.cco/.claude/skills/init-workspace)."
        warn "This skill is now managed (enterprise-level) and the managed version takes precedence."
        warn "You can safely remove the user copy: rm -rf ~/.cco/.claude/skills/init-workspace"
    fi
}

# Prepares output directory and persistent state (skip side effects in dry-run).
# Sets: output_dir
_start_prepare_state() {
    # ── Dry-run: redirect generated files to a staging directory ─────────
    # Default dry-run: ephemeral temp dir, auto-cleaned on exit.
    # --dump: persist to .tmp/ for manual inspection.
    output_dir="$project_dir"
    if $dry_run; then
        if $dry_run_dump; then
            output_dir="$project_dir/.tmp"
            rm -rf "$output_dir"
        else
            output_dir=$(mktemp -d)
            # Embed the path in the trap body rather than referencing $output_dir:
            # the EXIT trap fires after cmd_start returns, when the function-local
            # output_dir is out of scope — under set -u a bare "$output_dir" there
            # is an unbound variable, so the trap both errors (cco start --dry-run
            # exits non-zero) AND skips cleanup (the temp dir leaks). Substituting
            # the value at registration makes cleanup robust and the exit clean.
            trap "rm -rf '$output_dir'" EXIT
        fi
        mkdir -p "$output_dir/.claude" "$output_dir/.cco/managed"
        # Dry-run inspects generated overlays under the dump dir.
        managed_gen_dir="$output_dir/.cco/managed"
        claude_gen_dir="$output_dir/.claude"
    else
        # Real start: generated overlays are regenerable → CACHE (keyed by id).
        # claude_gen_dir holds only the legacy-cleanup target now (ADR-0042: the
        # session-info surface is injected via env, no workspace.yml file).
        managed_gen_dir="$session_cache_dir/managed"
        claude_gen_dir="$session_cache_dir/.claude"
    fi

    # ── Persistent side effects: skip in dry-run ─────────────────────────
    if ! $dry_run; then
        # Auto-clean stale dry-run dump (starting implies approval)
        [[ -d "$project_dir/.tmp" ]] && rm -rf "$project_dir/.tmp"

        # Session transcripts + auto-memory are machine-local STATE, keyed by
        # project identity (ADR-0009): never committed, never in ~/.cco. The
        # /session partition is the future state-sync opt-in boundary (§2.2).
        mkdir -p "$(_cco_project_session_transcripts "$project_name")" \
                 "$(_cco_project_session_memory "$project_name")" \
                 "$managed_gen_dir" \
                 "$claude_gen_dir"

        # Claude Code native-install cache dirs (ADR-0039): pre-create so the
        # bind-mounts attach to directories (not auto-created files) and the
        # first-start installer has a writable target. CACHE bucket — re-fetchable
        # and untouched by `cco clean`; shared across all projects/sessions.
        local claude_install_dir; claude_install_dir=$(_cco_claude_install_dir)
        mkdir -p "$claude_install_dir/bin" "$claude_install_dir/share"

        # Global auth/session state, shared across all projects → STATE
        # top-level (machine-local, never synced; design §2.2 / ADR-0016).
        local state_root; state_root=$(_cco_state_dir)

        # ~/.claude.json — preferences, MCP servers, session metadata (NOT auth tokens)
        # Re-sync from host when host has been updated (higher numStartups = more recent).
        local global_claude_json="$state_root/claude.json"
        if [[ -f "$HOME/.claude.json" ]]; then
            if [[ ! -f "$global_claude_json" ]]; then
                cp "$HOME/.claude.json" "$global_claude_json"
            else
                local host_startups global_startups
                host_startups=$(jq -r '.numStartups // 0' "$HOME/.claude.json" 2>/dev/null | head -n 1)
                [[ ! "$host_startups" =~ ^[0-9]+$ ]] && host_startups=0
                global_startups=$(jq -r '.numStartups // 0' "$global_claude_json" 2>/dev/null | head -n 1)
                [[ ! "$global_startups" =~ ^[0-9]+$ ]] && global_startups=0
                if [[ "$host_startups" -gt "$global_startups" ]]; then
                    cp "$HOME/.claude.json" "$global_claude_json"
                fi
            fi
        elif [[ ! -f "$global_claude_json" ]]; then
            echo '{}' > "$global_claude_json"
        fi
        # Container must never show onboarding — force hasCompletedOnboarding after any sync/creation.
        # Host may have false after logout+login; container needs true to skip the "theme: dark" screen.
        local current_onboarding
        current_onboarding=$(jq -r '.hasCompletedOnboarding // false' "$global_claude_json" 2>/dev/null || echo "false")
        if [[ "$current_onboarding" != "true" ]]; then
            jq '.hasCompletedOnboarding = true' "$global_claude_json" > "$global_claude_json.tmp" \
                && mv "$global_claude_json.tmp" "$global_claude_json"
        fi

        # ~/.claude/.credentials.json — OAuth tokens (access + refresh)
        # On macOS, Claude stores tokens in Keychain. On Linux (container), it reads from
        # ~/.claude/.credentials.json in plaintext. We seed this file from the macOS Keychain
        # so the container can authenticate without manual login.
        local global_creds="$state_root/.credentials.json"
        if [[ "$(uname)" == "Darwin" ]] && [[ "$auth_method" == "oauth" ]]; then
            local keychain_json
            keychain_json=$(security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w 2>/dev/null) || true
            if [[ -n "$keychain_json" ]]; then
                local keychain_expires file_expires
                keychain_expires=$(echo "$keychain_json" | jq -r '.claudeAiOauth.expiresAt // 0' 2>/dev/null || echo 0)
                file_expires=$(jq -r '.claudeAiOauth.expiresAt // 0' "$global_creds" 2>/dev/null || echo 0)
                if [[ "$keychain_expires" -gt "$file_expires" ]]; then
                    echo "$keychain_json" > "$global_creds"
                    chmod 600 "$global_creds"
                    info "Seeded credentials from macOS Keychain (keychain token is newer)"
                fi
            fi
        fi
        # Ensure the file exists (even if empty) so Docker bind mount doesn't create a directory
        if [[ ! -f "$global_creds" ]]; then
            echo '{}' > "$global_creds"
            chmod 600 "$global_creds"
        fi
    fi
}

# Generates integration files: socket policy, browser MCP, GitHub MCP.
_start_generate_integrations() {
    # ── Docker socket policy ──────────────────────────────────────────────
    if [[ "$mount_socket" == "true" ]]; then
        _generate_socket_policy "$project_yml" "$project_name" "$managed_gen_dir"
    else
        if ! $dry_run; then
            rm -f "$managed_gen_dir/policy.json"
        fi
    fi

    # ── Generate .managed/ integrations (regenerable overlays → CACHE) ────
    if [[ "$browser_enabled" == "true" ]]; then
        mkdir -p "$managed_gen_dir"
        _generate_browser_mcp "$managed_gen_dir/browser.json" \
            "$browser_mode" "$browser_effective_port" "$browser_mcp_args"
        echo "$browser_effective_port" > "$managed_gen_dir/.browser-port"
    else
        if ! $dry_run; then
            # Clean up stale managed files from a previous session
            rm -f "$managed_gen_dir/browser.json" "$managed_gen_dir/.browser-port"
        fi
    fi

    if [[ "$github_enabled" == "true" ]]; then
        mkdir -p "$managed_gen_dir"
        _generate_github_mcp "$managed_gen_dir/github.json" "$github_token_env"
    else
        if ! $dry_run; then
            rm -f "$managed_gen_dir/github.json"
        fi
    fi

    # Detect pack resource name conflicts (warning only, before compose generation)
    if [[ -n "$pack_names" ]]; then
        _detect_pack_conflicts "$pack_names" "$project_dir"
    fi

    # Warn on cross-tree collisions between committed .claude config and the
    # framework-reserved overlay tree (ADR-0005 F2). Unconditional — reserved
    # packs//llms/ violations apply even with no packs configured.
    _detect_cross_tree_conflicts "$project_yml" "$pack_names" "$claude_src" "$project_dir"
}

# Resolves @local markers and legacy {{REPO_*}} in project.yml before
# compose generation. Delegates to the shared impl in local-paths.sh;
# the only start-specific concern is skipping the tutorial/internal
# project (which uses template-baked paths, nothing to resolve).
_start_resolve_paths() {
    unresolved_refs=0
    $is_internal && return 0
    # Single resolution entry point (ADR-0033 / S1 finding #7): start invokes the
    # SAME resolve surface as `cco resolve` — interactive heal of every referenced
    # repo/mount/llms/pack, never blocking (P14) — instead of a parallel inlined
    # loop. _resolve_unit takes the repo dir (parent of the .cco config dir).
    _resolve_unit "$(dirname "$project_dir")"
    # Conscious-skip model (design §4.4 / P14, ADR-0017 D2): _resolve_unit offered
    # [c]lone / [p]ath / [s]kip per unresolved member (TTY) and already warned each
    # member it could not resolve (skip / non-TTY). Here we only COUNT the residue
    # for the passive ⚠ badge — the mount-gen excludes empty-path entries, so a
    # skipped member is never a silent empty mount (#B17).
    local kind key effective status
    while IFS=$'\t' read -r kind key effective status; do
        [[ -z "$kind" ]] && continue
        [[ "$status" == "exists" ]] && continue
        unresolved_refs=$((unresolved_refs + 1))
    done < <(_project_effective_paths "$project_dir")
}

# Emit the non-blocking config reminder aggregator (ADR-0008) for this project's
# RESOLVED member repos. Invariant H1: this runs ONLY after _start_resolve_paths,
# so the index is populated — reminders are never computed against an empty/
# unresolved index. Silent when members carry no <repo>/.cco/ (the pre-P2
# central layout). The remaining cco start source-selection wiring (§4.4:
# --from, Case-C precedence, the divergence notice, the source-transparency
# line + passive ⚠ badge) lands in P2, built once against the decentralized
# layout. Always non-blocking (P14).
_start_emit_reminders() {
    $is_internal && return 0
    local -a roots=()
    local _name _path
    while IFS=$'\t' read -r _name _path; do
        [[ -z "$_path" ]] && continue
        roots+=("$_path")
    done < <(_effective_repo_mounts "$project_yml" 2>/dev/null)
    [[ ${#roots[@]} -eq 0 ]] && return 0
    _emit_config_reminders "${roots[@]}"
    return 0
}

# Generates the docker-compose.yml file from project configuration.
# Sets: compose_file
_start_generate_compose() {
    # ── Generate docker-compose.yml ──────────────────────────────────
    # Real start writes the compose into STATE (machine-local, keyed by id;
    # design §2.2 BL3). Dry-run dumps it under the inspection dir. Every
    # framework mount source below is host-absolute (config/state/cache roots
    # now diverge, so a single --project-directory can no longer anchor them).
    local state_root global_claude
    state_root=$(_cco_state_dir)
    global_claude="$config_dir/.claude"   # flat global home (ADR-0028)
    if $dry_run; then
        mkdir -p "$output_dir/.cco"
        compose_file="$output_dir/.cco/docker-compose.yml"
    else
        mkdir -p "$session_state_dir"
        compose_file="$session_state_dir/docker-compose.yml"
    fi

    # Empty read-only source used to mask real secret files out of every .cco
    # mount (ADR-0036 D4 — see _emit_secret_overlays). One host-side empty file,
    # bind-mounted :ro over each secret path so the agent never sees real values.
    local secret_mask
    if $dry_run; then secret_mask="$output_dir/.cco/.secret-mask"
    else secret_mask="$session_cache_dir/.secret-mask"; fi
    mkdir -p "$(dirname "$secret_mask")"; : > "$secret_mask"

    {
        cat <<YAML
# AUTO-GENERATED by cco CLI from project.yml
# Manual edits will be overwritten on next \`cco start\`
# To customize, edit project.yml instead

services:
  claude:
    image: ${docker_image}
    container_name: cc-${project_name}
    labels:
      cco.project: "${project_name}"
    stdin_open: true
    tty: true
    environment:
      - PROJECT_NAME=${project_name}
      - TEAMMATE_MODE=${teammate_mode}
      - CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
YAML

        # Level-A session context (ADR-0042): the SessionStart / SubagentStart
        # hooks decode these and emit them as additionalContext. base64 keeps the
        # multi-line block a single safe compose value (INV-1: session-fixed info,
        # INV-2: no file). Emitted only when non-empty (subagent block is optional).
        [[ -n "$session_context_b64" ]]  && echo "      - CCO_SESSION_CONTEXT=${session_context_b64}"
        [[ -n "$subagent_context_b64" ]] && echo "      - CCO_SUBAGENT_CONTEXT=${subagent_context_b64}"

        # Claude Code channel/version (native install — ADR-0039). Forward the
        # `~/.cco/claude-version` config-knob preference WHEN SET. When the knob is
        # absent we deliberately do NOT emit this, so the container falls back to
        # the image's baked CLAUDE_CODE_VERSION default (`latest`, or whatever
        # `cco build --claude-version X` pinned). This lets the build flag re-pin a
        # knob-less install, while an explicit knob (stable / a pinned x.y.z)
        # outranks the build default. The entrypoint forwards it to install.sh.
        if [[ -f "$(_cco_claude_version_file)" ]]; then
            echo "      - CLAUDE_CODE_VERSION=$(_cco_claude_version_pref)"
        fi

        # Extra env from project.yml
        while IFS= read -r env_line; do
            [[ -z "$env_line" ]] && continue
            local env_key="${env_line%%:*}"
            local env_val="${env_line#*: }"
            echo "      - ${env_key}=${env_val}"
        done <<< "$(yml_get_env "$project_yml")"

        # Extra env from CLI
        for env in "${extra_envs[@]+"${extra_envs[@]}"}"; do
            echo "      - ${env}"
        done

        # Forward debug mode to container
        if [[ "${CCO_DEBUG:-}" == "1" ]]; then
            echo "      - CCO_DEBUG=1"
        fi

        # Access scopes derived ONCE from the resolved cco_access (ADR-0043
        # symmetric model; access-scope.sh is the single source, INV-E). read_scope
        # drives read-mount narrowing (project → only referenced packs); write_scope
        # drives the per-tree RW upgrades. Read/write symmetric: edit-project reads
        # at project scope (narrowed), NOT the whole store.
        local _read_scope _write_scope
        _read_scope=$(_cco_level_read_scope "$cco_access")
        _write_scope=$(_cco_level_write_scope "$cco_access")

        # Container-operator mode (ADR-0036 D4): under cco_access >= read, the
        # in-container cco runs behind the whitelist shim, operating on the real
        # buckets bind-mounted below (never the container's own $HOME). The flag +
        # the three CCO_*_HOME overrides together are what _cco_container_operator
        # keys on; CCO_CCO_ACCESS tells the shim which write verbs to allow. CONFIG
        # (~/.cco) needs no override — it is mounted at the natural $HOME/.cco.
        if [[ "$cco_access" != "none" ]]; then
            echo "      - CCO_CONTAINER_OPERATOR=1"
            echo "      - CCO_CCO_ACCESS=${cco_access}"
            echo "      - CCO_DATA_HOME=/home/claude/.local/share/cco"
            echo "      - CCO_STATE_HOME=/home/claude/.local/state/cco"
            echo "      - CCO_CACHE_HOME=/home/claude/.cache/cco"
            # Project-scope membership signals (ADR-0043): the packs and llms this
            # project references, comma-joined, so the in-container access-scope
            # layer (lib/access-scope.sh) can scope read-verb OUTPUT to the current
            # project at read-project. Computed ONCE here host-side (INV-E single
            # source): pack list from project.yml; llms = project.yml ∪ each
            # referenced pack's llms. Harmless at read-global+ (the layer ignores
            # them there). Names are slugs (no commas), so a CSV value is safe.
            local _op_packs_csv _op_llms_csv _op_ln _op_pk _op_pkdir
            _op_packs_csv=$(printf '%s\n' "$pack_names" | awk 'NF{printf "%s%s",(n++?",":""),$0}')
            _op_llms_csv=$({
                yml_get_llms_names "$project_yml" 2>/dev/null
                if [[ -n "$pack_names" ]]; then
                    while IFS= read -r _op_pk; do
                        [[ -z "$_op_pk" ]] && continue
                        _op_pkdir=$(_pack_resolve_dir "$_op_pk" "$project_dir" 2>/dev/null) || continue
                        [[ -f "$_op_pkdir/pack.yml" ]] && yml_get_llms_names "$_op_pkdir/pack.yml" 2>/dev/null
                    done <<< "$pack_names"
                fi
            } | awk 'NF && !seen[$0]++{printf "%s%s",(n++?",":""),$0}')
            [[ -n "$_op_packs_csv" ]] && echo "      - CCO_PROJECT_PACKS=${_op_packs_csv}"
            [[ -n "$_op_llms_csv" ]]  && echo "      - CCO_PROJECT_LLMS=${_op_llms_csv}"
        fi

        # Docker socket proxy: advertise proxy socket to all processes in container
        if [[ "$mount_socket" == "true" ]]; then
            echo "      - DOCKER_HOST=unix:///var/run/docker-proxy.sock"
        fi

        # CDP proxy port for entrypoint socat (Chrome 145+ Host header fix)
        if [[ "$browser_enabled" == "true" && "$browser_mode" == "host" ]]; then
            echo "      - CDP_PORT=${browser_effective_port}"
        fi

        # API key auth
        if [[ "$auth_method" == "api_key" ]]; then
            echo "      - ANTHROPIC_API_KEY=\${ANTHROPIC_API_KEY}"
        fi

        echo "    volumes:"

        # ── Axis-B (.claude authoring) + Axis-A (.cco wiring) mount modes ──
        # Driven by the resolved capability knobs (ADR-0036 D2, generalizing
        # ADR-0027 D3's edit-protection). claude_access governs the .claude trees
        # (B1 <repo>/.claude cross-cutting, B2 project /workspace/.claude, B3 global
        # ~/.cco/.claude); cco_access governs the <repo>/.cco structural overlay
        # (A1). The host IDE is unaffected (container-only).
        #
        # Axis B (claude_access): none = all .claude ro (B1 overlaid ro, B2 ro,
        # B3 authoring ro); repo (default) = B1+B2 rw, B3 authoring ro; all =
        # B1+B2 rw + B3 authoring rw. settings.json is ALWAYS rw (Claude Code writes
        # runtime prefs like /effort — a functional need, not authoring).
        local _b2_mode="" _b3_auth_mode="ro" _b1_ro=""
        case "$claude_access" in
            none) _b2_mode="ro"; _b1_ro=":ro" ;;
            all)  _b3_auth_mode="" ;;
            repo) : ;;   # defaults: B2 rw, B3 authoring ro, B1 rw (no overlay)
        esac
        # Axis A (write_scope): the committed <repo>/.cco structural config
        # (project.yml, secrets.env, .cco metadata) is overlaid READ-ONLY unless the
        # session's write_scope grants the project tree (edit-project / edit-all).
        # edit-global keeps A1 ro — only the personal store (A2) is writable there.
        # Keyed off write_scope now (ADR-0043) so the overlay and the operator-bucket
        # RW below share one source. config-editor resolves to edit-all via its
        # preset (its edit targets mount via generated extra_mounts, not this loop).
        local _committed_ro=":ro"
        if [[ "$_write_scope" == "project" || "$_write_scope" == "all" ]]; then
            _committed_ro=""
        fi

        # ~/.claude.json — preferences, MCP servers, session metadata (machine-local STATE)
        _compose_vol "${state_root}/claude.json" "/home/claude/.claude.json"
        # ~/.claude/.credentials.json — OAuth tokens (machine-local STATE, never synced)
        _compose_vol "${state_root}/.credentials.json" "/home/claude/.claude/.credentials.json"

        # Claude Code native install (ADR-0039): persistent bind-mount of the
        # binary + its state (host CACHE) into ~/.local. rw — the entrypoint's
        # first-start installer and the in-place auto-updater both write here, so
        # the binary survives restarts and updates without a `cco build`.
        local claude_install; claude_install=$(_cco_claude_install_dir)
        echo "      # Claude Code native install (binary + state, auto-updates in place — ADR-0039)"
        _compose_vol "${claude_install}/bin" "/home/claude/.local/bin"
        _compose_vol "${claude_install}/share" "/home/claude/.local/share/claude"

        # Global config B3 (~/.cco/.claude). settings.json is always rw (runtime
        # prefs); the authoring tree (CLAUDE.md/rules/agents/skills) is rw only under
        # claude_access=all, ro otherwise (_b3_auth_mode, ADR-0036 D2).
        echo "      # Global config B3 (settings.json always rw; authoring tree mode from claude_access)"
        _compose_vol "${global_claude}/settings.json" "/home/claude/.claude/settings.json"
        _compose_vol "${global_claude}/CLAUDE.md" "/home/claude/.claude/CLAUDE.md" "${_b3_auth_mode}"
        _compose_vol "${global_claude}/rules" "/home/claude/.claude/rules" "${_b3_auth_mode}"
        _compose_vol "${global_claude}/agents" "/home/claude/.claude/agents" "${_b3_auth_mode}"
        _compose_vol "${global_claude}/skills" "/home/claude/.claude/skills" "${_b3_auth_mode}"
        # Project config B2 (/workspace/.claude). Mode from claude_access
        # (_b2_mode: rw under repo/all for /init authoring per P17, ro under none);
        # the structural framework config (project.yml/secrets/.cco metadata) is
        # protected separately by the <repo>/.cco overlay below (Axis A, cco_access).
        echo "      # Project config B2 (/workspace/.claude — mode from claude_access; .cco metadata overlay below per cco_access)"
        _compose_vol "${claude_src}" "/workspace/.claude" "${_b2_mode}"
        _compose_vol "${project_dir}/project.yml" "/workspace/project.yml" "ro"
        # Claude state: session transcripts (machine-local STATE; enables /resume across rebuilds)
        echo "      # Claude state: session transcripts (machine-local STATE; /resume across rebuilds)"
        _compose_vol "$(_cco_project_session_transcripts "$project_name")" "/home/claude/.claude/projects/-workspace"
        # Memory: auto memory files (machine-local STATE, separate from transcripts)
        echo "      # Memory: auto memory files (machine-local STATE, separate from transcripts)"
        _compose_vol "$(_cco_project_session_memory "$project_name")" "/home/claude/.claude/projects/-workspace/memory"

        # ── Container-operator buckets (wrapped-cco — ADR-0036 D4, ships R2) ──
        # Under cco_access >= read, bind-mount the real buckets so the in-container
        # cco (behind the whitelist shim) operates on them, never the container's
        # own $HOME. A2 `~/.cco` structural (incl. packs/templates) + DATA + CACHE
        # follow the edit level (rw under edit-global/edit-all, ro otherwise); STATE
        # is the INDEX FILE ONLY, ro — transcripts, memory, and the 0600
        # remotes-token stay off the container (secrets host-only). CONFIG resolves
        # to the natural $HOME/.cco (no override). Real secret files in ~/.cco are
        # masked below. Built-in presets (config-editor/tutorial) layer on this in
        # step 5; a normal session opts in via --cco-access read|edit-*.
        #
        # Project-scope mount narrowing (ADR-0042 §8 + ADR-0043): when read_scope ==
        # project (read-project AND edit-project — symmetric), the CONFIG bucket is
        # NOT mounted whole — only this project's referenced personal-store packs are
        # exposed (ro), so `~/.cco/templates` and other projects'/unreferenced packs
        # stay physically hidden, matching the "project-scoped" risk profile (the
        # shim gates template/remote verbs behind read-global+). read-global/read-all
        # and edit-global/edit-all mount the whole store. DATA/STATE-index/CACHE are
        # unchanged (needed for `cco list`; carry no templates or other-project pack
        # content). RW follows write_scope (global/all → rw), independent of the read
        # narrowing: edit-project narrows the READ mount yet its project-config edits
        # ride the <repo>/.cco overlay (rw) above, not the personal store.
        if [[ "$cco_access" != "none" ]]; then
            local _op_rw="ro"
            case "$_write_scope" in global|all) _op_rw="" ;; esac
            echo "      # Container-operator buckets (wrapped-cco — ADR-0036 D4)"
            if [[ "$_read_scope" == "project" ]]; then
                # Narrowed CONFIG: only referenced personal-store packs (ro).
                local _rp_pack _rp_dir
                if [[ -n "$pack_names" ]]; then
                    while IFS= read -r _rp_pack; do
                        [[ -z "$_rp_pack" ]] && continue
                        # Personal store only ($PACKS_DIR/<name>); project-local packs
                        # come via the repo mount, not the operator bucket.
                        _rp_dir=$(_pack_resolve_dir "$_rp_pack")
                        [[ -z "$_rp_dir" ]] && continue
                        # Skip packs the framework treats as invalid (mirrors
                        # _session_collect_knowledge) — a malformed pack.yml never
                        # reaches any session mount.
                        [[ -f "$_rp_dir/pack.yml" ]] || continue
                        grep -qE '^(name|knowledge|llms|skills|agents|rules):' "$_rp_dir/pack.yml" || continue
                        _compose_vol "$_rp_dir" "/home/claude/.cco/packs/${_rp_pack}" "ro"
                        _emit_secret_overlays "$_rp_dir" "/home/claude/.cco/packs/${_rp_pack}" "$secret_mask"
                    done <<< "$pack_names"
                fi
            else
                # CONFIG A2 (~/.cco: packs/templates/global config + git for config save)
                _compose_vol "$config_dir" "/home/claude/.cco" "$_op_rw"
                _emit_secret_overlays "$config_dir" "/home/claude/.cco" "$secret_mask"
                # B3 (~/.cco/.claude global authoring) is governed by claude_access, NOT
                # the A2 edit level. When A2 is rw but global authoring is not
                # (claude_access != all → _b3_auth_mode=ro), re-overlay .claude :ro under
                # the A2 path so edit-global/edit-all cannot edit global .claude through
                # it — the two axes stay separate (ADR-0036 D2). Child mount wins.
                if [[ -z "$_op_rw" && "$_b3_auth_mode" == "ro" && -d "$config_dir/.claude" ]]; then
                    _compose_vol "$config_dir/.claude" "/home/claude/.cco/.claude" "ro"
                fi
            fi
            # DATA registries (tags/remotes/source) — remotes-token is in STATE, excluded
            local _op_data; _op_data=$(_cco_data_dir)
            [[ -d "$_op_data" ]] && _compose_vol "$_op_data" "/home/claude/.local/share/cco" "$_op_rw"
            # STATE index only, ro (logical→host map for `cco list`); guard on existence
            [[ -f "${state_root}/index" ]] && \
                _compose_vol "${state_root}/index" "/home/claude/.local/state/cco/index" "ro"
            # CACHE llms (listing/install) — mode follows the edit level
            local _op_llms; _op_llms=$(_cco_llms_dir)
            [[ -d "$_op_llms" ]] && _compose_vol "$_op_llms" "/home/claude/.cache/cco/llms" "$_op_rw"
        fi

        # (ADR-0042) No generated session-info overlay is mounted anymore. The
        # former workspace.yml :ro overlay is retired — Level A context is injected
        # via the CCO_SESSION_CONTEXT env var (see the environment block above).

        # Global MCP config (merged into ~/.claude.json by entrypoint)
        if [[ -f "$global_claude/mcp.json" ]]; then
            echo "      # Global MCP servers"
            _compose_vol "${global_claude}/mcp.json" "/home/claude/.claude/mcp-global.json" "ro"
        fi

        # Project MCP config (Claude Code expands ${VAR} natively)
        if [[ -f "$project_dir/mcp.json" ]]; then
            echo "      # Project MCP servers"
            _compose_vol "${project_dir}/mcp.json" "/workspace/.mcp.json" "ro"
        fi

        # Global runtime setup script (executed by entrypoint before project setup)
        if [[ -f "$config_dir/setup.sh" ]]; then
            echo "      # Global runtime setup"
            _compose_vol "${config_dir}/setup.sh" "/home/claude/global-setup.sh" "ro"
        fi

        # Project setup script (runtime, executed by entrypoint)
        if [[ -f "$project_dir/setup.sh" ]]; then
            echo "      # Project setup script"
            _compose_vol "${project_dir}/setup.sh" "/workspace/setup.sh" "ro"
        fi

        # Project MCP packages (runtime, installed by entrypoint)
        if [[ -f "$project_dir/mcp-packages.txt" ]]; then
            echo "      # Project MCP packages"
            _compose_vol "${project_dir}/mcp-packages.txt" "/workspace/mcp-packages.txt" "ro"
        fi

        # Managed integrations (framework-generated overlays → CACHE, :ro)
        if [[ -d "$managed_gen_dir" ]] && [[ -n "$(ls -A "$managed_gen_dir" 2>/dev/null)" ]]; then
            echo "      # Managed integrations"
            _compose_vol "${session_cache_dir}/managed" "/workspace/.managed" "ro"
        fi

        # Repository mounts. Unresolved references were already dropped upstream
        # by the P14 conscious-skip in _effective_repo_mounts (warn + exclude,
        # never a silent empty bind-mount, #B17), so every path here is a real,
        # existing filesystem path.
        echo "      # Repositories"
        while IFS=$'\t' read -r repo_name repo_path; do
            [[ -z "$repo_name" ]] && continue
            _compose_vol "${repo_path}" "/workspace/${repo_name}"
        done < <(_effective_repo_mounts "$project_yml")

        # Axis-B1 lockdown (claude_access=none): overlay each repo's native
        # <repo>/.claude :ro on top of the rw repo mount, so cross-cutting authoring
        # config is read-only too (advanced security — ADR-0036 D2). No overlay under
        # repo/all, where B1 stays rw as part of the repo mount.
        if [[ -n "$_b1_ro" ]]; then
            while IFS=$'\t' read -r repo_name repo_path; do
                [[ -z "$repo_name" ]] && continue
                [[ -d "$repo_path/.claude" ]] && \
                    _compose_vol "${repo_path}/.claude" "/workspace/${repo_name}/.claude" "ro"
            done < <(_effective_repo_mounts "$project_yml")
        fi

        # Axis-A1 edit-protection (ADR-0036 D2, generalizing ADR-0027 D3): overlay
        # each repo's committed .cco :ro on top of the rw repo mount (Docker applies
        # child mounts after the parent), so the agent cannot mutate the structural
        # framework config (project.yml, secrets.env, internal metadata) via the code
        # repo. The project's Claude config (.cco/claude) is still authored through
        # the B2 overlay above. Skipped when cco_access grants project edit
        # (edit-project/edit-all) or for built-ins (_committed_ro="").
        if [[ -n "$_committed_ro" ]]; then
            while IFS=$'\t' read -r repo_name repo_path; do
                [[ -z "$repo_name" ]] && continue
                [[ -d "$repo_path/.cco" ]] && \
                    _compose_vol "${repo_path}/.cco" "/workspace/${repo_name}/.cco" "ro"
            done < <(_effective_repo_mounts "$project_yml")
        fi

        # Secret-file masking (ADR-0036 D4): hide real secret files in EVERY repo's
        # committed .cco — whether it is exposed via the rw repo mount (edit modes /
        # built-ins) or the :ro overlay above (normal). The empty :ro overlay is a
        # deeper child mount, so it wins regardless of the .cco mount's own mode; the
        # committed *.example skeletons stay visible. Applies to all sessions (the
        # capability matrix filters secrets in every column).
        while IFS=$'\t' read -r repo_name repo_path; do
            [[ -z "$repo_name" ]] && continue
            _emit_secret_overlays "$repo_path/.cco" "/workspace/${repo_name}/.cco" "$secret_mask"
        done < <(_effective_repo_mounts "$project_yml")

        # Built-in config-mount secret masking (ADR-0036 D4): the config-editor /
        # tutorial presets surface config trees (~/.cco → cco-config, each target
        # <repo>/.cco → <name>-config) via generated extra_mounts, which the repo
        # loop above does NOT cover. Mask real secret files there too, so neither
        # the personal store nor any --all/--project target ever exposes real
        # values — only *.example. Pairs collected by the built-in branches (5b).
        local _cm _cm_host _cm_tgt
        for _cm in ${_op_config_masks[@]+"${_op_config_masks[@]}"}; do
            _cm_host="${_cm%%$'\t'*}"; _cm_tgt="${_cm#*$'\t'}"
            _emit_secret_overlays "$_cm_host" "$_cm_tgt" "$secret_mask"
        done

        # Extra mounts (same invariant as repos — resolved + existence
        # asserted upstream). The bridge emits abs_source<TAB>target<TAB>ro.
        local extra_mounts
        extra_mounts=$(_effective_extra_mounts "$project_yml")
        if [[ -n "$extra_mounts" ]]; then
            echo "      # Extra mounts"
            local _ms _mt _mro _suffix
            while IFS=$'\t' read -r _ms _mt _mro; do
                [[ -z "$_ms" ]] && continue
                _suffix=""
                [[ "$_mro" == "true" ]] && _suffix="ro"
                _compose_vol "$_ms" "$_mt" "$_suffix"
            done <<< "$extra_mounts"
        fi

        # Session reference mounts (--mount, ADR-0027 D2): read-only by default,
        # :rw opt-in. Pre-resolved to abs_src<TAB>target<TAB>ro above.
        if [[ ${#user_mount_lines[@]} -gt 0 ]]; then
            echo "      # Reference mounts (--mount)"
            local _uline _us _ut _uro _usuffix
            for _uline in "${user_mount_lines[@]}"; do
                IFS=$'\t' read -r _us _ut _uro <<< "$_uline"
                _usuffix=""
                [[ "$_uro" == "true" ]] && _usuffix="ro"
                _compose_vol "$_us" "$_ut" "$_usuffix"
            done
        fi

        # Pack resources: read-only mounts from central pack registry (ADR-14)
        _generate_pack_mounts "$pack_names" "$project_dir"

        # LLMs.txt documentation: read-only mounts from central llms registry
        _generate_llms_mounts "$project_yml" "$pack_names" "$project_dir"

        # Git identity (commit author — read-only, no SSH keys)
        echo "      # Git identity"
        _compose_vol "\${HOME}/.gitconfig" "/home/claude/.gitconfig" "ro"

        # Docker socket (opt-in via docker.mount_socket: true)
        if [[ "$mount_socket" == "true" ]]; then
            echo "      # Docker socket"
            _compose_vol "/var/run/docker.sock" "/var/run/docker.sock"
            # Policy file for socket proxy (if generated)
            if [[ -f "$managed_gen_dir/policy.json" ]]; then
                _compose_vol "${session_cache_dir}/managed/policy.json" "/etc/cco/policy.json" "ro"
            fi
        fi

        # Ports
        local all_ports=()
        while IFS= read -r port; do
            [[ -z "$port" ]] && continue
            all_ports+=("$port")
        done <<< "$(yml_get_ports "$project_yml")"
        for port in "${extra_ports[@]+"${extra_ports[@]}"}"; do
            all_ports+=("$port")
        done

        if [[ ${#all_ports[@]} -gt 0 ]]; then
            echo "    ports:"
            for port in "${all_ports[@]}"; do
                echo "      - \"${port}\""
            done
        fi

        # extra_hosts (browser host mode — resolves host.docker.internal on Linux)
        if [[ "$browser_enabled" == "true" && "$browser_mode" == "host" ]]; then
            echo "    extra_hosts:"
            echo '      - "host.docker.internal:host-gateway"'
        fi

        # Network (must be the last service-level section)
        cat <<YAML
    networks:
      - ${network}
    working_dir: /workspace

networks:
  ${network}:
    name: ${network}
    driver: bridge
YAML
    } > "$compose_file"
}

# Computes the Level-A session context (ADR-0042) and stashes it, base64-encoded,
# into session_context_b64 / subagent_context_b64 for _start_generate_compose to
# inject as CCO_SESSION_CONTEXT / CCO_SUBAGENT_CONTEXT env vars. NO file is
# written anywhere (INV-2): the retired workspace.yml generator is gone; the
# context is delivered as injected text the user never sees, edits, or commits.
# See lib/session-context.sh.
_start_generate_metadata() {
    # The project's committed CLAUDE.md drives the init-workspace nudge (design
    # §7): its absence/emptiness degrades only the rich narrative, never Level A.
    local _claude_md_present="true"
    if [[ ! -s "$claude_src/CLAUDE.md" ]]; then _claude_md_present="false"; fi

    local _ctx _subctx
    _ctx=$(_build_session_context "$project_name" "$project_yml" "$pack_names" \
        "$project_dir" "$show_host_paths" "$cco_access" "$_claude_md_present")
    _subctx=$(_build_subagent_context "$project_yml" "$pack_names" "$project_dir")
    # base64 (single line) sidesteps all compose-YAML newline/quoting concerns;
    # the hooks decode it back to text. tr -d '\n' guards against wrapping.
    session_context_b64=$(printf '%s' "$_ctx"    | base64 | tr -d '\n')
    subagent_context_b64=$(printf '%s' "$_subctx" | base64 | tr -d '\n')

    # Net cut: no generated session-info file is emitted anymore. Remove any stale
    # workspace.yml / packs.md a pre-ADR-0042 session may have left in the overlay
    # dir (idempotent; the committed-tree cleanup is handled by migration 014).
    rm -f "$claude_gen_dir/workspace.yml" "$claude_gen_dir/packs.md"

    # One-shot cleanup of legacy copied pack files (pre-ADR-14) — skip in dry-run
    if ! $dry_run; then
        _clean_pack_manifest "$project_dir"
    fi
}

# Displays the dry-run summary.
_start_show_summary() {
    # ── Structured dry-run summary ───────────────────────────────────
    echo ""
    info "${BOLD}Dry-run summary for '${project_name}'${NC}"
    echo ""
    info "  Image:          ${docker_image}"
    info "  Auth:           ${auth_method}"
    info "  Access:         claude=${claude_access} cco=${cco_access} host-paths=${show_host_paths}"
    info "  Teammate mode:  ${teammate_mode}"
    info "  Network:        ${network}"
    info "  Docker socket:  ${mount_socket}"
    if [[ "$mount_socket" == "true" ]]; then
        local _pol="project_only"
        _pol=$(yml_get_deep "$project_yml" "docker.containers.policy") || true
        [[ -z "$_pol" ]] && _pol="project_only"
        info "  Socket policy:  ${_pol}"
    fi
    if [[ "$browser_enabled" == "true" ]]; then
        info "  Browser:        ${browser_mode} mode (CDP port ${browser_effective_port})"
    else
        info "  Browser:        disabled"
    fi
    if [[ "$github_enabled" == "true" ]]; then
        info "  GitHub MCP:     enabled (token: \$${github_token_env})"
    else
        info "  GitHub MCP:     disabled"
    fi

    # Ports
    local all_ports=()
    while IFS= read -r _p; do
        [[ -z "$_p" ]] && continue
        all_ports+=("$_p")
    done <<< "$(yml_get_ports "$project_yml")"
    for _p in "${extra_ports[@]+"${extra_ports[@]}"}"; do
        all_ports+=("$_p")
    done
    if [[ ${#all_ports[@]} -gt 0 ]]; then
        info "  Ports:          ${all_ports[*]}"
    else
        info "  Ports:          (none)"
    fi

    # Repos
    local _repos
    _repos=$(_effective_repo_mounts "$project_yml")
    if [[ -n "$_repos" ]]; then
        info "  Repos:"
        while IFS=$'\t' read -r _rn _rp; do
            [[ -z "$_rn" ]] && continue
            info "    - ${_rn} (${_rp})"
        done <<< "$_repos"
    fi

    # Packs
    if [[ -n "$pack_names" ]]; then
        info "  Packs:"
        while IFS= read -r _pk; do
            [[ -z "$_pk" ]] && continue
            info "    - ${_pk}"
        done <<< "$pack_names"
    fi

    echo ""
    if $dry_run_dump; then
        info "Generated files available at: ${output_dir}/"
        echo ""
        info "  .cco/docker-compose.yml"
        [[ -f "$output_dir/.cco/managed/policy.json" ]]  && info "  .cco/managed/policy.json"
        [[ -f "$output_dir/.cco/managed/browser.json" ]]  && info "  .cco/managed/browser.json"
        [[ -f "$output_dir/.cco/managed/github.json" ]]   && info "  .cco/managed/github.json"
        echo ""
        info "Inspect with: cat ${output_dir}/.cco/docker-compose.yml"
    else
        ok "Dry-run complete. Use --dump to persist generated files for inspection."
    fi
}

# Launches the Docker session with auth and secrets.
_start_launch() {
    # Ensure ~/.claude.json exists on host (needed for MCP, session metadata)
    if [[ ! -f "$HOME/.claude.json" ]]; then
        echo '{}' > "$HOME/.claude.json"
    fi

    # Resolve auth and secrets for the session
    # OAuth: credentials are in ~/.claude/.credentials.json (seeded from macOS Keychain,
    # auto-refreshed by Claude). No env var needed — Claude reads the file directly.
    local run_env=()
    if [[ "$auth_method" == "api_key" ]]; then
        [[ -z "${ANTHROPIC_API_KEY:-}" ]] && die "ANTHROPIC_API_KEY is not set. Export it before running cco start --api-key."
        run_env+=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
    fi

    # Load global secrets as runtime env vars (for MCP servers that read env directly)
    load_global_secrets run_env
    # Load project-specific secrets (override global values — Docker uses last -e for duplicates)
    load_secrets_file run_env "$project_dir/secrets.env"

    info "Starting session for project '${project_name}'..."
    docker compose -f "$compose_file" --project-directory "$session_state_dir" run --rm --service-ports "${run_env[@]+"${run_env[@]}"}" claude

    ok "Session ended. Changes are in your repos."
}

cmd_start() {
    check_global

    local project=""
    local from_repo=""
    local teammate_mode=""
    local use_api_key=false
    local dry_run=false
    local dry_run_dump=false
    local opt_chrome=""      # "on" | "off" | "" (unset = read from project.yml)
    local opt_github=""      # "on" | "off" | "" (unset = read from project.yml)
    local opt_docker=""      # "off" | "" (unset = read from project.yml)
    local extra_ports=()
    local extra_envs=()
    local user_mounts=()        # --mount specs (ADR-0027 D2), :ro by default
    local enable_config_edit=false  # --enable-config-edit escape hatch (ADR-0027 D3)
    local config_editor_targets=()  # --project <name> (repeatable): narrow + mount its repos (ADR-0042 §8)
    local config_editor_repos=()    # --repo <name> (repeatable): add one resolvable repo (ADR-0042 §8)
    local config_editor_all=false   # --all: explicit alias of the broad default (kept for back-compat)
    local cli_claude_access=""      # --claude-access override (ADR-0036 D2/D3); "" = unset
    local cli_cco_access=""         # --cco-access override; supersedes --enable-config-edit
    local cli_show_host_paths=""    # "" | "true" | "false" (--show-host-paths / --no-…)

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from) [[ $# -lt 2 ]] && die "--from requires a <repo> name."; from_repo="$2"; shift 2 ;;
            --mount) [[ $# -lt 2 ]] && die "--mount requires <src>[:<target>][:ro|:rw]."; user_mounts+=("$2"); shift 2 ;;
            --enable-config-edit) enable_config_edit=true; shift ;;
            --claude-access) [[ $# -lt 2 ]] && die "--claude-access requires a value (none|repo|all)."; cli_claude_access="$2"; shift 2 ;;
            --cco-access) [[ $# -lt 2 ]] && die "--cco-access requires a value (none|read-project|read-global|read-all|edit-project|edit-global|edit-all)."; cli_cco_access="$2"; shift 2 ;;
            --show-host-paths) cli_show_host_paths="true"; shift ;;
            --no-show-host-paths) cli_show_host_paths="false"; shift ;;
            --project) [[ $# -lt 2 ]] && die "--project requires a <name> (config-editor project mode)."; config_editor_targets+=("$2"); shift 2 ;;
            --repo) [[ $# -lt 2 ]] && die "--repo requires a <name> (config-editor repo mount)."; config_editor_repos+=("$2"); shift 2 ;;
            --all) config_editor_all=true; shift ;;
            --teammate-mode) teammate_mode="$2"; shift 2 ;;
            --api-key) use_api_key=true; shift ;;
            --dry-run) dry_run=true; shift ;;
            --dump) dry_run_dump=true; shift ;;
            --chrome)     opt_chrome="on";  shift ;;
            --no-chrome)  opt_chrome="off"; shift ;;
            --github)     opt_github="on";  shift ;;
            --no-github)  opt_github="off"; shift ;;
            --no-docker)  opt_docker="off"; shift ;;
            --port) extra_ports+=("$2"); shift 2 ;;
            --env) extra_envs+=("$2"); shift 2 ;;
            --help|-h)
                cat <<'EOF'
Usage: cco start [project] [OPTIONS]

Reads the decentralized <repo>/.cco/ config. With no project name, starts the
project the current repo HOSTS (cwd-first); name a project to resolve it via the
machine-local index.

Built-in sessions: 'cco start config-editor' opens the config-editor. By default
it mounts your ~/.cco store + EVERY resolvable project's .cco/ for broad config
editing (no code repos). Narrow with --project <name> (repeatable) to mount just
that project's .cco/ AND its repos (repo-aware config authoring); --repo <name>
adds one repo. 'cco start tutorial' opens the read-only tutorial.

Options:
  --from <repo>        Use <repo>/.cco as the config source (Case-C divergence)
  --project <name>     config-editor only: narrow to <name>'s .cco/ + its repos (rw; repeatable)
  --repo <name>        config-editor only: also mount repo <name> (rw; repeatable)
  --all                config-editor only: explicit alias of the broad default (all .cco/, no repos)
  --teammate-mode <m>  Override display mode: tmux | auto
  --api-key            Use ANTHROPIC_API_KEY instead of OAuth
  --chrome             Enable browser automation for this session only
  --no-chrome          Disable browser automation for this session only
  --github             Enable GitHub MCP for this session only
  --no-github          Disable GitHub MCP for this session only
  --no-docker          Disable Docker socket mount for this session only
  --mount <s>[:<t>][:ro|:rw]  Mount reference material (repeatable; read-only by
                       default, :rw to make writable; target defaults to
                       /workspace/<basename>)
  --claude-access <l>  .claude authoring access: none | repo (default) | all
  --cco-access <l>     .cco/framework access: none | read-project (default) |
                       read-global | read-all | edit-project | edit-global |
                       edit-all (ADR-0036/0042; `read` = alias for read-all)
  --show-host-paths    Show the host<->container path map to the session (default)
  --no-show-host-paths Hide host paths from the session
  --enable-config-edit Deprecated alias for --cco-access edit-project (see 'cco
                       start config-editor' for the sanctioned config-editing
                       session)
  --dry-run            Show the generated docker-compose without running
  --dump               With --dry-run: persist artifacts to .tmp/ for inspection
  --port <p>           Add extra port mapping (repeatable)
  --env <K=V>          Add extra environment variable (repeatable)

Session flags (--chrome, --no-chrome, --github, --no-github, --no-docker) override
project.yml for one session only. To change the default, edit project.yml instead.
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$project" ]]; then
                    project="$1"; shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done

    # --enable-config-edit (ADR-0027) is now sugar for --cco-access edit-project
    # (ADR-0036 D3), deprecated for one release. An explicit --cco-access wins; the
    # legacy bool still drives the current mount path until step 3 switches the
    # mount logic over to the resolved cco_access knob.
    if $enable_config_edit && [[ -z "$cli_cco_access" ]]; then
        cli_cco_access="edit-project"
    fi

    # No project name is valid: cwd-first resolution (the repo this dir hosts).
    # _start_resolve_project dies with guidance when cwd is not a configured repo.

    # Resolve --mount specs eagerly (ADR-0027 D2): a bad source must fail before
    # any compose is generated, not mid-file. Each becomes abs_src<TAB>tgt<TAB>ro.
    local user_mount_lines=()
    local _mspec
    for _mspec in ${user_mounts[@]+"${user_mounts[@]}"}; do
        user_mount_lines+=("$(_parse_user_mount_spec "$_mspec")")
    done

    # Variables set by helper functions (declared here for shared scope)
    local project_dir project_yml is_internal claude_src source_repo source_kind
    local unresolved_refs=0
    local project_name auth_method docker_image mount_socket network
    local browser_enabled browser_mode browser_cdp_port browser_effective_port browser_mcp_args
    local github_enabled github_token_env pack_names
    local output_dir compose_file
    local config_dir session_state_dir session_cache_dir managed_gen_dir claude_gen_dir
    local claude_access cco_access show_host_paths   # resolved by _start_resolve_access (ADR-0036)
    local session_context_b64="" subagent_context_b64=""  # Level-A injected context (ADR-0042)
    local session_preset="normal"    # normal | tutorial | config-editor (built-in presets, D6)
    local _op_config_masks=()        # host<TAB>target pairs of built-in config mounts to secret-mask (5b)

    _start_resolve_project
    [[ "${CCO_DEBUG:-}" == "1" ]] && echo "[debug] resolve_project done" >&2

    # config-editor-only selectors (ADR-0042 §8). They are consumed solely in the
    # config-editor branch of _start_resolve_project; passed to any other session
    # they would be silently ignored (no mount, no error), so reject them here
    # with guidance rather than fail closed and confuse the user.
    if [[ "$session_preset" != "config-editor" ]]; then
        if [[ ${#config_editor_targets[@]} -gt 0 || ${#config_editor_repos[@]} -gt 0 || "$config_editor_all" == "true" ]]; then
            die "--all / --project / --repo apply only to 'cco start config-editor' (ADR-0042 §8). This is a '${session_preset}' session."
        fi
    else
        # --all is the explicit alias of the broad default (no targets); combining
        # it with a narrowing selector is contradictory — reject rather than
        # silently drop --all.
        if [[ "$config_editor_all" == "true" && ( ${#config_editor_targets[@]} -gt 0 || ${#config_editor_repos[@]} -gt 0 ) ]]; then
            die "--all (broad: every project's <repo>/.cco) cannot be combined with --project/--repo (which narrow the scope)."
        fi
    fi

    _start_load_config
    [[ "${CCO_DEBUG:-}" == "1" ]] && echo "[debug] load_config done" >&2

    # Resolve the capability-model knobs (ADR-0036 D2/D3). project_yml is set by
    # _start_resolve_project; the resolved values feed mount generation (step 3+).
    _start_resolve_access
    [[ "${CCO_DEBUG:-}" == "1" ]] && echo "[debug] resolve_access done" >&2

    _start_check_health
    [[ "${CCO_DEBUG:-}" == "1" ]] && echo "[debug] check_health done" >&2

    _start_prepare_state
    [[ "${CCO_DEBUG:-}" == "1" ]] && echo "[debug] prepare_state done" >&2

    _start_generate_integrations
    [[ "${CCO_DEBUG:-}" == "1" ]] && echo "[debug] generate_integrations done" >&2

    _start_resolve_paths
    [[ "${CCO_DEBUG:-}" == "1" ]] && echo "[debug] resolve_paths done" >&2

    # Source transparency + passive ⚠ badge (design §4.4 / ADR-0019 D2 layer-e /
    # P14), AFTER member resolution (H1). Always print which <repo>/.cco config
    # source was used, so the precedence (--from > cwd/by-name) is never opaque;
    # the badge names the next step (cco resolve) but never blocks the launch.
    if ! $is_internal; then
        info "started ${project_name} from $(basename "$source_repo") [source: ${source_kind}]"
        [[ "${unresolved_refs:-0}" -gt 0 ]] && \
            warn "⚠ ${project_name}: ${unresolved_refs} reference(s) unresolved — run 'cco resolve'"
    fi

    # H1: config reminders fire AFTER member resolution, never against an empty
    # index (ADR-0008). Silent on the pre-P2 central layout (no per-repo .cco/).
    _start_emit_reminders
    [[ "${CCO_DEBUG:-}" == "1" ]] && echo "[debug] emit_reminders done" >&2

    # Compute the Level-A session context (ADR-0042) BEFORE compose so the
    # generated compose can inject it as the CCO_SESSION_CONTEXT env var. No file
    # is written (the workspace.yml overlay is retired).
    _start_generate_metadata
    [[ "${CCO_DEBUG:-}" == "1" ]] && echo "[debug] generate_metadata done" >&2

    _start_generate_compose
    [[ "${CCO_DEBUG:-}" == "1" ]] && echo "[debug] generate_compose done" >&2

    if $dry_run; then
        _start_show_summary
        return 0
    fi

    _start_launch
}

# ── Browser support helpers ──────────────────────────────────────────

# Returns CDP ports claimed by running cco sessions (one per line).
# Enumerates projects via the STATE index (decentralized layout): each project's
# committed config is read from its repo `.cco/project.yml`, and its browser
# runtime file from CACHE (keyed by project name).
_collect_claimed_browser_ports() {
    local current_project="$1"
    local claimed=()
    local proj repo
    while IFS='=' read -r proj _; do
        [[ -z "$proj" ]] && continue
        [[ "$proj" == "$current_project" ]] && continue
        # Resolve the host repo via index membership: a joined multi-repo project's
        # key lives in `projects:`, not `paths:`, so _index_get_path on the project
        # name would silently miss it (dropping it from the port-conflict scan).
        repo=$(_resolve_unit_dir_for_project "$proj" 2>/dev/null)
        [[ -z "$repo" ]] && continue
        local yml="$repo/.cco/project.yml"
        [[ ! -f "$yml" ]] && continue
        local enabled; enabled=$(yml_get "$yml" "browser.enabled")
        [[ "$enabled" != "true" ]] && continue
        # Verify container is actually running (use yml name, fallback to index name)
        local yml_name; yml_name=$(yml_get "$yml" "name")
        [[ -z "$yml_name" ]] && yml_name="$proj"
        local container="cc-${yml_name}"
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$" || continue
        # Read effective port (runtime file > project.yml > default)
        local managed; managed=$(_cco_project_cache_managed "$proj")
        if [[ -f "$managed/.browser-port" ]]; then
            claimed+=("$(cat "$managed/.browser-port")")
        else
            local port; port=$(yml_get "$yml" "browser.cdp_port")
            [[ -z "$port" ]] && port="9222"
            claimed+=("$port")
        fi
    done < <(_index_list_projects)
    # Guard: bash 3.2 + set -u treats empty arrays as unbound
    [[ ${#claimed[@]} -gt 0 ]] && printf '%s\n' "${claimed[@]}"
}

# Finds the lowest free port starting from preferred, skipping claimed ports
_resolve_browser_port() {
    local preferred="$1"
    local current_project="$2"
    local claimed=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && claimed+=("$line")
    done < <(_collect_claimed_browser_ports "$current_project")

    local port="$preferred"
    while true; do
        local taken=false
        # Guard: bash 3.2 + set -u treats empty arrays as unbound
        for c in ${claimed[@]+"${claimed[@]}"}; do
            [[ "$c" == "$port" ]] && taken=true && break
        done
        if [[ "$taken" == "false" ]]; then
            if [[ "$port" != "$preferred" ]]; then
                warn "Browser: CDP port ${preferred} is claimed by another session."
                warn "         Using port ${port} instead."
                info "         Run: cco chrome start --project ${current_project}"
            fi
            echo "$port"
            return
        fi
        ((port++))
    done
}

# Generates .managed/browser.json with chrome-devtools-mcp configuration
_generate_browser_mcp() {
    local out_file="$1" mode="$2" cdp_port="$3" mcp_args="${4:-}"

    local browser_url
    if [[ "$mode" == "host" ]]; then
        browser_url="http://localhost:${cdp_port}"
    else
        # container mode: deferred
        browser_url="http://browser:${cdp_port}"
    fi

    # Build extra args JSON lines from mcp_args (newline-separated list)
    local extra_args=""
    if [[ -n "$mcp_args" ]]; then
        while IFS= read -r arg; do
            if [[ -n "$arg" ]]; then
                # Escape backslashes first, then double quotes for valid JSON
                arg="${arg//\\/\\\\}"
                arg="${arg//\"/\\\"}"
                extra_args+=",
        \"${arg}\""
            fi
        done <<< "$mcp_args"
    fi

    printf '{
  "mcpServers": {
    "chrome-devtools": {
      "command": "chrome-devtools-mcp",
      "args": [
        "--browserUrl=%s",
        "--no-usage-statistics",
        "--no-performance-crux"%s
      ]
    }
  }
}\n' "$browser_url" "$extra_args" > "$out_file"
}

# Generates .managed/github.json with github MCP server configuration
# $1 = output file path
# $2 = token_env: name of the env var holding the GitHub token (e.g. GITHUB_TOKEN)
_generate_github_mcp() {
    local out_file="$1" token_env="$2"
    [[ -z "$token_env" ]] && token_env="GITHUB_TOKEN"

    printf '{
  "mcpServers": {
    "github": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_TOKEN": "${%s}"
      }
    }
  }
}\n' "$token_env" > "$out_file"
}

# Generates .managed/policy.json for the Docker socket proxy.
# Reads docker.containers, docker.mounts, docker.security from project.yml.
# $1 = project.yml path, $2 = project name, $3 = project dir
# Build the mounts.allowed_paths JSON array for the proxy policy.
# For policy=project_only, uses each repo's resolved host path; for other
# policies, uses the explicit docker.mounts.allow list.
# Repo paths come post-resolution: unresolved references were dropped upstream by
# the P14 conscious-skip, so every path here is resolved and existing.
# Usage: _proxy_collect_allowed_paths <project_yml> <mt_policy>
# Output: JSON array on stdout (e.g. `[]` or `["/path/a","/path/b"]`)
_proxy_collect_allowed_paths() {
    local project_yml="$1" mt_policy="$2"
    if [[ "$mt_policy" == "project_only" ]]; then
        local repos
        repos=$(_effective_repo_mounts "$project_yml")
        [[ -z "$repos" ]] && { echo "[]"; return 0; }
        while IFS=$'\t' read -r _n _p; do
            [[ -z "$_p" ]] && continue
            printf '%s\n' "$_p"
        done <<< "$repos" | jq -R . | jq -s .
    else
        local mt_allow
        mt_allow=$(yml_get_deep_list "$project_yml" "docker.mounts.allow")
        [[ -z "$mt_allow" ]] && { echo "[]"; return 0; }
        while IFS= read -r _p; do
            [[ -z "$_p" ]] && continue
            expand_path "$_p"
        done <<< "$mt_allow" | jq -R . | jq -s .
    fi
}

# Build the mounts.path_map JSON object for the proxy policy.
# Maps each container-visible prefix → host path so the proxy can
# translate bind-mount paths coming from the sibling container before
# forwarding to the Docker daemon.
# Includes: /workspace/<repo_name> per repo, extra_mounts targets, and
# /home/claude → $HOME for ~/... expansions inside the container.
# Usage: _proxy_collect_pathmap <project_yml>
# Output: JSON object on stdout (e.g. `{"/workspace/foo":"/abs/foo",...}`)
_proxy_collect_pathmap() {
    local project_yml="$1"
    local _pathmap_lines=""

    # /workspace/<repo_name> → expanded host path per repo
    # (post-resolution: unresolved references were dropped by the P14
    # conscious-skip; see _proxy_collect_allowed_paths)
    local _repo_lines
    _repo_lines=$(_effective_repo_mounts "$project_yml")
    if [[ -n "$_repo_lines" ]]; then
        while IFS=$'\t' read -r _rn _host_p; do
            [[ -z "$_rn" ]] && continue
            _pathmap_lines="${_pathmap_lines}/workspace/${_rn}"$'\t'"${_host_p}"$'\n'
        done <<< "$_repo_lines"
    fi

    # extra_mounts: container target → expanded host source
    local _extra_mounts
    _extra_mounts=$(_effective_extra_mounts "$project_yml" 2>/dev/null || true)
    if [[ -n "$_extra_mounts" ]]; then
        while IFS=$'\t' read -r _src _tgt _ro; do
            [[ -z "$_src" ]] && continue
            _pathmap_lines="${_pathmap_lines}${_tgt}"$'\t'"${_src}"$'\n'
        done <<< "$_extra_mounts"
    fi

    # /home/claude → $HOME (for ~/... expansion inside the container)
    _pathmap_lines="${_pathmap_lines}/home/claude"$'\t'"${HOME}"$'\n'

    if [[ -z "$_pathmap_lines" ]]; then
        echo "{}"
        return 0
    fi
    printf '%s' "$_pathmap_lines" | grep -v '^$' | \
        jq -R 'split("\t") | {key: .[0], value: .[1]}' | jq -s 'from_entries'
}

_generate_socket_policy() {
    local project_yml="$1" project_name="$2" managed_dir="$3"

    mkdir -p "$managed_dir"
    local out_file="$managed_dir/policy.json"

    # Container policy
    local ct_policy ct_create ct_prefix
    ct_policy=$(yml_get_deep "$project_yml" "docker.containers.policy")
    ct_policy=$(yml_validate_enum "$ct_policy" "project_only" "project_only|allowlist|denylist|unrestricted")
    ct_create=$(_parse_bool "$(yml_get_deep "$project_yml" "docker.containers.create")" "true")
    ct_prefix=$(yml_get_deep "$project_yml" "docker.containers.name_prefix")
    [[ -z "$ct_prefix" ]] && ct_prefix="cc-${project_name}-"

    # Container allow/deny patterns
    local ct_allow_json="[]" ct_deny_json="[]"
    local ct_allow ct_deny
    ct_allow=$(yml_get_deep_list "$project_yml" "docker.containers.allow")
    ct_deny=$(yml_get_deep_list "$project_yml" "docker.containers.deny")
    if [[ -n "$ct_allow" ]]; then
        ct_allow_json=$(echo "$ct_allow" | jq -R . | jq -s .)
    fi
    if [[ -n "$ct_deny" ]]; then
        ct_deny_json=$(echo "$ct_deny" | jq -R . | jq -s .)
    fi

    # Required labels
    local ct_labels_json="{}"
    local ct_labels
    ct_labels=$(yml_get_deep_map "$project_yml" "docker.containers.required_labels")
    if [[ -n "$ct_labels" ]]; then
        ct_labels_json=$(echo "$ct_labels" | awk '{
            # Split only on the first colon to preserve colons in values
            idx = index($0, ":")
            if (idx > 0) {
                key = substr($0, 1, idx-1)
                val = substr($0, idx+1)
                printf "\"%s\":\"%s\"\n", key, val
            }
        }' | jq -s 'from_entries')
    else
        ct_labels_json="{\"cco.project\":\"${project_name}\"}"
    fi

    # Mount policy
    local mt_policy mt_force_ro
    mt_policy=$(yml_get_deep "$project_yml" "docker.mounts.policy")
    mt_policy=$(yml_validate_enum "$mt_policy" "project_only" "none|project_only|allowlist|any")
    mt_force_ro=$(_parse_bool "$(yml_get_deep "$project_yml" "docker.mounts.force_readonly")" "false")

    # Mount allowed paths + container→host path_map — see the dedicated
    # helpers above. Keeping policy data collection separate from the
    # JSON-template rendering below is an SRP hygiene measure.
    local mt_allowed_json mt_pathmap_json
    mt_allowed_json=$(_proxy_collect_allowed_paths "$project_yml" "$mt_policy")
    mt_pathmap_json=$(_proxy_collect_pathmap       "$project_yml")

    # Mount denied paths (explicit) — expanded like allowed paths
    local mt_denied_json="[]"
    local mt_deny
    mt_deny=$(yml_get_deep_list "$project_yml" "docker.mounts.deny")
    if [[ -n "$mt_deny" ]]; then
        mt_denied_json=$(while IFS= read -r _p; do
            [[ -z "$_p" ]] && continue
            expand_path "$_p"
        done <<< "$mt_deny" | jq -R . | jq -s .)
    fi

    # Security policy
    local sec_no_priv sec_no_sens sec_force_nonroot
    sec_no_priv=$(_parse_bool "$(yml_get_deep "$project_yml" "docker.security.no_privileged")" "true")
    sec_no_sens=$(_parse_bool "$(yml_get_deep "$project_yml" "docker.security.no_sensitive_mounts")" "true")
    sec_force_nonroot=$(_parse_bool "$(yml_get_deep "$project_yml" "docker.security.force_non_root")" "false")

    # Drop capabilities
    local sec_dropcaps_json="[\"SYS_ADMIN\",\"NET_ADMIN\"]"
    local sec_dropcaps
    sec_dropcaps=$(yml_get_deep_list "$project_yml" "docker.security.drop_capabilities")
    if [[ -n "$sec_dropcaps" ]]; then
        sec_dropcaps_json=$(echo "$sec_dropcaps" | jq -R . | jq -s .)
    fi

    # Resources (docker.security.resources.*)
    local sec_memory sec_cpus sec_max_ct
    sec_memory=$(yml_get_deep4 "$project_yml" "docker.security.resources.memory")
    sec_cpus=$(yml_get_deep4 "$project_yml" "docker.security.resources.cpus")
    sec_max_ct=$(yml_get_deep4 "$project_yml" "docker.security.resources.max_containers")

    # Convert memory string to bytes (e.g., "4g" → 4294967296)
    local memory_bytes=4294967296  # default 4g
    if [[ -n "$sec_memory" ]]; then
        case "$sec_memory" in
            *[gG]) memory_bytes=$(( ${sec_memory%[gG]} * 1024 * 1024 * 1024 )) ;;
            *[mM]) memory_bytes=$(( ${sec_memory%[mM]} * 1024 * 1024 )) ;;
            *)     memory_bytes="$sec_memory" ;;
        esac
    fi

    # Convert CPUs to nanoCPUs (e.g., "4" → 4000000000, "0.5" → 500000000)
    local nano_cpus=4000000000  # default 4
    if [[ -n "$sec_cpus" ]]; then
        # Use awk for fractional support (no bc dependency)
        nano_cpus=$(awk "BEGIN { printf \"%.0f\", $sec_cpus * 1000000000 }")
    fi

    [[ -z "$sec_max_ct" ]] && sec_max_ct=10

    # Network allowed prefixes
    local net_prefixes_json="[\"cc-${project_name}\"]"
    local custom_network
    custom_network=$(yml_get "$project_yml" "docker.network")
    if [[ -n "$custom_network" ]]; then
        net_prefixes_json="[\"${custom_network}\"]"
    fi

    # Write policy.json
    cat > "$out_file" <<POLICY
{
  "project_name": "${project_name}",
  "containers": {
    "policy": "${ct_policy}",
    "allow_patterns": ${ct_allow_json},
    "deny_patterns": ${ct_deny_json},
    "create_allowed": ${ct_create},
    "name_prefix": "${ct_prefix}",
    "required_labels": ${ct_labels_json}
  },
  "mounts": {
    "policy": "${mt_policy}",
    "allowed_paths": ${mt_allowed_json},
    "denied_paths": ${mt_denied_json},
    "implicit_deny": [
      "/var/run/docker.sock",
      "/etc/shadow",
      "/etc/sudoers"
    ],
    "force_readonly": ${mt_force_ro},
    "path_map": ${mt_pathmap_json}
  },
  "security": {
    "no_privileged": ${sec_no_priv},
    "no_sensitive_mounts": ${sec_no_sens},
    "force_non_root": ${sec_force_nonroot},
    "drop_capabilities": ${sec_dropcaps_json},
    "max_memory_bytes": ${memory_bytes},
    "max_nano_cpus": ${nano_cpus},
    "max_containers": ${sec_max_ct}
  },
  "networks": {
    "allowed_prefixes": ${net_prefixes_json}
  }
}
POLICY

    echo "[start] Generated Docker socket policy: containers=${ct_policy}, mounts=${mt_policy}" >&2
}
