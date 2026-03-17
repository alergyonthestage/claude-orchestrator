# Tutorial Project — Design

**Date**: 2026-03-17
**Version**: 2.1
**Scope**: Sprint 5 — Interactive Tutorial Project
**Status**: Current — tutorial is an internal framework resource
**Prerequisite**: [analysis.md](./analysis.md)

---

## 1. Design Overview

The tutorial is a framework-internal project at `internal/tutorial/`. It is
NOT installed in user-config — `cco start tutorial` launches it directly from
its source directory.

It uses no knowledge packs. Documentation is mounted live from the
claude-orchestrator repo (`docs/`), and the user's configuration directory
(`user-config/`) is mounted read-only for analysis.

The lead agent IS the guide — no dedicated guide subagent. The project CLAUDE.md provides the tutorial behavior, curriculum, and documentation map. Three inline skills (`/tutorial`, `/setup-project`, `/setup-pack`) serve as entry points for common workflows.

### 1.1 Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Agent model | Lead (inherits session model) | A) Simplest, no delegation overhead. Lead handles everything, delegates to global `analyst` for deep exploration when needed |
| Language | User's chat language (COMM_LANG as fallback) | Detect from user's first message; fall back to configured COMM_LANG |
| Skills context | B) Inline (not fork) | Interactive dialogue — user needs continuous context. Lead can delegate to subagents in specific cases |
| Docker socket | `false` by default | Safer. Agent explains how to enable if needed, with user approval |
| Knowledge packs | None | Self-contained. Docs mounted live, no duplication |
| Distribution | **Internal** (`cco start tutorial`, 2026-03-16) | Always current. No install, no update tracking. See docs/maintainer/configuration/resource-lifecycle/analysis.md §4 |
| Progress tracking | Not in v1 | MEMORY.md tracking deferred. Noted as future enhancement |
| Best practices guide | cco-specific version in `docs/guides/` | General-purpose guide transformed to explain why cco exists and how it implements structured agentic development patterns. Mounted live via `docs/` extra_mount, always fresh |
| Per-project knowledge | Not in v1 | Knowledge section currently only available in packs. Per-project knowledge (same `knowledge:` schema in project.yml) noted as future enhancement in roadmap |

---

## 1.2 Structured Agentic Development Guide

The general-purpose guide at `.claude/docs/resources/structured-agentic-development-guide.md`
is transformed into a **cco-specific guide** and moved to `docs/user-guides/structured-agentic-development.md`.

**Why transform (not copy)**: A general-purpose guide about agentic patterns is useful
but abstract. A cco-specific version explicitly maps each principle to the feature
of claude-orchestrator that implements it, explaining:
- **Why cco exists**: which problems in AI-assisted development it solves
- **How cco implements each pattern**: context hierarchy → stratified rules,
  Docker isolation → sandbox, packs → knowledge curation, etc.
- **How the user should use cco**: practical guidance grounded in the tool's features

**Why keep it whole**: The guide is a coherent ~400-line reference document.
Splitting it into rules would violate the rules constraint (~30 lines, always loaded).
The agent reads it on-demand when advising users on workflow, pack design, or project structure.

**Why move to `docs/user-guides/`**: It becomes official cco documentation alongside
the other user-facing guides, mounted live via the `docs/` extra_mount in the tutorial
project (and any future project that mounts docs). Maintainers update it alongside
other docs — zero staleness risk.

**CLAUDE.md doc map entry**:
```
| Structured development | user-guides/structured-agentic-development.md | When advising on workflow, pack design, project structure, or best practices |
```

**Implementation**: Phase 0 (prerequisite) — transform the guide and move it before
building the tutorial project template. The guide is useful independently of the tutorial.

---

## 2. Project File Structure

> **Updated 2026-03-16**: Path changed from `templates/project/tutorial/` to
> `internal/tutorial/`. No `.cco/` metadata — internal resources don't
> participate in the update system.

```
internal/tutorial/
├── project.yml                        # Fixed config: docs mount, user-config mount (ro)
├── .claude/
│   ├── CLAUDE.md                      # Core: agent behavior + curriculum + doc map
│   ├── settings.json                  # Empty (inherits global)
│   ├── skills/
│   │   ├── tutorial/
│   │   │   └── SKILL.md              # /tutorial — guided onboarding
│   │   ├── setup-project/
│   │   │   └── SKILL.md              # /setup-project — project creation wizard
│   │   └── setup-pack/
│   │       └── SKILL.md              # /setup-pack — pack creation wizard
│   └── rules/
│       └── tutorial-behavior.md       # Behavior constraints
└── setup.sh                           # Empty (no runtime setup needed)
```

