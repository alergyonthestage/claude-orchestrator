# Implementation-Review Handoff — adherence & coherence audit (recurring)

**Status**: Reusable playbook. **Run every N development cycles** (typically at each phase boundary,
**before** launching the next phase) to verify that the *implementation* still adheres to and is coherent
with the frozen **design + ADRs** (the single source of truth). Read-only audit: it produces a **gap
report** + updates the roadmap/handoffs; it does **not** write production code and does **not** re-open
settled design. Runs in its **own clean session**, opening by reading `guiding-principles.md` (P1–P18) **and
this file**.

> **Current run = the whole-scope pre-merge implementation review (v1 BUILD COMPLETE, P0–P5 closed,
> 2026-06-25).** No "next phase" remains — the loop (§7) feeds **merge-readiness + the maintainer's review
> cycle** (docs → refactoring → UX-UI → dogfooding), not a further build phase. The §4 LIVE transitional set
> is **empty**, so the audit's job shifts from "is this hybrid sanctioned?" to "**is anything still hybrid
> at all?**" — any remaining legacy/dual-read is now 🔴. Scope = the entire decentralized-config surface.
>
> **Approved reference = `decentralized-config/design.md` (living) + the ADRs `decisions/0005`–`0027`**
> (precedence: `guiding-principles.md` P1–P18 → ADRs → design → `requirements.md`); **verified against the
> written code.** The four maintainer-stated ambits map onto this playbook:
> 1. **No issues/bugs** → 🔴 conformance-bug findings (lenses 4 invariants, 6 test-contract).
> 2. **No implementation gaps** → ❌ *Missing* state + lens 3 phase-completeness (at build-complete, any ❌ is a real gap).
> 3. **Adherence to design + ADRs** → the **core**: the §1 four-state classification, code-grounded (`file:line`).
> 4. **Optimization / duplication** → lens 9 + the §1 optimization backlog — **flag-only**, anticipating the
>    dedicated refactoring review (do not refactor here).

> **Why this exists.** The decentralized-config refactor is a **breaking, multi-phase cutover** (design §9
> P0–P5) executed *out of design chronology* (dependency + reuse + open-closed). At any moment the codebase
> is a **mix** of: final-form modules, not-yet-built modules, and **deliberately transitional/hybrid** ones
> that bridge old↔new until a later phase deletes them. Without a periodic, code-grounded audit, two
> failure modes creep in: (1) **silent drift** — a module diverges from the spec and no test catches it
> (delta-green can mask it); (2) **false alarms** — an intentional transitional state is "fixed" early,
> re-breaking delta-green (the §5 trap that bit T4/Commit B). This audit catches both: it classifies every
> design/ADR element against the real code and **separates desired-legacy from real errors**.

---

## 1. What this review must produce

A **gap report** at `reviews/<DD-MM-YYYY>-impl-adherence-review.md` that, for the **whole
decentralized-config scope**, classifies the implementation state and is **directly actionable**:

- **Per design/ADR element, one of four states** (this classification is the core deliverable):
  | State | Meaning |
  |---|---|
  | ✅ **Implemented — conformant** | Built, in final form, matches design/ADR (cite `file:line`). |
  | ❌ **Missing** | Designed but not built at all; name the phase that owns it (design §9). |
  | 🟡 **Hybrid — intentional** | Already modified but **deliberately transitional** per the design/handoffs (bridges old↔new; dies in a named later phase). **Must match the Transitional Registry (§4).** Cite the phase that retires it. |
  | 🔴 **Hybrid — divergent / error** | Modified into a state the design did **not** sanction, OR a transitional state with no registry entry / no retiring phase, OR a conformance bug. Needs a fix (or a HITL decision). |
- **Severity** per finding: blocker / high / medium / nit. Each finding: *location (`file:line` / ADR) ·
  observed vs expected · why it matters · classification (above) · proposed resolution or HITL flag*.
- **HITL flags** (§6): every finding whose resolution is **not derivable from the spec** — an ambiguity
  (intentional-or-error?), a design/ADR contradiction the implementation surfaced, or a decision affecting
  how the toolkit is used (UX/interface/placement/sync). Per the autonomy-vs-HITL settings, these are
  **surfaced for the maintainer**, never silently resolved.
- **Roadmap/handoff + forward-feed** (§7): refresh the implementation-state in the roadmaps + memory, and
  feed the gap findings forward — during the build, into the **next phase's handoff**; at v1 build-complete,
  into **merge-readiness + the maintainer's pre-merge review cycle** (no next build phase remains).
- **Optimization & duplication backlog (flag-only)** — a **separate, non-blocking** list of code-quality
  opportunities (duplicated logic, dead code, a function doing too much, an over-complex path) that the
  audit notices while verifying conformance. **It anticipates the dedicated refactoring review** — so
  *surface and locate* each (`file:line` + one-line why), but **do NOT refactor here** and do NOT let it
  dilute the adherence focus. These are not 🔴 conformance findings; they are inputs to the next review.

