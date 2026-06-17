# R3 — Internal Metadata & the Unified Update/Merge Mechanism · Analysis Handoff

**Status**: Analysis-prep / handoff (2026-06-17). **R3 is reframed and deferred to a dedicated
clean session.** This document persists the session's findings, the maintainer's validated
intuitions, the method, and the open questions, so the next session starts with full context.
**Foundation**: read `guiding-principles.md` (P1–P10) first; then this doc; then the per-file
code anchors below.
**Prior**: R1 (ADR-0011, tag nature) · R2 (ADR-0012, manifest removed). Next free ADR = **0013**.

---

## Why R3 was reframed

R3 began as "place 5 internal files" (`.cco/source`, `.cco/meta`, `.cco/base/`,
`.claude/.cco/pack-manifest`, remotes registry+tokens). Code-grounding (3 analyst passes) +
maintainer review revealed a deeper truth: **these files are all metadata in service of ONE
thing — the resource diff/update/merge mechanism — and several of them mix responsibilities
with *different* sync/sharing needs in a single file.** You cannot correctly place them until
(a) the mechanism's shape and (b) the boundary between resource classes are settled.

**Two-phase plan for the clean session:**
- **Phase 0 — Cardinal points (frame the mechanism).** Establish: the **resource classes** that
  flow through update/merge; for each piece of tracked metadata, *what* it tracks, *for what
  function*, *for which scope*, and *which sync/sharing profile* it needs. Define the
  **team-shared ↔ private-multi-PC boundary** of the diff/update/merge mechanism. Couples with
  **S** (sharing unification) and **P9** (cco opinionated defaults shipped as an external
  package via the same publish/install path).
- **Phase 1 — Split & placement.** Using Phase-0's profiles, split each file by responsibility
  and place each datum. Record ADR(s) + update living docs + feed M.

---

## Cardinal points (the starting frame for the next session)

### Resource classes that flow through the update/merge mechanism
- **(A) Team-shared incoming** — packs/templates installed from a **Config Repo** (a third repo
  as remote; public, or private+token). "Team" here = *any* other user, known or not.
- **(B) Private user config, multi-PC** — the user's own `~/.cco` / `<repo>/.cco` resources
  synced across **their own** machines (Axis-1).
- **(C) cco opinionated defaults** — today baked/copied; **future**: extracted from cco-core and
  **shipped as an external package** installed via the *same* publish/install mechanism as (A).
  Unifying (C) into the shared path is the simplification the maintainer is driving toward.

> **Goal of the unification**: ONE diff/update/merge mechanism serving A/B/C, instead of separate
> ad-hoc paths. The metadata (`source`, hashes, `base/`) is the machinery of that mechanism.

### The discriminator (method)
For **every piece of information** a file carries, classify it **consciously on two orthogonal
axes** (P3/P4), then place it:
- **(a) Resource type** — `config` (user-authored, IDE-edited) · `internal` (cco-managed, CLI,
  hidden) · `state` (machine-local runtime) · `cache` (regenerable/transient).
- **(b) Sync/sharing profile** — `none` (machine-local, never travels) · `user-multi-PC`
  (Axis-1, the user's own machines) · `team-sharing` (Axis-2, other users, always via a Config
  Repo) — and note that `<repo>/.cco`'s git remote couples user-multi-PC **and** team-sharing
  onto one transport (P5), so "user-multi-PC but **not** team" is **not** expressible there.
If one file carries info with **heterogeneous** (a)/(b) values → that is the signal it must be
**split**. **Co-locate by sync-profile, not merely by functional domain.**

> **Co-locate by sync-profile, not merely by functional domain.** `source`, `meta.manifest`
> (hashes) and `base/` belong to the *same functional domain* (update/merge) but have
> **different sync profiles** — so they must stay in **separate files**. Merging them would
> re-create the grab-bag smell this analysis exists to remove.

---

## Per-file findings (code-grounded) + validated intuitions

### `.cco/source` — resource-coupled provenance
- **Role**: records the **upstream** a resource was installed from (`source` URL, `path`, `ref`,
  `commit`, `installed/updated`; llms: `url`, `variant`, `etag`, `resolved_url`). Drives
  `cco {project,pack,llms} update` and `internalize`.
- **Anchors**: `lib/paths.sh` `_cco_project_source()`/`_cco_pack_source()`; written
  `cmd-project-install.sh:201-207`, `cmd-pack.sh:676-683`, `cmd-llms.sh` `_llms_write_source`;
  read by `update-remote.sh _is_installed_project()/_check_remote_update()`, pack/project update,
  internalize. **Excluded from `cco pack export`** (`--exclude='.cco/source'`).
- **Validated model (maintainer)**: written/(re)written **locally by install/create**, per-PC.
  Canonical flow = update on one PC → **sync transports the applied result** (resource + updated
  `source`) to the other PC (ADR-0008: sync transports, never fabricates); independent update on
  the 2nd PC re-fetches the *same* upstream → converges, else reconciles via the divergence
  reminder. Only meaningful for resources **with an upstream**; for purely-local resources it is
  a trivial `source: local` / `native:`/`user:` marker.
