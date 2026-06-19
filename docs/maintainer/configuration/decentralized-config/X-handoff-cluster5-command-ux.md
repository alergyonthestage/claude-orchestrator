# X — Cluster 5 handoff (Command surface & UX)

> **✅ CLOSED 2026-06-19 — Cluster 5 RESOLVED & PERSISTED.** All 11 findings resolved in 5 groups (A–E)
> → **new ADR-0023** (D1–D6) + `design.md` re-sync + forward-annotations. The impl-readiness review (V)
> is **fully closed (all 5 clusters)**; the project proceeds to **implementation** along `design.md` §9
> P0–P5. See the review's *Cluster 5 — COMPLETE* log. This file is kept as the launch-pad record.

**Status**: Clusters 1–4 of the impl-readiness review (V) are **RESOLVED & PERSISTED**. **Cluster 5 is the
last open cluster.** This file lets a fresh clean session run Cluster 5 with the same method, then move to
implementation. Produced 2026-06-19 on `feat/vault/decentralized-config` (commits **local**, pushed from
the maintainer's Mac). Read **`W-handoff-cluster-resolution.md`** first (method + reading order); this file
is the Cluster-5-specific launch pad.

---

## 1. Method (unchanged — the same loop used for Clusters 1–4)

1. Take the cluster's findings from `reviews/18-06-2026-impl-readiness-review.md` (each has
   location · issue · why · **options + a recommendation**). Present a **preliminary analysis + a
   per-decision recap** to the maintainer: context, alternatives, the recommended option.
2. **Code-ground every claim** before asserting (read `bin/cco` / `lib/*.sh`; the V discussion proved
   several lens premises wrong by reading the code). **Adversarially verify** (a false "bug" was caught
   this way; in Cluster 4 a cross-doc path inconsistency was caught the same way).
