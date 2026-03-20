# Development Workflow Guide

> Operational best practices for developers using claude-orchestrator. This guide covers
> human behavior and habits — how to drive cco effectively, not how to configure it.
>
> For configuration: [configuring-rules.md](configuring-rules.md)
> For principles: [structured-agentic-development.md](structured-agentic-development.md)

---

## Overview

The quality of agentic development depends as much on **how you work with the agent**
as on how you configure it. This guide documents practices that have been tested through
extensive real-world use of claude-orchestrator and Claude Code. They are recommendations,
not requirements — adopt what works for your context.

---

## Context Management

### Clean context frequently

Each workflow phase should ideally run in a **fresh session** with clean context.
A fresh session receives only the defined inputs for that phase (design documents,
analysis summaries, etc.) rather than carrying accumulated noise from prior work.

**Why**: Long sessions accumulate context that biases the agent. An agent that just
finished debugging a tricky race condition will approach the next task with that
debugging mindset, even when it's not relevant. Fresh context means fresh perspective.

**How**: Use `/clear` between phases, or exit and restart the session. Pass phase
inputs explicitly (reference specific documents) rather than relying on conversation
history.

**Mid-session drift**: The framework includes a managed per-prompt hook that reinforces
key behavioral rules on every turn (check configured rules, verify git status, follow
approved design). If the agent still drifts during a long session, use `/clear` and
re-state the current objective with explicit references to the relevant design documents.

### One phase per session

Treat each phase as a focused session with:
- A clear **objective** (e.g., "analyze the authentication module")
- Defined **inputs** (e.g., "read `docs/auth/design.md` and `src/auth/`")
- Expected **outputs** (e.g., "produce `docs/auth/analysis.md`")

This maps naturally to cco's Docker isolation — each session starts clean, and artifacts
are persisted through the repository.

---

## Task Decomposition

### Why smaller tasks produce better results

Each prompt consumes a fixed budget of compute. When you ask for an entire application
in a single prompt, the agent spreads that budget across analysis, design, implementation,
testing, and documentation simultaneously — producing shallow results across all of them.

When you break the same work into focused phases and smaller units, the agent dedicates
its full compute budget to each step. The result is consistently deeper, more accurate,
and easier to review.

**The principle**: One focused task per prompt. The narrower the scope, the higher
the quality.

### Decomposition levels

Apply decomposition at multiple levels, each multiplying the quality improvement:

| Level | What you decompose | Example |
|-------|-------------------|---------|
| **Phases** | Split work into analysis → design → implementation | Instead of "build auth", do: "analyze auth requirements" → review → "design auth module" → review → "implement auth" |
| **Modules** | Split a feature into independent components | Instead of "build the whole app", do: "implement the data layer" → "implement the API" → "implement the UI" |
| **Sub-tasks** | Split a complex module into smaller units | Instead of "implement the API", do: "implement CRUD endpoints" → "add validation" → "add auth middleware" |

### When to decompose further

If the agent's output on a task is unsatisfying — incomplete, error-prone, or shallow —
the task is too large for a single prompt. The recommended recovery path:

1. **Stop and re-analyze**: Go back to analysis to understand why the task is complex
2. **Identify sub-problems**: Break the task into autonomous sub-tasks that can each
   be completed in a single focused prompt
3. **Simplify**: Sometimes the problem itself can be simplified — a simpler data model,
   fewer edge cases handled initially, a phased rollout
4. **Execute incrementally**: Complete each sub-task with its own analysis → implementation
   → review cycle

### Practical example

Instead of:
```
> Build a user authentication system with OAuth, email/password, 2FA, and password reset
```

Decompose into:
```
Session 1: > Analyze authentication requirements for the project (read existing code,
             identify constraints, list decisions needed)
         → Review analysis, approve approach

Session 2: > Design the auth module: data model, interfaces, flow diagrams
         → Review design, approve

Session 3: > Implement email/password registration and login
         → Review, fix issues

Session 4: > Implement OAuth provider integration
         → Review, fix issues

Session 5: > Implement password reset flow
         → Review, fix issues

Session 6: > Implement 2FA (TOTP)
         → Review, fix issues

Session 7: > Integration testing and documentation for the auth module
         → Final review
```

Each session produces focused, high-quality output. The total result is significantly
better than a single "build auth" prompt — and easier to review at each step.

### Task decomposition and the workflow

Task decomposition is complementary to the phased workflow. The workflow defines
**what type of work** happens (analysis, design, implementation). Decomposition defines
**how much work** happens per prompt. Both work together:

- **Workflow phases** ensure you analyze before implementing
- **Decomposition** ensures each phase focuses on a manageable scope
- **Review gates** between phases catch issues before they compound

The combination of phased workflow + decomposition + review gates is the highest-leverage
practice for agentic development quality.