- **Nature & profile**: **internal** (cco-managed, not hand-edited); **multi-PC synced WITH its
  resource**; **never team-shared** → it must **never sit in a publish-included path**.
- **Cat-4? — REOPENED for repo-scoped resources (maintainer correction, 2026-06-17).** The
  "sidecar" realization satisfies "multi-PC yes, team never" **only when the resource lives in
  `~/.cco`** (private-only by P5: multi-PC via `cco config push/pull`, never-team via privacy +
  publish-exclusion). **But for a resource in `<repo>/.cco` the repo's git remote serves BOTH
  axes at once (P5: team-shared by construction)** — so a sidecar there **cannot** give
  "multi-PC yes, team no": committing it shares it with teammates; gitignoring it removes it from
  multi-PC too (same transport). → For repo-scoped per-user data, a **dedicated cat-4 *location*
  outside the repo (privately synced, keyed by resource identity)** may be the only clean home.
  So the profile has **two candidate realizations** — **(i)** dedicated cat-4 bucket/location
  (data with no private home, or repo-scoped data that must NOT leak to the team); **(ii)**
  resource-coupled sidecar + publish-exclusion (works only for `~/.cco`-resident data). **This is
  an OPEN design question for R3 + the Cat-4 synthesis — do not treat the sidecar as settled.**
  Also clarify whether project `source` even *needs* to stay team-private (a teammate installs
  the template from the Config Repo and writes their *own* source; cloning the working repo would
  inherit it) — the principle (per-user provenance, re-established by each install) suggests it
  should not leak.
- **Not rebuildable** (the upstream URL exists nowhere else). **No secrets** (token comes from
  the remotes registry, matched via `remote_resolve_token_for_url(source.url)` — see remotes).

### `.cco/meta` — a GRAB-BAG mixing ≥5 responsibilities (split candidate, confirmed)
Concrete flows (who/when/why):
1. **Migrations**: `cco update` reads `schema_version` < latest → runs pending migrations → bumps
   it. *(framework-version bookkeeping; machine-local)*
2. **3-way change detection**: per tracked file, hash current vs `meta.manifest[file]` (last
   applied) vs `base/` vs new default → classify (unchanged / user-modified / update-available /
   merge); store new hash after apply. *(machine-local, rebuildable by rescanning)*
3. **Notifications**: `last_seen_changelog` / `last_read_changelog` drive "N new entries" and
   `--news`. *(notification state; machine-local; syncing would de-dupe across PCs — minor)*
4. **languages** (`communication/documentation/code`) → regenerated into `language.md`. *(a
   **user preference** leaking into a state file)*
5. **remote_cache** (remote HEAD + timestamp) → avoid network on update checks. *(pure CACHE)*
6. **template** (provenance-ish) + **local_framework_override** (escape-hatch flag).
- **Anchors**: `lib/paths.sh` meta helpers; `lib/update-meta.sh` (`_generate_cco_meta`,
  `_generate_project_cco_meta`, `_read_manifest`, `_run_migrations`); `cmd-init.sh:90-138`,
  `cmd-project-create.sh:191-218`. Global meta = user-local; project meta currently travels.
- **Conclusion (to formalise in R3)**: **split by responsibility/profile** — schema_version +
  manifest-hashes + policies → **STATE update-state** (machine-local); `languages` → user
  **preference/config**; changelog markers → notification state (machine-local, maybe synced);
  `remote_cache` → **CACHE**; `template`/`override` → provenance/flag. No secrets.

### `.cco/base/` — 3-way merge ancestor → STATE, machine-local, **NOT synced**
- **Role**: the **last-applied upstream version**, the common ancestor for `git merge-file
  --diff3 current base new`. Exists **only** for resources with an **upstream** (cco opinionated
  defaults; installed/shared resources) — **not** for purely user-authored or local files.
- **Anchors**: `lib/update-hash-io.sh` (`_save_base_version`, `_save_all_base_versions`,
  interpolation), `lib/update-merge.sh` (`_merge_file`, `_resolve_with_merge`),
  `lib/update-sync.sh`; seeded at `cco init`/`project create`/`install`, updated on sync.
- **Validated intuition (maintainer) — corrects current behaviour**: base is tied to the
  **local framework version**; if two PCs are on different cco versions, a synced base would be
  the **wrong ancestor** → broken merge. So base must be **machine-local STATE, NOT synced**;
  each PC reseeds its own. **Today the code commits base to the vault** ("for merge
  reproducibility") — that is a **design smell** the new model fixes (not an analysis error; the
  current code really does sync it). **Same sync-profile as `meta.manifest` hashes → co-locate
  the two as the machine-local "update-state".**
- **Cost flag (H6)**: the merge engine assumes `base/` is co-located with the scope's `.claude/`
  files; relocating to STATE means passing STATE paths into the merge functions (mechanical,
  touches several). Weigh in R3.

