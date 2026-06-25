# ADR 0016 — Consolidated resource taxonomy: the authoritative `resource → (bucket, sync-profile)` map

**Status**: Accepted (2026-06-17)
**Deciders**: maintainer + design session
**Context docs**: `../guiding-principles.md` (P1–P12 — **P12 refined by this session**),
`../M-handoff-consolidated-design.md` (M's working scaffold, maintainer-validated), `../design.md` §2/§3/§9,
`../resource-coherence-inventory.md`, `../analysis-roadmap.md` (M), `../reviews/16-06-2026-design-coherence-review.md`
(H5/H6/M3)
**Related ADRs**: 0002 (machine-agnostic config + index), 0004 (config/STATE/CACHE separation), 0006 (breaking
cutover, lazy migration), 0007 (system-dir locations / XDG — **completed** here: the 4-bucket map is made
authoritative), 0008 (sync transports commits; allowlist; pre-commit scan), 0009 (memory as STATE), 0010/0011
(tags), 0012 (manifest removed), 0013 (internal-metadata split), 0014 (referenced-resource coordinate model —
**refined** here: placement/scope finalized; the "central registry + resolve-at-publish" hint is corrected for
the by-construction-shared repo), 0015 (Cat-4 = XDG DATA)
**Resolves**: **M** — the consolidated taxonomy. Produces THE authoritative `resource → (destination,
sync-profile)` table, the 4-bucket `design.md §2` rewrite, the DATA byte-level layout, the STATE index that
subsumes `@local`/`local-paths.yml`, the coordinate-placement open decisions of ADR-0014/0015, and fixes
conflicts C1–C4. **Absorbs** review follow-ups **H5/H6/M3**. **Hands off**: **S** (sharing/resolve mechanism,
coordinate CLI + validation hook), **T** (transport/state-sync), **E** (impl follow-ups).

> Nothing here overrides a prior ADR's *nature/profile* verdicts; M consumes them and fixes the final
> byte-level placement. Where M and a prior ADR's *placement hint* disagree (ADR-0014's central-registry hint),
> M's resolution wins and the ADR is annotated as refined.

---

## Context

R1–R4 + the Cat-4 synthesis (ADR-0011/0012/0013/0014/0015) fixed every resource's *nature* (config vs internal)
and *sync-profile* (`none`/`opt-in`/`required`/team), and established the 4th bucket (XDG **DATA**). What
remained un-consolidated was a **single authoritative table** mapping every cco-managed resource to its
`(bucket, mutator, sync)`, an **exhaustive 4-bucket directory layout** (the current `design.md §2` is still a
3-bucket draft with stale entries), and two deferred placements: the **coordinate registry scope/namespacing**
(ADR-0014/0015 → M) and the **DATA byte-level layout** (ADR-0015 D5 → M).

During M the maintainer surfaced a genuine gap in ADR-0014's reasoning (recorded as **D2** below) that forced a
refinement, not a mechanical consolidation: ADR-0014's "coordinate is config, synced cross-PC **and
resolved-at-publish for the team**" implicitly assumed all team-sharing flows through a discrete **Config-Repo
publish** event. But by **P5**, `<repo>/.cco/` is **team-shared by construction** when the code repo has a
shared remote — there is **no publish boundary** at which to inject/resolve. A central per-user coordinate
registry (`~/.cco`) therefore **cannot** reach a teammate who clones the shared repo directly. This makes the
coordinate's home a *decided* matter for M, not a free choice.

---

## Decision

### D1 — The 4-bucket taxonomy is authoritative (completes ADR-0007)

cco-managed resources live in exactly four destination classes; the two CONFIG buckets hold **only** P1-config,
the three internal buckets are **hidden** (P6) and never in a config repo:

| Bucket | Path (default) | Override | Nature | Sync profile |
|---|---|---|---|---|
| CONFIG / repo | `<repo>/.cco/` | — | config | Axis-1 (repo remote) **+ Axis-2 by construction** (P5) |
| CONFIG / personal | `~/.cco/` | — | config | Axis-1 **private only** (`cco config push/pull`) — never team |
| **DATA** | `$XDG_DATA_HOME/cco` → `~/.local/share/cco` | `$CCO_DATA_HOME` | internal | **Axis-1 `required`, never team** |
| STATE | `$XDG_STATE_HOME/cco` → `~/.local/state/cco` | `$CCO_STATE_HOME` | internal | **`never`** (machine-local, non-portable) |
| CACHE | `$XDG_CACHE_HOME/cco` → `~/.cache/cco` | `$CCO_CACHE_HOME` | internal | **`never`** (regenerable) |

