# Knowledge Packs

> Practical guide to creating, configuring, and managing knowledge packs.

---

## What are Knowledge Packs

Knowledge packs are reusable packages that group documentation, conventions, skills, agents, and rules. They can be shared across multiple projects without duplicating files. A pack can contain, for example, a client's coding conventions, team guidelines, or documentation for a specific domain.

Packs live in your personal store at `~/.cco/packs/` (or, for a project-local authored pack with no `url` coordinate, in `<repo>/.cco/packs/`) and are activated per project via `project.yml`.

---

## Create a pack

### Quick command

```bash
cco pack create my-client-knowledge
```

This creates the complete directory structure in `~/.cco/packs/my-client-knowledge/` with a template `pack.yml`.

### Directory structure

```
~/.cco/packs/my-client-knowledge/
  pack.yml              # Pack definition (required)
  knowledge/            # Documentation files (optional)
    overview.md
    coding-conventions.md
  skills/               # Skill directories (optional)
    deploy/
      SKILL.md
  agents/               # Agent definitions (optional)
    specialist.md
  rules/                # Rule files (optional)
    api-conventions.md
```

### pack.yml format

The `pack.yml` file declares the contents of the pack. All sections are optional: a pack can contain only knowledge, only skills, or any combination.

```yaml
name: my-client-knowledge

# ── Knowledge files ─────────────────────────────────────────────────
knowledge:
  source: ~/documents/my-client-docs   # directory on host (mounted read-only at startup)
  files:
    - path: backend-coding-conventions.md
      description: "Read when writing backend code, APIs, or DB logic"
    - path: business-overview.md
      description: "Read for business context and product understanding"
    - testing-guidelines.md              # short form: without description

# ── Skills (directory names under skills/) ───────────────────────────
skills:
  - deploy

# ── Agents (file names under agents/) ───────────────────────────────
agents:
  - specialist.md

# ── Rules (file names under rules/) ─────────────────────────────────
rules:
  - api-conventions.md
```

---

## The knowledge section

The `knowledge` section is the heart of the pack: it allows you to inject documentation into Claude's context without modifying any `CLAUDE.md`.

### source

The `source` field specifies a directory on the host that contains documentation files. At `cco start`, the directory is mounted read-only into the container at `/workspace/.claude/packs/<pack-name>/`.

```yaml
knowledge:
  source: ~/documents/my-client-docs
```

If `source` is omitted, the pack uses its own internal `knowledge/` directory:

```yaml
# Without source: files go in ~/.cco/packs/<name>/knowledge/
knowledge:
  files:
    - path: overview.md
      description: "Project overview and architecture"
```

### files

The `files` list declares which files to make visible to Claude and with what instructions.

Each file can have two formats:

```yaml
files:
  # Extended format: with description (recommended)
  - path: backend-conventions.md
    description: "Read when writing backend code or API endpoints"

  # Short format: just the file name
  - testing-guidelines.md
```

The description is important: it is included in Claude's context to help him decide **when** to read that file. A good description indicates the use context ("Read when...", "Reference for...", "Check before...").

---

## Optional resources

In addition to knowledge, a pack can include skills, agents, and rules that are mounted read-only into the project configuration.

### Skills

Skills are directories containing a `SKILL.md` file. They are mounted read-only to `/workspace/.claude/skills/` and are available as slash commands (e.g., `/deploy`).

```yaml
skills:
  - deploy          # Reference to ~/.cco/packs/<name>/skills/deploy/SKILL.md
```

### Agents

Agents are Markdown files that define specialized subagents. They are mounted read-only to `/workspace/.claude/agents/`.

```yaml
agents:
  - devops-specialist.md   # Reference to ~/.cco/packs/<name>/agents/devops-specialist.md
```

### Rules

Rules are Markdown files with additional instructions. They are mounted read-only to `/workspace/.claude/rules/`.

```yaml
rules:
  - api-conventions.md     # Reference to ~/.cco/packs/<name>/rules/api-conventions.md
```

---

## Activate a pack in a project

To activate a pack, add its name to the `packs:` list in the project's `project.yml` file:

```yaml
# projects/my-saas/project.yml
name: my-saas

repos:
  - name: backend-api

packs:
  - my-client-knowledge
  - team-conventions
```

Packs are processed at each `cco start`: all resources (knowledge files, skills, agents, rules) are mounted automatically via read-only Docker volumes.

### Precedence in case of conflicts

