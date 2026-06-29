# CLI Specification

> Version: 1.0.0
> Status: v1.0 — Current
> Related: [spec.md](../../maintainers/foundation/analysis/spec.md) | [docker.md](../../maintainers/environment/design/design-docker.md)

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
Usage: cco init [--name <project>] [--template <name>] [--force]
                [--migrate <project> [--sync]] [--sync] [--lang <language>]

Options:
  --name <project>     Project name (default: prompt with the repo basename)
  --template <name>    Scaffold from project template <name> (user store first,
                       then framework defaults) instead of the base template
  --force              Overwrite an existing <repo>/.cco/ scaffold
  --migrate <project>  Hydrate this repo's .cco/ from the legacy vault backup for
                       <project> (lazy, per-project migration). A mode of cco init.
  --sync               Propagate the new member's project.yml repos[] edit / config
                       to the project's other config-bearing repos
  --lang <language>    Set communication language for Claude (default: English),
                       used when seeding ~/.cco on a fresh machine

Examples:
  cco init                          # Scaffold <repo>/.cco/ in the current repo
  cco init --name my-saas           # Scaffold with an explicit project name
  cco init --template python-svc    # Scaffold from a named project template
  cco init --lang Italian           # Seed ~/.cco with Italian communication
  cco init --migrate my-saas        # Hydrate this repo from the legacy backup
```

**What `cco init` does**

1. **Ensure the global config** — seed `~/.cco/` from the framework defaults
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
`~/.cco/.claude/rules/language.md` directly.

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
                       (uses ephemeral staging via mktemp, no persistent files)
  --dump               With --dry-run: write output to .tmp/ for inspection
  --port <p>           Add extra port mapping (repeatable)
  --env <K=V>          Add extra environment variable (repeatable)

Session flags (--chrome, --no-chrome, --github, --no-github, --no-docker)
override project.yml for one session only.
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
  --mount <s>[:<t>][:ro|:rw]  Mount reference material (repeatable; read-only by
                       default, :rw to make writable; target defaults to
                       /workspace/<basename>)
  --port <p>           Port mapping (repeatable)

Examples:
  cco new --repo ~/projects/my-experiment
  cco new --repo ~/projects/api --repo ~/projects/frontend
  cco new --repo ~/projects/app --port 3000:3000
  cco new --repo ~/projects/app --mount ~/reference/specs:ro
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

Add the current repo to `<project>` as a **member** (ADR-0034): embed its coordinate
(`name` + `url`, derived from `git remote get-url origin`) into the project's `repos[]` and
register its name→path binding in the index. The `repos[]` edit is applied to every member repo
that carries a synced copy (Case B); in a divergent project (Case C) `cco join` **prompts** which
member's `project.yml` to update, or all, and refuses non-interactively. Because `repos[]` is not
the sync discriminator (`cco sync` keys on `name:`), a partial edit converges to the other members
on the next `cco sync` — so join is **not** strict.

```
Usage: cco join <project> [--sync] [--name <name>]

Arguments:
  project              Name of an existing project (defined in another repo)

Options:
  --name <name>        Logical member name for this repo (default: the dir basename; prompted
                       interactively, falls back to the basename non-interactively)
  --sync               Copy the project's <repo>/.cco/ into this repo (Case B). Skipped + warned
                       if this repo already hosts a different project (ADR-0024 D2). Without it,
                       the repo stays a code-only member (Case A).

Examples:
  cco join my-saas                  # Join as a code-only member (Case A)
  cco join my-saas --name api       # Join under an explicit member name
  cco join my-saas --sync           # Join and receive a config copy (Case B)
```

The joining repo gets **no `.cco/`** (code-only member) unless `--sync`, which copies the
project's `.cco/` into it (respecting the D2 clobber-guard). After joining, commit + push the
updated `project.yml` in each changed member repo, then run `cco sync`. cco knows which members
are synced vs divergent from its per-machine sync-state tracking.

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

Deregister a project on this machine: remove cco's internal id-keyed state — the STATE index
entry (membership + path), the per-user tags, install provenance (DATA), and the project's
STATE/CACHE — **without** touching the repo or its committed `<repo>/.cco/` by default. The
inverse of `cco init`/`cco join` (ADR-0021).

```
Usage: cco forget <project> [-y] [--purge]

