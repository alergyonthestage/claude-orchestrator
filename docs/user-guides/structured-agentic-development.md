# Structured Agentic Development with claude-orchestrator

> How claude-orchestrator turns proven agentic development principles into
> a ready-to-use framework — so you can focus on building, not on configuring.

---

## Introduction

"Vibe coding" — using AI to rapidly generate code from natural language — is a powerful
catalyst for exploration and prototyping. But it does not scale. The moment a project
needs to be maintained, extended, or worked on by more than one person (human or agent),
an unstructured approach collapses under its own weight: context is lost between sessions,
regressions slip in unnoticed, and the codebase diverges from any coherent design.

The core thesis of structured agentic development is simple: **the same practices that
make human teams effective — clear communication, version control discipline, documented
decisions, defined workflows, and quality gates — make human-agent teams effective too.**
The difference is that agents require these practices to be *more explicit*, because they
cannot infer organizational context the way a human colleague can.

**claude-orchestrator (cco) exists to make these practices the default.** Rather than
asking every developer to manually configure context hierarchies, write rules files,
set up Docker isolation, and coordinate agent teams from scratch, cco provides an
opinionated framework where structured development is the path of least resistance.

This guide explains *why* each practice matters and *how* cco implements it. If you are
new to cco, this is the conceptual foundation. If you are experienced, it serves as a
reference for the design decisions behind the tool.

### Who This Guide Is For

Developers working on structured, long-lived projects with Claude Code — whether personal
with growth ambitions or professional/enterprise. It assumes familiarity with git, basic
software architecture concepts, and at least some experience with AI coding agents.

### How This Guide Is Organized

Three pillars, mirroring the concerns every agentic project must address:

1. **Team Discipline** — Git workflow, review practices, and architectural decisions
2. **Context Engineering** — How cco structures what the agent knows and when
3. **Workflow Orchestration** — The development cycle, quality gates, and session management

Each section states the principle, explains the reasoning, and shows how cco implements it.

---

## Pillar 1 — Team Discipline

### 1.1 Git as the Source of Truth

**Principle**: Every meaningful artifact — code, documentation, analysis, design specs,
roadmap, rules — lives in the repository under version control.

The repository is the only persistent state that survives across sessions, tool changes,
and team member turnover (human or agent). If it is not in the repo, it effectively does
not exist for the next session.

**How cco implements this:**

- **Repos are the workspace.** `cco start` mounts your repositories at `/workspace/<repo>/`.
  The workspace *is* your repos — nothing exists outside them except ephemeral container state.
- **Docs, rules, and context are versioned files.** Project configuration lives in
  `project.yml` and `.claude/` directories, all tracked in git. Analysis and design
  documents go in `docs/` within your repo. The agent's context comes from the repo,
  not from chat history.
- **Auto memory is project-scoped.** Each project's `claude-state/` directory is mounted
  to `~/.claude/projects/-workspace/`, isolating session transcripts and memory per project.
  Memory persists across sessions within the project but never leaks between projects.

### 1.2 Commit Discipline

**Principle**: Commits should be atomic, conventional, and frequent. Each commit represents
one logical unit of change that leaves the codebase in a working state.

Well-written commit history is not just collaboration hygiene — it is context for the agent.
A navigable record of what changed, why, and when helps the agent understand the evolution
of any module.

**How cco implements this:**

- **Conventional commits rule** (`defaults/global/.claude/rules/git-practices.md`) is
  loaded in every session, instructing the agent to use `feat:`, `fix:`, `docs:`,
  `refactor:`, `test:`, `chore:` prefixes with scope when it adds clarity.
- **Branch strategy rule** enforces `<type>/<scope>/<description>` naming and prevents
  direct commits to main/master.
- **Workflow phases** (see Pillar 3) create natural commit boundaries — each completed
  sub-task within a phase is a commit point.

### 1.3 Branch Strategy

**Principle**: Never commit directly to the main branch. Every implementation starts on
a feature branch and is integrated through review.

**How cco implements this:**

- The **git-practices rule** defines the branching convention and is loaded in every session.
- The **workflow rule** enforces that implementation happens on feature branches created
  at the start of the implementation phase.
- The **`/review` skill** provides a structured code review checklist before merge.

### 1.4 Architecture Decision Records

**Principle**: Significant architectural or design decisions should be captured in ADRs,
versioned in the repository.

ADRs are among the highest-value artifacts for agent-assisted development. When an agent
needs to work on a module, it needs to understand not just *what* the architecture is but
*why* it is that way and *what alternatives were considered*.

**How cco implements this:**

