---
name: init-workspace
description: >
  Initialize or refresh this project's CLAUDE.md with accurate context about
  the repositories, architecture, and knowledge packs.
  Run on the first session and after significant workspace changes.
argument-hint: "[repos | packs | all (default: all)]"
---

# Init Workspace: Project Context Initialization

Initialize or refresh the project's CLAUDE.md with accurate, up-to-date context.
Also updates `/workspace/.claude/workspace.yml` with repository and knowledge file
descriptions. Descriptions persist on the host via the rw `.claude/` mount.

## Scope

Parse `$ARGUMENTS` (default: `all`):
- `repos` — explore repositories and update their sections only
- `packs` — describe knowledge files only
- `all` — do everything

## Step 1: Read workspace.yml

Read `/workspace/.claude/workspace.yml` to understand the project structure:
repos (names and container paths at `/workspace/<name>`), packs (referenced pack names),
and extra_mounts (shared libraries mounted at their `target` paths).

If `workspace.yml` is missing or empty, check `/workspace/project.yml`
for the project name and repos list as fallback.

## Step 2: Explore repositories and shared libraries (scope: repos or all)

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

For each path in `extra_mounts` (if any): list the top-level directory and
read any README or package manifest to identify purpose and key exports.
Add them to the "Shared Libraries" section of CLAUDE.md.

## Step 3: Describe knowledge pack files (scope: packs or all)

For each entry in the packs section of `workspace.yml`, read the referenced
pack file (available at `/workspace/.claude/packs/<pack-name>/<file>`) and write a
1-sentence description of what it contains and when to consult it.

## Step 4: Read current CLAUDE.md

Read `/workspace/.claude/CLAUDE.md` if it exists. Identify:
- Sections that were manually written (preserve them)
- Placeholder sections or auto-generated content (replace them)
- Whether the file is empty or missing (proceed without confirmation)

If CLAUDE.md has substantial manual content, briefly summarize what you found
and confirm with the user before overwriting.

## Step 4b: Empty Workspace — User-Guided Initialization

If the workspace is empty (no repos in workspace.yml, no extra mounts, AND
CLAUDE.md is empty/missing/placeholder-only), guide the user:

1. Ask: "This workspace has no repositories yet. How much detail can you
   provide about the project?"

   - **(A) Just an idea** — ask for a 2-3 sentence description (what it does,
     who it's for). Generate a minimal CLAUDE.md with Overview populated.
     Suggest: "Consider running /analyze or starting a conversation to
     explore requirements before defining architecture."

   - **(B) Some decisions made** — ask follow-up questions:
     - What tech stack? (languages, frameworks, key dependencies)
     - What are the main components or services?
     - Any infrastructure needs? (databases, caches, queues)
     - Any integrations? (APIs, external services)
     Generate CLAUDE.md with Overview, Architecture, and Infrastructure
     populated from the answers.

   - **(C) Detailed specs available** — ask the user to share specs or
     design documents. Parse the information and populate all relevant
     sections. Suggest: "Run /design to formalize the architecture."

2. In all cases:
   - Keep generated content concise and factual
   - Mark sections needing further work with `<!-- TODO: define after analysis/design -->`
   - Save descriptions to workspace.yml for persistence

If the workspace has repos or existing content, skip this step entirely
and proceed with automatic discovery (the existing flow).

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

## Shared Libraries
<Only include if workspace.yml has extra_mounts entries>
| Path | Purpose |
|------|---------|
| <target> | <one-line description> |

## Knowledge Packs
<For each knowledge file: name → what it contains → when to read it>
```

Preserve any existing sections not listed above (e.g., custom workflow notes,
secrets management instructions, team conventions added manually).

## Step 6: Update workspace.yml

After writing CLAUDE.md, update `/workspace/.claude/workspace.yml` with the
descriptions you wrote for each repo and knowledge file.

`workspace.yml` is the authoritative store for descriptions. It persists on
the host via the rw `.claude/` mount — descriptions survive container restarts
and will be preserved the next time `cco start` regenerates the file.

Use precise awk/sed edits to update only the `description:` fields — do not
reformat or restructure the file.

`extra_mounts` entries in workspace.yml do not have description fields — they
are target paths only. No changes needed to that section.

Do **not** modify `/workspace/project.yml` — it is the host-managed
config file and is not the right place for auto-generated descriptions.

## Notes

- Do not modify any files outside `/workspace/.claude/` and the repos themselves
- If a repo path does not exist on disk, note it but continue with others
- Keep CLAUDE.md under ~200 lines — use concise, factual language
- Use `/init-workspace` to distinguish from the built-in `/init` command
- When generating the CLAUDE.md, do NOT include memory-related content.
  Memory policy is enforced by the managed rule `memory-policy.md`.
  If you discover important patterns or conventions during exploration,
  write them to `.claude/rules/` or the CLAUDE.md — not to memory.