Arguments:
  project              Name of the project to deregister

Options:
  -y, --yes            Skip the deregistration confirmation prompt
  --purge              Also delete the committed <repo>/.cco/ of every member repo this project
                       OWNS (with a backup first); the explicit consent for that deletion

Examples:
  cco forget old-service
  cco forget old-service -y
  cco forget old-service --purge      # also delete owned .cco/ dirs (backed up first)
```

`cco forget` previews what it will remove, then asks for confirmation (skip with `-y`; in a
non-interactive shell `-y` is required). A member repo shared with another project keeps its
path entry — only entries unique to the forgotten project are dropped.

By default the repo and its committed config are untouched, so a later `cco resolve --scan` (or
`cco start` from the repo) re-registers it. The one thing that does not auto-return is the
project's user-authored tags — re-tag if you resume the project.

**`--purge`** additionally deletes the committed `<repo>/.cco/` of every member repo the project
**owns** (its `project.yml` `name:` == this project) — a repo that hosts a **different** project,
is **shared** with another project, or is **unresolved** here is left untouched. Each deletion is
preceded by a **backup tar** into STATE and a warning if the `.cco/` has uncommitted changes;
`--purge` is the explicit consent (no extra prompt; works non-interactively, like `-y`), while an
interactive run without it asks before deleting and a non-interactive run without it skips the
deletion.

---

### 3.5 Listing projects → `cco list project`

The per-noun `cco project list` verb was **removed** (ADR-0029 D1): listing is now
unified under `cco list` (§3.5b). Running the old verb prints a one-line redirect.

```
cco list project             # projects only (NAME · REPOS · STATUS · TAGS)
cco list                     # all resources, grouped by kind
cco list project --tag work  # projects carrying the "work" tag
```

**Implementation** (under `cco list project`):
- List projects registered in the machine-local index (`<state>/cco/index` `projects:` map)
- Parse each repo's `<repo>/.cco/project.yml` for repo count
- Check Docker for running containers (`cc-<name>`)

---

### 3.5b `cco list` / `cco tag`

Per-user tags replace the removed vault profiles. Tags are **multi-valued per resource** and
**per-user** — they live in a machine-local-but-synced registry (`<data>/cco/tags.yml`, the
DATA bucket) and are never written into `project.yml`/`pack.yml` or shared with third parties.

#### `cco list [<kind>] [--tag <t>] [--sort kind|name|tag] [--reverse]`

The single listing surface (ADR-0029 D1). With no argument it prints a compact
cross-resource index — every project, pack, template, llms entry and remote,
grouped by kind, with a **TAGS** column. `cco list <kind>` narrows to one kind
(with its richer per-kind view); `--tag` filters by tag, globally or within a kind.
Long names are ellipsized so columns stay aligned in any terminal width.

```
Usage: cco list [<kind>] [--tag <t>] [--sort kind|name|tag] [--reverse|-r]

Arguments:
  <kind>               One of: project | pack | template | llms | remote
                       (plural forms accepted, e.g. `packs`)

Options:
  --tag <t>            Show only resources carrying tag <t>
  --sort kind|name|tag Order by kind (default), name, or first tag
                       (--sort tag: untagged resources sort last, then by name)
  --reverse, -r        Reverse the chosen order

Examples:
  cco list                     # All resources, grouped by kind (KIND · NAME · TAGS)
  cco list packs               # Packs only, with resource counts and tags
  cco list --tag work          # Every resource tagged "work"
  cco list project --tag work  # Projects tagged "work"
  cco list --sort tag          # Group resources by their first tag
  cco list packs --sort name -r  # Packs, name descending
