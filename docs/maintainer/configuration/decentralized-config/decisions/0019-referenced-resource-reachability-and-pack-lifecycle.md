# ADR 0019 — Referenced-resource reachability & pack lifecycle

**Status**: Accepted (2026-06-18)
**Deciders**: maintainer + design session (S), with adversarial review
**Context docs**: `../guiding-principles.md` (P5/P6/P12 — **P14/P15/P16 added by this cycle**),
`../S-handoff-sharing-unification.md`, `../design.md` §2/§3/§6/§7, `../decisions/0018-…`
(sharing surface — the companion ADR)
**Related ADRs**: 0002 (machine-agnostic config + index), 0008 (sync transports commits; reminder
philosophy), 0012 (manifest removed), 0013 (R3 shared-surface map: 3-way `base/` merge, `source`
provenance, `remote_cache`), 0014/0016 (referenced-resource coordinate model — **extended to packs
here**), 0017 (coordinate field semantics; warn-not-enforce integrity; unresolved-start prompt),
0018 (sharing model unification), 0020 (permissions)
**Resolves**: how a project's **referenced resources** (repos, llms, **and packs**) are carried,
resolved, and kept reachable when a project is shared with no publish boundary; and the **pack
source-of-truth lifecycle** (authoring → publish → working-copy update; internalization-as-cache).
**Hands off**: **E** (impl: schema + migration, sync-before-publish fix, resolution order, validate
contract, `cco …/internalize`).

> The companion ADR-0018 fixes the *sharing surface*; this ADR fixes what flows through it for
> *referenced resources*, closing the gap that the coordinate model (ADR-0014/0016) left for **packs**
> (never analyzed there — the authoritative table has rows for repos/llms only).

---

## Context

ADR-0014/0016 modeled **repos** and **llms** as referenced resources: a manifest carries the
coordinate (`name → url [+ ref/variant]`); content/local-path materialize per-machine (index/CACHE).
**Packs were never modeled this way.** Today `project.yml` references a pack **by name only**
(`packs: - my-pack`) and `cco start` resolves it purely locally (`~/.cco/packs/<name>`, `lib/packs.sh`).
So a teammate who clones a shared project repo gets a `packs:` reference but **not** the pack — the
shared project is broken. This is the same shape as the repo-URL problem (a shared `project.yml` must
carry a *reachable* coordinate for each referenced repo) and there is **no publish boundary** at which
to inject or validate, because projects ride the code-repo remote (P5).

A maintainer correction during S sharpened the model: **packs are intrinsically shared/DRY resources.**
A pack is authored once and reused across N projects; the maintainer's update propagates to all
consuming projects **instantly — already locally, before any team-sharing.** Therefore *copying* a
global pack into a project as its source-of-truth would sever exactly the propagation that is the
pack's reason to exist. This correction is recorded as **P15** and drives D3.

---

## Decision

### D1 — Packs are referenced resources; coordinate model extended (uniform with repos/llms)

A pack referenced by a project is a **coordinate**, exactly like a repo or an llms doc (P12):

```yaml
# project.yml / pack.yml — uniform schema (the package.json model, ADR-0016 D2)
packs:
  - name: shared-pack
    url: https://github.com/org/cco-sharing.git   # coordinate → the pack's sharing repo
    ref: v1.0                                      # OPTIONAL pin (branch/tag/commit)
    resource: packs/shared-pack                    # OPTIONAL sub-path within the sharing repo
  - name: project-local-pack                       # NO url → authored in-repo (D3 discriminator)
```

