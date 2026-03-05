# CLI Specification

> Version: 1.0.0
> Status: v1.0 — Current
> Related: [spec.md](../maintainer/spec.md) | [docker.md](../maintainer/docker/design.md)

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

# Initialize user config and build Docker image
cco init

# Add to PATH (if not done automatically)
# bash:
echo 'export PATH="$PATH:$HOME/claude-orchestrator/bin"' >> ~/.bashrc && source ~/.bashrc
# zsh:
# echo 'export PATH="$PATH:$HOME/claude-orchestrator/bin"' >> ~/.zshrc && source ~/.zshrc
```

---

## 3. Commands

### 3.0 `cco init`

Initialize user configuration by copying defaults. Required before first use.

```
Usage: cco init [--force] [--lang <language>]

Options:
  --force            Overwrite existing user-config/global/ config with defaults
  --lang <language>  Set communication language for Claude (default: English)

Examples:
  cco init                    # First-time setup (English)
  cco init --lang Italian     # First-time setup with Italian communication
  cco init --force            # Reset global config to defaults
```

**`--lang` and language templates**

The file `defaults/global/.claude/rules/language.md` contains three placeholders that `cco init` substitutes:

| Placeholder | Controls | Example value |
|-------------|----------|---------------|
| `{{COMM_LANG}}` | Claude's response/communication language | `Italian` |
| `{{DOCS_LANG}}` | Language for docs (README, guides) | `English` |
| `{{CODE_LANG}}` | Language for code comments/docstrings | `English` |

When `--lang` is provided, `{{COMM_LANG}}` is set to that language. `{{DOCS_LANG}}` and `{{CODE_LANG}}` always default to `English` (code is universal). To customize further, edit `user-config/global/.claude/rules/language.md` directly after `cco init`.

**Flow**:

```
1. COPY user defaults: defaults/global/.claude/ → user-config/global/.claude/
   - If user-config/global/ exists: skip (warn user, suggest --force)
   - If --force: overwrite

2. SUBSTITUTE language placeholders in user-config/global/.claude/rules/language.md
   - Replace {{COMM_LANG}} with --lang value (default: English)
   - Replace {{DOCS_LANG}} with English
   - Replace {{CODE_LANG}} with English

3. SYNC system files: defaults/system/.claude/ → user-config/global/.claude/ (always, even without --force)
   - Overwrites skills, agents, rules, settings.json from system.manifest
   - Preserves user-added files not in the manifest
   - Removes deprecated paths from previous manifest

4. CREATE user-config/projects/ directory (if needed)

5. PATH HINT
   - If cco is not in PATH, show the export command

6. BUILD Docker image
   - If Docker is running, run `cco build`
   - Otherwise, warn to run it later
```

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

MCP packages can also be listed in `user-config/global/mcp-packages.txt` (one per line) for automatic loading on every build.

---

### 3.2 `cco start <project>`

Start an interactive Claude Code session for a configured project.

```
Usage: cco start <project> [OPTIONS]

Arguments:
  project              Name of the project (directory under user-config/projects/)

Options:
  --teammate-mode <m>  Override display mode: tmux | auto
  --api-key            Use ANTHROPIC_API_KEY instead of OAuth
  --chrome             Enable browser automation for this session only
  --no-chrome          Disable browser automation for this session only
  --no-docker          Disable Docker socket mount for this session only
  --dry-run            Show the generated docker-compose without running
  --port <p>           Add extra port mapping (repeatable)
  --env <K=V>          Add extra environment variable (repeatable)

Session flags override project.yml for one session only.
To change the default, edit project.yml instead.

Examples:
  cco start my-saas
  cco start my-saas --chrome        # enable browser for this session
  cco start my-saas --no-chrome     # disable browser for this session
  cco start my-saas --no-docker     # disable Docker socket for this session
  cco start my-saas --teammate-mode auto
  cco start my-saas --port 9090:9090
  cco start my-saas --dry-run
```

**Flow**:

```
1. VALIDATE
   - Check user-config/projects/<project>/project.yml exists
   - Parse project.yml
   - Check no existing running session for this project (die if container cc-<name> is running)
   - Verify each repo path exists on host
   - Check Docker image exists (suggest `cco build` if not)

