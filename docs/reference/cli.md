# CLI Specification

> Version: 1.0.0
> Status: v1.0 — Current
> Related: [spec.md](../maintainer/architecture/spec.md) | [docker.md](../maintainer/integration/docker/design.md)

---

## 1. Overview

The CLI is a single bash script at `bin/cco` that orchestrates Docker sessions. It has no dependencies beyond `bash` (3.2+), `docker`, and standard Unix tools (`sed`, `awk`, `jq`).

> **Note for macOS users**: macOS ships with bash 3.2 (`/bin/bash`). This is the minimum supported version — no Homebrew bash required.

---

## 2. Installation

```bash
# Clone the repo
git clone <repo-url> ~/claude-orchestrator
cd ~/claude-orchestrator

# Build the Docker image, then seed the personal ~/.cco store + init a repo
cco build
cd ~/dev/my-repo && cco init

# Add to PATH (if not done automatically)
# bash:
echo 'export PATH="$PATH:$HOME/claude-orchestrator/bin"' >> ~/.bashrc && source ~/.bashrc
# zsh:
# echo 'export PATH="$PATH:$HOME/claude-orchestrator/bin"' >> ~/.zshrc && source ~/.zshrc
```

---

## 3. Commands

### 3.0 `cco init`

`cco init` is the **single project entry verb**. It is idempotent: it ensures the
personal global config store (`~/.cco/`) exists, then scaffolds a clean `<repo>/.cco/`
in the current repo and registers it in the machine-local index.

```
Usage: cco init [--migrate <project> [--sync]] [--sync] [--lang <language>]

Options:
  --migrate <project>  Hydrate this repo's .cco/ from the legacy vault backup for
                       <project> (lazy, per-project migration). A mode of cco init.
  --sync               Propagate the new member's project.yml repos[] edit / config
                       to the project's other config-bearing repos
  --lang <language>    Set communication language for Claude (default: English),
                       used when seeding ~/.cco/global on a fresh machine

Examples:
  cco init                          # Scaffold <repo>/.cco/ in the current repo
  cco init --lang Italian           # Seed ~/.cco/global with Italian communication
  cco init --migrate my-saas        # Hydrate this repo from the legacy backup
```

**What `cco init` does**

1. **Ensure the global config** — seed `~/.cco/global/` from the framework defaults
   **only if absent** (no `manifest.yml` is created). Global content for a fresh user
   lives in `~/.cco/`. This step is idempotent — an existing `~/.cco/` is left untouched.
2. **Scaffold `<repo>/.cco/`** — write a clean `project.yml` (logical names + coordinates),
   `secrets.env.example`, `.gitignore`, and the `claude/` config tree in the current repo.
3. **Register in the index** — record the repo's logical name → absolute path in the
   machine-local STATE index (`<state>/cco/index`).

`cco init`, `cco init --migrate`, and `cco join` are **mutually exclusive** entry points
for a repo: `cco init` = clean config; `cco init --migrate <old>` = bring a legacy vault
project's config into this repo; `cco join` = become a member of a project already defined
in another repo. The inverse (deregister) is `cco forget`.

**`--lang` and language templates**

The file `defaults/global/.claude/rules/language.md` contains three placeholders that the
global seed substitutes:

| Placeholder | Controls | Example value |
|-------------|----------|---------------|
| `{{COMM_LANG}}` | Claude's response/communication language | `Italian` |
| `{{DOCS_LANG}}` | Language for docs (README, guides) | `English` |
| `{{CODE_LANG}}` | Language for code comments/docstrings | `English` |

When `--lang` is provided, `{{COMM_LANG}}` is set to that language. `{{DOCS_LANG}}` and
`{{CODE_LANG}}` always default to `English` (code is universal). To customize further, edit
`~/.cco/global/.claude/rules/language.md` directly.

