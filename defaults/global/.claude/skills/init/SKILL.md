---
name: init
description: >
  Initialize or refresh this project's CLAUDE.md with accurate context about
  the repositories, architecture, and knowledge packs.
  Run on the first session and after significant workspace changes.
argument-hint: "[repos | packs | all (default: all)]"
---

# Init: Project Context Initialization

Initialize or refresh the project's CLAUDE.md with accurate, up-to-date context.
Also updates `/workspace/.claude/project.yml` and `/workspace/.claude/workspace.yml`
with repository and knowledge file descriptions.

## Scope

Parse `$ARGUMENTS` (default: `all`):
- `repos` — explore repositories and update their sections only
- `packs` — describe knowledge files only
- `all` — do everything

## Step 1: Read workspace.yml

Read `/workspace/.claude/workspace.yml` to understand the project structure:
repos (names, paths), packs (referenced pack names).

If `workspace.yml` is missing or empty, check `/workspace/.claude/project.yml`
for the project name and repos list as fallback.

## Step 2: Explore repositories (scope: repos or all)

For each repo listed in `workspace.yml`:

1. Read `README.md` (or `README`) — get the project description
2. Read the main manifest: `package.json`, `go.mod`, `pyproject.toml`,
   `Cargo.toml`, `pom.xml`, or `build.gradle` — identify language/framework/version
3. List top-level directories to understand the structure
4. Read any repo-level `.claude/CLAUDE.md` if present
5. Identify entry points: `src/main.*`, `cmd/`, `app/`, `server.*`, `index.*`

Synthesize a 2-3 sentence description covering:
- What the service/app does
- Tech stack (language, framework, key dependencies)
- Key commands (dev, test, build, lint)

## Step 3: Describe knowledge pack files (scope: packs or all)

For each entry in the packs section of `workspace.yml`, read the referenced
pack file (available at `/workspace/.packs/<pack-name>/<file>`) and write a
1-sentence description of what it contains and when to consult it.

## Step 4: Read current CLAUDE.md

Read `/workspace/.claude/CLAUDE.md` if it exists. Identify:
- Sections that were manually written (preserve them)
- Placeholder sections or auto-generated content (replace them)
- Whether the file is empty or missing (proceed without confirmation)

If CLAUDE.md has substantial manual content, briefly summarize what you found
and confirm with the user before overwriting.

## Step 5: Write CLAUDE.md

Write `/workspace/.claude/CLAUDE.md` with the following structure:

```
# Project: <project-name>

## Overview
<2-3 paragraphs: what this project does, key business context, overall architecture>

## Workspace Layout
| Repo | Path | Purpose |
|------|------|---------|
| <name> | /workspace/<name>/ | <one-line description> |

## Repositories

### <repo-name>
- **Path**: /workspace/<repo-name>/
- **Stack**: <framework, language, key libraries>
- **Key commands**: `<dev>` / `<test>` / `<build>` / `<lint>`
- **Architecture**: <entry points, key patterns, how it's structured>

<repeat for each repo>

## Architecture
<How the repos relate to each other: data flow, API boundaries, shared contracts>

## Infrastructure
- Docker network: cc-<project-name>
- <Any sibling services, databases, caches visible in docker-compose files>

## Knowledge Packs
<For each knowledge file: name → what it contains → when to read it>
```

Preserve any existing sections not listed above (e.g., custom workflow notes,
secrets management instructions, team conventions added manually).

## Step 6: Update project.yml and workspace.yml

After writing CLAUDE.md:

1. For each repo with a non-empty description, update the corresponding entry
   in `/workspace/.claude/project.yml`:
   ```yaml
   repos:
     - path: ~/path/to/repo
       name: repo-name
       description: "The description you wrote"
   ```
   If the `description:` field is missing from a repo entry, add it.

2. Update `/workspace/.claude/workspace.yml` with the same descriptions
   (matching the `description:` field under each repo entry).

Use precise awk/sed edits to update only the `description:` fields — do not
reformat or restructure the rest of the YAML files.

## Notes

- Do not modify any files outside `/workspace/.claude/` and the repos themselves
- If a repo path does not exist on disk, note it but continue with others
- Keep CLAUDE.md under ~200 lines — use concise, factual language
- This skill shadows the built-in `/init` command intentionally
