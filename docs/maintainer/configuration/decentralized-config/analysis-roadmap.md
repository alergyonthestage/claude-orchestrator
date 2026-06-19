# Decentralized cco Config — Analysis Roadmap

**Status**: Living tracker (started 2026-06-16). Orders the remaining design analyses by
dependency/convenience so each runs in its **own clean session** without losing context.
**Foundation**: every analysis opens by reading **`guiding-principles.md`** (P1–P17, source of truth;
P13–P17 added by the S cycle) and validates its decisions against it. Decisions are recorded as ADRs + propagated to `design.md`,
`requirements.md`, and `resource-coherence-inventory.md`.

> **Method (P10 + ADR-0011)**: classify each resource from its **role + problem solved + principles**,
> never from its current surface/path. A borderline resource gets its **own clean session**; correct
> placement needs undivided context on that resource's purpose. Each analysis validates resources
> **one-by-one**: (1) **current-state recap (code-grounded)**; (2) state role + problem solved;
> (3) classify on both axes (destination P2 + sync-profile P3) via P1–P9; (4) flag/resolve conflicts
> with `design.md`/ADRs; (5) **maintainer confirm/reject** on UX/usage-impacting choices (interface,
> sync strategy) — not derivable from code alone; (6) record an ADR + propagate to living docs; (7)
> mark `DONE` here.
>
> **Lessons (ADR-0011)**: *don't discard/accept a priori* — classify only from the validated role (a
> first pass mis-classified tags from the *absence* of a CLI). **Cross-cutting verdicts are
> synthesised, not per-resource** — the 4th-category existence is decided by a dedicated **Cat-4
> synthesis** over *all* candidates (R1–R4), not inside any single resource analysis.

---

## Completed (config design)

| Item | Output |
|---|---|
| RD-claude-mount / RD-paths / RD-home / RD-memory / RD-authoring | ADR-0005 / 0007 / 0008 / 0009 / 0010 |
| Cross-domain coherence review | `reviews/16-06-2026-design-coherence-review.md` |
| Resource-coherence inventory (old-model references) | `resource-coherence-inventory.md` |
| **Guiding principles (foundation, P1–P12)** | `guiding-principles.md` (P11 added by R3/ADR-0013; P12 + ADR-0014 method lesson added by R4; P2 4th-bucket **resolved** = XDG DATA by Cat-4/ADR-0015) |
| **Preliminary grounding** (destination + sync model) | folded into R1–R4 / M below |
| **S — sharing model unification** | ADR-0018 / 0019 / 0020 (P13–P17) |
| **V — impl-readiness review** (whole-scope, multi-agent ultracode) | `reviews/18-06-2026-impl-readiness-review.md` (58 findings + 5 critic; 37 decisions) |

---

## Post-V: cluster-by-cluster resolution (in progress, 2026-06-18)

V findings are resolved **cluster by cluster** with the maintainer, persisted to ADRs/design before E.
See **`W-handoff-cluster-resolution.md`** for the method + the open clusters.

| Cluster | Scope | Status |
|---|---|---|
| 1 — Migration safety | F1/F9/F10/F11/F12/F42/F43/F44 + new F59 | **RESOLVED & PERSISTED** → ADR-0021 (new) + ADR-0006/0009/0010 + design §7/§9/§11 + requirements FR-M1/M2 |
| 2 — Phasing & test-plan re-sync | F2/F7/F35/F36 + critic (test-suite teardown, entrypoint, secrets-env, spec.md, roadmap) | **RESOLVED & PERSISTED** → no new ADR; design §9/§11 6-phase map (E dissolved) + §6.2/§12 xrefs |
| 3 — Doc drift / re-sync | F3/F20/F21/F22/F23/F24/F30/F31/F32/F33 + critic | **Block A RESOLVED & PERSISTED** (rule `documentation-lifecycle.md` + design-intent re-sync + inventory); **Block B** rides the Phase-3 cutover |
| 4 — Coordinate model & resolution | F4/F6/F14/F15/F16/F17/F29/F37–F41/F45/F48/F56 | **RESOLVED & PERSISTED** → ADR-0022 (new) + forward-annot ADR-0016/0017/0018/0019 + design §2.2–§12 + requirements FR-Y-S6 |
| 5 — Command surface & UX | F13/F18/F19/F25/F26/F27/F34/F46/F47/F49/F50 | OPEN (next) |

