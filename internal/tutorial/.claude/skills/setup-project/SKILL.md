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
- **LLMs.txt**: Does the project use frameworks with llms.txt support? If so,
  suggest `cco llms install <url>` and adding `llms:` to project.yml or to a pack.
  This gives agents access to official, up-to-date framework documentation.
- **Docker socket**: Do they need sibling containers (postgres, redis, etc.)?

Present the suggested configuration and get approval.

## Step 3: Check Permissions

Before creating any files, verify:
1. Is `/workspace/user-config` mounted read-write?
   - If yes → proceed to creation
   - If no → suggest the user create a config-editor project on the host:
     `cco project create --template config-editor && cco start config-editor`.
     Alternatively, show the `cco project create` command with all flags
     they can run on their host to create the project manually.

## Step 4: Create Project

If rw access is available and user approves:
1. Create directory structure in `/workspace/user-config/projects/<name>/`
2. Write `project.yml` with the agreed configuration
3. Write `.claude/CLAUDE.md` with project overview and repo descriptions
4. Create empty directories: `.claude/agents/`, `.claude/rules/`, `.claude/skills/`
5. Create `.cco/claude-state/` directory
6. Create `memory/.gitkeep`

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