---

## Permission Modes per Phase

Claude Code's native permission modes map naturally to workflow phases. Use them to
match the level of control to the risk profile of each phase:

| Phase | Recommended Mode | Why |
|-------|-----------------|-----|
| Analysis | **Plan mode** (`Shift+Tab` to toggle) | Read-only exploration — the agent proposes, doesn't execute. Ideal for analysis and design where you want to review thinking before any action. |
| Design | **Plan mode** | Same rationale — design documents should be reviewed before being written. The agent outlines the design in the plan, you approve, then switch modes to write. |
| Implementation | **Skip permissions** (default in cco) | After analysis and design are reviewed and approved, implementation is often correct in one pass. Let the agent work freely. |
| Sensitive operations | **Accept edits** | When you want line-by-line control over what gets written — useful for security-sensitive code, production configs, or unfamiliar areas. |

**Key observation**: When analysis and design are thorough, reviewed, and approved,
implementation is frequently correct on the first pass — typically requiring only 1-2
review iterations for bug fixes. The investment in analysis and design quality pays off
directly in implementation accuracy.

**Note**: cco containers default to skip-permissions for all phases
(`--dangerously-skip-permissions`). To use Plan mode or Accept Edits mode,
toggle manually at the start of the session with `Shift+Tab`.

**Practical flow**:
1. Toggle to plan mode → agent produces analysis/design
2. Review and approve the plan
3. Switch to skip permissions → agent implements
4. Run `/review` → fix issues → run `/review` again
5. Switch to accept edits if touching sensitive areas

---

## Review Cycles

### Run reviews after every implementation cycle

A single implementation pass is rarely sufficient. **Typically 2-3 review + fix
iterations** are needed to reach good implementation quality.

The pattern:

```
Implementation → Review #1 → Fix → Review #2 → Fix → [Review #3 if needed] → Done
```

### Types of review

After each implementation cycle, run these reviews (can be parallel — use the
`reviewer` agent as a teammate for independent parallel review while the lead
agent continues working):

1. **Alignment review** — Does the implementation match the design documents?
   The agent should compare the actual code against the approved design, checking
   for missing features, deviations, and shortcuts.

2. **Bug hunting** — Are there critical bugs, edge cases, or error handling gaps?
   Use the `/review` skill or the `reviewer` agent for this.

3. **Documentation review** — Is any documentation stale? Are all references and
   concepts updated to reflect the new implementation? Check CLAUDE.md, README,
   inline comments, and any design documents.

4. **Test review** — Do the tests have sufficient coverage? Are they complete?
   Are there untested edge cases? Does the test suite actually run and pass?

### Why the second review matters

The second review **almost always** finds issues the first review missed. This is not
a failure of the first review — it's a natural consequence of how attention works.
The first review catches the obvious problems. Fixing those problems shifts the
codebase state, which can expose subtler issues that weren't visible before.

**Never consider a feature complete after only one review pass.**

### Automated + human review

Every development cycle should conclude with:
1. **Automated review** by the agent (using `/review` or the `reviewer` agent)
2. **Automated testing** (run the test suite)
3. **Human review** of the agent's work, focusing on:
   - Architectural alignment
   - Security implications
   - Code quality and maintainability
   - Business logic correctness

Human in the loop + automated reviews **drastically improve result quality** and prevent
the accumulation of bugs and errors.

---

## Phase Transitions

### Verify intermediate artifacts

**Always verify in detail all intermediate artifacts between phases.** The reference
documents are the analysis and design documents created in earlier phases.

Before moving from design to implementation:
- Is the design complete? Are all components specified?
- Are interfaces clearly defined? Are data models correct?
- Are edge cases and error handling addressed?

Before moving from implementation to documentation:
- Does the code match the design?
- Do all tests pass?
- Are there any TODO comments or known issues?

**Never skip the review of intermediate outputs** — errors compound across phases.
A small misunderstanding in the analysis becomes a design flaw, which becomes a
series of implementation bugs, which become stale documentation.

### Human approval at gates

The recommended workflow includes human approval gates between major phases.
The human should actively review and direct:
- **Major architectural choices** — the agent proposes, the human decides
- **Code quality and security** — the agent flags concerns, the human validates
- **Design decisions** — the agent presents alternatives with trade-offs, the human chooses
- **Phase completion** — the human confirms exit conditions are met before proceeding

---

## Testing and Validation

### Always give the agent a testing mechanism

Without a way to test and validate its own code, the agent produces work it cannot
verify. Errors accumulate silently until human review, at which point they are
expensive to fix.

**Effective strategies** (combine as appropriate):

