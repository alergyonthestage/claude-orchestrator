# P3-5 resume — review the doc sweep, then Section D (archive) → close Phase 3

**Purpose.** This session ran **P3-4 (config-editor + edit-protection, ADR-0027)** and **P3-5 sections
A/B + C** of the shipped-behavior doc cutover sweep, then stopped (context budget). The next session must
**first review** what was implemented (find gaps — part of it was done by parallel doc agents), **then
finish Section D** (archive the removed-feature design subtrees) to **CLOSE Phase 3**. Produced
2026-06-24. Baseline **936 passed / 3 failed** on `feat/vault/decentralized-config` (commits **local** —
the maintainer pushes from the Mac). Self-contained.

## 0. Authoritative methodology (unchanged — the law)

The **`decentralized-config` design IS the source of truth**, in precedence order:
`guiding-principles.md` (P1–P18) → ADRs (0005–0027) → living `design.md` → `requirements.md`. The more
specific/authoritative wins; **record any reconciliation**; a genuine design gap ⇒ **PAUSE and discuss**.
Non-negotiables: **AD12 breaking cutover** (new layout only, no aliases for removed verbs); **AD3/G8** no
real host path in committed config; **doc-lifecycle** (`.claude/rules/documentation-lifecycle.md`):
decision/analysis records = immutable history (forward-annotate); living design/guides = rewritten in
place to truth; **removed-feature design with no living successor = archived to `_archive/` at cutover**.
**Each commit leaves cco runnable + the suite delta-green** (the **3** P4–P5 baseline failures:
`test_resolve_name_from_full_variant_url`, `test_publish_ignore_path_patterns`,
`test_project_internalize_updates_base`). **Run with the hatch: `CCO_ALLOW_HOST_RESOLVE=1 ./bin/test`.**
**Maintainer-confirm** any UX/interface/placement choice. **Code-ground every claim** (line numbers
drift — re-read). **bash 3.2 / macOS.** **Self-development caveat:** edits to `config/`, `Dockerfile`,
baked `defaults/managed/**` are NOT live this session (need `cco build`); `lib/`, `internal/`,
`templates/`, `docs/` ARE host-side and live next `cco start` (testable via `./bin/test` now).

## 1. FIRST ACTION (MANDATORY) — review the P3-4 + P3-5 work before Section D

This session was **interrupted mid-phase**, and **Section C was executed by 5 parallel doc agents**.
Before writing Section D, run a **read-only, code/doc-grounded review** (the
`implementation-review-handoff.md` playbook, lighter cycle is fine) to confirm:

1. **Baseline** is exactly **936/3** (`CCO_ALLOW_HOST_RESOLVE=1 ./bin/test`); the 3 = the P4–P5 set above.
2. **P3-4 code conformant** (ADR-0027): `--mount` (ro default; `utils.sh:_parse_user_mount_spec`); the
   D3 **narrow** guardrail (`cmd-start.sh:_start_generate_compose` overlays `<repo>/.cco:ro` only,
   `/workspace/.claude` stays rw; `--enable-config-edit`; built-ins exempt via `is_internal`);
   config-editor built-in (`internal/config-editor/`, reserved name, `_setup_internal_config_editor`
   GENERATES the runtime project.yml with `readonly: false` on the rw mounts). **Transitional Registry
   still intact** — tier-2 legacy project-verbs + `@local` block die in **P4**, do NOT delete now.
