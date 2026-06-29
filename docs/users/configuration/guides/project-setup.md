# Project Setup Guide

> Related: [cli.md](../../reference/cli.md) | [context.md](../../foundation/reference/context-hierarchy.md) | [architecture.md](../../../maintainers/foundation/design/architecture.md)

---

## 1. Initialize a Project

A project's config lives **inside the repo it serves**, under `<repo>/.cco/`. The
repo you run `cco init` in becomes the project's **host repo**. Run it from
within that repo:

```bash
cd ~/projects/backend-api
cco init
```

This scaffolds `<repo>/.cco/` and registers the project in the machine-local index:

```
~/projects/backend-api/
└── .cco/
    ├── project.yml              # Main configuration
    ├── claude/
    │   ├── CLAUDE.md            # Instructions for Claude (project-level)
    │   ├── settings.json        # Settings overrides (optional)
    │   ├── agents/              # Custom subagents (optional)
    │   └── rules/               # Custom rules (optional)
    ├── secrets.env.example      # Template for credentials/tokens
    └── .gitignore               # Ignores secrets.env
```

The CLI auto-detects basic information from the host repo (package.json,
pyproject.toml, go.mod, etc.) and populates CLAUDE.md with relevant details.

For a multi-repo project, add the other repositories as members from the host repo:

```bash
cco project add repo frontend-app --path ~/projects/frontend-app
```

The host repo's `.cco/project.yml` carries logical names + machine-agnostic
coordinates; each member repo's real path on this machine is stored in the index
(never committed).

To work on a project a teammate has already shared, clone its host repo and run
`cco start <project>` from inside it — cwd-first resolution registers it
automatically (run `cco resolve --scan <dir>` first to bind member paths). Use
`cco join <project>` to add the **current** repo as a new member of an existing
project. To migrate a project from a legacy central install into its repo, use
`cco init --migrate <project>`.

### Configuration Assistant

If you prefer Claude's help to create and manage projects, the config-editor is
built in:

```bash
cco start config-editor
```

The config-editor mounts your personal store `~/.cco` with write access (and, in
project mode, the target `<repo>/.cco`), allowing Claude to create projects,
packs, and configuration files for you interactively.

---

## 2. Configure project.yml

### Repos vs Extra Mounts vs Packs

| Field | Purpose | Mounted at | Loaded in context | Typical use |
|-------|---------|------------|-------------------|-------------|
| `repos` | Active working repositories | `/workspace/<name>/` | On-demand (when Claude reads files) | Code Claude modifies |
| `extra_mounts` | Reference material | Custom path | No (Claude reads on request) | Shared libs, API specs, datasets |
| `packs` | Reusable cross-project knowledge + skills/agents/rules | `/workspace/.claude/packs/<name>/` | Yes (automatic via SessionStart hook) | Conventions, business overviews, guidelines; shared skills/agents |

**repos** — The repositories Claude actively works on. Mounted as subdirectories of `/workspace/` with read-write access. Any `.claude/CLAUDE.md` inside a repo is loaded automatically when Claude reads files in that directory.

**extra_mounts** — Additional material for reference. Mounted at an arbitrary path in the container, typically read-only. Useful for shared libraries (e.g. internal frameworks), API specs, or any reference files Claude might need to read but not modify.

**packs** — Groups of knowledge documents (conventions, business overviews, guidelines) defined once and reusable across projects without copying anything. Packs are resolved from your personal store (`~/.cco/packs/`) or a sharing repo; a pack with no `url` coordinate can be authored project-local in `<repo>/.cco/packs/`. The pack's source directory is mounted read-only; files are automatically injected into Claude's context via the SessionStart hook (no CLAUDE.md edit required). Packs can also contribute project-level skills, agents, and rules. Ideal for cross-cutting documentation and tooling that applies to all projects for a given client or domain.

```yaml
repos:
  - name: backend-api
  - name: frontend-app

extra_mounts:
  - name: shared-framework
    target: /workspace/shared-framework
    readonly: true

packs:
  - my-client-knowledge   # → ~/.cco/packs/my-client-knowledge/pack.yml
```

### Configure a Pack

Create `~/.cco/packs/<name>/pack.yml` (or `<repo>/.cco/packs/<name>/pack.yml` for a project-local pack):

```yaml
name: my-client-knowledge

knowledge:
  source: ~/documents/my-client    # directory with knowledge files (mounted :ro)
  files:
    - path: backend-coding-conventions.md
      description: "Read when writing backend code, APIs, or DB logic"
    - path: business-overview.md
      description: "Read for business context and product understanding"
    - testing-guidelines.md   # short form: no description

# Optional: shared skills, agents, rules
# skills:
#   - deploy
# agents:
#   - devops-specialist.md
# rules:
#   - api-conventions.md
```