**Notes**:
- No `agents/` definitions — the lead agent handles tutorial duties, delegates to global `analyst` when deeper code exploration is needed
- No `mcp.json` — tutorial doesn't need MCP servers
- No `.cco/` metadata — internal resources don't need update tracking
- No `claude-state/` or `memory/` — session state managed by the framework
  (stored in `user-config/.cco/tutorial-state/` or similar)

---

## 3. project.yml

```yaml
name: tutorial
description: "Interactive tutorial and onboarding assistant for claude-orchestrator"

# No repositories — tutorial is about cco itself, not code projects
repos: []

# ── Documentation & User Config ──────────────────────────────────────
# The tutorial agent reads cco documentation and your configuration
# to provide accurate, up-to-date guidance.
extra_mounts:
  # claude-orchestrator documentation (always up to date with your installation)
  - source: {{CCO_REPO_ROOT}}/docs
    target: /workspace/cco-docs
    readonly: true
  # Your user configuration (projects, packs, global settings)
  # Default: read-only (agent can analyze but not modify)
  # Change to readonly: false to let the agent create packs/projects for you
  - source: {{CCO_USER_CONFIG_DIR}}
    target: /workspace/user-config
    readonly: true

# ── Docker options ───────────────────────────────────────────────────
docker:
  # Docker socket disabled by default for safety.
  # Enable (mount_socket: true) if you want the agent to demonstrate
  # Docker features like sibling containers or docker compose.
  mount_socket: false
  ports: []
  env: {}

auth:
  method: oauth
```

### 3.1 Placeholder Substitution

`cco init` replaces these placeholders with absolute paths at creation time:

| Placeholder | Resolved from | Example value |
|-------------|---------------|---------------|
| `{{CCO_REPO_ROOT}}` | `$REPO_ROOT` (bin/cco line 6) | `/Users/alice/claude-orchestrator` |
| `{{CCO_USER_CONFIG_DIR}}` | `$USER_CONFIG_DIR` (bin/cco line 16) | `/Users/alice/claude-orchestrator/user-config` |

The substitution uses `sed`, same pattern as language placeholders in `cmd-init.sh:73-79`.

---

## 4. CLAUDE.md

This is the core of the tutorial project. It defines the agent's identity, behavior, documentation map, and curriculum. Kept under ~200 lines for context efficiency.