Resolver rules (ADR-0007/0015) apply uniformly to all XDG bases including DATA: **host-side only**, explicit
anti-in-container guard (`$HOME=/home/claude` / `/.dockerenv`), treat unset/empty/non-absolute XDG var as
absent, `mkdir -p` mode `0700`, route through `expand_path()`. UX split (ADR-0015): **`~/.cco` = what you edit
& version · `~/.local/share/cco` = internal but portable/synced · `state/`+`cache/` = plumbing you never sync.**

### D2 — Referenced-resource coordinate: **per-unit, embedded in the versioned manifest** (refines ADR-0014)

A coordinate (`name → url` + `ref` for repos / `variant` for llms) is **config** (P6/P12: team-shared ⇒ not
internal). ADR-0014 left its *scope* to M. M resolves it as **decentralized per-unit, embedded in the
referencing manifest**, for a decisive reason:

> **The by-construction-shared repo (P5) has no publish boundary.** Project config is team-shared the moment the
> code repo's remote is shared — continuously versioned, no discrete publish event at which to inject or
> resolve. A central `~/.cco` registry reaches the user's own 2nd PC (Axis-1 sync) and the Config-Repo path
> (resolve-at-publish), but **never** the teammate who clones the shared repo. Therefore the coordinate **must**
> live in the versioned config that travels with the manifest.

This **completes** ADR-0014's model C rather than contradicting it: the *category* (referenced-resource
coordinate, decomposed by sync-profile) and the *DRY-by-name* intent stand; only the storage is finalized as
**decentralized**, which is also what the cardinal move **"config decentralizes"** (ADR-0013 D1) demands of any
config datum.

**Uniform schema (maintainer-confirmed).** `project.yml` and `pack.yml` share **one** format: the `url`
(+`ref`/`variant`) is a field on each `repos:`/`llms:` reference entry. No separate registry file; no per-type
mechanism. Project coordinates ride the repo remote (Axis-1 + Axis-2 by construction); pack coordinates ride
`cco config push/pull` (Axis-1) and are carried to the team by **resolve-at-publish** (packs *do* have a
discrete `cco pack publish` event). Templates are scaffolds containing manifests → same schema by inclusion.

**Source of truth (answers M's open "what is authoritative"):**
- **repo `url`** → the **clone's own git remote** is authoritative (`git -C <path> remote get-url origin`, what
  `_sanitize_project_paths` already reads). The manifest `url:` is a **persisted bootstrap pointer** used to
  clone when the repo is not yet on this machine; once resolved it is **re-derivable → self-healing**. A stale
  repo `url:` is low-stakes.
- **llms `url`** → the **manifest entry that declares it** (llms has no intrinsic self). Stored once **per
  unit**.
- **Cross-unit "same upstream" is intentional independence, not an anomaly** — the **`package.json` model**:
  each unit pins its coordinate independently; two units referencing the same llms is exactly two `package.json`
  files each depending on `react`. There is **no global source of truth** because none is needed. DRY holds
  **within the unit** (the publishable/shareable unit); cross-unit replication mirrors the deliberate
  `project.yml` symmetry across a project's repos (ADR-0002) and is the accepted cost of decentralization.

**Decomposition (P12), final placement:**

| Datum | Nature | Bucket | Sync |
|---|---|---|---|
| reference **name (id)** | config | the manifest (`project.yml`/`pack.yml`) | with the manifest (both axes) |
| **coordinate** `url`(+`ref`/`variant`) | config | **the manifest entry**, per-unit | with the manifest (project: both axes; pack: Axis-1 + resolve-at-publish) |
| repo **local-path** | internal | **STATE index** (not a per-repo file) — see D4 | `never` |
| llms **content** + cache-state (`etag`/`resolved_url`/`downloaded`) | internal | **CACHE** `<cache>/cco/llms/<name>/` | `never` (re-fetch); name-keyed, deduped per-machine |

The expensive datum (downloaded content) stays **globally deduplicated per machine** in CACHE; the cheap datum
(a URL string) decentralizes with the config. (A `name→different-url` clash across units in the name-keyed CACHE
is a user-level naming choice and low-stakes since content is re-fetchable; cache-state records `resolved_url`
to disambiguate — byte-level note, not a blocker.)

> **Deferred note RESOLVED by ADR-0022 (F56, 2026-06-19; the row/note above is kept as written):** on every
> llms resolve, if the cached `resolved_url` ≠ the requesting unit's url → **re-fetch and overwrite**
> (last-writer per machine, one-line notice); if equal → reuse with no network. Layout stays name-keyed; a
> unit never silently runs with a foreign url's content. Cross-unit divergence is surfaced by
> `cco config coords --diff`/`cco config validate`, not encoded into storage.

