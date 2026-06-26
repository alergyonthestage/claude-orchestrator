# ADR 0021 — Resource Lifecycle: Entry Verbs, Deregistration & Cleanup Integrity

**Status**: Accepted (2026-06-18)
**Deciders**: maintainer + impl-readiness review (V), Cluster 1
**Context docs**: `../requirements.md` (AD12, FR-M1/M2), `../design.md` §7-§9, `../reviews/18-06-2026-impl-readiness-review.md` (F1/F9/F10/F11/F12/F42/F43/F44 + F59)
**Related ADRs**: 0006 (breaking cutover / migration), 0008 (config versioning + reminders), 0009 (memory as STATE), 0010 (profiles→tags), 0015/0016 (4-bucket taxonomy, id-keyed internal state), 0017 (CLI lifecycle), 0018 (sharing 2×2, project asymmetry), 0019 (reachability / warn-never-hide)

---

## Context

The impl-readiness review (V, Cluster 1) validated the migration/lifecycle design and surfaced
two gaps that the prior ADRs did not cover coherently:

1. **Entry-verb naming.** The design (ADR-0006, design §7) introduced a top-level `cco migrate`
   for the legacy→new bring-over, alongside `cco init` (clean) and `cco join` (member). `cco migrate`
   collides semantically with `cco update`, which already runs the framework's **schema migrations**
   (`migrations/{scope}/`, `cmd-update.sh`). For a user the two "migrations" are different axes
   (one-time legacy bring-over vs ongoing schema patching) but the shared verb is confusing.