## 2. Scope — the whole body to audit (code ⇄ spec)

- **Spec side (source of truth)**: `guiding-principles.md` (P1–P18); ADRs `decisions/0005`–`0027` (mind the
  refinement chains — later ADRs refine earlier ones; the **forward-annotations** mark what supersedes
  what); living `design.md` (§2 layout/buckets/schema, §3 index, §4 sync, §6 domains, §7 commands, §9
  phases, §11 tests, §12 futures), `requirements.md` (AD*/FR*), `resource-coherence-inventory.md`
  (the P3 cutover-sweep driver), `analysis-roadmap.md`.
- **Code side (the real surface)**: `bin/cco` dispatcher; `lib/*.sh` (esp. `paths.sh`, `index.sh`,
  `yaml.sh`, `local-paths.sh` [migrate-from-BACKUP readers only], `cmd-start.sh`/`cmd-new.sh`,
  `cmd-pack.sh`/`cmd-llms.sh`/`cmd-template.sh`, `cmd-remote.sh`/`remote.sh`, `update*.sh`, `tags.sh`,
  `cmd-config.sh`/`cmd-resolve.sh`/`cmd-sync.sh`, `cmd-forget.sh`, `cmd-project-*.sh` [query / export-import /
  add / validate / coords]); `migrate.sh`. **NOTE — gone (do not look for them):** `cmd-vault.sh`,
  `manifest.sh`, `cco project create`/`publish`/`install`/`update`, tier-2 `cco project resolve`/`validate
  <name>`/`add-pack`. `tests/*.sh` + `tests/helpers.sh`/`mocks.sh`; `config/entrypoint.sh` (container side —
  **read-only invariant**).
- **The diff since the last audit**: `git log --oneline` on `feat/vault/decentralized-config` since the
  previous review date narrows where new drift can have entered.

## 3. Method (reuse the V impl-readiness methodology)

This may be run as a **multi-agent workflow** (the V review used one: parallel lenses → adversarial verify
→ dedup → severity-rank → completeness critic) or single-session for a lighter cycle. Either way:

- **Code-ground every claim** (P10): cite `file:line`; line numbers drift, so re-read — never assert from a
  prior report. Build the writer/reader/consumer map **including the tests**.
- **Run the lenses in §5 in parallel**, each blind to the others (multi-modal sweep).
- **Adversarially verify** each finding (does it survive a skeptic pass?), then **dedup** across lenses,
  then **severity-rank** and **classify** (the §1 four-state table).
- A **completeness critic** closes the pass: *what scope was not covered — a lens not run, a phase not
  checked, a claim unverified?* Its output is the next round's work.
- **Delta-green awareness**: the suite is green-per-phase against a **known baseline failure set** (§4).
  A "green suite" is **not** proof of conformance — a masked assertion or an untested path can hide drift.
  Audit the **test contracts** (§11), not just the pass count.

## 4. The Transitional Registry — desired-legacy that must NOT be flagged as error

**This is the load-bearing input that prevents false positives.** Each item below is a *deliberate* hybrid
state sanctioned by the design/handoffs; flag it 🟡 (intentional) only if it still matches its description
and **its retiring phase has not yet passed**. If a retiring phase **has** passed and the legacy is still
present, that flips to 🔴 (the cleanup was missed). Keep this registry **current** at each audit.

### ✅ RETIRED through Phase 5 (do NOT re-investigate; gone)

The whole P0–P5 transitional set has landed and been removed in final form:
- **Commit A** (`c8ae080`): `@local`/sanitize/extract/restore + `local-paths.yml` plumbing → **REMOVED P4-5b**
  (`34b3429`); the per-section schema bridge legacy `- path:`/`- source:` arm → **COLLAPSED index-only P4-5c**
  (`105bd9c`); legacy parsers `yml_get_repos`/`yml_get_extra_mounts` → **REMOVED P4-5c-3** (`bdc90a0`).
- **T4-source** → **RETIRED P4-1** (`82b6956`): `source`→DATA + key rename (`source→url`/`path→resource`) +
  bookkeeping→STATE meta + `publish_target` re-derived (`remote_get_name_for_url`); `_relocate_legacy_pack_sources`
  migrates in-place source. **T5** (base/meta→STATE) → RETIRED P2-2 (`b0c215e`). **T4-tags** → RETIRED P3-2a (`548f2e5`).
