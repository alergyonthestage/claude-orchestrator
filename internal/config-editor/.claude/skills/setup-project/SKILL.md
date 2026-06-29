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
In the decentralized model a project's config lives **in its own repo** at
`<repo>/.cco/`, scaffolded on the host with `cco init`.

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
  suggest `cco llms install <url>` and adding an `llms:` coordinate to
  `project.yml` or to a pack. This gives agents official, up-to-date docs.
- **Docker socket**: Do they need sibling containers (postgres, redis, etc.)?

Present the suggested configuration and get approval.

## Step 3: Scaffold the Project

A project's committed `.cco/` is created **in its repo on the host** — this
session cannot create it directly unless it was started in project mode
(`cco start config-editor --project <name>`, which mounts that repo's `.cco/`).

Guide the user to run, on the host, inside the target repo:
1. `cco init` — scaffolds `<repo>/.cco/{project.yml, claude/, secrets.env.example,
   .gitignore}` and registers the project in the machine-local index.
   - `cco join <project>` instead, to add this repo to an existing project.
   - `cco init --migrate <old>` to bring a legacy project into the repo.
2. Edit `<repo>/.cco/project.yml` with the agreed repos (logical names +
   coordinates), packs, and docker config.
3. Edit `<repo>/.cco/claude/CLAUDE.md` with project context.

If this session is in **project mode**, you can edit that project's mounted
`.cco/` (at `/workspace/<name>-config`) directly after `cco init` has scaffolded it.

## Step 4: Post-Creation Guidance

After creation:
- Show the `cco start <name>` command to launch the new project.
- Suggest running `/init` (the init-workspace skill) on the first session to
  auto-generate a detailed CLAUDE.md from the repositories.
- If packs were suggested but not created, mention `/setup-pack`.
- Reference: `cco-docs/users/configuration/guides/project-setup.md`.
- Remind the user to run `cco config save` on host if they changed `~/.cco`
  (e.g. created/edited packs or templates).

## Important

- Always explain what each configuration option does.
- Reference the official docs for each concept introduced.
- Show the equivalent `cco` CLI commands the user runs on the host.
- Validate the project name (lowercase, hyphens, max 63 chars).
