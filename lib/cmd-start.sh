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
    # host path is committed (AD3/G8). Read-only mounts (the tutorial never edits),
    # so the `store` role is inert here — but correct, and correctness at the
    # producer is what keeps the role a signal rather than a heuristic (RC-1 §3.3).
    _CCO_MOUNT_OVERRIDE=$(printf 'cco-config\t%s\tstore\ncco-docs\t%s\t' "$(_cco_config_dir)" "$REPO_ROOT/docs")

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
    # The third column is the mount ROLE (RC-1 §3.3): the authoritative "framework
    # generated this, and it exposes THIS config tree" signal that lets the nested
    # clamp resolve each synthetic mount against the axis naming the tree it
    # represents. cco-docs is role-less (and readonly: true anyway).
    _CCO_MOUNT_OVERRIDE=$(printf 'cco-config\t%s\tstore\ncco-docs\t%s\t' "$cfg" "$REPO_ROOT/docs")
    local _tn _tp
    while IFS=$'\t' read -r _tn _tp; do
        [[ -z "$_tn" ]] && continue
        _CCO_MOUNT_OVERRIDE+=$(printf '\n%s-config\t%s\tproject-config' "$_tn" "$_tp")
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
        # cco-config (~/.cco) readonly FOLLOWS the resolved G (WS-A 2026-07-11): rw only
        # when the session may WRITE the store (G=rw — global mode, edit-global, edit-all),
        # ro in project mode (G=ro) so the store is referenceable but not writable without
        # an explicit --cco-access edit-global. Shares the resolver via
        # _config_editor_mount_ro, so this mount and the operator-bucket /home/claude/.cco
        # (_op_rw) agree. This project.yml is generated BEFORE _start_resolve_access, but G
        # is fully determined by mode + CLI for a built-in, so the flag is knowable now.
        local _cc_ro; _cc_ro=$(_config_editor_mount_ro g)
        # Each target's <repo>/.cco readonly FOLLOWS Pc, from the same resolver (RC-1 §3.5).
        # It used to be hardcoded `false`, which was harmless only because
        # _find_nested_config_dirs matched the mount root and re-overlaid it :ro — the
        # accident that also clobbered Pc=rw (RC-1 defect a). With the root no longer swept
        # this flag is the target's only enforcement, so a granular current=ro must be
        # honoured here or removing the accident would ESCALATE privilege. Shipped modes
        # (project / --all / edit-global) all carry Pc=rw → unchanged `false`.
        local _tg_ro; _tg_ro=$(_config_editor_mount_ro pc)
        cat <<YAML
extra_mounts:
  - name: cco-config
    target: /workspace/cco-config
    readonly: ${_cc_ro}
  - name: cco-docs
    target: /workspace/cco-docs
    readonly: true
YAML
        while IFS=$'\t' read -r _tn _tp; do
            [[ -z "$_tn" ]] && continue
            cat <<YAML
  - name: ${_tn}-config
    target: /workspace/${_tn}-config
    readonly: ${_tg_ro}
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

