#!/usr/bin/env bash
# lib/cmd-init.sh — the single project entry verb (ADR-0026)
#
# `cco init` (clean) does TWO things, run inside a repo:
#   1. ensures the global config (~/.cco/.claude) from the framework defaults,
#      idempotently — only when absent (fresh user); a one-time no-op afterwards.
#   2. scaffolds the per-repo committed <repo>/.cco/ (design §2.1) and registers
#      it in the STATE index.
# `cco init --migrate <project>` is the lazy per-project vault migration (ADR-0021).
#
# Ownership split (ADR-0026): J0 owns the empty roots; `cco init` owns the global
# CONTENT for a fresh user + the project scaffold; `cco update` owns the legacy
# vault migration. No `cco setup` verb (design §8).
#
# Provides: cmd_init()
# Dependencies: colors.sh, utils.sh, paths.sh, migrate.sh, index.sh, update*.sh,
#   secrets.sh, cmd-build.sh
# Globals: DEFAULTS_DIR, NATIVE_TEMPLATES_DIR, REPO_ROOT, GLOBAL_UNTRACKED_FILES

cmd_init() {
    local force=false
    local lang_arg=""
    local migrate_project=""
    local do_sync=false
    local name_arg=""
    local repo_name_arg=""
    local tmpl_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            --migrate)
                [[ -z "${2:-}" ]] && die "--migrate requires a project name (cco init --migrate <project>)"
                migrate_project="$2"; shift 2 ;;
            --sync) do_sync=true; shift ;;
            --name)
                [[ -z "${2:-}" ]] && die "--name requires a value (cco init --name <project>)"
                name_arg="$2"; shift 2 ;;
            --repo-name)
                [[ -z "${2:-}" ]] && die "--repo-name requires a value (cco init --repo-name <name>)"
                repo_name_arg="$2"; shift 2 ;;
            --template)
                [[ -z "${2:-}" ]] && die "--template requires a template name (cco init --template <name>)"
                tmpl_name="$2"; shift 2 ;;
            --lang)
                [[ -z "${2:-}" ]] && die "--lang requires a value (e.g. --lang Italian)"
                lang_arg="$2"; shift 2 ;;
            --help|-h)
                cat <<'EOF'
Usage: cco init [--name <project>] [--repo-name <name>] [--template <name>] [--force] [--lang <language>]
       cco init --migrate <project> [--sync]   (run inside a cloned repo)

Run inside a repo, `cco init` ensures your global config (~/.cco/.claude, only the
first time) and scaffolds this repo's committed .cco/ project config, registering
it on this machine. The current repo is seeded into the project's repos[] (its url
derived from `git remote get-url origin` when present), so `cco start` mounts it
without a manual edit. `--template` scaffolds from a named project template instead
of the base. `--migrate` instead brings one legacy-vault project into this
repo's .cco/.

Options:
  --name <project>       Project name (default: prompt with the repo basename)
  --repo-name <name>     Logical name of the current repo, seeded into repos[]
                         (default: prompt with the repo basename; an axis
                         independent of --name)
  --template <name>      Scaffold from project template <name> (user store first,
                         then native; default: base)
  --force                Overwrite an existing <repo>/.cco/ scaffold
  --migrate <project>    Migrate <project> from the legacy vault into this repo's
                         .cco/ (machine-agnostic; index + memory relocated)
  --sync                 With --migrate: propagate the .cco/ to the project's
                         other member repos
  --lang <lang>          Set global languages non-interactively (first run only).
                         Single value: cco init --lang Italian
                         Three values:  cco init --lang "Italian:Italian:English"
                         Format: communication[:docs[:code]]
EOF
                return 0
                ;;
            -*) die "Unknown option: $1" ;;
            *) die "Unexpected argument: $1 (did you mean --name $1?)" ;;
        esac
    done

    # Lazy per-project migration mode (ADR-0021): an alternative to a clean init —
    # hydrate this repo's .cco/ from the legacy-vault backup.
    if [[ -n "$migrate_project" ]]; then
        [[ -n "$tmpl_name" ]] && die "--template and --migrate are mutually exclusive."
        _cco_migrate_project "$migrate_project" "$do_sync"
        return $?
    fi

    # 1. Ensure the global config (idempotent). Returns 0 if it seeded the global
    #    (fresh user, or an explicit --force re-seed) so we know to build the
    #    image, 1 if it was already present and left untouched.
    local seeded_global=false
    if _cco_init_ensure_global "$lang_arg" "$force"; then
        seeded_global=true
    fi

    # 2. Scaffold the committed <repo>/.cco/ in the current repo + register it.
    _cco_init_scaffold_repo "$name_arg" "$force" "$tmpl_name" "$repo_name_arg"

    # 3. Build the Docker image only on a fresh global seed (first run); a
    #    project-only re-init does not rebuild. Skipped under CCO_SKIP_BUILD=1.
    if $seeded_global; then
        if [[ "${CCO_SKIP_BUILD:-}" == "1" ]]; then
            :
        elif docker info >/dev/null 2>&1; then
            echo "" >&2
            info "Building Docker image..."
            cmd_build
        else
            echo "" >&2
            warn "Docker not running. Run 'cco build' when Docker is available."
        fi
        if ! command -v cco &>/dev/null; then
            echo "" >&2
            info "Add cco to your PATH:"
            echo "  echo 'export PATH=\"\$PATH:$REPO_ROOT/bin\"' >> ~/.bashrc && source ~/.bashrc" >&2
        fi
    fi

    return 0
}