**First-run bootstrap (J0)**: on a fresh machine, **any** `cco` command (including `cco init`,
`cco start`, `cco new`) first creates the four config roots when missing — `~/.cco/`
(git-init'd) plus the three internal XDG bases DATA (`~/.local/share/cco`),
STATE (`~/.local/state/cco`), and CACHE (`~/.cache/cco`). This is per-root and idempotent.
If a legacy vault is present, the first run **backs it up** (into STATE) and prints migration
instructions. The eager global config migration is owned by `cco update`; per-project
migration is lazy via `cco init --migrate`.

---

### 3.1 `cco build`

Build or rebuild the Docker image.

```
Usage: cco build [--no-cache] [--mcp-packages "pkg1 pkg2"] [--claude-version "x.y.z"]

Options:
  --no-cache               Force rebuild without Docker cache (updates Claude Code)
  --mcp-packages "pkgs"    Pre-install MCP server npm packages in the image
  --claude-version "x.y.z" Pin Claude Code to a specific version (default: latest)

Examples:
  cco build
  cco build --no-cache
  cco build --claude-version 1.0.5
  cco build --mcp-packages "@modelcontextprotocol/server-github"
```

MCP packages can also be listed in `~/.cco/mcp-packages.txt` (one per line) for automatic loading on every build.

---

### 3.2 `cco start <project>`

Start an interactive Claude Code session for a configured project.

```
Usage: cco start [project] [OPTIONS]

Arguments:
  project              Name of the project. Optional when run from a repo dir:
                       the invoking repo's <repo>/.cco/ selects the project it hosts.

Options:
  --from <repo>        Pick which member's <repo>/.cco to use (Case-C divergence source)
  --teammate-mode <m>  Override display mode: tmux | auto
  --api-key            Use ANTHROPIC_API_KEY instead of OAuth
  --chrome             Enable browser automation for this session only
  --no-chrome          Disable browser automation for this session only
  --no-docker          Disable Docker socket mount for this session only
  --dry-run            Show the generated docker-compose without running
                       (uses ephemeral staging via mktemp, no persistent files)
  --dump               With --dry-run: write output to .tmp/ for inspection
  --port <p>           Add extra port mapping (repeatable)
  --env <K=V>          Add extra environment variable (repeatable)

Session flags override project.yml for one session only.
To change the default, edit project.yml instead.

Examples:
  cco start                          # From a repo dir: start the project it hosts
  cco start my-saas
  cco start my-saas --from frontend  # Use frontend's <repo>/.cco when repos diverge
  cco start my-saas --chrome         # enable browser for this session
  cco start my-saas --no-chrome      # disable browser for this session
  cco start my-saas --no-docker      # disable Docker socket for this session
  cco start my-saas --teammate-mode auto
  cco start my-saas --port 9090:9090
  cco start my-saas --dry-run
  cco start tutorial                 # built-in tutorial (see below)
  cco start config-editor            # built-in config editor (mounts ~/.cco rw)
```

**Source selection & resolution**: from a repo dir, `cco start` uses the invoking repo's
`.cco/` → the project that repo **hosts** (unambiguous: a repo hosts at most one project).
By name, if the project's config-bearing repos diverge, the source precedence is
`--from <repo>` > the optional `entry` repo > prompt. Absolute paths for every repo/mount
come from the machine-local index (`<state>/cco/index`); if any repo/mount is unresolved,
`cco start` prompts to **[r]esolve** (`cco resolve`), **[c]lone from `<url>`** (when the
coordinate carries a `url`), or **[s]kip** — it never launches with a silent empty mount.
`cco start` always prints which `<repo>/.cco` source it used.

**Reserved names: `tutorial`, `config-editor`**

`cco start tutorial` launches the built-in interactive tutorial directly from
`internal/tutorial/`; `cco start config-editor` launches the built-in config editor
(mounts `~/.cco` rw in global mode; `--project <name>` or a cwd hosting a configured repo
also mounts that project's `<repo>/.cco` rw). They are not user projects — they always
reflect the current framework version. These names are reserved.

**Flow**:

```
1. RESOLVE source + members (H1: resolution before notices)
   - From a repo dir: use the invoking repo's <repo>/.cco/ (the project it hosts);
     by name: resolve via the index (--from > entry > prompt on divergence)
   - Resolve each member repo/mount via the index; unresolved → prompt resolve|clone|skip
   - Check no existing running session for this project (die if container cc-<name> is running)
   - Check Docker image exists (suggest `cco build` if not)

2. GENERATE docker-compose.yml (into CACHE, host-absolute mount sources)
   - Read project.yml repos → generate volume mounts (paths from the index)
   - Read project.yml ports → generate port mappings
   - Read project.yml auth → set auth volumes/env vars
   - If mcp.json exists → mount as /workspace/.mcp.json (Claude Code expands ${VAR} natively)
   - Mount global MCP config for entrypoint merge
   - Apply CLI overrides (--port, --env, --teammate-mode)
   - Write to <cache>/cco/projects/<id>/docker-compose.yml

3. GENERATE pack + framework resources (into CACHE, overlaid :ro)
   - Detect name conflicts across packs (warn if same agent/rule/skill in multiple packs)
   - Add pack resource mounts (knowledge dirs, per-file rules/agents, per-dir skills — all :ro)
   - Generate packs.md (instructional list of knowledge files) + workspace.yml (project summary)
     into <cache>/cco/projects/<id>/.claude/ and overlay :ro onto /workspace/.claude

4. CREATE state dirs (if needed)
   - <state>/cco/projects/<id>/claude-state/  (session transcripts; enables /resume across rebuilds)
   - <state>/cco/projects/<id>/session/memory/  (auto memory; machine-local STATE, no sync in v1)

5. LAUNCH
   - Load ~/.cco/secrets.env as runtime env vars (validates KEY=VALUE format, skips malformed lines with warning)
   - docker compose -f <cache>/cco/projects/<id>/docker-compose.yml run --rm --service-ports claude

6. CLEANUP (after exit)
   - Container auto-removed (--rm)
   - Print summary: "Session ended. Changes are in your repos."
```

---

### 3.3 `cco new`

Start a temporary session without a project template.

```
Usage: cco new [OPTIONS]

Options:
  --repo <path>        Repository to mount (repeatable, at least one required)
  --name <name>        Temporary session name (default: "tmp-<timestamp>")
  --teammate-mode <m>  Override display mode
  --port <p>           Port mapping (repeatable)

Examples:
  cco new --repo ~/projects/my-experiment
  cco new --repo ~/projects/api --repo ~/projects/frontend
  cco new --repo ~/projects/app --port 3000:3000
```

**Flow**:

```
1. VALIDATE
   - At least one --repo is provided
   - Each repo path exists
   - Check no existing running session with this name

2. GENERATE temporary docker-compose
   - Create temp dir: /tmp/cc-<name>/
   - Generate docker-compose.yml with:
     - Global config mounted from ~/.cco (same as `cco start`)
     - No project .claude/ (empty /workspace/.claude/)
     - Specified repos mounted as subdirectories (literal paths, no index read/write)
     - Auto memory in temp dir

3. LAUNCH
   - Same as `cco start` but with temp compose file

4. CLEANUP
   - Container removed
   - Temp dir preserved (.cco/claude-state/ may be useful)
   - Print path to temp dir for reference
```

---

### 3.4 `cco join` / `cco init --migrate`

Project entry has a single clean path — `cco init` (§3.0). The two alternative entry
modes are `cco join` (add the current repo to an existing project) and `cco init --migrate`
(hydrate a repo from a legacy vault backup). All three are **mutually exclusive** per repo.

#### `cco join <project>`

Add the current repo to `<project>` as a **member**: register it in the index and add it to
`repos[]` in the project's `project.yml`. The new member's `repos[]` edit propagates to every
repo that carries a synced copy (Case B); in a divergent project (Case C) `cco join` **prompts**
which repo's `project.yml` to update, or all.

```
Usage: cco join <project> [--sync]

Arguments:
  project              Name of an existing project (defined in another repo)

Options:
  --sync               Copy the project's <repo>/.cco/ into this repo (source prompted
                       if divergent). Without it, the repo stays a code-only member (Case A).

Examples:
  cco join my-saas             # Join as a code-only member (Case A)
  cco join my-saas --sync      # Join and receive a config copy (Case B)
```

The joining repo gets **no `.cco/`** (code-only member) unless `--sync` / interactive confirm,
which copies the project's `.cco/` into it. cco knows which repos are synced vs divergent from
its internal sync-state tracking.

#### `cco init --migrate <project> [--sync]`

Hydrate the current repo's `.cco/` with a project's config migrated from the **legacy vault
backup** (lazy, per-project). This is a **mode of `cco init`**, not a top-level `cco migrate`.

```
Usage: cco init --migrate <project> [--sync]

Arguments:
  project              Legacy project name to migrate from the vault backup

Options:
  --sync               Propagate the migrated config to all member repos
                       (symmetric to `cco join --sync`)

Examples:
  cco init --migrate my-saas           # Migrate one project into this repo (Case A)
  cco init --migrate my-saas --sync    # Migrate and propagate to member repos (Case B)
```

The first run on a machine **backs up** the legacy vault (into STATE) and prints migration
instructions on any command. The eager global config migration is owned by `cco update`;
this per-project path reads from that backup. A profile→tag prompt is offered per project
during migrate.

---

### 3.4b `cco forget <project>`

> 🚧 **Planned — ships in a later release.** Today `cco forget` is not available — the command
> reports that a dedicated deregistration ships later (ADR-0021). To drop a project now, remove
> the repo (or its `<repo>/.cco/`) with normal git/filesystem ops; the index self-heals on the
> next `cco resolve --scan`. The contract below is the target surface.

Deregister a project: remove cco's internal id-keyed state — index entry, tags, install
provenance, and the project's STATE/CACHE — **without** touching the repo or its committed
`<repo>/.cco/`. The inverse of `cco init`/`cco join`.

```
Usage: cco forget <project>

Arguments:
  project              Name of the project to deregister

Examples:
  cco forget old-service
```

`cco forget` only removes machine-local bookkeeping. The repo and its committed config are
untouched, so a later `cco resolve --scan` (or `cco start` from the repo) re-registers it.

---

### 3.5 `cco project list`

List available projects with their status.

```
Usage: cco project list

Output:
  NAME           REPOS    STATUS
  my-saas        3        stopped
  experiment     1        running
```

**Implementation**:
- List projects registered in the machine-local index (`<state>/cco/index` `projects:` map)
- Parse each repo's `<repo>/.cco/project.yml` for repo count
- Check Docker for running containers (`cc-<name>`)

---

### 3.5b `cco list` / `cco tag`

Per-user tags replace the removed vault profiles. Tags are **multi-valued per resource** and
**per-user** — they live in a machine-local-but-synced registry (`<data>/cco/tags.yml`, the
DATA bucket) and are never written into `project.yml`/`pack.yml` or shared with third parties.

#### `cco list [--tag <t>]`

List resources, optionally filtered by tag. Reads the per-user tag registry.

```
Usage: cco list [--tag <t>]

Options:
  --tag <t>            Show only resources carrying tag <t>

Examples:
  cco list                     # All resources
  cco list --tag work          # Only resources tagged "work"
```

#### `cco tag add` / `cco tag rm`

Add or remove a per-user tag on a resource (writes the DATA tag registry).

```
Usage: cco tag add <tag> <resource>
       cco tag rm  <tag> <resource>

Examples:
  cco tag add work my-saas
  cco tag rm  work my-saas
```

Tags are organizational only; they carry no privilege and never affect resolution or sharing.

---

### 3.6 `cco stop [project]`

Stop a running session.

```
Usage: cco stop [project]

Arguments:
  project     Stop specific project session. If omitted, stop all.

Examples:
  cco stop my-saas
  cco stop              # Stop all running sessions
```

**Implementation**:
```bash
# Specific project
docker stop cc-<project>

# All sessions
docker ps --filter "name=cc-" -q | xargs docker stop
```

---

### 3.7 `cco chrome [start|stop|status]`

Manage a Chrome debug session on the host for browser automation. Chrome runs on the host OS with remote debugging enabled, and the container connects to it via `chrome-devtools-mcp`.

```
Usage: cco chrome [start|stop|status] [OPTIONS]

Subcommands:
  start    Launch Chrome with remote debugging (default)
  stop     Kill the debug Chrome process
  status   Check if CDP endpoint is reachable

Options:
  --project <name>   Auto-detect port from project runtime state
  --port <n>         Explicit CDP port (default: 9222)

Examples:
  cco chrome                          # Launch Chrome on default port 9222
  cco chrome start --project my-saas  # Launch on the port assigned to my-saas
  cco chrome status                   # Check if Chrome is reachable
  cco chrome stop                     # Kill the debug Chrome process
```

**Port resolution priority**:
1. `--port <n>` — explicit flag
2. `--project <name>` → reads the project's generated `managed/.browser-port` in CACHE
   (`<cache>/cco/projects/<id>/managed/.browser-port`, the effective runtime port)
3. `--project <name>` → falls back to the project's `<repo>/.cco/project.yml` `browser.cdp_port`
4. Default: `9222`

**Notes**:
- This command runs on the host, not inside the container
- Chrome is launched with `--user-data-dir=$HOME/.chrome-debug` (isolated profile)
- `--remote-allow-origins=*` is set to allow container connections
- If the container is not running, a warning is shown but the port is still used

---

### 3.8 `cco pack create <name>`

Create a new knowledge pack scaffold.

```
Usage: cco pack create <name> [OPTIONS]

Arguments:
  name                 Pack name (lowercase letters, numbers, and hyphens only)

Options:
  --template <name>    Template to use (default: base). See `cco template list --pack`

Examples:
  cco pack create react-guidelines
  cco pack create devops-tools
  cco pack create my-pack --template custom-layout
```

**Flow**:

```
1. VALIDATE
   - Global config exists (check_global)
   - Name matches pattern: ^[a-z0-9][a-z0-9-]*$
   - ~/.cco/packs/<name>/ does not already exist

2. CREATE directory structure
   - ~/.cco/packs/<name>/
   - ~/.cco/packs/<name>/knowledge/
   - ~/.cco/packs/<name>/skills/
   - ~/.cco/packs/<name>/agents/
   - ~/.cco/packs/<name>/rules/

3. GENERATE pack.yml
   - Scaffold with name field and commented-out sections
     for knowledge, skills, agents, rules

4. PRINT
   - "Pack created at ~/.cco/packs/<name>/"
   - Hint: subdirectory purposes and how to declare resources
```

---

### 3.9 `cco pack list`

List all knowledge packs with resource counts.

```
Usage: cco pack list

Output:
  NAME              KNOWLEDGE  SKILLS  AGENTS  RULES
  devops-tools      3          1       0       2
  react-guidelines  5          2       1       3
```

**Implementation**:
- Iterates directories under `~/.cco/packs/`
- Parses each `pack.yml` for knowledge files, skills, agents, and rules counts
- Displays a formatted table with resource counts (shows `0` when a category is empty)

---

### 3.10 `cco pack show <name>`

Show detailed information for a knowledge pack.

```
Usage: cco pack show <name>

Arguments:
  name                 Pack name to inspect

Examples:
  cco pack show react-guidelines
```

**Flow**:

```
1. VALIDATE
   - ~/.cco/packs/<name>/ exists
   - pack.yml exists (warns if missing)

2. DISPLAY
   - Pack name (from pack.yml 'name' field)
   - Knowledge: source directory (if set) and file list with descriptions
   - Skills: list of skill names
   - Agents: list of agent files
   - Rules: list of rule files
   - Used by projects: scans all projects for packs referencing this name
```

---

### 3.11 `cco pack remove <name> [--force]`

Remove a knowledge pack.

```
Usage: cco pack remove <name> [--force]

Arguments:
  name                 Pack name to remove

Options:
  --force              Skip confirmation prompt

Examples:
  cco pack remove old-pack
  cco pack remove old-pack --force
```

**Flow**:

```
1. VALIDATE
   - ~/.cco/packs/<name>/ exists

2. CHECK usage
   - Scan all projects for references to this pack
   - If used by projects:
     - Display warning: "Pack '<name>' is used by: <project-list>"
     - Without --force: prompt for confirmation (y/N)
     - Non-interactive terminal without --force: error and abort

3. REMOVE
   - rm -rf ~/.cco/packs/<name>/
   - "Pack '<name>' removed"
```

---

### 3.12 `cco pack validate [name]`

Validate pack structure and configuration.

```
Usage: cco pack validate [name]

Arguments:
  name                 Pack name to validate (optional; validates all packs if omitted)

Examples:
  cco pack validate react-guidelines
  cco pack validate                      # Validate all packs
```

**Flow**:

```
1. VALIDATE (per pack)
   - pack.yml exists
   - pack.yml has valid top-level keys (name, knowledge, skills, agents, rules)
   - 'name' field is present and matches directory name (warns on mismatch)
   - Knowledge source directory exists (if specified)
   - Skill directories exist under skills/ for each declared skill
   - Agent files exist under agents/ for each declared agent
   - Rule files exist under rules/ for each declared rule

2. RESULT
   - Errors for missing/invalid resources
   - Warnings for non-critical issues (e.g., name mismatch)
   - Returns exit code 1 if any pack has errors
```

---

### 3.13 `cco project show <name>`

Show detailed information for a configured project.

```
Usage: cco project show <name>

Arguments:
  name                 Project name to inspect

Examples:
  cco project show my-saas
```

**Flow**:

```
1. VALIDATE
   - The project is resolvable (its host repo's <repo>/.cco/project.yml exists)

2. DISPLAY
   - Name and description (from project.yml)
   - Repos: list with path existence check ([missing] marker for absent paths),
     and each member's role: host / synced copy / divergent / code-only member
   - Referenced-by: other projects that reference this repo (reverse index lookup)
   - Packs: list with existence check ([not found] marker for absent packs)
   - Docker config: auth method, ports, network name
   - Status: checks Docker for running container (cc-<name>)
   - ⚠ passive badge: unresolved/unreachable references, if any
```

**Repo↔project introspection (ADR-0024 D5)**: `cco project show` reports, for the project's
repos, the project each repo **hosts**, the projects that **reference** it, and each member's
sync state (host / synced / divergent / code-only) — derived from the index `projects:` map
(forward + reverse lookup) and the per-machine sync-meta. There is no separate top-level verb.

---

### 3.14 `cco project validate [name]`

> 🚧 **Planned — ships in a later release.** Today `cco project validate` reports that the
> share-readiness validator is not yet available (ADR-0023 D2); the legacy structure check was
> removed with the tier-2 verbs. To configure unresolved references now, use `cco resolve`. The
> contract below is the target surface.

**Share-readiness validation**: check that a project's config is safe to share via its repo
remote — every referenced id (repo/llms/pack) has a **reachable, machine-agnostic coordinate**,
no real paths leak, and no pack-name collision. Detect-only: it never blocks a `git push`.

```
Usage: cco project validate [name] [--all] [--reachable]

Arguments:
  name                 Project to validate (defaults to the cwd's hosted project)

Options:
  --all                Validate every project in the index
  --reachable          Also probe that each coordinate is currently reachable

Examples:
  cco project validate                 # cwd-first: validate the project this repo hosts
  cco project validate my-saas
  cco project validate --all
```

**Flow**:

```
1. VALIDATE (cwd-first)
   - project.yml exists and 'name' is present (fatal if missing)
   - Every referenced repo/llms/pack has a coordinate (url/ref) — machine-agnostic, no real paths
   - --reachable: probe each coordinate (ls-remote / fetch)
   - Pack collision: a no-coordinate authored pack shadowed by an unrelated same-name
     global pack is an ERROR (silent-wrong-build); every reachability gap stays a WARN

2. RESULT
   - exit 0 = share-ready; exit 1 = WARN (degraded/unreachable); exit 2 = ERROR (collision)
   - Detect-only — never blocks the git push path
   - "Project '<name>' is share-ready" on success
```

> This is the **share-readiness** validate. The **orphan-sanitization** of global internal
> state lives in `cco config validate` (§3.21).

---

### 3.15 `cco resolve` / `cco path`

Map a project's **logical names** (repos and extra mounts, declared in `project.yml` with
machine-agnostic coordinates) to **absolute paths on this machine**. Paths live in the
machine-local STATE **index** (`<state>/cco/index`), never in `project.yml` and never committed.
`project.yml` carries logical names + `url`/`ref` coordinates only — there are no `@local`
markers and no per-repo `local-paths.yml`.

#### `cco resolve [project]`

Resolve each unresolved repo/mount of a project: specify a local path, clone from the
coordinate `url`, or skip.

```
Usage: cco resolve [project]
       cco resolve --all
       cco resolve --scan <dir>

Arguments:
  project              Project to resolve (defaults to the cwd's hosted project)

Options:
  --all                Resolve every project in the index
  --scan <dir>         Auto-discover by scanning <dir> for .cco/project.yml and
                       reconcile (upsert) the index — non-destructive

Examples:
  cco resolve                  # Interactively resolve the cwd's project
  cco resolve my-saas
  cco resolve --all
  cco resolve --scan ~/dev     # Discover + register all projects under ~/dev
```

For each unresolved repo/mount, `cco resolve` offers: **specify a local path** · **clone from
`<url>`** (only when the coordinate carries a `url`) · **skip**. `--scan` is **non-destructive**:
it upserts each discovered `name → path` + `repos[]`, never deletes out-of-`<dir>` mappings or
manual `cco path set` overrides, and on a name-already-bound-to-a-different-path conflict it
warns and keeps the existing mapping (uniqueness invariant). There is no `--prune` in v1.
`cco resolve --scan` also bootstraps a fresh machine (populates an empty index).

#### `cco path set` / `cco path list`

The low-level index editor — fix divergence, point to a moved directory, register an external
install.

```
Usage: cco path set <name> <path>
       cco path list

Examples:
  cco path set backend ~/dev/backend     # Bind logical name → absolute path
  cco path list                          # Show all name → path mappings
```

Manual index edits are allowed but discouraged — prefer `cco resolve`. A logical name maps to
exactly one absolute path per machine (`cco init`/`cco join` refuse a name already bound to a
different path).

---

### 3.16 `cco update [OPTIONS]`

Run pending migrations, discover available updates, and notify of new features.

`cco update` performs three categories of operations:

1. **Migrations** (automatic): run pending migration scripts from `migrations/`
   for structural/breaking changes. Always run on global + all projects. `cco update`
   also owns the **eager global migration** from a legacy vault: it populates `~/.cco`
   from the first-run vault backup (after backing it up non-destructively). Per-project
   migration is lazy via `cco init --migrate`.
2. **Config discovery**: compare framework sources against the saved base to detect
   available updates to opinionated files (rules, agents, skills).
3. **Changelog**: report additive changes (new features) from `changelog.yml`.

Migrations and discovery are read-only by default — opinionated file changes
require explicit `--sync` to apply interactively. The merge ancestors (`base/`) and
update metadata (`meta`) are kept in machine-local STATE
(`<state>/cco/projects/<id>/update/`, global at `<state>/cco/global/update/`), never in
the committed `<repo>/.cco/`.

```
Usage: cco update [OPTIONS]

Runs pending migrations (global + all projects) and shows available updates.
Checks both framework defaults and remote sources for installed projects/packs.

Modes:
  (default)           Run migrations + show available config updates + changelog
  --check             List installed resources (packs/templates) with an upstream update [planned]
  --sync [scope]      Run migrations + interactively sync config from framework defaults
  --diff [scope]      Run migrations + show config update summary (or full diffs if scoped)
  --diff --all        Run migrations + show full diffs for all scopes
  --news              Show details of new features and additive changes

Scope (for --sync and --diff):
  (omitted)           Global + all projects
  global              Global config only
  <project-name>      One specific project only (no global)

Options:
  --offline           Skip remote source checks (framework-only discovery)
  --no-cache          Force fresh remote version check (ignore cache)
  --force             Non-interactive sync: overwrite all files with framework version
  --keep              Non-interactive sync: keep all user files, update base only
  --no-backup         Skip .bak file creation (with --sync)
  --dry-run           Preview pending migrations without running
  --help              Show this help message

Non-interactive mode:
  When stdin is not a TTY, --sync defaults to (S)kip for all files.

Migrations run automatically in all modes (except --news and --dry-run).
Config sync (--sync) covers opinionated files: rules, agents, skills,
and other framework defaults that you may have customized.

Examples:
  cco update                  # Run migrations + eager vault migration + available updates
  cco update --check          # List packs/templates with an upstream update [planned]
  cco update --diff           # Summary: file names + status per scope
  cco update --diff global    # Full diffs for global config only
  cco update --diff myapp     # Full diffs for one project
  cco update --diff --all     # Full diffs for everything
  cco update --sync           # Interactively sync all config from defaults
  cco update --sync global    # Sync global config only
  cco update --sync myapp     # Sync one project only (no global)
  cco update --news           # Show new features and examples
  cco update --dry-run        # Preview pending migrations
  cco update --offline        # Skip remote checks
```

> 🚧 **`cco update --check` is planned — ships in a later release.** The flag is documented here
> for completeness; today `cco update` runs without it (ADR-0022 D6). The rest of `cco update`
> (migrations, `--sync`, `--diff`, `--news`, `--dry-run`) is current. The `--check` contract below
> is the target surface.

**Discovery-flag division of labor**: four surfaces answer different "what would change?"
questions — `--check` (is a newer **upstream** available for an installed pack/template?,
DATA `source`-driven, read-only, exit 0), `--diff`/`--news` (what would the **framework
defaults** change?), and `--dry-run` (what migrations would run?). `--check` and `--diff`
do not overlap in source.

**`--check`**: lists installed packs/templates with an available upstream update, driven by
the install provenance in DATA (`<data>/cco/{packs,templates}/<name>/source`) and gated on
local-install presence. Three-state output (*not installed here* / comparable / indeterminate),
one greppable line per resource, always exit 0. Note: **projects do not install/update** —
a project's config travels with its code repo's own git remote, so projects are not part of
the upstream-update surface.

**Remote checks**: by default, `cco update --check` checks sharing-repo upstreams using
`git ls-remote` (lightweight, no clone). Results are cached for 1 hour. Use `--offline` to
skip, `--no-cache` to force a fresh check.

**Update sources**: `cco update` uses native framework sources: `defaults/global/`
for global config, `templates/project/base/` for base project files, and
`templates/project/<name>/` for native template-specific files. User templates are not
touched. `project.yml` is fully user-managed and not tracked by the update system (new fields
are additive with code defaults; schema changes use migrations).

**Migration scopes**: `global`, `project`, `pack`, `template`. Migrations always
run on all scopes — they are not filtered by `--sync`/`--diff` scope.

**Flow**:

```
0. FIRST-RUN VAULT MIGRATION (eager, global scope)
   - The first run on a machine backs up any legacy vault (into STATE), non-destructive
   - `cco update` then populates ~/.cco from the backup (global/.claude, packs/, templates/,
     setup scripts, languages, secrets.env) and decomposes the global metadata into STATE
   - Vault removal is offered only here, default keep (manual fs-delete instructions printed)

1. RUN MIGRATIONS (always global + all projects)
   - Global: migrations/global/ → ~/.cco/global/
   - Pack: migrations/pack/ → each ~/.cco/packs/*/ (meta in STATE)
   - Template: migrations/template/ → each ~/.cco/templates/*/ (meta in STATE)
   - Project: migrations/project/ → all projects (per-repo <repo>/.cco/, meta in STATE)
   - --dry-run: list pending migrations without running

2. NOTIFY additive changes (dual-tracker)
   - Discovery (`cco update`): shows entries where id > last_seen_changelog,
     updates last_seen_changelog only
   - News (`cco update --news`): shows entries where id > last_read_changelog,
     updates BOTH last_read_changelog AND last_seen_changelog

3. DISCOVER opinionated file updates
   - For each opinionated file, compare the saved STATE base vs framework source
   - Report available updates (read-only, no file changes)
   - Scope: default mode always checks global + all projects

4. SYNC (only with --sync)
   - Scope: global + all projects, or filtered by scope argument
   - For each file with available update:
     - User unchanged + framework changed: offer Apply/Skip/Diff
     - Both changed: offer Merge/Replace/Keep/Skip/Diff
   - 3-way merge via `git merge-file`:
     - Clean merge (no overlapping edits): auto-applied
     - Conflicts: file written with conflict markers, user resolves manually
   - Conflict resolution options:
     - (M)erge [default]: write file with markers, resolve manually
     - (E)dit: write + open in $EDITOR to resolve now
     - (R)eplace: overwrite with framework version + .bak
     - (K)eep: keep user version unchanged
     - (S)kip: defer to next run
   - If conflict markers remain after M/E: the STATE base is updated (no re-merge
     loop), but `cco start` blocks until markers are resolved
   - .bak created for each modified file (unless --no-backup)
   - The STATE base is updated to reflect the applied framework version
   - Non-interactive fallback: defaults to Skip (no silent changes)
   - Use `cco clean` to remove .bak files after reviewing

6. PRE-START SAFETY CHECK
   - `cco start` scans global and project .claude/ dirs for conflict markers
   - If unresolved `<<<<<<<` markers found: start is blocked with error
   - Forces user to resolve conflicts before launching a session
```

---

### 3.17 `cco pack install <url>`

Install packs from a remote **sharing repo** (a git repo whose layout holds `packs/` +
`templates/`, discovered structure-based — there is no `manifest.yml`). Installed packs land
in `~/.cco/packs/`.

```
Usage: cco pack install <url> [OPTIONS]

Arguments:
  url                  URL of the sharing repo (git repository)

Options:
  --pick <name>        Install only a specific pack from the repo
  --token <t>          Authentication token for private repos
  --force              Overwrite existing pack with the same name

Examples:
  cco pack install https://github.com/team/cco-sharing
  cco pack install https://github.com/team/cco-sharing --pick react-guidelines
  cco pack install https://github.com/team/cco-sharing --token ghp_... --force
```

**Install provenance**: the upstream coordinate is recorded in DATA
(`<data>/cco/packs/<name>/source` — `url`/`ref`), and the installed tree is recorded as the
STATE merge base (`<state>/cco/packs/<name>/update/base/`) for the next `cco pack update`.

---

### 3.18 `cco pack update`

Update pack(s) from their upstream sharing repo (3-way merge against the recorded STATE base).

```
Usage: cco pack update <name> [--force]
       cco pack update --all

Arguments:
  name                 Pack name to update

Options:
  --all                Update all packs that have a recorded upstream source
  --force              Overwrite local modifications

Examples:
  cco pack update react-guidelines
  cco pack update react-guidelines --force
  cco pack update --all
```

---

### 3.19 `cco pack export` / `cco pack import`

The tar-snapshot half of the pack sharing 2×2 (`publish`/`install` is the live-source half).

```
Usage: cco pack export <name>          # Write ~/.cco/packs/<name>/ to a .tar.gz archive
       cco pack import <archive>       # Install a pack from a .tar.gz archive into ~/.cco/packs/

Arguments:
  name                 Pack name to export
  archive              Path to a .tar.gz pack archive

Examples:
  cco pack export react-guidelines
  cco pack import ./react-guidelines.tar.gz
```

---

### 3.20 `cco project export` / `cco project import`

Projects are **not** published/installed — a project's `<repo>/.cco/` is shared **by
construction** through its code repo's own git remote (clone the repo and you have the config).
Projects therefore get only the **tar-snapshot** half of the 2×2: `export`/`import`.

```
Usage: cco project export <name>       # Snapshot the project's <repo>/.cco/ to a .tar.gz
       cco project import <archive>    # Bootstrap a repo's .cco/ from a .tar.gz snapshot

Arguments:
  name                 Project to export
  archive              Path to a .tar.gz project-config archive

Examples:
  cco project export my-saas
  cco project import ./my-saas.tar.gz
```

> **Removed**: `cco project install` and `cco project publish` no longer exist. To share a
> project, push its repo (the `<repo>/.cco/` rides the remote); to bootstrap a repo without a
> committed `.cco/`, use `cco init`, `cco init --migrate`, or `cco project import`. To version
> and multi-PC-sync your **personal** `~/.cco` store, use `cco config save/push/pull` (§3.21).

---

### 3.21 `cco config` (personal `~/.cco` store)

Version and multi-PC-sync your **personal** global store (`~/.cco/` — `global/.claude/`,
`packs/`, `templates/`). `~/.cco` is **always** a git-init'd working tree; only the remote is
opt-in. This replaces the removed `cco vault` surface. (Project config in `<repo>/.cco/` rides
each repo's **own** git remote with your normal git flow — `cco config` does not touch it.)

#### `cco config save [-m <msg>]`

Stage and commit the `~/.cco` store with an allowlist + secret scan. Versioning is **explicit
and manual** (no auto-commit). The allowlist commits only `packs/`, `templates/`,
`global/.claude/` and the global `setup*.sh` / `mcp-packages.txt` / `languages` (never
`git add -A`); the 2-pass secret scan refuses real secrets and exempts `*.example`.

```
Usage: cco config save [-m <msg>] [--dry-run]

Options:
  -m <msg>             Commit message (auto-generated if omitted)
  --dry-run            Show what would be committed without committing

Examples:
  cco config save
  cco config save -m "Add react-guidelines pack"
  cco config save --dry-run
```

#### `cco config push` / `cco config pull`

Sync the `~/.cco` store to/from its opt-in personal remote (private by default; a public remote
is allowed with a warning). Remote sync is explicit — never per-command. A non-fast-forward
pull aborts and notifies (resolve in your IDE, as ordinary git).

```
Usage: cco config push
       cco config pull

Examples:
  cco config push
  cco config pull
```

> Team-sharing does **not** go through `~/.cco` (which holds your personal global config).
> Share packs/templates via a **sharing repo** (`cco pack/template publish|install`), and share
> a project via its own code repo remote. See [configuration-management.md](../user-guides/configuration-management.md).

#### `cco config validate [--dry-run|--fix]`

> 🚧 **Planned — ships in a later release.** Today `cco config validate` is not available — the
> command reports that orphan cleanup ships later (ADR-0021 §5). STATE/CACHE rebuild freely via
> `cco resolve --scan`. The contract below is the target surface.

**Orphan-sanitization** of the global id-keyed internal state after a manual deletion: detect
and report orphaned entries; with `--fix`, prune them (preview-first / confirmed). Warn, never
hide; never automatic. STATE/CACHE are freely rebuildable (`cco resolve --scan`); DATA is pruned
only on confirm.

```
Usage: cco config validate [--dry-run|--fix]

Options:
  --dry-run            Report orphans only (no changes)
  --fix                Prune orphaned internal state (confirmed)

Examples:
  cco config validate
  cco config validate --fix
```

> This is the **orphan-sanitization** validate. **Share-readiness** validation of a project is
> `cco project validate` (§3.14).

---

### 3.21b `cco sync`

Keep a project's config-bearing repos byte-identical by copying the committed `<repo>/.cco/`
tree from a **source** repo to **target** repos on the same machine. This is a plain filesystem
copy — **no merge engine, no profiles, no vault**. The synced set is the entire committed
`<repo>/.cco/` (`project.yml`, `claude/**`, `mcp.json`, `setup.sh`, `mcp-packages.txt`, authored
`packs/`, `secrets.env.example`) **minus** the gitignored `secrets.env`.

```
Usage: cco sync [target] [--from <src>] [--dry-run|--auto-approve|--check]

Positional = target; --from = source; default source = the current repo (cwd).

| Command                          | Source       | Targets                     |
|----------------------------------|--------------|-----------------------------|
| cco sync                         | current repo | all repos in project.yml    |
| cco sync <repo>                  | current repo | only <repo>                 |
| cco sync --from <repo>           | <repo>       | all repos                   |
| cco sync <repoA> --from <repoB>  | <repoB>      | only <repoA>                |

Options:
  --dry-run            Preview the diff, copy nothing
  --auto-approve       Skip the confirmation prompt
  --check              Exit-code only (for your own CI/hooks)

Examples:
  cco sync                      # Copy the cwd's .cco/ to all member repos
  cco sync frontend             # Only the frontend repo
  cco sync --from backend       # Use backend's .cco/ as the source
  cco sync --dry-run
```

**Behavior**: resolve source + targets via the index, compute a truthful diff, and (unless
`--auto-approve`) show it and ask to confirm. On confirm, copy the source set into each target
**with the clobber-guard**: a target without `.cco/project.yml` (code-only member) simply
receives a copy; a target whose `project.yml` `name` matches the source converges; a target
that **hosts a different project** is **skipped with a warning** — never clobbered, with no
`--force` override. To re-home such a repo, de-init its `.cco/` then sync, or re-init with
`--sync`. Targets' git branches are irrelevant — sync is a filesystem copy; commit each repo
with your normal git flow.

Divergence is allowed and visible: `cco start` uses the chosen source and prints a non-blocking
notice ("project repos have divergent .cco; started from <repo>; run `cco sync` to converge").

---

### 3.22 Project sharing — by construction (no publish/install/update)

A project's config is **not** published or installed. The committed `<repo>/.cco/` rides each
repo's own git remote (Axis 1+2 by construction): clone the repo and you have the project's
config. There is therefore **no `cco project publish`, no `cco project install`, and no
`cco project update`**.

- **Get a shared project**: `git clone` the repo, then `cco start` (the `.cco/` is already
  present), or `cco init --migrate` / `cco project import` to bootstrap a repo that lacks one.
- **Update a shared project**: `git pull` the repo — the `.cco/` changes arrive as ordinary
  commits (`git log -- .cco/` isolates config history). To converge a project's
  config-bearing repos on this machine, run `cco sync` (§3.21b).
- **Framework defaults** still flow into projects via `cco update --sync` (§3.16); upstream
  pack/template updates via `cco update --check` + `cco pack/template update`.

---

### 3.23 `cco <res> internalize`

Sever a **referenced resource's** external coupling — one intent, per-resource mechanism. For a
**pack** or **template**, it cuts the upstream `url` so the resource becomes an authored local
source. (A **project** Case-C disconnect — `<repo>/.cco` → `~/.cco/projects` — is post-v1.)

```
Usage: cco <res> internalize <name> [--as <name>]

Arguments:
  res                  pack | template
  name                 Resource to internalize

Options:
  --as <name>          Fork under a new name (keeps the original tracked)

Examples:
  cco pack internalize my-docs-pack
  cco pack internalize team-rules --as team-rules-local
```

After internalizing a pack/template:
- The resource becomes a fully local authored **source** (no upstream `url`)
- Upstream updates (`cco pack/template update`) are no longer checked or available
- Your customizations are preserved

The inverse is `cco project add … --url` (adopt a coordinate) or `cco pack publish` (publish
yours). Caching a referenced pack (keeping its coordinate) is separate — the opt-in resolve
prompt or `export --bundle-packs`; there is no `vendor` verb in v1.

---

### 3.25 `cco project add` / `cco project coords`

Edit a project's referenced ids (repos/mounts/llms/packs) and keep their coordinates
consistent across the project's units. Operates on the cwd's `<repo>/.cco/project.yml`.

#### `cco project add <type> <name> [OPTIONS]`

Add a reference and, in one call, **embed its coordinate** in `project.yml` and optionally
register its local path in the index (`--path`). Packs are embedded with
`cco project add pack` — the legacy `add-pack` / `remove-pack` verbs were removed (no alias).

```
Usage: cco project add repo|mount|llms|pack <name> [OPTIONS]

Options:
  --url <url>          Coordinate URL (auto-derived from `origin` when --path is a clone)
  --ref <ref>          Git ref / branch for repos and packs
  --variant <v>        llms variant (e.g. full)
  --readonly           Mark an extra mount read-only
  --path <path>        Also register this name → local path in the index

Examples:
  cco project add repo backend --url git@github.com:org/backend.git --path ~/dev/backend
  cco project add llms react --url https://react.dev/llms-full.txt --variant full
  cco project add pack shared-pack --url https://github.com/org/cco-sharing.git --ref v1.0
  cco project add pack react-guidelines              # project-local authored pack (no url)
```

#### `cco project coords --diff [--sync --from <unit>]`

> 🚧 **Planned — ships in a later release.** `cco project coords` is not yet available (ADR-0016
> D3). `cco project add` (above) is current. The contract below is the target surface.

Check (and optionally reconcile) coordinate consistency across a project's units. `--sync`
requires an explicit `--from` (never auto-elects a source).

```
Usage: cco project coords --diff [--sync --from <unit>]

Examples:
  cco project coords --diff
  cco project coords --diff --sync --from backend
```

> Share-readiness (every referenced id has a reachable, machine-agnostic coordinate) is
> verified by `cco project validate` (§3.14).

---

### 3.26 `cco pack publish` / `cco template publish`

Publish a pack (or template) to a remote **sharing repo** (a git repo holding `packs/` +
`templates/`, discovered structure-based — no `manifest.yml`). Publishing is
**sync-before-publish**: a subsequent publish does a 3-way merge against the recorded STATE
base (aborts on conflict — "run `cco pack update` first"), never a blind overwrite.

```
Usage: cco pack publish <name> [<remote>] [OPTIONS]
       cco template publish <name> [<remote>] [OPTIONS]

Arguments:
  name                 Pack/template to publish
  remote               Remote name or direct URL (default: re-derived from the DATA remotes registry)

Options:
  --message <msg>      Commit message (default: "publish pack <name>")
  --dry-run            Show what would be published, don't push
  --force              Overwrite remote version without confirmation
  --token <token>      Auth token for HTTPS remotes

Examples:
  cco pack publish react-guidelines alberghi
  cco pack publish react-guidelines                  # re-derives the target from the registry
  cco pack publish react-guidelines --dry-run
```

The remote argument is resolved in order: registered remote name, direct URL, or the publish
target re-derived on demand by reverse-looking-up the resource's `url` in the DATA `remotes`
registry. On publish, the pushed tree is recorded as the new STATE merge base.

> **Templates**: `cco template publish|install|export|import` mirror the pack path and govern
> the **template artifact's** distribution (a reusable library). The **scaffolded output** of a
> template stays one-shot — no coordinate back, no auto-update.

---

### 3.27 `cco pack internalize`

Convert a pack to fully self-contained and locally owned (see also the unified
`cco <res> internalize`, §3.23).

```
Usage: cco pack internalize <name>

Examples:
  cco pack internalize my-docs-pack
```

Performs two independent operations as needed:

1. **Knowledge source internalization**: If `pack.yml` has a `knowledge.source`
   field pointing to an external directory, copies the referenced files into the
   pack's own `knowledge/` directory and removes the `source:` field from
   `pack.yml`. The original source path is not preserved.

2. **Sharing-repo disconnection**: If the pack was installed from a remote sharing
   repo (its DATA `source` records an upstream `url`), cuts the upstream coordinate so the
   pack becomes a local authored source. After disconnection, the pack will no longer receive
   updates via `cco pack update` — it becomes a fully local pack.

If neither condition applies, the command reports that the pack is already
self-contained.

---

### 3.28 `cco remote`

Manage named **sharing-repo** endpoints for publishing and installing packs/templates. The
de-tokenized registry lives in DATA (`<data>/cco/remotes`); the token is isolated in STATE
(`<state>/cco/remotes-token`, 0600, never synced).

#### `cco remote add <name> <url> [--token <token>]`

Register a named sharing-repo endpoint. Names must be lowercase alphanumeric with hyphens.
Use `--token` to save an auth token for HTTPS repos.

```
Usage: cco remote add <name> <url> [--token <token>]

Examples:
  cco remote add team git@github.com:my-org/cco-config.git
  cco remote add team https://github.com/my-org/cco-config.git --token ghp_xxx
```

#### `cco remote remove <name>`

Unregister a remote and its saved token (if any).

```
Usage: cco remote remove <name>

Examples:
  cco remote remove team
```

#### `cco remote list`

Show all registered remotes. Remotes with a saved token show `[token]`.

```
Usage: cco remote list
```

#### `cco remote set-token <name> <token>`

Save or update an auth token for a registered remote. The token is stored in STATE
(`<state>/cco/remotes-token`, 0600, never synced) and used automatically for HTTPS operations.

```
Usage: cco remote set-token <name> <token>

Examples:
  cco remote set-token team ghp_xxx
```

#### `cco remote remove-token <name>`

Remove the saved auth token for a remote.

```
Usage: cco remote remove-token <name>

Examples:
  cco remote remove-token team
```

---

### 3.30 `cco template`

Manage project and pack templates. Native templates ship with the tool in `templates/`; user templates are stored in `~/.cco/templates/` and take priority over native ones with the same name. Templates can also be shared via a sharing repo (`cco template publish|install|export|import`, §3.26 — the full 2×2 mirrors packs).

> **Removed**: there is no `cco manifest` / `manifest.yml`. Sharing-repo discovery is
> structure-based (a sharing repo holds `packs/` + `templates/`, discovered via `git ls-tree`).

#### `cco template list [--project|--pack]`

List available templates (both native and user).

```
Usage: cco template list [--project|--pack]

Options:
  --project    Show only project templates
  --pack       Show only pack templates

Examples:
  cco template list
  cco template list --project
```

#### `cco template show <name>`

Show template details (files, description).

```
Usage: cco template show <name>

Examples:
  cco template show base
  cco template show config-editor
```

#### `cco template create <name> --project|--pack`

Create a new user template by copying a base template. User templates are stored in `~/.cco/templates/` and take priority over native templates with the same name.

```
Usage: cco template create <name> --project|--pack

Examples:
  cco template create my-stack --project
  cco template create my-pack-layout --pack
```

#### `cco template remove <name>`

Remove a user template.

```
Usage: cco template remove <name>

Examples:
  cco template remove my-stack
```

---

### 3.31 `cco clean`

Remove files generated or left behind by the framework. Supports multiple cleanup
categories that can be combined.

```
Usage: cco clean [CATEGORY] [OPTIONS]

Categories (combinable):
  (default)          Remove .bak backup files created by cco update
  --new              Remove .new files created by cco update --sync (New-file option)
  --tmp              Remove .tmp/ directories (left by cco start --dry-run --dump)
  --generated        Remove the generated docker-compose.yml (regenerated by cco start)
  --all              All categories: .bak + .new + .tmp + generated compose

Scope options:
  --project <name>   Scope to a specific project only
  --dry-run          Show what would be removed without deleting

Examples:
  cco clean                         # Remove .bak files (global + all projects)
  cco clean --tmp                   # Remove .tmp/ dirs from all projects
  cco clean --generated             # Remove the generated docker-compose.yml from all projects
  cco clean --all                   # Remove all generated/temporary files
  cco clean --dry-run               # Preview everything that would be removed
  cco clean --project myapp         # Clean .bak files from a specific project
  cco clean --all --project myapp   # All categories, single project
  cco clean --tmp --dry-run         # Preview .tmp removal
```

**Note:** the merge ancestors (`base/` in STATE) are never removed by `cco clean`. They store the
diff/merge ancestors required for `cco update` discovery and `--sync` to function correctly.
The generated compose and overlays live in CACHE (`<cache>/cco/projects/<id>/`), regenerated by `cco start`.

### 3.32 `cco llms`

Manage llms.txt framework documentation. Downloads, stores, and serves official
framework docs to coding agents during sessions.

The downloaded **content** is cached per machine in CACHE (`~/.cache/cco/llms/<name>/`,
re-fetchable). The llms **coordinate** (`url` + `variant`) is config and is embedded per-unit
in the versioned manifest — referenced from packs (`pack.yml`) and projects (`project.yml`)
via the `llms:` section.

#### `cco llms install <url>`

```
Usage: cco llms install <url> [OPTIONS]

Options:
  --name <name>        Override the auto-detected framework name
  --variant <v>        Force variant: full, medium, small, index (default: auto)
  --pack <pack>        Add reference to this pack's pack.yml
  --project <project>  Add reference to this project's project.yml

Examples:
  cco llms install https://svelte.dev/docs/svelte/llms.txt
  cco llms install https://shadcn-svelte.com/llms.txt --name shadcn-svelte
  cco llms install https://svelte.dev/llms.txt --variant medium --pack my-pack
```

Auto-detects available variants (`llms-full.txt`, `llms-medium.txt`, etc.) and
downloads the best one (default: `full`). Always downloads the index `llms.txt`
if available. The cache-state (etag, resolved URL, download timestamp) is kept alongside the
content in CACHE; the `url`/`variant` coordinate is written into the referencing manifest.

#### `cco llms list`

```
Usage: cco llms list
```

Lists all installed llms entries with variant, line count, download date, source
URL, and which packs/projects reference them.

#### `cco llms show <name>`

```
Usage: cco llms show <name>
```

Shows detailed information: source URL, variant, download date, files with line
counts, and usage by packs/projects.

#### `cco llms update [<name>] [--all]`

```
Usage: cco llms update [<name>] [--all]

Examples:
  cco llms update svelte          # Update one entry
  cco llms update --all           # Update all installed entries
```

Re-downloads from source URLs. Reports line count changes. `cco update` also
checks llms freshness and suggests `cco llms update --all` when entries are
older than 30 days.

#### `cco llms rename <old-name> <new-name>`

```
Usage: cco llms rename <old-name> <new-name>
```

Renames an installed llms entry (directory and YAML references in packs/projects).

#### `cco llms remove <name> [--force]`

```
Usage: cco llms remove <name> [--force]
```

Removes an llms entry. Warns if referenced by packs or projects unless `--force`.

---

## 4. Project Configuration Format (project.yml)

`project.yml` lives in `<repo>/.cco/project.yml` and is **machine-agnostic**: it carries
**logical names + coordinates** only — never real local paths. Each `repos:`/`llms:`/`packs:`/
`extra_mounts:` entry carries its coordinate inline (`url`/`ref`/`variant`), identical across
the project's config-bearing repos. Absolute paths come from the machine-local index
(`<state>/cco/index`, set with `cco resolve`/`cco path`); there are no `@local` markers and no
per-repo `local-paths.yml`.

```yaml
name: projectA
repos:                   # all members by logical name + machine-agnostic coordinate
  - name: backend
    url: git@github.com:org/backend.git   # OPTIONAL bootstrap pointer (clone source for other PCs)
    ref: main                             # OPTIONAL ref to check out on auto-clone (default: remote default branch)
  - name: frontend
    url: git@github.com:org/frontend.git
llms:                    # referenced docs by name + coordinate (content → CACHE, re-fetched)
  - name: react
    url: https://react.dev/llms-full.txt  # MANDATORY for llms
    variant: full
extra_mounts:            # auxiliary mounts by logical name (coordinate OPTIONAL)
  - name: shared-assets
    url: git@github.com:org/assets.git
    target: /workspace/assets             # OPTIONAL; default /workspace/<name>
    readonly: true
entry: backend           # OPTIONAL tie-breaker for `cco start projectA`; not a privilege
packs:                   # referenced by name + OPTIONAL coordinate
  - name: shared-pack
    url: https://github.com/org/cco-sharing.git   # coordinate → the pack's sharing repo
    ref: v1.0                                      #   url absent → project-local authored pack in <repo>/.cco/packs/
```

The host repo is **not** written in the file — it is the invoking repo at runtime. Per-user
tags are **not** here either (they live in the DATA registry, never published). See
[project-yaml.md](project-yaml.md) for the complete field reference and knowledge pack format.

---

## 5. Generated docker-compose.yml

The CLI generates the docker-compose file from `project.yml` into CACHE
(`<cache>/cco/projects/<id>/docker-compose.yml`), never into the committed `<repo>/.cco/`. Mount
sources are **host-absolute** (config, state, and cache live under three roots, so a single
`--project-directory` anchor no longer suffices). The generated file includes a header comment:

```yaml
# AUTO-GENERATED by cco CLI from project.yml
# Manual edits will be overwritten on next `cco start`
# To customize, edit project.yml instead

services:
  claude:
    image: claude-orchestrator:latest
    container_name: cc-my-saas-platform
    stdin_open: true
    tty: true
    environment:
      - PROJECT_NAME=my-saas-platform
      - TEAMMATE_MODE=tmux
      - CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
      - NODE_ENV=development
      - DATABASE_URL=postgresql://postgres:postgres@postgres:5432/myapp
    volumes:
      # Auth: preferences + MCP servers (writable, synced from host)
      - /home/me/.local/state/cco/claude.json:/home/claude/.claude.json
      # Auth: OAuth credentials (seeded from macOS Keychain, auto-refreshed by Claude)
      - /home/me/.local/state/cco/.credentials.json:/home/claude/.claude/.credentials.json
      # Global config (~/.cco/global)
      - /home/me/.cco/global/.claude/settings.json:/home/claude/.claude/settings.json:ro
      - /home/me/.cco/global/.claude/CLAUDE.md:/home/claude/.claude/CLAUDE.md:ro
      - /home/me/.cco/global/.claude/rules:/home/claude/.claude/rules:ro
      - /home/me/.cco/global/.claude/agents:/home/claude/.claude/agents:ro
      - /home/me/.cco/global/.claude/skills:/home/claude/.claude/skills:ro
      # Project config (the invoking repo's <repo>/.cco/claude/) + generated overlays (CACHE, :ro)
      - /home/me/dev/backend/.cco/claude:/workspace/.claude
      - /home/me/.cache/cco/projects/projectA/.claude/packs.md:/workspace/.claude/packs.md:ro
      # Session transcripts (STATE; enables /resume across rebuilds)
      - /home/me/.local/state/cco/projects/projectA/claude-state:/home/claude/.claude/projects/-workspace
      # Memory (STATE; machine-local, no sync in v1; separate from transcripts)
      - /home/me/.local/state/cco/projects/projectA/session/memory:/home/claude/.claude/projects/-workspace/memory
      # Global MCP servers (optional, merged into ~/.claude.json by entrypoint)
      # - /home/me/.cco/global/.claude/mcp.json:/home/claude/.claude/mcp-global.json:ro
      # Project MCP servers (optional, Claude Code expands ${VAR} natively)
      # - /home/me/dev/backend/.cco/mcp.json:/workspace/.mcp.json:ro
      # Project setup script (optional, executed by entrypoint at runtime)
      # - /home/me/dev/backend/.cco/setup.sh:/workspace/setup.sh:ro
      # Project MCP packages (optional, installed by entrypoint at runtime)
      # - /home/me/dev/backend/.cco/mcp-packages.txt:/workspace/mcp-packages.txt:ro
      # Repositories (paths from the machine-local index)
      - /home/me/dev/backend:/workspace/backend
      - /home/me/dev/frontend:/workspace/frontend
      - /home/me/dev/shared-libs:/workspace/shared-libs
      # Extra mounts
      - /home/me/documents/api-specs:/workspace/docs/api-specs:ro
      # Git identity
      - /home/me/.gitconfig:/home/claude/.gitconfig:ro
      # Docker socket
      - /var/run/docker.sock:/var/run/docker.sock
    ports:
      - "3000:3000"
      - "4000:4000"
      - "5432:5432"
      - "6379:6379"
    networks:
      - cc-my-saas
    working_dir: /workspace

networks:
  cc-my-saas:
    name: cc-my-saas
    driver: bridge
```

> **Note**: Container paths are unchanged — only the host-side mount **sources** move to the
> `~/.cco` / STATE / CACHE roots. Conditional mounts (Global MCP, Project MCP, setup.sh,
> mcp-packages.txt) are only included when the corresponding file exists. They are shown
> commented out above for reference.

---

## 6. Docker Socket Security

When `docker.mount_socket: true` is set in `project.yml`, the orchestrator deploys a filtering proxy (`cco-docker-proxy`) between Claude and the Docker socket. Claude interacts with Docker through the proxy; the real socket is inaccessible.

### How it works

1. `cco start` generates the proxy `policy.json` from `project.yml` docker settings into CACHE (`<cache>/cco/projects/<id>/managed/policy.json`, overlaid `:ro`)
2. The entrypoint starts `cco-docker-proxy` as root, listening on `/var/run/docker-proxy.sock`
3. The real socket (`/var/run/docker.sock`) is locked to `chmod 600` (root-only)
4. `DOCKER_HOST` is set to the proxy socket — all Docker CLI commands go through the proxy

### Configuration

All settings are in `project.yml` under the `docker` key. See [project-yaml.md](project-yaml.md) for the full field reference.

| Section | Controls |
|---------|----------|
| `docker.containers` | Which containers Claude can see/create (policy, name prefix, labels) |
| `docker.mounts` | Which host paths Claude can mount (policy, allowed paths, force readonly) |
| `docker.security` | Privileged mode, root user, capabilities, resource limits, max containers |

### Default security posture

When `mount_socket: true` with no additional settings:

- **Container policy**: `project_only` — Claude sees only containers with the project prefix
- **Mount policy**: `project_only` — only project repo directories can be mounted
- **Privileged**: blocked
- **Sensitive mounts**: `/var/run/docker.sock`, `/etc/shadow`, `/etc/sudoers` always denied
- **Network**: only `cc-<project>-*` networks can be created
- **Resources**: 4GB memory, 4 CPUs, 10 containers max (defaults)

### Proxy failure behavior

If the proxy fails to start, the real socket remains locked (`chmod 600`). Docker commands will fail rather than fall back to unfiltered access.

---

## 7. Error Handling

| Scenario | Behavior |
|----------|----------|
| Project not found | `Error: Project 'foo' not found. Run 'cco project list' to see available projects.` |
| Session already running | `Error: Project 'foo' already has a running session (container cc-foo). Run 'cco stop foo' first.` |
| Repo path doesn't exist | `Error: Repository path ~/projects/foo does not exist.` |
| Docker image not built | `Error: Docker image 'claude-orchestrator:latest' not found. Run 'cco build' first.` |
| Docker not running | `Error: Docker daemon is not running. Start Docker Desktop.` |
| Port conflict | `Error: Port 3000 is already in use. Stop the conflicting service or use --port to remap.` |
| Repo already initialized | `Error: this repo already has a .cco/ (run 'cco start' or 'cco join'/'cco forget' to change it)` |
| Malformed secrets.env | `Warning: secrets.env:3: skipping malformed line (expected KEY=VALUE)` |

---

## 8. MCP Server Configuration

### 8.1 Project MCP (`mcp.json`)

Each project can include a `mcp.json` file using Claude Code's native `.mcp.json` format:

```json
{
  "mcpServers": {
    "github": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_TOKEN": "${GITHUB_TOKEN}"
      }
    }
  }
}
```

The `${VAR}` placeholders are expanded **natively by Claude Code** inside the container. The env vars must be available in the container environment via `~/.cco/secrets.env` (global), the project's `<repo>/.cco/secrets.env`, `project.yml` `docker.env`, or `--env` CLI flags.

**Important**: If a `${VAR}` reference in `mcp.json` cannot be resolved (env var not set), Claude Code will fail to parse the entire file and show "No MCP servers configured".

### 8.2 Global MCP (`~/.cco/global/.claude/mcp.json`)

MCP servers defined here are available in all projects. The entrypoint merges global and project MCP servers into `~/.claude.json` at container startup using `jq`. This ensures MCP servers are available via the user-scope mechanism (most reliable).

### 8.3 Secrets (`~/.cco/secrets.env`)

```bash
# ~/.cco/secrets.env — global secrets, gitignored
GITHUB_TOKEN=ghp_...
LINEAR_API_KEY=lin_api_...
```

Loaded by `cco start` and `cco new` as runtime `-e` flags. Never written to `docker-compose.yml`.

---

## 9. Shell Completion (Future)

Bash/Zsh completion for:
- `cco start <TAB>` → list project names
- `cco join <TAB>` → list projects available to join
- `cco stop <TAB>` → list running sessions

Not in v1 scope but trivial to add later.