```markdown
# Project: tutorial

## Overview

This is the interactive tutorial and onboarding assistant for claude-orchestrator.
You are a knowledgeable guide who helps users learn, configure, and master
claude-orchestrator through conversation, explanation, and hands-on assistance.

## Your Role

You are a tutorial guide. Your purpose is to help users:
1. **Learn** how claude-orchestrator works (concepts, architecture, workflows)
2. **Configure** their projects, packs, and environment effectively
3. **Discover** features and best practices they might not know about

You are NOT an autonomous executor. You are a teacher and consultant who:
- Explains concepts clearly, referencing official documentation
- Shows users what to do and why, making them more autonomous
- Creates files only when explicitly asked, explaining each step
- Suggests `cco` commands for the user to run on their host terminal

## Communication

- Communicate in the language the user writes in. If unclear, use their
  configured communication language.
- Write documentation files and code comments in English.
- Be concise but thorough when explaining concepts.
- Use examples from the user's actual configuration when available.

## Documentation Reference

The official cco documentation is mounted at `/workspace/cco-docs/`. Always
consult these files for accurate, up-to-date information. Never rely solely
on training data for cco-specific details.

### Documentation Map

| Topic | Path | When to read |
|-------|------|-------------|
| Overview & concepts | `getting-started/concepts.md` | Explaining fundamentals |
| First project walkthrough | `getting-started/first-project.md` | Guiding new users |
| Installation steps | `getting-started/installation.md` | Setup questions |
| Project configuration | `user-guides/project-setup.md` | project.yml, CLAUDE.md, repos, mounts, packs |
| Knowledge packs | `user-guides/knowledge-packs.md` | Creating and managing packs |
| Authentication | `user-guides/authentication.md` | OAuth, API key, GitHub token |
| Sharing & backup | `user-guides/sharing.md` | Config Repos, vault, team sharing |
| Agent teams | `user-guides/agent-teams.md` | tmux, iTerm2, multi-agent setup |
| Browser automation | `user-guides/browser-automation.md` | Chrome DevTools, CDP |
| Custom subagents | `user-guides/advanced/subagents.md` | Creating agents, model selection |
| Custom environment | `user-guides/advanced/custom-environment.md` | setup.sh, MCP, Docker images |
| Troubleshooting | `user-guides/troubleshooting.md` | Common issues and solutions |
| CLI reference | `reference/cli.md` | All cco commands and flags |
| Context hierarchy | `reference/context-hierarchy.md` | Settings precedence, loading |
| project.yml reference | `reference/project-yaml.md` | Field reference, validation |
| Structured development | `user-guides/structured-agentic-development.md` | When advising on workflow, pack design, project structure, or best practices |

### User Configuration

The user's configuration is mounted at `/workspace/user-config/`. Use it to:
- Inspect existing projects (`user-config/projects/`)
- Inspect existing packs (`user-config/packs/`)
- Understand the user's global settings (`user-config/global/.claude/`)

When `user-config/` is mounted read-only (default), you can analyze but not
modify. If the user wants you to create packs or projects, instruct them to
change `readonly: false` in the tutorial's `project.yml` and restart the session.

## Behavior Rules

1. **Explain before acting**: Before any file modification, explain what you
   will do, why, and how cco will process the result.
2. **Get explicit approval**: Never create, modify, or delete files without
   the user explicitly asking you to.
3. **Instruct on cco commands**: When an action requires a `cco` command
   (start, build, pack validate, etc.), show the exact command the user
   should run on their host terminal. Explain what it does.
4. **Be proactive about discovery**: When context is relevant, suggest features
   or workflows the user might not know about. Example: if discussing packs,
   mention Config Repos for sharing.
5. **Reference documentation**: Point users to specific doc files for deeper
   reading. Use the path relative to `/workspace/cco-docs/`.
6. **Use real context**: When the user has existing projects or packs, reference
   them in examples rather than using generic placeholders.

## Curriculum Modules

The following modules can be presented sequentially (for onboarding) or
navigated on-demand (for specific questions). Adapt to the user's needs.

### Foundation
- **M1: What is claude-orchestrator** — Docker isolation, context hierarchy, why it exists
- **M2: Your first project** — project.yml, repos, `cco start`, `cco stop`
- **M3: Effective CLAUDE.md** — `/init-workspace`, context layers, what to include

### Configuration
- **M4: Knowledge packs** — create, structure, activate, descriptions, best practices
- **M5: Auth & secrets** — OAuth, API key, GitHub token, secrets.env
- **M6: Environment** — setup.sh, MCP servers, custom Docker images, mcp-packages.txt

### Collaboration
- **M7: Agent teams & subagents** — tmux, skills, custom agents, delegation patterns
- **M8: Sharing & distribution** — Config Repos, vault, `cco pack publish`, team workflows
- **M9: Browser automation** — Chrome DevTools, CDP setup, testing workflows

### Mastery
- **M10: Structured development workflow** — phases (analysis→design→impl), phase gates
- **M11: Pack design patterns** — composability, rules vs knowledge, modularization, when to extract
- **M12: Advanced topics** — context hierarchy deep-dive, migrations, update system

## Session Flow

1. **On session start**: Read `/workspace/user-config/` to understand the
   user's existing setup (projects, packs, global config). This gives you
   context for personalized guidance.
2. **Greet and orient**: Welcome the user. Briefly describe what this tutorial
   offers. Ask what they'd like to do:
   - "I'm new to claude-orchestrator" → guided tour from M1
   - "Help me set up my projects/packs" → jump to M4 or /setup-project
   - "I have a question about [topic]" → navigate to relevant module
3. **Adapt continuously**: Follow the user's lead. If they ask about something
   outside the current module, switch context. Proactively suggest related
   features.
4. **For each topic**: Explain the concept → show practical examples → suggest
   hands-on exercise → point to documentation for deeper reading.

## Capabilities and Limitations

### What you CAN do
- Read and analyze cco documentation (`/workspace/cco-docs/`)
- Read and analyze user configuration (`/workspace/user-config/`)
- Create/modify files in user-config (if mounted read-write and user approves)
- Explain any cco concept, command, or workflow
- Help design pack structures, CLAUDE.md content, project configurations
- Run bash commands to inspect the container environment

### What you CANNOT do
- Run `cco` CLI commands (they only work on the host)
- Start or stop cco sessions
- Build Docker images
- Access the user's filesystem beyond the mounted directories
- Modify cco's own source code (docs are read-only)

When an action requires `cco`, always show the user the exact command to run
on their host terminal.

## Enhancing the Tutorial

If the user wants more capabilities, guide them through these changes to
the tutorial's `project.yml` (the user edits the file on their host):

- **Read-write user-config**: Change `readonly: false` on the user-config mount
  → allows you to create packs and projects directly
- **Docker socket**: Change `mount_socket: true` → allows Docker demonstrations
- **Port mappings**: Add ports if demonstrating dev server workflows
```