| Strategy | Best for | Example |
|----------|----------|---------|
| Automated tests | Logic, APIs, data processing | `npm test`, `pytest`, `go test` |
| Bash scripts | CLI tools, build validation | `bin/test`, custom validation scripts |
| Browser integration | UI behavior, visual correctness | Chrome DevTools MCP for screenshot comparison |
| Type checking / linting | Catching errors statically | `tsc --noEmit`, `eslint`, `mypy` |

**Recommendation**: Set up at least one testing mechanism before starting implementation.
Define in the project rules which validation methods are available and when the agent
should use them.

### Test-driven implementation

Encourage the agent to:
1. Write tests alongside implementation (not as an afterthought)
2. Run the full test suite after each logical unit of work
3. Fix failing tests before moving to the next task
4. Report test results as part of phase completion

---

## Periodic Maintenance

### Architecture and code reviews

Every few development cycles (the exact frequency depends on your pace), step back and
run broader reviews:

- **Refactoring review** — Are there patterns that should be extracted? Code that has
  grown organically and needs restructuring? Duplicated logic that should be unified?
- **Architecture review** — Does the current implementation still align with the intended
  architecture? Have any shortcuts become structural problems?

### Documentation structure review

Documentation entropy is real. Over time, files accumulate, topics get covered in
multiple places, and the structure drifts from the implementation.

**Why this matters for agent quality**: The agent checks existing documentation before
starting new work (this is a framework-enforced behavior). When documentation is
disorganized or duplicated, the agent either fails to find relevant prior decisions
(and starts from scratch) or finds contradictory versions (and makes arbitrary choices).
Documentation maintenance is not just housekeeping — it directly determines whether the
agent builds on prior work or ignores it.

Periodically review:
- **File organization** — Does the directory structure still make sense? Should files
  be merged or reorganized? Organize by domain/topic so all information about a subject
  is discoverable in one place.
- **Duplication** — Are multiple files covering the same topic? Merge them. Duplicated
  content inevitably diverges, and the agent may read only one copy — acting on stale
  information while a correct version exists elsewhere.
- **Single source of truth** — Is every concept, decision, or plan described in exactly
  one file? If it needs to be referenced elsewhere, use links rather than copying content.
  A single roadmap, a single design doc per domain, a single set of conventions per topic.
- **Accuracy** — Does the documentation match the current implementation? Update or
  remove stale content. Outdated documentation is actively harmful — the agent may find
  and follow it.
- **Rule consistency** — Are rules across files contradictory or outdated? Prune
  aggressively.

### Roadmap as single source of truth

Maintain a single roadmap file (e.g., `docs/roadmap.md`) as the definitive source for
planned work, priorities, current status, and known issues. Update it at the end of each
development cycle. The agent checks this file before starting work — a current roadmap
prevents duplicate effort and ensures the agent knows what is planned, in progress, or
completed.

### CLAUDE.md freshness

The project CLAUDE.md should always reflect the current state of the project. After
significant implementation work, update it:
- Architecture section: still accurate?
- Key commands: still correct?
- Infrastructure details: still current?
- Known issues / current state: updated?

---

## Common Pitfalls

Patterns that consistently lead to poor results:

| Pitfall | Consequence | Prevention |
|---------|-------------|------------|
| Skipping reviews | Accumulated bugs and design drift | Always run at least 2 review passes |
| Not cleaning context | Later phases carry noise from earlier ones | Fresh session per phase. If mid-session drift occurs, `/clear` and re-state the objective with explicit document references |
| No testing mechanism | Silent error accumulation | Set up tests before implementation |
| Rules in too many small files | Contradictions emerge unnoticed | Group correlated rules (see [configuring-rules.md](configuring-rules.md)) |
| Not verifying intermediate artifacts | Errors compound across phases | Review every phase output before proceeding |
| No explicit maintenance policy | Agent wastes effort on legacy compat during MVP | Define breaking changes policy per project |
| Never reviewing docs structure | Agent finds stale/contradictory docs, acts on wrong info | Periodic docs review every few cycles |
| Too much autonomy | Architectural drift, unwanted changes | Clear human gates at phase transitions |
| Too little autonomy | Slow, needy agent that asks about everything | Define what can be decided autonomously |
| Asking too much in one prompt | Shallow, incomplete results across all areas | Decompose into focused tasks — one concern per prompt |

---

## Quick Reference: Session Checklist

### Starting a development session

1. Start with clean context (`cco start <project>` or `/clear`)
2. State the current phase and objective clearly
3. Reference the relevant input documents explicitly
4. Confirm the scope level (project, module, feature)

### During implementation

1. Follow the approved design — pause and discuss if changes needed
2. Write tests alongside code
3. Commit after each logical unit
4. Run the test suite frequently

### Closing a feature

1. Run `/review` — fix issues found
2. Run `/review` again — fix remaining issues
3. Run the full test suite
4. Verify all documentation is updated
5. Review intermediate artifacts against the design
6. Human review and approval
7. Merge to main
