#!/usr/bin/env bash
# tests/test_access_resolution.sh — session capability-model knob resolution
# (ADR-0036 D2/D3, implementation step 2).
#
# Covers the three orthogonal knobs (claude_access / cco_access / show_host_paths),
# their precedence CLI > project.yml `access:` > global ~/.cco/access.yml > built-in
# preset default (repo / none / on), enum validation, and the deprecated
# --enable-config-edit → --cco-access edit-project alias. Resolution is host-side
# and side-effect-free; no Docker daemon required.

# Source the minimal chain cmd-start.sh's access helpers depend on.
_access_src() {
    source "$REPO_ROOT/lib/colors.sh"
    source "$REPO_ROOT/lib/utils.sh"
    source "$REPO_ROOT/lib/yaml.sh"
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/access-scope.sh"   # (G,Pc,Po) resolver used by _start_resolve_access
    source "$REPO_ROOT/lib/cmd-start.sh"
}

# ── Pure helpers ─────────────────────────────────────────────────────

test_access_is_member() {
    _access_src
    _access_is_member "none repo all" "repo" || fail "'repo' should be a member"
    _access_is_member "$_ACCESS_CCO_VALUES" "edit-global" || fail "'edit-global' should be a member"
    if _access_is_member "none repo all" "bogus"; then fail "'bogus' should not be a member"; fi
    return 0
}

# ── RC-1 §3.2: _nested_config_modes, the single nested-config predicate ──
#
# Two rules govern this table, both learned from a falsified first draft:
#
#  1. Assertions go through the MANDATED CONSUMER IDIOM (_peel_tab into two
#     names), never against the raw printf string. A raw-string comparison passes
#     while the wiring is inverted — exactly how the draft's defect would have
#     shipped. The draft encoded "writable" as an EMPTY field, and
#     `IFS=$'\t' read -r a b <<< $'\tro'` yields a=ro, b= — the two axes SWAPPED,
#     because tab is IFS whitespace to `read` (lib/utils.sh:96-110). The shipped
#     encoding is TOTAL (every field is literally "ro" or "rw") so the record is
#     safe under any reader, and _peel_tab is the second, independent guard.
#  2. The table MUST carry both mixed-axis directions. Same-valued axes are
#     structurally blind to an inversion.
_nc_assert() {
    local want_claude="$1" want_cco="$2"; shift 2
    local got_claude got_cco
    _peel_tab "$(_nested_config_modes "$@")" got_claude got_cco
    [[ "$got_claude" == "$want_claude" && "$got_cco" == "$want_cco" ]] \
        || fail "_nested_config_modes $* → ($got_claude,$got_cco), expected ($want_claude,$want_cco)"
}

test_nested_config_modes_table() {
    _access_src
    #        claude cco   mro    policy  role             ktriple(Cr,Cp,Cg,Co) ctriple(G,Pc,Po)
    # 1 — policy project, both axes ro: unchanged repo-native mapping.
    _nc_assert ro ro      false  project ''               "ro,ro,ro,ro"        "ro,ro,none"
    # 2 — policy project, MIXED: Cr=rw while Pc=ro. This is the live case behind
    #     test_dry_run_extra_mount_config_policy_project's --claude-access repo arm,
    #     and the case that falsified the draft encoding.
    _nc_assert rw ro      false  project ''               "rw,ro,ro,ro"        "ro,ro,none"
    # 3 — the inverse mix, so an axis swap cannot hide in either direction.
    _nc_assert ro rw      false  project ''               "ro,ro,ro,ro"        "ro,rw,none"
    # 4 — role store at the DEFAULT policy: ~/.cco follows Cg / G.
    _nc_assert rw rw      false  ro      store            "ro,ro,rw,ro"        "rw,none,none"
    # 5 — role store, MIXED: Cg=rw while G=ro. Reachable, and the reason the axes
    #     must be carried separately rather than collapsed to one flag.
    _nc_assert rw ro      false  ro      store            "ro,ro,rw,ro"        "ro,rw,none"
    # 6 — role project-config: <repo>/.cco follows Cp / Pc.
    _nc_assert rw rw      false  ro      project-config   "ro,rw,ro,ro"        "ro,rw,none"
    # 7 — NO role (a user extra_mount) stays STRICT ro at the default policy,
    #     whatever the session resolved. D-M1 leaves this default unchanged.
    _nc_assert ro ro      false  ro      ''               "rw,rw,rw,rw"        "rw,rw,rw"
    # 8 — a :ro mount already locks everything: short-circuit, no overlay.
    _nc_assert rw rw      true   ro      store            "ro,ro,ro,ro"        "none,none,none"
    # 9 — policy write opts out wholesale: short-circuit.
    _nc_assert rw rw      false  write   ''               "ro,ro,ro,ro"        "none,none,none"
    # 10 — fail-closed: an axis of `none` grants no access, so it must never yield
    #      a writable overlay. `none` is NOT `rw`.
    _nc_assert ro ro      false  ro      store            "none,none,none,none" "none,none,none"
    return 0
}

# The predicate is pure: the same arguments must give the same answer with no
# ambient session state, which is what makes the table above a real oracle for
# the wiring tests in test_config_editor.sh / test_start_dry_run.sh.
test_nested_config_modes_is_pure() {
    _access_src
    local a b
    a=$(_nested_config_modes false ro store "ro,ro,rw,ro" "rw,none,none")
    claude_cg="ro" cco_g="none" _mrole="project-config"   # ambient noise
    b=$(_nested_config_modes false ro store "ro,ro,rw,ro" "rw,none,none")
    assert_equals "$a" "$b" "_nested_config_modes must not read ambient state"
    assert_equals "rw"$'\t'"rw" "$a" "total encoding: both fields literal, never empty"
    return 0
}

test_access_norm_bool() {
    _access_src
    [[ "$(_access_norm_bool on)"    == "true"  ]] || fail "on→true"
    [[ "$(_access_norm_bool OFF)"   == "false" ]] || fail "OFF→false"
    [[ "$(_access_norm_bool true)"  == "true"  ]] || fail "true→true"
    [[ "$(_access_norm_bool 0)"     == "false" ]] || fail "0→false"
    [[ -z "$(_access_norm_bool '')" ]] || fail "empty token stays empty"
    if ( _access_norm_bool nonsense ) >/dev/null 2>&1; then fail "invalid bool should return non-zero"; fi
    return 0
}

test_access_pick_precedence() {
    _access_src
    [[ "$(_access_pick cli proj glob def)" == "cli"  ]] || fail "cli should win"
    [[ "$(_access_pick '' proj glob def)"  == "proj" ]] || fail "project next"
    [[ "$(_access_pick '' '' glob def)"    == "glob" ]] || fail "global next"
    [[ "$(_access_pick '' '' '' def)"      == "def"  ]] || fail "default last"
    return 0
}