### D3 — Consistency is enforced by tooling, not by storage (maintainer consideration 2)

Because storage is decentralized, cross-unit coordinate consistency is a **CLI** concern, **not** a storage
invariant — and crucially this introduces **no** global source of truth:

- A **derived `name→url` lookup**, regenerable by scanning the known manifests, powers auto-fill and divergence
  detection. It is internal, machine-local, **regenerable → CACHE** (`<cache>/cco/coords-lookup`), purely
  advisory; it may also be computed on demand without persisting. It is **not** config and **not** authoritative.
- Command surface (mechanism owned by **S/E**): `cco repo add <name>` / `cco llms add <name>` auto-resolves the
  `url` from a known id; `cco config coords --diff` lists units that disagree on the same id; `--sync`/
  `--sanitize` apply a coordinate globally across units. "Coherence by tooling, not by storage."

> **Deferred items RESOLVED by ADR-0022 (2026-06-19; the bullets above are kept as written):**
> - **F45 — coords-lookup is on-demand only for v1.** It is computed by a deterministic scan of the known
>   manifests every time, with **no persisted artifact** (the `<cache>/cco/coords-lookup` file is dropped — see
>   D7 annotation). Persisted caching is recorded as a future optimization. (Removes all invalidation/staleness
>   logic; a never-persisted value cannot drift.)
> - **F48 — `cco config coords --sync`/`--sanitize` never auto-elect a winner.** When units disagree the user
>   names the authoritative coordinate via `--from <unit>` (or an interactive pick), mirroring `cco sync --from`
>   (ADR-0017 D2); `--diff` stays read-only. This is a one-shot user-directed bulk edit — no persisted authority,
>   so P12's "no global source of truth" holds. (The command's full UX surface is **Cluster 5**.)

> **Command surface RESOLVED by ADR-0023 D1/D3 (2026-06-19; the bullets above are kept as written):** the
> coordinate-add verbs are **`cco project add repo/llms`** (embed-at-add under one `cco project` home,
> with a one-shot `--path` — ADR-0023 D3), not a separate `cco repo`/`cco llms add` namespace; and the
> consistency tooling `cco config coords --diff/--sync` is relocated to **`cco project coords`**
> (project-scoped, ADR-0023 D1). The illustrative naming above was deferred to S/E and is refined, not reversed.

> **Shipped P5-4b (2026-06-25; decision unchanged).** `cco project coords` in `lib/cmd-project-coords.sh`
> derives the name→url lookup on demand by scanning the indexed projects' `project.yml` (repos/mounts/
> llms/packs) with **no persisted artifact** (F45). `--diff` is read-only; `--sync --from <unit>` adopts
> the named unit's url across the divergent ids and **never auto-elects** (F48). Two impl notes:
> bare `cco project coords` (no flag) prints the full lookup (a convenience on top of the pinned
> `--diff`/`--sync` surface); a **url-less entry carries no coordinate and is excluded from divergence**
> (a missing coordinate is `cco project validate`'s concern, ADR-0023 D2 — not coords').

### D4 — STATE **index** subsumes `@local` + per-repo `local-paths.yml` (byte-level; resolves the flagged ambiguity)

There is **one** unified, machine-local **STATE index** `<state>/cco/index` — **not** a per-project file. It is
the **local-path materialization** of the repo coordinate (D2): ADR-0014's `local-path` datum, today realized as
`<repo>/.cco/local-paths.yml`, **becomes an `index` entry**. The per-repo `local-paths.yml` is **removed**: it
is internal data inside a config bucket (P6 violation, same class as C4), and `@local` markers disappear
(`project.yml` carries logical names only → nothing to sanitize, truthful `git diff`, G8 — design §3).

```yaml
# <state>/cco/index   (machine-local STATE; never committed, never synced; 0700; atomic write — H7→E)
version: 1
paths:                       # logical name → host-absolute path (repos AND extra mounts) — machine-global
  repo1:         /Users/me/dev/repo1
  shared-assets: /Users/me/assets
projects:                    # subsumes the old registry — membership only, NO tags, NO urls
  projectA: { repos: [repo1, repo2, repo3] }
```

Uniqueness invariant (AD5): one logical name → one absolute path per machine; this also serves the shared-repo
case (a repo used by two projects = one `paths:` entry). Concurrency/atomicity and the global-vs-namespaced
name question (H7) are impl-time (**E**); M fixes the byte-level shape and the subsumption.

