# Knowledge Packs

> Practical guide to creating, configuring, and managing knowledge packs.

---

## What are Knowledge Packs

Knowledge packs are reusable packages that group documentation, conventions, skills, agents, and rules. They can be shared across multiple projects without duplicating files. A pack can contain, for example, a client's coding conventions, team guidelines, or documentation for a specific domain.

Packs live in `global/packs/` and are activated per project via `project.yml`.

---

## Create a pack

### Quick command

```bash
cco pack create my-client-knowledge
```

This creates the complete directory structure in `global/packs/my-client-knowledge/` with a template `pack.yml`.

### Directory structure

```
global/packs/my-client-knowledge/
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
  source: ~/documents/my-client-docs   # directory on host (mounted read-only)
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

The `source` field specifies a directory on the host that contains documentation files. It is mounted read-only in the container at `/workspace/.packs/<pack-name>/`.

```yaml
knowledge:
  source: ~/documents/my-client-docs
```

If `source` is omitted, the pack uses its own internal `knowledge/` directory:

```yaml
# Without source: files go in global/packs/<name>/knowledge/
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

In addition to knowledge, a pack can include skills, agents, and rules that are copied to the project configuration.

### Skills

Skills are directories containing a `SKILL.md` file. They are copied to `/workspace/.claude/skills/` and are available as slash commands (e.g., `/deploy`).

```yaml
skills:
  - deploy          # Reference to global/packs/<name>/skills/deploy/SKILL.md
```

### Agents

Agents are Markdown files that define specialized subagents. They are copied to `/workspace/.claude/agents/`.

```yaml
agents:
  - devops-specialist.md   # Reference to global/packs/<name>/agents/devops-specialist.md
```

### Rules

Rules are Markdown files with additional instructions. They are copied to `/workspace/.claude/rules/`.

```yaml
rules:
  - api-conventions.md     # Reference to global/packs/<name>/rules/api-conventions.md
```

---

## Activate a pack in a project

To activate a pack, add its name to the `packs:` list in the project's `project.yml` file:

```yaml
# projects/my-saas/project.yml
name: my-saas

repos:
  - path: ~/projects/backend-api
    name: backend-api

packs:
  - my-client-knowledge
  - team-conventions
```

Packs are processed at each `cco start`: resources are copied and knowledge is mounted automatically.

### Precedence in case of conflicts

If two packs define the same agent, rule, or skill, the last pack in the `packs:` list wins. A warning is printed to the terminal to signal the conflict.

---

## Pack management

### List available packs

```bash
cco pack list
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
- The `knowledge.source` directory is mounted read-only to `/workspace/.packs/<name>/`
- The `.claude/packs.md` file is generated with the list of files and their descriptions
- Skills, agents, and rules are copied to the project's `.claude/` directory
- A `.pack-manifest` file tracks copied files for cleanup on the next startup

**2. When the Claude session starts:**
- The `session-context.sh` hook (SessionStart) injects the contents of `packs.md` into `additionalContext`
- Claude automatically receives the list of available knowledge files with descriptions
- Files are read on-demand by Claude when relevant to the current task

Example of generated `packs.md`:

```
The following knowledge files provide project-specific conventions and context.
Read the relevant files BEFORE starting any implementation, review, or design task.

- /workspace/.packs/my-client/backend-coding-conventions.md — Read when writing backend code
- /workspace/.packs/my-client/business-overview.md — Read for business context
- /workspace/.packs/my-client/testing-guidelines.md
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