# claude_access PRESET names (ADR-0049 §3): sugar over fixed (Cr,Cp,Cg,Co)
# triples. A source value may also be the granular map/CSV form; the Axis-B
# resolver (_claude_resolve_access, access-scope.sh) validates + resolves both,
# so this set is documentation of the preset vocabulary, not the validator.
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
    # Preset defaults (D6, revised by ADR-0042/0044): normal = repo/read-project/on
    # (was cco=none — the read-project default is what makes the on-demand
    # three-level model work: the agent can query its own environment via wrapped
    # cco, so Level A stays minimal). Built-ins define their own MOTIVATED presets
    # (ADR-0044 §1, read-only-vs-write): the tutorial is a read-only teacher →
    # read-all; config-editor WRITES config → minimum privilege by cwd/flag. These
    # become the level-4 default of the precedence chain (CLI still overrides).
    local _preset="${session_preset:-normal}"
    # claude_access (Axis B) no longer has a fixed preset default — it DERIVES from
    # the resolved cco triple (ADR-0049 §2), so only d_cco/d_shp are seeded here.
    local d_cco="read-project" d_shp="true"
    # Whether THIS session has a current project in scope (INV-2 conditional floor,
    # ADR-0046 §2 refinement). Fail-closed default `true`: a normal `cco start
    # <project>` always has one. Only a project-less built-in flips it (config-editor
    # global mode; future cco new) so its Pc may honestly floor to `none`.
    local _has_current_project="true"
    case "$_preset" in
        config-editor)
            # ADR-0044 §3, reconciled with the ADR-0046 ladder and the WS-A refinement
            # (2026-07-11): minimum-privilege by mode. The mode resolved from cwd + flags
            # (_resolve_config_editor_mode, run in _start_resolve_project before this)
            # sets both the TARGET set and the default triple:
            #   cwd-in-project / --project <name>  → (ro,rw,none): edit the target
            #     project(s) — all "current" for config-editor via _env_is_current_project
            #     — while READING the whole global store to reference it (G=ro). Writing
            #     ~/.cco is a distinct intent → --cco-access edit-global (rw,rw,none).
            #   outside any project (bare)         → (rw,none,none): edit the personal
            #     store ONLY; Pc has no referent (project-less → Pc honestly none).
            #   --all / --cco-access edit-all      → edit-all (every project, Po=rw).
            # G is clamped >= ro below (config-editor is an authoring tool — it must
            # always SEE the store, ADR-0044 §2 analogy). claude_access is NOT set
            # here: the general cco-derived Axis-B default (ADR-0049 §2/§8) subsumes the
            # former bespoke "claude follows G" (WS-A A-V3) — project mode (ro,rw,none)
            # derives (Cr=ro,Cp=rw,Cg=ro,Co=ro); edit-global (rw,rw,none) lifts Cg=rw;
            # edit-all lifts Co=rw. d_shp stays on. The by-mode default + project-less
            # flag come from the SINGLE source _config_editor_default_cco (shared with
            # the cco-config mount readonly, so the mount and the resolved triple never
            # diverge).
            d_shp="true"
            local _cedef; _cedef=$(_config_editor_default_cco)
            d_cco="${_cedef%%$'\t'*}"; _has_current_project="${_cedef##*$'\t'}" ;;
        tutorial)
            # ADR-0044 §2: read-only teacher → read-all reveals the user's whole
            # cco world (projects/packs/templates/llms) with no write risk (no
            # write verb is reachable). --cco-access can narrow, but is discouraged.
            d_cco="read-all"; d_shp="true" ;;   # claude derives → (ro,ro,ro,ro)=none
    esac

    # For a built-in the precedence collapses to CLI > preset: its generated
    # project.yml has no access: block, and the global ~/.cco/access.yml governs the
    # USER's own projects, not a framework built-in (so it must not, e.g., neuter
    # config-editor to none). A user can still narrow with an explicit --cco-access.
    # A normal session uses the full CLI > project.yml access: > global > preset.
    local p_claude="" p_cco="" p_shp="" g_claude="" g_cco="" g_shp=""
    # Granular MAP axes per source (ADR-0049 §9 / ADR-0046). project.yml: access.cco
    # and access.claude sub-keys (depth-3). ~/.cco/access.yml: cco.* and claude.*
    # sub-keys (depth-2 — the top-level key is at depth 1 there). A scalar and a map
    # are mutually exclusive on a key: when it is a map the scalar read is empty and
    # the map axes catch it, and vice-versa — so precedence just tries map before
    # scalar within each source's tier.
    local _mg="" _mc="" _mo=""                  # project.yml access.cco map
    local _clr="" _clc="" _clg="" _clo=""       # project.yml access.claude map (Cr,Cp,Cg,Co)
    local _gmg="" _gmc="" _gmo=""               # access.yml cco map
    local _gclr="" _gclc="" _gclg="" _gclo=""   # access.yml claude map
    if [[ "$_preset" == "normal" ]]; then
        # access.<key> is a 2-level block (2-space indent) → yml_get auto-depth 2
        # (NOT yml_get_deep, which forces depth 3 and would miss it).
        p_claude=$(yml_get "$project_yml" "access.claude" 2>/dev/null)
        p_cco=$(yml_get "$project_yml" "access.cco" 2>/dev/null)
        p_shp=$(yml_get "$project_yml" "access.show_host_paths" 2>/dev/null)
        _mg=$(yml_get_deep "$project_yml" "access.cco.global"  2>/dev/null)
        _mc=$(yml_get_deep "$project_yml" "access.cco.current" 2>/dev/null)
        _mo=$(yml_get_deep "$project_yml" "access.cco.others"  2>/dev/null)
        _clr=$(yml_get_deep "$project_yml" "access.claude.repo"    2>/dev/null)
        _clc=$(yml_get_deep "$project_yml" "access.claude.current" 2>/dev/null)
        _clg=$(yml_get_deep "$project_yml" "access.claude.global"  2>/dev/null)
        _clo=$(yml_get_deep "$project_yml" "access.claude.others"  2>/dev/null)
        local gfile; gfile=$(_cco_access_file)
        if [[ -f "$gfile" ]]; then
            g_claude=$(yml_get "$gfile" "claude" 2>/dev/null)
            g_cco=$(yml_get "$gfile" "cco" 2>/dev/null)
            g_shp=$(yml_get "$gfile" "show_host_paths" 2>/dev/null)
            _gmg=$(yml_get "$gfile" "cco.global"  2>/dev/null)
            _gmc=$(yml_get "$gfile" "cco.current" 2>/dev/null)
            _gmo=$(yml_get "$gfile" "cco.others"  2>/dev/null)
            _gclr=$(yml_get "$gfile" "claude.repo"    2>/dev/null)
            _gclc=$(yml_get "$gfile" "claude.current" 2>/dev/null)
            _gclg=$(yml_get "$gfile" "claude.global"  2>/dev/null)
            _gclo=$(yml_get "$gfile" "claude.others"  2>/dev/null)
        fi
    fi

    # ── cco access → the (G,Pc,Po) triple (ADR-0046) ─────────────────
    # A source's cco value is EITHER a scalar (a preset name OR the granular
    # "global=…,current=…,others=…" form) OR — project.yml only — the access.cco
    # MAP form (global/current/others sub-keys). Precedence unchanged (ADR-0036
    # D3): CLI > project.yml (scalar|map) > global scalar > preset default. The
    # winning source resolves to the triple (scalar → _cco_resolve_access; map →
    # _cco_promote_triple), which auto-promotes unspecified axes to the invariant
    # floor and REJECTS an explicit invariant-violating triple (§2, die → exit 1;
    # its message already reaches stderr, so we just propagate the exit). The bare
    # `read` alias is normalized inside the resolver (→ read-all). cco_access is
    # then the DISPLAY LABEL of the triple; cco_g/cco_pc/cco_po are the machine
    # source consumers derive from (INV-E). include_member_configs (§6) is an
    # additive project.yml bool (default false). Precedence within each tier tries the
    # granular MAP before the scalar; ~/.cco/access.yml gains its own map tier
    # (ADR-0049 §9), below the project scalar and above the global scalar. The map
    # axes were read above.
    # _has_current_project is threaded so the conditional INV-2 floor (§2) lets a
    # project-less session (config-editor global mode) floor Pc to `none`; every normal
    # session passes `true` and keeps the strict floor.
    local _cco_triple
    if   [[ -n "$cli_cco_access" ]]; then _cco_triple=$(_cco_resolve_access "$cli_cco_access" "$_has_current_project") || exit $?
    elif [[ -n "$_mg$_mc$_mo" ]];    then _cco_triple=$(_cco_promote_triple "$_mg" "$_mc" "$_mo" "$_has_current_project") || exit $?
    elif [[ -n "$p_cco" ]];          then _cco_triple=$(_cco_resolve_access "$p_cco" "$_has_current_project") || exit $?
    elif [[ -n "$_gmg$_gmc$_gmo" ]]; then _cco_triple=$(_cco_promote_triple "$_gmg" "$_gmc" "$_gmo" "$_has_current_project") || exit $?
    elif [[ -n "$g_cco" ]];          then _cco_triple=$(_cco_resolve_access "$g_cco" "$_has_current_project") || exit $?
    else                                  _cco_triple=$(_cco_resolve_access "$d_cco" "$_has_current_project") || exit $?
    fi
    read -r cco_g cco_pc cco_po <<< "$_cco_triple"

    # config-editor G-floor (WS-A / ADR-0044 §2 analogy): an authoring session must
    # always SEE the global store to reference/author against it, so G is never `none`
    # for config-editor. An explicit narrower override (e.g. --cco-access edit-project
    # → G=none) is clamped up to `ro`, with a one-line notice. This subsumes the old
    # F4 inert-edit-project case: (none,rw,none) becomes (ro,rw,none) — the project-mode
    # default — so ~/.cco stays readable (never writable unless G=rw).
    if [[ "$_preset" == "config-editor" && "$(_cco_axis_rank "$cco_g")" -lt 1 ]]; then
        echo "note: config-editor needs to read the global store to author against it — clamping cco_access global=none up to 'ro' (use --cco-access edit-global to also WRITE ~/.cco)." >&2
        cco_g="ro"
    fi
    cco_access=$(_cco_triple_label "$cco_g" "$cco_pc" "$cco_po")

    # ── claude access → the (Cr,Cp,Cg,Co) authoring triple (ADR-0049) ─
    # Axis B mirrors Axis A (§4bis). A source's claude value is a SCALAR (a preset
    # name OR the granular "repo=…,current=…,global=…,others=…" form) OR the
    # access.claude MAP form (sub-keys repo/current/global/others). Unspecified axes
    # DERIVE from the resolved cco triple (Cr always `ro`, §2), so the default is
    # never MORE permissive than the cco intent (P1). Precedence (§9): CLI >
    # project.yml access.claude (scalar|map) > ~/.cco/access.yml claude (scalar|map)
    # > cco-derived default. config-editor's former bespoke "claude follows G" is
    # GONE — the general derivation subsumes it (§8): project mode (ro,rw,none) →
    # (ro,rw,ro,ro); edit-global lifts Cg=rw; edit-all lifts Co=rw. The resolver dies
    # (exit 1) on a bad preset/token; propagate the exit. claude_access is then the
    # DISPLAY LABEL; claude_cr/cp/cg/co are the machine source consumers derive mount
    # modes from (INV-E). A map's omitted axes derive from cco just like a scalar's.
    local _claude_triple
    if   [[ -n "$cli_claude_access" ]];      then _claude_triple=$(_claude_resolve_access "$cli_claude_access" "$cco_g" "$cco_pc" "$cco_po") || exit $?
    elif [[ -n "$_clr$_clc$_clg$_clo" ]];    then _claude_triple=$(_claude_derive_triple "$_clr" "$_clc" "$_clg" "$_clo" "$cco_g" "$cco_pc" "$cco_po") || exit $?
    elif [[ -n "$p_claude" ]];               then _claude_triple=$(_claude_resolve_access "$p_claude" "$cco_g" "$cco_pc" "$cco_po") || exit $?
    elif [[ -n "$_gclr$_gclc$_gclg$_gclo" ]]; then _claude_triple=$(_claude_derive_triple "$_gclr" "$_gclc" "$_gclg" "$_gclo" "$cco_g" "$cco_pc" "$cco_po") || exit $?
    elif [[ -n "$g_claude" ]];               then _claude_triple=$(_claude_resolve_access "$g_claude" "$cco_g" "$cco_pc" "$cco_po") || exit $?
    else                                          _claude_triple=$(_claude_derive_triple "" "" "" "" "$cco_g" "$cco_pc" "$cco_po")
    fi
    read -r claude_cr claude_cp claude_cg claude_co <<< "$_claude_triple"
    claude_access=$(_claude_triple_label "$claude_cr" "$claude_cp" "$claude_cg" "$claude_co")

    # P2 discordance warning (ADR-0049 §4): the resolved Axis B grants MORE .claude
    # write than the cco-concordant default on a tree that lives inside .cco (Cp/Cg/Co
    # vs Pc/G/Po). Awareness, never a refusal — the knobs stay orthogonal explicit
    # choices. A derived triple is concordant by construction (never fires); only an
    # explicit preset/override wider than cco does. Cr never warns (no cco counterpart).
    if _claude_discordant "$claude_cr" "$claude_cp" "$claude_cg" "$claude_co" "$cco_g" "$cco_pc" "$cco_po"; then
        echo "note: claude_access ($claude_access) authors .claude more broadly than cco_access ($cco_access) reads/writes .cco config — explicit discordance, allowed (ADR-0049 §4). Align the two to silence this note." >&2
    fi

    # access.cco.include_member_configs (ADR-0046 §6, additive, default false):
    # when true, Pc's rw span widens from the hosting repo's <repo>/.cco to ALL
    # member repos' divergent .cco copies. project.yml only (a per-project mount
    # decision); a code-level default handles its absence (no migration).
    if [[ "$_preset" == "normal" ]]; then
        local _imc; _imc=$(_access_norm_bool "$(yml_get_deep "$project_yml" "access.cco.include_member_configs" 2>/dev/null)" 2>/dev/null) || _imc=""
        [[ -n "$_imc" ]] && cco_include_member_configs="$_imc"
    fi

    local shp_raw shp_norm
    shp_raw=$(_access_pick "$cli_show_host_paths" "$p_shp" "$g_shp" "$d_shp")
    shp_norm=$(_access_norm_bool "$shp_raw") \
        || die "Invalid show_host_paths '$shp_raw' (expected: true|false / on|off)."
    show_host_paths="$shp_norm"

    [[ "${CCO_DEBUG:-}" == "1" ]] && \
        echo "[debug] access: claude=$claude_access cco=$cco_access show_host_paths=$show_host_paths (G=$cco_g Pc=$cco_pc Po=$cco_po) (Cr=$claude_cr Cp=$claude_cp Cg=$claude_cg Co=$claude_co)" >&2
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

