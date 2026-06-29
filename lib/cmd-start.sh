#!/usr/bin/env bash
# lib/cmd-start.sh — Start project session command
#
# Provides: _setup_internal_tutorial(), cmd_start()
# Dependencies: colors.sh, utils.sh, yaml.sh, secrets.sh, workspace.sh, packs.sh
# Globals: IMAGE_NAME, REPO_ROOT, USER_CONFIG_DIR (projects via the STATE index, P5)

# ── Internal Tutorial Setup ──────────────────────────────────────────
# Prepares the runtime directory for the internal tutorial project.
# Content (.claude/, project.yml) is refreshed from internal/tutorial/ every start.
# Session transcripts/memory live in machine-local STATE (keyed by the internal
# project name, mounted via _cco_project_session_*), not in the runtime dir.
_setup_internal_tutorial() {
    local source_dir="$REPO_ROOT/internal/tutorial"
    local runtime_dir="$USER_CONFIG_DIR/.cco/internal/tutorial"

    [[ ! -d "$source_dir" ]] && die "Internal tutorial not found at $source_dir"

    # Ensure the runtime dir exists (content is refreshed below; session
    # transcripts/memory live in STATE, mounted via _cco_project_session_*).
    mkdir -p "$runtime_dir"

    # Always refresh content from framework source (ensures tutorial is current)
    rm -rf "$runtime_dir/.claude"
    cp -r "$source_dir/.claude" "$runtime_dir/.claude" \
        || die "Failed to refresh tutorial content from $source_dir. Check permissions and disk space."

    # Refresh project.yml with path substitution. CCO_CONFIG_DIR = the personal
    # store ~/.cco (read-only mount); CCO_USER_CONFIG_DIR kept for back-compat.
    sed -e "s|{{CCO_REPO_ROOT}}|$REPO_ROOT|g" \
        -e "s|{{CCO_CONFIG_DIR}}|$(_cco_config_dir)|g" \
        -e "s|{{CCO_USER_CONFIG_DIR}}|$USER_CONFIG_DIR|g" \
        "$source_dir/project.yml" > "$runtime_dir/project.yml" \
        || die "Failed to generate tutorial project.yml"

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
# Args: <target_cco_path> <target_name>  (both empty in global mode)
_setup_internal_config_editor() {
    local target_cco="$1" target_name="$2"
    local source_dir="$REPO_ROOT/internal/config-editor"
    local runtime_dir="$USER_CONFIG_DIR/.cco/internal/config-editor"

    [[ ! -d "$source_dir" ]] && die "Internal config-editor not found at $source_dir"

    mkdir -p "$runtime_dir"

    # Always refresh content from framework source (ensures it is current).
    rm -rf "$runtime_dir/.claude"
    cp -r "$source_dir/.claude" "$runtime_dir/.claude" \
        || die "Failed to refresh config-editor content from $source_dir."
    [[ -f "$source_dir/setup.sh" ]] && cp "$source_dir/setup.sh" "$runtime_dir/setup.sh"

    # Generate project.yml: ~/.cco rw + docs ro (+ the target's .cco rw in
    # project mode). The personal store is mounted read-write — editing it is
    # the whole purpose of this session.
    local cfg; cfg="$(_cco_config_dir)"
    # The mount bridge resolves names via the STATE index (name → host path), but
    # these are EPHEMERAL internal names — writing them into the persistent,
    # user-facing index pollutes it permanently and clobbers any user binding of the
    # same name (review H4). Publish them instead via the in-process session override
    # (_mount_override_get), which _effective_extra_mounts consults before the index.
    # The generated project.yml only references these names; they resolve via the
    # session override at start (never the persistent index), so no host path is
    # committed (AD3/G8).
    _CCO_MOUNT_OVERRIDE=$(printf 'cco-config\t%s\ncco-docs\t%s' "$cfg" "$REPO_ROOT/docs")
    [[ -n "$target_cco" ]] && _CCO_MOUNT_OVERRIDE+=$(printf '\n%s-config\t%s' "$target_name" "$target_cco")
    {
        cat <<YAML
name: config-editor
description: "Configuration editor for claude-orchestrator"
extra_mounts:
  - name: cco-config
    target: /workspace/cco-config
    readonly: false
  - name: cco-docs
    target: /workspace/cco-docs
    readonly: true
YAML
        if [[ -n "$target_cco" ]]; then
            cat <<YAML
  - name: ${target_name}-config
    target: /workspace/${target_name}-config
    readonly: false
YAML
        fi
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

# ── cmd_start() helper functions ─────────────────────────────────────
# These functions are called from within cmd_start() and share its local
# variable scope. They must NOT redeclare variables — they read/write
# cmd_start()'s locals directly.

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
        _setup_internal_tutorial
        project_dir="$USER_CONFIG_DIR/.cco/internal/tutorial"
        project_yml="$project_dir/project.yml"
        claude_src="$project_dir/.claude"
        source_repo="$project_dir"
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
        # Project mode: --project <name> wins; else a cwd that hosts a configured
        # repo. Resolve the target's <repo>/.cco for an additional rw mount.
        local _ce_path="" _ce_name="" _ce_cco=""
        if [[ -n "$config_editor_target" ]]; then
            _ce_path=$(_resolve_unit_dir_for_project "$config_editor_target") \
                || die "config-editor --project '$config_editor_target' is not resolvable on this machine. Run 'cco resolve' first."
            _ce_name="$config_editor_target"
        elif _ce_path=$(_resolve_find_unit_dir 2>/dev/null); then
            _ce_name=$(yml_get "$_ce_path/.cco/project.yml" name 2>/dev/null)
        fi
        [[ -n "$_ce_path" && -d "$_ce_path/.cco" ]] && _ce_cco="$_ce_path/.cco"
        _setup_internal_config_editor "$_ce_cco" "$_ce_name"
        project_dir="$USER_CONFIG_DIR/.cco/internal/config-editor"
        project_yml="$project_dir/project.yml"
        claude_src="$project_dir/.claude"
        source_repo="$project_dir"
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

    # Check for existing running session
    if ! $dry_run && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^cc-${project_name}$"; then
        die "Project '${project_name}' already has a running session (container cc-${project_name}). Run 'cco stop ${project}' first."
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

    # Parse packs early (needed both for compose and packs.md generation)
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
        # packs.md/workspace.yml are produced here and mounted :ro on top of the
        # rw project .claude (ADR-0005 F1), never written into the committed tree.
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
                host_startups=$(jq -r '.numStartups // 0' "$HOME/.claude.json" 2>/dev/null || echo 0)
                global_startups=$(jq -r '.numStartups // 0' "$global_claude_json" 2>/dev/null || echo 0)
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

        # Agentic config edit-protection (ADR-0027 D3, narrow scope). A normal
        # session overlays the committed structural framework config
        # (<repo>/.cco: project.yml, secrets.env, internal metadata) READ-ONLY
        # so the in-container agent cannot involuntarily mutate it while working
        # on code. The project's Claude config tree (/workspace/.claude) stays rw
        # (P17, /init authoring). The host IDE is unaffected (container-only).
        # Built-in sessions (tutorial, config-editor) and the explicit
        # --enable-config-edit escape hatch keep <repo>/.cco read-write.
        local _committed_ro=":ro"
        if $is_internal || $enable_config_edit; then _committed_ro=""; fi

        # ~/.claude.json — preferences, MCP servers, session metadata (machine-local STATE)
        _compose_vol "${state_root}/claude.json" "/home/claude/.claude.json"
        # ~/.claude/.credentials.json — OAuth tokens (machine-local STATE, never synced)
        _compose_vol "${state_root}/.credentials.json" "/home/claude/.claude/.credentials.json"

        # Global config (settings.json is rw — Claude Code writes runtime preferences like /effort)
        echo "      # Global config (settings.json is rw — Claude Code writes runtime preferences like /effort)"
        _compose_vol "${global_claude}/settings.json" "/home/claude/.claude/settings.json"
        _compose_vol "${global_claude}/CLAUDE.md" "/home/claude/.claude/CLAUDE.md" "ro"
        _compose_vol "${global_claude}/rules" "/home/claude/.claude/rules" "ro"
        _compose_vol "${global_claude}/agents" "/home/claude/.claude/agents" "ro"
        _compose_vol "${global_claude}/skills" "/home/claude/.claude/skills" "ro"
        # Project config. The Claude config tree (CLAUDE.md/rules/agents/skills)
        # stays rw so /init + normal project-config authoring work (P17); the
        # structural framework config (project.yml/secrets/.cco metadata) is
        # protected separately by the <repo>/.cco :ro overlay below (ADR-0027 D3).
        echo "      # Project config (.cco/claude is rw for /init authoring; .cco metadata is :ro below, ADR-0027 D3)"
        _compose_vol "${claude_src}" "/workspace/.claude"
        _compose_vol "${project_dir}/project.yml" "/workspace/project.yml" "ro"
        # Claude state: session transcripts (machine-local STATE; enables /resume across rebuilds)
        echo "      # Claude state: session transcripts (machine-local STATE; /resume across rebuilds)"
        _compose_vol "$(_cco_project_session_transcripts "$project_name")" "/home/claude/.claude/projects/-workspace"
        # Memory: auto memory files (machine-local STATE, separate from transcripts)
        echo "      # Memory: auto memory files (machine-local STATE, separate from transcripts)"
        _compose_vol "$(_cco_project_session_memory "$project_name")" "/home/claude/.claude/projects/-workspace/memory"

        # Generated .claude overlays (packs.md, workspace.yml) → CACHE, layered
        # :ro on top of the rw project .claude mount above (ADR-0005 F1/F3).
        # Docker applies child mounts after their parent regardless of order, so
        # the parent stays rw while these stay read-only; the committed project
        # .claude/ is never written by cco start.
        if [[ -f "$claude_gen_dir/packs.md" ]]; then
            _compose_vol "${session_cache_dir}/.claude/packs.md" "/workspace/.claude/packs.md" "ro"
        fi
        if [[ -f "$claude_gen_dir/workspace.yml" ]]; then
            _compose_vol "${session_cache_dir}/.claude/workspace.yml" "/workspace/.claude/workspace.yml" "ro"
        fi

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

        # Edit-protection (ADR-0027 D3): overlay each repo's committed .cco as
        # :ro on top of the rw repo mount (Docker applies child mounts after the
        # parent), so the agent cannot mutate the structural framework config
        # (project.yml, secrets.env, internal metadata) via the code repo. The
        # project's Claude config (.cco/claude) is still authored normally
        # through the rw /workspace/.claude overlay (P17). Skipped under
        # --enable-config-edit and for built-ins.
        if [[ -n "$_committed_ro" ]]; then
            while IFS=$'\t' read -r repo_name repo_path; do
                [[ -z "$repo_name" ]] && continue
                [[ -d "$repo_path/.cco" ]] && \
                    _compose_vol "${repo_path}/.cco" "/workspace/${repo_name}/.cco" "ro"
            done < <(_effective_repo_mounts "$project_yml")
        fi

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

# Generates pack metadata (packs.md, workspace.yml) and cleans legacy files.
# The two files are regenerable framework overlays (ADR-0005 F1): produced into
# claude_gen_dir (CACHE on a real start, the dump dir under --dry-run --dump) and
# mounted :ro by _start_generate_compose, never written into the committed tree.
_start_generate_metadata() {
    # Generate packs.md — instructional list of knowledge + llms files
    packs_md="$claude_gen_dir/packs.md"
    local has_knowledge=false has_llms=false

    # Check if there's any content to generate
    if [[ -n "$pack_names" ]]; then
        while IFS= read -r _pn; do
            [[ -z "$_pn" ]] && continue
            local _proot; _proot=$(_pack_resolve_dir "$_pn" "$project_dir")
            [[ -z "$_proot" ]] && continue
            local _pyml="$_proot/pack.yml"
            [[ -f "$_pyml" ]] && [[ -n "$(yml_get_pack_knowledge_files "$_pyml")" ]] && has_knowledge=true
        done <<< "$pack_names"
    fi
    local _llms_entries
    _llms_entries=$(_collect_llms_names "$project_yml" "$pack_names" "$project_dir")
    if [[ -n "$_llms_entries" ]]; then has_llms=true; fi

    if [[ "$has_knowledge" == "true" || "$has_llms" == "true" ]]; then
        echo "<!-- Auto-generated by cco start — do not edit manually -->" > "$packs_md"

        # Knowledge section
        if [[ "$has_knowledge" == "true" ]]; then
            echo "The following knowledge files provide project-specific conventions and context." >> "$packs_md"
            echo "Read the relevant files BEFORE starting any implementation, review, or design task." >> "$packs_md"
            echo "Do not ask the user for context that is covered by these files." >> "$packs_md"
            echo "" >> "$packs_md"
            while IFS= read -r pack_name; do
                [[ -z "$pack_name" ]] && continue
                local _pmroot; _pmroot=$(_pack_resolve_dir "$pack_name" "$project_dir")
                [[ -z "$_pmroot" ]] && continue
                local pack_yml="$_pmroot/pack.yml"
                [[ ! -f "$pack_yml" ]] && continue
                if ! grep -qE '^(name|knowledge|llms|skills|agents|rules):' "$pack_yml"; then
                    warn "Pack '$pack_name': pack.yml has no valid top-level keys — check for extra indentation."
                    continue
                fi
                local pack_files
                pack_files=$(yml_get_pack_knowledge_files "$pack_yml")
                if [[ -z "$pack_files" ]]; then continue; fi
                while IFS=$'\t' read -r fname fdesc; do
                    [[ -z "$fname" ]] && continue
                    if [[ -n "$fdesc" ]]; then
                        echo "- /workspace/.claude/packs/${pack_name}/${fname} — ${fdesc}" >> "$packs_md"
                    else
                        echo "- /workspace/.claude/packs/${pack_name}/${fname}" >> "$packs_md"
                    fi
                done <<< "$pack_files"
            done <<< "$pack_names"
        fi

        # LLMs section — use subshell capture to avoid bash 3.2 return-in-redirect bug
        if [[ "$has_llms" == "true" ]]; then
            local _llms_md
            _llms_md=$(_generate_llms_packs_md "$project_yml" "$pack_names" "$project_dir")
            if [[ -n "$_llms_md" ]]; then
                echo "$_llms_md" >> "$packs_md"
            fi
        fi

        local packs_md_lines
        packs_md_lines=$(grep -c '^- ' "$packs_md" 2>/dev/null || echo 0)
        ok "Generated .claude/packs.md (${packs_md_lines} file(s))"
    elif [[ -f "$packs_md" ]]; then
        rm -f "$packs_md"
    fi

    # Generate workspace.yml — structured project context for /init
    _generate_workspace_yml "$claude_gen_dir" "$project_name" "$project_yml" "$pack_names"

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
        [[ -f "$packs_md" ]]                          && info "  .claude/packs.md"
        [[ -f "$claude_gen_dir/workspace.yml" ]]      && info "  .claude/workspace.yml"
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
    local config_editor_target=""   # --project <name> for the config-editor built-in (ADR-0027 D1)

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from) [[ $# -lt 2 ]] && die "--from requires a <repo> name."; from_repo="$2"; shift 2 ;;
            --mount) [[ $# -lt 2 ]] && die "--mount requires <src>[:<target>][:ro|:rw]."; user_mounts+=("$2"); shift 2 ;;
            --enable-config-edit) enable_config_edit=true; shift ;;
            --project) [[ $# -lt 2 ]] && die "--project requires a <name> (config-editor project mode)."; config_editor_target="$2"; shift 2 ;;
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

Built-in sessions: 'cco start config-editor' opens the config-editor (edit your
~/.cco store); add --project <name> (or run from a configured repo) to also
mount that project's .cco/ for editing. 'cco start tutorial' opens the tutorial.

Options:
  --from <repo>        Use <repo>/.cco as the config source (Case-C divergence)
  --project <name>     config-editor only: also mount <name>'s .cco/ (rw)
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
  --enable-config-edit Allow the agent to edit this repo's committed .cco/ config
                       in this session (off by default — see 'cco start
                       config-editor' for the sanctioned config-editing session)
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
    local output_dir compose_file packs_md
    local config_dir session_state_dir session_cache_dir managed_gen_dir claude_gen_dir

    _start_resolve_project
    [[ "${CCO_DEBUG:-}" == "1" ]] && echo "[debug] resolve_project done" >&2

    _start_load_config
    [[ "${CCO_DEBUG:-}" == "1" ]] && echo "[debug] load_config done" >&2

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

    # Generate the .claude overlays (packs.md, workspace.yml) BEFORE compose so
    # compose can mount them :ro by existence — the same generate-then-mount
    # ordering used for the managed/ overlays (ADR-0005 F1).
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