# ── _start_resolve_access precedence (direct call) ───────────────────
# Declares the cmd_start locals the function reads/writes, then invokes it.

_access_setup_home() {
    local tmp="$1"
    export HOME="$tmp/home" CCO_ALLOW_HOST_RESOLVE=1
    unset CCO_CONFIG_HOME XDG_CONFIG_HOME
    mkdir -p "$HOME/.cco"
}

test_access_resolve_defaults() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src

    local project_yml="$tmp/project.yml"; printf 'name: p\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths
    local claude_cr claude_cp claude_cg claude_co
    _start_resolve_access
    # ADR-0049 §2/§6: claude_access now DERIVES from cco. Default cco read-project
    # (none,ro,none) → (Cr=ro, Cp=ro, Cg=ro, Co=ro) = preset `none` — a normal
    # session no longer authors .claude by default (reverses ADR-0027 P17).
    [[ "$claude_access" == "none" ]]  || fail "default claude derives to none, got: $claude_access"
    [[ "$claude_cr $claude_cp $claude_cg $claude_co" == "ro ro ro ro" ]] \
        || fail "default claude axes (ro,ro,ro,ro), got: $claude_cr $claude_cp $claude_cg $claude_co"
    [[ "$cco_access" == "read-project" ]] || fail "default cco=read-project (ADR-0042), got: $cco_access"
    [[ "$show_host_paths" == "true" ]] || fail "default show_host_paths=true, got: $show_host_paths"
}

test_access_resolve_project_block() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src

    local project_yml="$tmp/project.yml"
    printf 'name: p\naccess:\n  claude: all\n  cco: read-global\n  show_host_paths: false\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths
    _start_resolve_access
    [[ "$claude_access" == "all" ]]      || fail "project claude=all, got: $claude_access"
    [[ "$cco_access" == "read-global" ]] || fail "project cco=read-global, got: $cco_access"
    [[ "$show_host_paths" == "false" ]]  || fail "project show_host_paths=false, got: $show_host_paths"
}

# ADR-0042 symmetric read scoping: the three read levels validate; bare `read`
# is accepted as a back-compat alias normalized to read-all.
test_access_read_scopes_and_legacy_alias() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"; printf 'name: p\n' > "$project_yml"
    local cli_claude_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths lvl
    for lvl in read-project read-global read-all; do
        local cli_cco_access="$lvl"
        _start_resolve_access
        [[ "$cco_access" == "$lvl" ]] || fail "read scope $lvl should validate, got: $cco_access"
    done
    # Legacy `read` → read-all.
    local cli_cco_access="read"
    _start_resolve_access
    [[ "$cco_access" == "read-all" ]] || fail "legacy 'read' should normalize to read-all, got: $cco_access"
}

test_access_resolve_global_default() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src

    printf 'claude: none\ncco: edit-global\nshow_host_paths: false\n' > "$HOME/.cco/access.yml"
    local project_yml="$tmp/project.yml"; printf 'name: p\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths
    _start_resolve_access
    [[ "$claude_access" == "none" ]]        || fail "global claude=none, got: $claude_access"
    [[ "$cco_access" == "edit-global" ]]    || fail "global cco=edit-global, got: $cco_access"
    [[ "$show_host_paths" == "false" ]]     || fail "global show_host_paths=false, got: $show_host_paths"
}

test_access_resolve_project_over_global() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src

    printf 'claude: none\ncco: none\n' > "$HOME/.cco/access.yml"
    local project_yml="$tmp/project.yml"
    printf 'name: p\naccess:\n  claude: all\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths
    _start_resolve_access
    [[ "$claude_access" == "all" ]] || fail "project should override global claude, got: $claude_access"
    # cco not set at project level → falls through to global 'none'
    [[ "$cco_access" == "none" ]]   || fail "cco should fall through to global none, got: $cco_access"
}

test_access_resolve_cli_over_project() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src

    local project_yml="$tmp/project.yml"
    printf 'name: p\naccess:\n  claude: all\n  cco: edit-all\n' > "$project_yml"
    local cli_claude_access="repo" cli_cco_access="" cli_show_host_paths="false"
    local claude_access cco_access show_host_paths
    _start_resolve_access
    [[ "$claude_access" == "repo" ]]    || fail "CLI should override project claude, got: $claude_access"
    [[ "$cco_access" == "edit-all" ]]   || fail "cco (no CLI) keeps project value, got: $cco_access"
    [[ "$show_host_paths" == "false" ]] || fail "CLI --no-show-host-paths wins, got: $show_host_paths"
}

test_access_resolve_invalid_project_value_dies() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src

    local project_yml="$tmp/project.yml"
    printf 'name: p\naccess:\n  cco: bogus\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths
    local out rc=0
    out=$( _start_resolve_access 2>&1 ) || rc=$?
    [[ $rc -ne 0 ]] || fail "invalid cco_access should abort, got rc=0"
    [[ "$out" == *"Invalid cco_access"* ]] || fail "expected validation message, got: $out"
}

# ── Built-in presets (ADR-0044) ──────────────────────────────────────

# tutorial → read-only teacher: claude=none, cco=read-all (was read-project).
test_access_preset_tutorial_read_all() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"; printf 'name: tutorial\n' > "$project_yml"
    local session_preset="tutorial"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths
    _start_resolve_access
    [[ "$claude_access" == "none" ]]  || fail "tutorial claude=none, got: $claude_access"
    [[ "$cco_access" == "read-all" ]] || fail "tutorial cco=read-all (ADR-0044 §2), got: $cco_access"
}