# ── Global-config ensure (ADR-0026 step 1) ───────────────────────────
# Scaffold ~/.cco/access.yml COMMENTED, only when absent (ADR-0049 §9). It is the
# user's explicit GLOBAL access default — the level-3 tier below CLI flags and a
# project.yml `access:` block, above the built-in cco-derived defaults. Written
# fully commented so nothing is set implicitly: the user sees the escape exists but
# every knob keeps its derived default until they uncomment a line. Idempotent —
# never clobbers an existing (possibly edited) file. Both knobs accept a scalar
# preset OR a granular map (symmetric with project.yml `access:`).
_write_access_scaffold() {
    local f; f=$(_cco_access_file)   # ~/.cco/access.yml
    [[ -f "$f" ]] && return 0
    mkdir -p "$(dirname "$f")" || return 0
    cat > "$f" <<'YAML'
# ~/.cco/access.yml — your GLOBAL session-access defaults (all OPTIONAL).
# Precedence: CLI flags > a project's project.yml `access:` block > THIS file >
# built-in defaults. Everything here is commented: uncomment only what you want to
# change globally. Both knobs take a scalar preset OR a granular map.

# ── .cco config access (cco_access, ADR-0046) ────────────────────────
# Scalar preset:
# cco: read-project        # none | read-project (default) | read-global |
#                          #   read-all | edit-project | edit-global | edit-all
# …or a granular map — three axes on the lattice none < ro < rw:
# cco:
#   global: ro             # G  — the rest of the personal ~/.cco store
#   current: ro            # Pc — this project's config (never none while enabled)
#   others: none           # Po — other projects' config (Po <= Pc)

# ── .claude authoring access (claude_access, ADR-0049) ───────────────
# By DEFAULT claude_access DERIVES from cco (never more permissive): a read-only
# cco session keeps .claude read-only too. Set this only to author .claude.
# Scalar preset:
# claude: none             # none (all .claude read-only) | repo (author repo-native
#                          #   + this project's .claude) | all (author every tree)
# …or a granular map — four axes on the lattice ro < rw (omitted axes derive from cco):
# claude:
#   repo: ro               # Cr — <repo>/.claude repo-native (default ro)
#   current: ro            # Cp — <repo>/.cco/claude       (default = cco current)
#   global: ro             # Cg — ~/.cco/.claude           (default = cco global)
#   others: ro             # Co — other projects' .claude  (default = cco others)

# ── Host path map (show_host_paths) ──────────────────────────────────
# show_host_paths: true    # show the host<->container path map (default: true)
YAML
    return 0
}

