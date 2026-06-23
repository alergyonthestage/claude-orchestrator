# P3-4 + P3-5 — config-editor rehome + shipped-behavior doc cutover sweep (launch handoff)

**Purpose.** Launch the **final two Phase-3 commits** in a fresh session, after **P3-1/P3-2/P3-3/P3-3b
are DONE** (the decentralized `cco start` runtime, `cco tag`/`cco config`, the vault/profile world
removed, and `cco init` = the single decentralized project entry verb). Baseline **921 passed / 3 failed**
on `feat/vault/decentralized-config` (commits **local** — maintainer pushes from the Mac). This file is
self-contained. Produced 2026-06-23.

After P3-4 + P3-5, **Phase 3 (legacy cutover) is CLOSED** and the next session opens Phase 4 (sharing core).

## 0. Authoritative methodology (unchanged)

The **`decentralized-config` design IS the law**, in precedence order: `guiding-principles.md` (P1–P18) →
the ADRs (0005–0026) → living `design.md` → `requirements.md`. The more specific/authoritative wins;
**record any reconciliation**; a genuine design gap ⇒ **PAUSE and discuss** (a real example: P3-3b's
build was re-sequenced into two commits after code-grounding surfaced the global-retarget blast radius —
ADR-0026 Implementation note). Non-negotiables: **build-once final form**; **AD12 breaking cutover**
(new layout only, no aliases for removed verbs); **each commit leaves cco runnable + the suite
delta-green** (= the **3** P4–5 sharing baseline failures: `test_resolve_name_from_full_variant_url`,
`test_publish_ignore_path_patterns`, `test_project_internalize_updates_base`); **maintainer-confirm** any
UX/interface/placement choice (present options + a spec-grounded recommendation, persist, then act);
**code-ground every claim** (line numbers drift — re-read); **bash 3.2 / macOS** throughout;
**self-development caveat** (edits to `config/`, `Dockerfile`, baked `defaults/managed/**` are NOT live this
session — they need `cco build`).

**Doc-lifecycle (`.claude/rules/documentation-lifecycle.md`) governs P3-5.** Three classes: decision/analysis
records = **immutable history** (forward-annotate, never rewrite); living design/architecture/guides =
**rewritten in place to truth, no "SUPERSEDED" banners**; removed-feature design with no living successor =
**archived to `_archive/` at cutover**. **Timing**: shipped-behavior docs are rewritten at the phase that
makes the change true — P3 is that phase, so the sweep is now correct (never ahead of code).

## 1. First action (MANDATORY) — P3-3b→P3-4 adherence audit

Run the recurring **`implementation-review-handoff.md`** playbook (read-only, code-grounded, the
Transitional Registry §4 lens) scoped to the **P3-3b boundary** *before* writing P3-4 code, with clean
context. Confirm: (a) baseline is exactly **921/3** (`CCO_ALLOW_HOST_RESOLVE=1 ./bin/test`); (b) the
`cco init` transform + global-home cutover are conformant to ADR-0026 + design §2.3/§7; (c) the
Transitional Registry is intact — **tier-2 legacy project-verbs** (`cco project resolve` / `validate <name>`
/ `add-pack` / `remove-pack` / `delete`) and the **`@local` sanitize/extract/restore block** are STILL
present (they die in **P4** with their publish/install/query consumers — do **not** delete them in P3-4/5);
(d) `_resolve_template_vars` now lives in `cmd-template.sh` (relocated from the deleted
`cmd-project-create.sh`) and is still consumed by `cco project install`/`update`. Record a one-line
confirmation, then proceed. A genuine gap ⇒ PAUSE.

## 2. Baseline & context to load

1. `guiding-principles.md` P1–P18. 2. `design.md` §2.3 (`~/.cco`), §2.4 (`project.yml` coordinate schema),
§6.2 (Domain-B sharing), §7 (command surface), §9 P3. 3. **`resource-coherence-inventory.md`** — the
**authoritative P3-5 driver** (Sections A–D, with file:line targets + old→new markers). 4.
`.claude/rules/documentation-lifecycle.md`. 5. ADRs 0005 (dual `.claude` scope), 0008 (`~/.cco` management),
0012 (no manifest), 0018 D1 ("Config Repo" → **sharing repo** / **config bucket**), 0024 (`.claude` scope
reach). 6. The personal progress note `decentralized-config-impl-progress.md` (live cursor). 7. The code in
§3/§4.