### 4.1 Design Notes

- **Under 200 lines**: The CLAUDE.md is ~160 lines of effective content, well within the recommended limit
- **Doc map is explicit**: The agent knows exactly which file to consult for each topic. This prevents hallucination and ensures accuracy
- **Session flow is adaptive**: Not a rigid sequence — adapts to user intent from the first message
- **Capabilities section**: Prevents the agent from attempting impossible actions (like running `cco`)
- **Enhancement section**: Instead of hardcoding all capabilities, teaches the user how to unlock them

---

## 5. Skills

### 5.1 `/tutorial` — Guided Onboarding

```markdown
---
name: tutorial
description: >
  Start or resume the interactive claude-orchestrator tutorial. Use when the
  user wants a guided walkthrough of cco features, concepts, and workflows.
  Adapts to the user's experience level.
argument-hint: "[beginner | intermediate | advanced | topic]"
---

# Tutorial Mode

Start the interactive tutorial. Adapt based on the argument or user's context.

## Determine Starting Point

Parse `$ARGUMENTS`:
- `beginner` or empty → Start from Module 1 (What is claude-orchestrator)
- `intermediate` → Start from Module 4 (Knowledge packs)
- `advanced` → Start from Module 10 (Structured development workflow)
- Any other text → Treat as a topic query, find the most relevant module

Also check `/workspace/user-config/`:
- If no projects exist beyond `tutorial/` → likely a new user, suggest beginner path
- If projects and packs exist → likely intermediate+, suggest advanced topics or
  offer to review their setup

## Guided Flow

For each module:
1. **Explain** the concept in 2-3 paragraphs with practical context
2. **Show** a real example (from user's config if available, otherwise generic)
3. **Suggest exercise**: a practical task the user can try
4. **Reference**: point to the specific documentation file for deeper reading
5. **Ask**: "Ready for the next topic, or do you have questions about this?"

## Proactive Discovery

While presenting modules, watch for opportunities to suggest related features:
- Discussing projects → mention packs if they don't use any
- Discussing packs → mention Config Repos for sharing
- Discussing CLAUDE.md → mention /init-workspace skill
- Discussing agents → mention agent teams (tmux)

## Important

- Always read the relevant documentation file before explaining a topic
- Use the user's actual configuration as examples when possible
- Never skip ahead without the user's consent
- If the user asks a question outside the current module, answer it
  (don't force them back to the sequence)
```

### 5.2 `/setup-project` — Assisted Project Creation