If two packs define the same agent, rule, or skill, the last pack in the `packs:` list wins. A warning is printed to the terminal to signal the conflict.

---

## Pack management

### List available packs

```bash
cco list packs
```

Output:
```
NAME              KNOWLEDGE  SKILLS  AGENTS  RULES
my-client             3         1       1       1
team-conventions      2         0       0       2
```

### View pack details

```bash
cco pack show my-client-knowledge
```

Shows the complete contents of the pack: knowledge files with descriptions, skills, agents, rules, and projects that use it.

### Validate a pack

```bash
# Validate a specific pack
cco pack validate my-client-knowledge

# Validate all packs
cco pack validate
```

Verifies the pack structure: presence of `pack.yml`, existence of declared files, correct format.

### Remove a pack

```bash
# With confirmation (if used by active projects)
cco pack remove my-client-knowledge

# Force removal
cco pack remove my-client-knowledge --force
```

If the pack is used by one or more projects, confirmation is requested before removal.

---

## How injection works

Knowledge pack injection is completely automatic and requires no changes to `CLAUDE.md` files.

The process happens in two phases:

**1. At `cco start` time:**
- Knowledge directories are mounted read-only at `/workspace/.claude/packs/<name>/`
- Pack skills, agents, and rules are mounted read-only into `/workspace/.claude/` (per-file for rules/agents, per-directory for skills)
- The `.claude/packs.md` file is generated with the list of files and their descriptions

**2. When the Claude session starts:**
- The `session-context.sh` hook (SessionStart) injects the contents of `packs.md` into `additionalContext`
- Claude automatically receives the list of available knowledge files with descriptions
- Files are read on-demand by Claude when relevant to the current task

Example of generated `packs.md`:

```
The following knowledge files provide project-specific conventions and context.
Read the relevant files BEFORE starting any implementation, review, or design task.

- /workspace/.claude/packs/my-client/backend-coding-conventions.md — Read when writing backend code
- /workspace/.claude/packs/my-client/business-overview.md — Read for business context
- /workspace/.claude/packs/my-client/testing-guidelines.md
```

---

## Best practices

### Naming

- Use lowercase names with hyphens: `my-client-docs`, `team-backend-conventions`
- Choose descriptive names that indicate the domain: `frontend-design-system`, `devops-runbooks`

### File descriptions

- Write action-oriented descriptions: "Read when writing...", "Check before deploying...", "Reference for..."
- Avoid generic descriptions like "Documentation" or "Guidelines"
- The description helps Claude decide when to read the file, so be specific

### Knowledge file organization

- Keep files focused on a single topic
- Prefer multiple small files to one large file (reduces context consumption)
- If a file exceeds 500 lines, consider splitting it
- Use descriptive file names: `backend-coding-conventions.md` instead of `conventions.md`

### Separation of concerns

- Use the `knowledge` section for documentation and context (read-only, not processed)
- Use `skills` for user-invocable actions (e.g., deploy, review)
- Use `rules` for always-active behavioral instructions
- Use `agents` for specialized subagents with defined roles

---

## Sharing packs

Packs are shared across machines and teams via a **sharing repo** — a dedicated git
remote whose structure (`packs/`, `templates/`) is discovered directly. There is no
manifest file; the repo is enumerated to find available packs.

```bash
# Publish a pack to a sharing repo (creates/updates it on the remote)
cco pack publish <name> [remote]

# Install a pack from a sharing repo
cco pack install <git-url>

# Update an installed pack from its remote source
cco pack update <name>
```

A pack referenced by `url` coordinate is a **cache** of its upstream (re-fetchable,
updated via `cco pack update`); a pack with no `url` is authored project-local in
`<repo>/.cco/packs/`. To back up your whole personal store (`~/.cco/`, including
packs), use `cco config push`.

For the complete sharing workflow (multi-machine sync, team distribution, project templates), see the [Configuration Management guide](../../configuration/guides/configuration-management.md).

---

## Related: Framework Documentation (llms.txt)

While knowledge packs bundle user-written conventions and guidelines, official framework documentation can be installed separately via `cco llms install`. The downloaded LLMs.txt **content** is cached per machine under `~/.cache/cco/llms/`, while the **coordinate** (`url` + variant) that references it is embedded per-unit in the `project.yml`/`pack.yml` that uses it.

See [project-yaml.md § LLMs.txt](../../configuration/reference/project-yaml.md#llmstxt--framework-documentation) and `cco llms --help`.