# ── Functional-write floor: settings.local.json overlay (ADR-0049 §5) ──
# Claude Code writes "Always allow" / local runtime state (autoMode, model) to a
# .claude/settings.local.json; when the parent .claude tree is mounted :ro (Cp/Cr
# read-only), that write would hit a read-only filesystem. Keep JUST that file
# writable via a rw CHILD overlay bound from a machine-local STATE source (Docker
# applies the deeper child mount after the :ro parent, so the child's rw wins).
#
# The child mount needs BOTH ends to exist as files:
#   - the STATE source, and
#   - the MOUNTPOINT itself, inside the :ro parent. Docker/runc cannot create it
#     there (`mknod ... read-only file system` — the container then fails to
#     start), so cco must seed it host-side, in the mount's backing directory,
#     BEFORE the bind. Ordering alone is not enough: the target must pre-exist.
# The stub is inert — the rw STATE bind always shadows it, so its content never
# reaches the session; it is gitignored, so nothing leaks into the repo.
#
# STATE is seeded FROM the mountpoint, so a pre-existing settings.local.json (a
# repo that already carried real local prefs before this overlay existed) keeps
# its content on first start instead of being shadowed by an empty `{}`. From
# then on STATE is the live copy and the stub stays frozen.
# All seeding is skipped on dry-run — the dumped compose is never executed.
# Args: <state_source> <host_mountpoint> <container_target> <dry_run:true|false>.
_emit_local_settings_overlay() {
    local src="$1" mp="$2" tgt="$3" dry="$4"
    if [[ "$dry" != "true" ]]; then
        # Mountpoint stub inside the :ro-to-be parent (its dir is the mount source,
        # so it exists; a missing one means a caller bug, and the bind fails loudly).
        [[ -f "$mp" ]] || printf '{}\n' > "$mp" 2>/dev/null || true
        # STATE source, seeded from the mountpoint (see above).
        mkdir -p "$(dirname "$src")" 2>/dev/null || true
        [[ -f "$src" ]] || cp "$mp" "$src" 2>/dev/null || printf '{}\n' > "$src" 2>/dev/null || true
    fi
    _compose_vol "$src" "$tgt"
}

# ── Recursive nested-config detection (ADR-0049 §7) ──────────────────
# Claude Code discovers nested .claude natively, so a monorepo's packages/x/.claude
# (and a member's .cco with a project.yml) escape a root-only overlay. Emit the
# path of each directory named <base> under <root>, RELATIVE to <root>, one per
# line — bounded (maxdepth) and pruned (heavy/irrelevant dirs) so the per-start
# scan stays cheap. When <require_file> is given only dirs containing that file
# qualify (e.g. .cco carrying a project.yml). Args: <root> <base> [<require_file>].
#
# INVARIANT: this NEVER returns the search root itself (rel would be empty). Its
# domain is dirs strictly BELOW <root>. The root's own mode is governed by the
# mount that produced it — ADR-0049 §7, "the mount's own readonly: flag governs
# everything else" — never by the nested clamp. Consequence: EVERY producer of a
# config mount owns its own `readonly:` (see _config_editor_mount_ro), because
# nothing re-clamps the root behind its back. `-mindepth 1` enforces this at the
# find level; the bash guard restates it so the contract survives a find edit.
_find_nested_config_dirs() {
    local root="$1" base="$2" require_file="${3:-}" d rel
    [[ -d "$root" ]] || return 0
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        [[ -n "$require_file" && ! -f "$d/$require_file" ]] && continue
        rel="${d#"$root"}"; rel="${rel#/}"
        [[ -z "$rel" ]] && continue          # the search root itself — not nested
        printf '%s\n' "$rel"
    done < <(find "$root" -mindepth 1 -maxdepth 6 \
                \( -name .git -o -name node_modules -o -name .venv -o -name venv \
                   -o -name vendor -o -name target -o -name dist -o -name build \) -prune -o \
                -type d -name "$base" -print 2>/dev/null | sort)
}