That's it — **no CLAUDE.md edit needed**. Every `cco start` mounts the source directory read-only, generates `.claude/packs.md` with the file list and descriptions, and the `session-context.sh` hook injects it into `additionalContext` automatically. Claude sees which files are available and reads them on-demand when relevant. The original files stay in your knowledge repo — zero duplication.

### Install and Reference Framework Documentation

Official framework documentation can be installed and referenced separately from knowledge packs:

```bash
cco llms install https://svelte.dev/docs/svelte/llms.txt
```

Reference in `project.yml`:

```yaml
llms:
  - name: svelte
    url: https://svelte.dev/llms.txt   # required — the re-fetch coordinate
```

See [project-yaml.md § LLMs.txt](../reference/project-yaml.md#llmstxt--framework-documentation) for all options.

### Ports and Environment Variables

```yaml
docker:
  ports:
    - "3000:3000"       # Frontend dev server
    - "4000:4000"       # Backend API
    - "5432:5432"       # PostgreSQL (sibling container)
  env:
    NODE_ENV: development
    DATABASE_URL: "postgresql://postgres:postgres@postgres:5432/myapp"
```

Ports make services accessible from `localhost` on macOS. Environment variables are available inside the container.

### Authentication

```yaml
auth:
  method: oauth         # Default: use token from macOS Keychain
  # method: api_key     # Alternative: use ANTHROPIC_API_KEY env var
```

With `oauth` (default), credentials are seeded from the macOS Keychain into the container automatically. If seeding is not available (first-time setup, Linux host, or expired credentials), Claude Code prompts for authentication directly inside the container by displaying a URL to open in a browser.

**Important**: Copying the authentication URL from a tmux session requires specific copy-paste steps. See [Copy & Paste in tmux Mode](../../integration/guides/agent-teams.md#24-copy--paste-in-tmux-mode) for how to copy text from the container, including the [in-container login](#in-container-login-without-credential-seeding) section for this specific scenario.

### Browser Automation (optional)

Enable Claude to control a browser via Chrome DevTools Protocol (CDP). The browser runs on your host OS and is visible in real time while Claude operates it.

```yaml
browser:
  enabled: true           # Activate chrome-devtools-mcp
  mode: host              # Chrome runs on your host (default and only mode)
  cdp_port: 9222          # Chrome remote debugging port (default: 9222)
  mcp_args: []            # Extra flags for chrome-devtools-mcp
```

**Setup**:
1. Add `browser.enabled: true` to `project.yml`, or use `cco start <project> --chrome` for a one-session override
2. Launch Chrome with remote debugging: `cco chrome start`
3. Start your session: `cco start <project>`

Claude can now use browser tools (navigate, click, fill forms, read pages, take screenshots) via the `chrome-devtools-mcp` server.

For the complete guide — including multi-project setup, security, troubleshooting, and all available browser tools — see [browser-automation.md](../../integration/guides/browser-automation.md).

---

## 3. Writing a Good CLAUDE.md

The file `<repo>/.cco/claude/CLAUDE.md` (in the project's host repo) is the central place to give Claude context about the project. A good CLAUDE.md is the difference between productive sessions and sessions where Claude constantly asks for clarification.

### Recommended Approach: Use /init-workspace

On the first session for a project, ask Claude to analyze the codebase:

```
> /init-workspace
```

The orchestrator ships `/init-workspace` as a managed skill (baked into the Docker image at `/etc/claude-code/.claude/skills/init-workspace/`). It reads `workspace.yml` (generated by `cco start`), explores each repository, and generates a structured CLAUDE.md covering: overview, workspace layout, per-repo stack and commands, architecture, and knowledge pack descriptions. Optionally pass `repos`, `packs`, or `all` (default) to limit scope.

You can then refine the generated CLAUDE.md manually. Preserved sections survive subsequent `/init-workspace` runs.

### What to Include

- **Overview**: What the project does, how the repositories relate to each other
- **Architecture**: Technologies, patterns, main components
- **Commands**: Build, test, dev server, deploy — for each repository
- **Conventions**: Code style, naming, patterns to follow
- **Infrastructure**: If you use Docker Compose for services (postgres, redis...), specify the project network

### Example

```markdown
# Project: my-saas

## Overview
SaaS platform with a Node.js backend and React frontend.

## Repositories
- `/workspace/backend-api/` — REST + GraphQL API (Node.js, Express, Prisma)
- `/workspace/frontend-app/` — React SPA with Vite + TailwindCSS

## Architecture
The backend exposes REST API on :4000 and GraphQL on :4000/graphql.
The frontend communicates via fetch with the backend.
PostgreSQL reachable as `postgres:5432` on the Docker network.

## Commands
### backend-api
- Dev: `npm run dev` (port 4000)
- Test: `npm test` / `npm run test:watch`
- Lint: `npm run lint`

### frontend-app
- Dev: `npm run dev` (port 3000)
- Build: `npm run build`
- Test: `npm run test`

## Infrastructure
Docker network: `cc-<project-name>` (matches the `name:` field in your `project.yml`)
For infrastructure docker-compose files, use:
\`\`\`yaml
networks:
  default:
    external: true
    name: cc-my-saas   # replace with your actual project name
\`\`\`
```

---

## 4. Context Hierarchy

Claude Code loads instructions in order of precedence:

```
1. ~/.claude/CLAUDE.md                          ← Global (always loaded)
   └── ~/.claude/rules/*.md

2. /workspace/.claude/CLAUDE.md                 ← Project (always loaded)
   └── /workspace/.claude/rules/*.md

   + additionalContext (SessionStart hook):
       ├── project name, repos, MCP servers
       └── packs.md content               ← Knowledge packs (automatic)
             /workspace/.claude/packs/<name>/*.md  ← read on-demand by Claude

3. /workspace/<repo>/.claude/CLAUDE.md          ← Repository (on-demand)
```

Project settings (level 2) override global settings (level 1). Repository instructions (level 3) are added when Claude reads files in that directory.

**Knowledge packs** are injected by the `session-context.sh` hook into `additionalContext` at startup — Claude sees what files are available and reads them on-demand. No `@.claude/packs.md` import in CLAUDE.md is required or needed.

For more details on the hierarchy see [context.md](../../foundation/reference/context-hierarchy.md).

### The four `.claude` scopes and their reach

The container paths above are sourced from four distinct host-side scopes — three
user-managed plus one framework-managed. What distinguishes them is **reach**: who
sees the config you put there.

| Scope | Host source | Container path | Reach |
|---|---|---|---|
| **Managed** | `defaults/managed/` (baked in image) | `/etc/claude-code/` | Non-overridable framework policy; own path, highest priority |
| **Global user** | `~/.cco/.claude/` | `~/.claude` | All of my projects on this machine |
| **Project / cross-repo** | the host repo's `<repo>/.cco/claude/` | `/workspace/.claude` | This project, across all its repos (no cross-project leak) |
| **Repo-native** | `<repo>/.claude/` | `/workspace/<repo>/.claude` | Cross-cutting: every project that mounts this repo, **and** native (non-cco) Claude use |

Two consequences:

- **`<repo>/.cco/claude/` is per-(hosted-)project and never leaks across projects.**
  Only the **invoking** repo's `.cco/claude/` becomes `/workspace/.claude`; a repo
  that merely *references* another project does not pull in that project's
  `.cco/claude/`.
- **`<repo>/.claude/` (repo-native) is the cross-cutting tree** — loaded for every
  project that mounts the repo and for plain Claude use. cco never reads or syncs it.

**Where to put a thing — by intended reach:**

| Intended reach | Put it in |
|---|---|
| cross-cutting whenever this repo is mounted (+ native Claude) | `<repo>/.claude/` (repo-native) |
| this project, across all its repos | the host repo's `<repo>/.cco/claude/` (project scope) |
| all of my projects on this machine | `~/.cco/.claude/` |
| non-overridable framework policy | `defaults/managed/` (managed) |

---

## 5. Keeping Configuration Separate per Machine

Project config lives **inside each repo** (`<repo>/.cco/`), and personal config
lives in your store at `~/.cco/`. There is no central `user-config/` directory to
relocate — cloning the same repos on another machine gives you the same project
config automatically (it travels with the code).

What is **machine-local** — the name→path index, session transcripts, memory, and
caches — lives under XDG directories (`~/.local/state/cco`, `~/.cache/cco`,
`~/.local/share/cco`) and is managed automatically. You never hand-edit these, and
they are not committed or synced (see *Path Portability*, below).

To back up or sync your **personal store** across machines, version `~/.cco/` with
`cco config save/push/pull` (see section 6).

---

## 6. Versioning and Sharing Configuration

Project config and personal config are versioned through **two separate channels**:

- **Project config** (`<repo>/.cco/`) is versioned with **normal git** — it is
  committed inside the repo it serves and travels with the code.
- **Personal config** (`~/.cco/` — global `.claude/`, packs, templates) is versioned
  with `cco config`:

```bash
# Version your personal store with automatic secret detection
cco config save "Initial config"
cco config push                   # Push to a remote for backup / multi-machine sync
cco config pull                   # Restore on another machine

# Install packs from a team sharing repo
cco pack install git@github.com:my-org/cco-packs
```

When the orchestrator is updated (`git pull`), run `cco update` to run migrations and discover available framework changes. Use `cco update --diff` to preview changes, and `cco update --sync` to interactively sync them via 3-way merge that preserves your customizations. When edits overlap, the file is written with conflict markers (like git) — resolve them manually, then run `cco update --sync` again. **Note**: `cco start` will block if any config files contain unresolved conflict markers. Use `cco clean` to remove `.bak` backups after reviewing.

For the full workflow (`cco config` commands, multi-machine sync, team sharing, publishing), see the [Configuration Management guide](configuration-management.md).

### How to share a project

Project config is **distributed per host repo**: each project is shared by riding
**its own host repo's git remote**. There is no central project store and no
`cco project publish` — you commit `<repo>/.cco/` and push the repo; a teammate
clones it and runs `cco start <project>` (cwd-first resolution registers it).

- **A repo hosts exactly one project** (its `project.yml` `name`) — one development
  scope. The same repo may be **referenced** by N other projects as a member.
- **The cross-project case** (two projects that depend on each other): each project
  lives in **its own** host repo and **mounts the other** as a member. For example,
  `cave-auth` hosts and shares project `cave-auth` (and mounts `cave-infrastructure`),
  while `cave-infrastructure` hosts and shares project `cave-infrastructure` (and
  mounts `cave-auth`). Two host repos, two remotes, two audiences — the shared repo
  is mounted by both, but the two projects are distinct scopes.
- **You cannot host two projects in one repo.** To get a second project that
  references an existing repo, create a separate, config-only host repo whose
  `project.yml` references the original repo as a member.

When `cco sync` would write a project's config into a repo that already hosts a
**different** project, it **skips and warns** (it never clobbers another project's
config). To re-home a repo, de-init then re-init it.

---

## 7. Path Portability (Multi-Machine)

Repo and mount paths are **machine-local by construction**: `project.yml` carries
only logical names + machine-agnostic `url`/`ref` coordinates, while each name's
real absolute path on this machine lives in the **STATE index** (never committed).
So a committed `<repo>/.cco/` is portable as-is — nothing in it points at a path
specific to your machine.

On a new machine (or for a freshly added member repo), `cco start` detects names
with no resolved local path and prompts you to:

- **(c) Clone** — auto-clone from the `url:` coordinate (derived from the git remote)
- **(p) Specify path** — enter the path where the repo lives on this machine
- **(s) Skip** — skip the repo for this session (prompted again next time)

You can also resolve paths ahead of time:

```bash
cco resolve myapp                              # Interactive mode
cco resolve myapp --repo backend ~/dev/be      # Direct set
cco path myapp                                 # Show resolved paths / status
```

This is transparent — the system records each name→path mapping in the index and
reuses it on every subsequent session.

---

## 8. Post-Creation Checklist

> See also: [Knowledge Packs guide](../../packs/guides/knowledge-packs.md) for creating and managing packs, [Authentication guide](../../integration/guides/authentication.md) for OAuth and API key setup.

After `cco init`:

- [ ] Verify `.cco/project.yml`: repos, ports, environment variables
- [ ] Customize `.cco/claude/CLAUDE.md` (or use `/init-workspace` on the first session)
- [ ] **Define your git branching model** in `~/.cco/.claude/rules/git-practices.md` — specify which branches exist, what work is allowed on each, and the merge flow direction. See [Configuring Rules — Git Practices](configuring-rules.md#3-git-practices) for guidance and examples
- [ ] Add custom settings in `.cco/claude/settings.json` if needed
- [ ] Configure `packs:` in `.cco/project.yml` if you have cross-project knowledge or shared skills to include
- [ ] (Packs no longer require any CLAUDE.md edit — they're injected automatically)
- [ ] Commit `<repo>/.cco/` (excluding `secrets.env`) so teammates get the same setup
- [ ] First run: `cco start <name>` — verify everything works
- [ ] Optional: add custom subagents in `.cco/claude/agents/`