---

## Analyses (ordered)

> The preliminary grounding (2 analysts, this session) produced a near-complete destination map and a
> sync-profile assignment, but the maintainer **reopened** three borderline classifications that the
> grounding had answered too quickly (tags/4th-category, manifest, internal metadata). Each becomes a
> dedicated role-first analysis (R1–R3) that feeds the consolidated mapping (M).

### R1 — tags nature & the Cat-4 method  ·  status: RESOLVED-PARTIAL (ADR-0011, 2026-06-17)
**Resolved (nature)**: the tag interface is **CLI-canonical** (`cco tag add/rm` + `cco list --tag`),
so by P1 tags are **internal** (cco-managed, not hand-edited) — correcting ADR-0010's provisional
"config" framing. Semantics unchanged (per-user, never-team, synced cross-PC). UX-confirmed by the
maintainer (CLI assign/filter >> hand-editing YAML; registry is a structured table, cf. `.git/index`).
**Deferred (placement + cat-4 verdict)**: `tags.yml`'s **physical bucket** (dedicated 4th
"internal-but-synced" bucket vs co-locate in `~/.cco`) and the **4th-category existence/membership**
are decided by the **Cat-4 synthesis** (new step below), since both depend on the full validated
candidate set (R1–R4). Selection rule: co-locate in `~/.cco` only if tags are the *sole* member;
else prefer a dedicated bucket. **Method correction recorded**: cat-4 is a *synthesis* verdict, not a
per-resource one — do not pre-judge. **Output**: ADR-0011 (+ `guiding-principles.md` P2/P10 +
`design.md` annotations updated). **Feeds**: the Cat-4 synthesis, then M.

### R2 — manifest.yml: role & necessity  ·  status: DONE (ADR-0012, 2026-06-17) — **REMOVE**
**Finding (code-grounded)**: every functional *read* of `manifest.yml` is discovery/validation
(`project/pack install`), both fully replaceable by navigating the Config Repo's predefined
structure (`templates/*/`, `packs/*/`) — each resource self-describes via its own
`pack.yml`/`project.yml`. No manifest-exclusive datum is consumed: descriptions come from
`pack.yml`; **repo URLs travel injected in the published `project.yml`** (`_sanitize` →
`_resolve_installed_paths`), **not** via the manifest; the manifest's `repos:url`, sharing tags,
and repo identity are **write-only**. The local `~/.cco/manifest.yml` has **no consumer**.
**Decision**: **remove `manifest.yml` entirely** — discovery becomes structure-based; delete
`lib/manifest.sh` + `cco manifest` + the `manifest_refresh`/`manifest_init` call sites. It is
**Domain-B** (Config-Repo-bound), **not** Axis-1 → **not a cat-4 candidate**. Write-only metadata
(repo identity, sharing tags, single-file catalogue) is dropped — re-add minimally only on real
need (YAGNI). **Output**: ADR-0012; the team-sharing **refactor is owned by S**. **Moots**
inventory open #1.

