# ADR 0013 — Internal Metadata: all-internal, centralized, split by sync-profile

**Status**: Accepted (2026-06-17)
**Deciders**: maintainer + design session
**Context docs**: `../analysis-roadmap.md` (R3), `../R3-update-metadata-handoff.md`,
`../guiding-principles.md` (P1–P11 — P11 added by this session), `../design.md` §2,
`../resource-coherence-inventory.md`
**Related ADRs**: 0004 (config/STATE/CACHE separation), 0006 (breaking cutover, lazy migration),
0008 (sync transports, never fabricates), 0009 (memory as STATE), 0010/0011 (tag nature & the
Cat-4 method), 0012 (manifest removed)
**Resolves**: R3 (internal metadata & the unified update/merge mechanism) — Phase 0 framing +
the per-file nature/placement verdicts. **Feeds**: the Cat-4 synthesis (candidates: `source`,
de-tokenized remotes registry) and **M** (consolidated mapping). **Coordinates with**: **S**
(team-sharing / publish-install / opinionated-as-package) and **P9**.

---

## Context

R3's scope is five families of cco-managed metadata that drive the resource diff/update/merge
mechanism: `.cco/source` (provenance), `.cco/meta` (a grab-bag of ≥5 responsibilities), `.cco/base/`
(3-way merge ancestors), `.claude/.cco/pack-manifest` (legacy), and the remotes registry **+ tokens**.

Three analyst passes + maintainer review (see the handoff) showed these files are all metadata in
service of **one** thing — the update/merge mechanism — and that several mix responsibilities with
**different sync/sharing profiles in a single file** (esp. `.cco/meta`). The placement question could
not be answered until two things were framed: (a) the nature of these files (config vs internal), and
(b) the sync-profile of each datum they carry. This ADR fixes both, plus the boundary that hands the
team-sharing concern to **S**.

**Code-grounded current state** (the smell this ADR corrects):

| Datum | Today | Anchor |
|---|---|---|
| `.cco/base/` | **synced via vault** ("NOT gitignored — for merge reproducibility") | `lib/cmd-vault.sh:41` |
| `.cco/source*` | **synced via vault** (NOT gitignored) | `lib/cmd-vault.sh:41` |
| `.cco/meta` (global) | excluded from vault (machine-local) | `lib/cmd-vault.sh:55-56` |
| `<repo>/.cco/meta` | **travels on the repo's own git remote** (leaks machine-local state to teammates) | repo remote, not vault-governed |
| `.cco/remotes` (url+token) | excluded from vault (machine-local) | `lib/cmd-vault.sh:74` |
| `pack-manifest` | excluded; read once at `cco start` to clean legacy residue | `lib/cmd-vault.sh:64`, `cmd-start.sh:653` |
| `memory/` | **synced via vault** (D33) | `lib/cmd-vault.sh:43` |
| `claude-state/` (transcripts) | excluded (machine-local) | `lib/cmd-vault.sh:67-68` |

## Decision

### D1 — All in-scope files are **internal** → excluded a priori from the config buckets

By P1 (edit criterion: only `cco …` mutates them, never hand-edited from an IDE) and P6 (internal
data is hidden, never in a config repo), `source`, `meta`, `base/`, `pack-manifest`, and the remotes
registry are **internal**. They must **not** live in `~/.cco` or `<repo>/.cco` (P2: config buckets
hold **only** config). Their home is ∈ **{STATE, CACHE, cat-4}**.

**Corollary — config decentralizes, internal centralizes.** Per-project *config* is decentralized
into each `<repo>/.cco`, but per-project *internal metadata* is **centralized** in an internal bucket,
**keyed by project/resource identity** (e.g. `<STATE>/cco/projects/<name>/…`). This is coherent with
P1/P2/P6 and has a decisive consequence:

> **The dual-axis `<repo>/.cco` problem dissolves for internal metadata.** By extracting internal
> data out of `<repo>/.cco`, it no longer rides the repo's git remote — so it cannot leak to
> teammates (P5) and the "multi-PC yes, team no" tension (handoff open-question #2) **no longer needs
> a sidecar workaround**. The solo-adopter-in-team case (P5/A4) remains a separate, already-classified
> future exception, **out of scope here**.

This resolves inventory conflict **C4** (`.cco/source` / pack `.cco/meta` inside config buckets
violate P6). The "resource-coupled sidecar" realization for `source` is therefore **dropped** (it
would re-introduce internal data into a config bucket); `source` becomes centralized internal,
keyed by resource identity.

### D2 — STATE is refined: an internal **sync-eligibility** taxonomy

STATE today holds only session-state (transcripts, memory). Admitting cco machinery state is correct
by *nature*, but makes STATE heterogeneous **by sync-profile**. Every internal datum is classified on
a three-value sync axis:

- **`never`** — syncing **breaks cco**: `base/` (ancestor tied to the *local* framework version → a
  synced base would be the wrong merge ancestor across PCs on different cco versions), file hashes,
  `schema_version`, policies, `local_framework_override`, **and tokens** (security invariant).
- **`opt-in`** — desirable, deferred to the future R-state-sync (P8): `memory/`, transcripts/history.
- **`required`** — multi-PC by design (Axis-1, **never team**): cat-4 candidates (`tags.yml`,
  de-tokenized remotes registry, possibly `source`).

**Recommendation (design-motivated refactor, accepted under D5): partition STATE internally by
sync-eligibility, not only by functional domain** — e.g. `<STATE>/cco/session/` (P8 opt-in) vs
`<STATE>/cco/update/` (never-sync machinery). This gives the future P8 transport a clean
**allowlist boundary** so it can never sweep base/hashes/tokens into a memory/history sync. It is the
"co-locate by sync-profile" principle applied *inside* STATE. The exhaustive layout is finalized in
**M**; this ADR fixes the principle.

### D3 — Per-datum verdicts (split `.cco/meta`; place each datum)

| Datum | Nature | Bucket | Sync | R3 / S | Notes |
|---|---|---|---|---|---|
| `source` (provenance) | internal | **cat-4 candidate** | required? / `never`+reinstall | shared | verdict → Cat-4 synthesis |
| `base/` (merge ancestor) | internal | STATE `/update` | **never** | shared (merge engine) | corrects today's vault-sync; H6 refactor (D5) |
| `meta.manifest` (file hashes) | internal | STATE `/update` | `never` | local | 3-way change detection |
| `schema_version` / policies | internal | STATE `/update` | `never` | local | migrations |
| changelog markers (`last_seen/read_changelog`) | internal | STATE `/update` | `never` | local | sync would only de-dupe (minor) |
| `remote_cache` (remote HEAD + ts) | internal | **CACHE** | `never` (regenerable) | shared | avoids network on update checks |
| `local_framework_override` | internal flag | STATE `/update` | `never` | local | escape hatch |
| `languages` | **config / preference** | `~/.cco` (config) | n/a (config sync) | local | **the one exception** — see D4 |
| remotes **token** | internal secret | STATE (isolated) | **never** | shared | already excluded today ✓ |
| de-tokenized remotes registry (name→url) | internal | **cat-4 candidate** | `required` | shared | today *not* synced → becomes synced (enhancement) |
| `pack-manifest` | legacy | — | — | — | **remove** (D6) |
| `memory/` · transcripts | STATE session | STATE `/session` | `opt-in` (P8) | local | unchanged direction |

### D4 — `languages` is the single non-internal exception → **config / preference**

Once `.cco/meta` is split, `languages` (which regenerates the user-facing `language.md`) is a genuine
**user preference**, not machinery. By P1 it is **config** and belongs in the config bucket (`~/.cco`),
following normal config sync — **not** STATE. It is the lone datum in R3's scope that escapes the
"all internal" rule.

### D5 — Design-motivated refactors are accepted

Relocating `base/` to STATE requires passing STATE paths into the merge functions (the **H6** cost:
`_merge_file` / `_resolve_with_merge` assume `base/` is co-located with the scope's `.claude/`).
This refactor is **accepted** because it is motivated by a correct sync-profile and respects the
cardinal principles. Same for STATE internal partitioning (D2).

### D6 — `pack-manifest` is removed outright

The pack-manifest is pre-ADR-14 cleanup residue; ADR-14 mounts packs `:ro` (no copy) so nothing
writes it anymore. With the Phase-3 breaking cutover (ADR-0006, store recreated) the "pre-ADR-14
residue" case does not exist. **Remove the mechanism** (`_clean_pack_manifest`, the `cmd-start.sh`
read, `_cco_project_pack_manifest`) — **no one-shot migrator** (YAGNI; consistent with the manifest.yml
removal, ADR-0012). Lean direction: remove complexity where it serves nothing.

### D7 — R3 ↔ S boundary

R3 owns the internal metadata of the **local + cross-PC-user (Axis-1)** update/merge mechanism. The
**team-sharing / publish-install / opinionated-defaults-as-external-package (Class C, P9)** dimension
is a separate analysis **coordinated with S**. R3 contributes the **shared-surface map**: machinery
common to both paths — the **3-way merge with `base/`** (used for opinionated-default updates *and*
installed-resource updates), `source` provenance (drives `cco update` of installed resources), the
remotes registry + token (auth for install/update), `remote_cache` (remote checks). S must not
re-derive these; it consumes this boundary.

## Resource classes framing (Phase 0 cardinal points)

The mechanism serves three resource classes; the A↔B boundary is set as: **R3 = local + B**, **A + C
→ S**.

- **(A) Team-shared incoming** — packs/templates installed from a Config Repo (Axis-2). → S.
- **(B) Private user config, multi-PC** — the user's own resources synced across their machines
  (Axis-1). → R3 (this ADR).
- **(C) cco opinionated defaults** — today baked/copied; future: extracted and shipped as an external
  package via the same publish/install path (P9). → S / R-pkg.

## Alternatives Considered

| Alternative | Pros | Cons | Verdict |
|---|---|---|---|
| **Keep internal metadata in config buckets** (today) + sidecar for "multi-PC, never-team" | No relocation work | Violates P1/P6; `<repo>/.cco` rides the repo remote → leaks machinery to teammates (P5); sidecar fails for repo-scoped data | **Rejected** |
| **All internal → STATE/CACHE/cat-4, centralized keyed-by-identity (chosen)** | P1/P6-clean; dissolves the dual-axis leak; config decentralized + internal centralized is coherent | Relocation + H6 merge-path refactor; STATE becomes heterogeneous (mitigated by D2 partitioning) | **Accepted** |
| **Merge `source` + hashes + `base/` into one per-resource "update unit"** | One functional home | They have **different** sync-profiles (provenance synced-ish; hashes/base never) — merging re-creates the grab-bag smell | **Rejected** (co-locate by sync-profile, not domain) |
| **Keep `pack-manifest` with a one-shot migrator** | Safety net for migrators | Cutover (ADR-0006) removes the residue case; dead complexity | **Rejected** (YAGNI) |

## Consequences

**Positive** — internal metadata leaves the config buckets (P1/P6 clean; truthful `git diff` on
config, G8); the dual-axis leak of `<repo>/.cco/meta` is removed; `.cco/meta` grab-bag is split by
responsibility/profile; `base/` stops being wrongly synced; STATE gains a clean never/opt-in/required
boundary protecting the future P8 sync; `pack-manifest` and its code are removed; two clean inputs
(`source`, de-tokenized registry) flow to the Cat-4 synthesis.

**Negative** — H6 merge-path refactor (STATE paths into merge functions); STATE is now heterogeneous
(mitigated by D2 partitioning); the de-tokenized registry **starts** syncing where it did not before
(token stays local — verify no security regression at implementation); the exhaustive layout + the
final cat-4 verdict for `source`/registry are deferred (to M / Cat-4) — this ADR fixes nature,
profile, and direction, not the final byte-level paths.

## Reuse / Drop / Build-new

| Element | Verdict |
|---|---|
| `pack-manifest` mechanism (`_clean_pack_manifest`, `_cco_project_pack_manifest`, `cmd-start.sh:653` read) | **Drop** |
| `.cco/base/` location coupled to `.claude/` (merge-engine path assumption) | **Refactor** (→ STATE; H6) |
| `.cco/meta` as a single grab-bag file | **Drop / split** by responsibility (D3) |
| 3-way merge engine, `source` provenance read/write, remotes url/token split | **Reuse** (relocate only; url/token already on separate lines) |
| STATE internal partitioning (`/session` vs `/update`); centralized keyed-by-identity internal layout | **Build-new** (finalized in M) |

## Open (deferred, not unresolved)

- **Cat-4 synthesis** decides: does the 4th "internal-but-synced, never-team" category exist; its
  membership (`tags.yml`, de-tokenized registry, **possibly `source`**); placement (sole member →
  co-locate in `~/.cco` vs dedicated bucket). `source` sync verdict (`required` cat-4 vs
  `never`+reinstall) is decided there.
- **M** finalizes the exhaustive `resource → (bucket, sync-profile)` layout and the STATE internal
  paths (`/session`, `/update`).
- **S** owns Class A + C: the publish/install/diff/update unification, using R3's shared-surface map;
  also the security check that splitting the registry from tokens introduces no token leak.
- **P8 (R-state-sync)** must implement the memory/transcript sync as an **allowlist** over
  `<STATE>/cco/session/` only — never the `/update` machinery.