# _nc_emit <claude_axis> <cco_axis> — an axis of "rw" yields "rw"; "ro" AND
# "none" both yield "ro". Fail-closed: an axis that grants no access must never
# produce a writable overlay.
_nc_emit() {
    local c="ro" o="ro"
    [[ "$1" == "rw" ]] && c="rw"
    [[ "$2" == "rw" ]] && o="rw"
    printf '%s\t%s' "$c" "$o"
}

# The SINGLE source for "what mode do nested config trees inside an extra_mount
# take?" — the predicate that three call sites had inlined and let drift apart.
# Pure: every input is an argument, so it is unit-testable in isolation.
#
# Echoes "<claude_mode>\t<cco_mode>". Each field is the LITERAL "ro" (emit a :ro
# overlay) or "rw" (leave writable) — TOTAL, never empty, so the record is safe
# under any reader and self-describing at the call site. Consumers still peel with
# _peel_tab (the repo rule for TAB records, and the guard that survives a future
# contributor reintroducing an empty field), and compare == "ro", not -n.
#
# Args: <mount_ro> <policy> [<role>] [<ktriple>] [<ctriple>]
#   role ∈ ''(user mount) | store | project-config     — see _mount_override_role
#   ktriple = "Cr,Cp,Cg,Co"    ctriple = "G,Pc,Po"
#
# Why the axis is keyed by ROLE (ADR-0049 §7 / D-M5): a framework-synthetic config
# mount is governed by the session triple for the tree it REPRESENTS. Routing it
# through the existing `project` policy instead would map .claude to Cr — which
# ADR-0049 pins at `ro` for every session — so ~/.cco/.claude would stay clamped
# forever and Cg=rw would remain unenforced (E6A-12, E6B-02). A user extra_mount
# is not a config tree and keeps the strict `ro` default (D-M1).
_nested_config_modes() {
    local mro="$1" policy="$2" role="${3:-}" ktriple="${4:-}" ctriple="${5:-}"
    local cr cp cg co g pc po
    # Comma is NOT IFS whitespace, so empty axes are preserved here (unlike tab).
    IFS=, read -r cr cp cg co <<< "$ktriple"
    IFS=, read -r g  pc po    <<< "$ctriple"
    # A :ro mount already locks everything; `write` opts out wholesale.
    [[ "$mro" == "true" || "$policy" == "write" ]] && { printf 'rw\trw'; return 0; }
    case "$policy" in
        project) _nc_emit "$cr" "$pc"; return 0 ;;   # unchanged: repo-native axes
    esac
    # policy = ro (the default).
    case "$role" in
        store)          _nc_emit "$cg" "$g"  ;;     # ~/.cco      → Cg / G
        project-config) _nc_emit "$cp" "$pc" ;;     # <repo>/.cco → Cp / Pc
        *)              printf 'ro\tro'     ;;      # user extra_mount — UNCHANGED
    esac
    return 0
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

# Resolve the config-editor session's minimum-privilege MODE (ADR-0044 §3) from
# the CLI flags + cwd, ONCE, so both the preset cco_access default
# (_start_resolve_access) and the mounted target set
# (_start_collect_config_editor_targets) derive from the same decision. Sets
# config_editor_mode ∈ all|project|global and, for the cwd-project case,
# config_editor_cwd_dir (the hosting repo dir). Precedence:
#   all      → --all OR --cco-access edit-all (the explicit broad wideners)
#   project  → named --project targets, ELSE a cwd inside a project
#   global   → outside any project (bare) — ~/.cco only, no project trees
# Shares cmd_start scope.
_resolve_config_editor_mode() {
    config_editor_mode="global"
    config_editor_cwd_dir=""
    if [[ "$config_editor_all" == true || "$cli_cco_access" == "edit-all" ]]; then
        config_editor_mode="all"
    elif [[ ${#config_editor_targets[@]} -gt 0 ]]; then
        config_editor_mode="project"
    elif config_editor_cwd_dir=$(_resolve_find_unit_dir 2>/dev/null); then
        config_editor_mode="project"
    else
        config_editor_cwd_dir=""
        config_editor_mode="global"
    fi
}

# The config-editor by-mode DEFAULT cco intent (SINGLE source, WS-A 2026-07-11). Emits
# "<intent>\t<has_current_project>" for the resolved config_editor_mode. Both
# _start_resolve_access (the session triple) and _config_editor_mount_ro (the generated
# mounts' readonly) read it, so the mount mode and the resolved triple never diverge:
#   project  → (ro,rw,none): edit the target project(s), READ the whole store to reference.
#   all      → edit-all (rw,rw,rw): every project + store.
#   global   → (rw,none,none): edit ONLY the store; project-less (Pc has no referent).
# Reads cmd_start local config_editor_mode.
_config_editor_default_cco() {
    case "${config_editor_mode:-global}" in
        all)     printf 'edit-all\ttrue' ;;
        project) printf 'global=ro,current=rw,others=none\ttrue' ;;
        *)       printf 'global=rw,current=none,others=none\tfalse' ;;
    esac
}

# _config_editor_mount_ro <axis> → "true"/"false": is a GENERATED config-editor mount
# READ-ONLY for this session? The mount is writable iff the triple axis that names the
# tree it exposes is rw:
#   g   → cco-config    (~/.cco, the personal store)      — the whole point of the session
#   pc  → <name>-config (a target project's <repo>/.cco)  — classified `current` (ADR-0048)
# Both mounts are ROOTS, and since _find_nested_config_dirs stopped sweeping roots this
# flag is their ONLY physical enforcement — a hardcoded value here is a declared-vs-
# enforced defect (RC-1 §3.5). Keying the root to the same axis as the nested clamp
# (_nested_config_modes' store / project-config roles) means root and nested trees of one
# mount cannot contradict each other.
# For a built-in the only cco_access sources are the CLI override and the by-mode default
# (project.yml/access.yml bypassed for built-ins), so the triple is fully determined here —
# the SAME inputs _start_resolve_access resolves, hence the mount and the triple agree,
# even though this runs BEFORE it. Fails safe to read-only. Reads cmd_start locals
# config_editor_mode, cli_cco_access.
_config_editor_mount_ro() {
    local axis="${1:-g}"
    local intent plflag g pc po _def
    _def=$(_config_editor_default_cco)
    intent="${_def%%$'\t'*}"; plflag="${_def##*$'\t'}"
    [[ -n "$cli_cco_access" ]] && intent="$cli_cco_access"   # CLI > by-mode default
    local triple; triple=$(_cco_resolve_access "$intent" "$plflag" 2>/dev/null) || { printf 'true'; return; }
    read -r g pc po <<< "$triple"
    local val; case "$axis" in pc) val="$pc" ;; *) val="$g" ;; esac
    [[ "$val" == "rw" ]] && printf 'false' || printf 'true'
}

