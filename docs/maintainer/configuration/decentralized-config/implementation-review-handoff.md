# Implementation-Review Handoff — adherence & coherence audit (recurring)

**Status**: Reusable playbook. **Run every N development cycles** (typically at each phase boundary,
**before** launching the next phase) to verify that the *implementation* still adheres to and is coherent
with the frozen **design + ADRs** (the single source of truth). Read-only audit: it produces a **gap
report** + updates the roadmap/handoffs; it does **not** write production code and does **not** re-open
settled design. Runs in its **own clean session**, opening by reading `guiding-principles.md` (P1–P17) **and
this file**.

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
- **Roadmap/handoff updates** (§7): refresh the implementation-state in the roadmaps + memory, and produce
  or correct the **next phase's handoff** so the gap findings feed the next build cycle.

## 2. Scope — the whole body to audit (code ⇄ spec)

- **Spec side (source of truth)**: `guiding-principles.md` (P1–P17); ADRs `decisions/0001`–`0023` (mind the
  refinement chains — later ADRs refine earlier ones; the **forward-annotations** mark what supersedes
  what); living `design.md` (§2 layout/buckets/schema, §3 index, §4 sync, §6 domains, §7 commands, §9
  phases, §11 tests, §12 futures), `requirements.md` (AD*/FR*), `resource-coherence-inventory.md`
  (the P3 cutover-sweep driver), `analysis-roadmap.md`.
- **Code side (the real surface)**: `bin/cco` dispatcher; `lib/*.sh` (esp. `paths.sh`, `index.sh`,
  `yaml.sh`, `local-paths.sh`, `cmd-start.sh`/`cmd-new.sh`, `packs.sh`/`llms.sh`, `cmd-remote.sh`/
  `remote.sh`, `update*.sh`, `cmd-vault.sh`, `cmd-project-*.sh`, `manifest.sh`); `tests/*.sh` +
  `tests/helpers.sh`/`mocks.sh`; `config/entrypoint.sh` (container side — **read-only invariant**).
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

- **Commit A (`c8ae080`) — kept-transitional, dies P3/P4:**
  - `@local`/sanitize/extract/restore + `local-paths.yml` plumbing in `lib/local-paths.sh` — **NOT
    deleted** (still consumed by vault/publish, which ride P3/P4). Final state: index-only.
  - **Per-section schema bridge** — resolver/mount-gen detect schema per section (`yml_get_repos`/
    `yml_get_extra_mounts` non-empty ⇒ legacy chain; empty ⇒ coordinate parsers + STATE index). Collapses
    to index-only when legacy dies (P3/P4). Emitters `_effective_repo_mounts`/`_effective_extra_mounts`.
- **Commit B (`848cf63`) — kept-transitional, dies P3/P4:**
  - **Dual-seed** in the harness (`setup_global_from_defaults` seeds legacy `GLOBAL_DIR` **and**
    `~/.cco/global`); **legacy `CCO_*_DIR` KEPT** (consumed by not-yet-cutover init/update/build/clean/
    project-create/vault commands + ~20 vault-profile tests); `check_global` not re-pointed (satisfied by
    dual-seed); ~~**vault-git mirror kept** until the vault is removed (P3)~~ — **vault-git mirror ✅ GONE
    with the vault (P3-3)**. The dual-seed + legacy `CCO_*_DIR` stay until their last consumer cuts over
    (init transforms P3-3b; update/build/clean → P3-3b/P4).
- **Re-sequenced OUT of P0 (built later, in final form — `source`/base stay in place until then):**
  - **T4-source → P4**: `source` provenance stays at `<repo|pack>/.cco/source` (read **in place**); the
    →DATA relocation + `url`/`ref`/`resource` rename + `publish_target` re-derivation (F4, ADR-0022 D1)
    lands in P4.
  - **~~T5 → P2~~ — ✅ RETIRED 2026-06-23 (landed in P2-2 `b0c215e`).** Merge-engine artifacts `.cco/base/`
    + `.cco/meta` relocated to STATE keyed by identity (`_cco_{global,project,pack}_{meta,base_dir}` →
    `<state>/cco/.../update/{meta,base}`, `<id>`=`name`); global `.cco/meta` decomposed (languages→`~/.cco`,
    markers→STATE top-level, schema/policies/flags/hash-`manifest:`→global STATE meta); merge **logic**
    (`update-merge.sh`) untouched. **No production code writes base/meta to the old `.cco/` location.**
    Residual `.cco/meta`/`.cco/source` *reads* belong only to legacy machinery separately registered
    (legacy vault → P3; pack source/provenance → P4). Verified `reviews/23-06-2026-impl-adherence-review.md`.
  - **~~T4-tags → P3~~ — ✅ RETIRED 2026-06-23 (P3-2a `548f2e5`).** `cco tag add/rm` + `cco list [--tag]`
    now consume the DATA `tags.yml` (new `lib/tags.sh`; the P2 migration seed delegates to `_tags_add`,
    single writer / P12 DRY).