3. **Decision classes** (the maintainer's standing instruction):
   - **Design/UX-impacting → require explicit maintainer confirmation** (Cluster 5 is *mostly* this — it
     IS the command-surface & UX cluster).
   - **Secondary/technical (no architecture/UX impact) → may be taken autonomously**, but still presented
     for completeness. All recommendations must stay consistent with the approved ADRs/design.
4. **Persist nothing without approval.** On approval: forward-annotate ADRs (history kept verbatim, per
   `.claude/rules/documentation-lifecycle.md`), rewrite the living docs (`design.md` §7 mainly,
   `requirements.md`) in place, annotate the review's Cluster-5 Resolution Log, then **commit** (atomic).
5. **Phasing**: do NOT renumber phases. Map each resolution onto the Cluster-2 **P0–P5** dependency map
   (P0 substrate · P1 core-local · P2 migration · P3 legacy-cutover · P4 sharing-core · P5 sharing-ext).
   The review's "Phase 0-3 / E" vocabulary is superseded.

## 2. Scope — the 11 findings (grouped), with reference docs & the decision at stake

Finding IDs index the review. Impact tag: 🔵 = design/UX (confirm) · ⚙️ = technical (autonomous, present).
**Most of Cluster 5 is 🔵** — it owns the command taxonomy and user-facing affordances.

### Group A — `cco config` namespace coherence (the umbrella)
- **F46** 🔵 — `cco config` is an overloaded grab-bag spanning **two buckets** (personal `~/.cco` vs
  project `<repo>/.cco`) and **four unrelated concerns** (versioning · validate · coords · protect);
  never enumerated as a coherent subcommand set. **This is the organizing decision** — F26/F19/F27 are
  sub-surfaces of it. Refs: `design.md §7:529,532` + `:270-271,477-478,509`; ADR-0008/0016 D3,D9/0019
  D2/0020 D4.
- **F26** 🔵 — **`cco config validate` contract** is under-specified: argument scope, per-failure exit
  codes, output format, the mechanical machine-agnostic/absolute-path detection, hook-installer existence,
  heal-backfill non-TTY semantics. **Must carry the Cluster-4 carry-ins** (see §3). Refs: ADR-0016 §D9
  (268-275); ADR-0019 §D2 (72-85); `design.md §2.4:271,296-299`; `lib/local-paths.sh:163` (non-TTY guard).
  *Likely the one finding that warrants a dedicated ADR-0023.*
- **F19** 🔵 — coordinate-add verbs **`cco repo add` / `cco llms add`** (the primary `embed-at-add`
  reachability mechanism, P14 layer-a) **and** `cco config coords`/`validate` are **missing from the §7
  command table**. Must wire F48's `coords --sync --from` (pinned in Cluster 4). Refs: `design.md §7`
  (the table) vs `§2.4:270-271`; ADR-0019 D2 layer-a (74); ADR-0016 D3; `bin/cco`; `lib/cmd-llms.sh:34-39`.

### Group B — Resolution UX & affordances
- **F49** 🔵 — `cco resolve` source-selection precedence and the layered **heal/validate reachability**
  model are **user-invisible**: undefined unresolved-start prompt copy and the passive-⚠ next-step
  affordance. Refs: `design.md §4.4:400-402, §7:524-526`; ADR-0017 D2:79-80; ADR-0019 D2 (layers b/c/e).
- **F50** 🔵 (light) — three+ overlapping "what would change?" discovery surfaces on `cco update`
  (**`--check` vs `--diff` vs `--dry-run` vs `--news`**) with no documented division of labor. Refs:
  `design.md §7:531, §6.2:506`; ADR-0018 D5; `lib/cmd-update.sh:28,39,40,81`; `CLAUDE.md` update flags.
  (`--check` semantics already fixed by ADR-0022 D6 — here only the *division of labor* vs the others.)

### Group C — Sharing / 2×2 command-surface accuracy
- **F34** ⚙️/🔵 — `design.md §6.2` lists `cmd-project-publish.sh`/`cmd-project-install.sh` as merely
  "revised" although **ADR-0018 D2 removes the project publish/install surface**, and the 2×2 row is
  mislabelled "transform" though 6 verbs are net-new and 2 removed. Mostly doc-accuracy (autonomous) but
  the verb-status labels touch the §7 table. Refs: `design.md §6.2:511-513, §7:530`; ADR-0018 D2;
  `bin/cco:167-181,206-218`; `lib/cmd-template.sh:55-58`.
- **F47** 🔵 — template sharing verbs (**publish/install/export/import**) claimed by the 2×2 are **absent
  from the §7 Templates row and the code**; the **pack/template symmetry vs scaffold-only** tension is
  unresolved. Refs: `design.md §6.2:496-497, §7:528,530`; ADR-0018 D2/D3; ADR-0019 D7;
  `lib/cmd-template.sh:55-58`.
- **F13** 🔵 — **`cco project internalize`** is labelled "net-new (→ E)" but **already exists in code**
  with a different (project-source-disconnect / knowledge-copy) semantic under the now-abolished
  project-install model — a verb-name/semantic clash to resolve. Refs: ADR-0019 §D3/D4 (118-119) +
  Reuse/Build-new table (218); `lib/cmd-project-update.sh:230-311`; `lib/cmd-project-install.sh:9`;
  `lib/cmd-pack.sh:750-861` (`cmd_pack_internalize`); `bin/cco:173`.

### Group D — Entry points & schema
- **F18** 🔵 — **`cco new`** (ad-hoc/temporary session) — a real top-level entry point sharing the
  compose/mount code being rewritten — is **entirely unaddressed** by the design. Refs: `design.md §7`
  (table), `§8` (journeys); `requirements.md §3 + :310`; `bin/cco:141` (`cmd_new`); `lib/cmd-new.sh`.
- **F25** ⚙️/🔵 — **`extra_mounts` schema (M5)**: `§2.4` uses `- name:` but code/FR use
  `- source:`/`- target:`; the **machine-agnostic container target** has no home in the new schema.
  Mostly a schema reconciliation (technical) with one UX question (where the container target lives).
  Refs: `design.md §2.4:257-259, §3:268,310-312`; `requirements.md AD5:96`; ADR-0016 §Open (380);
  `lib/yaml.sh:350-410`; `lib/local-paths.sh:515-560`.

### Group E — Permissions scaffold
- **F27** 🔵 — **`cco config protect` contract**: scaffolded CODEOWNERS content/location and per-host
  instruction text are unspecified; the literal `<repo>/.cco/CODEOWNERS` location is **ineffective on
  GitHub** (CODEOWNERS must be at repo root / `.github/`); and the **ship-in-v1 decision is open**
  (a scope call). Refs: ADR-0020 §D4 (74-86), §Open (153-159); `design.md §7:532` ("NEW (optional)").

## 3. Cluster-4 carry-ins Cluster 5 MUST honor (do not re-open; wire them)

- **`cco config validate` (F26)** must implement, as ONE contract, the predicates already decided
  elsewhere — consolidate them (F53 nit flagged the DRY hazard of D9≈D2 restating the contract):
  - ADR-0022 **D4** — the pack three-layer resolver's **one ERROR row** (no-coordinate authored-in-repo
    pack also present as `~/.cco/packs/X`); everything else WARN (P14/P17). validate is **exit-code only**,
    never the git push path.
  - ADR-0021 **§5** — **orphan sanitization**: `validate [--dry-run]` detects, `--fix` prunes,
    **preview-first, never automatic**; STATE/CACHE freely rebuildable, **DATA pruned only on confirm**.
  - ADR-0016 **D9** (opt-in pre-commit hook) + ADR-0019 **D2** (reachability validity) — same contract,
    state it once.