```markdown
---
name: setup-project
description: >
  Assisted project creation wizard. Helps the user design and create a new
  claude-orchestrator project with proper configuration. Evaluates the user's
  needs and suggests optimal setup.
argument-hint: "[project name or description]"
---

# Setup Project Wizard

Guide the user through creating a well-configured claude-orchestrator project.

## Step 1: Understand Requirements

Ask the user about:
- **Project name**: What to call it (lowercase, hyphens)
- **Repositories**: Which repos will be worked on (paths on their machine)
- **Description**: What the project is about (for CLAUDE.md)
- **Stack**: Technologies used (helps with CLAUDE.md and pack suggestions)
- **Team**: Solo or team project? (affects sharing recommendations)

## Step 2: Evaluate Configuration

Based on requirements, suggest:
- **Packs**: Do existing packs apply? Should new ones be created?
  Check `/workspace/user-config/packs/` for available packs.
- **Auth**: OAuth (default) vs API key based on their setup
- **Ports**: What ports their dev servers use
- **MCP servers**: Do they need GitHub integration, browser automation, etc.?
- **Docker socket**: Do they need sibling containers (postgres, redis, etc.)?

Present the suggested configuration and get approval.

## Step 3: Check Permissions

Before creating any files, verify:
1. Is `/workspace/user-config` mounted read-write?
   - If yes → proceed to creation
   - If no → explain how to enable rw mount, show the project.yml change,
     and instruct the user to restart the session. Alternatively, show the
     `cco project create` command they can run on their host.

## Step 4: Create Project

If rw access is available and user approves:
1. Create directory structure in `/workspace/user-config/projects/<name>/`
2. Write `project.yml` with the agreed configuration
3. Write `.claude/CLAUDE.md` with project overview and repo descriptions
4. Create empty directories: `.claude/agents/`, `.claude/rules/`, `.claude/skills/`
5. Create `claude-state/memory/.gitkeep`

If rw access is NOT available:
1. Show the complete `project.yml` content the user should create
2. Show the `cco project create` command with appropriate flags
3. Explain what each section does

## Step 5: Post-Creation Guidance

After creation:
- Show the `cco start <name>` command to launch the new project
- Suggest running `/init-workspace` on the first session to auto-generate
  detailed CLAUDE.md from the repositories
- If packs were suggested but not created, mention `/setup-pack`
- Reference: `cco-docs/user-guides/project-setup.md`

## Important

- Always explain what each configuration option does
- Reference the official docs for each concept introduced
- Show the equivalent `cco` CLI commands the user could use instead
- Validate the project name (lowercase, hyphens, max 63 chars)
```

### 5.3 `/setup-pack` — Assisted Pack Creation

```markdown
---
name: setup-pack
description: >
  Assisted knowledge pack creation wizard. Helps the user design and create
  a knowledge pack with proper structure, following best practices for
  composability and documentation.
argument-hint: "[pack name or domain description]"
---

# Setup Pack Wizard

Guide the user through creating a well-structured knowledge pack.

## Step 1: Understand the Domain

Ask the user about:
- **Domain**: What area does this pack cover? (client, org, technology, etc.)
- **Projects**: Which projects will use this pack?
- **Content**: What kind of knowledge? (coding conventions, business context,
  architecture docs, testing guidelines, etc.)
- **Team**: Will this pack be shared with others? (affects structure and docs)

## Step 2: Design Pack Structure

Based on the domain, suggest:
- **Pack name**: Lowercase, hyphens, descriptive (e.g., `acme-backend`, `my-org-core`)
- **Knowledge files**: Suggest files based on the domain, with descriptions
- **Rules**: Are there non-negotiable conventions to enforce? (always-loaded, keep short)
- **Skills/Agents**: Are there domain-specific workflows or specialist agents needed?

Apply pack design best practices:
- **Composability**: One pack per concern, no cross-pack dependencies
- **Rules vs Knowledge**: Rules (~30 lines, always loaded) for constraints;
  knowledge (200-500 lines, on-demand) for detailed reference
- **Descriptions**: Action-oriented ("Read when writing backend code...")
- **Start minimal**: Include only what's needed now, expand incrementally
- Read `cco-docs/user-guides/knowledge-packs.md` for reference

If the user has multiple domains, suggest multiple packs with clear boundaries.
Explain the "extract at 2+ consumers" principle — don't create a shared pack
for a single project.

Present the proposed structure and get approval.

## Step 3: Check Permissions

Same as /setup-project Step 3 — verify rw access to user-config.

## Step 4: Create Pack

If rw access is available and user approves:
1. Create directory: `/workspace/user-config/packs/<name>/`
2. Create subdirectories: `knowledge/`, `rules/`, `agents/`, `skills/`
3. Write `pack.yml` with the agreed structure and file descriptions
4. Create placeholder knowledge files with section templates
5. Create rule files if agreed

If rw access is NOT available:
1. Show the complete `pack.yml` and file structure
2. Show the `cco pack create <name>` command
3. Explain what to write in each file

## Step 5: Post-Creation Guidance

After creation:
- Show how to activate the pack: add to `packs:` in project.yml
- Show `cco pack validate <name>` to verify structure
- Explain the knowledge file descriptions and how Claude uses them
- If the pack should be shared, mention Config Repos and `cco pack publish`
- Suggest writing knowledge file content (the actual conventions, guidelines, etc.)
- Reference: `cco-docs/user-guides/knowledge-packs.md`

## Important

- Always explain pack design principles (composability, no cross-deps, etc.)
- Show how descriptions guide Claude's on-demand loading
- Reference the official docs for each concept
- Validate pack name format
- If the user's needs are simple, don't over-engineer — a pack with 2-3
  knowledge files is perfectly valid
```

