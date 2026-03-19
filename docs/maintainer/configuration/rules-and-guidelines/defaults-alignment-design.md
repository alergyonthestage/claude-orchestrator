# Defaults Alignment Design — FI-2 + FI-5

> Aligns managed defaults, global defaults (rules, agents, skills, CLAUDE.md), and
> project templates with the user guides and framework philosophy.
>
> Date: 2026-03-19
>
> **Status**: Implemented (2026-03-19).
>
> **Predecessors**:
> - [`analysis.md`](analysis.md) — rules categories, scope mapping, file grouping
> - [`../resource-lifecycle/analysis.md`](../resource-lifecycle/analysis.md) — update policies
> - [FI-2](../../decisions/framework-improvements.md#fi-2-init-workspace-on-empty-projects)
> - [FI-5](../../decisions/framework-improvements.md#fi-5-human-workflow-guide-and-review-best-practices)
>
> **User guides** (the reference for what "good practice" means):
> - [`development-workflow.md`](../../../user-guides/development-workflow.md)
> - [`configuring-rules.md`](../../../user-guides/configuring-rules.md)
> - [`structured-agentic-development.md`](../../../user-guides/structured-agentic-development.md)
> - [`project-setup.md`](../../../user-guides/project-setup.md)

---

## 1. Design Principles

### 1.1 Scope Separation

| Scope | Purpose | Content Type | Overridable |
|-------|---------|-------------|-------------|
| **Managed** | Framework facts and mechanisms | Docker env, workspace layout, memory policy, context hierarchy, agent teams, hooks, deny rules | No |
| **Global** | Opinionated starting point | Workflow, git, documentation, language rules; agents; skills | Yes — user-owned after `cco init` |
| **Project template** | Minimal scaffolding | CLAUDE.md skeleton, settings.json | Yes — user fills in |
| **Pack template** | Empty scaffolding | Directory structure only | Yes |

### 1.2 Content Principle

> **CLAUDE.md and rules never hardcode specific behaviors.** They remind the agent to
> check and follow user-defined rules. The actual rule content depends on the user's
> configuration, which they customize via config-editor, tutorial, or manual editing.

Concretely:
- Managed CLAUDE.md says "user rules exist in `.claude/rules/`, always check and follow them"
- Global CLAUDE.md says "follow the rules in `.claude/rules/`" without duplicating their content
- Global rules provide reasonable defaults (workflow phases, git branches, docs structure)
- The user modifies, removes, or extends any global default without impacting framework operation

### 1.3 No Duplication Between Layers

Every piece of guidance lives in exactly one place:
- Framework behavior → managed CLAUDE.md or managed rules
- Workflow/git/docs/language → global rules (one file per domain)
- How to interact → global CLAUDE.md (communication style only)
- Agents and skills → global agents/skills directories
- Detailed advice → user guides (not loaded in agent context)

If content appears in two places, drift is inevitable. The managed layer points to
global rules; global CLAUDE.md points to rules; neither duplicates rule content.

---

## 2. Managed Layer Changes

### 2.1 Managed CLAUDE.md — add Context Hierarchy and Workspace Safety

**Current** (27 lines): Docker env, workspace layout, memory policy, agent teams.

**Proposed additions:**

```markdown
## Context Hierarchy
- Managed rules (this file, memory-policy.md) define framework behavior
- User rules in `.claude/rules/` define workflow, git, documentation,
  and other conventions — always check and follow them
- Project-level rules (in `/workspace/.claude/rules/`) take precedence
  over global rules for that project
- Knowledge packs provide domain-specific context on demand

## Workspace Safety
- /workspace/ root is NOT a mounted repository — do not write project
  files here (they are lost when the container exits)
- Write only in mounted repositories (/workspace/<repo-name>/) or
  extra mounts configured with :rw access
- Check mount mode before writing to extra mounts — some are :ro
```

**Rationale:**
- Context Hierarchy: framework fact (how cco's 4-tier system works), not an opinion
- Workspace Safety: framework fact (Docker mount behavior), prevents data loss

### 2.2 Managed Rules — no changes

`memory-policy.md` is already correct. No other managed rules needed.

### 2.3 Managed Settings — no changes for FI-5

`managed-settings.json` hooks and deny rules are framework infrastructure.
FI-8 (PromptSubmit hook) is a separate item — not included in this design.

---

## 3. Global Layer Changes

### 3.1 Global CLAUDE.md — rewrite

**Current** (61 lines): duplicates workflow phases (8 phases + scope levels + phase
behavior), git practices, communication style, agent teams, Docker env.

**Problems:**
- Workflow phases duplicated from `rules/workflow.md`
- Git practices duplicated from `rules/git-practices.md`
- Agent teams duplicated from managed CLAUDE.md
- Docker env duplicated from managed CLAUDE.md

**Proposed:**

```markdown
# Global Instructions

## How to Work

Follow the rules defined in `.claude/rules/` for workflow phases,
git practices, documentation, and other conventions. If project-level
rules exist, they take precedence for that project.

When starting a task:
1. Check which rules are active and relevant
2. Clarify the scope and current phase with the user
3. Follow the defined workflow — ask before advancing phases

## Communication Style
- Be concise and direct
- Present findings in structured format
- When presenting options, include trade-offs
- Ask clarifying questions before making assumptions
- At the end of each phase, summarize what was done and what's next
```

**What's removed and why:**
- Development Workflow (phases, scope levels, phase behavior) → in `rules/workflow.md`
- Git Practices → in `rules/git-practices.md`
- Agent Teams → in managed CLAUDE.md (framework fact)
- Docker Environment → in managed CLAUDE.md (framework fact)

**What stays:**
- "How to Work" — the meta-instruction to follow rules (not duplicated elsewhere)
- "Communication Style" — interaction preference, not a workflow or git rule

### 3.2 Global Rules

#### `workflow.md` — expand with Principles section

**Current** (31 lines): 4 phase sections with bullet lists.

**Proposed changes:** Add a Principles section at the top. Keep phase sections as-is.

```markdown
# Workflow Phase Rules

## Principles
- Phase transitions require explicit user approval — never auto-advance
- Decompose complex tasks: clarify scope before starting work
- If the approach changes during implementation, pause and discuss
- At the end of each phase, summarize findings and propose next steps

## Analysis Phase
[unchanged]

## Design Phase
[unchanged — remove "see diagrams rule" cross-reference]

## Implementation Phase
[unchanged]

## Documentation Phase
[unchanged]
```

**Rationale:** The Principles section adds 4 lines encoding the most critical
practices from the user guides (approval gates, decomposition, pause-if-changed,
phase summaries) without being too prescriptive. The phase sections remain minimal.

#### `diagrams.md` → `documentation.md` — rename and expand

**Current** `diagrams.md` (25 lines): Mermaid conventions only.

**Proposed** `documentation.md`:

```markdown
# Documentation Practices

## Structure
- Write documentation in the repository's /docs directory
- Organize by domain or module, not by document type
- Use consistent naming conventions within the project
- Keep related documentation close to the code it describes
- After completing a development cycle, review and update stale docs
- Periodically evaluate if docs need reorganization for better discovery

## Diagrams

Mermaid diagrams are required in written artifacts — files written
to the filesystem:
- Documentation files (README, guides, changelogs)
- Design documents and architecture specs
- Any .md file produced as output

Mermaid diagrams are NOT used in:
- Direct chat responses displayed in the terminal
- Plan mode output (displayed inline in terminal)

In terminal output, use plain text, bullet lists, or indented outlines.

### Rules
- Always use Mermaid syntax, never ASCII art
- Wrap in fenced code blocks: ```mermaid ... ```
- Split complex diagrams into multiple smaller ones
- Prefer text/lists when a diagram adds no value
```

**What's added:**
- Structure section (6 lines): /docs as default location, domain-based org,
  stale docs review after dev cycles, periodic reorganization assessment
- These are generic enough to be useful without being prescriptive

**What's preserved:** All Mermaid rules intact.

#### `git-practices.md` — no changes

Already concise and well-scoped. Branch strategy, conventional commits, frequency.
Not too opinionated, not too vague. Covers the essentials.

#### `language.md` — no changes

Template with `{{...}}` placeholders. Interpolated by `cco init`, regenerated
by `cco update --sync`. Stored in `.cco/meta`. Working correctly.

### 3.3 Global Agents

#### `analyst.md` — no changes needed

Well-structured: clear role, analysis framework, guidelines, memory instructions.
Model: haiku (cost-effective for read-only exploration). Tools: read-only + web.
Aligned with `/analyze` skill and user guide recommendations.

**Assessment:** The agent is generic enough to work across projects. The analysis
framework (Summary, Key Findings, Relevant Files, Questions) is a reasonable default
that users can customize. No changes needed.

#### `reviewer.md` — no changes needed

Well-structured: clear role, 5-category checklist, severity-based output format.
Model: sonnet (good balance for review quality). Tools: read-only.
Aligned with `/review` skill and multi-pass review recommendations in user guides.

**Assessment:** The review checklist covers the right categories (correctness,
security, code quality, performance, maintainability). The output format (Critical,
Warnings, Suggestions, Good Practices) is universally useful. No changes needed.

### 3.4 Global Skills

#### `/analyze` — no changes needed

Aligned with workflow Analysis phase. Uses Explore agent for systematic discovery.
Output format matches analyst agent. Fork context prevents pollution.

#### `/design` — no changes needed

Aligned with workflow Design phase. Uses Plan agent. Output includes requirements,
options, recommended design, implementation steps, risks. References ADRs.

#### `/review` — no changes needed

Aligned with reviewer agent checklist. Covers correctness, security, performance,
readability, testing. Severity-based output (blocker/major/minor/nit).

#### `/commit` — minor improvement possible

**Current:** Well-structured conventional commit workflow with `disable-model-invocation: true`.

**Potential improvement:** The skill could remind to check git rules before committing:
"Follow the git conventions defined in `.claude/rules/`" — consistent with the principle
that skills reference rules without hardcoding them. However, this is minor and optional.

**Decision:** No change in this sprint. The skill already follows conventional commits
which aligns with the default `git-practices.md`.

### 3.5 Global Settings (`settings.json`)

**Current:** Permissions allow-list, attribution, tmux teammate mode, cleanup, MCP.

**Assessment:** No changes needed. The permissions list is broad but appropriate for
a containerized environment where `--dangerously-skip-permissions` is the norm.
Attribution format is standard. Teammate mode defaults to tmux (works everywhere).

---

## 4. Project Template Changes

### 4.1 Remove `templates/project/base/.claude/rules/language.md`

**Current:** A "commented-out" override using `#` prefixes. But `#` in markdown
creates headings, not comments. The file content is visible to the agent and
potentially confusing.

**Decision:** Remove the file. Users create a project-level language override
explicitly when needed. The global `language.md` applies by default.

**Migration:** Delete the file from existing projects. Since it's `untracked`
in `PROJECT_FILE_POLICIES`, the update system doesn't manage it. A migration
script should: (a) check if the file exists and is unmodified (matches template),
(b) if so, delete it, (c) if modified by user, leave it and notify.

### 4.2 Update `templates/project/base/.claude/CLAUDE.md`

**Current** (34 lines): Skeleton with `{{PROJECT_NAME}}`, `{{DESCRIPTION}}`,
and HTML comment placeholders.

**Proposed:**

```markdown
# Project: {{PROJECT_NAME}}

## Overview
{{DESCRIPTION}}

<!-- Run /init-workspace after starting the first session to auto-populate
     this file from your repositories and knowledge packs. -->

## Repositories

## Project-Specific Instructions

## Architecture

## Infrastructure

## Key Commands
```

**What's changed:**
- Added `/init-workspace` hint as HTML comment (visible to user reading the
  file, not treated as an instruction by the agent)
- Removed verbose HTML comment blocks from each section (noise reduction)
- Kept Infrastructure section without the networking details (too specific
  for a generic template; `/init-workspace` will discover infrastructure)

### 4.3 No other template changes

The project template should remain minimal scaffolding. No rules, no agents,
no skills at project level. The user adds these per-project when needed.

---

## 5. FI-2: `/init-workspace` Adaptive Flow

### 5.1 Current Behavior

The skill (`defaults/managed/.claude/skills/init-workspace/SKILL.md`) follows
6 steps: read workspace.yml → explore repos → describe packs → read CLAUDE.md →
write CLAUDE.md → update workspace.yml.

On empty workspaces (no repos, no descriptions), it generates a CLAUDE.md with
empty placeholder sections. No user interaction.

### 5.2 Proposed Change

Add a new step between "Read current CLAUDE.md" (Step 4) and "Write CLAUDE.md"
(Step 5) that detects empty workspaces and guides the user adaptively.

#### Detection Criteria

Empty workspace = ALL of these are true:
- No repos listed in workspace.yml (or workspace.yml missing)
- No extra_mounts listed
- CLAUDE.md is empty, missing, or contains only template placeholders

#### Adaptive Flow

```
Step 4b: Empty Workspace — User-Guided Initialization

If the workspace is empty (no repos, no extra mounts, no existing content):

1. Ask the user: "This workspace has no repositories yet. How much detail
   can you provide about the project?"

   - (A) "I have an idea but nothing defined yet"
   - (B) "I have some decisions made (stack, architecture, key components)"
   - (C) "I have detailed specs or design documents to share"

2. Based on the response:

   (A) Minimal — ask for:
   - Project description (2-3 sentences: what it does, who it's for)
   - Generate a minimal CLAUDE.md with Overview populated
   - Suggest: "Consider running /analyze or starting a conversation
     to explore requirements before defining architecture"

   (B) Moderate — ask follow-up questions:
   - What tech stack? (languages, frameworks, key dependencies)
   - What are the main components or services?
   - Any infrastructure needs? (databases, caches, message queues)
   - Any integrations? (APIs, external services)
   - Generate CLAUDE.md with Overview, Architecture, and
     Infrastructure sections populated

   (C) Detailed — ask the user to share:
   - "Paste or describe your specs, and I'll structure them into
     the project context"
   - Parse the provided information and populate all relevant
     sections of CLAUDE.md
   - Suggest follow-up: "Run /design to formalize the architecture"

3. In all cases:
   - Keep generated content concise and factual
   - Mark sections that need further work with
     <!-- TODO: define after analysis/design -->
   - Save descriptions to workspace.yml for persistence
```

### 5.3 Scope

**File to modify:** `defaults/managed/.claude/skills/init-workspace/SKILL.md`

**Effort:** Low — ~30 lines of additions to the skill definition. The logic is
executed by the agent (not code); the skill just provides instructions.

**Impact:** Managed skill, baked into Docker. Changes apply on next `cco build`.
No migration needed.

---

## 6. Update System Impact

### 6.1 Change Classification

| Change | Type | Mechanism |
|--------|------|-----------|
| Managed CLAUDE.md (Context Hierarchy + Workspace Safety) | Framework | Baked in Docker image on `cco build` |
| Global CLAUDE.md (rewrite) | Opinionated | `cco update --sync` |
| `workflow.md` (add Principles) | Opinionated | `cco update --sync` |
| `diagrams.md` → `documentation.md` | **Breaking** (rename) | Migration script |
| `git-practices.md` (no change) | — | — |
| `language.md` (no change) | — | — |
| Template `language.md` removal | **Breaking** (delete) | Migration script |
| Template CLAUDE.md update | Template-only | New projects only |
| `init-workspace` SKILL.md | Framework | Baked in Docker image on `cco build` |

### 6.2 Migrations Required

#### Migration 1: `diagrams.md` → `documentation.md` (scope: global)

```
Migration ID: next sequential in migrations/global/
Scope: global
Action:
  1. If user-config/global/.claude/rules/diagrams.md exists:
     a. Rename to documentation.md
     b. Update .cco/base/ entry (rename diagrams.md → documentation.md)
  2. If diagrams.md doesn't exist, no-op
Idempotent: yes (check target exists before rename)
```

**File policy change:** In `GLOBAL_FILE_POLICIES`:
- Remove `".claude/rules/diagrams.md:tracked"`
- Add `".claude/rules/documentation.md:tracked"`

The policy transition (`tracked → tracked` with rename) is NOT automatic —
requires migration because the system doesn't know the old→new path mapping.

#### Migration 2: Remove template `language.md` (scope: project)

```
Migration ID: next sequential in migrations/project/
Scope: project
Action:
  1. If .claude/rules/language.md exists in project:
     a. Compare content with known template content (commented-out override)
     b. If unmodified: delete the file
     c. If modified by user: leave it, print info message
  2. If doesn't exist, no-op
Idempotent: yes (check existence before action)
```

### 6.3 Changelog Entry

```yaml
- id: <next>
  date: "2026-03-19"
  type: additive
  title: "Defaults alignment: improved rules, documentation practices, workspace safety"
  description: >
    Global defaults updated to align with user guides. Key changes:
    diagrams.md renamed to documentation.md (includes docs structure practices),
    workflow.md expanded with approval gates and task decomposition principles,
    global CLAUDE.md simplified (no longer duplicates rule content).
    Managed CLAUDE.md now includes context hierarchy and workspace safety guidance.
    /init-workspace skill now guides users through empty workspace setup.
    Run 'cco update' to discover changes and 'cco update --sync' to apply.
```

---

## 7. Files Changed — Complete Manifest

### Modified Files

| File | Lines (approx) | Change |
|------|----------------|--------|
| `defaults/managed/CLAUDE.md` | 27 → 40 | +Context Hierarchy, +Workspace Safety |
| `defaults/managed/.claude/skills/init-workspace/SKILL.md` | 141 → ~175 | +Step 4b adaptive flow |
| `defaults/global/.claude/CLAUDE.md` | 61 → ~18 | Rewrite: remove duplications |
| `defaults/global/.claude/rules/workflow.md` | 31 → ~36 | +Principles section |
| `defaults/global/.claude/rules/diagrams.md` | — | **Deleted** (renamed) |
| `defaults/global/.claude/rules/documentation.md` | — | **Created** (from diagrams.md + structure) |
| `templates/project/base/.claude/CLAUDE.md` | 34 → ~18 | +init-workspace hint, cleanup |
| `templates/project/base/.claude/rules/language.md` | — | **Deleted** |
| `lib/update.sh` | — | Policy change: diagrams→documentation |
| `migrations/global/NNN_rename_diagrams_to_documentation.sh` | — | **Created** |
| `migrations/project/NNN_remove_template_language_override.sh` | — | **Created** |
| `changelog.yml` | — | +1 entry |
| `docs/maintainer/decisions/roadmap.md` | — | Update FI-2 and FI-5 status |

### Unchanged Files (assessed, no changes needed)

| File | Reason |
|------|--------|
| `defaults/global/.claude/rules/git-practices.md` | Already well-scoped |
| `defaults/global/.claude/rules/language.md` | Template system works correctly |
| `defaults/global/.claude/agents/analyst.md` | Generic, well-structured |
| `defaults/global/.claude/agents/reviewer.md` | Generic, well-structured |
| `defaults/global/.claude/skills/analyze/SKILL.md` | Aligned with workflow |
| `defaults/global/.claude/skills/design/SKILL.md` | Aligned with workflow |
| `defaults/global/.claude/skills/review/SKILL.md` | Aligned with reviewer |
| `defaults/global/.claude/skills/commit/SKILL.md` | Aligned with git-practices |
| `defaults/global/.claude/settings.json` | Appropriate for container env |
| `defaults/global/.claude/mcp.json` | Empty placeholder, correct |
| `defaults/managed/managed-settings.json` | Framework hooks, no FI-5 changes |
| `defaults/managed/.claude/rules/memory-policy.md` | Already correct |

---

## 8. Open Questions

### Resolved in This Design

| Question | Resolution |
|----------|-----------|
| Where do Agent Teams / Docker instructions go? | Managed CLAUDE.md only (framework facts) |
| Should rules hardcode specific behaviors? | No — rules provide defaults, CLAUDE.md points to rules |
| What about template project-level language.md? | Remove (# comments don't work in .md) |
| Should agents/skills change? | No — already generic and well-aligned |
| What goes in the documentation rule? | /docs default, domain-based org, stale review, reorg assessment |

### Deferred

| Question | Context | Deferred To |
|----------|---------|-------------|
| FI-8 PromptSubmit hook | Reinforcement reminder on every prompt. Depends on FI-5 defaults being finalized | FI-8 design (separate document) |
| `/commit` skill referencing git rules | Minor improvement, not blocking | Future sprint |
| Additional skills (`/implement`, `/document`, `/test`) | Mentioned in analysis.md, not yet prioritized | Evaluation in future sprint |
| Communication Style as separate rule | Currently in global CLAUDE.md. Could become `communication.md` rule for user customization | Future if users request it |
