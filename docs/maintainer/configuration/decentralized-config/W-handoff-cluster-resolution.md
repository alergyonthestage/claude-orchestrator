# W — Cluster-resolution handoff (post-V impl-readiness review)

**Status**: The impl-readiness review (gate **V**) is **DONE**. Findings are resolved **cluster by
cluster** with the maintainer; each agreed resolution is persisted into the ADRs/design/requirements
before moving on. **Clusters 1, 2 and 4 are RESOLVED & PERSISTED; Cluster 3 (doc-resync) Block A is
RESOLVED & PERSISTED — Block B rides the Phase-3 cutover (see §3c).** Only **Cluster 5** remains OPEN —
**next session = Cluster 5** (command surface & UX; clean session preferred). This file lets a **fresh
clean session** resume without losing the workflow results, the method, or the remaining work. Produced
2026-06-18 on branch `feat/vault/decentralized-config` (commits **local**, pushed from the maintainer's
Mac); updated 2026-06-19 (Cluster 3 Block A; Cluster 4).

---

## 1. What V produced (don't re-run it)

A multi-agent ultracode workflow (10 review lenses → adversarial verify → dedup → option analysis →
completeness critic; 59 agents) validated the **whole** decentralized-config scope. Output:

- **`reviews/18-06-2026-impl-readiness-review.md`** — the authoritative report: **58 findings** (1
  blocker, 20 high, 26 medium, 11 nit; 37 decisions) + 5 completeness-critic findings, each with
  location · issue · why · proposed resolution, and **principle-aligned options + a recommendation** for
  every decision-finding. The report's tail has a **Cluster Resolution Log** tracking what is resolved.
- **`reviews/18-06-2026-impl-readiness-review.json`** — the **raw machine-readable workflow output**
  (the source the `.md` was generated from; 59-agent run, `.result.findings`/`.options`/`.critic`/
  `.coverage`, verified byte-complete vs the report). Use it only to re-process/re-generate
  programmatically; the `.md` is the canonical human+agent-readable form.

**Do not re-run the workflow.** Read the report (`.md`). Resolve the remaining clusters against it.
(The per-agent execution transcripts are NOT persisted — they were session-scoped/ephemeral and are
process, not product; everything decision-relevant is in the report + this archive.)

## 2. Method (keep using this)

1. Take the next cluster. Present its decision-findings to the maintainer with the report's options +
   a recommendation. **Code-ground every claim** (read `bin/cco` / `lib/*.sh` — the V discussion proved
   several lens premises wrong by reading the code; e.g. profile-state shadows, enforced name uniqueness).
2. The maintainer decides/refines. **Persist nothing without explicit approval.**
3. On approval, persist into the ADRs/design.md/requirements.md (docs in **English**), keep
   cross-references consistent, annotate the report's Cluster Resolution Log, then **commit** (atomic,
   on `feat/vault/decentralized-config`).
4. Adversarially verify before asserting (the V "security bug" was a false alarm caught this way).

## 3. Cluster 1 — RESOLVED & PERSISTED (reference for the pattern)

Persisted to: **new ADR-0021** (resource lifecycle: entry verbs / `cco forget` / F59 cleanup), ADR-0006
(raw-tar backup incl. `.git`+`profile-state/` → STATE; `cco init --migrate`; F43/F44; plaintext-at-rest),
ADR-0009 D6 (memory non-clobber, F11), ADR-0010 §5 (lazy+optional projects / atomic shared; F42 accepted
regression), design.md §7/§9/§11, requirements.md FR-M1/M2. Key outcomes + the 5 code-grounded
corrections are in the report's Cluster Resolution Log. Verbs decided: **`cco init --migrate [--sync]`**
(top-level `cco migrate` dropped), **`cco forget <project>`**, **`cco config validate [--fix]`** (orphan
sanitization, explicit/preview-first/never-automatic).

## 3b. Cluster 2 — Phasing & test-plan re-sync — RESOLVED & PERSISTED (2026-06-18, commit 0e640fb)

Closed `F2 F7 F35 F36` + **critic HIGH** (existing-suite teardown) + critic mediums **BL3** (per-mount
bucket map) and **secrets env-injection**. The **decisive maintainer directive**: now that the design is
closed, the **implementation order is not bound to the design's chronology** — re-derive it from
**dependency + reuse + open-closed** (build the most-reused substrate first; build every module **once**
in its final form; never schema-migrate a file twice). **Design and UX unchanged — only the build
order.** The "→ E" workstream is **dissolved** into a **6-phase dependency-layer map**: **0** substrate ·
**1** core-local · **2** migration · **3** legacy-cutover · **4** sharing-core · **5** sharing-ext.
Open-closed sharpened the report's recommendations: ALL coordinate schema+parsers (repos/llms **and**
packs) in Phase 0; the Phase-2 migration writes the complete final `project.yml` in one pass (no double
migration, F37 backfill); **H6 + M3 move to the Phase-0 substrate** (reused; M3 satisfies the Phase-5 S8
invariant by construction); H7→P0. §11 now carries the **categorized teardown** of the 35-file suite
(harness `helpers.sh`/`mocks.sh` migrates first in P0). Persisted: **design.md §9/§11 rewritten** +
§6.2/§12 xrefs; analysis-roadmap (E dissolved + mermaid + sequence); inventory items 2/3/5/6 phase-homes;
review Cluster-Resolution-Log. *(The critic mediums spec.md/architecture.md FR-staleness + roadmap/
inventory ADR-range are doc-drift → handled in **Cluster 3**.)*