- **`cco config coords` (F19/F46)** must use **explicit `--from <unit>`, never auto-elect** (ADR-0016 D3,
  pinned by Cluster 4 / F48); `--diff` read-only.
- **`cco repo/llms add` (F19)** = `embed-at-add` (P14 layer-a, ADR-0019 D2): auto-resolve the `url` from a
  known id (the on-demand coords scan, ADR-0022/F45) and embed it in the manifest entry.
- **Sharing verbs (F34/F47)** must match **ADR-0018 D2** (projects do NOT publish/install; ride the repo
  remote) and the **2×2** (publish↔install + export↔import).
- **Doc class**: these are **design-intent command-surface** decisions → persist to `design.md §7` (and a
  possible ADR-0023) **now**. The user-facing *guide/tutorial* rewrites are **shipped-behavior** → they
  ride **Cluster 3 Block B / the Phase-3 cutover sweep** (don't rewrite ahead of code;
  `.claude/rules/documentation-lifecycle.md`).

## 4. Likely persistence shape (confirm during the cluster)

- **One new ADR-0023** for the genuinely-new decisions — most plausibly the **`cco config` namespace
  taxonomy (F46)** + the **`cco config validate` contract (F26)**, with F19/F27/F47/F13/F18 either folded
  in or persisted as `design.md §7` refinements depending on how much each is a *decision* vs a
  *spec-fill*. Decide the ADR-vs-refinement split with the maintainer (as in Cluster 4). **Next free ADR =
  0023.**
- Living-doc edits concentrate in **`design.md §7`** (the command table — the cluster's centre of
  gravity), plus `§6.2` (F34/F47), `§2.4`/`§3` (F25), `§4.4` (F49), `§8` (F18 journey).
- Annotate the review's **Cluster-5 Resolution Log** and flip `analysis-roadmap.md` + the global
  `docs/maintainer/decisions/roadmap.md` + `W-handoff` to "all clusters resolved → implementation".

## 5. Reading order for the fresh session

1. `guiding-principles.md` (P1–P17). 2. `W-handoff-cluster-resolution.md` (method) + **this file**.
3. The review's Cluster-5 findings (F46, F26, F19, F49, F50, F34, F47, F13, F18, F25, F27) + the review's
   Cluster-4 Resolution Log (the carry-ins). 4. ADRs touched: 0016 (D3/D9), 0017 (D2), 0018 (D2/D3), 0019
   (D2/D7), 0020 (D4), 0021 (§4/§5), 0022 (D4/D6). 5. Code grounding: `bin/cco` dispatcher,
   `lib/cmd-new.sh`, `lib/cmd-template.sh`, `lib/cmd-project-*.sh`, `lib/cmd-pack.sh` (internalize),
   `lib/local-paths.sh` (validate/non-TTY), `lib/cmd-update.sh` (discovery flags). 6. `design.md §7`/`§6.2`.

## 6. After Cluster 5

Cluster 5 is the **last** review cluster. When it lands, the impl-readiness review (V) is fully resolved
and the project proceeds to **implementation** along the `design.md §9` P0–P5 dependency-layered phases
(T = post-v1 state-sync, future).