# config-editor → minimum privilege by resolved mode: global→(rw,none,none),
# project→(ro,rw,none), all→edit-all (ADR-0044 §3 / ADR-0048 WS-A). claude_access
# is now the GENERAL cco-derived Axis-B default (ADR-0049 §8) — the bespoke
# "claude follows G" is gone, so config-editor's claude column is a CONSEQUENCE:
#   project → cco (ro,rw,none) → claude (ro,rw,ro,ro) = custom (author the target's
#             B2, read the rest). NOT preset `repo` (which would author B1 too).
#   global  → cco (rw,none,none) → claude (ro,ro,rw,ro) = author the global B3 only.
#   all     → cco (rw,rw,rw) → claude (ro,rw,rw,rw) = author every project's B2/B3,
#             but B1 (Cr) stays ro.
test_access_preset_config_editor_by_mode() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"; printf 'name: config-editor\n' > "$project_yml"
    local session_preset="config-editor"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths config_editor_mode
    local claude_cr claude_cp claude_cg claude_co
    local cco_g cco_pc cco_po cco_include_member_configs
    config_editor_mode="project"; _start_resolve_access
    [[ "$cco_g $cco_pc $cco_po" == "ro rw none" ]] || fail "config-editor project→(ro,rw,none), got: $cco_g $cco_pc $cco_po"
    [[ "$cco_access" == "global=ro,current=rw,others=none" ]] || fail "project label, got: $cco_access"
    [[ "$claude_cr $claude_cp $claude_cg $claude_co" == "ro rw ro ro" ]] \
        || fail "config-editor project→claude (ro,rw,ro,ro), got: $claude_cr $claude_cp $claude_cg $claude_co"
    [[ "$claude_access" == "repo=ro,current=rw,global=ro,others=ro" ]] \
        || fail "config-editor project claude label, got: $claude_access"
    config_editor_mode="global"; _start_resolve_access
    [[ "$cco_g $cco_pc $cco_po" == "rw none none" ]] || fail "config-editor global→(rw,none,none), got: $cco_g $cco_pc $cco_po"
    [[ "$cco_access" == "global=rw,current=none,others=none" ]] || fail "global label, got: $cco_access"
    [[ "$claude_cr $claude_cp $claude_cg $claude_co" == "ro ro rw ro" ]] \
        || fail "config-editor global→claude (ro,ro,rw,ro), got: $claude_cr $claude_cp $claude_cg $claude_co"
    config_editor_mode="all"; _start_resolve_access
    [[ "$cco_access" == "edit-all" ]]     || fail "config-editor all→edit-all, got: $cco_access"
    [[ "$claude_cr $claude_cp $claude_cg $claude_co" == "ro rw rw rw" ]] \
        || fail "config-editor all→claude (ro,rw,rw,rw) — Cr stays ro, got: $claude_cr $claude_cp $claude_cg $claude_co"
}

# An explicit --cco-access still overrides the config-editor by-mode default. An
# edit-global override in project mode widens cco to (rw,rw,none); claude then
# DERIVES to (ro,rw,rw,ro) — both the target B2 and the global B3 authorable.
test_access_preset_config_editor_cli_override() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"; printf 'name: config-editor\n' > "$project_yml"
    local session_preset="config-editor" config_editor_mode="project"
    local cli_claude_access="" cli_cco_access="edit-global" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    local claude_cr claude_cp claude_cg claude_co
    _start_resolve_access
    [[ "$cco_access" == "edit-global" ]] || fail "CLI edit-global overrides the config-editor default, got: $cco_access"
    [[ "$claude_cr $claude_cp $claude_cg $claude_co" == "ro rw rw ro" ]] \
        || fail "edit-global override → claude (ro,rw,rw,ro), got: $claude_cr $claude_cp $claude_cg $claude_co"
}

# config-editor G>=ro clamp (WS-A / ADR-0044 §2 analogy): an explicit narrower override
# whose G is below ro is clamped up to ro (the authoring tool must always SEE the store).
# read-project (none,ro,none) → (ro,ro,none)=read-global; edit-project (none,rw,none) →
# (ro,rw,none). The store stays read-only (G!=rw) — only edit-global grants a store write.
test_access_config_editor_g_clamp() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"; printf 'name: config-editor\n' > "$project_yml"
    local session_preset="config-editor" config_editor_mode="project"
    local cli_claude_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs cli_cco_access
    cli_cco_access="read-project"; _start_resolve_access 2>/dev/null
    [[ "$cco_g $cco_pc $cco_po" == "ro ro none" ]] || fail "read-project clamps G→ro, got: $cco_g $cco_pc $cco_po"
    cli_cco_access="edit-project"; _start_resolve_access 2>/dev/null
    [[ "$cco_g $cco_pc $cco_po" == "ro rw none" ]] || fail "edit-project clamps G→ro, got: $cco_g $cco_pc $cco_po"
}

# ── Axis-B claude_access resolver (ADR-0049) ─────────────────────────

# Pure helpers: preset triples + reverse, cco-axis collapse, granular parse,
# cco-derived fill, label, and the discordance predicate.
test_claude_axis_b_pure_helpers() {
    _access_src
    # Preset → fixed "Cr Cp Cg Co" and its reverse.
    [[ "$(_claude_preset_triple none)" == "ro ro ro ro" ]] || fail "preset none"
    [[ "$(_claude_preset_triple repo)" == "rw rw ro ro" ]] || fail "preset repo"
    [[ "$(_claude_preset_triple all)"  == "rw rw rw rw" ]] || fail "preset all"
    ( _claude_preset_triple bogus ); [[ $? -ne 0 ]] || fail "unknown preset returns non-zero"
    [[ "$(_claude_triple_preset "ro ro ro ro")" == "none" ]] || fail "reverse none"
    [[ "$(_claude_triple_preset "rw rw ro ro")" == "repo" ]] || fail "reverse repo"
    ( _claude_triple_preset "ro rw ro ro" ); [[ $? -ne 0 ]] || fail "custom triple has no preset name"
    # cco-axis collapse onto the {ro,rw} lattice: rw→rw, none/ro→ro.
    [[ "$(_claude_from_cco_axis rw)"   == "rw" ]] || fail "collapse rw"
    [[ "$(_claude_from_cco_axis ro)"   == "ro" ]] || fail "collapse ro"
    [[ "$(_claude_from_cco_axis none)" == "ro" ]] || fail "collapse none→ro"
    # Granular parse (partial, pipe-delimited, EMPTY for unspecified axes).
    [[ "$(_claude_parse_granular "current=rw,global=ro")" == "|rw|ro|" ]] \
        || fail "parse partial, got: $(_claude_parse_granular 'current=rw,global=ro')"
    ( _claude_parse_granular "current=maybe" 2>/dev/null ); [[ $? -ne 0 ]] || fail "bad value dies"
    ( _claude_parse_granular "bogus=rw" 2>/dev/null );     [[ $? -ne 0 ]] || fail "unknown key dies"
    _claude_parse_granular "none" >/dev/null && fail "no '=' returns 1 (a preset scalar)"
    # Derive: empty axes fill from cco (Cr→ro ALWAYS); explicit axes pass through.
    [[ "$(_claude_derive_triple "" "" "" "" rw rw none)" == "ro rw rw ro" ]] || fail "derive from cco (edit-global-ish)"
    [[ "$(_claude_derive_triple rw "" "" "" none ro none)" == "rw ro ro ro" ]] || fail "explicit Cr=rw passes through"
    # Label round-trips (preset name when it matches, else granular).
    [[ "$(_claude_triple_label ro ro ro ro)" == "none" ]] || fail "label none"
    [[ "$(_claude_triple_label ro rw ro ro)" == "repo=ro,current=rw,global=ro,others=ro" ]] || fail "custom label"
    # Discordance predicate (0 = discordant): rw where the cco-concordant default is ro.
    _claude_discordant ro rw rw ro rw rw none && fail "claude derived from cco (rw,rw,none) is concordant, not discordant"
    _claude_discordant ro ro rw ro none ro none || fail "Cg=rw over G=none(→ro) IS discordant"
    _claude_discordant ro rw ro ro none ro none || fail "Cp=rw over Pc=ro(→ro) IS discordant"
    _claude_discordant rw ro ro ro none ro none && fail "Cr=rw never warns (no cco counterpart)"
    return 0
}

