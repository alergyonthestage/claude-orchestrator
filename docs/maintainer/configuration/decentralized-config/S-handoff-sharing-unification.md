# S — Sharing Model Unification: handoff for the next (clean) session

> **✅ RESOLVED — S DONE (2026-06-18).** This scaffold is consumed by **ADR-0018** (sharing surface:
> nomenclature, 2×2 command matrix, structure-based discovery, asymmetry, solo-adopter A+B), **ADR-0019**
> (referenced-resource reachability + pack lifecycle: coordinate model extended to packs, working-copy
> lifecycle, internalize-as-cache), and **ADR-0020** (permissions delegated to git). New cardinal
> principles **P13–P17** in `guiding-principles.md`. Decisions propagated to `design.md` §2.1/§2.4/§6.2/
> §7/§12, `analysis-roadmap.md`, `resource-coherence-inventory.md`, `requirements.md`, and the global
> roadmap. Kept below as history (the S1–S11 scope map and reading order). **Next = implementation (E).**

**Status**: Handoff scaffold for analysis **S** (team-sharing / Config-Repo unification). Produced
2026-06-17 after M + the M-review refinements (ADR-0016/0017). **Resolved 2026-06-18 by
ADR-0018/0019/0020.** S ran in its **own clean session**, opening by reading `guiding-principles.md`
(P1–P12, source of truth) **and this file**.

**Read first**: `guiding-principles.md` (esp. **P3** two axes, **P5** sharing asymmetry, **P6**
hide-internal, **P9** packaging-aware, **P12** referenced-resource coordinates). **Grounded in**: ADRs
0001–0017. **Consumes**: ADR-0016 (authoritative `resource→(bucket,sync)` table), ADR-0017 (coordinate
field semantics), ADR-0014 (coordinate model), ADR-0012 (manifest removed), ADR-0013 (R3
shared-surface map). **Produces**: ADR(s) / a dedicated sharing design doc + `design.md §6.2`/§7
updates + propagation to `requirements.md`, `analysis-roadmap.md`, `resource-coherence-inventory.md`.
**Hands off**: **T** (transport / state-sync), **E** (impl follow-ups). **Next free ADR = 0018.**

> Nothing here overrides an ADR. Where this scaffold and an ADR disagree, the ADR wins and this draft
> is the defect to correct. This is S's *starting point*, not a decision.

---

## 1. Where M left things (the inputs S builds on)

The **config** side is fully decided (ADRs 0001–0017). The cardinal end-state S must respect:

1. **Config decentralizes**: project config → `<repo>/.cco/` (rides the repo remote; team-shared **by
   construction**, P5); personal global config → `~/.cco/` (Axis-1 private only).
2. **Internal centralizes keyed-by-identity** in DATA/STATE/CACHE; never in a config bucket (P6).
3. **Referenced-resource coordinates** (`name→url`+`ref`/`variant`) are **config, embedded per-unit in
   the manifest** (`project.yml`/`pack.yml`, uniform schema — `package.json` model; ADR-0016 D2 /
   ADR-0017 D1). Content → CACHE; local-path → STATE index. **Cross-unit consistency is by tooling,
   not storage** (no global registry).
4. Two distinct team channels (the cut S must keep clean):
   - **`<repo>/.cco/` team-shared *by construction*** (P5) via the shared code repo — **no publish
     boundary**, coordinates already travel in the versioned config.
   - **`~/.cco` resources (packs/templates) shared *only* via a Config Repo** (Domain B, `cco
     pack/project publish` to a 3rd repo) — a **discrete publish event** where resolution happens.

S owns the **Domain-B / Config-Repo** half (the publish event), plus the coordinate/validation CLI and
the team-shared-repo structure realignment.

## 2. What S must produce (scope)