> **H7 RESOLVED by ADR-0022 D2 (F17, 2026-06-19; the text above is kept as written):** the **global-flat**
> model is **ratified for v1** — the AD5 uniqueness invariant and the shared-repo-one-entry rule above are the
> v1 schema; per-project **namespacing is reserved post-v1** (it would require revising AD5 + the join
> semantics). The "global-vs-namespaced … is impl-time (E)" framing is therefore **superseded**: it was a
> schema/invariant question, not an impl detail. What remains for E is **pure mechanism**: atomic write =
> `mktemp` + `mv` (the existing `local-paths.sh` convention), single-writer, **no file lock** in v1 (writes are
> user-serial; a rare race is last-writer-wins and self-heals via the idempotent `cco resolve --scan`).

### D5 — DATA byte-level layout (resolves ADR-0015 D5)

```
<data>/cco/                            # $XDG_DATA_HOME/cco → ~/.local/share/cco   (0700)
  tags.yml                             # per-user global tag registry — typed keys avoid collisions
  remotes                              # de-tokenized Config-Repo endpoint registry (token lives in STATE)
  projects/<id>/source                 # install-provenance, keyed by project identity
  packs/<name>/source                  # install-provenance, keyed by pack identity
  templates/<name>/source              # install-provenance, keyed by template identity
```

- **`tags.yml`** — typed top-level keys prevent name collisions across resource kinds:
  ```yaml
  version: 1
  packs:      { mypack: [client, archived] }
  projects:   { projectA: [work] }
  templates:  { mytmpl: [personal] }
  ```
- **`remotes`** — plain de-tokenized map; the auth token is split out to STATE (D6):
  ```yaml
  version: 1
  remotes:
    origin: https://github.com/org/cco-config.git
    work:   https://git.company.com/team/cco-config.git
  ```
- **`source`** — **standalone file per resource identity** (not folded into one shared file): aligns with
  "centralized keyed-by-identity" (ADR-0013/0015), makes the publish re-strip trivial (delete the file), and
  makes per-resource sync atomic. It carries **only upstream coordinates** — confirming ADR-0015 D3's
  `required` sync-class with **no machine-specific leak** (no local path, no hash):
  ```yaml
  url: https://github.com/org/cco-config.git
  ref: main
  resource: packs/mypack       # optional sub-path within the Config Repo
  ```

`<id>` is the resource's logical name, identical to the STATE/CACHE keying so one identity spans buckets.
**Disambiguation (carried from ADR-0015 D3 / ADR-0014):** the DATA `remotes` registry (Config-Repo endpoints,
**never-team**) is **distinct** from the D2 **coordinate** (referenced-resource locators, **team-shared →
config in the manifest**). Same `name→url` shape, opposite Axis-2 → opposite bucket.

> **`source` schema + migration SPECIFIED by ADR-0022 D1 (F4, 2026-06-19; the layout above is kept as
> written):** the relocation from the config-bucket `<repo|pack>/.cco/source` to the DATA path above is a
> **cross-bucket relocation + field rename + reader rewrite** (not "Reuse"): `source:`→`url:`, `path:`→
> `resource:`, `ref:` kept. The machine-local bookkeeping (`commit`/`installed`/`updated`/`version`) moves to
> **STATE `/update` meta** (keyed by identity), so the DATA `source` is a **pure upstream coordinate** —
> confirming "no machine-specific leak". The machine-local `publish_target` is **dropped and re-derived on
> demand** (reverse-lookup of `url` in the DATA `remotes` registry). llms `source` is **not** relocated (D2/D7
> split it). The P2 migration writes the complete final form in one pass.

### D6 — STATE internal layout, partitioned by sync-eligibility (ADR-0013 D2; H6)

```
<state>/cco/                           # $XDG_STATE_HOME/cco → ~/.local/state/cco   (0700)
  index                                # D4 — name→abs-path + project→members (subsumes @local + local-paths.yml)
  remotes-token                        # SECRET, isolated, 0600, never-sync (split from the DATA registry; M3)
  last_seen / last_read                # global changelog markers
  claude.json / .credentials.json      # seeded auth
  sync-meta                            # sync-set membership + last-synced fingerprints (§4.6)
  backups/                             # vault-migration archives — moved OUT of ~/.cco (C1)
  projects/<id>/
    session/   memory/  claude-state/(transcripts)      # opt-in P8 (future R-state-sync)
    update/    meta(hashes, schema_version, policies, flags, local_framework_override)  base/(3-way ancestors)
    docker-compose.yml   .tmp/
```

