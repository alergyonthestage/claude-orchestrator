# Owner Preferences — Rules, Workflow & Configuration

> Personal preferences, rules, configurations, and workflow practices that the project
> owner has found effective through experience with claude-orchestrator. These serve as
> input for writing the recommended user guides and default rules.
>
> Date: 2026-03-15

---

## Development Workflow (Human Behavior)

These are practices for the **human developer** driving claude-orchestrator, not rules
written into configuration files.

### Context Management

- **Clean context frequently** — start fresh sessions for each phase/step. Each phase
  should operate with clean context, receiving only the defined inputs.
- Treat each phase as a session of the agent with its own objective, rules, and I/O.

### Review Cycles

- **Run reviews after every development cycle.** A single pass is rarely sufficient.
  Typically 2-3 review + bug-fix iterations are needed to reach good implementation quality.
- Review types to run after each implementation cycle:
  1. **Alignment review**: verify implementation matches the design documents
  2. **Bug hunting**: identify critical bugs and edge cases
  3. **Docs review**: ensure no stale documentation, all references updated to new design
  4. **Test review**: verify sufficient test coverage and completeness
- **Always execute before considering a feature closed and complete.** The second review
  frequently catches implementation errors that were missed during coding.
- Consider periodic **refactoring reviews** and **architecture optimization analyses**.

### Periodic Maintenance Reviews (Long-term)

Beyond code refactoring, every N development cycles perform broader maintenance reviews:
- **Documentation structure review**: evaluate if docs need re-organization, merge files that
  cover the same topics, verify docs are up-to-date with the current implementation
- **Rule consistency check**: verify that rules across files are not contradictory or stale
- The goal is to prevent documentation drift and structural entropy over time

### Validation and Testing Strategy

- **Always give Claude a way to test and validate its own code.** The specific method depends
  on the project, but valid strategies include (also in combination):
  - **Automated tests** (unit, integration, e2e)
  - **Bash scripts** for quick validation of CLI tools or build outputs
  - **Browser integration** (via Chrome DevTools MCP) to verify final UI behavior
- Without a validation mechanism, Claude produces code it cannot verify, leading to
  accumulated errors that only surface during human review

### Human in the Loop

- The human must always control and direct:
  - Major architectural choices
  - Code quality and security decisions
  - Compliance and conformity requirements
  - Principal design decisions
- Human in the loop + automated reviews **drastically improve result quality** and prevent
  accumulation of bugs and errors.
- Every development cycle must conclude with: automated testing + human testing and verification.

### Verification Between Phases

- **Always verify in detail all intermediate artifacts between phases.** The reference
  documents are the analysis and design documents created in earlier phases.
- Never skip the review of intermediate outputs — they compound errors if left unchecked.

---

## Workflow Phases (State Machine)

The preferred workflow is not strictly linear. It resembles a state machine with cycles
and backward edges:

### Phases

1. **Analysis** → Understand requirements, explore codebase, identify constraints
2. **Design** → Propose architecture, interfaces, data models
3. **Implementation** → Write code and tests following approved design
4. **Testing** → Run tests, verify coverage, validate behavior
5. **Documentation** → Update all relevant docs
6. **Review** → Automated + human review

### Transitions and Conditions

- Each phase has defined **exit conditions** to determine completion
- Review gates between major phases (analysis→design, design→implementation)
- **Backward transitions**:
  - If tests fail → return to implementation for fixes
  - If review finds design misalignment → return to implementation or design
  - If review finds missing requirements → return to analysis
- Phase transitions are **manual** (require human approval) by default

### Phase Definition Requirements

Each phase/step should specify:
- **Rules and behavior**: what the agent should/shouldn't do during the step
- **Session objective**: clear goal for the phase
- **Model**: which model to use (future: per-phase model configuration)
- **Input**: required documents, files, resources with explicit paths
- **Output**: produced artifacts with explicit paths where to save them
- **Exit conditions**: when the phase is considered complete
- **Next phase logic**: conditions determining which phase follows

---

## Rule Configuration Preferences

### Grouping Principle

> **One rule file per decision domain. Correlated rules in the same file to avoid
> contradictions.** If two rules can conflict, they must be in the same file where
> the contradiction is visible and resolvable.

Rationale: In separate files it's harder to spot contradictory rules. Grouping by
topic (all "git" rules in one file, all "docs" rules in another) reduces the risk
of creating inconsistencies. Some cross-category risks remain (e.g., docs vs language)
but are acceptable.

### Rules vs. Knowledge Loading

> **Rules are always in context** — keep them short, focused, enforcement-oriented.
> **Knowledge and docs are loaded on-demand** — put detailed guidelines, examples,
> and reference material in knowledge docs or packs.

A rule should be a directive (2-3 lines), not a detailed explanation. Comprehensive
guidelines belong in documentation that the agent reads when relevant.

### Packs as Single Source of Truth

When a resource (rules, skills, agents, knowledge) must be shared across multiple
projects, always define it in a **pack**. Never copy/paste between projects. A pack
ensures a single source of truth: update once, all projects using it receive the update.