2. **Cleanup / referential integrity (F59).** The new model keys internal state by identity `<id>`
   across **DATA** (`tags.yml`, per-id `source` provenance, de-tokenized remotes registry), **STATE**
   (the local-path `index`, per-project `memory/`/session, sync-meta, remotes token), and **CACHE**
   (`coords-lookup`, `remote_cache`, llms content). The design specified how this state is **created**
   (init/join/migrate, resolve, install) but **not** how it is **cleaned** on removal. Concretely:
   `tags.yml` is cleaned by **no** command today (grep is empty); the new design has **no project
   removal verb at all** (`cco project create/delete` are removed, design §9); and a **manual**
   deletion (user `rm`s a repo's `.cco/` or a `~/.cco` resource) orphans all id-keyed internal state.

The review also resolved three premises that simplify the design (recorded in the review report):
- secrets/local-paths of **all** profiles are physically on disk in the vault's `profile-state/<branch>/`
  stash shadows (`cmd-vault.sh:1291`), so a raw archive captures them (refines ADR-0006 backup — F1/F9);
- profile→tag conversion is **lazy + optional** for projects (ADR-0010 §5) and **atomic** for shared
  resources (packs/templates), per the resource's storage nature (F10);
- cross-resource **name uniqueness is already enforced** at create time (`cmd-project-create.sh:70`,
  `cmd-pack.sh:62`), so a same-name-different-content collision cannot occur via the tool (F12 dismissed).

## Decision

### 1. Entry verbs — fold the legacy bring-over into `cco init`

The three mutually-exclusive entry points for a repo become:

| Verb | Meaning |
|------|---------|
| `cco init` | scaffold a clean `<repo>/.cco/` |
| `cco init --migrate <old> [--sync]` | hydrate `<repo>/.cco/` from the **legacy vault backup**'s project config (lazy, per-project). `--sync` propagates the migrated `.cco/` to **all** member repos of the legacy project; without it only the current repo is initialized — **symmetric with `cco join [--sync]`** |
| `cco join [--sync]` | become a **member** of a project defined in another repo |

The top-level `cco migrate` verb is **dropped** (folded into `cco init --migrate`). This removes the
`migrate`↔`update` confusion at zero cost to the rest of the design — it is a pure UX rename of an
entry mode (refines ADR-0006 Dec-3). Fresh installs (no legacy vault) never see `--migrate`; the
legacy-vault backup is triggered by the **J0 first-run detector** (ADR-0017 D3), conditional on a
legacy-vault signal (a git `~/.cco`/`user-config` with profile branches / `.vault-profile`), and is
**separate** from `cco update`'s schema migrations. A brand-new user runs **zero** migration.

### 2. Deregister verb — `cco forget <project>`

`cco forget <project>` removes cco's internal, id-keyed bookkeeping for that project — the STATE
`index` entry, STATE `memory/`/session, DATA `source`, the `tags.yml` entry, and CACHE entries — and
**does NOT touch** the user's repo or its committed `<repo>/.cco/`. It is the explicit inverse of the
entry trio: "stop tracking this project on this machine." (Naming: `cco forget` is preferred over
`cco project remove`/`delete` to avoid implying the repo or its config is deleted — projects are
decentralized config in the user's own repo, removed only by the user's own git.)

### 3. Source of truth + self-healing (the two drift states are both accepted)

`<repo>/.cco/project.yml` is the **source of truth** for "what a project is"; the internal buckets are
**derived bookkeeping**. Discovery is **cwd-first** and the index is **rebuildable** (`cco resolve
--scan`). Therefore the two ways internal state and repo state can drift are **not symmetric in harm**
and are both accepted:

- **`forget` but the repo's `.cco/` is kept** → not "dirty": the index re-registers automatically from
  the still-valid `project.yml` on the next `cco start` from that repo (or `cco resolve --scan`). Only
  user-authored **tags** do not auto-return (they are not derivable) — acceptable, since `forget` is an
  explicit "done" action; re-tag if the project is resumed.
- **the repo's `.cco/` is removed but no `forget` was run** → harmless orphans: dead `index`/`tags`/
  `source` entries; `cco start <name>` fails gracefully ("no `.cco/` at `<path>`"). Cleaned by the
  explicit sanitization pass (Decision 5).

### 4. Delete cascade (the resources that *do* have a removal verb)

`cco pack remove`, `cco template remove`, `cco llms remove`, and `cco remote remove` must clean **all**
the id-keyed internal state they created, not just the CONFIG copy:
- pack/template/llms: the `tags.yml` entry + DATA `source` (+ CACHE entries) for that id;
- **`cco remote remove`** must clean **both** the DATA url registry **and** the STATE token. (Today url
  and token share one file and `cmd-remote.sh:168` already removes both; after the **M3 split**
  url→DATA / token→STATE the command needs **two** writes — this is a forward-looking requirement, not
  a current bug. Intersects F6.) No token may leak to logs (S8).

### 5. Orphan sanitization — explicit, preview-first, never automatic

`cco config validate [--dry-run]` **detects and reports** orphaned internal entries (tags/source/index/
cache/token with no resolvable resource), **warn-never-hide** (ADR-0019); `cco config validate --fix`
(or `cco resolve --scan --prune`) prunes them, **preview-first, with confirmation**. Cleanup
aggressiveness follows the bucket's **sync-class + regenerability** (ADR-0016):
- **STATE/CACHE** (machine-local, regenerable) → freely rebuilt/pruned via `cco resolve --scan`;
- **DATA** (`tags`/`source`, Axis-1-synced) → pruned **only explicitly + confirmed**, because a wrong
  prune **propagates** across the user's machines.

**Automatic / periodic background sanitization is rejected.** A non-resolving path on this machine does
**not** mean "deleted" — the repo may be on another machine, an unmounted drive, or simply not cloned
here (the index is machine-local). Orphans are surfaced via the existing **reminder** mechanism
(ADR-0008: nudge, never auto-act).

> **Namespace REFINED by ADR-0023 D1 (2026-06-19; the contract above is kept as written):** this
> orphan-sanitization job keeps the verb **`cco config validate [--dry-run|--fix]`** (global, id-keyed
> internal state). The *share-readiness* validate (every referenced coordinate reachable + machine-
> agnostic; ADR-0016 D9 / ADR-0019 D2 / ADR-0022 D4 pack-ERROR) is a **separate job on a separate scope**
> and moves to **`cco project validate`** (ADR-0023 D2). The two `validate` verbs are intentional —
> different scope, different question ("is my internal state clean?" vs "is this project share-ready?").

### 6. Defensive uniqueness (F12 dismissed)

The legacy vault already enforces cross-resource name uniqueness at create
(`cmd-project-create.sh:70`, `cmd-pack.sh:62` — `die "… must be unique across all profiles"`), so the
same name cannot carry divergent content on two profiles via the tool. `cco init --migrate` therefore
needs only a **defensive assertion** of that invariant (guarding against a hand-edited vault) — **no**
suffix/merge/prompt machinery.

## Alternatives Considered

| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| Keep top-level `cco migrate` | matches the init/join/migrate trio; no rename | `migrate`↔`update` UX confusion (the review's finding) | Rejected |
| No deregister verb — sanitization only | smallest surface; "projects live in the repo, remove via git" | internal state accumulates silently until the user runs `validate`; no intentional "I'm done" action | Rejected |
| Automatic periodic sanitization | hands-off cleanliness | false positives (non-resolving ≠ deleted); a wrong DATA prune propagates across machines; violates ADR-0008 explicit-over-automatic | Rejected |
| `cco init --migrate` + `cco forget` + explicit `validate` sanitization (chosen) | resolves the verb clash; complete id-keyed cleanup; self-healing index; no silent loss; honors bucket sync-class + warn-never-hide | new code (`forget`, delete-cascade, validate-orphan pass); M3 split adds a second cleanup write | **Accepted** |

## Consequences

**Positive** — a coherent entry/exit verb surface (`init`/`init --migrate`/`join` ↔ `forget`);
referential integrity for id-keyed internal state; a self-healing, rebuildable index; no silent data
loss; cleanup policy derived from the bucket taxonomy rather than ad-hoc.

**Negative** — `cco forget`, the per-resource delete-cascade, and the `cco config validate` orphan pass
are **new code** (E); the M3 remote split adds a second cleanup write to `cco remote remove`; a user who
neither `forget`s nor removes leaves harmless orphans until they run `validate` (acceptable, surfaced by
a reminder). `cco init` now carries a `--migrate` mode while `cco join` stays a separate verb (a minor,
deliberate asymmetry — both are first-step entry points but `--migrate` is a *source* of `init`).

## Reuse / Drop / Build-new

| Element | Verdict |
|---------|---------|
| cwd-first discovery; `cco resolve --scan` index rebuild; ADR-0008 reminder mechanism; legacy create-time uniqueness guard pattern | **Reuse** |
| top-level `cco migrate` verb | **Drop** (folded into `cco init --migrate`) |
| `cco init --migrate [--sync]`; `cco forget <project>`; delete-cascade in `pack/template/llms/remote remove`; `cco config validate [--fix]` orphan detect/prune; defensive uniqueness assert in migrate | **Build-new** |

## Open

- Exact `cco config validate` predicate set + output format, and the `--fix` vs `cco resolve --scan
  --prune` surface naming → **Cluster 5** (command/UX; F26). Not blocking.
  > **RESOLVED in P5-2c implementation (2026-06-25, maintainer-confirmed).** Predicate set =
  > the full bucket sweep: STATE index path entries (missing target dir) + project memberships
  > (no resolvable member); STATE/CACHE per-id dirs (projects/packs/templates) for a gone
  > resource; STATE remote token with no DATA registry entry; DATA `tags.yml` + install-provenance
  > dirs for a gone resource. Surface = **`cco config validate [--dry-run | --fix [-y]]`** (the
  > read-only report exits 0, reminder-style; `--fix` prunes STATE/CACHE under the main confirm and
  > synced DATA under a second confirm; `-y` confirms non-interactively). `cco resolve --scan` has
  > **no** `--prune` (Decision-5's prune lives solely in `cco config validate --fix`; consistent
  > with ADR-0022 D3 / F38 scan = upsert-only).
- llms internal bucket placement (CONFIG vs CACHE) for cleanup is to be confirmed against ADR-0016 D7
  during E (the review flagged uncertainty in `cmd-llms.sh`). Not blocking.
  > **NOTE (P5-2a, 2026-06-25):** `cco llms remove` needs no delete-cascade — llms entries live
  > wholly in CONFIG (`~/.cco/llms/<name>`, with `source` in-dir) and are not a tag kind, so the
  > existing `rm -rf "$llms_dir"` already removes all of llms's id-keyed state. A future llms→CACHE
  > relocation (ADR-0016 D2/D7) would revisit this; it is out of P5-2 scope.