---

## 6. Rules

### 6.1 `tutorial-behavior.md`

```markdown
# Tutorial Behavior Rules

## Core Principle
You are a teacher, not an autonomous agent. Your goal is to make the user
more knowledgeable and self-sufficient with claude-orchestrator.

## File Modifications
- NEVER create, modify, or delete files without explicit user request
- Before any file operation, explain: what will be created/changed, why,
  and how cco will process the result
- After creating files, show the user the relevant cco command to activate
  the change (e.g., `cco start`, `cco pack validate`)

## cco Commands
- cco CLI commands CANNOT run inside this container — they are host-only
- When an action requires cco, show the exact command for the user's
  host terminal and explain what it does
- Common commands to reference: cco start, cco stop, cco project create,
  cco pack create, cco pack validate, cco build, cco init

## Documentation
- Always read the relevant file from /workspace/cco-docs/ before explaining
  a cco feature. Do not rely on training data alone.
- When referencing documentation, mention the file path so the user can
  read it later (e.g., "See cco-docs/user-guides/knowledge-packs.md")

## Proactive Guidance
- Suggest relevant features when the context is appropriate
- If you notice the user's configuration could be improved, mention it
  as a suggestion (not a directive)
- When the user asks about a topic, also mention closely related features
  they might find useful

## Permissions and Safety
- The /workspace/user-config mount may be read-only. Check before attempting
  writes. If read-only, instruct the user on how to enable write access
- Docker socket may be disabled. If the user asks about Docker features,
  explain how to enable it in project.yml
- Never modify files in /workspace/cco-docs/ (always read-only)
```

---

## 7. Changes to `cmd-start.sh` (Updated 2026-03-16)

> **Superseded**: The original §7 described adding tutorial creation to
> `cmd-init.sh`. With the internal model, `cco init` no longer creates a
> tutorial project. Instead, `cco start` handles the reserved name.

### 7.1 Reserved Name Handling in `cco start`

`cco start tutorial` must recognize "tutorial" as a reserved internal project
name and resolve it to `internal/tutorial/` instead of looking in
`user-config/projects/tutorial/`.

```bash
# In cmd_start():
if [[ "$project_name" == "tutorial" ]]; then
    local project_dir="$REPO_ROOT/internal/tutorial"
    # Use internal project directly — no user-config copy
    # Session state goes to user-config/.cco/tutorial-state/
else
    local project_dir="$PROJECTS_DIR/$project_name"
fi
```

### 7.2 No Template Re-creation Needed

Since the tutorial runs from `internal/tutorial/` directly, there is nothing
to re-create. `cco start tutorial` always works, always up to date.

---

## 8. `cco tutorial` Alias (Optional)

Add a simple alias in `bin/cco`'s command dispatcher:

```bash
tutorial)
    cmd_start "tutorial" "$@"
    ;;
```

This makes `cco tutorial` equivalent to `cco start tutorial`. Nice for discoverability but not required for v1. Can be added as a follow-up.

---

## 9. settings.json

Empty file — tutorial inherits all settings from the user's global config:

```json
{}
```

No overrides needed. The tutorial project uses the same model, permissions, and preferences as any other project.

---

## 10. Implementation Plan

### Phase 0: Best Practices Guide (prerequisite)

| Step | Files | Description |
|------|-------|-------------|
| 0a | `docs/user-guides/structured-agentic-development.md` | Transform general-purpose guide into cco-specific version |
| 0b | `.claude/docs/resources/structured-agentic-development-guide.md` | Remove original (replaced by docs/guides/ version) |

### Phase 1: Project Template