2. GENERATE docker-compose.yml
   - Read project.yml repos → generate volume mounts
   - Read project.yml ports → generate port mappings
   - Read project.yml auth → set auth volumes/env vars
   - If mcp.json exists → mount as /workspace/.mcp.json (Claude Code expands ${VAR} natively)
   - Mount global MCP config for entrypoint merge
   - Apply CLI overrides (--port, --env, --teammate-mode)
   - Write to user-config/projects/<project>/docker-compose.yml

3. GENERATE pack resources
   - Clean stale files from previous .pack-manifest
   - Detect name conflicts across packs (warn if same agent/rule/skill in multiple packs)
   - Copy skills, agents, rules from each pack into user-config/projects/<n>/.claude/
   - Write new .pack-manifest tracking all copied files
   - Generate .claude/packs.md (instructional list of knowledge files)
   - Generate .claude/workspace.yml (structured project summary for /init)

4. CREATE directories (if needed)
   - user-config/projects/<project>/claude-state/memory/  (for auto memory + session transcripts; migrates legacy memory/ if present)

5. LAUNCH
   - Load user-config/global/secrets.env as runtime env vars (validates KEY=VALUE format, skips malformed lines with warning)
   - docker compose -f user-config/projects/<project>/docker-compose.yml \
       run --rm --service-ports claude

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
     - Global config mounted (same as user-config/projects)
     - No project .claude/ (empty /workspace/.claude/)
     - Specified repos mounted as subdirectories
     - Auto memory in temp dir

3. LAUNCH
   - Same as `cco start` but with temp compose file

4. CLEANUP
   - Container removed
   - Temp dir preserved (claude-state/ may be useful)
   - Print path to temp dir for reference
```

---

### 3.4 `cco project create <name>`

Create a new project from the template.

```
Usage: cco project create <name> [OPTIONS]

Arguments:
  name                 Project name (lowercase, hyphens, no spaces)

Options:
  --repo <path>        Add a repo to the project (repeatable)
  --description <d>    Project description

Examples:
  cco project create my-saas --repo ~/projects/api --repo ~/projects/web
  cco project create experiment --description "Testing new auth flow"
```

**Flow**:

```
1. VALIDATE
   - Name is valid (lowercase, hyphens, no spaces)
   - user-config/projects/<name>/ does not already exist

2. COPY template
   - Copy defaults/_template/ → user-config/projects/<name>/

3. CONFIGURE
   - If --repo flags provided: write repos to project.yml
   - If --description provided: update project.yml and CLAUDE.md
   - Replace {{PROJECT_NAME}} and {{DESCRIPTION}} placeholders

4. CREATE directories
   - user-config/projects/<name>/claude-state/memory/

5. PRINT
   - "Project created at user-config/projects/<name>/"
   - "Edit project.yml to configure repos and settings"
   - "Run: cco start <name>"
```

---

### 3.5 `cco project list`

List available projects with their status.

```
Usage: cco project list

Output:
  NAME           REPOS    STATUS
  my-saas        3        stopped
  experiment     1        running
  _template      -        (template)
```

**Implementation**:
- List directories under `user-config/projects/` (exclude `_template`)
- Parse each `project.yml` for repo count
- Check Docker for running containers (`cc-<name>`)

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
2. `--project <name>` → reads `user-config/projects/<name>/.managed/.browser-port` (effective runtime port)
3. `--project <name>` → falls back to `user-config/projects/<name>/project.yml` `browser.cdp_port`
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
Usage: cco pack create <name>

Arguments:
  name                 Pack name (lowercase letters, numbers, and hyphens only)

Examples:
  cco pack create react-guidelines
  cco pack create devops-tools
```

**Flow**:

```
1. VALIDATE
   - Global config exists (check_global)
   - Name matches pattern: ^[a-z0-9][a-z0-9-]*$
   - user-config/packs/<name>/ does not already exist

2. CREATE directory structure
   - user-config/packs/<name>/
   - user-config/packs/<name>/knowledge/
   - user-config/packs/<name>/skills/
   - user-config/packs/<name>/agents/
   - user-config/packs/<name>/rules/

3. GENERATE pack.yml
   - Scaffold with name field and commented-out sections
     for knowledge, skills, agents, rules

4. PRINT
   - "Pack created at user-config/packs/<name>/"
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
- Iterates directories under `user-config/packs/`
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
   - user-config/packs/<name>/ exists
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
   - user-config/packs/<name>/ exists

2. CHECK usage
   - Scan all projects for references to this pack
   - If used by projects:
     - Display warning: "Pack '<name>' is used by: <project-list>"
     - Without --force: prompt for confirmation (y/N)
     - Non-interactive terminal without --force: error and abort

3. REMOVE
   - rm -rf user-config/packs/<name>/
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
   - user-config/projects/<name>/project.yml exists

2. DISPLAY
   - Name and description (from project.yml)
   - Repos: list with path existence check ([missing] marker for absent paths)
   - Packs: list with existence check ([not found] marker for absent packs)
   - Docker config: auth method, ports, network name
   - Status: checks Docker for running container (cc-<name>)
```

---

### 3.14 `cco project validate <name>`

Validate project structure and configuration.

```
Usage: cco project validate <name>

Arguments:
  name                 Project name to validate

Examples:
  cco project validate my-saas
```

**Flow**:

```
1. VALIDATE
   - project.yml exists (fatal if missing)
   - 'name' field is present in project.yml
   - .claude/ directory exists (warns if missing)
   - Each configured repo path exists on the filesystem
   - Each referenced pack exists in user-config/packs/

2. RESULT
   - Errors for missing project.yml, missing name field, missing repo paths,
     missing packs
   - Warnings for missing .claude/ directory, no repos configured
   - Returns exit code 1 if any errors found
   - "Project '<name>' is valid" on success
```

---

### 3.15 `cco update [OPTIONS]`

Update global and/or project configuration from defaults.

```
Usage: cco update [OPTIONS]

Options:
  --project <name>     Update a specific project (instead of global)
  --all                Update global config + all projects
  --dry-run            Show what would change without modifying anything
  --force              Overwrite even user-modified files
  --keep               Always keep user version on conflicts
  --backup             Create .bak backup + overwrite on conflicts

Examples:
  cco update                    # Update global defaults (interactive)
  cco update --dry-run          # Preview changes
  cco update --project myapp    # Update specific project
  cco update --all              # Update global + all projects
  cco update --force            # Overwrite all conflicts
```

**Flow**:

```
1. DETERMINE scope
   - --all: update global config, then iterate all projects
   - --project <name>: update only the specified project
   - Default (no flags): update global config only

2. UPDATE
   - Detect changes between defaults and current config
   - Preserve user modifications based on conflict mode:
     - Interactive (default): prompt user for each conflict
     - --force: overwrite all conflicts with defaults
     - --keep: always keep existing user version
     - --backup: create .bak backup, then overwrite

3. RESULT
   - --dry-run: "Dry run complete. No changes made."
   - Otherwise: "Update complete."
```

---

### 3.16 `cco pack install <url>`

Install packs from a remote Config Repo.

```
Usage: cco pack install <url> [OPTIONS]

Arguments:
  url                  URL of the Config Repo (git repository)

Options:
  --pick <name>        Install only a specific pack from the repo
  --token <t>          Authentication token for private repos
  --force              Overwrite existing pack with the same name

Examples:
  cco pack install https://github.com/team/config-repo
  cco pack install https://github.com/team/config-repo --pick react-guidelines
  cco pack install https://github.com/team/config-repo --token ghp_... --force
```

---

### 3.17 `cco pack update`

Update pack(s) from their remote source.

```
Usage: cco pack update <name> [--force]
       cco pack update --all

Arguments:
  name                 Pack name to update

Options:
  --all                Update all packs that have a remote source
  --force              Overwrite local modifications

Examples:
  cco pack update react-guidelines
  cco pack update react-guidelines --force
  cco pack update --all
```

---

### 3.18 `cco pack export <name>`

