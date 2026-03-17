# Rules, Guidelines & Workflow Configuration — Analysis

> Analysis of how to organize rules, guidelines, workflow definitions, and best practices
> within claude-orchestrator. Covers scope decisions, file grouping, and the boundary
> between framework defaults and user documentation.
>
> Date: 2026-03-15
>
> **Related**: For file update policies (tracked/untracked/generated) and resource
> lifecycle mechanics, see [`resource-lifecycle/analysis.md`](../resource-lifecycle/analysis.md).
> This document focuses on **content organization** (which rules go in which files),
> not on update mechanics.

---

## Context

claude-orchestrator provides an isolated environment and tools for AI-assisted development.
The framework intentionally avoids being opinionated/enforced — all workflow rules and
guidelines are **recommendations** that users can modify, extend, or remove entirely.

This analysis examines:
1. What categories of rules/guidelines exist
2. Where each category should live (scope/layer)
3. How to group rules in files to minimize contradictions
4. What belongs as a default vs. what belongs only in documentation

---

## Categories of Rules and Guidelines

Six distinct categories have been identified:

### 1. Workflow Phases and Steps

Defines the development workflow as a state machine. Phases represent sessions (with
clean context) of the agent. Not necessarily linear — may include cycles, loops, and
backward transitions with conditions.

Each phase/step should define:
- Agent behavior rules during the step
- Session objective
- Model to use (with future claude-orchestrator integration for per-phase model selection)
- Required input/output with explicit file paths
- Exit conditions and rules for determining the next phase

### 2. Documentation Structure

Rules for organizing documentation:
- Directory structure and file positioning (`/docs`, external systems via MCP, etc.)
- Unambiguous location for every file type — prevents duplication and contradictory versions
- Update and versioning rules, changelog conventions
- File format, tooling (Mermaid for diagrams), and structure conventions

### 3. Git Practices

- Git workflow (git-flow, gitlab-flow, etc.) with merge direction and branch flow
- Merges correspond to human review points and PRs; commits are automated by the LLM
- Naming conventions for commits and branches
- Commit frequency (atomic commits, working state commits, etc.)
- What to include in commit messages and PR descriptions

### 4. Language

- Language for code writing
- Language for documentation
- Language for human communication (chat/terminal LLM responses)

### 5. Maintenance and Updates

- Backward compatibility policy: maintain legacy code vs. allow breaking changes
- Depends heavily on project phase (MVP vs. production with users)
- Documentation archival strategy (archive old docs vs. rely on git history)
- When to perform system/module reviews and evaluate refactoring opportunities

### 6. Human in the Loop vs. Autonomous Decisions

- What requires human approval and what can be decided autonomously
- Process for autonomous decisions (preventive analysis, evaluate alternatives against
  architecture, user intent, complexity, and trade-offs)
- Process for requesting human review (analysis, context, recommended solution)

### Per-Project/Stack Configuration (Separate Category)

Not part of the universal guidelines — these are project-specific:
- Architecture and project structure (directory tree, file positioning)
- Technology stack
- Libraries and frameworks
- Coding guidelines specific to language/app/project

These belong in **packs** (reusable cross-project) or **project-level rules** (specific to
one project).

---

## Scope Analysis: What Goes Where

### Framework Philosophy

| Layer | Role | Content Type |
|-------|------|-------------|
| **Managed** | Framework infrastructure, NOT opinions | Hooks, memory-policy, deny rules, `init-workspace` skill |
| **Global defaults** | Minimal starting point, user-owned | Template rules the user customizes after `cco init` |
| **User guides** | Tested best practices, detailed advice | "How to configure an effective workflow" |
| **Tutorial** | Interactive personalization guide | References user guides as knowledge source |

**Key principle**: The framework provides tools and environment. Opinionated content is
delivered as advice (user guides) and minimal starting points (global defaults), never as
enforced rules.

### Category-to-Scope Mapping