### R3 — Internal metadata & the unified update/merge mechanism  ·  status: DONE (ADR-0013, 2026-06-17)
**Resolved**: all in-scope files are **internal** → excluded a priori from `~/.cco`/`<repo>/.cco`
(P1/P6); they go to **STATE/CACHE/cat-4**, **centralized keyed-by-resource/project identity** even
as config decentralizes per-repo. This **dissolves** the dual-axis `<repo>/.cco` leak (internal data
no longer rides the repo remote) and closes inventory **C4**. STATE refined with a three-value
**sync class** (`never`/`opt-in`/`required`) + recommended internal partition (`/session` vs
`/update`) so the future P8 sync is allowlist-bounded. `.cco/meta` **split by responsibility**
(hashes/schema/policies/changelog→STATE·`never`; `languages`→**config/preference**, the one
exception; `remote_cache`→CACHE; flags→STATE). `base/`→**STATE, `never`-sync** (corrects today's
vault-sync; H6 merge-path refactor **accepted**). remotes **split** (token→STATE·`never`;
de-tokenized registry→**cat-4 candidate**). `source`→internal **cat-4 candidate** (sidecar dropped).
`pack-manifest`→**removed** outright (no migrator). **R3↔S boundary**: R3 owns local+Axis-1 (Class B);
team-sharing/publish-install/opinionated-package (A+C, P9)→**S**, consuming R3's shared-surface map.
**New principle P11** (three-question classification) added to `guiding-principles.md`.
**Output**: ADR-0013. **Feeds**: Cat-4 synthesis (`source` + registry candidates) + M.

<details><summary>Original reframing note (kept for context)</summary>

**status: REFRAMED → dedicated clean session**
**Scope (resources)**: `.cco/source` (project/pack/llms provenance), `.cco/meta` (a **grab-bag**:
schema/hashes/policies/changelog/languages/remote_cache/flags), `.cco/base/` (merge ancestors),
`.claude/.cco/pack-manifest` (legacy), remotes registry **+ tokens**.
**Reframed (this session, 2026-06-17)**: these files are all metadata serving **one** thing — the
resource **diff/update/merge mechanism** — and several **mix responsibilities with different
sync/sharing profiles in one file** (esp. `.cco/meta`). Placement can't be decided until the
mechanism's shape + the **team-shared ↔ private-multi-PC boundary** are framed. **Two-phase plan**:
**Phase 0** — cardinal points (resource classes A team-shared / B private-multi-PC / C cco
opinionated-as-external-package; per-datum: what/why/scope/sync-profile; the A↔B boundary; couples
with **S** + **P9**); **Phase 1** — split each file by profile & place each datum.
**Validated conclusions (carry forward)**: `source` = resource-coupled provenance (multi-PC synced
*with* the resource, **never team**); sidecar works for `~/.cco`-resident resources, but for
`<repo>/.cco` the repo remote couples sync+sharing (P5) so "multi-PC yes, team no" is **not**
expressible there → **cat-4 *location* reopened** for repo-scoped per-user data (OPEN, not settled); `.cco/meta` → **split by responsibility/profile** (update-state→STATE · languages→preference
· changelog→notification · remote_cache→CACHE); `.cco/base/` → **STATE, machine-local, NOT synced**
(corrects today's vault-tracking; same profile as meta-hashes → co-locate; H6 merge-engine refactor
cost); `pack-manifest` → **remove** (legacy, mooted by cutover); remotes → **split** (tokens→STATE
never-synced · de-tokenized registry→cat-4 candidate). **Principle**: *co-locate by sync-profile, not
just functional domain.* **Full context + open questions**: see **`R3-update-metadata-handoff.md`**.
**Output**: ADR(s) + feed M + the Cat-4 synthesis (source/remotes inputs). Absorbs H6/M3.
</details>