The `/session` (`opt-in`) vs `/update` (`never`) partition is the **allowlist boundary** that prevents a future
P8 state-sync from ever sweeping `base/`/hashes/tokens. **H6 refactor (accepted, → E):** `base/` and `meta`
move from the committed `.cco/` into STATE `/update`; the merge helpers (`_cco_project_meta`/
`_cco_project_base_dir`/`_cco_project_compose`, `_merge_file`/`_resolve_with_merge`) take **separate config vs
state bases** — the `cco update` merge *logic* is unchanged, its *paths* are remapped.

> **Forward-annotation (2026-06-19) — D6 refinements (decision unchanged).** Two clarifications, both
> persisted in `design.md` §2.2 + §9 P2/§11; the D6 *decision* (base/meta→STATE `/update`, partitioned
> by sync-eligibility) stands verbatim:
> 1. **Global STATE update home pinned (fills a D6 enumeration gap).** The tree above lists
>    `projects/<id>/update/` + (D5) `packs/<name>/update/base/` but **omitted a global home**. The global
>    scope's update artifacts live at **`<state>/cco/global/update/{meta,base}`** (parallel to the
>    project entry). The global `.cco/meta` is **decomposed** (ADR-0013 D4): `languages`→`~/.cco`,
>    `last_seen`/`last_read`→STATE top-level (already shown), `schema_version`/policies/flags/
>    `local_framework_override`→this global update meta. *(Correction — ADR-0025: only the separate
>    `manifest.yml` is dropped, ADR-0012; the per-file hash `manifest:` block **travels into this
>    global update meta**, ADR-0013 D3 — not dropped.)*
> 2. **H6 build phase = Phase 2** (not P0). The "→ E" tag predates the Cluster-2 phase map; E is dissolved.
>    The relocation co-locates with the P2 migration (which *creates* base/meta in final form, build-once)
>    and `test_update`'s P2 rewrite — relocating in P0 would break delta-green against the hardcoded
>    `.cco/{meta,base}` assertions in `test_update` (P2) and `test_publish_install_sync` (P4–P5).
>    (Maintainer-confirmed re-sequence, 2026-06-19.)

### D7 — CACHE internal layout (regenerable; C2/H5/F1)

```
<cache>/cco/                           # $XDG_CACHE_HOME/cco → ~/.cache/cco   (0700)
  llms/<name>/                         # llms CONTENT download + cache-state (etag, resolved_url, downloaded)
  installed/                           # Config-Repo clones for install/update
  remote_cache                         # remote HEAD + ts (avoids network on update checks)
  coords-lookup                        # D3 — derived name→url lookup (advisory; scan-regenerable) [v1: NOT persisted — see below]
  projects/<id>/
    .claude/                           # generated overlays (packs.md, workspace.yml) → :ro into /workspace/.claude (F1)
    managed/                           # generated browser.json / github.json / policy.json → :ro overlay (H5)
  *.bak   dry-run/                     # update artifacts (cco clean)
```

**H5 resolution:** project `mcp.json`, `setup.sh`, `mcp-packages.txt` are **project config** → `<repo>/.cco/`
(D8); the framework-**generated** `.cco/managed/` (browser/github/policy JSON) follows F1 → **CACHE**, overlaid
`:ro` like `packs.md` (today it is generated into `<repo>/.cco/managed/` by `cmd-start.sh` — relocate). **C2
resolution:** only llms **content** → CACHE; the llms **coordinate** → the manifest (D2).

> **`coords-lookup` REFINED by ADR-0022 D-set (F45, 2026-06-19; the layout above is kept as written):** for v1
> `coords-lookup` is **computed on demand, never persisted** — the standalone CACHE file is **not created**.
> The line is retained above only to document where a future persisted cache would live if a measured need
> appears. (Eliminates invalidation/staleness handling entirely.)

### D8 — The two CONFIG buckets, exhaustive (fixes C3/C4)

**`<repo>/.cco/`** — project config, machine-agnostic, authored-only (rides the repo remote):
```
<repo>/.cco/
  .gitignore                 # ignores secrets.env + secret patterns; !secrets.env.example
  project.yml                # source of truth: repos[]/extra_mounts[]/packs:/llms: WITH embedded url/ref/variant (D2)
  secrets.env                # GITIGNORED, user-edited, IDE-reachable (the only in-repo gitignore exception)
  secrets.env.example        # COMMITTED skeleton
  mcp.json                   # project MCP config (H5)
  setup.sh                   # project setup script (H5)
  mcp-packages.txt           # project MCP package list (H5)
  claude/                    # COMMITTED + (copy-)synced → /workspace/.claude
    CLAUDE.md  rules/  agents/  skills/  settings.json
```
**Gone (C4 — all internal → STATE/CACHE/DATA):** `source`, `meta`, `base/`, `local-paths.yml`, generated
`docker-compose.yml`, generated `managed/`, `claude-state/`, `memory/`. **Never present:** `packs.md`/
`workspace.yml` (generated → CACHE overlay, F1).