| Category | Default Rule? | User Guide? | Rationale |
|----------|:------------:|:-----------:|-----------|
| Workflow phases | Yes (minimal) | Yes (detailed) | A basic workflow is universally useful as starting point. Detailed state machine config is advice. |
| Docs structure | Yes (minimal) | Yes (detailed) | Basic structure conventions help. Detailed org is project-specific. |
| Git practices | Yes (minimal) | Yes (detailed) | Conventional commits and feature branches are near-universal. Merge flow varies. |
| Language | Yes (template) | No | Essential — user MUST define this. Template with `{{LANG}}` placeholders. |
| Maintenance | No | Yes | Too project-dependent for a sensible default. MVP vs production are opposites. |
| Human in the loop | Partial (in workflow) | Yes | Phase-transition autonomy goes in workflow rule. General patterns go in user guide. |
| Per-project/stack | No (templates) | Yes (examples) | Belongs in packs and project rules. User guide shows how to configure. |

### Skills: Managed or Global?

Current skills: `/analyze`, `/design`, `/review`, `/commit`

| Skill | Universal? | Opinionated? | Customizable? |
|-------|:----------:|:------------:|:-------------:|
| `/analyze` | Yes | Yes (checklist, approach) | User may change checklist, tools, agent |
| `/design` | Yes | Yes (design doc format) | User may prefer ADR vs design doc |
| `/review` | Yes | Yes (review checklist) | Strongly customizable |
| `/commit` | Yes | Less so, but conventions vary | Conventional commits vs other |

**Decision**: All workflow skills are **global defaults**, not managed.

- The **mechanism** for skills is framework (managed) — Claude Code knows how to execute skills
- The **specific skills** are opinionated content — users customize them
- `/analyze`, `/design`, `/review` are the "recommended workflow in a box"
- Users who don't want separate phases can delete them; users who want `/implement` or `/test` can add them
- Only `init-workspace` remains managed (framework infrastructure)

### Potential Additional Skills

| Skill | Purpose | Status |
|-------|---------|--------|
| `/implement` | Implementation phase with design checklist | To evaluate |
| `/document` | Documentation phase with update checklist | To evaluate |
| `/test` | Testing phase with coverage check | To evaluate |

---

## File Grouping Analysis

### Guiding Principle

> One rule file per decision domain. Correlated rules in the same file to avoid
> contradictions. If two rules can conflict, they must be in the same file where
> the contradiction is visible and resolvable.

### Correlation Matrix

Analysis of correlation and contradiction risk between categories:

```
                WORK  DOCS  GIT   LANG  MAINT  AUTON  DIAG
WORKFLOW         —    low   low   none  med    HIGH   none
DOCS-STRUCT      .     —    none  MED   low    none   HIGH
GIT              .     .     —    none  low    low    none
LANGUAGE         .     .     .     —    none   none   none
MAINTENANCE      .     .     .     .     —     med    none
AUTONOMY         .     .     .     .     .      —     none
DIAGRAMS         .     .     .     .     .      .      —
```

**High correlation (contradiction risk):**

1. **WORKFLOW <-> AUTONOMY** — Both define "when to proceed" and "when to stop".
   Example: workflow says "proceed to next phase after exit condition", autonomy says
   "ask for approval before proceeding". If in separate files, contradiction almost
   guaranteed. **Resolution: merge into same file.**

2. **DOCS-STRUCT <-> DIAGRAMS** — Both define "how to write documentation". Diagrams
   is a subset of docs-structure. Example: docs-structure says "use bullet list for
   comparisons", diagrams says "use Mermaid for comparisons". **Resolution: merge
   into same file.**

**Medium correlation (manageable risk):**

3. **DOCS-STRUCT <-> LANGUAGE** — Language says "write docs in English", docs-structure
   says where and how. Potential conflict: language defines language, docs defines
   templates with sections in another language. Risk acceptable because domains are
   clear: language = *in which language*, docs = *where and how*.