- cco's own architecture uses ADRs extensively (`docs/maintainer/architecture/architecture.md`),
  providing a working example.
- The **`/design` skill** produces design documents that capture context, decisions,
  alternatives, and consequences — the same structure as ADRs.
- The **`/analyze` skill** identifies constraints and risks that inform architectural
  decisions, producing the input that ADRs formalize.

### 1.5 Review as a Two-Layer Process

**Principle**: Agent review for mechanical quality, human review for intent alignment
and domain correctness.

**How cco implements this:**

- The **`reviewer` agent** (available globally as a teammate) examines diffs for code
  quality, convention adherence, potential bugs, test coverage gaps, and documentation
  completeness. It runs as a specialized subagent that does not modify code.
- The **`/review` skill** provides a structured checklist the lead agent follows.
- The **workflow phases** enforce human approval gates between analysis, design,
  implementation, and documentation — the human is always the final quality gate.

---

## Pillar 2 — Context Engineering

Context is the single most important factor in agent performance. A powerful model with
poor context produces poor results. A well-contextualized agent with clear, focused
information produces work that is consistently useful.

### 2.1 The Minimum Necessary Context Principle

**Principle**: Provide the agent with the minimum context necessary to perform the current
task well — but ensure that minimum is complete.

The "lost in the middle" problem is well-documented: models pay more attention to the
beginning and end of their context, and lose track of information in the center.
Long, bloated contexts make this worse.

**How cco implements this:**

- **Stratified context loading.** Not everything is loaded upfront. The four-tier hierarchy
  (see 2.2) ensures invariant rules are always present while task-specific knowledge is
  loaded on demand.
- **Knowledge packs** curate domain-specific context into focused packages. A pack provides
  exactly the knowledge needed for its domain — no more, no less. The agent reads pack
  documents when relevant, not at session start.
- **Short, focused sessions.** cco's project isolation encourages one project per session.
  The workflow phases encourage one phase per session. Fresh context beats accumulated noise.

### 2.2 Context Stratification — The Four-Tier Hierarchy

**Principle**: Not all context has the same lifespan or relevance. Organize it into layers
with different loading strategies.

This is the central architectural decision of claude-orchestrator. The four tiers map
directly onto Claude Code's native settings resolution:

| Tier | Container Path | What It Contains | Loading |
|------|---------------|-------------------|---------|
| **Managed** | `/etc/claude-code/` | Framework hooks, env vars, deny rules, base instructions | Always loaded, not overridable |
| **Global** | `~/.claude/` | User rules, agents, skills, settings, preferences | Always loaded, user-owned |
| **Project** | `/workspace/.claude/` | Project CLAUDE.md, project-specific rules and skills | Always loaded per project |
| **Nested** | `/workspace/<repo>/.claude/` | Repo-specific context from the repo's own `.claude/` | On-demand, from repo |

**Why this matters:**

- **Managed tier** ensures framework invariants (hooks, security constraints) cannot be
  overridden. This is the "guardrails" layer.
- **Global tier** captures user preferences that apply to all projects — communication
  language, coding conventions, workflow rules. Set once, applied everywhere.
- **Project tier** carries project-specific context — architecture, current state,
  key commands, infrastructure details. Different for each project.
- **Nested tier** allows repos to carry their own agent context without conflicting
  with the project-level configuration.

This stratification solves the core problem of context engineering: providing the right
information at the right time without overwhelming the agent.

### 2.3 Rules as the Primary Enforcement Mechanism

**Principle**: Rules are the most reliable way to enforce consistent agent behavior.
They should be explicit, versioned, and periodically reviewed.

**How cco implements this:**

- **Rules directory** (`defaults/global/.claude/rules/`) ships with focused rule files:
  `workflow.md` (phase constraints), `git-practices.md` (commit/branch conventions),
  `diagrams.md` (Mermaid in docs, plain text in terminal), `language.md` (communication
  and documentation language preferences).
- **Scoped rules**: Global rules apply everywhere. Project-level rules in
  `projects/<name>/.claude/rules/` override or extend for specific projects.
- **Rules are short and focused.** Each rule file addresses one concern in ~20-40 lines.
  This avoids rule fatigue (the tendency for rules to accumulate into an unmanageable mass).
- **Rules are versioned.** Tracked in git, updated via `cco update`, with migrations
  when structure changes.

### 2.4 Knowledge Packs — Curated Domain Context

**Principle**: Documentation is context infrastructure that the agent depends on to
work correctly.

**How cco implements this:**