3. **P3-5 A/B + C doc accuracy** (the agent-written part needs a human-grade pass): spot-check that the
   swept docs match the **real shipped command surface** (`design.md §7` + the actual `bin/cco`
   dispatcher) — no invented verbs/flags, "Config Repo"→"sharing repo" never renamed a config **bucket**,
   Mermaid diagrams well-formed, no dangling links to retired `vault/`/`sharing/` paths. Re-grep for
   residual old-model markers (the only legitimate hits are **intentional negations** — "no
   `manifest.yml`", "there is no `cco vault`", "the removed `@local`"). Confirm the three **flagged**
   maintainer notes (§4) and decide them.
4. **Coverage gaps** the inventory names but this session did **not** touch (decide: in-scope-now vs
   defer/note): `docs/maintainer/architecture/{coding-conventions,security,testing}.md` (had old-model
   marker hits, NOT in the inventory C list); the maintainer-design subtrees `configuration/{llms,packs,
   update-system,internal/tutorial,scope-hierarchy,rules-and-guidelines}/` (mostly out of the inventory's
   explicit C scope — some live, some stale). The inventory C list was executed; these are the residue.

Record a one-line confirmation per item; a genuine gap ⇒ fix (delta-green) or PAUSE.

## 2. Context to load (reading order)

1. `guiding-principles.md` (P1–P18). 2. **This file.** 3. `resource-coherence-inventory.md` — the
**P3-5 driver**; its top **"P3-5 EXECUTION STATUS"** banner + **Section D** are the work-list. 4.
`.claude/rules/documentation-lifecycle.md` (governs the archive). 5. `design.md` §2 (layout/buckets),
§7 (command surface), §9 P3. 6. ADRs **0012** (no manifest), **0018 D1** ("config repo" retired → config
bucket / sharing repo), **0009** (memory=STATE). 7. The personal progress note
`decentralized-config-impl-progress.md` (live cursor). 8. `git log --oneline -12` for what landed.

## 3. Section D — archive the removed-feature design subtrees (the resume work)

**Driver: `resource-coherence-inventory.md` Section D.** Per the doc-lifecycle rule, design docs for a
**removed** mechanism with **no living successor** are **archived — not deleted, not in-place-bannered**
(the successor is the `decentralized-config/` tree). Disposition (Phase-3 cutover):

1. **Create `docs/maintainer/configuration/_archive/`** and **`git mv`** into it the **removed-mechanism
   subtrees**: `vault/` (vault profiles, `@local`/local-paths design) and `sharing/` (Config-Repo +
   manifest design — superseded by `decentralized-config/` ADR-0018-0023). Use `git mv` to preserve
   history.
2. **`resource-lifecycle/` is only PARTIALLY removed** — its **file-policy (tracked/untracked/generated)
   + changelog dual-tracker** concepts are **LIVE** (referenced by `.claude/rules/update-system.md` and
   `docs/maintainer/configuration/update-system/`). **Re-home those surviving concepts into the living
   `update-system/` design FIRST**, then archive only the dead `.cco/`-layout remainder of
   `resource-lifecycle/`. (The C.6 index-README rewrite ALREADY wrote pointers asserting this re-home +
   the `_archive/` move — Section D must make them TRUE so the index stops dangling.)
3. **Update area-index "canonical source" pointers** so vault-profiles / publish-install flow / `.cco/`
   layout redirect to `decentralized-config/` (C.6 mostly did this in
   `docs/maintainer/configuration/README.md` — verify + complete).
4. **Back-references from frozen ADRs** to `../vault/…`/`../sharing/…` may dangle after the move —
   accept (ADRs are history) or fix in one pass; do not block the cutover on it.

**This is docs only — keep delta-green at 3.** Suggest splitting D into: (D-archive) the `git mv` + dead
remainder, and (D-rehome) the `update-system/` re-home + index-pointer reconciliation. Each green.
**Log anything left** if you bound coverage (silent partial = reads as "done" when it isn't).

After D, **run the C.6/Section-D link audit** (no broken relative links into `_archive/` from live docs;
the `_archive/` internal cross-links may dangle — accept) and a final residual-marker grep. Then
**Phase 3 is CLOSED.**

## 4. Flagged for the maintainer (decide during the review)

- **Managed `defaults/managed/.claude/rules/memory-policy.md`** ("vault-synced" → machine-local STATE)
  is **baked into the image + non-overridable → only takes effect after `cco build`**. The edit is
  committed (A/B `5c6ad29`); flag that a rebuild is needed for it to go live.
- **`docs/maintainer/integration/docker/design.md`** compose `build.context: ../../` is now strictly
  inconsistent (the generated compose lives in STATE, not in-repo) — left unchanged pending a
  build-context decision.
- **`docs/reference/cli.md`** has **no standalone `cco template update` subsection** (templates ride the
  pack update path) and intentional section-number gaps where removed verbs lived — confirm acceptable.
- **`.claude/rules/update-system.md:20`** "vault capabilities" example: a **user-owned rule** — per the
  memory-policy rule, **propose the swap to the maintainer, do not auto-edit**.

## 5. What landed this session (for the review)

**P3-4 → ADR-0027** (`docs/.../decisions/0027-…md`), 5 commits: `531a0f8` (ADR+design §7/inventory
A.1/roadmap) · `2783ce5` (D2 `--mount`) · `f590efe` (D3 narrow edit-protection; `/workspace/.claude`
kept rw after the managed `init-workspace`/`/init` write-conflict surfaced + maintainer-confirmed) ·
`871993e` (D1 config-editor built-in) · `3881aa4` (roadmap). **P3-5:** `5c6ad29` (A/B) · `141e24e` (C,
24 files). Two maintainer HITL rounds shaped P3-4 (D1/D2/D3 + the narrow-guardrail refinement). Suite
**936/3** throughout. Next free ADR = **0028**.

## 6. After Phase 3 → Phase 4 (sharing core)

Run a **P3→P4 adherence audit** at the boundary. Phase 4 lands (see `Y-handoff-implementation.md` §6):
`source`→DATA relocation + field rename + `publish_target` re-derivation (ADR-0022 D1); manifest **code**
removal / structure-based discovery / `lib/manifest.sh` + `cco manifest` deletion; sync-before-publish
3-way merge; the 2×2 publish/install/export/import wiring; project-publish/install removal; the **tier-2
legacy verbs + `@local` block** removal (build-once with their consumers); "config repo" → "sharing repo"
**code** paths. Pre-merge: dogfooding e2e on the Mac (`P2-dogfooding-validation.md` §3); never accept the
legacy-vault offer-to-remove until merged + validated.
