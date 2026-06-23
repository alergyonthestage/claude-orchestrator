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
  Check `/workspace/cco-config/packs/` (`~/.cco/packs/`) for available packs.
- **Auth**: OAuth (default) vs API key based on their setup
- **Ports**: What ports their dev servers use
- **MCP servers**: Do they need GitHub integration, browser automation, etc.?
- **LLMs.txt**: Does the project use frameworks with llms.txt support? If so,
  suggest `cco llms install <url>` and adding `llms:` to project.yml or to a pack.
  This gives agents access to official, up-to-date framework documentation.
- **Docker socket**: Do they need sibling containers (postgres, redis, etc.)?

Present the suggested configuration and get approval.

## Step 3: Scaffold the Project (on the host)

The tutorial is read-only, so it cannot create the project here. A project's
committed `.cco/` is scaffolded **in its repo on the host** with `cco init`.

Guide the user to run, on the host, inside the target repo:
1. `cco init` — scaffolds `<repo>/.cco/{project.yml, claude/, secrets.env.example,
   .gitignore}` and registers the project in the machine-local index.
   - `cco join <project>` to add this repo to an existing project.
   - `cco init --migrate <old>` to bring a legacy-vault project into the repo.
2. Edit `<repo>/.cco/project.yml` with the agreed repos (logical names +
   coordinates), packs, and docker config.
3. Edit `<repo>/.cco/claude/CLAUDE.md` with project context.

For hands-on assistance editing config, suggest `cco start config-editor`.

## Step 4: Post-Scaffold Guidance

After scaffolding:
- Show the `cco start <name>` command to launch the new project.
- Suggest running `/init` on the first session to auto-generate a detailed
  CLAUDE.md from the repositories.
- If packs were suggested but not created, mention `/setup-pack`.
- Reference: `cco-docs/user-guides/project-setup.md`.

## Important

- Always explain what each configuration option does
- Reference the official docs for each concept introduced
- Show the equivalent `cco` CLI commands the user could use instead
- Validate the project name (lowercase, hyphens, max 63 chars)