# A claude PRESET fixes the triple regardless of the cco intent (no derivation) —
# repo=(rw,rw,ro,ro) even under cco edit-all (which would DERIVE to (ro,rw,rw,rw)).
test_access_resolve_claude_preset_no_derive() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"; printf 'name: p\n' > "$project_yml"
    local cli_claude_access="repo" cli_cco_access="edit-all" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    local claude_cr claude_cp claude_cg claude_co
    _start_resolve_access
    [[ "$claude_cr $claude_cp $claude_cg $claude_co" == "rw rw ro ro" ]] \
        || fail "preset repo fixes the triple despite cco edit-all, got: $claude_cr $claude_cp $claude_cg $claude_co"
    [[ "$claude_access" == "repo" ]] || fail "preset label repo, got: $claude_access"
}

# CLI granular claude: explicit axes are set; omitted axes DERIVE from cco (default
# read-project → Pc=ro,Po=none). global=rw → (Cr=ro, Cp=ro, Cg=rw, Co=ro).
test_access_resolve_claude_granular_cli() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"; printf 'name: p\n' > "$project_yml"
    local cli_claude_access="global=rw" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    local claude_cr claude_cp claude_cg claude_co
    _start_resolve_access
    [[ "$claude_cr $claude_cp $claude_cg $claude_co" == "ro ro rw ro" ]] \
        || fail "granular claude derives omitted axes from cco, got: $claude_cr $claude_cp $claude_cg $claude_co"
    [[ "$claude_access" == "repo=ro,current=ro,global=rw,others=ro" ]] || fail "granular claude label, got: $claude_access"
}

# project.yml scalar claude preset resolves (precedence below CLI, above global).
test_access_resolve_claude_project_scalar() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"
    printf 'name: p\naccess:\n  claude: repo\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    local claude_cr claude_cp claude_cg claude_co
    _start_resolve_access
    [[ "$claude_access" == "repo" ]] || fail "project.yml claude: repo, got: $claude_access"
    [[ "$claude_cr $claude_cp $claude_cg $claude_co" == "rw rw ro ro" ]] \
        || fail "project claude preset triple, got: $claude_cr $claude_cp $claude_cg $claude_co"
}

# project.yml access.claude MAP form: explicit axes set, omitted axes derive from
# cco (default read-project → Pc=ro,Po=none). {current:rw, global:ro} → (ro,rw,ro,ro).
test_access_resolve_claude_map_form() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"
    printf 'name: p\naccess:\n  claude:\n    current: rw\n    global: ro\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    local claude_cr claude_cp claude_cg claude_co
    _start_resolve_access
    [[ "$claude_cr $claude_cp $claude_cg $claude_co" == "ro rw ro ro" ]] \
        || fail "project claude map → (ro,rw,ro,ro), got: $claude_cr $claude_cp $claude_cg $claude_co"
    [[ "$claude_access" == "repo=ro,current=rw,global=ro,others=ro" ]] || fail "project claude map label, got: $claude_access"
}

# A partial project.yml claude map derives omitted axes from cco edit-all
# (rw,rw,rw): only repo:rw set → (rw, rw, rw, rw) — Cp/Cg/Co derive to rw.
test_access_resolve_claude_map_partial_derives() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"
    printf 'name: p\naccess:\n  cco: edit-all\n  claude:\n    repo: rw\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    local claude_cr claude_cp claude_cg claude_co
    _start_resolve_access
    [[ "$claude_cr $claude_cp $claude_cg $claude_co" == "rw rw rw rw" ]] \
        || fail "partial claude map derives from cco edit-all, got: $claude_cr $claude_cp $claude_cg $claude_co"
    [[ "$claude_access" == "all" ]] || fail "partial map label rounds to all, got: $claude_access"
}

# ~/.cco/access.yml granular MAP for claude (level 3, below project). {global:rw}
# under default cco read-project → (ro,ro,rw,ro).
test_access_resolve_global_claude_map() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    printf 'claude:\n  global: rw\n' > "$HOME/.cco/access.yml"
    local project_yml="$tmp/project.yml"; printf 'name: p\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    local claude_cr claude_cp claude_cg claude_co
    _start_resolve_access
    [[ "$claude_cr $claude_cp $claude_cg $claude_co" == "ro ro rw ro" ]] \
        || fail "access.yml claude map → (ro,ro,rw,ro), got: $claude_cr $claude_cp $claude_cg $claude_co"
}

# ~/.cco/access.yml granular MAP for cco (symmetric with project.yml). {global:rw,
# current:ro,others:ro} → (rw,ro,ro).
test_access_resolve_global_cco_map() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    printf 'cco:\n  global: rw\n  current: ro\n  others: ro\n' > "$HOME/.cco/access.yml"
    local project_yml="$tmp/project.yml"; printf 'name: p\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    _start_resolve_access
    [[ "$cco_g $cco_pc $cco_po" == "rw ro ro" ]] || fail "access.yml cco map → (rw,ro,ro), got: $cco_g $cco_pc $cco_po"
}

# A project.yml claude map wins over an ~/.cco/access.yml claude map (precedence).
test_access_resolve_claude_map_precedence() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    printf 'claude:\n  global: rw\n' > "$HOME/.cco/access.yml"
    local project_yml="$tmp/project.yml"
    printf 'name: p\naccess:\n  claude:\n    repo: rw\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    local claude_cr claude_cp claude_cg claude_co
    _start_resolve_access
    # Project map wins → Cr=rw explicit, Cg derives from cco (ro), NOT the global map's rw.
    [[ "$claude_cr $claude_cp $claude_cg $claude_co" == "rw ro ro ro" ]] \
        || fail "project claude map wins over global, got: $claude_cr $claude_cp $claude_cg $claude_co"
}

