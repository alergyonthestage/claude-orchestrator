# W — Cluster-resolution handoff (post-V impl-readiness review)

**Status**: The impl-readiness review (gate **V**) is **DONE**. Findings are resolved **cluster by
cluster** with the maintainer; each agreed resolution is persisted into the ADRs/design/requirements
before moving on. **Cluster 1 (migration safety) is RESOLVED & PERSISTED.** Clusters 2–5 are OPEN —
this file lets a **fresh clean session** resume without losing the workflow results, the method, or the
remaining work. Produced 2026-06-18 on branch `feat/vault/decentralized-config` (commits **local**,
pushed from the maintainer's Mac).

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

## 4. Clusters still OPEN (the work remaining)

Finding IDs reference the report. Present per cluster, decide, persist.

- **Cluster 2 — Phasing & test-plan re-sync** (`F2 F7 F35 F36` + **critic HIGH**: the existing 35-file
  `tests/` suite + `helpers.sh` old-schema harness has **no teardown plan** → the §9 "tests green per
  phase" invariant is unachievable; + critic mediums: entrypoint↔compose container-path contract, global
  secrets/OAuth env-injection re-point, spec.md/architecture.md FR-level staleness, roadmap ADR-range).
  §9 phases 0–3 predate the S/coordinate cycle and ADR-0021 — produce an updated phase map (note already
  left in design.md §11). **Recommended:** Phase 4 sharing-core + Phase 5 sharing-ext (report F2).
- **Cluster 3 — Doc drift / re-sync** (mostly mechanical `edit`s): `F3` (requirements.md residual stale
  spots beyond what Cluster 1 touched), `F20` (top-level README), `F21` (internal/tutorial subtree),
  `F22 F23 F24` (early-ADR forward-annotations), `F30 F31 F32 F33` (user-doc realignment + "Config Repo"
  →"sharing repo"), + critic: `spec.md`/`architecture.md`, roadmap/inventory ADR-range. Re-sync toward
  design.md; nomenclature pass.
- **Cluster 4 — Coordinate model & resolution** (technical): `F4 F6 F14 F15 F16 F17 F29 F37 F38 F39 F40
  F41 F45 F48 F56`. Schema/migration of coordinates, three-layer pack resolution, M3 remotes url/token
  split (intersects ADR-0021 delete-cascade), index atomicity/namespacing (H7).
- **Cluster 5 — Command surface & UX** (ux/both): `F13 F18 F19 F25 F26 F27 F34 F46 F47 F49 F50`. Owns the
  exact **`cco config validate` contract** (F26) referenced by ADR-0021, the `cco config` namespace
  coherence (F46), coordinate-add verbs `cco repo/llms add` (F19), `cco new` (F18), template sharing
  symmetry (F47), `internalize` semantics clash (F13). Agent-3's command-symmetry analysis (current vs
  new verb table, entry-points category, project-removal philosophy) feeds this cluster.

## 5. Reading order for the fresh session

1. `guiding-principles.md` (P1–P17). 2. **This file.** 3. `reviews/18-06-2026-impl-readiness-review.md`
(esp. the target cluster's findings + the Cluster Resolution Log; the sibling
`…review.json` is the raw machine-readable source if needed). 4. The ADRs the cluster touches
(latest first: 0021, 0020→0016, then the refinement chains). 5. Code grounding for the cluster
(`bin/cco`, the relevant `lib/*.sh`). 6. `design.md` sections the cluster edits.

## 6. Preference

Tackling Cluster 2 (or any further cluster) in a **fresh clean session** is preferred (context hygiene);
this handoff + the report + the persisted ADRs carry everything forward.
