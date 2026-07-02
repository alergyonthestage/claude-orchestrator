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
The rich project narrative lives in CLAUDE.md (authored here). Structured resource
descriptions have a single home — `project.yml` — and are optional; you can only
write them when the session has `cco_access ≥ edit-project` (see the final section).

## Scope

Parse `$ARGUMENTS` (default: `all`):
- `repos` — explore repositories and update their sections only
- `packs` — describe knowledge files only
- `all` — do everything

## Step 1: Read the session context

Your session already carries an injected **cco session-context block**
(`<CcoSessionInfo>`, added at startup) describing the project structure: repos
(container paths at `/workspace/<name>`, with optional descriptions), packs,
knowledge files (indexed pack knowledge with paths + descriptions), llms
(official framework docs), extra mounts, and — when `show_host_paths` is on — a
host↔container path map. Use it as your inventory.

Read `/workspace/project.yml` for the authoritative, structured resource list
(repos, packs, llms, extra_mounts) and any existing `description:` fields. You can
also query more on demand with the wrapped `cco` CLI (`cco list`, `cco project
show`) when the session's access scope allows it.

## Step 2: Explore repositories and shared libraries (scope: repos or all)

For each repo listed in the session context / `project.yml`:

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

For each knowledge file listed in the session context (e.g.
`/workspace/.claude/packs/<pack-name>/<file>`), read it and write a 1-sentence
description of what it contains and when to consult it.

## Step 4: Read current CLAUDE.md

Read `/workspace/.claude/CLAUDE.md` if it exists. Identify:
- Sections that were manually written (preserve them)
- Placeholder sections or auto-generated content (replace them)
- Whether the file is empty or missing (proceed without confirmation)

If CLAUDE.md has substantial manual content, briefly summarize what you found
and confirm with the user before overwriting.

## Step 4b: Empty Workspace — User-Guided Initialization

If the workspace is empty (no repos in the session context / project.yml, no
extra mounts, AND CLAUDE.md is empty/missing/placeholder-only), guide the user:

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
   - The narrative lives in CLAUDE.md; structured descriptions go into
     `project.yml` only if this session has `cco_access ≥ edit-project`

If the workspace has repos or existing content, skip this step entirely
and proceed with automatic discovery (the existing flow).

## Step 5: Write CLAUDE.md

Write `/workspace/.claude/CLAUDE.md` with the following structure.

**Scope rule**: `/workspace/.claude/CLAUDE.md` is the project-level file — it
describes the cross-repo/cross-mount coordination, overall architecture, and
infrastructure. Even for single-repo projects, this is the primary file.
Repo-specific details (stack, commands, internal architecture) belong in each
repo's own `/workspace/<repo>/.claude/CLAUDE.md`. Do not duplicate repo-specific
content in the project CLAUDE.md.

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
<Only include if the project has extra_mounts entries>
| Path | Purpose |
|------|---------|
| <target> | <one-line description> |

## Knowledge Packs
<For each knowledge file: name → what it contains → when to read it>
```

Preserve any existing sections not listed above (e.g., custom workflow notes,
secrets management instructions, team conventions added manually).

## Step 6: (Optional) Persist structured descriptions to project.yml

There is no `workspace.yml` write-back anymore — the session context is injected
fresh at each start and never edited from inside the container (ADR-0042). The one
structured home for resource descriptions is `project.yml` (`repos[].description`,
`extra_mounts[].description`), which is machine-agnostic, committed, and shared.

Only write them **if this session has `cco_access ≥ edit-project`** (e.g. a
`cco start config-editor --project <name>` session, which mounts both the project
config and its repos). In a normal session `project.yml` is mounted read-only —
do not attempt to edit it; the rich context lives in CLAUDE.md and that is enough.

When you may write: add or update only the `description:` field of the relevant
`repos[]` / `extra_mounts[]` entry in `/workspace/project.yml` (or `<repo>/.cco/
project.yml`) with precise edits — do not reformat or restructure the file. These
descriptions then render into the injected session context on the next start.

## Notes

- Do not modify files outside `/workspace/.claude/` and the repos themselves —
  except the optional `project.yml` description write-back of Step 6, and only
  when `cco_access ≥ edit-project` (otherwise project.yml is mounted read-only)
- If a repo path does not exist on disk, note it but continue with others
- Keep CLAUDE.md under ~200 lines — use concise, factual language
- Use `/init-workspace` to distinguish from the built-in `/init` command
- When generating the CLAUDE.md, do NOT include memory-related content.
  Memory policy is enforced by the managed rule `memory-policy.md`.
  If you discover important patterns or conventions during exploration,
  write them to `.claude/rules/` or the CLAUDE.md — not to memory.