# A bad axis value in the claude MAP dies naming claude_access.
test_access_resolve_claude_map_bad_value() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"
    printf 'name: p\naccess:\n  claude:\n    current: maybe\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    local claude_cr claude_cp claude_cg claude_co
    local out rc=0
    out=$( _start_resolve_access 2>&1 ) || rc=$?
    [[ $rc -ne 0 ]] || fail "bad claude map value must be rejected, got rc=0"
    [[ "$out" == *"claude_access"* ]] || fail "message should name claude_access, got: $out"
}

# P2 discordance warning (ADR-0049 §4): an explicit claude MORE permissive than the
# cco-concordant default emits a note to stderr — allowed, never a refusal.
test_access_claude_discordance_warns() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"; printf 'name: p\n' > "$project_yml"
    # claude=all authoring while cco stays read-project (ro) → discordant on Cp/Cg.
    local cli_claude_access="all" cli_cco_access="read-project" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    local claude_cr claude_cp claude_cg claude_co
    local out; out=$( _start_resolve_access 2>&1 )
    [[ "$out" == *"discordance"* || "$out" == *"more broadly"* ]] \
        || fail "explicit claude wider than cco should warn, got: $out"
}

# A concordant (derived) claude NEVER warns.
test_access_claude_concordant_no_warn() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"; printf 'name: p\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="edit-all" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    local claude_cr claude_cp claude_cg claude_co
    local out; out=$( _start_resolve_access 2>&1 )
    [[ "$out" != *"discordance"* && "$out" != *"more broadly"* ]] \
        || fail "a derived (concordant) claude must not warn, got: $out"
}

# A bad claude value (unknown key/out-of-lattice) dies naming claude_access.
test_access_resolve_claude_bad_token() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"; printf 'name: p\n' > "$project_yml"
    local cli_claude_access="repo=maybe" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    local claude_cr claude_cp claude_cg claude_co
    local out rc=0
    out=$( _start_resolve_access 2>&1 ) || rc=$?
    [[ $rc -ne 0 ]] || fail "bad claude value must be rejected, got rc=0"
    [[ "$out" == *"claude_access"* ]] || fail "message should name claude_access, got: $out"
}

# ── (G,Pc,Po) triple resolution (ADR-0046) ───────────────────────────

# edit-global is REDEFINED (§3): its triple is (rw,rw,none) — it now writes the
# current project too. The label round-trips to "edit-global".
test_access_resolve_edit_global_triple() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"; printf 'name: p\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="edit-global" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    _start_resolve_access
    [[ "$cco_g $cco_pc $cco_po" == "rw rw none" ]] || fail "edit-global → (rw,rw,none), got: $cco_g $cco_pc $cco_po"
    [[ "$cco_access" == "edit-global" ]] || fail "label round-trips, got: $cco_access"
}

# Granular CLI form with auto-promotion: others=rw → Pc=rw (INV-4), G=none.
test_access_resolve_granular_cli() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"; printf 'name: p\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="others=rw" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    _start_resolve_access
    [[ "$cco_g $cco_pc $cco_po" == "none rw rw" ]] || fail "others=rw promotes Pc=rw, got: $cco_g $cco_pc $cco_po"
    [[ "$cco_access" == "global=none,current=rw,others=rw" ]] || fail "granular label, got: $cco_access"
}

# INV-2 conditional floor (ADR-0046 §2 refinement, 2026-07-11): the Pc>=ro project
# floor holds ONLY when the session has a current project. _cco_promote_triple's 4th arg
# has_current_project (default true = fail-closed) toggles it.
test_access_inv2_conditional_floor() {
    _access_src
    # has_project=true (default): an unspecified Pc floors to ro; an explicit none dies.
    [[ "$(_cco_promote_triple rw "" "")" == "rw ro none" ]] || fail "default floors Pc→ro"
    ( _cco_promote_triple none none none 2>/dev/null ); [[ $? -ne 0 ]] || fail "explicit Pc=none with a project must die (INV-2)"
    # has_project=false (project-less): Pc honestly floors to / stays none, no die.
    [[ "$(_cco_promote_triple rw "" "" false)" == "rw none none" ]] || fail "project-less floors Pc→none, got: $(_cco_promote_triple rw '' '' false)"
    [[ "$(_cco_promote_triple none none none false)" == "none none none" ]] || fail "project-less accepts explicit Pc=none"
    # INV-4 still enforced even project-less: others>current is rejected.
    ( _cco_promote_triple rw none ro false 2>/dev/null ); [[ $? -ne 0 ]] || fail "project-less others=ro > current=none must die (INV-4/INV-3)"
}

# Resolution-level regression: a NORMAL session (has_current_project=true) that asks for
# current=none is still rejected — the conditional floor does not leak to standard starts.
test_access_normal_current_none_rejected() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"; printf 'name: p\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="current=none" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    ( _start_resolve_access 2>/dev/null ); [[ $? -ne 0 ]] || fail "normal session current=none must be rejected (strict INV-2)"
}

# Case 7 granular: global=rw,current=ro,others=ro.
test_access_resolve_granular_case7() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"; printf 'name: p\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="global=rw,current=ro,others=ro" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    _start_resolve_access
    [[ "$cco_g $cco_pc $cco_po" == "rw ro ro" ]] || fail "case7 triple, got: $cco_g $cco_pc $cco_po"
}

# The project.yml access.cco MAP form resolves to a triple (auto-promotion applies).
test_access_resolve_map_form() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"
    printf 'name: p\naccess:\n  cco:\n    global: ro\n    current: rw\n    others: rw\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    _start_resolve_access
    [[ "$cco_g $cco_pc $cco_po" == "ro rw rw" ]] || fail "map form → (ro,rw,rw), got: $cco_g $cco_pc $cco_po"
}

# A partial map auto-promotes the unspecified axes.
test_access_resolve_map_partial_promotes() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"
    printf 'name: p\naccess:\n  cco:\n    others: rw\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    _start_resolve_access
    [[ "$cco_g $cco_pc $cco_po" == "none rw rw" ]] || fail "partial map promotes Pc=rw, got: $cco_g $cco_pc $cco_po"
}

# CLI granular overrides a project.yml scalar (precedence unchanged).
test_access_resolve_granular_precedence() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"
    printf 'name: p\naccess:\n  cco: read-project\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="global=rw,current=rw" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    _start_resolve_access
    [[ "$cco_g $cco_pc $cco_po" == "rw rw none" ]] || fail "CLI granular wins over project scalar, got: $cco_g $cco_pc $cco_po"
}

# An explicit invariant-violating triple is REJECTED (die, exit≠0) naming it.
test_access_resolve_invariant_rejection() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"; printf 'name: p\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="current=ro,others=rw" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    local out rc=0
    out=$( _start_resolve_access 2>&1 ) || rc=$?
    [[ $rc -ne 0 ]]           || fail "current=ro,others=rw must be rejected, got rc=0"
    [[ "$out" == *"INV-4"* ]] || fail "rejection should name INV-4, got: $out"
}