### Preferred File Organization (4 files)

| File | Content |
|------|---------|
| `workflow.md` | Phases, state machine transitions, human-in-the-loop rules, exit conditions, phase I/O |
| `documentation.md` | Docs directory structure, file positioning, format conventions, Mermaid usage, versioning |
| `git-practices.md` | Branch strategy, commit conventions, merge flow, PR conventions |
| `language.md` | Languages for code, documentation, and communication |

### Scope Preferences

- **Managed**: only framework infrastructure (hooks, memory-policy, deny rules)
- **Global defaults**: minimal starting points that users customize
- **User guides**: detailed best practices and recommendations
- **Project-level**: project-specific rules (architecture, stack, coding guidelines)
- Skills for workflow phases → **global defaults** (not managed), users can customize

### Documentation Structure Preferences

- `/docs` for development files
- External MCP systems (e.g., Docmost) for cross-project/org documentation
- `/docs` organized by directory:
  - `user-guides/` — operational how-tos
  - `maintainer/` — architecture, decisions, design docs
  - `maintainer/decisions/` — ADRs
- Maintainer docs organized by **feature/module/business domain**, not by document type
- Final documents named by type: `analysis.md`, `design.md`, `adr-NNN.md`, `review.md`

### Git Preferences

- Specify the full flow and merge direction between branches
- Merges = human review points and PRs
- Commits = automated by LLM
- Atomic, working-state commits with conventional commit format
- Branch naming: `<type>/<scope>/<description>`

### Language Preferences

- Communication with human: Italian
- Documentation: English
- Code, comments, identifiers: English

### Maintenance Philosophy

- During MVP/early development (no users, no production):
  - Breaking changes are allowed and **preferred** over maintaining legacy code
  - Eliminate legacy code rather than keeping backward compatibility
  - No documentation archival — rely on git for versioning
- During production (with users):
  - Evaluate backward compatibility carefully
  - Consider archival strategy for superseded docs
- **Regular refactoring reviews** to optimize architecture and encourage good
  software engineering patterns (reuse, maintainability, optimization)

### Skills Beyond Workflow Phases

Skills are not limited to workflow phase entry points. They are one of Claude's most
powerful and widely-used mechanisms. Two conceptual categories:
- **Capability upskill**: teaches Claude new abilities (frontend design, document
  generation, framework-specific patterns). May become obsolete as models improve.
- **Encoded preference**: captures repeatable workflows and processes (sprint planning,
  code review methodology, analysis templates). Stays relevant regardless of model.

cco should promote and guide skill creation as a core practice, not just for phases.
Skills complement rules (always-on behavior) and knowledge (on-demand reference).

### Permission Modes per Phase

- **Plan mode** for analysis and design phases — agent proposes, human reviews
- **Skip permissions** for implementation — after approved design, let the agent work freely
- **Accept edits** for sensitive operations — line-by-line control when needed
- Key insight: when analysis and design are thorough and reviewed, implementation is
  frequently correct on the first pass (1-2 review iterations for bug fixes)

### Human in the Loop Preferences

- **Requires human approval**:
  - Phase transitions in the workflow
  - Architectural decisions
  - Breaking changes to public APIs
  - Security-sensitive changes
- **Can be decided autonomously by LLM**:
  - Implementation details within approved design
  - Bug fixes within existing architecture
  - Documentation updates
  - Test writing
- **Autonomous decision process**: always perform preventive analysis, evaluate
  alternatives against existing architecture, user intent, implementation complexity,
  and pros/cons of each approach
- **Human review request process**: always provide preventive analysis, full context,
  and recommended solution with alternatives

---

## Observations and Lessons Learned

### What Works Well

1. **Phase-based workflow with clean context** — prevents context pollution and keeps
   each session focused
2. **Multiple review passes** — the second review almost always finds issues the first
   missed
3. **Explicit I/O per phase** — prevents the "where did that design doc go?" problem
4. **Correlated rules in same file** — significantly reduces contradictory instructions
5. **Minimal defaults + detailed guides** — respects user autonomy while sharing knowledge
6. **Human in the loop at phase transitions** — catches direction errors early
7. **Giving Claude a testing mechanism** — self-validation drastically reduces error accumulation
8. **Periodic docs structure reviews** — prevents documentation drift and file duplication

### Common Pitfalls to Document

1. **Skipping reviews** — leads to accumulated bugs and design drift
2. **Not cleaning context** — later phases carry noise from earlier ones
3. **Rules in too many small files** — contradictions emerge unnoticed
4. **Opinionated defaults that are too heavy** — users feel constrained, delete everything
5. **Maintenance policy not explicitly declared** — LLM defaults to conservative backward
   compatibility even during MVP phase, wasting effort on legacy support
6. **Not verifying intermediate artifacts** — errors compound across phases
7. **No testing/validation mechanism for Claude** — code is produced but never verified,
   bugs pile up silently until human review
8. **Never reviewing docs structure** — files accumulate, duplicate, and drift from
   implementation over time