**Baseline check (do first):** `git status` clean on `feat/vault/decentralized-config`; run
**`CCO_ALLOW_HOST_RESOLVE=1 ./bin/test`** → **921 passed / 3 failed** (the 3 above). A different set ⇒ stop
and reconcile.

## 3. P3-4 — config-editor rehome (5e)

The `config-editor` is the special project whose purpose is to **edit the user's own cco config**. It is a
**host-side template** (`templates/project/config-editor/`, NOT baked). Today it mounts the legacy central
`user-config/` and tells the user to run `cco vault save`. Both are dead post-cutover.

**Files (re-read — line numbers drift):**
- `templates/project/config-editor/project.yml` — `repos: - path: {{CCO_USER_CONFIG_DIR}}` (legacy
  `path:` schema + central store) and `extra_mounts: - source: {{CCO_REPO_ROOT}}/docs` (legacy `source:`).
- `templates/project/config-editor/.claude/rules/config-safety.md:15-17` — `cco vault save` / `cco vault
  diff` / "Config Repo" references.
- `templates/project/config-editor/.claude/skills/{setup-pack,setup-project}/SKILL.md` — write into
  `user-config/packs|templates/`; reference the vault.
- `templates/project/config-editor/.claude/CLAUDE.md` — describes editing `user-config/`.
- Mirror skills exist in `internal/tutorial/.claude/skills/{setup-pack,setup-project}/` (P3-5 / tutorial
  rewrite — A.4; keep them consistent).

**Two design questions to settle FIRST (maintainer-confirm — these are not mechanical):**

1. **How is config-editor instantiated now?** `cco project create --template config-editor` was the entry
   and it is **deleted** (P3-3b); `cco init` has no `--template`. Options: **(a)** make config-editor a
   **built-in launched like the tutorial** (`internal/`-style, `cco start config-editor`, no scaffold —
   the tutorial precedent, `internal/tutorial/`); **(b)** a dedicated `cco config edit` verb that spins up
   the session; **(c)** defer config-editor to post-v1 and drop the template now. Recommendation to
   evaluate: **(a)** — it matches the tutorial model (a framework-provided, non-scaffolded session) and
   needs no new verb. Confirm before building.