# An unknown granular key / bad value dies.
test_access_resolve_granular_bad_token() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"; printf 'name: p\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="global=maybe" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs
    local rc=0
    ( _start_resolve_access ) >/dev/null 2>&1 || rc=$?
    [[ $rc -ne 0 ]] || fail "bad granular value must be rejected"
}

# ── Full-flow integration (dry-run) ──────────────────────────────────

test_access_alias_enable_config_edit_maps_to_edit_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    export CCO_DEBUG=1
    run_cco start "test-proj" --enable-config-edit --dry-run
    unset CCO_DEBUG
    assert_output_contains "cco=edit-project"
}

test_access_cli_flag_reaches_resolution() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    export CCO_DEBUG=1
    run_cco start "test-proj" --claude-access all --cco-access read --no-show-host-paths --dry-run
    unset CCO_DEBUG
    # Legacy `read` normalizes to read-all (ADR-0042) before it reaches the debug line.
    assert_output_contains "claude=all cco=read-all show_host_paths=false"
}

test_access_invalid_cli_value_dies() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    local rc=0
    run_cco start "test-proj" --cco-access bogus --dry-run || rc=$?
    [[ $rc -ne 0 ]] || fail "invalid --cco-access should abort, got rc=0"
    assert_output_contains "Invalid cco_access"
}

# ── Mount modes driven by the knobs (step 3) ─────────────────────────
# Assert the generated docker-compose reflects the resolved Axis-B/Axis-A modes.

_access_compose() { cat "$DRY_RUN_DIR/.cco/docker-compose.yml"; }

test_access_mount_defaults() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --dry-run --dump
    local c; c=$(_access_compose)
    # ADR-0049 §6: a normal session no longer authors .claude by default — claude
    # derives to (ro,ro,ro,ro)=none, so B2 project .claude is now :ro (was rw/P17).
    echo "$c" | grep -qE '/workspace/\.claude:ro"' || fail "B2 should be :ro by default (ADR-0049 reverses P17)"
    # B3 global authoring ro
    echo "$c" | grep -qE '/home/claude/\.claude/CLAUDE\.md:ro"' || fail "B3 authoring ro by default"
    # A1 <repo>/.cco overlaid :ro (cco_access=read-project default → Pc=ro)
    echo "$c" | grep -qE 'dummy-repo/\.cco:/workspace/dummy-repo/\.cco:ro"' || fail "A1 :ro overlay expected by default"
}

test_access_mount_claude_none_locks_b2_and_b1() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.claude"   # B1 native repo claude tree
    run_cco start "test-proj" --claude-access none --dry-run --dump
    local c; c=$(_access_compose)
    echo "$c" | grep -qE '/workspace/\.claude:ro"' || fail "B2 should be :ro under claude-access none"
    echo "$c" | grep -qE 'dummy-repo/\.claude:/workspace/dummy-repo/\.claude:ro"' || fail "B1 native .claude should be :ro overlaid under none"
}

# Functional-write floor (ADR-0049 §5): when B2 is :ro (default now), a rw child
# overlay keeps /workspace/.claude/settings.local.json writable from per-project STATE.
test_access_mount_settings_local_overlay_b2() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --dry-run --dump   # default → B2 :ro
    local c; c=$(_access_compose)
    # The overlay line ends at settings.local.json with NO :ro (rw child).
    echo "$c" | grep -qE 'local-settings/workspace\.json:/workspace/\.claude/settings\.local\.json"' \
        || fail "settings.local.json rw overlay expected under B2 :ro"
    # Under --claude-access repo (B2 rw) the overlay is absent (parent is writable).
    run_cco start "test-proj" --claude-access repo --dry-run --dump
    c=$(_access_compose)
    if echo "$c" | grep -q 'settings\.local\.json'; then
        fail "settings.local.json overlay must be absent when B2 is rw"
    fi
}

# Recursive B1 (ADR-0049 §7): a monorepo's NESTED packages/x/.claude is overlaid
# :ro too (not just the repo-root .claude) under the default Cr=ro.
test_access_mount_nested_claude_recursive() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.claude" "$CCO_DUMMY_REPO/packages/x/.claude"
    run_cco start "test-proj" --dry-run --dump   # default Cr=ro
    local c; c=$(_access_compose)
    echo "$c" | grep -qE 'dummy-repo/\.claude:/workspace/dummy-repo/\.claude:ro"' \
        || fail "repo-root .claude :ro overlay expected"
    echo "$c" | grep -qE 'packages/x/\.claude:/workspace/dummy-repo/packages/x/\.claude:ro"' \
        || fail "NESTED packages/x/.claude :ro overlay expected (recursive detection)"
    # Under --claude-access repo (Cr=rw) neither is overlaid.
    run_cco start "test-proj" --claude-access repo --dry-run --dump
    c=$(_access_compose)
    if echo "$c" | grep -qE 'packages/x/\.claude:.*:ro"'; then
        fail "nested .claude must not be :ro when Cr=rw"
    fi
}

# The B1 :ro overlay (Cr=ro default) also carries a settings.local.json rw child
# for each repo that has a native .claude tree.
test_access_mount_settings_local_overlay_b1() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.claude"
    run_cco start "test-proj" --dry-run --dump   # Cr=ro default → B1 :ro overlay
    local c; c=$(_access_compose)
    echo "$c" | grep -qE 'local-settings/repo-dummy-repo\.json:/workspace/dummy-repo/\.claude/settings\.local\.json"' \
        || fail "B1 settings.local.json rw overlay expected for a repo with a native .claude"
}

test_access_mount_claude_all_unlocks_b3() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    run_cco start "test-proj" --claude-access all --dry-run --dump
    local c; c=$(_access_compose)
    # global authoring now rw (quote right after CLAUDE.md, no :ro)
    echo "$c" | grep -qE '/home/claude/\.claude/CLAUDE\.md"' || fail "B3 authoring should be rw under claude-access all"
    if echo "$c" | grep -qE '/home/claude/\.claude/CLAUDE\.md:ro"'; then fail "B3 CLAUDE.md must not be :ro under all"; fi
}

test_access_mount_cco_edit_project_unlocks_a1() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --cco-access edit-project --dry-run --dump
    local c; c=$(_access_compose)
    if echo "$c" | grep -qE 'dummy-repo/\.cco:/workspace/dummy-repo/\.cco:ro"'; then
        fail "A1 :ro overlay should be absent under cco-access edit-project"
    fi
}