Resolution backend differs only in *where content lands* (repos → clone into the index local-path;
llms → fetch into CACHE; **packs → install into the user's `~/.cco/packs` library**). The
coordinate-field semantics of ADR-0017 D1 apply (url optional; `ref` optional; `origin`/`source`
derivation; **warn-not-enforce** on mismatch).

### D2 — Unified reachability, boundary-less (the P-URL ≡ pack-reachability unification)

repos, llms, and packs are all **referenced resources of a shared unit**; each must carry a
**reachable coordinate** for the unit to be shareable. Because a project has **no publish boundary**
(P5), enforcement is **distributed and best-effort, never a hard block** — one layered model for all
three (this is **P14**):

| Layer | Mechanism | Catches |
|---|---|---|
| **a. embed-at-add** | `cco repo/llms/project add-pack` derives & embeds the coordinate (from `origin` / the pack's `source`) | presence by default |
| **b. heal-at-resolve/start** | `cco resolve` (clone in hand) offers to backfill a missing coordinate; one-line notice | **hand-edited `project.yml`** (config is IDE-editable, P1) |
| **c. `cco config validate`** | a deliberate, exit-code-only share-readiness check (not hook-dependent) | deterministic gap detection |
| **d. opt-in pre-commit hook** | the validate contract wired into the user's git hook / CI | voluntary CI-style gating |
| **e. passive ⚠** | `cco start`/`cco list` badge unresolved/unreachable coordinates | passive awareness |

The **validity contract** (ADR-0016 D9): every referenced id has its coordinate; ids unique within
their section; config machine-agnostic (no real paths, truthful `git diff` G8). Crucially: *a resource
referenced by a **team-shared** project must have a reachable coordinate (or a bundled cache, D6)* —
`validate` flags the gap, never blocks. Layers **b/c/e do not require a configured hook**, so even a
hand-edit that bypasses the CLI is surfaced. This subsumes the earlier "repo-URL" (P-URL) question and
the "never-published pack" hole into **one** mechanism.

### D3 — A shared resource's local copy is never its source (internalize = cache only) — see P15

Because packs are intrinsically DRY (P15), the discriminator across pack locations is the **presence
of a coordinate**:

- **`<repo>/.cco/packs/X` with no coordinate** → **authored-in-repo**, project-scoped: it *is* the
  source (nothing upstream; no propagation to break). Config by P1 (authored, IDE-editable, versioned
  — the same nature as `<repo>/.cco/claude/`). Legitimate; but if the project is shared and the pack
  is not otherwise reachable, `validate` (D2) flags it.
- **`<repo>/.cco/packs/X` with a coordinate** → a **cache** of an upstream pack — **not** its source.
  Used only as the last resolution layer (D5). It **never** supersedes the live source.
- **`~/.cco/packs/X`** → the user's library copy: a **working copy** of a published pack (D4) or a
  personal authored pack.

**Internalizing a pack copy into a project must never become its source-of-truth** — that would sever
the DRY/update propagation P15 protects. Internalization is **only** a cache/last-layer fallback (D6),
with live-source-first resolution (D5). `cco pack internalize` (already in the code) is the *deliberate*
act of cutting the coordinate to make a pack self-contained — distinct from, and the opposite of, the
implicit cache.

### D4 — Source-of-truth = working-copy / git-clone model; **sync-before-publish** (see P16)

- A pack authored in `~/.cco/packs/X` is the source **until first published**. On `cco pack publish` →
  `<sharing-repo>/packs/X`, **the sharing repo becomes the source-of-truth for everyone, maintainers
  included**; the local `~/.cco/packs/X` becomes a **working copy** with a recorded `source`
  coordinate, synced via `publish` (push) / `update` (pull) — the git clone↔remote model.
- **Multi-maintainer:** install (get working copy) → edit → publish. **`cco pack publish` MUST
  sync-before-push** (pull + 3-way merge against the installed commit, abort/merge on divergence). The
  current code does a **fast-forward push** that can silently clobber a co-maintainer's changes
  (`lib/cmd-pack.sh` publish path) — a **defect to fix** (→ E). Reuses the `cco project update` 3-way
  `base/` merge (R3, ADR-0013 D7).
- `cco pack internalize` / `cco project internalize` (the latter is net-new, → E) cut the coordinate →
  the resource becomes a self-contained local source (stops receiving updates).

### D5 — Two parallel axes: resolution/mount vs update/source-of-truth (see P16)

What is **mounted** at runtime and where **updates** come from are **separate** axes (do not conflate
"what I run" with "where updates come from"):

| Axis | Governs | Order / rule |
|---|---|---|
| **Resolution / mount** (what `cco start` uses) | which copy of the pack runs | `~/.cco/packs/X` (local working copy) → fetch from `url` (sharing repo) → `<repo>/.cco/packs/X` (cache) |
| **Update / source-of-truth** (`source` provenance) | where updates come from | after publish, **the sharing repo**; `publish`/`update` sync against it |

**Local has precedence at mount** (you run what you have/edited — the git working-tree model); the
canonical remote governs updates. The cache (`<repo>/.cco/packs/X`) is genuinely last on both axes —
it never shadows a reachable source, so a maintainer's update propagates to everyone *with access*;
only an access-less consumer sees the frozen cache. **Name collision** (a pack name present both as a
global `~/.cco/packs/X` and as an authored `<repo>/.cco/packs/X`): `cco config validate` flags it; at
mount the local working copy (`~/.cco/packs/X`) wins per the order above.

### D6 — Internalize-as-cache: explicit, opt-in, last-layer (and the sole exception)

Internalization into `<repo>/.cco/packs/X` is the **last-resort fallback** for the access-asymmetry
consumer (can read the project repo but not the pack's sharing repo) or offline/no-sharing-repo use:

- **Trigger = opt-in at resolve/validate** (mirrors ADR-0017 D2 unresolved-start prompt), **never a
  silent default**: on an unresolved/unreachable pack reference, cco offers — (i) *specify a sharing-
  repo url* (recommended), (ii) *internalize-as-cache* (bundle the local pack into `<repo>/.cco/packs`),
  (iii) *proceed without* + warn.
- The cache **carries the coordinate** (so it is known to be a cache, D3) and is **refreshed by
  `cco update`** when the maintainer has access to the live source (then committed) — the cache is a
  maintainer-curated snapshot, never auto-updated for an access-less consumer (resolves the freshness
  question).
- **`cco project export --bundle-packs`** materializes the same self-containment into a **tar** (a tar
  is a snapshot by definition — the right place for a frozen copy). When a project depends on packs,
  `export` performs **dependency-closure** (bundles the referenced packs, with conscious user
  confirmation); `import` installs them.
- **Packs are the SOLE cache exception.** repos are code working-trees (not vendorable; a missing url
  for a shared project is surfaced by `validate`, never cached); llms content already lives in CACHE
  and is always re-fetchable (url mandatory, ADR-0017 D1). Only packs — small curated bundles — may be
  vendored as a last resort.
- A pragmatic alternative the user may choose (permitted, **not** recommended): point a pack `url` at
  the author's **public `~/.cco` remote** (no ad-hoc sharing repo). This is just a url under the
  coordinate model; it triggers the same public-remote warning (ADR-0017 D4 / S9) and slightly re-blurs
  the personal-store/sharing-repo split — accepted as a low-setup convenience, like the cache itself.

### D7 — Templates are scaffold-time only (out of the referenced-resource model)

A template is consumed at **scaffold time** (`cco project/pack create --template`) and has **no live
reference** afterward — it is **not** carried as a coordinate in `project.yml`/`pack.yml`, and an
already-scaffolded project does **not** receive template updates. (The framework's *opinionated*
template files update via the opinionated channel — `cco update --sync` from the official sharing repo,
F-opin / ADR-0018 D5 of the packaging work — not via a "template update".) A user-content "update from
template" is a deferred advanced feature (merge/divergence) — out of scope.

---

## Principles & method-lessons (persisted — guiding-principles P14/P15/P16)

- **P14 (unified, boundary-less reachability)** — repos/llms/packs are one category; a shared unit
  needs reachable coordinates; surfaced by layered embed/heal/validate, **never hard-block**; the
  absence of a publish boundary for projects is *by design*, replaced by distributed best-effort.
- **P15 (a shared resource's local copy is never its source)** — the maintainer's correction. Packs
  (and any DRY referenced resource) are authored once and propagate; a local materialization is a
  *reference/cache*, governed by the live source. **Bias to avoid:** treating "self-contained /
  vendored copy" as free — it silently severs propagation. The discriminator is the **coordinate's
  presence** (cache) vs absence (authored-here source).
- **P16 (source-of-truth follows publish; two parallel axes)** — after publish, the remote is the
  source-of-truth for all (working-copy model); **sync-before-publish**, never fast-forward-clobber;
  and **mount-resolution** (local-first) is a *separate* axis from **update-source** (the remote).

## Alternatives Considered

| Alternative | Pros | Cons | Verdict |
|---|---|---|---|
| **Vendor referenced packs into `<repo>/.cco/packs` as source** (lockfile model) | self-contained; offline; no extra remote | **severs DRY/update propagation (P15)** — the maintainer's correction; duplication; staleness; per-project update friction | **Rejected as source** (allowed only as explicit cache, D6) |
| **Pack reference = name only (status quo)** | simplest | breaks for every shared project (teammate can't resolve the pack) | **Rejected** (the gap D1 closes) |
| **Hard-enforce coordinate presence at a project "publish"** | strong integrity | there is no project publish boundary (P5); contradicts warn-not-enforce (ADR-0017) | **Rejected** (layered warn, D2) |
| **Coordinate model extended to packs + working-copy lifecycle + cache-as-last-layer (chosen)** | uniform with repos/llms; preserves DRY; graceful degradation; reuses R3 machinery | three resolution locations + a discriminator (mitigated: simple `url`-presence rule + `validate`) | **Accepted** |

## Consequences

**Positive** — packs join the coordinate model (uniform repos/llms/packs); shared projects become
resolvable; DRY/update propagation is preserved (P15); the working-copy lifecycle gives a single
source-of-truth (P16) and exposes a real publish defect (fast-forward clobber) to fix; internalize-as-
cache enables low-setup/offline sharing without muddying the source; templates are cleanly out of
scope. **Negative** — `project.yml`/`pack.yml` gain an embedded pack coordinate (schema change +
migration, → E); resolution has three layers + a discriminator (kept simple by the `url`-presence rule
and `validate`); `cco pack publish` needs the sync-before-publish fix; `cco project internalize` is
net-new.

## Reuse / Drop / Build-new

| Element | Verdict |
|---|---|
| `cco pack install/update` + `.cco/source` provenance + `remote_cache` (R3) | **Reuse** (pack coordinate resolution rides this) |
| `cco pack internalize` (cut the coordinate → self-contained) | **Reuse** (the deliberate opposite of the implicit cache, D3/D4) |
| `lib/packs.sh` local-by-name resolution (`~/.cco/packs` only) | **Refactor** — three-layer order (D5): `~/.cco/packs` → url-fetch → `<repo>/.cco/packs` cache |
| `cco pack publish` fast-forward push | **Fix** — sync-before-publish 3-way merge (D4; defect) |
| `cco project update` 3-way `base/` merge | **Reuse** (pack publish/update merge) |
| pack coordinate schema + migration; `cco project add-pack` embed; `cco config validate` contract; internalize-as-cache prompt; `export --bundle-packs` dependency-closure; `cco project internalize` | **Build-new** (→ E) |

## Open (deferred, not unresolved)

- **E** — `packs:` coordinate schema + migration (name-only → `{name,url?,ref?,resource?}`; legacy
  central `~/.cco/llms/<name>/source` already covered by ADR-0016); the three-layer resolution order;
  the `cco config validate` reachability contract + layered embed/heal/warn; the **sync-before-publish**
  fix (defect); internalize-as-cache prompt + `cco update` cache refresh; `export --bundle-packs`
  dependency-closure; `cco project internalize`.
- **Companion ADRs** — sharing surface (0018); permissions (0020).