# Collect the config-editor's edit targets + repo mounts (ADR-0042 §8 / ADR-0044
# §3). Sets the shared _ce_targets (newline-joined "name<TAB><repo>/.cco") and
# _ce_repos (newline-joined repo logical names), keyed off the mode resolved by
# _resolve_config_editor_mode:
#   NARROW (`--project <name>`, repeatable) → those projects' <repo>/.cco PLUS
#     each project's resolvable repos (repo-aware authoring). Each --project MUST
#     resolve — dies otherwise.
#   ALL (`--all` / `--cco-access edit-all`) → every resolvable project's
#     <repo>/.cco, NO repos. Broad config editing — the explicit widener.
#   PROJECT via cwd (bare inside a project) → the cwd project's <repo>/.cco PLUS
#     its resolvable repos (like a single --project).
#   GLOBAL (bare outside any project) → NO project targets (~/.cco only).
#   `--repo <name>` (repeatable, any mode) adds one resolvable repo to the set.
#
# Repos are an EXPLICIT opt-in (P18 refined, not broken — design §8): --all mounts
# no code, only <repo>/.cco config. Shares cmd_start scope; reads config_editor_*.
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
    elif [[ "$config_editor_mode" == "all" ]]; then
        # ALL (--all / --cco-access edit-all): every resolvable project's .cco, no repos.
        while IFS=$'\t' read -r name path _; do
            [[ -z "$name" ]] && continue
            [[ -d "$path/.cco" ]] || continue
            _ce_targets+="${name}"$'\t'"${path}/.cco"$'\n'
        done < <(_project_foreach)
    elif [[ "$config_editor_mode" == "project" && -n "$config_editor_cwd_dir" ]]; then
        # PROJECT (bare inside a project): the cwd project's .cco + its repos.
        name=$(yml_get "$config_editor_cwd_dir/.cco/project.yml" name 2>/dev/null)
        [[ -n "$name" && -d "$config_editor_cwd_dir/.cco" ]] \
            && _ce_targets+="${name}"$'\t'"${config_editor_cwd_dir}/.cco"$'\n'
        while IFS=$'\t' read -r rn rp; do
            _ce_add_repo "$rn"
        done < <(_effective_repo_mounts "$config_editor_cwd_dir/.cco/project.yml")
    fi
    # else: mode=global (bare outside any project) → no project targets, ~/.cco only.
    # --repo <name>: add a single resolvable repo (fine-grained reference mount).
    for t in ${config_editor_repos[@]+"${config_editor_repos[@]}"}; do
        # config-editor --repo is a cross-project reference (no single current
        # project) — resolve the bare name across all projects (ADR-0051).
        path=$(_index_get_path_any "$t")
        [[ "$path" == /* && -d "$path" ]] \
            || die "config-editor --repo '$t' is not resolvable on this machine. Run 'cco resolve' first."
        _ce_add_repo "$t"
    done
}

# Fail loud, don't launch inert (F4). A config-editor session that intends a PROJECT
# write (Pc=rw) but for which the mode/collector resolved ZERO project targets, and
# whose G is not rw either, can write NOTHING: no <repo>/.cco is mounted (no target)
# and G!=rw rules out the personal store. Post-clamp (WS-A) the reachable inert triple
# is (ro,rw,none) — an explicit `--cco-access edit-project` (or current=rw) issued
# outside any project; the G>=ro clamp turns the old (none,rw,none) into (ro,rw,none),
# so the guard keys off Pc/Po/targets, NOT G=none. edit-global (G=rw) can always write
# ~/.cco → never inert, never guarded; the project-mode default (ro,rw,none) always has
# a resolved target → never guarded.
# Reads cmd_start locals (session_preset, cco_g/pc/po, _ce_targets); no side effects.
_start_guard_config_editor_scope() {
    [[ "${session_preset:-}" == "config-editor" ]] || return 0
    [[ "$cco_pc" == rw && "$cco_g" != rw && "$cco_po" == none ]] || return 0
    [[ -z "${_ce_targets:-}" ]] || return 0
    die "config-editor --cco-access edit-project needs a project to edit, but none was resolved.
  You are outside a project and passed no --project. Fix one of:
    • cd into a project's repo (its <repo>/.cco becomes the target), or
    • pass --project <name> (repeatable), or
    • use --cco-access edit-global to edit the personal store (~/.cco) only."
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
        session_preset="config-editor"     # preset: min-privilege by mode (ADR-0044 §3)
        # Scope (ADR-0044 §3): minimum privilege by cwd/flag. Resolve the mode ONCE
        # (all|project|global) so the preset cco_access default (_start_resolve_access)
        # and the mounted targets below agree. cwd-in-project → edit-project (its
        # .cco + repos); outside → edit-global (~/.cco only); --all / --cco-access
        # edit-all → edit-all (every project's .cco); --project → targeted.
        # The collector sets _ce_targets (newline name<TAB>cco_path) + _ce_repos
        # (newline repo names) directly via shared scope so its die() propagates
        # (bash 3.2 has no namerefs, and a $() subshell would swallow the die).
        # _ce_targets/_ce_repos are declared at cmd_start scope (NOT here) so their
        # value survives into _start_generate_compose (CCO_CONFIG_TARGETS + the R2
        # descriptor read them); reset before collecting.
        _resolve_config_editor_mode
        _ce_targets="" _ce_repos=""
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
            # Cross-project by-name lookup (no project context in hand yet).
            unit_dir=$(_index_get_path_any "$from_repo") \
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

    # Trusted session descriptor host path (ADR-0047 R2). Kept OUT of the managed
    # overlay dir (which is bulk-mounted :ro at /workspace/.managed) so it surfaces
    # ONLY at /etc/cco/session-access. Written in the operator env block below (it
    # needs the resolved scope + membership) and mounted :ro there.
    local session_descriptor
    if $dry_run; then session_descriptor="$output_dir/.cco/session-access"
    else session_descriptor="$session_cache_dir/session-access"; fi

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

        # Mount modes derived ONCE from the resolved (G,Pc,Po) triple (ADR-0046 §7;
        # access-scope.sh is the single source, INV-E). Each axis drives one mount
        # decision — no {project,global,all} ordinal in between:
        #   Pc=rw  → the current project's <repo>/.cco (A1) is editable.
        #   G=rw   → the personal store ~/.cco + DATA/CACHE (A2) are editable.
        #   G=none → the CONFIG mount is NARROWED to referenced packs (the rest of
        #            the store stays physically hidden); G≥ro mounts the whole store.
        # This is where edit-global's redefined (rw,rw,none) takes effect — Pc=rw
        # now unlocks A1, which the old (rw,ro,none) kept :ro.
        local _pc_rw="false" _g_rw="false" _g_none="false"
        [[ "$cco_pc" == "rw"   ]] && _pc_rw="true"
        [[ "$cco_g"  == "rw"   ]] && _g_rw="true"
        [[ "$cco_g"  == "none" ]] && _g_none="true"

        # Container-operator mode (ADR-0036 D4): under cco_access >= read, the
        # in-container cco runs behind the whitelist shim, operating on the real
        # buckets bind-mounted below (never the container's own $HOME). The flag +
        # the three CCO_*_HOME overrides together are what _cco_container_operator
        # keys on; CCO_CCO_ACCESS tells the shim which write verbs to allow. CONFIG
        # (~/.cco) needs no override — it is mounted at the natural $HOME/.cco.
        if [[ "$cco_access" != "none" ]]; then
            echo "      - CCO_CONTAINER_OPERATOR=1"
            # CCO_ACCESS_TRIPLE is the (G,Pc,Po) the in-container layer derives every
            # scope decision from (INV-E); CCO_CCO_ACCESS is its display label. NOTE
            # (ADR-0047): the outer, claude-side cco reads these from the env, but the
            # env is agent-mutable and is only an EARLY UX gate. The AUTHORITATIVE copy
            # for every elevated store operation is the cco-svc-owned :ro session
            # descriptor written below (the setuid helper injects it), so an agent
            # cannot forge a wider scope across the boundary.
            echo "      - CCO_ACCESS_TRIPLE=${cco_g},${cco_pc},${cco_po}"
            echo "      - CCO_CCO_ACCESS=${cco_access}"
            # Internal-store bucket homes now point UNDER the cco-svc privileged root
            # (ADR-0047): the claude user cannot traverse it, so the outer cco only
            # builds path strings — actual store IO is elevated via the helper. The
            # resolvers skip _cco_ensure_dir under these in operator mode (the buckets
            # are bind-mounted below). CONFIG (~/.cco) is unaffected (natural $HOME).
            echo "      - CCO_DATA_HOME=/var/lib/cco-internal/share/cco"
            echo "      - CCO_STATE_HOME=/var/lib/cco-internal/state/cco"
            echo "      - CCO_CACHE_HOME=/var/lib/cco-internal/cache/cco"
            # Session-state introspection (F4): the other two resolved knobs, so the
            # in-container introspection verb can report the full session state
            # (ADR-0043 deferred these "until a verb needs them" — it now does).
            echo "      - CCO_CLAUDE_ACCESS=${claude_access}"
            # CCO_CLAUDE_TRIPLE is the resolved (Cr,Cp,Cg,Co) Axis-B triple (ADR-0049);
            # CCO_CLAUDE_ACCESS is its display label. whoami renders both.
            echo "      - CCO_CLAUDE_TRIPLE=${claude_cr},${claude_cp},${claude_cg},${claude_co}"
            echo "      - CCO_SHOW_HOST_PATHS=${show_host_paths}"
            # config-editor editing targets (D9): PROJECT_NAME stays the started
            # project (config-editor); CCO_CONFIG_TARGETS carries the names whose
            # .cco this session may edit, so the resolver (layout 2) and the managed
            # rule can introspect the TARGET, never overloading PROJECT_NAME.
            local _cfg_targets_csv=""
            if [[ -n "${_ce_targets:-}" ]]; then
                _cfg_targets_csv=$(printf '%s' "$_ce_targets" | awk -F'\t' 'NF{printf "%s%s",(n++?",":""),$1}')
            fi
            [[ -n "$_cfg_targets_csv" ]] && echo "      - CCO_CONFIG_TARGETS=${_cfg_targets_csv}"
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

            # ── Trusted session descriptor (ADR-0047 R2) ─────────────────
            # The setuid helper reads THIS file — never argv/env — to derive the
            # (G,Pc,Po) scope + membership for every elevated store operation, so an
            # agent cannot forge a wider scope. Written host-side and bind-mounted :ro
            # at /etc/cco/session-access below. Keys mirror the helper's whitelist; the
            # value set is exactly the trusted scoping inputs (an inner redirect, so
            # this does NOT leak into the compose stream). Empty CSVs are fine — an
            # empty injected var reads the same as absent to the scope layer.
            mkdir -p "$(dirname "$session_descriptor")"
            {
                printf 'CCO_ACCESS_TRIPLE=%s,%s,%s\n' "$cco_g" "$cco_pc" "$cco_po"
                printf 'CCO_CCO_ACCESS=%s\n' "$cco_access"
                printf 'PROJECT_NAME=%s\n' "$project_name"
                printf 'CCO_SHOW_HOST_PATHS=%s\n' "$show_host_paths"
                printf 'CCO_PROJECT_PACKS=%s\n' "$_op_packs_csv"
                printf 'CCO_PROJECT_LLMS=%s\n' "$_op_llms_csv"
                printf 'CCO_CONFIG_TARGETS=%s\n' "$_cfg_targets_csv"
            } > "$session_descriptor"
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
        # Driven by the resolved capability knobs. claude_access is now the per-tree
        # triple (Cr,Cp,Cg,Co) (ADR-0049) — each axis drives ONE mount decision, no
        # coarse enum in between (the label is display-only). cco_access governs the
        # <repo>/.cco structural overlay (A1). The host IDE is unaffected.
        #
        #   Cp → B2 project /workspace/.claude      : ro ⇒ mounted :ro
        #   Cg → B3 global  ~/.cco/.claude authoring : ro ⇒ CLAUDE.md/rules/… :ro
        #   Cr → B1 repo-native <repo>/.claude       : ro ⇒ :ro overlay on the repo
        # settings.json is ALWAYS rw (Claude Code writes runtime prefs like /effort —
        # a functional need, not authoring). The functional-write floor also keeps
        # settings.local.json writable via a rw child overlay when B2/B1 is :ro
        # (ADR-0049 §5) — emitted next to each tree below.
        local _b2_mode="" _b3_auth_mode="" _b1_ro=""
        [[ "$claude_cp" == "ro" ]] && _b2_mode="ro"
        [[ "$claude_cg" == "ro" ]] && _b3_auth_mode="ro"
        [[ "$claude_cr" == "ro" ]] && _b1_ro=":ro"
        # Axis A (write_scope): the committed <repo>/.cco structural config
        # (project.yml, secrets.env, .cco metadata) is overlaid READ-ONLY unless the
        # session's write_scope grants the project tree (edit-project / edit-all).
        # edit-global keeps A1 ro — only the personal store (A2) is writable there.
        # Keyed off write_scope now (ADR-0043) so the overlay and the operator-bucket
        # RW below share one source. config-editor resolves to edit-all via its
        # preset (its edit targets mount via generated extra_mounts, not this loop).
        local _committed_ro=":ro"
        if [[ "$_pc_rw" == "true" ]]; then
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
        # prefs); the authoring tree (CLAUDE.md/rules/agents/skills) is rw only when
        # Cg=rw, ro otherwise (_b3_auth_mode, ADR-0049 §2).
        echo "      # Global config B3 (settings.json always rw; authoring tree mode from claude Cg)"
        _compose_vol "${global_claude}/settings.json" "/home/claude/.claude/settings.json"
        _compose_vol "${global_claude}/CLAUDE.md" "/home/claude/.claude/CLAUDE.md" "${_b3_auth_mode}"
        _compose_vol "${global_claude}/rules" "/home/claude/.claude/rules" "${_b3_auth_mode}"
        _compose_vol "${global_claude}/agents" "/home/claude/.claude/agents" "${_b3_auth_mode}"
        _compose_vol "${global_claude}/skills" "/home/claude/.claude/skills" "${_b3_auth_mode}"
        # Project config B2 (/workspace/.claude). Mode from claude Cp (_b2_mode: rw
        # when Cp=rw, ro otherwise — ADR-0049 reverses P17, so a normal read-project
        # session is ro). The structural framework config (project.yml/secrets/.cco
        # metadata) is protected separately by the <repo>/.cco overlay below (Axis A).
        echo "      # Project config B2 (/workspace/.claude — mode from claude Cp; .cco metadata overlay below per cco_access)"
        _compose_vol "${claude_src}" "/workspace/.claude" "${_b2_mode}"
        # Functional-write floor (ADR-0049 §5): when B2 is :ro, keep settings.local.json
        # writable via a rw child overlay from per-project STATE.
        if [[ "$_b2_mode" == "ro" ]]; then
            _emit_local_settings_overlay "${session_state_dir}/local-settings/workspace.json" \
                "${claude_src}/settings.local.json" \
                "/workspace/.claude/settings.local.json" "$dry_run"
        fi
        _compose_vol "${project_dir}/project.yml" "/workspace/project.yml" "ro"
        # Claude state: session transcripts (machine-local STATE; enables /resume across rebuilds)
        echo "      # Claude state: session transcripts (machine-local STATE; /resume across rebuilds)"
        _compose_vol "$(_cco_project_session_transcripts "$project_name")" "/home/claude/.claude/projects/-workspace"
        # Memory: auto memory files (machine-local STATE, separate from transcripts)
        echo "      # Memory: auto memory files (machine-local STATE, separate from transcripts)"
        _compose_vol "$(_cco_project_session_memory "$project_name")" "/home/claude/.claude/projects/-workspace/memory"

        # ── Container-operator buckets (wrapped-cco — ADR-0036 D4 / ADR-0047) ──
        # Under cco_access >= read the in-container cco (behind the whitelist shim)
        # operates on the real buckets, never the container's own $HOME. Two distinct
        # trees with OPPOSITE confinement models (ADR-0047 §1):
        #
        #  • CONFIG CONTENT — A2 `~/.cco` (packs/templates/global .claude). Read
        #    NATIVELY by Claude Code as files, so it MUST stay mounted at the natural
        #    $HOME/.cco. Confined the same way as before: the read-project narrowing
        #    (referenced packs only), secret-masking, and the :ro/:rw write flag. NOT
        #    the leak surface — unchanged here.
        #
        #  • INTERNAL STORE — the STATE index, DATA registries, CACHE llms. Read ONLY
        #    by cco, and the carrier of the cross-project + host-path confidential data
        #    (the S1/S1b leak). These now mount UNDER the cco-svc privileged root
        #    /var/lib/cco-internal (units 1-2), which the claude user cannot traverse.
        #    Because the parent boundary confines reads and the setuid helper's
        #    (G,Pc,Po) gate is the write authority (ADR-0047 §4), they may mount WHOLE
        #    + rw — the former read-project ro-narrowing of the internal registries is
        #    dropped. Secrets stay OFF the container: the 0600 STATE remotes-token,
        #    transcripts and memory are never mounted (only the STATE index file
        #    crosses). Built-in presets (config-editor/tutorial) layer on this; a
        #    normal session opts in via --cco-access read|edit-*.
        if [[ "$cco_access" != "none" ]]; then
            local _op_rw="ro"
            [[ "$_g_rw" == "true" ]] && _op_rw=""
            echo "      # Container-operator buckets (wrapped-cco — ADR-0036 D4)"
            if [[ "$_g_none" == "true" ]]; then
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
            # Internal-store registries → UNDER the cco-svc privileged root (ADR-0047
            # §4): whole + rw, no :ro flag and no read-project narrowing (the parent
            # boundary confines reads; the helper's (G,Pc,Po) gate is the write
            # authority). Secrets excluded — the 0600 remotes-token (STATE) and
            # transcripts/memory never mount; only the STATE index FILE crosses.
            echo "      # Internal store (STATE index + DATA + CACHE) — cco-svc boundary (ADR-0047)"
            local _op_data; _op_data=$(_cco_data_dir)
            [[ -d "$_op_data" ]] && _compose_vol "$_op_data" "/var/lib/cco-internal/share/cco"
            [[ -f "${state_root}/index" ]] && \
                _compose_vol "${state_root}/index" "/var/lib/cco-internal/state/cco/index"
            local _op_llms; _op_llms=$(_cco_llms_dir)
            [[ -d "$_op_llms" ]] && _compose_vol "$_op_llms" "/var/lib/cco-internal/cache/cco/llms"
            # Session running registry (ADR-0045, refined by ADR-0047): host-written
            # markers, mounted :ro UNDER the boundary. Filenames are project names
            # (S1-confidential) → NOT a claude-readable mount; read only inside the
            # elevated `cco __store list/show`, gated by _env_in_scope. Create the host
            # dir so the :ro source exists on a first-ever start.
            local _op_running; _op_running=$(_cco_running_dir)
            mkdir -p "$_op_running" 2>/dev/null || true
            [[ -d "$_op_running" ]] && \
                _compose_vol "$_op_running" "/var/lib/cco-internal/state/cco/running" "ro"
            # Trusted session descriptor (ADR-0047 R2): :ro so the agent cannot forge a
            # wider scope (the :ro flag is VFS-level, fakeowner-independent). The setuid
            # helper reads it to gate every elevated store op. Written above.
            [[ -f "$session_descriptor" ]] && \
                _compose_vol "$session_descriptor" "/etc/cco/session-access" "ro"
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

        # Axis-B1 lockdown (Cr=ro — now the DEFAULT, ADR-0049 §2): overlay each repo's
        # native <repo>/.claude :ro on top of the rw repo mount, so the repo's own
        # authoring config is read-only. No overlay when Cr=rw (explicit repo/all),
        # where B1 stays rw as part of the repo mount. The functional-write floor
        # (ADR-0049 §5) keeps settings.local.json writable via a rw child overlay from
        # per-project STATE, so a session that authors inside a repo can still persist
        # local runtime state under the :ro tree.
        if [[ -n "$_b1_ro" ]]; then
            local _cl_rel
            while IFS=$'\t' read -r repo_name repo_path; do
                [[ -z "$repo_name" ]] && continue
                # Recursive (ADR-0049 §7): root <repo>/.claude AND any nested
                # packages/*/.claude a monorepo carries. rel ".claude" is the root.
                while IFS= read -r _cl_rel; do
                    [[ -z "$_cl_rel" ]] && continue
                    _compose_vol "${repo_path}/${_cl_rel}" "/workspace/${repo_name}/${_cl_rel}" "ro"
                    # Functional-write floor only at the repo-root tree (where a
                    # session started in the repo would write settings.local.json).
                    [[ "$_cl_rel" == ".claude" ]] && \
                        _emit_local_settings_overlay "${session_state_dir}/local-settings/repo-${repo_name}.json" \
                            "${repo_path}/.claude/settings.local.json" \
                            "/workspace/${repo_name}/.claude/settings.local.json" "$dry_run"
                done < <(_find_nested_config_dirs "$repo_path" ".claude")
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
            local _cc_rel
            while IFS=$'\t' read -r repo_name repo_path; do
                [[ -z "$repo_name" ]] && continue
                # Recursive (ADR-0049 §7): the root <repo>/.cco (always — the project's
                # committed config) plus any NESTED .cco that carries a project.yml (a
                # monorepo member's config). A nested .cco WITHOUT a project.yml is left
                # untouched (not a cco project tree).
                while IFS= read -r _cc_rel; do
                    [[ -z "$_cc_rel" ]] && continue
                    [[ "$_cc_rel" != ".cco" && ! -f "${repo_path}/${_cc_rel}/project.yml" ]] && continue
                    _compose_vol "${repo_path}/${_cc_rel}" "/workspace/${repo_name}/${_cc_rel}" "ro"
                done < <(_find_nested_config_dirs "$repo_path" ".cco")
            done < <(_effective_repo_mounts "$project_yml")
        fi
        # NOTE (ADR-0046 §6 multi-repo Pc — DEFERRED): the resolved
        # cco_include_member_configs flag is plumbed but not yet enforced here. Today
        # every mounted repo's <repo>/.cco follows Pc uniformly (== the flag's `true`
        # span). The §6 DEFAULT (Pc's rw span limited to the HOSTING repo, other
        # members' divergent .cco re-overlaid :ro) needs the multi-repo mount model
        # to distinguish host vs member reliably (the current test fixtures mount a
        # non-host member as the project's editable .cco). Tracked as a follow-up so
        # this schema lands purely additive and non-regressive.

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

        # Extra mounts (same invariant as repos — resolved + existence asserted
        # upstream). The bridge emits src<TAB>target<TAB>ro<TAB>policy<TAB>role.
        local extra_mounts
        extra_mounts=$(_effective_extra_mounts "$project_yml")
        if [[ -n "$extra_mounts" ]]; then
            echo "      # Extra mounts"
            # 5-field record (src⇥tgt⇥ro⇥policy⇥role). Peeled by hand: the role
            # field is empty for every user mount, and tab is IFS whitespace to
            # `read`, which would shift the fields left (lib/utils.sh:96-110).
            local _mline _ms _mt _mro _mpolicy _mrole _suffix _nc_rel _claude_ro _cco_ro
            while IFS= read -r _mline; do
                _peel_tab "$_mline" _ms _mt _mro _mpolicy _mrole
                [[ -z "$_ms" ]] && continue
                _suffix=""
                [[ "$_mro" == "true" ]] && _suffix="ro"
                _compose_vol "$_ms" "$_mt" "$_suffix"
                # Nested-config governance (ADR-0049 §7), resolved by ONE pure
                # predicate (RC-1 §3.2) instead of the 3-way if/else that had
                # drifted apart from its two sibling call sites — the repo branch
                # below (_committed_ro) and the operator bucket (_b3_auth_mode).
                # config_access_policy: ro (default) → strict for a USER mount,
                # session-triple-governed for a framework mount that exposes a
                # config tree · project → follow Cr / Pc · write → no overlay.
                # Compare == "ro": the encoding is total, never empty.
                _peel_tab "$(_nested_config_modes "$_mro" "$_mpolicy" "$_mrole" \
                                "$claude_cr,$claude_cp,$claude_cg,$claude_co" \
                                "$cco_g,$cco_pc,$cco_po")" _claude_ro _cco_ro
                if [[ "$_claude_ro" == "ro" ]]; then
                    while IFS= read -r _nc_rel; do
                        [[ -z "$_nc_rel" ]] && continue
                        _compose_vol "${_ms}/${_nc_rel}" "${_mt}/${_nc_rel}" "ro"
                    done < <(_find_nested_config_dirs "$_ms" ".claude")
                fi
                if [[ "$_cco_ro" == "ro" ]]; then
                    while IFS= read -r _nc_rel; do
                        [[ -z "$_nc_rel" ]] && continue
                        # extra_mounts aren't projects → a nested .cco tree
                        # qualifies only when it carries a project.yml. The mount
                        # ROOT is never a candidate (_find_nested_config_dirs);
                        # its mode comes from the mount's own readonly:.
                        [[ -f "${_ms}/${_nc_rel}/project.yml" ]] || continue
                        _compose_vol "${_ms}/${_nc_rel}" "${_mt}/${_nc_rel}" "ro"
                    done < <(_find_nested_config_dirs "$_ms" ".cco")
                fi
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

    # Session running registry (ADR-0045). `docker compose run` blocks for the whole
    # session, so this host process OWNS the marker lifecycle: reconcile stale markers
    # (backstop for prior unclean exits), write our marker, run, then remove it. The
    # post-run unmark is the PRIMARY reaper for the common no-`cco stop` exit (Ctrl-C
    # and a normal Claude Code exit both return control here); `|| _run_rc=$?` keeps
    # `set -e` from aborting before the unmark on a non-zero session exit. A hard kill
    # of this process skips the unmark → the next host read reconciles it away.
    _cco_running_reconcile
    _cco_running_mark "$project_name"
    local _run_rc=0
    docker compose -f "$compose_file" --project-directory "$session_state_dir" run --rm --service-ports "${run_env[@]+"${run_env[@]}"}" claude || _run_rc=$?
    _cco_running_unmark "$project_name"

    ok "Session ended. Changes are in your repos."
    return "$_run_rc"
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
    local config_editor_all=false   # --all: explicit widener → every project's .cco (ADR-0044 §3)
    local config_editor_mode=""     # resolved all|project|global (ADR-0044 §3; _resolve_config_editor_mode)
    local config_editor_cwd_dir=""  # the cwd project's host repo dir, when mode=project via cwd
    # Config-editor collected targets/repos (ADR-0044 §3 / D9). Declared at cmd_start
    # scope — NOT local to _start_resolve_project — so the collector's output survives
    # into _start_generate_compose (a sibling call), which derives CCO_CONFIG_TARGETS +
    # the trusted session descriptor (ADR-0047 R2) from _ce_targets. A function-local
    # here would be invisible to compose-gen, silently emptying CCO_CONFIG_TARGETS and
    # neutering the config-editor ownership predicate (_env_is_current_project, B5).
    local _ce_targets="" _ce_repos=""
    local cli_claude_access=""      # --claude-access override (ADR-0036 D2/D3); "" = unset
    local cli_cco_access=""         # --cco-access override; supersedes --enable-config-edit
    local cli_show_host_paths=""    # "" | "true" | "false" (--show-host-paths / --no-…)

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from) [[ $# -lt 2 ]] && die "--from requires a <repo> name."; from_repo="$2"; shift 2 ;;
            --mount) [[ $# -lt 2 ]] && die "--mount requires <src>[:<target>][:ro|:rw]."; user_mounts+=("$2"); shift 2 ;;
            --enable-config-edit) enable_config_edit=true; shift ;;
            --claude-access) [[ $# -lt 2 ]] && die "--claude-access requires a value (none|repo|all, or granular repo=…,current=…,global=…,others=…)."; cli_claude_access="$2"; shift 2 ;;
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
    local claude_cr claude_cp claude_cg claude_co    # resolved (Cr,Cp,Cg,Co) claude triple (ADR-0049); claude_access = its label
    local cco_g cco_pc cco_po                        # resolved (G,Pc,Po) triple (ADR-0046); cco_access = its label
    local cco_include_member_configs="false"         # access.cco.include_member_configs (ADR-0046 §6)
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

    _start_guard_config_editor_scope

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
        local _emline _pol _role
        while IFS= read -r _emline; do
            _peel_tab "$_emline" _src _tgt _ro _pol _role
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
