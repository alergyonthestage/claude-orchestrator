# ADR 0010 — Resource Authoring & Per-User Tag Organization

**Status**: Accepted (2026-06-16)
**Deciders**: maintainer + design session
**Context docs**: `../requirements.md` (AD2, FR-C1/C4, §8), `../design.md` §2.3, §2.4, §3, §7
**Related ADRs**: 0008 (`~/.cco` versioning — hand-authored, cco only scaffolds), 0007
(`~/.cco` dotdir-as-git-repo), 0006 (breaking cutover — vault & profile branches removed),
0002 (machine-local index — paths only)
**Resolves**: RD-authoring (the last config RD)

---

## Context

Global resources — knowledge **packs** and project **templates** — live in `~/.cco`
(`packs/`, `templates/`), a personal git store. RD-authoring must settle two things the
design left open: **how** users author these resources, and **how** they organize them now
that vault profiles are gone.

Code-grounded facts (today's `user-config/` store):

- **cco only scaffolds, never writes content.** `cco pack create` (`cmd-pack.sh:13-91`)
  copies a skeleton (`pack.yml` placeholder + empty `knowledge/ skills/ agents/ rules/`) to
  `packs/<name>/`; `cco template create` (`cmd-template.sh:211-297`) scaffolds
  `templates/<kind>/<name>/`. Content is **hand-authored** in an editor — ADR-0008 already
  fixed this ("cco offers no command that edits pack/template content").
- **The `config-editor` project template already implements direct-store editing.** It mounts
  `{{CCO_USER_CONFIG_DIR}}` read-write and ships `setup-pack`/`setup-project` skills + a
  `config-safety` rule (`templates/project/config-editor/`). It is the "config-editor agent"
  ADR-0008 references; it writes resource files directly into the global store.
- **No author-in-project-then-promote flow exists for packs.** Resource movement is
  project↔global↔remote via Config Repos (`pack/project publish|install|update|export`,
  `internalize`). The only local promotion is `template create --from <project|pack>`
  (resource→template).
- **The store is flat-by-name.** `packs/<name>/` everywhere; listing/manifest/validate/install
  all assume `$PACKS_DIR/$name` + a single-level `*/` glob keyed by basename
  (`cmd-pack.sh:107`, `manifest.sh:62,88,185`, `_install_pack_from_dir:643`).
- **No tags on resources today**, except round-tripped sharing metadata in the manifest
  (`manifest.sh:77-79`, explicitly *not* from `pack.yml`). `cco list --tag` does not exist.
- **Profiles are git branches** of the vault (`cmd-vault.sh` profile ops); a resource is
  "in" a profile by living on that branch (shared on `main`, exclusive via `.vault-profile`).
  Profile branches are dropped by the decentralization (ADR-0006/0008).

A hard requirement shaped the tag decision: **tags are per-user, must NOT reach third
parties.** They may sync across the *user's own* machines (Domain A) but must never travel to
a team via publish/install (Domain B).

## Decision

### 1. Authoring = direct `~/.cco` edit (canonical)
Users author global resources by **opening `~/.cco` directly** (in an IDE, or via the
`config-editor` agent). cco only **scaffolds** (`cco pack create`, `cco template create`); it
never edits content (ADR-0008). The `config-editor` template is **rehomed** to mount `~/.cco`
(was `user-config/`). **No author-in-repo + promote** flow in v1 — it would add a second
authoring model in tension with the lean direction, and the need is already covered by direct
edit (and the existing `template create --from`). Recorded as a possible future evolution only
if a concrete need emerges.

### 2. Organization = tags, not profiles (clean replacement, no overlap)
The legacy **profile** system (git branches) is **removed entirely**; a **net-new, independent
`tags`** system is added. Tags are **multi-valued per resource** and **transversal** — the
correct semantics, vs a profile's "resource belongs to exactly one profile". The user applies
tags freely (to distinguish resources, or to emulate profiles). The store stays **flat**
(no per-profile subdirs): subdirs would break the repo-wide flat-by-name assumptions and the
manifest scan, force single-membership, don't even solve filename collisions (resource files
mount flat into the container, `packs.sh:108`), and add migration cost. **No overlap** between
the two systems — profiles are deleted, tags are introduced fresh, so there is no dual-axis
machinery to maintain.

### 3. Tags live in a per-user registry in `~/.cco` (never in shared definition files)
A single per-user **tag registry** `~/.cco/tags.yml` maps `resource → [tags]` for **both packs
and projects**. It is:
- **per-user** (the user defines it);
- **synced across the user's machines** via the personal store (`cco config push/pull`,
  Domain A) — added to the ADR-0008 allowlist (`!tags.yml`);
- **never shared with third parties** (Domain B): it is **not** in `pack.yml`/`project.yml`
  (which travel on publish/clone), **not** in the manifest, **not** in the index.

`cco list [--tag <t>]` reads the registry. Rationale: putting tags inside `pack.yml`/
`project.yml` ("first-class field") would leak them to every consumer on `cco pack publish` /
template clone — violating the per-user requirement. A per-user registry in the personal store
is the only home that is simultaneously per-user, cross-PC-synced, and team-private.

