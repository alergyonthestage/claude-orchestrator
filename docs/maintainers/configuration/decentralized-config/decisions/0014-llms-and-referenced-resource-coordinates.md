# ADR 0014 — llms nature + the "referenced-resource coordinate" model (repos & llms)

**Status**: Accepted (2026-06-17)
**Deciders**: maintainer + design session
**Context docs**: `../analysis-roadmap.md` (R4), `../guiding-principles.md` (P1–P12 — **P12 added by
this session**), `../design.md` §2, `../resource-coherence-inventory.md`
**Related ADRs**: 0001 (decentralization), 0004 (config/STATE/CACHE), 0007 (system-dir locations —
this ADR **refines** its provisional `llms/ → CACHE`, conflict **C2**), 0010/0011 (tag nature & the
CLI-canonical→internal heuristic — **bounded** here by the team-share discriminator), 0012 (manifest
removed — the "resolve coordinates at the publish boundary, don't keep a redundant manifest" logic),
0013 (internal-metadata split — install-provenance `source` is internal/never-team, **distinct** from
the llms coordinate decided here)
**Resolves**: R4 (llms nature + shareable references). **Feeds**: the Cat-4 synthesis (one fewer
candidate — llms is config, not cat-4) and **M** (taxonomy). **Hands mechanism to**: **S**
(publish/install resolution + repo-side integration) and **M** (registry scope/namespacing).

---

## Context

