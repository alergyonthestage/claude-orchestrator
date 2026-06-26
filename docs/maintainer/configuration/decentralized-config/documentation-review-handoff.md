# Documentation-Review Handoff — decentralized-config v1 (pre-merge, step 2)

**Status**: Self-contained launcher for the **documentation review** — **step 2** of the maintainer's
pre-merge review cycle (impl review → **docs review** → refactoring review → UX-UI review → dogfooding →
merge/release v1). It surfaces **stale, incoherent, mis-placed, or missing documentation** across the whole
project and brings every doc into line with the **shipped** code + the frozen design. Runs in its **own
clean session**, opening by reading `guiding-principles.md` (P1–P18) **and this file**.

> **State at hand-off (2026-06-26):** decentralized-config **v1 BUILD COMPLETE** (P0–P5 closed) ·
> **step-1 implementation review DONE** (`reviews/25-06-2026-impl-adherence-review.md`) · **pre-merge fix
> backlog F1–F5 ✅ RESOLVED** (`pre-merge-fix-handoff.md`; 6 commits LOCAL, merge-gate cleared) ·
> **deep migration/decentralized-config implementation review DONE + ALL FINDINGS RESOLVED 2026-06-26**
> (`reviews/26-06-2026-migration-impl-review.md` + its Resolution log; 2 BLOCKER + 7 HIGH + 10 MEDIUM +
> all LOW/NIT, 19 commits `d136344`→`738973e`; notably H7 fixed a latent bug where migrated memory landed
> off the session mount, and M2/M3 were closed as verified no-op). The CODE is now believed correct &
> complete for the migration flow — so the shipped-behavior the docs must match is stable. Baseline
> **905/0** (`CCO_ALLOW_HOST_RESOLVE=1 ./bin/test`). Branch `feat/vault/decentralized-config`, commits
> **LOCAL** (maintainer pushes from Mac). ADRs **0005–0027**; next free ADR **0028**.