### R4 — llms: nature & shareable references  ·  status: DONE (ADR-0014, 2026-06-17)
**Resolved**: llms **content** = re-fetchable → **CACHE** (`never`-sync; hand-curated llms **not**
supported — no code path, YAGNI). The shareable-reference question generalized: llms URLs and project
**repo** URLs are the **same data category** — *coordinates of by-name-referenced resources* — designed
together (**model C, unified**). A referenced resource decomposes by sync-profile: **name** (config,
travels with the manifest) · **coordinate `name→url`(+variant/ref)** (**config** — team-shared ⇒ not
internal by P6; stored **once**/DRY; **synced cross-PC + resolved-at-publish for team**; enables
auto-resolve) · **local-path** (repos: internal, **local-only**, explicit `cco resolve`) · **content**
(llms: CACHE). **Option A (inline url per-manifest) rejected** (denormalization → update anomaly).
**Refines C2** (only llms *content*→CACHE; *coordinate*→config). **Removes llms from Cat-4** (config,
not internal-never-team); R3 install-provenance `source` stays a candidate (kept **distinct**). New
**principle P12** + **ADR-0014 method lesson** (the reusable analysis lens) added to
`guiding-principles.md`. **Output**: ADR-0014. **Hands to M** (registry scope/namespacing) **and S**
(publish-boundary resolution, repo URL persistence/Axis-1 gap, `llms:`/`repos:` schema + migration).

### Cat-4 — 4th-category synthesis  ·  status: DONE (ADR-0015, 2026-06-17) — **EXISTS = XDG DATA**
**Resolved**: the cross-cutting verdict R1 deferred. **(1) The 4th "internal-but-synced **never-team**"
category EXISTS** — none of config/STATE/CACHE expresses the `(internal · Axis-1 · never-team)` profile;
it is the XDG **DATA** tier, **completing** ADR-0007's CONFIG/DATA/STATE/CACHE map (DATA was left
unassigned). Location: **`$XDG_DATA_HOME/cco` → `~/.local/share/cco`** (override `$CCO_DATA_HOME`).
**(2) Membership** = `tags.yml` (R1) · **de-tokenized remotes registry** + **install-provenance
`source`** (R3) — `source` sync-class resolved to **`required`** (travels with its Axis-1-synced
resource; never-team via publish re-strip). **Excluded**: tokens (STATE·`never`, security), llms/repo
coordinate (config, P12), manifest (removed). **(3) `tags.yml` placement**: ≥2 members → selection rule
picks a **dedicated bucket** → `<DATA>/cco/tags.yml` (**not** `~/.cco`). **(informational, → T)**: one
git transport (ADR-0008) may serve DATA + STATE-`/session` + `~/.cco`, with a **per-store sync-class
allowlist** and separate dirs. Refines ADR-0007 §Decision-2 (registry STATE→DATA; token stays STATE).
**Output**: ADR-0015 (+ `guiding-principles.md` P2 + roadmap + inventory updated). **Feeds & unblocks**: M
(byte-level layout + registry scope/namespacing).

### M — Consolidated resource taxonomy & mapping  ·  status: DONE (ADR-0016 + ADR-0017, 2026-06-17)
**Resolved**: produced THE authoritative `resource → (bucket, mutator, sync)` table; rewrote
`design.md §2.1/2.2/2.3` to the **4-bucket** layout (CONFIG×2/DATA/STATE/CACHE); fixed conflicts
**C1–C4**; absorbed **H5/H6/M3**. **Two open decisions settled**: (1) **coordinate scope** = *per-unit,
embedded in the versioned manifest* (uniform `project.yml`/`pack.yml` schema, `package.json` model) —
**refines ADR-0014**: the maintainer surfaced that the by-construction-shared repo (P5) has **no
publish boundary**, so a central registry can't reach a repo-cloning teammate; source-of-truth = the
unit's manifest (repos self-heal from their git remote), cross-unit replication = intentional
independence, consistency **by tooling not storage** (`cco config coords --diff/--sync`), content→CACHE,
local-path→STATE index; (2) **DATA byte-level** = `tags.yml` (typed keys) · `remotes` · per-identity
standalone `source` files (upstream-only, `required`). Also fixed: the **STATE index subsumes** `@local`
+ per-repo `local-paths.yml` (byte-level, D4); **P12 refined**; opt-in `cco config validate` hook (D9).
**Output**: ADR-0016 + `design.md §2` rewrite + `guiding-principles.md` P12 + this roadmap + inventory.
**Hands to**: **S** (publish resolution, coordinate CLI + validation, `llms:`/`repos:` schema+migration),
**E** (H6 merge-path, M3 remote decoupling, index concurrency/H7).
> **Scaffold (history)**: `M-handoff-consolidated-design.md` — the cross-ADR end-state synthesis
> (4-bucket trees, consolidated table, legacy→new fan-out map, conflicts/open-decisions). Maintainer-
> validated 2026-06-17; consumed by ADR-0016.
> **M-review refinements → ADR-0017** (maintainer, same day): coordinate field semantics (url/ref
> optional, llms url mandatory, origin derivation, url-may-differ→warn); CLI consolidation (`cco resolve
> [--scan][--all]` absorbs `index refresh`; `cco start --from`; start-unresolved prompt); J0 bootstraps
> all 4 buckets incl DATA on any command; `~/.cco` always git-versioned + **public-remote allow+warn
> (resolves P3)**. Futures F1–F4 → S (Domain-B realignment) / T (DATA-STATE sync-engine).