| # | Item | Source / owner note |
|---|---|---|
| **S1** | **Publish-boundary coordinate resolution** — at `cco pack/project publish`, inject/resolve the unit's referenced coordinates into the published bundle (repos already inject URLs at publish; generalize to llms). The by-construction repo path needs nothing. **Never publish cat-4**: re-strip install-provenance `source` (a recipient re-establishes their own on install). | ADR-0014 D4, ADR-0015 D3, ADR-0016 D2 |
| **S2** | **Repo URL persistence / Axis-1 gap closure** — persist the repo `url` as a manifest coordinate (already decided, ADR-0017 D1); S defines the install/resolve flow that consumes it. | ADR-0014, ADR-0017 D1 |
| **S3** | **`llms:`/`repos:` schema change + migration** — embed `url`(+`ref`/`variant`) on reference entries (uniform `project.yml`/`pack.yml`); migrate existing manifests + the legacy central llms `~/.cco/llms/<name>/source`. | ADR-0016 D2, ADR-0017 D1 |
| **S4** | **Coordinate CLI** — `cco repo/llms add <name>` (auto-resolve `url` from a known id via the CACHE `coords-lookup`), `cco config coords --diff/--sync/--sanitize` (list/heal cross-unit divergence). Consistency by tooling. | ADR-0016 D3, ADR-0017 D2 |
| **S5** | **`cco config validate` opt-in pre-commit hook** — sharing-integrity contract: every referenced id has its coordinate; ids unique within section; config machine-agnostic (no real paths, truthful `git diff` G8). Default non-blocking (cf. `cco sync --check`). | ADR-0016 D9 |
| **S6** | **Manifest-removal refactor (Domain-B discovery)** — replace `manifest.yml` discovery/validation in `project/pack install` with **structure-based discovery** (`ls templates/*/`, `ls packs/*/`); replace empty-repo `manifest_init` with a `.gitkeep`/first-resource commit; delete `lib/manifest.sh` + `cco manifest` + `manifest_refresh`/`manifest_init` call sites; decide whether any **minimal** repo identity/catalogue surface is worth re-introducing (default: **no**, YAGNI). | ADR-0012 |
| **S7** | **Domain-B Config-Repo structure realignment (ADR-0017 F3)** — clean/align the team-shared Config-Repo layout to the decentralized model (no manifest; coordinates resolve-at-publish; structure-based discovery). Note any divergences the new design introduced. | ADR-0017 F3 |
| **S8** | **No-token-leak security check** — verify the registry/token split (de-tokenized `remotes`→DATA; token→STATE·`never`·`0600`) introduces no token leak at publish/install/sync. | ADR-0013 D7, ADR-0015 |
| **S9** | **`~/.cco` public-remote warning mechanism** — implement the *allow + warn* decision (P3 resolved by ADR-0017 D4): the warning copy/trigger when a user sets a public Axis-1 remote; document team-sharing ≠ `~/.cco`. | ADR-0017 D4 |
| **S10** | **Opinionated defaults as an official public Config Repo** — evaluate shipping cco's opinionated packs/templates separately via the same publish/install path any user uses (P9). | P9, R-pkg / R-update-native |
| **S11** | **A4 fallback (option B), post-v1** — solo cco adopter in a team that won't commit `.cco/`: project `.cco/` under `~/.cco` outside the repo (index `config_path` field, `~/.cco/projects/` re-expansion, `cco start` discovery/precedence). Record; likely defer. | P5/A4 |

## 3. What S consumes (do not re-derive)

- **The authoritative table** (ADR-0016): every `resource→(bucket,mutator,sync)`. S places nothing new
  into a bucket; it designs the *publish/install/update/export mechanism* over the existing map.
- **R3's shared-surface map** (ADR-0013 D7): the machinery common to local-update **and**
  team-install — the **3-way merge with `base/`**, **`source` provenance** (drives `cco update` of
  installed resources), the **remotes registry + token** (auth), **`remote_cache`** (remote checks).
  S reuses these; it does not rebuild them.
- **The A↔B↔C resource classes** (ADR-0013): A = team-shared incoming (S), B = private multi-PC (R3,
  done), C = cco opinionated defaults (S / R-pkg).
- **The coordinate model** (ADR-0014/0016/0017): reference by-name; coordinate embedded per-unit;
  resolve-at-publish for the Config-Repo path; content→CACHE; local-path→STATE index.

## 4. Open decisions S must settle

1. **Publish-bundle shape** — what exactly travels in a published pack/project (resolved coordinates
   injected; `source` re-stripped; no cat-4; no manifest). Define the on-disk Config-Repo layout that
   structure-based discovery walks.
2. **Install/update resolution** — how a recipient resolves embedded coordinates (repos → clone into a
   chosen local-path via `cco resolve`; llms → fetch into CACHE), and how `cco update` of an installed
   resource uses `source` + `remote_cache`.
3. **Minimal repo identity/catalogue?** — after removing `manifest.yml`, is *any* lightweight
   repo-level descriptor worth keeping (default: no). If yes, justify against YAGNI.
4. **Axis-1 public-repo** — the *policy* is resolved (allow + warn, ADR-0017 D4); S defines the
   *mechanism* (warning copy, when triggered) and the guide wording.
5. **Opinionated-defaults distribution** — official public Config Repo vs baked-in; coordinate with
   R-pkg / R-update-native.

## 5. Method (P10/P11/P12 + the ADR-0014 lens)

Classify each datum/flow from **role + problem + how-mutated**, never surface/path. Decompose; classify
on `resource-type × sharing-sync-profile`; apply **P6** (team-shared ⇒ not internal) and **DRY** as
discriminators; **resolve at the boundary, don't duplicate**. **Maintainer confirmation** is required on
UX/interface/sync-strategy choices (not derivable from code alone). Record an ADR (next free = **0018**)
+ propagate to `design.md`/`requirements.md`/`analysis-roadmap.md`/`resource-coherence-inventory.md`.

## 6. Reading order for the S session

1. `guiding-principles.md` (P1–P12; esp. P3/P5/P6/P9/P12).
2. **This file.**
3. ADR-0012 (manifest removed), ADR-0013 (R3 shared-surface map + A/B/C classes), ADR-0014 (coordinate
   model), ADR-0016 (authoritative table + D2/D3/D9), ADR-0017 (coordinate fields + D4 public-remote +
   F3 Domain-B realignment).
4. `design.md` §6 (two sync domains) + §7 (command surface) + §10 (packaging) — the current Domain-B
   surface S realigns.
5. Code grounding (P10): `lib/cmd-project-publish.sh`, `lib/cmd-project-install.sh`, `lib/cmd-pack.sh`,
   `lib/cmd-remote.sh`, `lib/remote.sh`, `lib/manifest.sh`, `lib/local-paths.sh:_sanitize_project_paths`
   (the existing publish-time URL injection to generalize).