## 3c. Cluster 3 — Doc drift / re-sync — Block A RESOLVED & PERSISTED (2026-06-19)

**Policy fixed first** and persisted as the repo rule **`.claude/rules/documentation-lifecycle.md`**:
three doc classes — **decision/analysis history** (ADRs/reviews/analyses: immutable, superseded +
forward-annotated, never rewritten) · **living design/architecture docs** (rewritten to current truth in
place, **no inline "superseded" sections**; history in git) · **removed-feature design docs** (archived
at cutover, not bannered, not deleted). Update-**timing** discriminator: **design-intent docs → now**;
**shipped-behavior docs → ride the phase that makes them true / the cutover sweep** (never rewrite ahead
of the code). This **supersedes the review's F30 option-A in-place-banner recommendation** with an archive
policy. Cluster 3 added **no new ADR** (the policy is a rule, not an ADR).

**Block A — persisted now** (commits `ca18919`, `0b735db`, `85cdd9b`):
- `requirements.md` (F3) re-synced (tags → DATA internal `<data>/cco/tags.yml`; `cco index refresh --scan`
  → `cco resolve --scan`; ADR range 0001–0021; publish/install → 2×2; `cco migrate` → `cco init
  --migrate`); `design.md §1` (F24) relabelled; ADR-0002 (F22) + ADR-0014 D2 (F23) forward-annotated
  (decision text kept verbatim).
- `resource-coherence-inventory.md` **completed** as the cutover-sweep driver: A.4 `internal/tutorial`
  (F21), C.0 repo-root README (F20), C.6 docs index pages (F31); `concepts.md`/`knowledge-packs.md`
  C4→C3 (F33); `spec.md` C4→C2 FR-level (critic); legend + cross-cutting pattern #5 for "Config Repo"→
  sharing-repo (F32); **Section D** maintainer-design archive (F30); ADR-range nits. Review
  Cluster-Resolution-Log updated.

**Block B — deferred to the Phase-3 cutover** (shipped-behavior docs): the actual rewrites of `README.md`,
the user guides, `internal/tutorial`, `concepts.md`/`knowledge-packs.md`, `spec.md`/`architecture.md` FRs,
the four docs index pages, the ~43-occurrence "Config Repo" sweep, and the Section-D `_archive/` move. All
inventoried; none can be rewritten ahead of the code without misdescribing what currently ships.

## 4. Clusters still OPEN (the work remaining)

Finding IDs reference the report. Present per cluster, decide, persist. **Next = Cluster 5.**

- **Cluster 3 — Doc drift / re-sync — Block A RESOLVED & PERSISTED (2026-06-19; see §3c).** Design-intent
  docs re-synced (`F3 F22 F23 F24`) + inventory completed as the cutover-sweep driver (`F20 F21 F30 F31
  F32 F33` + spec.md/roadmap/inventory critic). **Block B** = the user-facing rewrites those inventory
  items describe, **deferred to the Phase-3 cutover** (shipped-behavior; never ahead of code).
- **Cluster 4 — Coordinate model & resolution — RESOLVED & PERSISTED (2026-06-19).** All 15 findings
  (`F4 F6 F14 F15 F16 F17 F29 F37 F38 F39 F40 F41 F45 F48 F56`) resolved → **new ADR-0022** (6 new
  decisions: source-relocation/publish_target · global-flat index/H7 · `--scan` upsert · pack
  cache-iff-coordinate+ERROR · pack STATE `base/`/sync-before-publish · `--check` 3-state) + forward-
  annotations to ADR-0016/0017/0018/0019 + design.md re-sync (§2.2–§12) + requirements FR-Y-S6. Phasing
  re-read onto the Cluster-2 P0–P5 map (no renumber). See the review's Cluster-4 Resolution Log for the
  full per-finding outcomes + the 4 maintainer-confirmed forks.
- **Cluster 5 — Command surface & UX** (ux/both): `F13 F18 F19 F25 F26 F27 F34 F46 F47 F49 F50`. Owns the
  exact **`cco config validate` contract** (F26) referenced by ADR-0021, the `cco config` namespace
  coherence (F46), coordinate-add verbs `cco repo/llms add` (F19), `cco new` (F18), template sharing
  symmetry (F47), `internalize` semantics clash (F13). Agent-3's command-symmetry analysis (current vs
  new verb table, entry-points category, project-removal philosophy) feeds this cluster. **Launch pad:
  `X-handoff-cluster5-command-ux.md`** (groups, reference docs per finding, the Cluster-4 carry-ins the
  command surface must wire, likely ADR-0023 shape).

## 5. Reading order for the fresh session

1. `guiding-principles.md` (P1–P17). 2. **This file.** 3. `reviews/18-06-2026-impl-readiness-review.md`
(esp. the target cluster's findings + the Cluster Resolution Log; the sibling
`…review.json` is the raw machine-readable source if needed). 4. The ADRs the cluster touches
(latest first: 0021, 0020→0016, then the refinement chains). 5. Code grounding for the cluster
(`bin/cco`, the relevant `lib/*.sh`). 6. `design.md` sections the cluster edits.

## 6. Preference

Tackling Cluster 4 (or any further cluster) in a **fresh clean session** is preferred (context hygiene);
this handoff + the report + the persisted ADRs carry everything forward.