# edit-global is REDEFINED to (rw,rw,none) (ADR-0046 §3): it now edits the current
# project (Pc=rw) AS WELL as the global store, so the <repo>/.cco :ro overlay (A1)
# must be ABSENT. This is the exact boundary that FLIPPED vs the old (rw,ro,none).
test_access_mount_cco_edit_global_unlocks_a1() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --cco-access edit-global --dry-run --dump
    local c; c=$(_access_compose)
    if echo "$c" | grep -qE 'dummy-repo/\.cco:/workspace/dummy-repo/\.cco:ro"'; then
        fail "A1 :ro overlay must be ABSENT under edit-global (project now editable, ADR-0046 §3)"
    fi
    # G=rw still makes the personal store rw.
    echo "$c" | grep -qE ':/home/claude/\.cco"' || fail "~/.cco should be rw under edit-global (G=rw)"
}

# The old edit-global intent — curate the GLOBAL store while the project stays
# read-only — is now the granular off-ladder point (rw,ro,none): CONFIG rw (G=rw)
# yet A1 :ro (Pc=ro). This is the boundary a regression would slip through.
test_access_mount_granular_curate_global_keeps_a1_ro() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --cco-access global=rw,current=ro --dry-run --dump
    local c; c=$(_access_compose)
    echo "$c" | grep -qE 'dummy-repo/\.cco:/workspace/dummy-repo/\.cco:ro"' \
        || fail "A1 :ro overlay must REMAIN under (rw,ro,none) — project not editable (Pc=ro)"
    echo "$c" | grep -qE ':/home/claude/\.cco"' || fail "~/.cco should be rw under (rw,ro,none) (G=rw)"
    echo "$c" | grep -q 'CCO_ACCESS_TRIPLE=rw,ro,none' || fail "triple exported as rw,ro,none"
}

# ADR-0046 §6: access.cco.include_member_configs is read into the resolver local
# (default false, additive). The mount-level narrowing it will drive is deferred
# (see the DEFERRED note in _start_generate_compose); this pins the schema read.
test_access_resolve_include_member_configs_read() {
    local tmp; tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
    _access_setup_home "$tmp"; _access_src
    local project_yml="$tmp/project.yml"
    printf 'name: p\naccess:\n  cco:\n    current: rw\n    include_member_configs: true\n' > "$project_yml"
    local cli_claude_access="" cli_cco_access="" cli_show_host_paths=""
    local claude_access cco_access show_host_paths cco_g cco_pc cco_po cco_include_member_configs="false"
    _start_resolve_access
    [[ "$cco_include_member_configs" == "true" ]] || fail "flag should be read as true, got: $cco_include_member_configs"
    # Absent → default false.
    printf 'name: p\naccess:\n  cco: edit-project\n' > "$project_yml"
    cco_include_member_configs="false"
    _start_resolve_access
    [[ "$cco_include_member_configs" == "false" ]] || fail "flag should default false when absent, got: $cco_include_member_configs"
}

# A granular session exports CCO_ACCESS_TRIPLE + the granular CCO_CCO_ACCESS label.
test_access_mount_exports_triple() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --cco-access others=rw --dry-run --dump
    local c; c=$(_access_compose)
    echo "$c" | grep -q 'CCO_ACCESS_TRIPLE=none,rw,rw'                 || fail "triple none,rw,rw exported"
    echo "$c" | grep -q 'CCO_CCO_ACCESS=global=none,current=rw,others=rw' || fail "granular label exported"
    # Pc=rw → A1 editable (no :ro overlay).
    if echo "$c" | grep -qE 'dummy-repo/\.cco:/workspace/dummy-repo/\.cco:ro"'; then
        fail "A1 :ro overlay must be absent when Pc=rw"
    fi
}

# ── Container-operator buckets + secret masking (step 4, ADR-0036 D4) ─

# cco_access=none (explicit — no longer the default under ADR-0042) → no operator
# mode, no buckets.
test_operator_none_no_buckets() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --cco-access none --dry-run --dump
    local c; c=$(_access_compose)
    if echo "$c" | grep -q 'CCO_CONTAINER_OPERATOR'; then fail "no operator env expected under cco-access none"; fi
    if echo "$c" | grep -qE ':/home/claude/\.cco"'; then fail "no ~/.cco bucket mount expected under cco-access none"; fi
}

# Normal default is now read-project (ADR-0042) → operator env present, buckets ro.
test_operator_default_read_project() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --dry-run --dump
    local c; c=$(_access_compose)
    echo "$c" | grep -q 'CCO_CONTAINER_OPERATOR=1'      || fail "operator env expected by default (read-project)"
    echo "$c" | grep -q 'CCO_CCO_ACCESS=read-project'   || fail "CCO_CCO_ACCESS=read-project expected by default"
    # read-project narrowing (ADR-0042 §8): the WHOLE ~/.cco is NOT mounted —
    # only referenced personal-store packs (none here) would be.
    if echo "$c" | grep -qE ':/home/claude/\.cco:ro"'; then
        fail "read-project must NOT mount the whole ~/.cco (narrowed to referenced packs)"
    fi
    # STATE crosses UNDER the cco-svc privileged root (ADR-0047) — the parent boundary
    # confines it, so the former :ro narrowing flag is gone — and only through the
    # shareable sub-bucket, as a DIRECTORY bind (v3 R1: a file bind leaves index
    # writers with no writable parent for their mktemp sibling).
    echo "$c" | grep -qE '/var/lib/cco-internal/state/cco/shared"' \
        || fail "STATE/shared expected under the cco-svc privileged root (ADR-0047)"
    if echo "$c" | grep -qE '/var/lib/cco-internal/state/cco/index"'; then
        fail "the index must NOT be bound as a file — bind the shared/ directory (v3 R1)"
    fi
    # The trusted session descriptor is mounted :ro so the agent cannot forge scope.
    echo "$c" | grep -qE '/etc/cco/session-access:ro"' \
        || fail "trusted :ro session descriptor expected in operator mode (ADR-0047 R2)"
}

