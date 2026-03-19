# Configuring Rules, Skills & Workflow

> How to set up and organize rules, skills, agents, and workflow configuration
> to get the most out of claude-orchestrator. Covers categories, grouping strategy,
> scope decisions, and concrete examples.
>
> Related: [structured-agentic-development.md](structured-agentic-development.md) |
> [context-hierarchy.md](../reference/context-hierarchy.md) |
> [project-setup.md](project-setup.md)

---

## Overview

claude-orchestrator ships with a set of default rules and skills as a tested starting
point. This guide helps you understand the categories of configuration available,
decide what to customize, and organize your rules effectively.

**Key principle**: cco provides the mechanisms — you decide the content. Every rule,
skill, and agent can be modified, replaced, or removed. The defaults reflect practices
that have proven effective in real-world agentic development, but your workflow is yours
to define.

---

## Rules vs. Skills vs. Agents vs. Knowledge

Claude Code provides four extension mechanisms. Understanding when to use each is
key to effective configuration. **cco builds on Claude Code's native features — it
does not replace or modify them.** All Claude Code concepts (skills, agents, rules,
MCP, hooks) work exactly the same inside cco. What cco adds is the project layer,
knowledge packs, and multi-repo context management on top.

For the full reference, see the
[Claude Code documentation](https://code.claude.com/docs/en/features-overview.md)
and the [Complete Guide to Building Skills for Claude](https://resources.anthropic.com/hubfs/The-Complete-Guide-to-Building-Skill-for-Claude.pdf).

| Mechanism | Purpose | Context loading | When to use |
|-----------|---------|-----------------|-------------|
| **Rules** | Short behavioral directives | Always loaded into context | Enforce conventions the agent must follow in every session |
| **Knowledge / Docs** | Detailed reference material | Loaded on-demand when the agent reads them | Architecture guides, API specs, design docs, business context |
| **Skills** | Task-specific workflows invocable by the user | Loaded when invoked via `/command` | Phase entry points, repeatable procedures, structured checklists |
| **Agents** | Specialized subagent personas | Loaded when the agent spawns them | Delegated tasks (analysis, review) with focused expertise |

### The key distinction: rules vs. knowledge

**Rules are always in context** — they consume context window on every turn. Keep them
**short, focused, and enforcement-oriented**. A rule should be a directive the agent
follows, not a detailed explanation.

**Knowledge and documentation are loaded on-demand** — the agent reads them when
relevant. Put detailed guidelines, comprehensive examples, architecture descriptions,
and reference material here. This keeps the always-loaded context lean.

**Rule of thumb**: If the instruction is "always do X" in 2-3 lines → **rule**.
If the instruction is "here's how X works and why, with examples" → **knowledge doc**.

### Understanding skills in depth

Skills are one of Claude's most powerful and widely-used extension mechanisms. They go
far beyond workflow phases — they teach Claude new capabilities and encode repeatable
processes. cco builds on Claude Code's native skill system without replacing it.

For the full reference, see Anthropic's
[Complete Guide to Building Skills for Claude](https://resources.anthropic.com/hubfs/The-Complete-Guide-to-Building-Skill-for-Claude.pdf).

**Two categories of skills** (conceptual):

| Category | Purpose | Longevity | Example |
|----------|---------|-----------|---------|
| **Capability upskill** | Teaches Claude a new ability it doesn't have natively | May become obsolete as models improve | Frontend design guidelines, PDF form filling, document generation |
| **Encoded preference** | Captures a repeatable workflow or process sequence | Stays relevant (your workflow, your process) | Sprint planning, code review checklist, analysis methodology |

Capability upskills fill knowledge gaps — they give Claude expertise it lacks (e.g.,
your specific design system, a framework's best practices). As models improve, some
capability upskills may become unnecessary. Encoded preferences capture *your* workflow
and stay relevant regardless of model capability.

**Three use case categories** (from Anthropic):

1. **Document & Asset Creation** — Creating consistent, high-quality output (documents,
   designs, code, presentations). Example: `frontend-design` skill for production-grade
   UI. Key: embedded style guides, templates, quality checklists.

2. **Workflow Automation** — Multi-step processes with consistent methodology. Example:
   `skill-creator` skill that walks through use case definition, frontmatter generation,
   and validation. Key: step-by-step with validation gates, iterative refinement loops.

3. **MCP Enhancement** — Workflow guidance on top of MCP tool access. Example: Sentry's
   `sentry-code-review` skill that coordinates error monitoring with PR analysis.
   Key: MCP provides the tools (kitchen), skills provide the recipes.

**Progressive disclosure** — Skills use a three-level loading system:
- **Level 1 (YAML frontmatter)**: Always in Claude's context. Just enough for Claude
  to know *when* to use the skill. Keep this minimal.
- **Level 2 (SKILL.md body)**: Loaded when Claude thinks the skill is relevant.
  Contains the full instructions.
- **Level 3 (Linked files)**: Additional files in `references/`, `scripts/`, `assets/`
  that Claude reads only as needed.

This aligns perfectly with the rules vs. knowledge principle: frontmatter is like a
rule (always loaded, brief), while the skill body and references are like knowledge
(loaded on demand, detailed).

### When to create a skill vs. a rule

- A **rule** governs behavior that applies continuously (e.g., "use conventional commits").
  Rules are always loaded into context — keep them short.
- A **skill** teaches a specific ability or captures a repeatable process. Skills are
  loaded on-demand when triggered by user request or context relevance.

**Rule of thumb**: If Claude should *always* follow it → **rule**. If Claude should
*do it when asked* or *when a specific task comes up* → **skill**.

cco's default skills (`/analyze`, `/design`, `/review`, `/commit`) correspond to workflow
phases, but skills are not limited to this. You can create skills for any repeatable
task: generating specific document types, running analysis methodologies, creating
frontend components with your design system, automating multi-step processes, etc.

### When to create an agent vs. a skill

- A **skill** runs in the lead agent's context — same conversation, same tools
- An **agent** runs as a separate subagent with its own context, tools, and optionally
  a different model (e.g., haiku for fast analysis, sonnet for review)

Use agents when you want parallel work, focused expertise, or cost-effective delegation.
Use skills when the task benefits from the current conversation context.

**Skills + MCP**: If you use MCP servers (e.g., for Notion, Linear, Slack, databases),
skills are the natural complement. The MCP gives Claude *access* to the tool; a skill
teaches Claude *how to use it effectively* for your specific workflows.

### Packs as single source of truth

When a set of rules, skills, agents, or knowledge documents applies to **multiple
projects**, define them in a **pack** rather than duplicating across projects.

Packs ensure a single source of truth: update the pack once, and all projects using it
receive the update. This prevents copy/paste drift and manual sync between projects.

**Use packs for**: stack-specific conventions (React patterns, Go idioms), client/domain
knowledge, shared coding guidelines, reusable agent personas, cross-project skills.

**Don't use packs for**: project-specific configuration that only applies to one project.

---

## Configuration Scope

Rules and skills can live at different levels. Choose the right scope for each:

| Scope | Location | When to use |
|-------|----------|-------------|
| **Global** | `global/.claude/rules/`, `global/.claude/skills/` | Conventions that apply to ALL your projects (language, commit style, general workflow) |
| **Project** | `projects/<name>/.claude/rules/`, `projects/<name>/.claude/skills/` | Project-specific conventions (architecture patterns, testing strategy, deployment rules) |
| **Pack** | `packs/<name>/rules/`, `packs/<name>/skills/` | Reusable conventions shared across projects (e.g., a "React" pack with frontend rules) |
| **Repo** | `<repo>/.claude/rules/` | Repo-specific rules committed to the repository itself (shared with all repo contributors) |

**Resolution order**: Managed (framework) → Global → Project → Pack → Repo. When rules
conflict, lower-scoped rules take precedence for their scope.

**Rule of thumb**: Start global. Move to project-level only when a rule genuinely differs
between projects. Use packs when a set of rules applies to multiple projects sharing
the same stack or domain.

---

## Categories of Rules

Through extensive testing, six categories of rules have emerged as the building blocks
of an effective agentic development configuration. Not all categories need to be
configured as rules — some are better suited as documentation or project-level decisions.

### 1. Workflow Phases

**What it covers**: The development cycle — phases, transitions, exit conditions,
and what the agent should/shouldn't do during each phase.

**Why it matters**: Without workflow rules, agents tend to jump between analysis,
implementation, and documentation freely, producing inconsistent results and making
it hard to review their work.

**What to define**:
- Which phases exist in your workflow (e.g., analysis → design → implementation → testing → docs)
- Behavioral constraints per phase (e.g., "no code changes during analysis")
- Exit conditions: when a phase is considered complete
- Input/output per phase: what documents or artifacts each phase consumes and produces
- Human approval gates: which transitions require explicit human approval

**Recommended scope**: Global (the workflow is usually consistent across projects).

**cco default**: `workflow.md` — defines 4 phases (analysis, design, implementation,
documentation) with basic behavioral constraints.

### 2. Documentation Structure

**What it covers**: Where documentation lives, how it's organized, formatting
conventions, and diagram usage.

**Why it matters**: Without explicit structure rules, agents create documentation in
inconsistent locations, leading to duplicated or contradictory files. A clear structure
ensures every document has an unambiguous home.

**What to define**:
- Directory structure (e.g., `/docs/user-guides/`, `/docs/maintainer/`, `/docs/reference/`)
- File naming conventions (e.g., `analysis.md`, `design.md`, `adr-NNN.md`)
- Organization principle (e.g., by domain/module, not by document type)
- Diagram conventions (e.g., Mermaid in written files, plain text in terminal output)
- Changelog and versioning conventions
- Where external documentation lives (e.g., MCP-connected systems like Docmost)

**Recommended scope**: Global for general conventions, project-level for project-specific
directory structure.

**cco default**: `diagrams.md` — covers Mermaid usage. Consider expanding into a broader
`documentation.md` rule.

### 3. Git Practices

**What it covers**: Branch strategy, commit conventions, merge flow, and PR practices.

**Why it matters**: Agents commit frequently and need clear conventions to produce
a navigable git history. Without rules, commit messages vary wildly and branch naming
is inconsistent.

**What to define**:
- Branch strategy (e.g., git-flow, trunk-based, feature branches)
- Branch naming convention (e.g., `<type>/<scope>/<description>`)
- Commit message format (e.g., conventional commits)
- Commit frequency (e.g., after each logical unit, always in a working state)
- Merge flow and direction (which branches merge into which)
- What merges correspond to (human review points, PRs)
- What commits correspond to (automated by LLM within approved work)
- Per-branch policies (what kind of work is allowed on each branch)

**Recommended scope**: Global (git conventions rarely differ between projects).

**cco default**: `git-practices.md` — covers branch naming, conventional commits, and
commit frequency.

**Important: define the branching model early**. Before the agent starts working on a
project, establish clear per-branch policies. Without them, the agent may commit directly
to `main` or mix feature work with hotfixes. A well-defined branching model tells the
agent exactly where to work and what each branch is for.

Example of per-branch policies in your git rule:
```markdown
## Branch Policies
- `main` — production-ready code. Only hotfixes and merge commits from `develop`.
  No direct feature work.
- `develop` — integration branch. Only merge commits from feature branches.
  No direct commits except minor fixes.
- `feat/<scope>/<description>` — feature development. All new work happens here.
  Branch from `develop`, merge back to `develop` via PR.
- `fix/<scope>/<description>` — bug fixes. Branch from `develop` for normal fixes,
  from `main` for hotfixes. Merge back to the source branch.
```

Every user's workflow is different — trunk-based, git-flow, or a custom model — but
the key is to **define it explicitly** so the agent knows the rules. The cco default
provides a starting point; customize it to match your team's actual flow.

### 4. Language

**What it covers**: Which language to use for code, documentation, and communication.

**Why it matters**: In multilingual teams or when the developer communicates in a
language different from the codebase, agents need explicit guidance to avoid mixing
languages.

**What to define**:
- Communication language (chat/terminal responses)
- Documentation language (README, guides, changelogs)
- Code language (comments, docstrings, identifiers)

**Recommended scope**: Global (usually consistent across all projects).

**cco default**: `language.md` — template with placeholders for each language setting.

### 5. Maintenance & Evolution Policy

**What it covers**: Backward compatibility, breaking changes, legacy code management,
and documentation lifecycle.

**Why it matters**: Without explicit policy, agents default to conservative backward
compatibility — maintaining deprecated code, adding compatibility shims, archiving
old docs — even when the project is an early MVP where breaking changes are preferred.
This wastes significant effort.

**What to define**:
- Project phase (MVP/greenfield vs. production with users)
- Breaking changes policy (allowed freely, require approval, never)
- Legacy code strategy (eliminate aggressively vs. maintain backward compat)
- Documentation archival (delete superseded docs vs. archive them)
- Refactoring triggers (when to suggest refactoring reviews)
- Periodic review cadence (every N development cycles, review architecture and docs structure)

**Recommended scope**: **Project-level** (this differs fundamentally between projects).

**cco default**: None. This category is too project-dependent for a universal default.
Define it explicitly for each project.

### 6. Human in the Loop vs. Autonomous Decisions

**What it covers**: What requires human approval and what the agent can decide
autonomously.

**Why it matters**: Too much autonomy leads to architectural drift and unwanted changes.
Too little autonomy makes the agent slow and needy. The right balance depends on your
trust level and the risk profile of the task.

**What to define**:
- What requires human approval (e.g., phase transitions, architectural decisions,
  breaking changes, security-sensitive changes)
- What can be decided autonomously (e.g., implementation details within approved design,
  bug fixes, documentation updates, test writing)
- Process for autonomous decisions (e.g., always analyze alternatives first)
- Process for requesting approval (e.g., present analysis, context, and recommended solution)

**Recommended scope**: Global for general autonomy rules. The workflow rule already covers
phase-transition autonomy — additional autonomy rules should be placed in the same file
to avoid contradictions (see [Grouping Principle](#grouping-principle) below).

**cco default**: Partial — the workflow rule includes human approval gates at phase
transitions.

---

## Grouping Principle

How you organize rules into files matters. The guiding principle:

> **One rule file per decision domain. Correlated rules in the same file.**
> If two rules can potentially conflict, they must be in the same file where
> the contradiction is visible and resolvable.

### Why this matters

When rules are spread across many small files, contradictions between files go
unnoticed. For example:
- `workflow.md` says "proceed to the next phase after exit conditions are met"
- `autonomy.md` (separate file) says "always ask for human approval before proceeding"

These two rules conflict, but because they're in different files, neither the human
nor the agent will easily spot the contradiction. If both rules are in the same file,
the conflict is immediately visible and can be resolved.

### Recommended grouping

Based on correlation analysis between categories:

| File | Unified Content | Why unified |
|------|----------------|-------------|
| `workflow.md` | Phases + transitions + human-in-the-loop rules + exit conditions | Workflow and autonomy both define "when to proceed" — high contradiction risk if separated |
| `documentation.md` | Docs structure + format + diagrams + versioning | Docs structure and diagram conventions both define "how to write documentation" — subset relationship |
| `git-practices.md` | Branch strategy + commits + merge flow + PR conventions | Self-contained domain |
| `language.md` | Languages for code, docs, communication | Self-contained domain |

**Maintenance policy** is not included in this grouping because it belongs at the
project level, not in a global rule.

### When to split files

Split a rule file when:
- It exceeds ~60-80 lines (readability drops)
- It covers genuinely independent domains (no contradiction risk)
- Different parts need different scopes (global vs. project)

Do **not** split when:
- The rules in the file can potentially conflict with each other — keep them visible together
- The file is large but cohesive (a long workflow definition is better as one file than
  two half-definitions)

---

## Per-Project Configuration

Beyond universal rules, each project benefits from project-specific configuration:

### Architecture & Project Structure

Define in the project's `.claude/CLAUDE.md` or `.claude/rules/`:
- Directory tree and file positioning conventions
- Technology stack and key dependencies
- Architectural patterns in use (e.g., hexagonal architecture, event sourcing)
- Key abstractions and their locations

### Coding Guidelines

Define per stack/language, often in a **pack** for reusability:
- Framework-specific conventions (e.g., React component patterns, Go error handling)
- Testing strategy (unit, integration, e2e — what tools, what coverage target)
- API design conventions
- Error handling patterns

### Testing & Validation Strategy

**Always give the agent a way to test and validate its own code.** Without a validation
mechanism, the agent produces code it cannot verify, and errors accumulate silently
until human review.

Valid strategies (can be combined):
- **Automated tests** — unit, integration, e2e test suites the agent can run
- **Bash scripts** — quick validation scripts for CLI tools or build outputs
- **Browser integration** — Chrome DevTools MCP to verify UI behavior
- **Type checking / linting** — static analysis as a first validation pass

Define in the project rules which validation methods are available and when to use them.

---

## Configuring Skills

### Default skills

cco ships with workflow-phase skills as defaults: `/analyze`, `/design`, `/review`,
`/commit`. These are just the starting point — skills can do much more.

### Customizing existing skills

Each skill is a folder with a `SKILL.md` file in `global/.claude/skills/` or
`projects/<name>/.claude/skills/`. To customize:

1. Open the skill file (e.g., `global/.claude/skills/analyze/SKILL.md`)
2. Modify the instructions, checklist, or output format
3. The changes apply to all future sessions

### Creating new skills

Skills are not limited to workflow phases. Create skills for any repeatable task:

**Workflow phase skills** (entry points for development phases):
```
skills/implement/SKILL.md    # Implementation with design checklist
skills/test/SKILL.md         # Testing with coverage targets
skills/document/SKILL.md     # Documentation update checklist
```

**Capability skills** (teach Claude new abilities):
```
skills/frontend-design/SKILL.md     # Your design system guidelines
skills/api-design/SKILL.md          # Your API conventions
skills/migration-generator/SKILL.md # Database migration patterns
```

**Process skills** (encode repeatable workflows):
```
skills/sprint-planning/SKILL.md  # Sprint setup with your methodology
skills/incident-report/SKILL.md  # Post-mortem document generation
skills/release-notes/SKILL.md    # Changelog from git history
```

**MCP-enhanced skills** (workflows on top of tool access):
```
skills/deploy-review/SKILL.md   # Check monitoring after deploy (via MCP)
skills/issue-triage/SKILL.md    # Triage with Linear/GitHub (via MCP)
```

### Skill structure best practices

Following Anthropic's official guidance:

- **SKILL.md** (required): Instructions in Markdown with YAML frontmatter
- **scripts/** (optional): Executable code (Python, Bash, etc.)
- **references/** (optional): Detailed documentation loaded as needed
- **assets/** (optional): Templates, fonts, icons used in output

**Frontmatter is critical** — it determines when Claude loads the skill:
```yaml
---
name: your-skill-name
description: What it does. Use when user asks to [specific trigger phrases].
---
```

The description must include both *what the skill does* and *when to use it*.
Include specific trigger phrases users might say.

**Keep SKILL.md focused** — move detailed reference material to `references/`.
This leverages progressive disclosure: Claude reads the full skill body only when
triggered, and reads reference files only when needed.

### Skill scope

- **Global skills** apply to all projects — use for universal capabilities
- **Project skills** apply to one project — use for project-specific workflows
- **Pack skills** apply to all projects using that pack — use for stack-specific skills

### Skill lifecycle

Skills are living documents. As models improve, some capability upskills may become
unnecessary (the model already knows what the skill teaches). Periodically evaluate:
- Does the skill still improve results compared to baseline?
- Has a model update made the skill redundant?
- Does the skill need updating for new patterns or tools?

Use the `skill-creator` (available as a Claude Code plugin) to help create, review,
and improve skills.

---

## Getting Started

### Before you start: key decisions

Before writing any configuration, take a few minutes to answer these questions. The
answers directly shape your rules and project setup — getting them right upfront prevents
rework and misaligned agent behavior.

**Essential** (without these, the agent starts with wrong assumptions):

| # | Decision | Where it goes | Questions to answer |
|---|----------|---------------|---------------------|
| 1 | **Language** | `rules/language.md` | What language for chat? For documentation? For code comments? |
| 2 | **Git branching model** | `rules/git-practices.md` | Which branches exist? What work is allowed on each? What's the merge flow? (See [Git Practices](#3-git-practices) for examples) |
| 3 | **Autonomy level** | `rules/workflow.md` | What requires human approval? What can the agent decide alone? Where are the gates? |

**Recommended** (defaults cover the base case, but customizing improves results):

| # | Decision | Where it goes | Questions to answer |
|---|----------|---------------|---------------------|
| 4 | **Maintenance policy** | Project CLAUDE.md or project rule | Is this an MVP or production? Are breaking changes allowed? How to handle legacy code? |
| 5 | **Testing strategy** | Project CLAUDE.md | Which test tools are available? When should the agent run tests? What coverage is expected? |
| 6 | **Workflow phases** | `rules/workflow.md` | Are the default 4 phases (analysis → design → implementation → docs) right for you, or do you need a different flow? |

**Why this matters**: The agent's first session sets the tone for the entire project.
If the branching model isn't defined, the agent commits to `main`. If autonomy rules
are vague, the agent either asks about everything or makes decisions you didn't want.
If the maintenance policy is missing, the agent wastes effort on backward compatibility
for an early MVP. Five minutes of upfront decisions prevent hours of correction later.

**Practical approach**: You don't need to write perfect rules on day one. Start with
the essentials (1-3), use the defaults for everything else, and refine based on
experience. The [periodic review](#periodic-review) practice catches what needs updating.

### If you're new to cco

The defaults work out of the box. Start with them and customize as you learn what works
for your projects:

1. Run `cco start tutorial` — the tutorial guides you through initial configuration
2. Set your **language** preferences (edit `global/.claude/rules/language.md`)
3. Use the default workflow for a few sessions — note what works and what doesn't
4. Gradually customize rules based on your experience

### If you're migrating an existing workflow

1. Identify which categories above you already have opinions about
2. Create or modify rule files following the [grouping principle](#grouping-principle)
3. Start with global rules, then specialize per-project as needed
4. Review the [Development Workflow Guide](development-workflow.md) for operational
   best practices

### Periodic review

Every few development cycles, review your configuration:

- **Rules**: Still relevant? Any contradictions between files? Prune aggressively.
- **Documentation structure**: Does the docs layout still fit? Merge files covering
  the same topics. Verify docs match the current implementation.
- **Skills**: Do they still match your workflow? Add or remove as phases evolve.
- **CLAUDE.md files**: Accurate reflection of current project state?

This maintenance prevents rule drift and documentation entropy over time.