### `.claude/.cco/pack-manifest` — legacy, effectively dead → REMOVE
- **Role**: pre-ADR-14 cleanup marker, listing files a pack **copied** into a project so they
  could be deleted on removal. **Anchors**: `lib/paths.sh` `_cco_project_pack_manifest()`,
  `lib/packs.sh` `_clean_pack_manifest()`, `cmd-start.sh:653`.
- **Status**: ADR-14 mounts packs **:ro** (no copy) → **nothing writes it anymore**; it is only
  read once at `cco start` to clean legacy residue, then deleted. Machine-local, gitignored.
- **Conclusion**: with the **breaking cutover** (ADR-0006, store recreated) the "pre-ADR-14
  residue" case should not exist → **remove the mechanism** (confirm whether to keep a one-shot
  safety net for migrators).

### remotes registry (`.cco/remotes`) + tokens — SPLIT
- **Role**: the user's **personal publish/install infrastructure** — named Config Repos
  (`name=url`) + optional **tokens** (`name.token=...`). Distinct from a project's member repos
  in `project.yml` (project *composition*). **Anchors**: `lib/paths.sh` `_cco_remotes_file()`,
  `lib/cmd-remote.sh` (add/remove/set-token/remove-token; `remote_get_url/token`,
  `remote_resolve_token_for_url`), `lib/remote.sh` `_build_git_auth` (`GITHUB_TOKEN` fallback).
- **Facts**: tokens are secrets (`chmod 600`; in `_SECRET_FILENAME_PATTERNS`; `vault save`
  aborts). **url and token are already on separate lines → cleanly splittable, no logic change.**
- **Decision (already aligned with maintainer)**: **(a) tokens → STATE, machine-local, NEVER
  synced** (security invariant); **(b) de-tokenized registry (name→url) → cat-4 candidate**
  (internal, CLI-managed, synced cross-PC per-user, never team) so a remote registered on one PC
  is available on another (token absent → prompt/re-auth).
- **Link to `source`**: at update, cco matches `source.url` against the remotes registry to find
  the token (`remote_resolve_token_for_url`). So `source` (per-resource, travels with resource) +
  remotes registry (per-user, synced) cooperate; tokens never travel.

---

## Cross-cutting principles to carry forward
1. **One unified diff/update/merge mechanism** across resource classes A (team-shared),
   B (private multi-PC config), C (cco opinionated defaults as a future external package).
   Define the **A ↔ B boundary** of that mechanism — couples with **S** and **P9**.
2. **Classify each datum by sync/sharing profile**, then **co-locate by profile** (not just by
   functional domain). A file mixing profiles = a split signal.
3. **The "internal-but-synced, never-team" profile has two candidate realizations** — and the
   choice is **OPEN**: a dedicated cat-4 **bucket/location** (data with no private home, **or
   repo-scoped data that must not leak to the team**) vs a **resource-coupled sidecar +
   publish-exclusion** (works only for `~/.cco`-resident data — **fails for `<repo>/.cco`**,
   whose remote couples both axes, P5). The Cat-4 synthesis must decide per datum; the sidecar is
   **not** a settled default.
4. **Security invariant**: tokens (and any inline-token in an llms `source.url`) → STATE,
   machine-local, **never synced, never published**.
5. **Provenance ≠ update-state**: `source` (synced-with-resource) and `{hashes + base/}`
   (machine-local) are the same *domain* but **different files** by profile.

## Open questions for the clean session
- **Repo-scoped per-user data vs the dual-axis `<repo>/.cco` transport (key).** Since
  `<repo>/.cco`'s remote serves user-multi-PC **and** team at once (P5), any datum that must be
  "multi-PC yes, team no" (e.g. project `source`, or future per-user internal metadata attached
  to a team-shared repo) **cannot** live there as a sidecar. Decide: (i) a dedicated cat-4
  *location* outside the repo (privately synced, keyed by resource identity), or (ii) accept
  team-visibility where the datum is genuinely harmless to share, or (iii) re-establish it locally
  per install (no travel). Ties to the **A4 solo-adopter** tension (P5).
- The exact **A ↔ B boundary** of the update/merge mechanism, and where **C** (opinionated
  package) plugs in (with S / P9).
- `.cco/meta` split: confirm the target file/path per responsibility (update-state vs preference
  vs notification vs cache vs provenance/flag).
- `.cco/base/` in STATE: accept the **H6** merge-engine refactor cost, or a documented sidecar?
- `pack-manifest`: remove outright, or keep a one-shot migrator safety net?
- de-tokenized remotes registry: confirm cat-4 **bucket** membership (vs another realization).
- Does the unified mechanism let us **co-locate `{source-equivalent provenance} + {hashes} +
  base/`** per-resource as a single "update-tracking unit" *while keeping their sync profiles
  distinct* (e.g. provenance flagged synced, hashes/base flagged local within one dir)?

## Method reminder (P10 + ADR-0011)
Per-resource: current-state recap (code) → role/problem → validation vs ADRs/principles →
**maintainer confirm/reject** on UX/usage/sync choices → nature + classification + sync strategy.
Don't discard/accept a priori. Cross-cutting verdicts (cat-4 existence/membership) are
**synthesised**, not decided inside one file's analysis.