# read-project narrowing (ADR-0042 §8): a referenced personal-store pack is the
# ONLY thing exposed under /home/claude/.cco (ro); the whole store, templates,
# and other packs stay hidden. read-global/read-all mount the whole store.
test_operator_read_project_narrows_to_referenced_packs() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    local pack_src="$CCO_PACKS_DIR/k-pack/knowledge"; mkdir -p "$pack_src"
    create_pack "$tmpdir" "k-pack" "$(printf 'name: k-pack\nknowledge:\n  source: %s\n  files:\n    - overview.md\n' "$pack_src")"
    echo "# Overview" > "$pack_src/overview.md"
    # An unreferenced personal-store pack that must stay hidden.
    mkdir -p "$CCO_PACKS_DIR/other-pack"; printf 'name: other-pack\n' > "$CCO_PACKS_DIR/other-pack/pack.yml"
    create_project "$tmpdir" "test-proj" "$(printf 'name: test-proj\nrepos:\n  - name: dummy-repo\npacks:\n  - k-pack\n')"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --dry-run --dump
    local c; c=$(_access_compose)
    # The referenced pack is mounted ro at its narrowed operator-bucket path.
    echo "$c" | grep -qE "/packs/k-pack:/home/claude/\.cco/packs/k-pack:ro\"" \
        || fail "referenced personal-store pack should mount ro under narrowed ~/.cco"
    # The whole ~/.cco and the unreferenced pack are NOT mounted.
    if echo "$c" | grep -qE ':/home/claude/\.cco:ro"'; then fail "whole ~/.cco must not mount under read-project"; fi
    if echo "$c" | grep -q 'other-pack'; then fail "unreferenced pack must stay hidden under read-project"; fi
}

# --cco-access read (legacy alias → read-all) → operator env + buckets, all ro;
# STATE is index-only. Exercises the alias flowing through resolution to compose.
test_operator_read_mounts_buckets_ro() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --cco-access read --dry-run --dump
    local c; c=$(_access_compose)
    echo "$c" | grep -q 'CCO_CONTAINER_OPERATOR=1'    || fail "operator env expected under read"
    echo "$c" | grep -q 'CCO_CCO_ACCESS=read-all'     || fail "legacy read should resolve to CCO_CCO_ACCESS=read-all"
    echo "$c" | grep -qE ':/home/claude/\.cco:ro"'    || fail "~/.cco should be ro under read"
    echo "$c" | grep -qE '/var/lib/cco-internal/state/cco/shared"' || fail "STATE/shared expected under privileged root"
    # STATE crosses on an ALLOW-LIST: only shared/ (+ the :ro running/ registry).
    # Never the whole state dir, and never remotes-token.
    if echo "$c" | grep -qE ':/var/lib/cco-internal/state/cco"'; then fail "whole STATE dir must not be mounted"; fi
    if echo "$c" | grep -q 'remotes-token'; then fail "remotes-token must never be mounted"; fi
}

# --cco-access edit-global → A2 (~/.cco) + DATA rw.
test_operator_edit_global_rw_buckets() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    run_cco start "test-proj" --cco-access edit-global --dry-run --dump
    local c; c=$(_access_compose)
    echo "$c" | grep -qE ':/home/claude/\.cco"'                   || fail "~/.cco should be rw under edit-global"
    echo "$c" | grep -qE ':/var/lib/cco-internal/share/cco"'      || fail "DATA mounts under the cco-svc privileged root"
    # STATE crosses via shared/ only, under the privileged root (ADR-0047 §4: no :ro
    # flag — the parent boundary + the helper's (G,Pc,Po) gate are the enforcement,
    # not the mode). A DIRECTORY bind, so index writers have a writable parent (v3 R1).
    echo "$c" | grep -qE '/var/lib/cco-internal/state/cco/shared"' || fail "STATE/shared mounts under the privileged root"
}

# Real secret files masked out of the repo .cco (rw edit mount); *.example survives.
test_operator_secret_masking_repo() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    printf 'S=1\n' > "$CCO_DUMMY_REPO/.cco/secrets.env"
    printf 'S=\n'  > "$CCO_DUMMY_REPO/.cco/secrets.env.example"
    printf 'k\n'   > "$CCO_DUMMY_REPO/.cco/tls.key"
    run_cco start "test-proj" --cco-access edit-all --dry-run --dump
    local c; c=$(_access_compose)
    echo "$c" | grep -qE 'secret-mask:/workspace/dummy-repo/\.cco/secrets\.env:ro"' || fail "secrets.env should be masked"
    echo "$c" | grep -qE 'secret-mask:/workspace/dummy-repo/\.cco/tls\.key:ro"'     || fail "tls.key should be masked"
    if echo "$c" | grep -qE 'secret-mask:.*secrets\.env\.example'; then fail "*.example must NOT be masked"; fi
}

# Secret masking applies even to a normal session's :ro .cco overlay.
test_operator_secret_masking_normal_session() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    mkdir -p "$CCO_DUMMY_REPO/.cco"
    printf 'S=1\n' > "$CCO_DUMMY_REPO/.cco/secrets.env"
    run_cco start "test-proj" --dry-run --dump   # cco_access=read-project (normal default)
    local c; c=$(_access_compose)
    echo "$c" | grep -qE 'secret-mask:/workspace/dummy-repo/\.cco/secrets\.env:ro"' \
        || fail "secrets.env masked even in a normal session (capability matrix: filtered in every column)"
}

# Global secret (~/.cco/secrets.env) masked on the A2 mount.
test_operator_secret_masking_global_store() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    printf 'G=1\n' > "$HOME/.cco/secrets.env"
    run_cco start "test-proj" --cco-access edit-global --dry-run --dump
    local c; c=$(_access_compose)
    echo "$c" | grep -qE 'secret-mask:/home/claude/\.cco/secrets\.env:ro"' \
        || fail "~/.cco/secrets.env should be masked on the A2 mount"
}

# B3 axis stays separate from A2: the ~/.cco/.claude authoring tree follows claude
# Cg, not the cco store's rw. Under edit-global (rw,rw,none) claude DERIVES Cg=rw
# (concordant, ADR-0049 §2), so B3 is rw and no guard overlay appears. Tightening
# claude to global=ro (discordant-safe) re-overlays ~/.cco/.claude :ro even though
# the store (A2) is rw — the two axes stay independent.
test_operator_b3_guard_ro_under_edit_global() {
    local tmpdir; tmpdir=$(mktemp -d); trap "rm -rf '$tmpdir'" EXIT
    setup_cco_env "$tmpdir"
    setup_global_from_defaults "$tmpdir"
    create_project "$tmpdir" "test-proj" "$(minimal_project_yml test-proj)"
    # edit-global alone → claude Cg=rw → B3 rw, no guard overlay.
    run_cco start "test-proj" --cco-access edit-global --dry-run --dump
    local c; c=$(_access_compose)
    if echo "$c" | grep -qE ':/home/claude/\.cco/\.claude:ro"'; then
        fail "B3 should be rw under edit-global (claude Cg derives rw) — no guard overlay"
    fi
    # Tighten claude global authoring to ro while the store stays rw → guard fires.
    run_cco start "test-proj" --cco-access edit-global --claude-access global=ro --dry-run --dump
    c=$(_access_compose)
    echo "$c" | grep -qE ':/home/claude/\.cco/\.claude:ro"' \
        || fail "~/.cco/.claude should be re-overlaid :ro when claude Cg=ro but the store is rw"
}
