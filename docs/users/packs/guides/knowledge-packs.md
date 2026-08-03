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

# ── Framework docs (optional; same schema as project.yml `llms:`) ────
llms:
  - name: svelte
    url: https://svelte.dev/llms.txt   # required — the re-fetch coordinate
```

A pack's `llms:` entries are merged with the project's at `cco start`; where both
name the same entry, the **project's** `description`/`variant` overrides win.

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
# <repo>/.cco/project.yml  (in the project's host repo)
name: my-saas

repos:
  - name: backend-api

packs:
  - my-client-knowledge
  - team-conventions
```

Entries also take a coordinate map (`- name:` plus `url`/`ref`) when the pack comes
from a sharing repo — see
[project-yaml.md § Field Reference](../../configuration/reference/project-yaml.md#field-reference)
for the full `packs[]` schema.

Packs are processed at each `cco start`: all resources (knowledge files, skills, agents, rules) are mounted automatically via read-only Docker volumes.

### Precedence in case of conflicts

If two packs define the same agent, rule, or skill, the last pack in the `packs:` list wins. A warning is printed to the terminal to signal the conflict.

A pack resource also **shadows a project file of the same name** — see
[Configuring Rules § Configuration Scope](../../configuration/guides/configuring-rules.md#configuration-scope)
for why, and what to do instead.

---

## Pack management

### List available packs

```bash
cco list packs
```

Output:
```
NAME              KNOWLEDGE  SKILLS  AGENTS  RULES  TAGS
my-client             3         1       1       1   work
team-conventions      2         0       0       2
```

> Inside a session the listing is **scoped to your access level**: at the default
> `read-project` you see only the packs the current project references, with a
> count-only notice on stderr for the rest. Hidden is not absent — widen with
> `--cco-access read-global` on the host to see the whole store.

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
- The `knowledge` section of the session context is built with the list of files and their descriptions, and base64-encoded into the `CCO_SESSION_CONTEXT` env var (no `workspace.yml` file — ADR-0042)

**2. When the Claude session starts:**
- The `session-context.sh` hook (SessionStart) decodes `CCO_SESSION_CONTEXT`, renders an instructional preamble, and injects the `knowledge` section into `additionalContext`
- Claude automatically receives the list of available knowledge files with descriptions
- Files are read on-demand by Claude when relevant to the current task

Example rendered `knowledge` section:

```
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

# Move a pack between machines without git
cco pack export <name>            # -> <name>.tar.gz
cco pack import ./<name>.tar.gz

# Rename a pack (re-keys its stores and every project's packs[] reference)
cco pack rename <old> <new>
```

**Where these run.** `cco pack publish` and `cco pack export` are **host-only** — a
session refuses them (exit 2) and tells you to run them on your host. The rest
(`create`, `install`, `import`, `update`, `rename`, `remove`, `internalize`) write your
personal store, so in-session they need an `edit-global`/`edit-all` session; `show` and
`validate` are readable at any level.

A pack referenced by `url` coordinate is a **cache** of its upstream (re-fetchable,
updated via `cco pack update`); a pack with no `url` is authored project-local in
`<repo>/.cco/packs/`. To back up your whole personal store (`~/.cco/`, including
packs), use `cco config push`.

For the complete sharing workflow (multi-machine sync, team distribution, project templates), see the [Configuration Management guide](../../configuration/guides/configuration-management.md).

---

## Related: Framework Documentation (llms.txt)

While knowledge packs bundle user-written conventions and guidelines, official framework documentation can be installed separately via `cco llms install`. The downloaded LLMs.txt **content** is cached per machine under `~/.cache/cco/llms/`, while the **coordinate** (`url` + variant) that references it is embedded per-unit in the `project.yml`/`pack.yml` that uses it.

See [project-yaml.md § LLMs.txt](../../configuration/reference/project-yaml.md#llmstxt--framework-documentation) and `cco llms --help`.