# Seed ~/.cco/.claude from the framework defaults ONLY when absent. Idempotent:
# returns 0 (and seeds) on a fresh user, 1 (no-op) when the global already exists.
# Targets $(_cco_global_claude_dir) = ~/.cco/.claude (flat, ADR-0028 — no `global/`
# wrapper). Emits NO manifest.yml (ADR-0012) and touches NO central PROJECTS_DIR.
_cco_init_ensure_global() {
    local lang_arg="$1" force="${2:-false}"
    local cfg gclaude
    cfg="$(_cco_config_dir)"          # ~/.cco
    gclaude="$(_cco_global_claude_dir)"   # ~/.cco/.claude

    # Already set up → one-time no-op (fresh users get it here; migrating users
    # get it from `cco update`, ADR-0025). An explicit --force re-seeds from the
    # framework defaults (the documented reset escape hatch; clobbers local edits).
    if [[ -d "$gclaude" ]]; then
        [[ "$force" == "true" ]] || return 1
        rm -rf "$gclaude"
    fi

    # Language selection (prompt unless --lang given) — only on a fresh seed.
    local comm_lang docs_lang code_lang
    if [[ -n "$lang_arg" ]]; then
        IFS=':' read -r comm_lang docs_lang code_lang <<< "$lang_arg"
        comm_lang="${comm_lang:-English}"
        docs_lang="${docs_lang:-$comm_lang}"
        code_lang="${code_lang:-English}"
    elif (exec < /dev/tty) 2>/dev/null; then
        echo "" >&2
        info "Language configuration"
        echo "  Common choices: English, Italian, Spanish, French, German, Portuguese" >&2
        read -rp "  Communication language (Claude responses) [English]: " comm_lang < /dev/tty
        comm_lang="${comm_lang:-English}"
        read -rp "  Documentation language [${comm_lang}]: " docs_lang < /dev/tty
        docs_lang="${docs_lang:-$comm_lang}"
        read -rp "  Code comments language [English]: " code_lang < /dev/tty
        code_lang="${code_lang:-English}"
    else
        comm_lang="English"; docs_lang="English"; code_lang="English"
    fi

    info "Initializing global config at $gclaude ..."
    mkdir -p "$cfg" || die "Failed to create config directory: $cfg"
    cp -r "$DEFAULTS_DIR/global/.claude" "$gclaude" \
        || die "Failed to copy default config from $DEFAULTS_DIR/global/.claude"

    # Replace language placeholders.
    local lang_file="$gclaude/rules/language.md"
    _substitute "$lang_file" "COMM_LANG" "$comm_lang"
    _substitute "$lang_file" "DOCS_LANG" "$docs_lang"
    _substitute "$lang_file" "CODE_LANG" "$code_lang"

    # Global setup scripts / MCP package list → ~/.cco top-level (design §2.3).
    local f
    for f in setup.sh setup-build.sh mcp-packages.txt; do
        [[ -f "$DEFAULTS_DIR/global/$f" ]] && cp "$DEFAULTS_DIR/global/$f" "$cfg/$f"
    done

    # Build the global STATE meta (hashes + schema) — H6, already STATE-relocated.
    local latest_schema latest_changelog now meta_file
    latest_schema=$(_latest_schema_version "global")
    latest_changelog=$(_latest_changelog_id)
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    meta_file=$(_cco_global_meta)
    (
        cd "$gclaude" || exit 1
        find . -type f ! -name 'meta' ! -path './.cco/*' | sed 's|^\./||' | sort | while IFS= read -r rel; do
            local skip=false uf
            for uf in ${GLOBAL_UNTRACKED_FILES[@]+"${GLOBAL_UNTRACKED_FILES[@]}"}; do
                [[ "$rel" == "$uf" ]] && skip=true && break
            done
            $skip && continue
            printf '%s\t%s\n' "$rel" "$(_file_hash "$gclaude/$rel")"
        done
    ) | _generate_cco_meta "$meta_file" "$latest_schema" "$now"

    # Decomposed config/state datums (ADR-0013 D4): languages → ~/.cco,
    # changelog markers → STATE top-level.
    _write_languages "$comm_lang" "$docs_lang" "$code_lang"
    _write_access_scaffold   # ~/.cco/access.yml commented escape (ADR-0049 §9)
    _write_last_seen_changelog "$latest_changelog"
    _write_last_read_changelog "$latest_changelog"

    # Save base versions for future 3-way merge (STATE).
    _save_all_base_versions "$(_cco_global_base_dir)" "$DEFAULTS_DIR/global/.claude" "global"

    # Fresh install — nothing to migrate, just marks the schema current.
    if ! _run_migrations "global" "$gclaude" 0 "$meta_file"; then
        error "Migrations failed during init. Run 'cco update' to retry."
    fi

    ok "Global config initialized at $gclaude (languages: $comm_lang / $docs_lang / $code_lang)"
    return 0
}