- **Knowledge packs** (`user-config/packs/`) are curated bundles of documentation,
  rules, and configuration for specific domains — a web development pack, a homeserver
  pack, an AI development pack, etc.
- **Packs are composable.** A project can use multiple packs via `packs:` in `project.yml`.
  Each pack's knowledge is merged into the project context.
- **Packs are shareable.** The Config Repo system (`cco pack publish`, `cco pack install`)
  allows sharing packs across machines, teams, and organizations.
- **Knowledge is catalogued at start, loaded on demand.** At session start, `cco start`
  generates a `packs.md` index listing available pack documents with descriptions. The
  agent reads individual pack files when relevant, keeping the active context lean.

### 2.5 Separation of Knowledge and Instructions

**Principle**: Clearly distinguish between background knowledge (what the system is) and
operational instructions (what the agent should do now).

**How cco implements this:**

- **CLAUDE.md files** contain project knowledge: overview, architecture, key commands,
  infrastructure. They describe *what is*.
- **Rules files** contain behavioral instructions: workflow phases, coding conventions,
  commit practices. They prescribe *what to do*.
- **Skills** provide operational instructions for specific tasks: `/analyze` enters
  analysis mode, `/design` enters design mode, `/review` runs a structured review.
  They define *how to act now*.
- The three-way separation (CLAUDE.md for knowledge, rules for invariant behavior,
  skills for task-specific action) keeps each concern clean and maintainable.

---

## Pillar 3 — Workflow Orchestration

### 3.1 The Phased Development Cycle

**Principle**: Every development cycle follows a defined sequence of phases with explicit
transitions. Phase transitions require human approval.

```
Analysis → [Human Review] → Design → [Human Review] → Implementation → [Human Review] → Documentation → Closure
```

**How cco implements this:**

- The **workflow rule** (`defaults/global/.claude/rules/workflow.md`) defines phase-specific
  behavioral constraints:
  - Analysis: read and understand, DO NOT modify files
  - Design: propose interfaces and models, DO NOT write implementation code
  - Implementation: follow the approved design, commit after each logical unit
  - Documentation: update docs, DO NOT add new features
- **Skills as phase entry points**: `/analyze` provides structured analysis templates,
  `/design` provides design templates, `/review` provides review checklists.
- **Human gates are explicit.** The CLAUDE.md framework instruction states: "Phase
  transitions are MANUAL — never skip ahead or auto-advance without explicit user approval."

### 3.2 Docker Isolation — The Session Sandbox

**Principle**: Each session should be independent and isolated to prevent cross-contamination.

**How cco implements this:**

- **Docker is the sandbox.** Each `cco start` launches a fresh container with only the
  configured repos mounted. The agent cannot access host files outside its workspace.
  `--dangerously-skip-permissions` is safe inside the container because the container
  *is* the permission boundary.
- **Project-scoped sessions.** One project per container. No accidental cross-project
  modifications.
- **Ephemeral by default.** The container is `--rm` — it is destroyed when the session ends.
  Only repos (mounted from host) and auto memory (mounted to `claude-state/`) persist.
  Everything else starts clean next session.

### 3.3 Session Handoff Through Artifacts

**Principle**: When transitioning between sessions, produce explicit handoff documents
that capture the state at the boundary.

**How cco implements this:**

- **Analysis and design docs serve as handoff documents.** The `/analyze` skill produces
  a structured analysis summary; `/design` produces a design specification. Both are
  versioned files in the repo that the next session can read.
- **Auto memory** (`claude-state/`) provides continuity for context that does not belong
  in committed files — current task state, debugging notes, session-specific context.
- **CLAUDE.md as living state.** The project CLAUDE.md should reflect the current state
  of the project. Updating it at the end of significant phases ensures the next session
  starts with accurate context.

### 3.4 Agent Teams — Coordinated Multi-Agent Work

**Principle**: When working with multiple agents, define clear task boundaries, share
context, and coordinate through artifacts.

**How cco implements this:**

- **Lead-and-teammates model.** The lead agent coordinates, delegates, and synthesizes.
  Teammates (`analyst`, `reviewer`) focus on specialized tasks. The human remains the
  final decision-maker.
- **tmux-based teams.** `cco start --teammate-mode tmux` launches agents in
  tmux panes (tmux is the default mode). The lead can spawn teammates for parallel work.
- **Communication through artifacts.** Agents coordinate through the shared task list,
  versioned documents, and code — not through direct message passing. All coordination
  is visible and auditable.
- **Shared context, separate focus.** All agents in a team share the same project
  context (CLAUDE.md, rules, knowledge packs) but each focuses on its defined scope.

### 3.5 Testing as Design Verification