### 4. Project tags move out of `project.yml` and the index
The design previously showed project `tags:` inside `project.yml` (§2.4) and the machine-local
index (§3). Both are **removed**: project tags live in the `~/.cco` registry like pack tags.
`project.yml` stays purely shared machine-agnostic config (no personal organization leaks via a
published template); the index stays **paths/repos only** (machine-local, ADR-0002/0007 — no
tags). Clean split: a project's *config* is shared; the user's *tagging* of it is personal.

### 5. Migration is user-chosen (profiles → tags or not)
Profile→tag conversion is **opt-in and granular**, matching the lazy per-project migration
(ADR-0006/0021): for **projects**, `cco init --migrate <project>` **prompts the user (CLI)** whether
to **convert that project's origin profile into a tag** — seeding it in `<data>/cco/tags.yml` (DATA
bucket — ADR-0015/0016, not `~/.cco`) — or to **start untagged**. For **shared resources** (packs and
templates, which do not migrate per-project), conversion is **atomic**: when `~/.cco` is populated from
the backup, the profile-exclusive packs' origin tags are seeded as a set (templates are always-shared
→ no origin tag). Because tags are an independent new system, this is a one-shot data seed, not a
structural coupling.

> **What is preserved vs. what is an accepted regression (F42).** Legacy profiles did **two** jobs:
> (a) *organization* (which resources belong together) and (b) *workspace selection/visibility* (which
> projects appear when a profile is active). Conversion preserves **(a) as tags**; **(b) has no v1
> equivalent** and is an **accepted regression** (same precedent as ADR-0009's dropped cross-PC memory
> sync) — there is no "switch to profile X → these projects appear". `cco list --tag` joins `tags.yml`
> against the STATE index at read time; under the lazy model a tag is seeded only when its project is
> migrated (hence resolvable), so "tagged-but-unresolved" is rare — and where it occurs (e.g. a later
> `cco forget`/manual removal) it is **shown with an `(unresolved)` marker, never hidden** (warn-never-
> hide, ADR-0019). The migration docs must drop the blanket "lossless" wording for selection.

## Alternatives Considered

| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Author-in-repo + promote** (author a pack inside a project, then promote to `~/.cco`) | Author with project context; reuses `template create --from`/`_install_pack_from_dir` | Second authoring model vs the lean direct-edit; needs a new "resource inside a repo" scope concept; redundant with direct edit | Rejected (v1) |
| **Subdirs per profile** (`packs/<profile>/<name>/`) | Mirrors old profile grouping; permits same-name packs across groups | Breaks flat-by-name repo-wide + manifest scan; single-membership (a pack can be in one subdir but many tags); no real collision benefit (files mount flat); extra migration work | Rejected |
| **Tags first-class in `pack.yml`/`project.yml`** | Tag travels with the resource; no separate file | **Leaks to third parties** on publish/clone — violates the per-user requirement; couples personal org into shared config | Rejected |
| **Tags manifest-only** (today's behavior) | No new file | Manifest is the *sharing* layer (Domain B); doesn't model per-user cross-PC org; wrong domain | Rejected |
| **Direct edit + per-user `~/.cco/tags.yml` registry, flat store (chosen)** | Per-user, cross-PC-synced (Domain A), team-private; flat store untouched; multi-tag semantics; clean profile removal, no overlap; zero migration coupling | A registry + `cco list --tag` are new code; project tags need `~/.cco` synced to appear on another of the user's PCs; config-editor/skills/rules must be rehomed | **Accepted** |

## Consequences

**Positive** — one canonical, lean authoring model (open `~/.cco`); cco's scaffold-only role is
preserved (ADR-0008); tags are semantically correct (multi-valued, transversal) and live where
personal data belongs — synced with the *user* (Domain A), never leaked to the *team* (Domain
B); the flat store and manifest scan are untouched; profile removal is clean with no dual-axis
machinery; migration conversion is a user choice, not a forced coupling.

**Negative** — a per-user tag registry (`~/.cco/tags.yml`) + `cco list --tag` are new code; a
project's tags are no longer in the portable `project.yml`, so on another of the user's machines
they appear only once `~/.cco` is synced (acceptable — tags are personal); the `config-editor`
template, its `setup-pack`/`setup-project` skills, and the `config-safety` rule must be rehomed
to `~/.cco` and de-vaulted (`cco vault save` → `cco config save`). **This feeds a dedicated
global resource-coherence inventory** (next analysis) covering every resource that references
the old model.

## Reuse / Drop / Build-new

| Element | Verdict |
|---------|---------|
| `cco pack create` / `cco template create` scaffolding; `template create --from` | **Reuse** (retarget to `~/.cco`) |
| `config-editor` template + `setup-pack`/`setup-project` skills + `config-safety` rule | **Reuse, rehomed** (`user-config/` → `~/.cco`; `cco vault save` → `cco config save`) |
| Vault **profile branches** + `.vault-profile` + `vault profile/move` cross-branch ops | **Drop** (ADR-0006/0008) |
| `~/.cco/tags.yml` per-user registry; `cco list --tag` filter; allowlist `!tags.yml`; `manifest_refresh` tag handling stays manifest-local (not from `pack.yml`); migrate profile→tag prompt | **Build-new** |

## Open
None for v1. Author-in-repo + promote deferred (future, only on real need). Next analysis: a
**global resource-coherence inventory** — every skill/agent/rule/template/doc/managed file that
references the old model (`user-config/`, `cco vault *`, profiles, vault-synced memory) and must
be realigned to the decentralized system.