```

> `--sort`/`--reverse` always render the compact index (KIND · NAME · TAGS), even
> when a `<kind>` is given — so `cco list packs --sort tag` sorts packs by tag.

> The per-noun `cco project|pack|template|llms|remote list` verbs were removed;
> each prints a one-line redirect to `cco list <kind>`. Full detail for one
> resource stays on `cco <kind> show <name>`.

#### `cco tag add` / `cco tag remove`

Add or remove a per-user tag on a resource (writes the DATA tag registry). The
kind is auto-detected; pass `--pack`/`--project`/`--template` to disambiguate.

```
Usage: cco tag add    <name> <tag> [--pack|--project|--template]
       cco tag remove <name> <tag> [--pack|--project|--template]   (alias: rm)

Examples:
  cco tag add    my-saas work
  cco tag remove my-saas work
  cco tag rm     my-saas work        # `rm` is a kept alias of `remove`
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
  --template <name>    Template to use (default: base). See `cco list templates`

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

### 3.9 Listing packs → `cco list packs`

The per-noun `cco pack list` verb was **removed** (ADR-0029 D1) → use `cco list
packs` (resource counts) or `cco list` for all kinds. The old verb prints a
one-line redirect.

```
cco list packs               # NAME · KNOWLEDGE · SKILLS · AGENTS · RULES · TAGS
cco list packs --tag infra   # packs carrying the "infra" tag
cco list packs --sort tag    # packs ordered by tag (via the compact index)
```

**Implementation** (under `cco list packs`):
- Iterates directories under `~/.cco/packs/`
- Parses each `pack.yml` for knowledge files, skills, agents, and rules counts
- Displays a formatted table with resource counts (shows `0` when a category is empty),
  a per-user **TAGS** column (`—` when untagged), and a NAME column sized to the
  widest pack name (long names ellipsized so the count columns stay aligned)
- Sorting/filtering by tag is served by the compact index (`--sort tag` / `--tag`)

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

### 3.11 `cco pack remove <name> [-y] [--force]`

Remove a knowledge pack and its id-keyed internal state. Follows the uniform
destructive-confirmation contract (ADR-0029 D2): it previews the cascade, then
confirms.

```
Usage: cco pack remove <name> [-y] [--force]

Arguments:
  name                 Pack name to remove

Options:
  -y, --yes            Skip the confirmation prompt
  --force              Remove even if the pack is still used by a project
                       (overrides the in-use block; implies -y)

Examples:
  cco pack remove old-pack            # preview + confirm
  cco pack remove old-pack -y         # skip the prompt
  cco pack remove shared-pack --force # remove an in-use pack
```

**Flow**:

```
1. VALIDATE
   - ~/.cco/packs/<name>/ exists

2. PREVIEW the cascade
   - packs/<name>/ + DATA install-provenance + STATE merge base/meta + tag binding

3. CHECK usage (the in-use block)
   - Scan all projects for references to this pack
   - If used by projects: warn, and require --force to remove anyway

4. CONFIRM (ADR-0029 D2)
   - Interactive [y/N] (default No); -y/--yes skips (--force, the in-use override, implies -y)
   - Non-interactive without -y → die ("re-run with -y"); never a silent rm

5. REMOVE
   - rm -rf the pack + its DATA/STATE state + tag binding
   - "Pack '<name>' removed"
```

The same confirm contract (preview → `[y/N]` → `-y/--yes` to skip → die when
non-interactive without `-y`) governs `cco llms remove`, `cco template remove`,
`cco remote remove`, and `cco forget` (its reference model). `--force` is the
**in-use override** (step 3) and exists only where a removal can actually be
blocked — `cco pack remove` and `cco llms remove`; `cco forget`,
`cco template remove` and `cco remote remove` have no such block and accept only
`-y/--yes` (ADR-0029 D2).

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
   - pack.yml has valid top-level keys (name, knowledge, llms, skills, agents, rules)
   - 'name' field is present and matches directory name (warns on mismatch)
   - Knowledge source directory exists (if specified)
   - Skill directories exist under skills/ for each declared skill
   - Agent files exist under agents/ for each declared agent
   - Rule files exist under rules/ for each declared rule
   - Each referenced llms is installed; if missing it prints an executable
     remedy ('cco llms install <url> --name <n>') when the entry carries a url,
     or flags a share-readiness gap ('has no url coordinate') when it does not