**Principle**: Tests verify that the implementation matches the design. An implementation
without tests is not complete.

In agent-assisted development, tests serve an additional critical function: they catch
**silent regressions**. An agent working on feature B may inadvertently break feature A
if feature A is not in its current context.

**How cco implements this:**

- The **workflow rule** specifies: "Write tests alongside implementation. Run existing
  tests to verify no regressions."
- The **reviewer agent** checks for test coverage gaps during code review.
- cco's own test suite (`bin/test`) validates the framework itself — a working example
  of the practice.

### 3.6 Scope-Aware Workflow

**Principle**: The development cycle applies recursively at different scope levels.

The same analysis-design-implementation cycle applies whether you are working at project,
service, module, or feature scope. The depth scales with scope — a project-level analysis
might span multiple sessions, while a feature-level analysis might be a few paragraphs.

**How cco implements this:**

- The **CLAUDE.md framework instruction** explicitly lists scope levels and requires
  clarification of the current scope before starting work.
- **Skills adapt to scope.** `/analyze` and `/design` produce proportional output
  based on the scope of the task.

---

## Cross-Cutting Concerns

### Skills as a Prompt Library

Effective prompts and instructions should be treated as code: versioned, refined, and
reused. cco implements this through the **skills system**:

- Global skills (`defaults/global/.claude/skills/`) provide reusable workflows available
  in every project — analysis, design, review, commit.
- Project-level skills (`projects/<name>/.claude/skills/`) provide project-specific
  workflows.
- Skills are markdown files with structured instructions. They evolve with the project.

### Periodic Health Checks

At each major milestone, review:

- **Rules**: Still relevant? Any contradictions? Prune aggressively.
- **Documentation**: Accurately reflects the current codebase?
- **CLAUDE.md**: Up to date with current project state?
- **Knowledge packs**: Still accurate? Any stale references?

cco's migration system (`cco update`) handles framework-level updates automatically.
Project-level health checks remain the developer's responsibility.

### Handling Agent Drift

Agent drift occurs when the agent gradually deviates from the intended approach during
long tasks. cco's mitigations:

- **Short sessions** (Docker isolation, one project per container)
- **Frequent commits** (workflow rule, git-practices rule)
- **Explicit constraints** in rules ("DO NOT modify files during analysis")
- **Diff review** via `/review` skill and `reviewer` agent before merging

### Scope Creep Prevention

Agents tend toward "helpful over-reach" — fixing adjacent code, refactoring something
they happen to read, adding features they think would be useful.

cco addresses this through:

- **Workflow phases** with explicit behavioral constraints (analysis = read only,
  design = no implementation code)
- **Rules** that can define explicit "do not modify" boundaries
- **Review gates** that catch out-of-scope changes before they are merged

---

## Summary of Principles and cco Features

| # | Principle | cco Feature |
|---|-----------|-------------|
| 1 | Repository as source of truth | Repos mounted at `/workspace/`, all context in versioned files |
| 2 | Atomic, conventional commits | `git-practices.md` rule loaded in every session |
| 3 | Branch-review-merge | Branch naming convention + `/review` skill |
| 4 | ADRs for decisions | `/design` skill produces ADR-structured documents |
| 5 | Two-layer review | `analyst` + `reviewer` agents (mechanical) + human gates (intent) |
| 6 | Minimum necessary context | Four-tier hierarchy, on-demand knowledge loading |
| 7 | Stratified context | Managed → Global → Project → Nested tiers |
| 8 | Living documentation | CLAUDE.md updated per phase, docs in repos |
| 9 | Domain-organized docs | `docs/<domain>/analysis.md`, `docs/<domain>/design.md` |
| 10 | Knowledge vs. instructions | CLAUDE.md (knowledge) / rules (behavior) / skills (actions) |
| 11 | Phased workflow with human gates | `workflow.md` rule + skills as phase entry points |
| 12 | Session independence | Docker containers, ephemeral by default |
| 13 | Handoff documents | Analysis/design docs + auto memory persistence |
| 14 | Exit criteria | Workflow phases with explicit completion checks |
| 15 | Tests as design verification | Workflow rule + reviewer agent coverage checks |
| 16 | Scope discipline | Phase constraints + review gates |
| 17 | Periodic health checks | `cco update` for framework + manual project review |
| 18 | Retrospectives | Post-feature review, rules refinement cycle |

---

*This guide is a living document maintained alongside claude-orchestrator. As the
framework evolves, so does this guide. It is mounted live via the `docs/` extra_mount
in the tutorial project, ensuring you always read the latest version.*