- **Legacy commands:** `cco vault *` + profile/switch/shadow + memory-auto-commit (D33/D32) → REMOVED P3-3
  (`a76e1f6`); `cco project create` → REMOVED P3-3b (`d9e44a2`); `cco manifest` + `lib/manifest.sh` + writers
  → REMOVED P4-2 (`6b2673f`, structure-based `_discover_resources`); tier-2 `cco project resolve`/`validate
  <name>`/`add-pack`/`remove-pack`/`delete` → REMOVED P4-5a (`3b0859b`); `cco project publish`/`install`/
  `update`/`internalize` → REMOVED P4-4e (`a5d6cca`). Removed verbs give AD12 explicit "was removed" rejections.

- **P4-5d central-layout teardown** → **RETIRED in P5-1** (`0da6153`/`6209bae`/`7e9d458`/`0116679`): the
  legacy `$PROJECTS_DIR`/`CCO_*_DIR` central enumeration is **gone** — every command enumerates via
  `_index_list_projects` + `_index_get_path`; managed runtime → CACHE (`_cco_project_cache_managed`); harness
  dual-seed removed (host `.cco/` + index only). Verified: zero `$PROJECTS_DIR`/`CCO_PROJECTS_DIR` in `lib/bin/tests`.
- **P5-0 llms straddler** → **FIXED P5-0** (`2f93de8`): `_llms_resolve_name_from_url` now prefers a meaningful
  path segment over the domain → resolved `test_resolve_name_from_full_variant_url` (the last baseline failure).
- **KEEP-forever (NOT to be flagged/removed):** `_project_effective_paths` (cmd-start), `_local_paths_get`/
  `_get_section` (migrate reads legacy `local-paths.yml` from BACKUP, `migrate.sh:492`), `_resolve_entry_index`,
  `_prompt_for_path`.

### 🟡 LIVE transitional set — **EMPTY at v1 build-complete (P5 DONE, 2026-06-25)**

There is **no live sanctioned hybrid left**: P0–P5 are all closed and every transitional item has been
retired. **Consequence for this (pre-merge, whole-scope) review:** there is no longer a "next phase" to
retire anything, so **any** hybrid / dual-read / legacy-bridge / central-layout remnant found in the code is
**🔴 (a missed cleanup or a divergence), not 🟡**. The only deliberately-kept legacy is the **KEEP-forever**
list above (migrate-from-BACKUP readers) — those stay. One documented, separately-tracked doc gap:
`integration/browser-mcp/design.md` still describes the pre-refactor file layout/mount (`browser.json` /
CACHE `managed/` / `/workspace/.managed`) below a current-layout note — a logged doc-coherence item, not a
code finding.

### Known baseline — **894 passed / 0 failed** (run `CCO_ALLOW_HOST_RESOLVE=1 ./bin/test`)

The suite is at **ZERO failures** — any failure is a regression. (Without the `CCO_ALLOW_HOST_RESOLVE=1`
hatch, 3–4 pure path-resolver unit tests `test_paths_project_meta_*`/`test_update_no_backup_skips_bak` fail
the H4 guard *by design* — not regressions; always run with the hatch.) Keep the `bin/test:_run_test`
`ASSERTION FAILED`-sentinel fix (un-masks mid-test assertion failures).

> **Update rule:** when a phase lands, move its retired items out of the LIVE set (they become ✅ or gone).
> A LIVE entry whose retiring phase is in the past is itself a finding. At v1 build-complete the LIVE set is
> empty — keep it that way; a new hybrid would need an explicit post-v1 sanction.

## 5. Review lenses (run in parallel — adapt/compose as fits the cycle)

1. **Bucket-taxonomy adherence** — does the code place each datum in its **authoritative home**
   (ADR-0016 table; CONFIG `~/.cco` · DATA `~/.local/share/cco` · STATE `~/.local/state/cco` · CACHE
   `~/.cache/cco`)? Any internal file written into a committed config bucket (P6/G8 violation)? Any
   regenerable output not in CACHE? Resolver guard H4 intact?
2. **Coordinate model & index** — `project.yml`/`pack.yml` carry **logical names + coordinates only**, never
   real paths (AD3/G8 — `git diff` truthful); the **STATE index** maps name→path; `mktemp`+`mv` atomic, no
   lock, global-flat (H7/ADR-0022 D2). Schema/parsers in final form (F5)?
3. **Phase completeness vs §9** — for each P0–P5 item: built? final-form (built-once, no double
   schema-migration)? pending in its owning phase? Cross-check against the §11 test contracts.
4. **Invariant adherence** — H1 (resolution before notices/divergence), H4 (host-side resolver guard),
   H6/H7, the **compose↔entrypoint container-path contract** (host-source changes only; container paths
   fixed), P14 (reachability layered, **never hard-block**), P15 (a local copy is never its source;
   discriminator = coordinate presence), P17 (permissions delegated to git).
5. **Transitional vs error** — for every hybrid state in the code, is it in the **§4 registry**, still
   matching its description, with its retiring phase **still ahead**? If not → 🔴. This lens is what makes
   the audit trustworthy.