# ── Per-repo scaffold (ADR-0026 step 2 / design §2.1) ────────────────
# Write the committed <repo>/.cco/ in the current repo from templates/project/base
# and register it in the STATE index. Refuses an existing .cco/ unless --force.
_cco_init_scaffold_repo() {
    local name_arg="$1" force="$2" tmpl_name="${3:-}" repo_name_arg="${4:-}"
    local target="$PWD"
    local ccodir="$target/.cco"

    if [[ -d "$ccodir" ]] && [[ "$force" != "true" ]]; then
        die "$ccodir already exists — refusing to clobber. Use --force to overwrite, or 'cco join' to add this repo to an existing project."
    fi

    # Resolve the project name: --name › prompt(basename) › basename.
    local name; name=$(_cco_init_resolve_name "$name_arg")
    _cco_valid_project_name "$name" \
        || die "Invalid project name '$name' — must be lowercase letters, numbers, and hyphens, starting alphanumeric. Pass --name <name>."
    _check_reserved_project_name "$name"

    # F12 name-uniqueness: the name must not already bind a DIFFERENT repo. Binding
    # the same name to the same repo is a legitimate re-init (e.g. --force).
    local existing_path; existing_path=$(_index_get_path "$name" 2>/dev/null || true)
    if [[ -n "$existing_path" && "$existing_path" != "$target" ]]; then
        die "A project named '$name' is already registered to $existing_path. Choose another name (--name) or 'cco forget' it first."
    fi
    # A migrated/joined project records its name in the projects: registry but its
    # host repo path under the member repo names, not under the project name — so the
    # paths: check above can miss it. Reject a name already taken there too (H3).
    local existing_repos; existing_repos=$(_index_get_project_repos "$name" 2>/dev/null || true)
    if [[ -n "$existing_repos" && "$existing_path" != "$target" ]]; then
        die "A project named '$name' is already registered. Choose another name (--name) or 'cco forget' it first."
    fi

    # Resolve the hosting repo's LOGICAL name (its repos[] entry + index member
    # key). Its default is the dir basename — an axis independent of the project
    # name, both editable (--repo-name / prompt). The member is keyed by THIS name
    # (not the project name) so a repo name that diverges from the project name
    # still resolves — the same coordinate model as `cco join` (ADR-0017 D1/D2).
    local repo_name; repo_name=$(_cco_init_resolve_repo_name "$repo_name_arg")
    _cco_valid_project_name "$repo_name" \
        || die "Invalid repo name '$repo_name' — must be lowercase letters, numbers, and hyphens, starting alphanumeric. Pass --repo-name <name>."
    # The repo logical name must not already bind a DIFFERENT path in the index
    # (re-binding the same repo on a --force re-init is legitimate).
    local rn_existing; rn_existing=$(_index_get_path "$repo_name" 2>/dev/null || true)
    if [[ -n "$rn_existing" && "$rn_existing" != "$target" ]]; then
        die "A repo named '$repo_name' is already bound to $rn_existing in the index. Choose another --repo-name, or 'cco forget' it first."
    fi

    # Resolve the source project-template: --template <name> (user store first,
    # then native — _resolve_template), else the native base. Every project
    # template shares the base structure (project.yml + .claude/ + H5 files +
    # secrets.env skeleton), so the copy logic below is template-agnostic.
    local tmpl
    if [[ -n "$tmpl_name" ]]; then
        tmpl=$(_resolve_template "project" "$tmpl_name")
    else
        tmpl="$NATIVE_TEMPLATES_DIR/project/base"
    fi
    [[ -d "$tmpl" ]] || die "Project template '${tmpl_name:-base}' not found."

    # Stage as a SIBLING of the target .cco (M1): same filesystem, so the move into
    # place is an atomic rename — a stage under $TMPDIR (often a separate tmpfs) makes
    # `mv` a non-atomic cross-device copy that can leave a partial .cco/ (breaks F44).
    local stage; stage=$(mktemp -d "$target/.cco-scaffold.XXXXXX") \
        || die "Could not create a staging dir in $target (is it writable?)."
    # shellcheck disable=SC2064
    # EXIT (not RETURN): die() exits, bypassing a RETURN trap and leaking the stage (H2).
    trap "rm -rf '$stage'" EXIT
    mkdir -p "$stage/claude"

    # project.yml — base template with logical names only (no real paths; AD3/G8).
    cp "$tmpl/project.yml" "$stage/project.yml"

    # claude/ — authored project config (CLAUDE.md, settings.json, agents/rules/skills).
    cp -r "$tmpl/.claude/." "$stage/claude/" 2>/dev/null || true

    # Resolve {{VAR}} placeholders across project.yml + the claude/ tree (ADR-0019
    # D7 scaffold-time; P4-4d follow-up): PROJECT_NAME is preset; on a TTY the
    # remaining vars (DESCRIPTION, any template-author custom vars) are prompted,
    # non-interactively DESCRIPTION defaults to a TODO and others substitute their
    # own name. Replaces the prior PROJECT_NAME/DESCRIPTION-only substitution.
    _resolve_template_vars "$stage" "$name"

    # H5 optional project config carried by the base template.
    local f
    for f in mcp.json setup.sh mcp-packages.txt; do
        [[ -f "$tmpl/$f" ]] && cp "$tmpl/$f" "$stage/$f"
    done

    # secrets.env.example — committed skeleton (the real secrets.env is gitignored,
    # user-created). Derive from the template skeleton.
    if [[ -f "$tmpl/secrets.env" ]]; then
        cp "$tmpl/secrets.env" "$stage/secrets.env.example"
    fi

    # .cco/.gitignore — secret exclusions (design §2.1; reused writer).
    _cco_write_project_gitignore "$stage/.gitignore"

    # Secret-scan committed files (secrets.env gitignored; *.example exempt, FR-S3).
    local cf hit
    while IFS= read -r cf; do
        [[ "$cf" == *.example ]] && continue
        if hit=$(_secret_match_filename "$cf" 2>/dev/null) && [[ -n "$hit" ]]; then
            die "Refusing to scaffold: a secret-like file would be committed: ${cf#$stage/}"
        fi
    done < <(find "$stage" -type f)

    # Atomic move into place (a partial .cco/ never survives a failure).
    [[ -d "$ccodir" ]] && rm -rf "$ccodir"     # only when --force
    mv "$stage" "$ccodir" || die "Failed to install the scaffolded .cco/ into $target."

    # Seed the hosting repo into the committed project.yml repos[]: a
    # machine-agnostic coordinate (logical name + OPTIONAL url from origin). The
    # local path never enters project.yml — it lives only in the index (AD3/G8).
    # Without this the manifest would ship an empty repos[] and `cco start` would
    # mount nothing despite the index knowing the repo (init/start inconsistency).
    local repo_url=""
    if git -C "$target" rev-parse --git-dir >/dev/null 2>&1; then
        repo_url=$(git -C "$target" remote get-url origin 2>/dev/null || true)
    fi
    local -a _repo_fields=()
    [[ -n "$repo_url" ]] && _repo_fields+=("url=$repo_url")
    _yml_append_coord "$ccodir/project.yml" repos "$repo_name" ${_repo_fields[@]+"${_repo_fields[@]}"}

    # Register in the STATE index: this repo hosts the project and is its own
    # (sole) member, keyed by the repo's LOGICAL name (same shape as migrate/join;
    # repo_name defaults to — but may diverge from — the project name).
    _index_set_path "$repo_name" "$target"
    _index_set_project_repos "$name" "$repo_name"

    # Born at the latest schema (decentralized projects are scaffolded in final
    # form) + seed the 3-way-merge base, so `cco update` runs zero migrations and
    # sees no spurious diffs (P5).
    _cco_project_seed_update_state "$ccodir" "${tmpl_name:-base}"

    ok "Scaffolded project '$name' in $ccodir/"
    if [[ -n "$repo_url" ]]; then
        echo "  Seeded repos[] with '$repo_name' (url: $repo_url) + registered it in the index (1 repo)." >&2
    else
        echo "  Seeded repos[] with '$repo_name' + registered it in the index (1 repo; no origin url — add one later in project.yml)." >&2
    fi
    echo "  Next: cco start $name" >&2
    return 0
}