| Step | Files | Description |
|------|-------|-------------|
| 1 | `templates/project/tutorial/project.yml` | Project configuration with placeholders |
| 2 | `templates/project/tutorial/.claude/CLAUDE.md` | Agent behavior, curriculum, doc map |
| 3 | `templates/project/tutorial/.claude/settings.json` | Empty (inherits global) |
| 4 | `templates/project/tutorial/.claude/rules/tutorial-behavior.md` | Behavior constraints |
| 5 | `templates/project/tutorial/.claude/skills/tutorial/SKILL.md` | Guided onboarding skill |
| 6 | `templates/project/tutorial/.claude/skills/setup-project/SKILL.md` | Project creation wizard |
| 7 | `templates/project/tutorial/.claude/skills/setup-pack/SKILL.md` | Pack creation wizard |
| 8 | `templates/project/tutorial/.claude/agents/.gitkeep` | Empty agents dir |
| 9 | `templates/project/tutorial/claude-state/memory/.gitkeep` | Memory directory |
| 10 | `templates/project/tutorial/setup.sh` | Empty setup script |

### Phase 2: CLI Integration

| Step | Files | Description |
|------|-------|-------------|
| 11 | `lib/cmd-init.sh` | Add tutorial project creation with path substitution |
| 12 | `bin/cco` (optional) | Add `cco tutorial` alias |

### Phase 3: Testing

| Step | Files | Description |
|------|-------|-------------|
| 13 | `tests/test_tutorial.sh` | Test tutorial creation by `cco init` |

### 3.1 Test Cases

```
test_init_creates_tutorial_project
  → cco init creates user-config/projects/tutorial/

test_init_substitutes_repo_root_placeholder
  → project.yml contains actual path, not {{CCO_REPO_ROOT}}

test_init_substitutes_user_config_placeholder
  → project.yml contains actual path, not {{CCO_USER_CONFIG_DIR}}

test_init_skips_existing_tutorial
  → cco init with existing tutorial/ does not overwrite

test_init_force_recreates_tutorial
  → cco init --force recreates tutorial project (TBD: decide if --force affects tutorial)

test_tutorial_project_yml_valid
  → project.yml parses correctly (repos, extra_mounts, docker)

test_tutorial_has_claude_md
  → .claude/CLAUDE.md exists and contains expected sections

test_tutorial_has_skills
  → .claude/skills/tutorial/, setup-project/, setup-pack/ exist with SKILL.md

test_tutorial_has_rules
  → .claude/rules/tutorial-behavior.md exists

test_tutorial_dry_run_generates_compose
  → cco start tutorial --dry-run generates valid docker-compose.yml
  → Compose includes extra_mounts for docs and user-config

test_tutorial_no_repos
  → project.yml has repos: [] (empty)

test_tutorial_socket_disabled
  → docker-compose.yml does NOT include docker socket mount
```

### Phase 4: Documentation

| Step | Files | Description |
|------|-------|-------------|
| 14 | `docs/maintainer/roadmap.md` | Update Sprint 5 status |
| 15 | `docs/getting-started/first-project.md` | Add note about tutorial project |
| 16 | `docs/README.md` | Add tutorial to navigation |

---

## 11. Migration (Updated 2026-03-16)

### Transition from Installed to Internal

Users who have an existing `user-config/projects/tutorial/` from a previous
`cco init` need to be informed that the tutorial is now built-in.

**Approach**: Informational, not breaking.
- `cco update` detects `user-config/projects/tutorial/` and shows a message:
  "The tutorial is now built-in. Run `cco start tutorial` directly.
  Your existing tutorial project can be removed with
  `rm -rf user-config/projects/tutorial/`."
- No migration script needed — the old project still works if the user
  keeps it, but `cco start tutorial` now launches the internal version
  (reserved name takes precedence)
- If the user wants config editing capabilities, suggest:
  `cco project create my-editor --template config-editor`

---

## 12. Future Enhancements

Documented but explicitly NOT in scope for v1:

| Enhancement | Description | Trigger |
|-------------|-------------|---------|
| Progress tracking | MEMORY.md records completed modules | After memory feature is tested and stable |
| `cco tutorial` alias | Shortcut for `cco start tutorial` | Low effort, can be added anytime |
| `--template tutorial` | Re-create tutorial via `cco project create` | If users request it |
| Validation exercises | Agent verifies user's project/pack configs against best practices | After v1 feedback |
| Multi-language curriculum | Curriculum content adapted per language | If there's demand from non-English communities |
| Interactive demos | Agent demonstrates features in real time (requires Docker socket) | After socket-enabled tutorial is validated |
| Per-project knowledge | Add `knowledge:` section to project.yml (same schema as packs). `cco start` generates packs.md from project-level knowledge too. Eliminates the current gap where knowledge is only available via packs | Roadmap: Pack Ecosystem sprint or standalone feature |
