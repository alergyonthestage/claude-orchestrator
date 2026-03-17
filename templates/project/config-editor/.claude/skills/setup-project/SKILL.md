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

## Step 3: Create Project

After user approves:
1. Create directory structure in `/workspace/user-config/projects/<name>/`
2. Write `project.yml` with the agreed configuration
3. Write `.claude/CLAUDE.md` with project overview and repo descriptions
4. Create `.claude/settings.json` with `{}`
5. Create supporting dirs: `.cco/claude-state/`, `memory/.gitkeep`

## Step 4: Post-Creation Guidance

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
- Remind the user to run `cco vault sync` after creation if vault is active
