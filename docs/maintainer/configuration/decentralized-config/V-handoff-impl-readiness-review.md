# V — Impl-readiness review: handoff for the next (clean) session

**Status**: Handoff scaffold for the **comprehensive design review (V)** of the *entire*
decentralized-config scope, run **before** implementation (E). Produced 2026-06-18 after the design was
CLOSED (R1–R4 + Cat-4 + M + S; ADRs 0001–0020; principles P1–P17). V runs in its **own clean session**,
opening by reading `guiding-principles.md` (P1–P17, source of truth) **and this file**.

> **Why V exists.** Every *design* analysis is done, but the design grew across ~20 ADRs and several
> refinement cycles (later ADRs refined earlier ones — e.g. 0014→0016→0017→0019). No pass has yet
> validated the **whole implementation scope as one coherent body**. V is a **read-only validation gate**:
> find inconsistencies, gaps, ambiguities, cross-ADR conflicts, and impl-readiness blockers **on paper**,
> where they are cheap to fix — before E starts. V does **not** write code and does **not** re-open
> settled decisions without cause (a clash with a principle is the defect to fix, in the doc).

---

## 1. What V must produce

A **validation report** (`reviews/<date>-impl-readiness-review.md`) with severity-ranked findings
(blocker / high / medium / nit), each: *location (file:line/ADR) · issue · why it matters · proposed
resolution*. Where a finding requires a decision (not just an edit), flag it for the maintainer. Net
output: a coherent, gap-closed, implementation-ready design — or a precise list of what to fix first.

## 2. Scope (the whole body to validate)

- **Principles**: `guiding-principles.md` (P1–P17).
- **ADRs**: `decisions/0001`–`0020` (esp. the refinement chains: 0010→0011→0015 tags; 0013→0015→0016
  internal/DATA; 0014→0016→0017→0019 coordinate model; 0012→0018 manifest/sharing; 0008→0020 perms).
- **Living docs**: `design.md` (esp. §2 layout, §3 index, §4 sync, §6 domains, §7 commands, §9 phases,
  §11 tests, §12 futures), `requirements.md` (AD*/FR*), `resource-coherence-inventory.md`,
  `analysis-roadmap.md`.
- **Code grounding** (P10): `bin/cco`, `lib/*.sh` (the real surface E will change), `tests/`.

## 3. Suggested review perspectives (run in parallel — one agent each)

Distinct lenses so each agent is blind to what the others surface (multi-modal sweep). Compose/adjust
as fits:

1. **Cross-ADR & principle coherence** — does any ADR contradict another or P1–P17? Are all
   *refinements* fully propagated (e.g. ADR-0014's central-registry hint corrected by 0016 — stated
   consistently everywhere; tag nature 0011 vs placement 0015)? Any decision clashing with a principle?
2. **design.md ↔ ADR ↔ requirements sync** — is `design.md` fully reconciled with all 20 ADRs? Hunt
   stale spots (we already found §6.2 was a placeholder; are there others — e.g. §5 `@local`, §9 phases
   predating S, §11 tests missing pack/sharing cases?). Are AD*/FR* in `requirements.md` current?
3. **Completeness / gaps** — resources/flows/commands designed but under-specified or missing: the
   pack-coordinate **schema + migration** shape; `cco config validate` exact contract; `cco config
   protect` contract; `export --bundle-packs` dependency-closure; `cco project internalize`;
   extra_mounts `target` (M5); index concurrency/namespacing (H7); `cco update --check` output.
4. **Ambiguity / impl-readiness** — for each "→ E" open item across the ADRs, is it a *mechanism*
   (ready to build) or a hidden *decision* (needs maintainer input first)? Surface the latter.
5. **Phasing (§9) re-validation** — the Phase 0–3 plan predates S. Where do the S items land
   (manifest deletion, structure-based discovery, sync-before-publish fix, pack coordinates + migration,
   internalize-as-cache, `cco config protect`, `cco update --check`)? Produce an updated phase map.
6. **Code-grounding / feasibility** — do decisions match the real code (bash 3.2; `lib/manifest.sh`,
   `cmd-pack.sh` publish fast-forward defect, `lib/packs.sh` resolution, `lib/local-paths.sh`,
   `cmd-remote.sh`)? Any decision hard/infeasible as written? Confirm the call-site inventories.
7. **Doc-coherence sweep readiness** — is `resource-coherence-inventory.md` complete & correct (the
   dozens of user-facing files to realign at cutover)? Any old-model reference missed; any new S-era
   item (config-bucket/sharing-repo nomenclature, pack coordinates, perms) not yet inventoried?
8. **Migration & breaking-cutover safety** — the legacy→new fan-out (ADR-0006/0016 table); the
   profile→tag, memory→STATE, manifest-removal, pack name-only→coordinate migrations; idempotency;
   backup/verify ordering (M8). Anything lossy or unguarded?

> **Method per perspective**: each finding cited to `file:line`/ADR; **adversarially verify** (a finding
> that survives a skeptic pass), then **dedup** across perspectives, then **severity-rank**. A
> **completeness critic** at the end asks "what scope was not covered?".

## 4. What V must NOT do

Re-open settled decisions without a principle-level reason; write implementation code; expand scope
(new features). V validates the *existing* design for implementation-readiness.

## 5. Reading order for the V session

1. `guiding-principles.md` (P1–P17). 2. **This file.** 3. `design.md` end-to-end. 4. ADRs 0018/0019/0020
(latest, S cycle) then skim 0001–0017 for the refinement chains. 5. `resource-coherence-inventory.md`,
`analysis-roadmap.md`, `requirements.md`. 6. Code grounding (`bin/cco`, `lib/*.sh`, `tests/`).

## 6. After V

Resolve blockers/highs (edit docs / maintainer decisions) → then **E (implementation)** per the
(re-validated) `design.md §9` phases. T (RD-triggers / R-state-sync / DATA-STATE engine) and
solo-adopter Case C remain post-v1.