**`~/.cco/`** — personal global store (its own git working tree; authored-only; opt-in private remote):
```
~/.cco/
  .git/  .gitignore          # allowlist whitelist (explicit staging, never git add -A)
  packs/<name>/              # hand-authored packs: pack.yml (WITH embedded llms coordinates, D2) + .md
  templates/<name>/          # user project/pack templates
  global/.claude/            # global Claude config (CLAUDE.md, rules, agents, skills, settings.json, mcp.json)
  secrets.env                # global secrets, GITIGNORED
  secrets.env.example        # committed skeleton (C3)
  languages                  # the ONE config datum extracted from .cco/meta (ADR-0013 D4); regenerates language.md
  setup.sh  setup-build.sh  mcp-packages.txt   # global setup/build/mcp (C3)
```
**Changes vs prior drafts (C3):** `tags.yml` **moved out** → DATA (ADR-0015); `manifest.yml` **removed**
(ADR-0012, must NOT appear); the `!tags.yml` allowlist line is **dropped** (ADR-0015); `backups/` **moved out**
→ STATE (C1); llms **content** is **not** here → CACHE (C2); **no** central coordinate registry file (D2 —
coordinates live in the manifests). `~/.cco` stays **authored-content-only**, the precondition ADR-0007 relies
on for the clean in-place git-repo model and for P6.

### D9 — Opt-in pre-commit config validation (maintainer consideration 3 → S/E)