### S — Sharing model unification  ·  status: DONE (ADR-0018 + ADR-0019 + ADR-0020, 2026-06-18)
> **Scaffold (history)**: `S-handoff-sharing-unification.md` (S1–S11 scope, consumed inputs, open
> decisions, reading order) — now resolved by ADR-0018/0019/0020.
**Resolved** across three ADRs:
- **ADR-0018 (sharing surface)**: nomenclature **config bucket vs sharing repo** ("config repo"
  retired); a symmetric **2×2 command matrix** (`publish`↔`install` for packs/templates; `export`↔
  `import` tar for all incl. projects); **projects do NOT publish/install** — `<repo>/.cco` rides the
  code-repo remote (P5/**P13**), the asymmetry is **inherent & kept** (reject `cco share` facade /
  packs-as-repos); sharing-repo structure = `packs/`+`templates/` only, **structure-based discovery**
  (manifest removed, ADR-0012), init-at-first-publish, merge-on-existing; **`cco update --check`**;
  **solo-adopter A+B v1, C post-v1** with reserved hooks (the A4 fallback folds here).
- **ADR-0019 (reachability & pack lifecycle)**: coordinate model **extended to packs**; **unified
  boundary-less reachability** (P-URL ≡ pack-reachability; layered embed/heal/validate, never
  hard-block, **P14**); **a shared resource's local copy is never its source** (DRY, **P15** — the
  maintainer correction); **working-copy lifecycle + sync-before-publish** fix (**P16**); **two
  resolution axes** (mount local-first vs update source-of-truth); **internalize-as-cache** (opt-in,
  last-layer, the sole cache exception; `export --bundle-packs` for tar dependency-closure); templates
  scaffold-only; the **coordinate CLI / `cco config validate`** reachability contract.
- **ADR-0020 (permissions)**: enforcement **delegated to git** (**P17**, like auth P7) — cco assists
  (optional `cco config protect`), never gatekeeps; sharing-repo whole-repo split + repo-splitting for
  read granularity; project-repo `<repo>/.cco` co-writability accepted; **S8 no-token-leak** invariant
  confirmed.
**Principles persisted**: `guiding-principles.md` **P13–P17**. **Propagated**: `design.md`
§2.1/§2.4/§6.2/§7/§12 + this roadmap + `resource-coherence-inventory.md` + `requirements.md` +
`docs/maintainer/decisions/roadmap.md`. **Hands to**: **E** (impl: manifest deletion, structure-based
discovery, sync-before-publish, 2×2 wiring, pack-coordinate schema + migration, `cco update --check`,
`cco config protect`, S8 checklist), **a dedicated post-v1 analysis** (solo-adopter Case C).

### T — RD-triggers / R-state-sync  ·  status: FUTURE
Background daemon / native hooks / git hooks vs manual-only (v1 = manual). Owns `~/.cco` background
auto-sync and **R-state-sync** (memory + transcripts cross-PC/cross-team opt-in, ADR-0009) — the future
STATE-sync category (P8). **From ADR-0017 (F4)**: the **DATA/STATE sync-engine choice** — git (ADR-0015
D6) is a *recommendation*, not a constraint; a more appropriate engine may fit, **evaluated
transversally with the project-sync daemon** (different scopes, possibly shared infra). **Depends on**:
R1–S settled.

### V — Impl-readiness review (whole-scope validation)  ·  status: NEXT (before E)
> **Start here**: `V-handoff-impl-readiness-review.md` — scope (all ADRs 0001–0020 + P1–P17 + living
> docs + code), **8 parallel review perspectives** (cross-ADR/principle coherence; design↔ADR↔req sync;
> completeness/gaps; ambiguity/impl-readiness; §9 phasing re-validation; code-grounding/feasibility;
> doc-coherence-sweep readiness; migration/cutover safety), method, reading order.
**Goal**: a **read-only validation gate** over the *entire* decentralized-config design **before**
implementation — find inconsistencies, gaps, ambiguities, cross-ADR conflicts, impl-readiness blockers
on paper (cheap to fix). The design grew across ~20 ADRs + refinement cycles; no pass has validated the
whole body as one. **Run in a clean session, ideally with parallel agents on different perspectives**
(multi-modal sweep → adversarial verify → dedup → severity-rank → completeness critic). **Output**:
`reviews/<date>-impl-readiness-review.md` (severity-ranked findings + maintainer-decision flags).
**Does NOT** write code or re-open settled decisions without a principle-level reason. **Then → E.**

### E — Implementation  ·  status: DISSOLVED into the dependency-layered phase map (design.md §9, Cluster 2, 2026-06-18)
The former "E" workstream is **no longer a separate timeline**. Cluster 2 of the V impl-readiness review
re-derived the implementation order from **dependency + reuse + open-closed** (build the most-reused
substrate first; build every module once in its final form) — design and UX unchanged, only the build
order. Every former "→ E" item now has a **phase home** in design.md §9 (Phase 0 substrate · 1 core ·
2 migration · 3 cutover · 4 sharing-core · 5 sharing-ext). Carried-item anchors: **H7** (index
concurrency/namespacing) → Phase 0 (where the index is born); **H6** (`base`/`meta`→STATE merge-paths)
and **M3** (remotes DATA/STATE split) → Phase 0 substrate (reused by update + sync-before-publish; M3
satisfies the Phase-5 S8 invariant by construction) — *classification absorbed by M/R3*; **H2**
(reminder-aggregator cost), **M1/M2** (sync edge cases + sync-state lifecycle) → Phase 1; **H8** (join
Case-C) → Phase 2; **M4/M5** (extra_mounts schema/migration) → Phase 0 (schema) + Phase 2 (migration).
Test contracts + existing-suite teardown: design.md §11.

---

## Dependency order
```mermaid
flowchart LR
  P["guiding-principles P1-P11 (done)"] --> R1["R1 · tags nature (done, ADR-0011)"]
  P --> R2["R2 · manifest (done, ADR-0012 → REMOVE)"]
  P --> R3["R3 · internal metadata (done, ADR-0013)"]
  P --> R4["R4 · llms & coordinates (done, ADR-0014)"]
  R1 --> C4["Cat-4 · synthesis (done, ADR-0015)<br/>EXISTS = XDG DATA; tags+registry+source"]
  R3 --> C4
  R4 --> C4
  C4 --> M["M · consolidated mapping (done, ADR-0016)<br/>4-bucket; coord per-unit; C1-C4 fixed; H5/H6/M3"]
  R3 --> M
  R4 --> M
  R4 --> S["S · sharing unification (done, ADR-0018/0019/0020)<br/>2×2 matrix; pack coordinates; reachability P14; DRY P15; permissions P17"]
  R2 -- "manifest removal → structure-based discovery" --> S
  M --> S
  C4 -.-> T["T · RD-triggers / R-state-sync (future); cat-4 ∩ P8 sync transport"]
  S --> V["V · impl-readiness review (NEXT) — whole-scope validation, parallel perspectives"]
  V --> E["impl · dependency-layered phases (design.md §9)<br/>P0 substrate · P1 core · P2 migration · P3 cutover · P4 sharing-core · P5 sharing-ext"]
  V --> T
  M -.-> E
```
**Recommended sequence**: R1 ✅ → R2 ✅ → R3 ✅ (ADR-0013) → R4 ✅ (ADR-0014) → **Cat-4 ✅ (ADR-0015 —
4th bucket EXISTS = XDG DATA)** → **M ✅ (ADR-0016 — authoritative table; 4-bucket §2 rewrite; coordinate
per-unit/`package.json` model; DATA byte-level; STATE index subsumes @local; C1–C4; H5/H6/M3)** → **S ✅
(ADR-0018/0019/0020 — sharing unification: 2×2 matrix, pack coordinates + reachability P14, DRY P15,
working-copy lifecycle P16, permissions delegated-to-git P17; manifest-removal realized; solo-adopter
A+B)** → **V (NEXT — impl-readiness review: whole-scope validation, parallel perspectives, read-only
gate)** → impl (dependency-layered phases, design.md §9; "E" dissolved, Cluster 2) → (T future).
**Config + sharing design CLOSED; V running cluster-by-cluster — Cluster 2 (phasing & test-plan) DONE.**

## Notes
- R1 is **resolved-partial** (ADR-0011): tag *nature* fixed (CLI-canonical → internal); the
  *4th-category verdict* + tag *placement* were **deferred** to the new **Cat-4 synthesis** step,
  because a cross-cutting verdict must be synthesised over *all* validated candidates, not decided
  inside one resource analysis.
- R2 is **DONE** (ADR-0012): `manifest.yml` is functionally redundant (every read is
  discovery/validation, replaceable by the Config Repo's directory structure) → **removed**; the
  team-sharing refactor is owned by S. Not a cat-4 candidate.
- R3 is **DONE** (ADR-0013, 2026-06-17): all in-scope internal-metadata files are **internal** →
  excluded from the config buckets and **centralized keyed-by-identity** in STATE/CACHE/cat-4 (config
  decentralizes, internal centralizes), which **dissolves** the dual-axis `<repo>/.cco` leak. `.cco/meta`
  split by responsibility; `base/`→STATE·`never`-sync (H6 refactor accepted); remotes split
  (token·`never` / registry→cat-4); `source`→cat-4 candidate (sidecar dropped); `pack-manifest`
  removed. STATE refined with a `never`/`opt-in`/`required` sync class. Principle **P11** added.
  Team-sharing (A+C) handed to **S** via R3's shared-surface map. Full context:
  **`R3-update-metadata-handoff.md`** (now annotated as resolved).
- R4 is **DONE** (ADR-0014, 2026-06-17): llms content → CACHE (hand-curated rejected); the
  shareable-reference question generalized into the **"referenced-resource coordinate" model** (repos
  + llms, **unified — option C**): reference by-name; one **canonical coordinate `name→url`(+variant/
  ref)** = config, synced cross-PC + resolved-at-publish (DRY, auto-resolve); **local-path** stays
  internal-local; **content** → CACHE. Inline-A rejected (denormalization). llms removed from Cat-4
  (config). New **P12** + **method lesson** (the reusable analysis lens) added. Registry
  scope/namespacing → M; resolve-at-publish + repo URL persistence + schema/migration → S.
- Cat-4 is **DONE** (ADR-0015, 2026-06-17): the 4th "internal-but-synced, never-team" category
  **EXISTS** = the XDG **DATA** tier (`$XDG_DATA_HOME/cco` → `~/.local/share/cco`, override
  `$CCO_DATA_HOME`), completing ADR-0007's CONFIG/DATA/STATE/CACHE map (DATA was unassigned). Members:
  `tags.yml` · de-tokenized remotes registry · install-provenance `source` (sync resolved to
  **`required`**). Tokens excluded (STATE·`never`, security); llms/repo coordinate excluded (config,
  P12); manifest removed. `tags.yml` placement → **dedicated bucket** (≥2 members ⇒ selection rule),
  `<DATA>/cco/tags.yml`. Transport ∩ P8 (one git engine, per-store allowlist) → informational, owned
  by T. P2 of `guiding-principles.md` updated (4th bucket now resolved). Byte-level layout + registry
  scope/namespacing → **M**. Refines ADR-0007 §Decision-2 (registry STATE→DATA; token stays STATE).
- M is **DONE** (ADR-0016, 2026-06-17): the authoritative `resource → (bucket, mutator, sync)` table +
  4-bucket `design.md §2` rewrite + C1–C4 fixes + H5/H6/M3. **Coordinate placement resolved per-unit,
  embedded in the versioned manifest** (uniform `project.yml`/`pack.yml` schema, `package.json` model) —
  **refines ADR-0014**: a maintainer-surfaced gap (the by-construction-shared repo, P5, has **no publish
  boundary** → a central registry can't reach a repo-cloning teammate). Source-of-truth = the unit's
  manifest (repos self-heal from their git remote); cross-unit replication = intentional independence;
  consistency **by tooling not storage**; content→CACHE; local-path→**STATE index** (subsumes `@local` +
  per-repo `local-paths.yml`, D4). **DATA byte-level** finalized (`tags.yml` typed keys · `remotes` ·
  per-identity standalone `source`). **P12 refined**; opt-in `cco config validate` hook (D9). Coordinate
  CLI + publish resolution + `llms:`/`repos:` schema/migration → **S**; H6/M3/H7 → **E**.
- M-review refinements (maintainer, 2026-06-17) → **ADR-0017**: coordinate field semantics (repo `url`
  optional/bootstrap, `ref` optional/default-branch, llms `url` mandatory, `origin` derivation,
  url-may-differ→**warn not enforce**); CLI consolidation onto **`cco resolve`** (`--scan` absorbs
  `index refresh`, `--all`) + **`cco start --from`** (Case-C source) + explicit prompt on
  start-with-unresolved; **J0** bootstraps all 4 buckets incl **DATA** on **any** command, per-root
  idempotent; **`~/.cco` always git-versioned**, remote opt-in private-default, **public allow+warn →
  resolves P3**. Futures F1 (local-file llms) · F2 (Case-C convergence merge, reuse 3-way) → §12; F3
  (Domain-B Config-Repo realignment) → **S**; F4 (DATA/STATE sync-engine choice) → **T**.
- S is **DONE** (ADR-0018/0019/0020, 2026-06-18): sharing model unified. **Config bucket vs sharing
  repo** nomenclature; **2×2 command matrix** (projects ride the repo remote — no publish/install,
  the asymmetry is inherent & kept, **P13**); **coordinate model extended to packs** with **unified
  boundary-less reachability** (layered embed/heal/validate, never hard-block, **P14**); **a shared
  resource's local copy is never its source** (DRY, **P15** — the maintainer's in-session correction
  captured as principle); **working-copy lifecycle + sync-before-publish** (**P16**); **two resolution
  axes** (mount local-first vs update source-of-truth); **internalize-as-cache** (opt-in, last-layer,
  the sole cache exception); templates scaffold-only; **permissions delegated to git, cco assists**
  (**P17**); S8 no-token-leak confirmed. Manifest-removal (ADR-0012) is realized via structure-based
  discovery. Opinionated-defaults-as-sharing-repo (F-opin) designed, migrated post-impl. New principles
  **P13–P17** added. Impl → **E**; solo-adopter Case C → dedicated post-v1 analysis.
- ADR numbers are assigned when each session runs (next free number; last used = **0020**).