2. **How does the session edit `~/.cco` path-free?** Committed config must stay machine-agnostic
   (AD3/G8) — no real host path in a committed `project.yml`. `~/.cco` is a per-machine host path. If
   config-editor is a **built-in** (option a), it is generated/mounted at `cco start` time (like the
   tutorial's runtime materialization) so the host path is injected by the launcher, never committed —
   which sidesteps the schema entirely. If it stays a template, the `~/.cco` mount needs a launcher-side
   special-case (not a committed coordinate). Settle this with question 1.

**Once the model is settled, the mechanical rehome:**
- Mount **`~/.cco`** (the personal store) instead of `user-config/`; docs mount stays read-only.
- `config-safety.md`: `cco vault save` → **`cco config save`**; `cco vault diff` → **`cco config diff`**
  *(verify the verb exists — P3-2b shipped `cco config save/push/pull`; `cco config diff`/`validate` were
  deferred to P5, so reword to what actually ships, e.g. `git -C ~/.cco diff` or `cco config save` review)*;
  "Config Repo" → **sharing repo** (ADR-0018 D1).
- `setup-pack`/`setup-project` skills: write into **`~/.cco/packs|templates/`**; drop vault language.
- `CLAUDE.md`: describe editing `~/.cco`.
- If it stays a template, convert `project.yml` to the **coordinate schema** (no `path:`/`source:`).

**Self-development caveat:** these are host-side template/skill/rule files (not baked) — edits ARE live for
a fresh `cco start` next session, but NOT for the running session.

**Tests:** config-editor has no dedicated suite today; add light coverage for the chosen instantiation
path (e.g. `cco start config-editor` resolves + mounts `~/.cco`) if it becomes a built-in. Delta-green
stays 3.

## 4. P3-5 — shipped-behavior doc cutover sweep (5f)

**Inventory-driven — `resource-coherence-inventory.md` is the checklist (Sections A–D, file:line).** Do NOT
re-derive; execute it. This is the phase where shipped-behavior docs become true (doc-lifecycle timing).
Highlights (see the inventory for the complete list + exact lines):

- **A** templates/skills/agents: A.1 config-editor (done in P3-4), A.4 `internal/tutorial/` substantial
  rewrite (rides cutover), A.2 base-template comment nits (incl. the base `project.yml` llms/github comment
  staleness deferred from P3-3b), A.3 verified-clean.
- **B** managed + infra: **B "HIGHEST"** = `defaults/managed/.claude/rules/memory-policy.md:13,31`
  "machine-synced via vault" / "vault-synced" → **"machine-local STATE, not synced (v1)"** (ADR-0009).
  **It is baked in the image + non-overridable + ACTIVELY FALSE post-cutover → needs `cco build`** (flag
  to the maintainer; the edit is host-side but only takes effect after a rebuild). Also
  `docs/reference/context-hierarchy.md` (managed-rule change note) and `.gitignore` dead `/user-config/`
  entries + new `<repo>/.cco/secrets.env` ignore.
- **C** documentation: C.0 README (heavy), C.1 full-rewrite removed-feature sections, C.2 the "contract"
  docs (`user-config/` remap + diagrams), C.3 onboarding/concepts/knowledge-packs (structural — drop
  `cco manifest`/`manifest.yml`, "Config Repos" → sharing repo, `cco vault push` → `cco config push`,
  central `user-config/llms/` → CACHE content + per-unit coordinate), C.4 mechanical path/command subs,
  C.5 roadmap reconcile, C.6 docs index/nav READMEs, **C.7 ADR-0024 shipped-behavior additions** (multi-
  project / `.cco`-vs-`.claude` scopes), and the global **"Config Repo" → "sharing repo"** context-sensitive
  rename (NOT a blind `s///` — the third-repo concept survives; legend in the inventory).
- **D** maintainer-design history subtrees (vault / config-repo / resource-lifecycle, ~15 files describing
  **removed** mechanisms): **archive to `_archive/`** at cutover per the doc-lifecycle rule — re-home any
  surviving concept into a living doc first; update area-index "canonical source" pointers; dangling
  back-references from frozen ADRs are accepted.

**This is large and low-risk (docs only) but easy to do partially.** Consider splitting P3-5 into a few
commits by inventory section (A/B · C · D), each green. **Log what is left** if you bound coverage —
silent partial sweeps read as "done" when they aren't.

## 5. Invariants (never violate)

- **AD12** new layout only; **AD3/G8** no real path in committed config; **doc-lifecycle** timing
  (shipped-behavior now, at the phase that makes it true; archive removed-feature design, don't delete).
- **Do NOT delete the P4-deferred transitionals**: tier-2 `cco project resolve/validate<name>/add-pack/
  remove-pack/delete`, the `@local` sanitize/extract/restore block, `lib/manifest.sh` + `cco manifest` code
  (discovery-before-delete), and `source`→DATA relocation — they die in **P4** with their consumers (see
  the P3 handoff §7 + the Transitional Registry). P3-5 only fixes *docs* that describe them as the way the
  shipped tool behaves; the **code** stays until P4.
- Delta-green stays **3**; **`cco build`-gated edits** (managed `memory-policy.md`, `context-hierarchy.md`)
  must be flagged — they are not live this session.

## 6. After P3 (→ Phase 4, sharing core)

Run a **P3→P4 adherence audit** at the boundary first. Phase 4 lands: `source`→DATA relocation +
field rename + `publish_target` re-derivation (ADR-0022 D1); manifest **code** removal / structure-based
discovery / `lib/manifest.sh` + `cco manifest` deletion (F14); sync-before-publish 3-way merge fix; the 2×2
publish/install/export/import verb wiring; project-publish/install removal; the **tier-2 legacy verbs +
`@local` block** removal (build-once with their consumers); "config repo" → "sharing repo" **code** paths.
See `Y-handoff-implementation.md` §6 for the full deferred list.

Next free ADR = **0027**. Pre-merge: dogfooding e2e validation on the Mac
(`P2-dogfooding-validation.md` §3) before develop/main; never accept the legacy-vault offer-to-remove until
merged + validated.