An **opt-in, default non-blocking** pre-commit/pre-push validation extends the existing secret-scan hook
(ADR-0008 / design §2.1). It guards **sharing integrity** so an invalid `<repo>/.cco/` is not committed and
broken for recipients. The **validity contract** (recorded here; mechanism → S/E): every referenced
`repos:`/`llms:` id has its coordinate; ids are unique within their section; the config is **machine-agnostic**
(no real paths → truthful `git diff`, G8). Surfaced as `cco config validate` (exit-code only, invocable from the
user's own git hook / CI — cf. `cco sync --check`); never blocks by default (ADR-0008 reminder philosophy).

> **Surfaced verb RESOLVED by ADR-0023 D2 (2026-06-19; the validity contract above is kept as written):**
> the share-readiness check is **`cco project validate`** (cwd-first; exit 0/1/2; presence-only by default
> + `--reachable` opt-in network probe; docs-only pre-commit snippet, no installer in v1; non-TTY no-op),
> **not** `cco config validate` (which ADR-0023 D1 keeps for orphan-sanitization, ADR-0021 §5). Full I/O
> contract: ADR-0023 D2.

---

## The authoritative table (`resource → bucket · mutator · sync`)

"Mutator" applies the P1 edit-criterion (config = user via IDE; internal = `cco …` only). The **Legacy →
new** column folds in the migration fan-out map (one legacy file → N destinations).

| Resource | Bucket | Mutator | Sync | Legacy → new (fan-out) |
|---|---|---|---|---|
| `project.yml` (incl. embedded repo/llms coordinates), `claude/`, `mcp.json`, `setup.sh`, `mcp-packages.txt` | `<repo>/.cco` | user (IDE) | repo remote (both axes) | from `user-config/projects/<name>/` config part |
| project `secrets.env` | `<repo>/.cco` (gitignored) | user (IDE) | none (local) | unchanged location concept |
| `packs/` (pack.yml incl. llms coordinates), `templates/`, `global/.claude/`, `languages`, global `setup*.sh`/`mcp-packages.txt`, global `secrets.env` | `~/.cco` | user (IDE / config-editor agent) | `cco config push/pull` (private) | `languages` ← split from `.cco/meta` |
| **tags.yml** | **DATA** | `cco tag add/rm` | `required` | profiles (vault git-branches) → tag seeds |
| **remotes** (`name→url`) | **DATA** | `cco remote …` | `required` | `remotes` split: url → DATA |
| **source** (install-provenance, per identity) | **DATA** | cco (install/update) | `required` (travels with its resource; re-stripped at publish) | `.cco/source` → DATA keyed-by-identity |
| **index** (name→abs-path + project→members) | STATE | cco (`resolve`/`index refresh`) | `never` | `@local` + per-repo `local-paths.yml` → unified index |
| `remotes-token` | STATE (0600, isolated) | `cco remote set-token` | `never` (security) | `remotes` split: token → STATE |
| `base/`, `meta` (hashes/schema/policies/flags/`local_framework_override`) | STATE `/update` | cco (update) | `never` (version-tied) | `.cco/base/`, `.cco/meta` (update-state) → STATE (H6) |
| `last_seen`/`last_read` (changelog markers) | STATE | cco (update) | `never` | `.cco/meta` changelog markers → STATE |
| `sync-meta`, seeded `claude.json`/`.credentials.json`, generated `docker-compose.yml` | STATE | cco | `never` | unchanged class (relocate) |
| `backups/` (vault-migration archives) | STATE | cco (migrate) | `never` | `~/.cco/backups/` → STATE (**C1**) |
| `memory/`, transcripts (`claude-state/`) | STATE `/session` | Claude / cco | **`opt-in`** (P8 future) | `memory/` (vault-tracked) → STATE, no sync v1 (ADR-0009) |
| llms **content** + cache-state | CACHE | cco (`llms install/update`) | `never` (re-fetch) | llms content → CACHE (**C2**) |
| `installed/` clones, `remote_cache`, generated `.claude` overlays, generated `managed/`, `coords-lookup`, `.bak` | CACHE | cco | `never` | `.cco/managed/` → CACHE overlay (**H5**); `remote_cache` ← `.cco/meta` |
| **referenced repo/llms coordinate** (`url`+`ref`/`variant`) | the manifest (config, **D2**) | user (CLI/IDE; value is user knowledge) | with the manifest | llms central `source` url+variant → manifest; repo derived-at-publish url → persisted manifest coordinate |
| **removed** | — | — | — | `manifest.yml` (ADR-0012), `pack-manifest` (ADR-0013 D6) — no migrator |

---

## Validation against P1–P12

- **P1 (edit criterion)** — every CONFIG-bucket entry is user-edited (incl. coordinates, "the CLI is merely the
  editor; the value is user knowledge", ADR-0014 D3); every DATA/STATE/CACHE entry is `cco`-only. ✓
- **P2 (destination taxonomy)** — 4 buckets, exhaustively mapped; DATA resolved (ADR-0015). ✓
- **P3/P4 (two orthogonal axes; classify on both)** — every row carries an explicit `(bucket, sync)` pair;
  heterogeneous-profile files were split (`.cco/meta`, `remotes`). ✓
- **P5 (sharing asymmetry)** — the coordinate placement (D2) is **derived from** P5: by-construction repo
  sharing has no publish boundary → coordinate in the versioned config. ✓
- **P6 (hide internal)** — no internal datum remains in a config bucket; `local-paths.yml`/`source`/`meta`/
  `base/` all evicted; `~/.cco` stays authored-only. ✓ (closes C4)
- **P7 (sync mechanics)** — transports commits, never fabricates (ADR-0008); team via Config Repo; D3 lookup
  is derived, not a sync channel. ✓
- **P8 (STATE-sync is future)** — `/session` vs `/update` allowlist boundary preserved (D6). ✓
- **P9 (packaging-aware)** — no tool code in any data bucket; coordinates/source are data, not code. ✓
- **P10/P11 (classify by role; three questions)** — each datum placed from role + mutation + sync-class, not
  surface; the coordinate was decomposed (name/url/local-path/content) and split by profile (D2). ✓
- **P12 (referenced-resource coordinates)** — **refined**: coordinate is config, but **decentralized per-unit
  in the versioned manifest** (not a central registry); resolve-at-publish applies to the Config-Repo path; the
  by-construction repo carries it in the versioned config; DRY is scoped to the unit. The `name→url` (config,
  manifest) vs `name→local-path` (internal, STATE index) vs `content` (CACHE) cut is preserved. See the
  guiding-principles P12 update. ✓

---

## Alternatives Considered

| Alternative | Pros | Cons | Verdict |
|---|---|---|---|
| **Central per-user coordinate registry in `~/.cco` + resolve-at-publish** (ADR-0014's hint) | max DRY (one entry ever); preserves today's llms model | **infeasible for the by-construction-shared repo (P5)** — never reaches a teammate cloning the shared repo; centralizes config (against ADR-0013 D1); needs a global namespace; `~/.cco` would stop being authored-only | **Rejected** (the M-surfaced gap) |
| **Per-unit, dedicated sibling `coordinates.yml`** | explicit "registry per unit"; `project.yml` stays name-only | a second file to keep aligned to `repos:`/`llms:`; two manifests per unit; not the `package.json` shape | **Rejected** (maintainer: keep one uniform manifest) |
| **Per-unit, embedded in `project.yml`/`pack.yml`, uniform schema (chosen)** | one manifest (`package.json` model); travels for A/B/C; closes the repo Axis-1 gap; no namespacing; evolves the existing publish-time `url:` injection | mild cross-unit coordinate duplication (accepted as intentional per-unit independence; tooled by D3) | **Accepted** |
| **`source` folded into a single `<data>/cco/sources.yml`** | fewer files | weaker keyed-by-identity; non-atomic per-resource; harder publish-strip | **Rejected** (standalone per-identity, D5) |
| **Keep `local-paths.yml` per-repo** | minimal change | internal data in a config bucket (P6 violation, C4-class); duplicates the index; re-introduces sanitize/`@local` machinery | **Rejected** (unified STATE index, D4) |

---

## Consequences

**Positive** — a single authoritative `resource → (bucket, sync)` table; the 4-bucket layout is exhaustive and
P1–P12-clean; C1–C4 fixed; the coordinate's home is decided on a principled (P5-derived) basis and **closes the
repo Axis-1 auto-resolve gap**; one uniform manifest schema (`package.json` model) with a clear per-unit source
of truth (repos self-heal from their git remote); cross-unit consistency handled by tooling without a global
source of truth (D3); DATA/STATE/CACHE byte-level layouts fixed; the STATE index subsumes `@local`/
`local-paths.yml` (truthful `git diff`, G8); H5/H6/M3 absorbed; **S is unblocked** (it consumes this table + the
coordinate CLI/validation contract).

**Negative** — `project.yml`/`pack.yml` gain a schema change (embedded `url`/`ref`/`variant`) requiring a
migration (→ S); mild cross-unit coordinate duplication is accepted (mitigated by D3 tooling); the H6 merge-path
refactor and the `cmd-remote.sh` vault-git decoupling (M3) are real impl work (→ E); the derived `coords-lookup`
and the validation hook are new build (→ S/E). This ADR fixes the **target spec**; the **mechanism** (publish
resolution, coordinate CLI, validation, index concurrency) is owned by S/E.

## Reuse / Drop / Build-new

| Element | Verdict |
|---|---|
| `_sanitize_project_paths` repo-url derivation (`git remote get-url origin`) | **Reuse / generalize** — persist the url as a manifest coordinate (D2), not publish-only |
| per-repo `.cco/local-paths.yml`; `@local` markers; sanitize/restore machinery | **Drop** — subsumed by the STATE index (D4) |
| llms central `~/.cco/llms/<name>/source` (url+variant) | **Refactor** — url+variant → manifest coordinate; content/cache-state → CACHE |
| `cco update` 3-way merge logic | **Reuse** (relocate paths only — H6) |
| `cmd-remote.sh` coupling to vault git (`$USER_CONFIG_DIR/.git`); `remotes` `0600` | **Refactor** (M3 → E): decouple; registry → DATA, token → STATE `0600` |
| uniform manifest coordinate schema; STATE index subsumption; DATA byte-level; `coords-lookup`; `cco config validate`; coordinate CLI (`repo/llms add`, `coords --diff/--sync`) | **Build-new** (spec here; mechanism → S/E) |

## Open (deferred, not unresolved)

- **S** — publish-boundary resolution of coordinates (Config-Repo path); the `repos:`/`llms:` **schema change +
  migration** (embed `url`/`ref`/`variant`); the coordinate **CLI** (`cco repo/llms add`, `cco config coords
  --diff/--sync/--sanitize`) and the **`cco config validate`** hook; the no-token-leak check on the
  registry/token split; manifest-removal structure-based discovery; A4 fallback; Axis-1 public-repo.
- **T (R-state-sync)** — unified internal transport across DATA (`required`), STATE `/session` (`opt-in`),
  `~/.cco`; per-store allowlist; background auto-sync.
- **E (impl)** — H6 merge-path remap; M3 `cmd-remote.sh` decoupling; index atomicity/locking + global-vs-
  namespaced logical names (H7); `coords-lookup` persistence-vs-on-demand; CACHE name-collision disambiguation;
  extra_mounts `target` schema/migration (M5).

> **M5 RESOLVED by ADR-0023 D5 (2026-06-19):** the `extra_mounts` schema is `name` + OPTIONAL
> `url`/`ref` (coordinate, like `repos:`) + OPTIONAL `target` (machine-agnostic container path, default
> `/workspace/<name>`) + `readonly`; the host path lives in the STATE index keyed by `name`. No local
> cache/vendor (repo rule). Migration `source:/target:` → `name`+`target`(+`url?`) + index seed (P2).