# Resolve the scaffold project name (ADR-0026 / maintainer-confirmed naming):
# --name wins; else prompt interactively with the repo basename as the default
# (Enter accepts); non-interactive falls back to the basename. Validation is the
# caller's job. Echoes the chosen name on stdout (the read prompt goes to the tty,
# so $(...) capture stays clean).
_cco_init_resolve_name() {
    local name_arg="$1" base name=""
    base=$(basename "$PWD")
    if [[ -n "$name_arg" ]]; then
        name="$name_arg"
    elif (exec < /dev/tty) 2>/dev/null; then
        # B-DF2: no `2>/dev/null` on the read — bash writes the `-p` prompt to stderr,
        # so redirecting it swallows the prompt and the command looks hung. The tty is
        # already proven available by the guard above; `|| name=""` handles a read fail.
        read -rp "  Project name [$base]: " name < /dev/tty || name=""
        name="${name:-$base}"
    else
        name="$base"
    fi
    printf '%s' "$name"
}

# Resolve the hosting repo's LOGICAL name: --repo-name › prompt(basename) ›
# basename. An axis independent of the project name (both default to the dir
# basename). Same TTY discipline as _cco_init_resolve_name (B-DF2: no 2>/dev/null
# on the read, or the bash `-p` prompt written to stderr is swallowed and the
# command looks hung). Echoes the chosen name on stdout.
_cco_init_resolve_repo_name() {
    local repo_arg="$1" base name=""
    base=$(basename "$PWD")
    if [[ -n "$repo_arg" ]]; then
        name="$repo_arg"
    elif (exec < /dev/tty) 2>/dev/null; then
        read -rp "  Repo name [$base]: " name < /dev/tty || name=""
        name="${name:-$base}"
    else
        name="$base"
    fi
    printf '%s' "$name"
}