- **Known baseline test failures — 3 (NOT regressions — do not re-investigate). Re-baselined
  2026-06-23 (P3-3 vault cutover)** — the 5 P3 vault/profile failures vanished with their files at P3-3
  (`a76e1f6`), shrinking the FAIL set **8 → 3** exactly as the P3 handoff §4 predicted. The suite is now
  **949/3**; delta-green is measured against these 3. **Run with the host-resolve hatch:
  `CCO_ALLOW_HOST_RESOLVE=1 ./bin/test`** — without it, 3–4 pure path-resolver unit tests
  (`test_paths_project_meta_*`, `test_update_no_backup_skips_bak`) fail on the H4 guard *by design* (not
  regressions). The remaining 3 are stale-assertion / legacy test-drift in the §11 rewrite buckets:
  - **~~P2 — update/migration rewrite (8)~~ — ✅ RESOLVED 2026-06-23 (P2-2 `b0c215e`).**
  - **~~P3 — vault/profiles removed (5)~~ — ✅ RETIRED 2026-06-23 (P3-3 `a76e1f6`).**
    `test_vault.sh` (54) + `test_vault_profiles.sh` (incl. the 5 failures
    `test_vault_switch_to_main_shared_only`, `test_profile_show_active_profile`,
    `test_vault_move_preserves_unaccounted_files`, `test_vault_push_with_profile_syncs_shared`,
    `test_profile_create_preserves_unaccounted_files`) **deleted with the vault**; 3 vault-git-mirror
    tests trimmed from `test_remote.sh` + 1 vault-cmd backup-skip from `test_migrate.sh`.
  - **P4–P5 — sharing rewrite (3, still red):** `test_resolve_name_from_full_variant_url` (stale llms
    name-derivation) · `test_publish_ignore_path_patterns` · `test_project_internalize_updates_base`.
  > The 3 P0-scope `test_invariants` failures the mask-guard surfaced were **spot-fixed** at the P0 audit
  > and are **green**. The `bin/test:_run_test` `ASSERTION FAILED`-sentinel fix — keep it.
- **Legacy commands — status:** `cco vault *` + the profile/switch/shadow machinery + memory auto-commit
  (D33/D32) **✅ REMOVED at P3-3 (`a76e1f6`)**. **Still live (deferred):** `cco project create` (dies
  **P3-3b** when `cco init` scaffold replaces it — ADR-0026), `cco manifest` + the tier-2 legacy
  `cco project resolve`/`validate <name>`/`add-pack`/`remove-pack`/`delete` + the `@local` sanitize block
  (die **P4** with their publish/install/query consumers — build-once). Present-but-legacy is **expected**
  until their phase.

> **Update rule:** when a phase lands, move its retired items out of this registry (they should now be
> ❌→✅ or simply gone). A registry entry whose retiring phase is in the past is itself a finding.

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
8. **Next-phase migration/cutover safety** — for the phase about to start, are the prerequisites in place,
   the call-site inventories current, the breaking deletions guarded (discovery-before-delete, backup
   ordering, idempotency)? Surface blockers before the build starts.

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
4. **Produce/correct the next phase's handoff** so its preliminary analysis incorporates the gap findings.
5. Resolve HITL flags with the maintainer; fixes for 🔴 errors are scheduled (now, or into the owning phase).

## 8. What this review must NOT do

Write production code; re-open settled design without a principle-level reason; expand scope (new
features); rewrite shipped-behavior docs ahead of the code; or "fix" a §4 intentional-transitional state
early (that re-breaks delta-green — flag it, don't touch it). It audits the *existing* implementation for
conformance and readiness.

## 9. Reading order for the review session

1. `guiding-principles.md` (**P1–P17**). 2. **This file** (esp. §4 registry + §1 four-state classification).
3. `Y-handoff-implementation.md` (build method + the P0–P5 phase map + cross-cutting invariants + the
deferred list). 4. `design.md` **§2/§3/§4/§9/§11** + the load-bearing ADRs (**0007/0015/0016** buckets,
**0017** CLI, **0019** reachability, **0022** coordinate/resolution, **0023** command surface). 5. The
personal progress note (`decentralized-config-impl-progress.md`) for the latest cursor. 6. The code (§2)
and `git log` since the last review. 7. The prior review (`reviews/18-06-2026-impl-readiness-review.md`) for
the design-readiness baseline.