Export a pack as a `.tar.gz` archive.

```
Usage: cco pack export <name>

Arguments:
  name                 Pack name to export

Examples:
  cco pack export react-guidelines
```

---

### 3.19 `cco project install <url>`

Install a project template from a Config Repo.

```
Usage: cco project install <url> [OPTIONS]

Arguments:
  url                  URL of the Config Repo (git repository)

Options:
  --pick <n>           Install only a specific project template from the repo
  --as <n>             Use a custom name for the installed project
  --var K=V            Set a template variable (repeatable)
  --token <t>          Authentication token for private repos
  --force              Overwrite existing project with the same name

Examples:
  cco project install https://github.com/team/config-repo
  cco project install https://github.com/team/config-repo --pick saas-template --as my-saas
  cco project install https://github.com/team/config-repo --var DB_HOST=localhost --var DB_PORT=5432
  cco project install https://github.com/team/config-repo --token ghp_... --force
```

---

### 3.20 `cco vault`

Git-backed configuration versioning for `user-config/`.

#### `cco vault init [<path>]`

Initialize git-backed config versioning.

```
Usage: cco vault init [<path>]

Arguments:
  path                 Path to initialize (default: user-config/)

Examples:
  cco vault init
  cco vault init ~/my-config
```

#### `cco vault sync [msg]`

Commit config state with pre-commit summary.

```
Usage: cco vault sync [msg] [OPTIONS]

Arguments:
  msg                  Optional commit message (auto-generated if omitted)

Options:
  --yes                Skip confirmation prompt
  --dry-run            Show what would be committed without committing

Examples:
  cco vault sync
  cco vault sync "Added react-guidelines pack"
  cco vault sync --dry-run
  cco vault sync --yes
```

#### `cco vault diff`

Show uncommitted changes by category.

```
Usage: cco vault diff
```

#### `cco vault log`

Show commit history.

```
Usage: cco vault log [OPTIONS]

Options:
  --limit N            Show only the last N commits (default: 10)

Examples:
  cco vault log
  cco vault log --limit 5
```

#### `cco vault restore <ref>`

Restore config to a previous state.

```
Usage: cco vault restore <ref>

Arguments:
  ref                  Git ref to restore (commit hash, tag, etc.)

Examples:
  cco vault restore abc1234
  cco vault restore HEAD~3
```

#### `cco vault remote add <name> <url>`

Add a remote to the vault.

```
Usage: cco vault remote add <name> <url>

Examples:
  cco vault remote add origin https://github.com/user/my-config.git
```

#### `cco vault push [<remote>]` / `cco vault pull [<remote>]`

Push or pull vault to/from a remote.

```
Usage: cco vault push [<remote>]
       cco vault pull [<remote>]

Arguments:
  remote               Remote name (default: origin)

Examples:
  cco vault push
  cco vault pull
  cco vault push backup
```

#### `cco vault status`

Show vault state.

```
Usage: cco vault status
```

---

### 3.21 `cco manifest`

Manage the `manifest.yml` manifest for sharing packs and templates via Config Repos.

#### `cco manifest refresh`

Regenerate `manifest.yml` from `user-config/packs/` and `user-config/templates/`.

```
Usage: cco manifest refresh
```

#### `cco manifest validate`

Cross-check `manifest.yml` against the actual files on disk.

```
Usage: cco manifest validate
```

#### `cco manifest show`

Display `manifest.yml` contents.

```
Usage: cco manifest show
```

---

## 4. Project Configuration Format (project.yml)

See [project-yaml.md](project-yaml.md) for the complete project.yml field reference and knowledge pack format.

---

## 5. Generated docker-compose.yml