6. **Test-contract adherence** — §11 per-phase rows honored? Delta-green holds against the §4 baseline?
   **Masked-assertion audit**: the runner uses `( set -e; fn )` but bare `assert_*` are **still masked**
   (a mid-test failure is swallowed; only the last command's status counts) — multi-assert tests need
   `|| return 1`. Hunt masked assertions that hide drift.
7. **Doc coherence** — living design/ADR/requirements match the code; **shipped-behavior docs (README,
   guides, tutorial, FRs, index pages) are NOT rewritten ahead of the code** (doc-lifecycle: they ride the
   P3 cutover sweep). `resource-coherence-inventory.md` still accurate as the cutover driver?
8. **Cutover / merge safety** — breaking deletions guarded (discovery-before-delete, backup ordering,
   idempotency)? Any half-migrated path? At v1 build-complete this lens checks **merge-readiness** (nothing
   left half-cut over) rather than a next build phase's prerequisites.
9. **Optimization & duplication (flag-only — feeds the refactoring review)** — while doing the conformance
   passes, note code-quality opportunities: **duplicated logic** (the same parse/resolve/merge written twice
   — a DRY violation), **dead code** (an unreferenced helper after a verb was removed), a function with
   **mixed responsibilities**, or an **over-complex path** a shared helper would simplify. Record each as a
   *flag* (`file:line` + one-line why) on the §1 optimization backlog — **do not refactor**, do not raise as
   🔴. This is a deliberately light pass that *anticipates* the dedicated refactoring review (SOLID/DRY/KISS/
   YAGNI); the adherence audit stays primary.

## 6. HITL — what to surface for human decision

Per the autonomy-vs-HITL settings, **flag (do not auto-resolve)** any of:
- A 🔴 finding where "intentional transitional" vs "error" is **genuinely ambiguous** (the registry is
  silent and the design doesn't clearly sanction the state).
- A **design/ADR contradiction** the implementation surfaced (two specs disagree; the more
  specific/authoritative wins, but record the reconciliation and confirm if it changes behavior).
- Any resolution that affects **how the toolkit is used** (UX, interface, bucket placement, sync strategy)
  — not derivable from code (guiding-principles P10 method-lesson b).
- A **scope/sequencing** change (an item is cheaper/safer to build in a different phase than §9 says).

Present each with options + a spec-grounded recommendation; persist the chosen answer (ADR / design /
roadmap) before it is acted on.

## 7. After the review — close the loop

1. Write the gap report (`reviews/<date>-impl-adherence-review.md`).
2. **Update the implementation-state** in `docs/maintainer/decisions/roadmap.md` (global) +
   `analysis-roadmap.md` + the personal memory (`decentralized-config-impl-progress.md`) — what is ✅/❌/🟡/🔴.
3. **Refresh the §4 Transitional Registry** (retire landed items; add any new sanctioned hybrids).
4. **Feed the findings forward.** At v1 build-complete there is no next *build* phase: 🔴 fixes feed
   **merge-readiness** and the maintainer's **pre-merge review cycle** (this review → documentation review →
   refactoring review → UX-UI review → dogfooding). (During the build this step instead produced/corrected
   the *next phase's* handoff.)
5. Resolve HITL flags with the maintainer; fixes for 🔴 errors are scheduled (now, or pre-merge).

## 8. What this review must NOT do

Write production code; re-open settled design without a principle-level reason; expand scope (new
features); rewrite shipped-behavior docs ahead of the code; or "fix" a §4 intentional-transitional state
early (that re-breaks delta-green — flag it, don't touch it). It audits the *existing* implementation for
conformance and readiness. **On optimization/duplication (lens 9): you may *flag* opportunities (location +
why) as a non-blocking backlog, but you must NOT perform the refactor here** — that is the separate
refactoring review. Flagging anticipates it; doing it would expand scope and risk the adherence focus.

## 9. Reading order for the review session

1. `guiding-principles.md` (**P1–P18**). 2. **This file** (esp. §4 registry + §1 four-state classification).
3. The build method + cross-cutting invariants — `guiding-principles.md` (P1–P18) + the live
`decentralized-config-impl-progress.md` progress note (the P5-final-stretch handoff was consumed at
P5 build-complete and removed) + `design.md`
**§9** (P0–P5 phase map + §11 test contracts) / **§12** (deferred-post-v1). 4. `design.md` **§2/§3/§4/§9/§11** + the load-bearing ADRs (**0007/0015/0016** buckets,
**0017** CLI, **0019** reachability, **0022** coordinate/resolution, **0023** command surface). 5. The
personal progress note (`decentralized-config-impl-progress.md`) for the latest cursor. 6. The code (§2)
and `git log` since the last review. 7. The prior review (`reviews/18-06-2026-impl-readiness-review.md`) for
the design-readiness baseline.