2. RESULT (greppable, matching `cco project validate`, ADR-0023 D2)
   - One "<name>: <reason>" line per finding — no inline ✗/⚠ symbols
   - A summary line: "validate: N issue(s) [error=E warning=W]"
   - A name/dir mismatch is a warning (non-fatal); everything else is an error
   - A valid pack prints "Pack '<name>' is valid"; exit 1 if any pack has errors
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

### 3.13b `cco project rename [<old>] <new>`

Rename a project. A project's identity is its `project.yml` `name:` — the same string keys the
machine-local index, the per-user tags, and the internal STATE/CACHE/DATA directories — so a
rename is a multi-store **identity re-key**, not a single-file edit (ADR-0031).

```
Usage: cco project rename [<old>] <new>

Arguments:
  old    Project to rename (omit to rename the cwd's project)
  new    New project name (lowercase letters, numbers, hyphens; not reserved, not in use)

Options:
  -y, --yes    Skip the confirmation prompt

Examples:
  cco project rename old-name new-name   # explicit
  cco project rename new-name            # rename the project hosting the cwd
```

**What it re-keys**: the `project.yml` `name:` in **every** member repo's `.cco/`, the index
`projects:` membership (members preserved), the DATA tags, and the
`<state|cache|data>/cco/projects/<name>/` directories.

**Strict member resolution**: the rename **refuses** unless every member repo is resolved on this
machine (run `cco resolve` first). A partial `name:` rewrite would leave the project's repos
disagreeing on identity, and `cco sync`'s clobber-guard would then permanently skip the
un-rewritten members. For a single-repo project this is always satisfiable from within the repo.

**After renaming**, commit + push the updated `.cco/project.yml` in each member repo and run
`cco sync` — the cross-repo edits live in your git working trees (cco delegates them to git, P17).

---

### 3.14 `cco project validate [name]`

**Share-readiness validation**: check that a project's config is safe to share via its repo
remote — every referenced id (repo/mount/llms/pack) has a **reachable, machine-agnostic
coordinate**, no real paths leak, and no pack-name collision. Detect-only: it never blocks a
`git push` (ADR-0023 D2).

```
Usage: cco project validate [name] [--all] [--reachable] [-v]

Arguments:
  name                 Project to validate (defaults to the cwd's hosted project)

Options:
  --all                Validate every project in the index
  --reachable          Also probe that each coordinate is currently reachable
  -v, --verbose        Print a line on success too

Examples:
  cco project validate                 # cwd-first: validate the project this repo hosts
  cco project validate my-saas
  cco project validate --all
```

**Flow**:

```
1. VALIDATE (cwd-first; else resolve [name] via the index; --all = every project)
   - project.yml exists and 'name' is present
   - Coordinate gap: a referenced repo / extra_mount / llms with no url (a pack url is
     OPTIONAL — a url-less pack is an authored-in-repo source, never a gap)
   - Machine-agnostic: a url/resource that is a real/absolute host path, plus any forbidden
     path:/source: key (the rejected inline-path flow) — reported, never stripped
   - Uniqueness: a duplicate id within a section
   - Pack collision: a no-url authored pack shadowed by an unrelated same-name global pack
     is an ERROR (silent-wrong-build)
   - --reachable: also probe each coordinate (git ls-remote / HTTP HEAD), offline-tolerant

2. RESULT (exit = numeric max severity, grep-style)
   - exit 0 = share-ready · exit 1 = reachability/coordinate gap (WARN)
     · exit 2 = path leak, duplicate id, or pack collision (ERROR)
   - One greppable "<section>.<id>: <reason>" line per finding + a one-line tally
     [reachability=X agnostic=Y uniqueness=Z collision=W]
   - Detect-only — never blocks the git push path; quiet on success unless -v
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
`<url>`** (only when the coordinate carries a `url`) · **skip**. It is **one heal verb for all four
referenced-resource kinds** — repos, extra mounts, **llms**, and **packs** — there is no separate
`cco llms resolve` / `cco pack resolve`:

- a not-installed **llms** offers **install from `<url>`** · **use a different url** · **skip**; the
  content lands in CACHE and the committed `project.yml` url is left untouched.
- a not-installed **pack** (missing from both local layers `~/.cco/packs` and `<repo>/.cco/packs`)
  offers **install from `<url>`** (via `cco pack install --pick`) · **use a different url** ·
  **skip**; a pack already present in a local layer is a clean skip.

After healing, `cco resolve` prints a **status row per referenced resource** (`✓ resolved` /
`⚠ unresolved [+url]`) across all four kinds, so it always shows the complete picture — not only the
references it prompted for. Nothing ever hard-blocks: an unresolved reference is a conscious-skip
(warn), never an abort (P14). `cco start` invokes this **same** surface before launch (one entry
point — no duplicated resolution loop).

`--scan` is **non-destructive**:
it upserts each discovered `name → path` + `repos[]`, never deletes out-of-`<dir>` mappings or
manual `cco path set` overrides, and on a name-already-bound-to-a-different-path conflict it
warns and keeps the existing mapping (uniqueness invariant). There is no `--prune` in v1.
`cco resolve --scan` also bootstraps a fresh machine (populates an empty index).

#### `cco path set` / `cco path list` (advanced)

The low-level index editor — fix divergence, point to a moved directory, register an external
install. The index is **internal** (P1/P6), so `cco path` is **demoted** (ADR-0029 D4): it is
**not listed in `cco help`** and is documented under `cco resolve --help` as an advanced
override. The command itself is unchanged — normal users meet only `cco resolve`.

```
Usage: cco path set <name> <path>
       cco path list

Examples:
  cco path set backend ~/dev/backend     # Bind logical name → absolute path
  cco path list                          # Show all name → path mappings
```

Manual index edits are allowed but discouraged — prefer `cco resolve`. A logical name maps to
exactly one absolute path per machine (`cco init`/`cco join` refuse a name already bound to a
different path). The index stores **absolute paths only**: every write is normalized (`~`/`$HOME`
expanded) and a value that cannot be made absolute is refused. `cco path list` normalizes each value
for display and flags any stale non-absolute entry (e.g. a legacy `@local`) as `⚠ malformed`; run
`cco update` (which normalizes the index) or `cco resolve --scan <dir>` to clean it.

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
  --check             List installed resources (packs/templates) with an upstream update
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
  --local             Escape hatch (with --sync <project>): apply framework defaults
                      directly on an installed project
  --dry-run           Preview pending migrations without running
  --help              Show this help message

Non-interactive mode:
  When stdin is not a TTY, --sync defaults to (S)kip for all files.

Migrations run automatically in all modes (except --news and --dry-run).
Config sync (--sync) covers opinionated files: rules, agents, skills,
and other framework defaults that you may have customized.

Examples:
  cco update                  # Run migrations + eager vault migration + available updates
  cco update --check          # List packs/templates with an upstream update
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
   - `cco update` then populates ~/.cco from the backup (.claude, packs/, templates/,
     setup scripts, languages, secrets.env) and decomposes the global metadata into STATE
   - Vault removal is offered only here, default keep (manual fs-delete instructions printed)

1. RUN MIGRATIONS (always global + all projects)
   - Global: migrations/global/ → ~/.cco/
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
Usage: cco project export [<name>] [--output <path>] [--bundle-packs]
       cco project import <archive> [--force]

Arguments:
  name                 Project to export (default: the cwd-first project)
  archive              Path to a .tar.gz project-config archive

Options:
  --bundle-packs       Dependency-closure: also bundle the project's referenced
                       global packs (~/.cco/packs) so the import is self-contained
                       without their sharing repos (ADR-0019 D6). Packs authored
                       in <repo>/.cco/packs already travel inside .cco. `import`
                       installs bundled packs (existing copies are kept).

Examples:
  cco project export my-saas
  cco project export my-saas --bundle-packs
  cco project import ./my-saas.tar.gz
```