4. **WORKFLOW <-> MAINTENANCE** — Maintenance says "when to refactor", workflow defines
   phases. Potential: maintenance says "refactoring after every sprint" but workflow
   has no refactoring phase. Manageable because maintenance is not included as a default.

5. **MAINTENANCE <-> AUTONOMY** — Maintenance says "breaking changes allowed", autonomy
   says "ask before breaking changes". Since both are in the same scope (workflow.md
   for autonomy, user guide for maintenance), the risk is mitigated.

### Recommended Grouping: 4 Default Rule Files

| File | Unified Content | Merges |
|------|----------------|--------|
| `workflow.md` | Phases + transitions + human-in-the-loop + exit conditions | workflow + autonomy |
| `documentation.md` | Docs structure + format + diagrams + versioning | docs-structure + diagrams |
| `git-practices.md` | Branch strategy + commits + merge flow + PR conventions | git (expanded) |
| `language.md` | Languages for code, docs, communication | language (unchanged, template) |

**Maintenance excluded from defaults** because:
- Strongly project-dependent (MVP vs production are opposite policies)
- No universally sensible default
- Parts correlated with autonomy (breaking changes policy) go in workflow.md
- General guidelines documented in user guide as best practices to evaluate per-project

---

## Documentation Deliverables

### For `docs/user-guides/`

Two new guides needed:

| File | Content | Purpose |
|------|---------|---------|
| `development-workflow.md` | Human workflow: context cleanup, review cycles, verification before closing features, human-in-the-loop patterns, when/how to use reviews | Operational "how to" for the developer driving claude-orchestrator |
| `configuring-rules.md` | How to configure rules: categories, grouping principle (correlated = same file), scope (global vs project), examples per category, maintenance policy, breaking changes strategy | Reference for users customizing their setup; used by tutorial |

### For `defaults/global/.claude/rules/`

Update existing defaults:
- Expand `workflow.md` with state machine, input/output, exit conditions, autonomy rules
- Replace `diagrams.md` with `documentation.md` (unified)
- Expand `git-practices.md` with merge flow and PR conventions
- Keep `language.md` as-is (template)

---

## Open Questions

1. **Workflow state machine detail level**: Should the default rule define an explicit
   state graph (with conditions on edges), or a more flexible description with guidelines?
   Recommendation: flexible description for the default, detailed state machine example
   in the user guide.

2. **Per-phase models**: The roadmap mentions different models for different phases. Should
   the workflow rule already include model suggestions per phase, or wait for technical
   support? Recommendation: wait for the feature, document the concept in user guide.

3. **Review cycles**: Include only in the human user guide, or also as a rule for Claude
   (e.g., "after implementation, automatically run `/review` before declaring complete")?
   Recommendation: both — minimal rule in workflow.md (suggest review before closing),
   detailed human process in user guide.

4. **Additional workflow skills**: Evaluate `/implement`, `/document`, `/test` as global
   defaults or just document them as examples in the user guide.

5. **`language.md` initialization flow**: Currently `cco init` interactively asks the
   user for their preferred language and fills the `{{LANG}}` template. Alternatives
   to evaluate:
   - **Remove interactive init** — let the tutorial agent or user configure manually
   - **Expand init** — ask for more preferences during init (git conventions, workflow)
   - **Agent-assisted init** — run an agent during init that interviews the user
   - **Keep template as-is** — `{{LANG}}` placeholders remain, no conflict with user edits

   Key consideration: if `cco init` fills `language.md`, subsequent `cco update --sync`
   must not overwrite user customizations. The current mechanism (copied once, never
   overwritten) already handles this, but the template in `defaults/global/` still has
   `{{LANG}}` which shows as a diff in `cco update --diff`. Need to decide if init
   should transform the template or if the user should edit manually.

---

## Next Steps

1. Write the two user guides (`development-workflow.md`, `configuring-rules.md`)
2. Update the 4 default rule files accordingly
3. Update the project tutorial to reference the new user guides
4. Consider integration with roadmap items (per-phase models, additional skills)
