# Review Playbooks — recurring review types (TEMPORARY staging doc)

> **Status: temporary staging copy.** The maintainer runs these reviews across projects and
> will promote them to the **`cave` knowledge pack** (and likely to invocable `/cmd` slash
> commands in a project's local `.claude/`) **after** the decentralized-config migration ships.
> Until then this file is the cross-session reference: a review session can read it and run the
> matching playbook. **Do not over-invest here** — it is meant to be migrated, then deleted.
>
> Source of these definitions: maintainer brief (2026-06-25). The decentralized-config
> **implementation review** already has a fuller, project-specific playbook at
> [`configuration/decentralized-config/implementation-review-handoff.md`](../../configuration/decentralized-config/implementation-review-handoff.md);
> this file generalises it and adds the other three types.

Each review is run in its **own clean session** (different scope ⇒ different context), is
**read-only** with respect to production code unless the maintainer approves changes, and opens
by reading the project's source-of-truth (design/ADRs/principles + `.claude/rules/`).

---

## 1. Implementation review

- **When**: at the end of one or more development/implementation sessions — including between
  phases of the same sprint.
- **Goal**: verify the implementation **adheres to the reference design**, is free of bugs/issues,
  and is **complete**. Identify divergences of the implementation from the design, and any gaps or
  implementation errors to fix. Verify the **tests** are aligned with the design and requirements —
  that they do **not** endorse incorrect behaviour and do **not** hide false positives.
- **Project reference**: the recurring, code-grounded adherence/coherence playbook in
  `configuration/decentralized-config/implementation-review-handoff.md` (Transitional Registry,
  four-state classification, parallel read-only lenses → adversarial verify → gap report).

## 2. Documentation review

- **When**: **after** the implementation review for one or more development sessions; or after N
  development cycles / at the end of a development cycle (sprint).
- **Goal**: find **stale docs** to update; verify that **all** documentation reflects the reference
  design and is coherent with the real code/implementation, architecture, and design. Check related
  resources and docs: user guides, guidelines, designs of other modules that reference this one.
  Surface the docs to **update, correct, modify, or remove/archive**.
- **Project reference**: the doc-lifecycle policy `.claude/rules/documentation-lifecycle.md`
  (history vs living vs archived doc classes; design-intent-now vs shipped-behavior-at-cutover timing), and
  the decentralized-config v1 pre-merge instance
  `configuration/decentralized-config/documentation-review-handoff.md` (whole-doc-landscape scope, the
  now-due shipped-behavior cutover sweep, doc-coherence lenses, candidate work-list).

## 3. Refactoring review

- **When**: at the end of a significant development cycle (sprint) — a package of N related features —
  or at the end of developing a new version to publish.
- **Goal**: evaluate the design and implementation against software-engineering and good-programming
  principles. Identify **duplicated** functionality/responsibility, components with **multiple mixed
  responsibilities**, and modules/features that are hard to **extend, maintain, or reuse**. Propose
  programming patterns / design techniques to refactor the architecture or component design for
  maintainability, extensibility, reuse, testability, and other desired code qualities.
- **Principles**: S.O.L.I.D., DRY (Don't Repeat Yourself), Open/Closed, KISS, YAGNI.

## 4. UX-UI review

- **When**: on the user-facing surface — CLI, UI, API endpoints, etc.
- **Goal**: verify the UX is **frictionless** and coherent with the application's goals, understandable
  by users, and that the interface exposes the information users need **without** leaking internal
  details irrelevant to the user. Checklist:
  - **Symmetry & learnability** of commands/verbs and their actions on the surface — similar verbs map
    to the same action/meaning; avoid ambiguity/confusion.
  - **No multiple paths** to the same action via different commands, unless an explicit, documented
    reason differentiates them.
  - **Completeness**: operations that are implemented and useful/necessary to the user are correctly
    exposed by the UI. Find features that are implemented but **not reachable/usable** from the interface.
  - **Explicit confirmation** of destructive or sensitive actions, to reduce accidental unwanted actions.
  - **Simple onboarding**, scoped to only the necessary data/information.
  - Before performing/confirming an action, the user receives **all relevant information** to act consciously.

---

## Notes

- These four are not mutually exclusive within a release: a typical pre-release flow is
  implementation review → documentation review → refactoring review → UX-UI review (each its own session).
- Promotion path (post-migration): fold into the `cave` pack as reusable assets; optionally expose as
  `/review-impl`, `/review-docs`, `/review-refactor`, `/review-ux` commands in a project's `.claude/`.