The CLI generates `docker-compose.yml` from `project.yml`. The generated file includes a header comment:

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
      - ../../user-config/global/claude-state/claude.json:/home/claude/.claude.json
      # Auth: OAuth credentials (seeded from macOS Keychain, auto-refreshed by Claude)
      - ../../user-config/global/claude-state/.credentials.json:/home/claude/.claude/.credentials.json
      # Global config
      - ../../user-config/global/.claude/settings.json:/home/claude/.claude/settings.json:ro
      - ../../user-config/global/.claude/CLAUDE.md:/home/claude/.claude/CLAUDE.md:ro
      - ../../user-config/global/.claude/rules:/home/claude/.claude/rules:ro
      - ../../user-config/global/.claude/agents:/home/claude/.claude/agents:ro
      - ../../user-config/global/.claude/skills:/home/claude/.claude/skills:ro
      # Project config
      - ./.claude:/workspace/.claude
      - ./project.yml:/workspace/project.yml:ro
      # Claude state: auto memory + session transcripts (enables /resume across rebuilds)
      - ./claude-state:/home/claude/.claude/projects/-workspace
      # Global MCP servers (optional, merged into ~/.claude.json by entrypoint)
      # - ../../user-config/global/.claude/mcp.json:/home/claude/.claude/mcp-global.json:ro
      # Project MCP servers (optional, Claude Code expands ${VAR} natively)
      # - ./mcp.json:/workspace/.mcp.json:ro
      # Project setup script (optional, executed by entrypoint at runtime)
      # - ./setup.sh:/workspace/setup.sh:ro
      # Project MCP packages (optional, installed by entrypoint at runtime)
      # - ./mcp-packages.txt:/workspace/mcp-packages.txt:ro
      # Repositories
      - ~/projects/backend-api:/workspace/backend-api
      - ~/projects/frontend-app:/workspace/frontend-app
      - ~/projects/shared-libs:/workspace/shared-libs
      # Extra mounts
      - ~/documents/api-specs:/workspace/docs/api-specs:ro
      # Git identity
      - ~/.gitconfig:/home/claude/.gitconfig:ro
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

> **Note**: Conditional mounts (Global MCP, Project MCP, setup.sh, mcp-packages.txt) are only included when the corresponding file exists. They are shown commented out above for reference.

---

## 6. Error Handling

| Scenario | Behavior |
|----------|----------|
| Project not found | `Error: Project 'foo' not found. Run 'cco project list' to see available projects.` |
| Session already running | `Error: Project 'foo' already has a running session (container cc-foo). Run 'cco stop foo' first.` |
| Repo path doesn't exist | `Error: Repository path ~/projects/foo does not exist.` |
| Docker image not built | `Error: Docker image 'claude-orchestrator:latest' not found. Run 'cco build' first.` |
| Docker not running | `Error: Docker daemon is not running. Start Docker Desktop.` |
| Port conflict | `Error: Port 3000 is already in use. Stop the conflicting service or use --port to remap.` |
| Project already exists | `Error: Project 'foo' already exists at user-config/projects/foo/` |
| Malformed secrets.env | `Warning: secrets.env:3: skipping malformed line (expected KEY=VALUE)` |

---

## 7. MCP Server Configuration

### 7.1 Project MCP (`mcp.json`)

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

The `${VAR}` placeholders are expanded **natively by Claude Code** inside the container. The env vars must be available in the container environment via `user-config/global/secrets.env`, `project.yml` `docker.env`, or `--env` CLI flags.

**Important**: If a `${VAR}` reference in `mcp.json` cannot be resolved (env var not set), Claude Code will fail to parse the entire file and show "No MCP servers configured".

### 7.2 Global MCP (`user-config/global/.claude/mcp.json`)

MCP servers defined here are available in all projects. The entrypoint merges global and project MCP servers into `~/.claude.json` at container startup using `jq`. This ensures MCP servers are available via the user-scope mechanism (most reliable).

### 7.3 Secrets (`user-config/global/secrets.env`)

```bash
# user-config/global/secrets.env — gitignored
GITHUB_TOKEN=ghp_...
LINEAR_API_KEY=lin_api_...
```

Loaded by `cco start` and `cco new` as runtime `-e` flags. Never written to `docker-compose.yml`.

---

## 8. Shell Completion (Future)

Bash/Zsh completion for:
- `cco start <TAB>` → list project names
- `cco project create <TAB>` → suggest name patterns
- `cco stop <TAB>` → list running sessions

Not in v1 scope but trivial to add later.