R4 must establish (a) the **nature** of llms — re-fetchable downloads (→ CACHE) or hand-curated
config? — and (b) the **shareable-reference model**: what must travel so a third party (a teammate,
or the user's own 2nd PC) can fully **resolve** a project/pack that references llms. The analysis
surfaced that the question is **not llms-specific**: llms URLs and project **repo** URLs are the
**same data category** — *coordinates of by-name-referenced resources* — and must be designed
together.

## Finding (code-grounded) — two divergent models today

| | How referenced | Where the URL lives | DRY? | Travels? |
|---|---|---|---|---|
| **llms** | **by name** in `project.yml`/`pack.yml` `llms:`; reused by many consumers (`_llms_find_users`) | **once**, central `~/.cco/llms/<name>/.cco/source` (`url`+`variant`) | ✅ one update point | ❌ store is local (CACHE/ADR-0007) → **by-name doesn't resolve for a recipient** |
| **repos** | by name + **path** in `project.yml` `repos:` | **nowhere persistent** — `path` only; URL is **derived at publish** (`_sanitize_project_paths`: `git remote get-url origin`), injected into the published `project.yml`, read back at install (`_resolve_installed_paths`) | n/a (not stored) | ✅ at publish — but **absent for Axis-1** (own 2nd PC, no publish) → no auto-resolve |

- llms: **normalized** (one canonical URL, N by-name references) — good DRY — but the registry is
  **local**, so sharing breaks.
- repos: **ephemeral URL** (derived at publish, lost otherwise); the persistent local datum is the
  **machine-specific path** (`.cco/local-paths.yml`, internal, never synced — gitignored
  `cmd-vault.sh:72`). So a synced/working `project.yml` carries **no URL** → the user's 2nd PC cannot
  auto-resolve.

**Why option A (inline the URL into each consumer manifest) is rejected**: it would **denormalize**
the llms URL into N copies → an **update anomaly** (change the URL ⇒ edit N manifests). It *introduces*
to llms a duplication that does not exist today; repos avoid it precisely by **not storing** the URL
inline. Denormalization is the wrong direction.

## Decision

### D1 — llms content is re-fetchable → CACHE; hand-curated llms is **not** supported

No code path creates or edits an llms entry by hand (install **requires a URL**; `rename` touches only
the handle; the only "manual" act is choosing variant/name = *selection*, not authoring). No concrete
case for a locally-authored llms was found. → the **content `llms*.txt` is regenerable → CACHE,
`never`-synced** (each PC/teammate re-fetches). This **confirms** ADR-0007's `llms/ → CACHE` **for the
downloads only** (see D3).

### D2 — The "referenced-resource coordinate" model (repos & llms), unified — **option C**

A resource **referenced by name** from a manifest decomposes into data with **different sync-profiles**
(P3/P4); co-locate by profile, not by functional domain:

| Datum | Nature | Bucket | Sync | Realization |
|---|---|---|---|---|
| **name (id)** — the reference handle | config | the consuming manifest | both (with the manifest) | travels with `project.yml`/`pack.yml` |
| **coordinate** `name→url` (+`variant` llms / `ref` repo) | **config** (user-known locator) | a **canonical registry, stored once** (placement → M) | **cross-PC synced** (Axis-1) **+ resolved-at-publish for the team** (never publish the whole registry) | enables **auto-resolve** (clone/fetch) |
| **local-path** (repos only) | internal | `.cco/local-paths.yml` | **local-only, never synced/shared** | explicit `cco … resolve` per PC |
| **content** (llms only) | re-fetchable | **CACHE** | `never` | re-fetched from the coordinate |
| `etag`/`resolved_url`/`downloaded` (llms) | cache-state | CACHE | `never` | re-derived on fetch |

> **Placement REFINED by ADR-0016 D2 (forward-annotation; the row above is kept as
> written):** the coordinate is **embedded per-unit in the versioned manifest**
> (`project.yml`/`pack.yml`, the `package.json` model), **NOT** a central registry — the
> by-construction-shared repo has **no publish boundary** to inject a registry at (P5).
> The *category* (config, user-known locator) and the *DRY-by-name* intent stand; only the
> "canonical registry, stored once" placement is superseded (see also ADR-0016 D8, which
> forbids a central coordinate-registry file). The repos-only `local-path` row likewise
> moves into the STATE **index** (ADR-0016 D4), not a per-repo `.cco/local-paths.yml`.

The **coordinate is unified** across repos and llms (same data category: `name→url`); only the
**resolution backend differs** (repo → `git clone` into a local-path, interactive, per-PC; llms →
fetch into CACHE, automatic). The key cut is **`name→url` (synced + shared) vs `name→local-path`
(local-only)** — same functional domain, opposite sync-profiles → **separate stores** (exactly the
`source`-vs-`base/` cut of ADR-0013).

**Why C over B** (B = keep per-type handling; llms its own registry, repos their derived-at-publish
URL): C **subsumes** B, fixes the **repo Axis-1 gap** (URL becomes a persisted, synced coordinate
instead of ephemeral), preserves DRY for both, and gives **one** coordinate concept. B leaves two
mechanisms and the repo gap unresolved.

### D3 — Nature: the coordinate is **config**, not internal (and not cat-4)

The CLI-canonical→internal heuristic (ADR-0011, used for tags) is **bounded** here by a discriminator:
**a datum that must be team-shared cannot be internal** (P6: internal is never-team) → it is **config**.
The coordinate URL **must** reach teammates so they can resolve a shared resource ⇒ **config** (the CLI
is merely the editor; the *value* is the user's knowledge — literally like a repo URL in a shared
`project.yml`). Therefore:
- llms is **removed from the Cat-4 candidate set** (cat-4 = internal-but-synced **never-team**; the
  coordinate is config + **team-shared**).
- This is **distinct** from R3's install-provenance `.cco/source` (ADR-0013): that is **internal,
  never-team, cco-derived** (a teammate re-establishes their own on install) → it **stays** a cat-4
  candidate. **Two different files/scopes; keep them separate.**
- ADR-0007 / conflict **C2** refined: only the llms **content/downloads** → CACHE; the **coordinate**
  (url+variant) → **config** (synced Axis-1; carried to team at publish).

### D4 — Scope: what R4 fixes now vs what is handed off

- **R4/ADR-0014 (now)**: classifies **llms fully** under C; establishes the **referenced-resource
  coordinate category** and its tri-partite cut; fixes the **nature** (content→CACHE; coordinate→
  config synced+shared, DRY-by-name; local-path→internal-local); rejects inline-A; refines C2; removes
  llms from cat-4; records **principle P12** + the reusable **analysis method** (below).
- **→ M (taxonomy)**: the **registry scope** (global vs per-project) and **name namespacing** across
  repos+llms; the consolidated `resource → (bucket, sync-profile)` placement of the coordinate registry.
- **→ S (sharing/resolve mechanism)**: the **publish-boundary resolution** (inject referenced
  coordinates into the shared bundle, as repos already do for URLs), the **repo-side integration**
  (persist URL as a synced coordinate, closing the Axis-1 gap), schema change to the `llms:`/`repos:`
  references + migration. Consistent with ADR-0012's structure-based, no-redundant-manifest direction.

## Method & reasoning — the analysis lens (persisted as a reusable model)

This verdict came from a repeatable lens, recorded here and distilled into `guiding-principles.md`
(P10 method lessons, ADR-0014) for future analyses:

1. **Ground in code first** — current state, role, how each datum is *mutated* — before classifying
   (P10). (Here: where URLs live, who writes them, how publish/install resolve.)
2. **Decompose the resource into its constituent data** — a file/resource rarely has a single
   profile (an llms entry = content + coordinate + cache-state; a repo reference = name + url +
   local-path).
3. **Classify each datum on the orthogonal pair** *resource-type* (config/internal/state/cache) ×
   *sharing-sync-profile* (none/Axis-1/team/both) — P1/P3/P4.
4. **Apply the defined principles as discriminators** — here **P6** (team-shared ⇒ not internal,
   which fixed the config-vs-internal nature) and **DRY** (a canonical value is stored once,
   referenced by-name, never duplicated — which killed option A).
5. **Heterogeneous profiles within one file = split signal** → co-locate by profile (the `name→url`
   vs `name→local-path` cut).
6. **Separate the canonical datum from its references and its local materializations; resolve at the
   boundary** rather than duplicate eagerly (normalization over denormalization).
7. **Fix nature/classification now; hand mechanism to the owning analysis (S/M); leave cross-cutting
   verdicts (cat-4) to their synthesis.**

This *(resource-type × sharing-type) + DRY + principle-coherence + decompose/split + resolve-at-
boundary* lens is the reusable take-home of the session.

## Alternatives Considered

| Alternative | Pros | Cons | Verdict |
|---|---|---|---|
| **A — inline `url+variant` into each `llms:`/`repos:` reference** | self-contained; travels by construction | **denormalizes** → update anomaly (N edits); regresses llms's existing DRY; repos avoid it by not storing URL | **Rejected** |
| **B — per-type: llms keeps its local registry; repos keep derived-at-publish URL** | minimal change | leaves the **repo Axis-1 gap**; two mechanisms; llms registry still doesn't travel | **Rejected** (subsumed by C) |
| **C — one unified `name→url(+variant/ref)` coordinate registry: config, synced cross-PC + resolved-at-publish; local-path stays internal-local; content→CACHE (chosen)** | DRY for both; fixes repo Axis-1 gap; one coordinate concept; principled sync-profile cut; coherent with ADR-0012 | registry scope/namespacing + repo integration + resolve mechanism are new work (→ M/S); `llms:`/`repos:` schema change + migration | **Accepted** |
| **hand-curated llms as config in `~/.cco`** | supports a local-authored doc | no code path, no concrete need (YAGNI) | **Rejected** |

## Consequences

**Positive** — one coherent model for referenced-resource coordinates (repos + llms); DRY preserved
(one URL, N by-name references); the **repo Axis-1 auto-resolve gap is closed** by persisting the URL
as a synced coordinate; clean sync-profile separation (`url` config-synced-shared · `local-path`
internal-local · `content` CACHE); one fewer Cat-4 candidate; ADR-0007/C2 refined precisely; a reusable
analysis method captured (P12 + P10 method lesson).

**Negative** — registry scope/namespacing (global vs per-project) is deferred to M; the repo-side
integration + publish-boundary resolution + schema change/migration are new work owned by S; the
existing llms `.cco/source` is re-scoped (the authoritative `url+variant` becomes the synced
coordinate; the file shrinks to cache-state or folds into the registry — finalized in M).

## Reuse / Drop / Build-new

| Element | Verdict |
|---|---|
| llms by-name references in `project.yml`/`pack.yml`; `_llms_find_users` reuse model | **Reuse** |
| repo URL derivation/injection at publish (`_sanitize_project_paths`); install resolve (`_resolve_installed_paths`); `.cco/local-paths.yml` (name→path, internal-local) | **Reuse / generalize** into the coordinate model (→ S) |
| llms content download/`update` (etag) → CACHE | **Reuse** (relocate per ADR-0007) |
| unified `name→url(+variant/ref)` coordinate registry (config, synced + resolve-at-publish); persisting repo URL for Axis-1 auto-resolve; `llms:`/`repos:` schema + migration | **Build-new** (M scope + S mechanism) |
| inlining URLs per-manifest (option A) | **Drop** (never adopt) |

## Open (deferred, not unresolved)

- **M** — coordinate registry **scope** (global vs per-project) and **name namespacing** across
  repos+llms; consolidated placement of the registry bucket.
- **S** — publish-boundary **resolution** of referenced coordinates; repo URL **persistence** (close
  Axis-1 gap); `llms:`/`repos:` **schema change + migration**.
- **Cat-4 synthesis** — unaffected by llms (now config, not a candidate); R3's install-provenance
  `source` + de-tokenized registry remain the candidates.
- Whether a repo coordinate needs a **`ref`** (branch/commit) field alongside `url` — confirm in M/S.