> **Removed**: `cco project install` and `cco project publish` no longer exist. To share a
> project, push its repo (the `<repo>/.cco/` rides the remote); to bootstrap a repo without a
> committed `.cco/`, use `cco init`, `cco init --migrate`, or `cco project import`. To version
> and multi-PC-sync your **personal** `~/.cco` store, use `cco config save/push/pull` (§3.21).

---

### 3.21 `cco config` (personal `~/.cco` store)

Version and multi-PC-sync your **personal** global store (`~/.cco/` — `.claude/`,
`packs/`, `templates/`). `~/.cco` is **always** a git-init'd working tree; only the remote is
opt-in. This replaces the removed `cco vault` surface. (Project config in `<repo>/.cco/` rides
each repo's **own** git remote with your normal git flow — `cco config` does not touch it.)

#### `cco config save [-m <msg>]`

Stage and commit the `~/.cco` store with an allowlist + secret scan. Versioning is **explicit
and manual** (no auto-commit). The allowlist commits only `packs/`, `templates/`,
`.claude/` and the global `setup*.sh` / `mcp-packages.txt` / `languages` (never
`git add -A`); the 2-pass secret scan refuses real secrets and exempts `*.example`.

```
Usage: cco config save [-m <msg>]

Options:
  -m <msg>             Commit message (auto-generated if omitted)

Examples:
  cco config save
  cco config save -m "Add react-guidelines pack"
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
> a project via its own code repo remote. See [configuration-management.md](../configuration/guides/configuration-management.md).

#### `cco config validate [--dry-run | --fix [-y]]`

**Orphan-sanitization** of the global id-keyed internal state after a manual deletion: detect
and report orphaned entries (index paths/memberships, tags, install provenance, STATE/CACHE
per-id dirs, remote tokens) whose backing resource no longer resolves; with `--fix`, prune them
(preview-first / confirmed). Warn, never hide; never automatic. STATE/CACHE are freely
rebuildable (`cco resolve --scan`) and pruned under the main confirmation; synced DATA
(tags/source) is pruned under a **second** confirmation, since a wrong prune propagates across
your machines — a non-resolving DATA resource may simply live on another machine. The read-only
report exits 0 (reminder-style).

```
Usage: cco config validate [--dry-run | --fix [-y]]

Options:
  --dry-run            Report orphans only, no changes (the default)
  --fix                Prune orphaned internal state (preview-first, confirmed)
  -y, --yes            With --fix: confirm non-interactively (both phases)

Examples:
  cco config validate
  cco config validate --fix
  cco config validate --fix -y
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
Usage: cco sync [target] [--from <src>] [--all] [--dry-run [--dump]]
                [--auto-approve|--check]

Positional = target; --from = source. The **current repo (cwd)** is the other
endpoint by default — cwd-anchored, like the rest of the CLI.

| Command                          | Source       | Targets                     |
|----------------------------------|--------------|-----------------------------|
| cco sync                         | current repo | all other member repos      |
| cco sync <repo>                  | current repo | only <repo>                 |
| cco sync --from <repo>           | <repo>       | the current repo (cwd)      |
| cco sync <repoA> --from <repoB>  | <repoB>      | only <repoA>                |
| cco sync --from <repo> --all     | <repo>       | all other member repos      |

Without an explicit target, `--from` syncs into the member repo you are standing
in (a "pull into here" — including a not-yet-initialised repo already known to the
index). `--all` overrides that to broadcast. Bare `cco sync` broadcasts from the
cwd. Running `--from` from a cwd that is not a member (and without `--all`) is an
error — there is no implicit target.

Options:
  --all                Broadcast to all other members (with --from, or to
                       broadcast from an explicit source)
  --dry-run            Preview the change summary, copy nothing
  --dump               With --dry-run: write each target's full diff to
                       <target>/.cco/.tmp/sync-<source>.diff (clean: cco clean --tmp)
  --auto-approve       Skip the confirmation prompt
  --check              Exit-code only (for your own CI/hooks)

Examples:
  cco sync                      # Copy the cwd's .cco/ to all member repos
  cco sync frontend             # Only the frontend repo
  cd frontend && cco sync --from backend   # Pull backend's .cco/ into frontend
  cco sync --from backend --all            # Broadcast backend's .cco/ to all
  cco sync --dry-run --dump     # Write full per-target diffs to .cco/.tmp/
```

**Output**: by default `cco sync` shows a **compact per-file change summary** (each
file listed once as `+ new` or `~ modified` with line counts), not the full diff —
so the confirm prompt stays readable. The complete unified diff is one
`cco sync --dry-run --dump` away, written per target under `<target>/.cco/.tmp/`
and removable with `cco clean --tmp`.

**Behavior**: resolve source + targets via the index, compute a truthful summary, and (unless
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

#### `cco project coords [--diff] [--sync --from <unit>]`

Check (and optionally reconcile) coordinate consistency across your projects (ADR-0016 D3).
The STATE index is global-flat (one logical name → one path), so a name's `url` coordinate
should match in every manifest. The lookup is derived on demand by scanning the indexed
projects' `project.yml` — nothing is persisted. `--sync` requires an explicit `--from` (it
never auto-elects a source) and edits the committed `project.yml` files (preview + confirm).

```
Usage: cco project coords [--diff] [--sync --from <unit>] [-y]

  (none)               Print the full derived name → url lookup
  --diff               Print only the names whose url diverges across units (read-only)
  --sync --from <unit> Adopt <unit>'s url for each divergent name across all units
  -y, --yes            Confirm --sync non-interactively

Examples:
  cco project coords
  cco project coords --diff
  cco project coords --sync --from backend
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

#### `cco remote remove <name> [-y]`

Unregister a remote and its saved token (if any). Previews and confirms first
(ADR-0029 D2).

```
Usage: cco remote remove <name> [-y]

Options:
  -y, --yes            Skip the confirmation prompt

Examples:
  cco remote remove team
  cco remote remove team -y
```

#### Listing remotes → `cco list remotes`

The per-noun `cco remote list` verb was **removed** (ADR-0029 D1) → use
`cco list remotes` (remotes with a saved token show `[token]`). The old verb
prints a one-line redirect.

```
cco list remotes
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

Templates mirror packs: **create · install · update · publish · export · import ·
internalize · show · remove · validate** (ADR-0029 D3). Listing is unified under
`cco list templates` (the per-noun `cco template list` was removed).

#### Listing templates → `cco list templates`

```
cco list templates           # native + user templates (KIND · NAME · TAGS)
```

The old `cco template list [--project|--pack]` verb prints a one-line redirect.

#### `cco template update <name> [--all] [--force]`

Update an installed template from its recorded remote source (the pack-`update`
analogue; supersedes the never-built "future `cco template sync`" idea). Re-clones
the source coordinate, re-installs, and refreshes the STATE `installed_commit`.

```
Usage: cco template update <name> [--force]
       cco template update --all [--force]

Examples:
  cco template update my-stack          # update one template
  cco template update --all             # every template with a remote source
```

#### `cco template validate [name] [--all]`

Structural validation of a template tree (kind marker + expected config tree) —
the pack-`validate` analogue. With no name (or `--all`), validates every user
template. Output is greppable like `cco project`/`pack validate` (a
"<name>: <reason>" line per finding + a `validate: N issue(s)` summary, no inline
symbols; a missing config tree is a warning, a missing kind marker an error).

```
Usage: cco template validate [name] [--all]

Examples:
  cco template validate my-stack
  cco template validate --all
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

#### `cco template remove <name> [-y]`

Remove a user template and its id-keyed internal state (DATA provenance, STATE
merge base, tag binding). Previews the cascade and confirms first (ADR-0029 D2);
native templates cannot be removed.

```
Usage: cco template remove <name> [-y]

Options:
  -y, --yes            Skip the confirmation prompt

Examples:
  cco template remove my-stack          # preview + confirm
  cco template remove my-stack -y       # skip the prompt
```

---

### 3.31 `cco clean`

Remove files generated or left behind by the framework. Supports multiple cleanup
categories that can be combined.

```
Usage: cco clean [CATEGORY] [OPTIONS]

Categories (combinable):
  (default)          Remove .bak backup files created by cco update
  --bak              Explicitly select the .bak category (same as the default)
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

**Default is conservative:** with no category flag, `cco clean` removes only `.bak` files (recoverable
merge fall-backs). Dry-run artifacts (`--tmp`) and the generated compose (`--generated`) are left in
place — select them explicitly or use `--all`. When the default finds nothing, `cco clean` prints a
discoverability hint pointing at the other categories.

**Scope is index-based, not cwd-based:** without `--project`, `cco clean` cleans the global config plus
**every project in the machine-local index** — the same regardless of which directory you run it from.
`--project <name>` scopes to one project. A project not yet in the index (created without `cco resolve`)
is silently skipped by the global scope; run `cco resolve` to register it.

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

#### Listing llms entries → `cco list llms`

The per-noun `cco llms list` verb was **removed** (ADR-0029 D1) → use `cco list
llms` (variant, line count, download date, source URL, and which packs/projects
reference each entry). The old verb prints a one-line redirect.

```
cco list llms
```

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

#### `cco llms remove <name> [-y] [--force]`

```
Usage: cco llms remove <name> [-y] [--force]

Options:
  -y, --yes            Skip the confirmation prompt
  --force              Remove even if still referenced by a pack/project
                       (overrides the referenced block; implies -y)
```

Removes an llms entry. Previews and confirms first (ADR-0029 D2); a still-referenced
entry needs `--force`. Non-interactive without `-y` → die.

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
[project-yaml.md](../configuration/reference/project-yaml.md) for the complete field reference and knowledge pack format.

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
      # Global config (~/.cco)
      - /home/me/.cco/.claude/settings.json:/home/claude/.claude/settings.json:ro
      - /home/me/.cco/.claude/CLAUDE.md:/home/claude/.claude/CLAUDE.md:ro
      - /home/me/.cco/.claude/rules:/home/claude/.claude/rules:ro
      - /home/me/.cco/.claude/agents:/home/claude/.claude/agents:ro
      - /home/me/.cco/.claude/skills:/home/claude/.claude/skills:ro
      # Project config (the invoking repo's <repo>/.cco/claude/) + generated overlays (CACHE, :ro)
      - /home/me/dev/backend/.cco/claude:/workspace/.claude
      - /home/me/.cache/cco/projects/projectA/.claude/packs.md:/workspace/.claude/packs.md:ro
      # Session transcripts (STATE; enables /resume across rebuilds)
      - /home/me/.local/state/cco/projects/projectA/claude-state:/home/claude/.claude/projects/-workspace
      # Memory (STATE; machine-local, no sync in v1; separate from transcripts)
      - /home/me/.local/state/cco/projects/projectA/session/memory:/home/claude/.claude/projects/-workspace/memory
      # Global MCP servers (optional, merged into ~/.claude.json by entrypoint)
      # - /home/me/.cco/.claude/mcp.json:/home/claude/.claude/mcp-global.json:ro
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

All settings are in `project.yml` under the `docker` key. See [project-yaml.md](../configuration/reference/project-yaml.md) for the full field reference.

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
| Project not found | `Error: Project 'foo' not found. Run 'cco list project' to see available projects.` |
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

### 8.2 Global MCP (`~/.cco/.claude/mcp.json`)

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
