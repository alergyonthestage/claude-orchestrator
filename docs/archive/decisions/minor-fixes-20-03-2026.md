# Minor Fixes Batch — 2026-03-20

> Raised: 2026-03-20. Four minor fixes addressing UX, workflow quality, context clarity, and documentation practices.

---

## MF-1: Remove `companyAnnouncements` from Managed Settings

**Status**: Implemented.

**Problem**: The `companyAnnouncements` field in `managed-settings.json` displays a reminder to run `cco build --no-cache` for updates. However, Claude Code renders it as "Message from \<org email\>", exposing the user's organization email address. The "from" label is determined by Claude Code based on the authenticated account — not controllable by the settings.

**Alternatives considered**:
- **Keep it**: unacceptable — shows user's private email in every session
- **Find a way to change the "from" label**: not possible — Claude Code derives it from the org profile
- **Move the reminder elsewhere**: the managed CLAUDE.md already has a "Self-Development" section with the same information

**Decision**: Remove `companyAnnouncements` entirely. The update reminder is already present in the managed CLAUDE.md and doesn't need a separate UI banner. No information is lost.

**Impact**: Managed file (baked in image). Effective on next `cco build`.

---

## MF-2: Design-Driven Testing in Workflow Rules

**Status**: Implemented.

**Problem**: The workflow rule's Implementation Phase says "Write tests alongside implementation" but gives no guidance on *how* tests should be written. This leads to agents writing tests that validate the implementation as-is rather than verifying the expected behavior from the design — effectively rubber-stamping bugs.

**Alternatives considered**:
- **Add a separate "Testing" phase**: rejected — adds ceremony without value. Tests are integral to implementation, not a separate phase. A dedicated phase would encourage writing tests *after* the code, which is the opposite of what we want.
- **Add a "Testing Approach" subsection to Implementation**: chosen — keeps tests tightly coupled to implementation while providing clear guidance on the design-driven approach.

**Decision**: Expand the Implementation Phase in `defaults/global/.claude/rules/workflow.md` with a "Testing Approach" subsection. Key principles: tests verify design expectations (not implementation details), write tests before or alongside code (TDD), when a test fails question the implementation first, test contracts not internals, ask when the design is ambiguous.

**Impact**: Opinionated file. Users discover via `cco update --diff`, apply with `--sync`.

---

## MF-3: CLAUDE.md Hierarchy (Project vs Repo)

**Status**: Implemented.

**Problem**: The agent doesn't understand the distinction between `/workspace/.claude/CLAUDE.md` (project-level, cross-repo) and `/workspace/<repo>/.claude/CLAUDE.md` (repo-specific). This causes confusion about where to write context, especially in single-repo projects where the distinction seems unnecessary but matters for future scalability.

**Context**: A cco project can have multiple repos and mounts. The project-level CLAUDE.md is always loaded; repo-level CLAUDE.md files are loaded on-demand. If a single-repo project uses only the repo CLAUDE.md and later adds a second repo, the existing CLAUDE.md scope becomes incorrect.

**Decision**: Add the hierarchy explanation in two managed files:
1. `defaults/managed/CLAUDE.md` — new "CLAUDE.md Hierarchy" section explaining both scopes and the rule that project-level is always primary
2. `defaults/managed/.claude/skills/init-workspace/SKILL.md` — scope rule note in Step 5 to ensure the skill generates content in the right file

**Rule**: Even for single-repo projects, the project-level CLAUDE.md is primary. Repo CLAUDE.md contains only repo-specific information.

**Impact**: Managed files (baked in image). Effective on next `cco build`.

---

## MF-4: ADR Practice in Documentation Rules

**Status**: Implemented.

**Problem**: No documentation rule mandates recording architectural decisions and their rationale. Agents lose context about *why* decisions were made across sessions, leading to re-discussion of settled questions or silent contradiction of prior decisions.

**Context**: The project already uses ADRs extensively in `docs/maintainer/decisions/` and `docs/maintainer/configuration/*/`. The documentation-first managed rule says to check existing docs, but the user-level documentation rule doesn't tell the agent to *create* decision records.

**Decision**: Add an "Architecture Decision Records (ADR)" section to `defaults/global/.claude/rules/documentation.md`. Key principles: record significant decisions with context/alternatives/rationale, ADRs are essential for agent continuity, keep them close to the domain they affect, mark superseded decisions.

**Impact**: Opinionated file. Users discover via `cco update --diff`, apply with `--sync`.