> **This session is read-mostly.** Like the impl review it produces a **findings report** and then applies
> the **maintainer-approved** doc fixes (docs are not production code; the doc-lifecycle rule §3 gives clear
> guidance, so fixes can be applied in-session cluster-by-cluster *with confirmation*, or staged into a
> report first — maintainer's call). **It does NOT touch production code, re-open settled design, or
> implement features.** Phase transitions need maintainer go-ahead (`.claude/rules/workflow.md`).

---

## 0. TL;DR

The build is done and **shipped-behavior is now true**, so this is the moment to run the **shipped-behavior
doc sweep** that the doc-lifecycle rule deliberately *deferred* during the build (`don't rewrite a guide to
a command that doesn't exist yet`). Verify every doc against the **real CLI / real paths / real behavior**;
rewrite **living** docs to the current truth; **archive** removed-feature docs; fix **cross-references**;
and do the **structure/discoverability reorg** the maintainer wants for the main docs. A concrete
starting work-list (already surfaced across the build) is in **§5** — but the review must be exhaustive,
not limited to it.

---

## 1. Reading order

1. `guiding-principles.md` (**P1–P18**) — the law the docs must not contradict.
2. **This file.**
3. `.claude/rules/documentation-lifecycle.md` — **the governing policy** (3 doc classes + timing). §3 below
   distils it; read the rule itself.
4. `../../review-playbooks.md` **§2 (Documentation review)** — the generic playbook this instantiates.
5. The structural sibling `implementation-review-handoff.md` (the recurring impl playbook) — reuse its
   method (parallel lenses → adversarial verify → report), retargeted from code-conformance to doc-coherence.
6. The **source-of-truth** docs the rest must agree with: living `design.md`, `requirements.md`,
   `guiding-principles.md`, and ADRs `decisions/0005`–`0027`.
7. The **shipped surface** to check docs against: `bin/cco` + `lib/*.sh` (the real verbs/flags/paths), and
   `CCO_ALLOW_HOST_RESOLVE=1 ./bin/test` green at 897/0 (proves the behavior the docs must describe).
8. The personal progress note `decentralized-config-impl-progress.md` (tail = latest cursor) for what
   changed last (F1–F5) and the running list of deferred doc items.

**Precedence when docs disagree**: `guiding-principles.md` P1–P18 → ADRs 0005–0027 → `design.md` →
`requirements.md` → shipped-behavior guides. Record any reconciliation; do not silently pick one.

---

## 2. Goal & what this review produces

**Goal (playbook §2):** find **stale docs** to update; verify that **all** documentation reflects the
reference design and is **coherent with the real shipped code**, architecture, and design — including user
guides, guidelines, and the **designs of other modules that reference this one**. Surface every doc to
**update · correct · modify · remove/archive · reorganize**.

**Produce:**
- A **doc-coherence findings report** at `reviews/<DD-MM-YYYY>-doc-review.md` — per finding: *location
  (`path:line`) · observed (what the doc says) vs expected (what the code/design actually is) · doc class
  (history / living / shipped-behavior / archived) · action (update / correct / archive / reorg / leave) ·
  severity*. Group into clusters for cluster-by-cluster resolution (the Cluster-3 / pre-merge-fix model).
- The **applied fixes** for each maintainer-approved cluster (living rewrites in place; shipped-behavior
  corrections; archive moves via `git mv`; cross-reference repairs), each an **atomic commit**, LOCAL.
- **Roadmap + progress-note** refresh (step-2 status; what was corrected/archived/reorganized).
- A **HITL list** for anything not derivable from the spec: a doc↔doc contradiction, a structure/reorg
  decision that changes navigation, or an "is this doc still wanted?" call.

---

## 3. The governing law — doc-lifecycle (3 classes + the timing flip)

From `.claude/rules/documentation-lifecycle.md`:

| Class | Examples | What this review does |
|---|---|---|
| **History** (decision/analysis records) | ADRs (`decisions/`), `reviews/`, role-first analyses | **Do NOT rewrite** the decision text. If a later decision superseded one, ensure it carries a **forward-annotation**. Otherwise leave. |
| **Living** (design/architecture) | `design.md`, `requirements.md`, `architecture/spec.md` + `architecture.md`, integration designs, user guides | **Rewrite in place to the current/target truth** — no "SUPERSEDED" banners accumulate inside them; git holds the history. |
| **Archived** (removed-feature design with no living successor) | already moved: `_archive/{vault,sharing,resource-lifecycle}/` | If a new removed-feature doc surfaces, **`git mv` to `_archive/`** at cutover (don't delete; don't banner). |

**The timing flip — why NOW.** The single discriminator is *what a doc describes*. **Design-intent** docs
were kept current during the build. **Shipped-behavior** docs (README, guides, tutorial, `spec.md` FRs,
`cli.md`) were deliberately **NOT** rewritten ahead of the code (a guide that documents a command before it
exists "lies in the opposite direction"). **The code is now shipped (v1 build complete + F1–F5).** So this
review is exactly the **consolidated cutover sweep** the rule schedules: shipped-behavior docs must now be
brought to match the real CLI/paths/behavior. Never the reverse — if a doc describes something the code does
*not* do, the doc is wrong (fix the doc), unless it is clearly a 🚧-planned marker for a deferred feature.

---

## 4. Scope — the whole doc landscape (decentralized-config is the lens)

Audit **every** doc; the refactor is the lens for *what changed*. Trees and what to check:

| Tree | Class | Check against |
|---|---|---|
| top-level `README.md`, `CLAUDE.md` | living/shipped | the 4-bucket model, `<repo>/.cco` homes, the real verb list, `~/.cco`+CACHE pack/template/llms homes (**F1**) |
| `docs/getting-started/` | shipped-behavior | the real `cco init`/`join`/`start` flow + onboarding |
| `docs/reference/` (`cli.md`, `context-hierarchy.md`) | shipped-behavior | every documented verb/flag exists in `bin/cco`/`lib`; 🚧 markers only for genuinely-deferred verbs |
| `docs/user-guides/` (+ `advanced/`) | shipped-behavior | `configuration-management.md`, `project-setup.md`, `agent-teams.md`, `subagents.md`, tutorial — paths/commands match shipped code |
| `docs/maintainer/architecture/` (`spec.md`, `architecture.md`, `coding-conventions.md`, `security.md`) | living | FRs/ADRs reflect the shipped decentralized model; the P4-doc rewrites are coherent |
| `docs/maintainer/integration/` (`docker/`, `browser-mcp/`, `auth/`) | living | **browser-mcp/design.md deep layout rewrite (the one logged item, §5)**; docker/design `build.context`; auth/design |
| `docs/maintainer/configuration/` — **`decentralized-config/`** (design.md, requirements.md, guiding-principles.md, analysis-roadmap.md, resource-coherence-inventory.md, RD-*, the handoffs, `reviews/`, `decisions/` ADRs) | living + history | **internal coherence** of the source-of-truth set; ADR forward-annotations intact; consumed handoffs removed/banner-correct |
| `docs/maintainer/configuration/update-system/` | living | the canonical file-policy/changelog/migration docs match the engine |
| `docs/maintainer/configuration/_archive/` | archived | the redirect pointers still resolve; nothing live still depends on an archived path |
| `docs/maintainer/decisions/roadmap.md` | living (project-tracking) | **§73 mega-block consolidation/reorg (§5)**; status current to step 2 |
| `docs/maintainer/internal/` | living | accuracy |
| the various `CLAUDE.md` (`templates/project/base/`, `defaults/managed/`, `defaults/global/`, `internal/{tutorial,config-editor}/`) | shipped | reflect the decentralized model; **managed `memory-policy.md` needs `cco build`** to bake (§5) |

---

## 5. Known candidates / starting work-list (NOT exhaustive — the sweep must go wider)

Already surfaced across the build (roadmap "Post-v1 backlog" + per-phase deferred notes + the progress
note). Treat as the seed list, then sweep for more:

1. **`browser-mcp/design.md` deep layout rewrite** — the one **logged doc-coherence item**. It still
   describes the pre-refactor layout below a "current-layout" note: generated file renamed
   `browser-mcp.json` → **`browser.json`** (`cmd-start.sh:467`); central `projects/<name>/` → **CACHE**
   `<cache>/cco/projects/<name>/managed/`; single-file mount → whole `managed/` dir
   **`/workspace/.managed:ro`** (`cmd-start.sh:694`). Origin = the Commit-B/T8 managed→CACHE consolidation,
   not P5. The current-layout note governs it; the **full rewrite** is this review's job.
2. **Global `decisions/roadmap.md` §73 mega-block** — a huge stratified single-line status block ripe for
   **consolidation/restructure** for discoverability (the maintainer flagged structure/organization reorg
   of the main docs as part of this review).
3. **`review-playbooks.md` → `cave` knowledge pack** — it is a TEMPORARY staging doc; its promotion to the
   `cave` pack (and optional `/review-*` slash commands) is **post-migration**, but verify the plan is
   recorded and the doc is correctly marked temporary.
4. **Maintainer notes from the P3-5 close-out (non-blocking, verify/resolve):**
   - `integration/docker/design.md` `build.context: ../../` may now be inconsistent with the layout.
   - `cli.md` has no `cco template update` subsection (F3 added a 🚧 note in `configuration-management.md`;
     check `cli.md` is consistent — `cco template update` is **deferred**, must read 🚧 everywhere).
   - managed `defaults/managed/.claude/rules/memory-policy.md` was updated to vault→STATE but **needs
     `cco build`** to bake into the image (note the build dependency where relevant).
5. **F1 homes propagation** — packs/templates now live in **`~/.cco/{packs,templates}`** and llms content in
   **CACHE**; sweep shipped-behavior docs for any residual `user-config/` path mention or a stale
   "packs live under …" statement. (Design docs were already correct — F1 aligned code *to* design.)
6. **Re-verify the 24+ user-facing docs rewritten in P3-5** (`141e24e`: README, cli.md,
   configuration-management, context-hierarchy, architecture, docker/design, spec FRs, getting-started,
   project-setup, knowledge-packs, index READMEs, repo CLAUDE.md) — they were written mid-cutover; confirm
   they are still accurate after **P4, P5, and F1–F5** (e.g. removed verbs, the validate/forget/coords
   surface, the `~/.cco`/CACHE homes).
7. **Stale dev artifacts in the repo tree** — `user-config/global/` and `user-config/projects/{…}` exist in
   the working tree (old central-layout dev output, default `$CCO_USER_CONFIG_DIR`). **Check whether they
   are git-tracked**; if so they are stale and should be gitignored/removed (HITL — it touches the repo, not
   just docs).
8. **Cross-reference integrity** — after the `_archive/` moves and handoff removals, hunt **dangling links**
   (a live doc pointing at a moved/removed path) and **forward-annotation gaps** in superseded ADRs.
9. **Terminology coherence** — "Config Repo" → **sharing repo** / **config bucket** (ADR-0018 D1); confirm
   no residual old nomenclature in shipped docs.

---

## 6. Method (reuse the impl-review methodology, retargeted to docs)

May be a **multi-agent workflow** (parallel doc-coherence lenses → adversarial verify → dedup → cluster →
report) or a single session for a lighter pass. Either way:

- **Code-ground every claim** (P10): a doc statement is "stale" only if it disagrees with `bin/cco`/`lib`
  (the real verb/flag/path/behavior) or the source-of-truth design/ADR — cite `path:line` on **both** sides
  (doc ↔ code/design). Line numbers drift; re-read.
- **Run doc lenses in parallel**, each blind to the others:
  1. **Shipped-behavior accuracy** — does every command/flag/path a guide shows actually exist and behave so?
  2. **Living-doc truth** — do `design.md`/`requirements.md`/architecture reflect the *shipped* model?
  3. **Source-of-truth internal coherence** — within decentralized-config (design ↔ requirements ↔ ADRs ↔
     guiding-principles); forward-annotations present where superseded.
  4. **Cross-reference & archive integrity** — no dangling links; `_archive/` redirects resolve; consumed
     handoffs removed/bannered.
  5. **Terminology / nomenclature** — consistent vocabulary (sharing repo, the 4 buckets, the verbs).
  6. **Structure / discoverability** — is the information findable; does a tree need reorg (roadmap §73)?
- **Adversarially verify** each finding (is the doc *really* wrong, or is the code the outlier?), **dedup**,
  **classify** (history/living/shipped/archived), assign an **action**, and **cluster**.
- A **completeness critic** closes the pass: *which doc tree / CLAUDE.md / reference was not opened; which
  claim was asserted from memory not re-read?* Its output is the next round.

---

## 7. Out of scope (do NOT do here)

- **Production code changes** — this is a docs pass. A doc finding that reveals a *code* bug is recorded as a
  HITL note for the refactoring/UX review, not fixed here.
- **The 13 optimization/duplication flags** (the impl review's lens-9 backlog) — owned by the **refactoring
  review** (review-cycle step 3).
- **UX-UI concerns** (verb symmetry, reachability, confirmation prompts) — owned by the **UX-UI review**
  (step 4). A doc review may *note* a UX smell as a HITL hand-off, not act on it.
- **Re-opening settled design**; adding features; rewriting a doc to a model the shipped code does not expose
  (that is the inverse lie the doc-lifecycle rule forbids).
- The **personal memory/progress notes** are not repo docs — keep them current as working notes, but they
  are not part of the published doc set under review.

---

## 8. After the review — close the loop

1. Write the findings report (`reviews/<date>-doc-review.md`), clustered.
2. Apply the maintainer-approved fixes per cluster (atomic commits, LOCAL; living-rewrite in place /
   shipped-behavior correction / `git mv` archive / cross-ref repair / reorg).
3. **Update** `docs/maintainer/decisions/roadmap.md` (step-2 status) + the progress note
   (`decentralized-config-impl-progress.md`) + this handoff's status banner.
4. **Resolve HITL flags** with the maintainer before acting on them.
5. **Next (pending maintainer go-ahead — never auto-advance):** review-cycle **step 3 = refactoring /
   optimization review** (consumes the 13 optimization flags) → step 4 UX-UI → dogfooding e2e on Mac
   (`P2-dogfooding-validation.md`) → merge / release v1.

---

## 9. Reference paths

- **Generic playbook**: `../../review-playbooks.md` §2 (Documentation review)
- **Structural sibling (method source)**: `implementation-review-handoff.md`
- **Governing policy**: `.claude/rules/documentation-lifecycle.md`
- **Step-1 review (just completed)**: `reviews/25-06-2026-impl-adherence-review.md`
- **Pre-merge fixes (just completed)**: `pre-merge-fix-handoff.md` (F1–F5 RESOLVED banner)
- **Source of truth**: `design.md`, `requirements.md`, `guiding-principles.md` (P1–P18), ADRs
  `decisions/0005`–`0027`
- **Roadmaps**: global `docs/maintainer/decisions/roadmap.md`; `analysis-roadmap.md`
- **Cutover-sweep driver**: `resource-coherence-inventory.md`
- **Dogfooding (later step)**: `P2-dogfooding-validation.md`
- **Personal cursor**: memory `decentralized-config-impl-progress.md` (tail)
- **Rules**: `.claude/rules/{documentation,documentation-lifecycle,workflow,git-workflow}.md`

---

*Generated with Claude Code*
