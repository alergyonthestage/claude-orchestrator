# Resource-Coherence Inventory — Decentralized In-Repo Config

**Status**: Implementation-prep checklist (DESIGN phase, 2026-06-16; open items updated by M/ADR-0016,
2026-06-17; **sharing/pack/permission items by S/ADR-0018-0020, 2026-06-18**). Living artifact —
update as items are completed during implementation.
**Method**: 3 code-grounded analyst agents in parallel (templates/skills/agents · docs/roadmap ·
managed/infra/CLAUDE.md), then synthesis. No files modified by the analysis.
**Scope**: every resource **outside the core CLI** (`lib/*.sh`, `bin/cco` — covered by the
phased teardown in `design.md §9`) that references the **old** config model and must be realigned
to the decentralized model (ADRs 0001–0010). The `docs/maintainer/configuration/decentralized-config/`
tree is the NEW design (source of truth) and is excluded.

> **Purpose**: when the vault/profile/`user-config/` model is removed, dozens of peripheral
> resources (skills, templates, rules, docs, the managed `CLAUDE.md` baked into the image) still
> describe the old world. Several become **actively wrong** (not merely stale) at cutover —
> instructing users to run removed commands or promising a cross-PC memory sync that no longer
> exists. This inventory is the single checklist to keep them coherent.

---

## Old → New marker legend (what was hunted, and what it becomes)

| Old-model marker | New model |
|---|---|
| `user-config/` central root (`projects/`, `packs/`, `templates/`, `global/`) | **REMOVED.** Project config → `<repo>/.cco/`; global resources → `~/.cco/` (`packs/ templates/ global/.claude/` — **`manifest.yml` removed**, ADR-0012); **internal-but-synced → DATA** (`~/.local/share/cco`: `tags.yml`, de-tokenized remotes registry, install-provenance `source` — ADR-0015); state/cache → XDG (`~/.local/state/cco`, `~/.cache/cco`); machine-local index → STATE |
| `cco vault *` (save/diff/switch/move/profile/init/log/status) | **REMOVED.** Normal git for `<repo>/.cco/`; `cco config save/push/pull` for `~/.cco/` (ADR-0008) |
| **Profiles** (vault git branches, `.vault-profile`) | **REMOVED.** Per-user **tags**, **CLI-canonical → internal** (`cco tag add/rm` + `cco list --tag`, ADR-0011); registry `tags.yml` → **DATA bucket** `<DATA>/cco/tags.yml` (4th bucket EXISTS, ADR-0015 — not `~/.cco`); semantics per ADR-0010 |
| `@local` markers + per-repo `local-paths.yml` | **REMOVED.** Subsumed into the unified machine-local **STATE `index`** (`name→abs-path`); per-repo file evicted (internal-in-config-bucket, P6) — `project.yml` carries logical names + machine-agnostic `url` coordinates only (ADR-0002/0016 D4) |
| `memory/` (vault-tracked, auto-committed, cross-PC synced) | Machine-local **STATE** `<state>/cco/projects/<id>/memory/`, **no sync in v1** (ADR-0009) |
| `cco project create` | **REMOVED.** Entry points = `cco init` \| `cco join` \| `cco migrate` |
| `cco project resolve` | `cco resolve` / `cco path` (index-backed clone/resolve) |
| Generated `packs.md`/`workspace.yml`/`docker-compose.yml` written in-repo | → CACHE/STATE, overlaid `:ro` (ADR-0005/0007) |

---

## Phasing principle

Doc/resource updates ride the phase that makes them **true**, with one rule of thumb:
- **In-repo `<repo>/.cco/` layout facts** (project config moved in-repo) → **Phase 0**.
- **Commands that still work until removed** (`cco vault *`, `cco project create`, profiles) and the
  **`~/.cco` global store + `cco config`** → **Phase 3** (the breaking cutover).
- **Memory → STATE** facts → **Phase 2/3** (relocation lands with `cco migrate`; the managed
  `memory-policy.md` falsehood is corrected at the Phase-3 cutover; needs `cco build` — baked in image).
- **User-facing onboarding docs describe the END state** and should not be half-migrated → do them as a
  **Phase-3 documentation sweep**, not piecemeal.

---

## A. Templates, skills, agents

### A.1 `config-editor` project template — THE primary hotspot (substantially rewrite, not patch)
Its `project.yml`, `CLAUDE.md`, `config-safety` rule, and both skills are built end-to-end around
`user-config/projects|packs/`, vault, `@local`, and removed commands.

| Resource (file:line) | Old-model reference | Required change | Phase |
|---|---|---|---|
| `templates/project/config-editor/project.yml:7` | `- path: {{CCO_USER_CONFIG_DIR}}` | Mount `~/.cco/` via the new global-dir placeholder/var (`CCO_USER_CONFIG_DIR` removed) | **0/3** (coordinate with the `bin/cco`/`lib/paths.sh` rename) |
| `…/project.yml:5,8` | `# user-config is mounted as a repo`; `name: user-config` | Rename mount (e.g. `cco-config`) + reword comment to "`~/.cco` global resources" | 3 |
| `…/.claude/CLAUDE.md:50-74` | `/workspace/user-config/` layout tree (`projects/`, `packs/`, `memory/ (vault-tracked)`, `manifest.yml`) | Rewrite the whole layout block: `~/.cco/` (packs/templates/global/tags.yml — **no `manifest.yml`**, removed ADR-0012) + `<repo>/.cco/` + STATE/XDG | 3 |
| `…/.claude/CLAUDE.md:13,78-92` | `### Vault Management`; `cco vault save/diff`; project-creation flow under `projects/<name>/` | Replace with `cco config save/push/pull` (`~/.cco`) + normal git (`<repo>/.cco`); entry = init/join/migrate | 3 |
| `…/.claude/CLAUDE.md:37,127,135-137` | `@local … cco project resolve`; `cco project create`; `cco vault save`; `cco vault diff`; `cco project resolve` (command list) | Remove/replace each removed command | 3 |
| `…/.claude/rules/config-safety.md:14-17` | `## Vault Awareness` + `cco vault save/diff` + "reference the vault" | Rewrite: `cco config save/push/pull` + normal git; drop "vault" | 3 |
| `…/.claude/skills/setup-project/SKILL.md:27,41,45-46,56` | `/workspace/user-config/packs/`; create under `user-config/projects/<name>/`; `cco vault save` reminder | Retarget to in-repo `<repo>/.cco/` init + `~/.cco/packs/`; `cco config save`/git | 3 |
| `…/.claude/skills/setup-pack/SKILL.md:51,66` | create `/workspace/user-config/packs/<name>/`; `cco vault save` reminder | `~/.cco/packs/<name>/`; `cco config save` | 3 |

### A.2 Base templates (light, comments only)

| Resource (file:line) | Old-model reference | Required change | Phase |
|---|---|---|---|
| `templates/project/base/project.yml:16` | `# Reference packs from user-config/packs/<name>/pack.yml` | Packs referenced by **name + OPTIONAL coordinate** (`url`/`ref`/`resource`, ADR-0019 D1); resolved into `~/.cco/packs/<name>`; show the coordinate schema + the project-local `<repo>/.cco/packs/` option | 1 |
| `templates/project/base/project.yml:25` | `# Files are stored in user-config/llms/ … mounted read-only` | `~/.cache/cco/llms/` (CACHE, ADR-0007) | 1 |

### A.3 Verified clean (no change)
`templates/pack/base/*`; `defaults/global/.claude/agents/{analyst,reviewer}.md` and
`defaults/global/.claude/skills/{analyze,commit,design,review}` — the `memory: user` frontmatter is
native Claude-Code **subagent** scope, NOT the cco memory/vault model (do not touch).

---

## B. Managed config + infrastructure + CLAUDE.md

| Resource (file:line) | Old-model reference | Required change | Phase | Risk |
|---|---|---|---|---|
| `defaults/managed/.claude/rules/memory-policy.md:13,31` | `Memory is personal, machine-synced via vault`; `vault-synced` | `machine-local STATE, NOT synced (v1)` (ADR-0009) | 3 | **HIGHEST — baked in image, non-overridable, ACTIVELY FALSE post-cutover.** Needs `cco build` |
| `defaults/managed/.claude/rules/memory-policy.md:5` | memory path `~/.claude/projects/-workspace/memory/` | Note host home = `<state>/cco/projects/<id>/memory/` (container path unchanged) | 3 | Managed/baked |
| `CLAUDE.md:13-22,181` (repo root) | `user-config/ is the unified root`; `copied to user-config/global/.claude/`; `user-config/ is gitignored`; generated `projects/*/memory/` | Rewrite scope/layout block: `~/.cco` + `<repo>/.cco` + STATE/CACHE; generated compose → STATE | 0/3 | **HIGH — authoritative self-dev onboarding** |
| `CLAUDE.md:64-77` (repo root) | full `cco vault *` command list; `cco project create/install/update/delete` | `cco config *` + `cco sync`/`resolve`/`list --tag`; entry = init/join/migrate | 3 | Commands won't exist |
| `CLAUDE.md:128` (repo root) | `memory/ … vault-tracked and syncs across machines` | memory = STATE, no sync v1 | 3 | Actively false |
| `CLAUDE.md:153-154` (repo root) | `lib/local-paths.sh … @local … local-paths.yml`; `lib/cmd-vault.sh … profiles (git-backed)` | Update lib descriptions: index-backed; `cmd-vault.sh` → `cmd-config.sh`/`cmd-sync.sh` | 1/3 | Key-files list |
| `.claude/rules/update-system.md:20` | example "new **vault** capabilities" | swap example for "config/sync" | 3 | Low; **user-owned rule — propose, don't auto-edit** |
| `.gitignore:1-2,11` | `/user-config/`; `user-config/global/secrets.env` | Dead entries post-cutover; new ignore for `<repo>/.cco/secrets.env` (state/cache are out-of-repo) | 0/3 | |
| `.dockerignore:3` | `projects/*/claude-state/` | Stale glob (build-context only) — clean up | 3 | Low |
| `changelog.yml` (24-40, 62-76, 150-212) | history entries: vault profiles, memory vault-tracked, `cco project create`, `@local`/`local-paths` | **Do NOT rewrite history.** Add ONE new breaking entry announcing vault removal + memory→STATE + profiles→tags | 3 | Append-only |

### B.1 Verified model-agnostic infrastructure (no change for this cutover)
`config/hooks/*` (session-context, subagent-context, prompt-submit, statusline, precompact),
`config/entrypoint.sh`, `config/tmux.conf`, `Dockerfile`, `defaults/managed/managed-settings.json`,
`defaults/managed/CLAUDE.md` (concept only — points to memory-policy.md), `defaults/managed/.claude/rules/{documentation-first,use-official-docs}.md`,
`defaults/managed/.claude/skills/init-workspace/SKILL.md`, all `defaults/global/.claude/rules/*` and
`defaults/global/.claude/{CLAUDE.md,settings.json,mcp.json}` — these operate on in-container runtime
paths, not the host config layout. (The only real infra change is **BL3** — relative `./` compose
mounts → host-absolute — which lives in `lib/cmd-start.sh`, Phase 0, tracked in `design.md §9`.)

---

## C. Documentation (`docs/`)

### C.1 Full rewrite — entire sections describe REMOVED features (highest user-facing risk)

| Doc | What | Action |
|---|---|---|
| `docs/user-guides/configuration-management.md` (§2 Vault 30-89, §3 Profiles 90-209, workflows 490-572, cmd ref 573+) | ~2 of ~9 sections are vault+profiles | Delete vault/profile sections; rewrite around git on `.cco/` + `cco config` + per-user tags |
| `docs/reference/cli.md` (§3.4 `project create` 251-309; §3.21 `cco vault`+profiles 911-1229) | ~370 lines on removed surface | Replace with `cco init/join/migrate`, `cco config save/push/pull`, `cco sync`, `cco resolve`, `cco list --tag` |

### C.2 Heavy rewrite — structural `user-config/` remap + diagrams/tables (the "contract" docs)

| Doc (representative lines) | Focus | Action |
|---|---|---|
| `docs/reference/context-hierarchy.md` (43-46, 144-510, 784-808; memory 380-416, 867-897) | scope tables "Real Location" + mount/memory | Remap global→`~/.cco`, project→`<repo>/.cco`, secrets in-repo gitignored; mount = single `/workspace/.claude` + `:ro` overlays (ADR-0005); memory = STATE |
| `docs/maintainer/architecture/architecture.md` (17-123 diagram/table; memory 197-222; 280, 394-505, 624-664) | architecture diagram + memory rationale | Redraw on decentralized model; rewrite memory rationale (ADR-0009); update command list |
| `docs/maintainer/integration/docker/design.md` (mount table 389-410; tree 649-716; memory 556-816; gen files 788-791) | Docker mount table = contract | Remap mount sources (host-absolute, ADR-0005); generated files → CACHE; memory → STATE |

### C.3 Medium — onboarding (first commands the user types: correctness-critical)

| Doc (representative lines) | Action |
|---|---|
| `docs/getting-started/installation.md` (45-104) | `cco project create` → init/join/migrate; `user-config/` → `~/.cco`/`<repo>/.cco` |
| `docs/getting-started/first-project.md` (14-45; memory 30) | same command swap; memory note |
| `docs/user-guides/project-setup.md` (10-339; vault 289-339) | command swap; remove the "built-in vault"/`@local` section → git on `.cco/` + index |

### C.4 Light — mechanical path/command substitution

`docs/getting-started/concepts.md` (83 `cco vault push`→`cco config push`; 11,114 paths) ·
`docs/user-guides/knowledge-packs.md` (paths; 295 `cco vault push`) ·
`docs/user-guides/authentication.md` (claude-state→STATE; secrets paths) ·
`docs/user-guides/troubleshooting.md` (paths; 366 `project create`) ·
`docs/user-guides/advanced/custom-environment.md` (`user-config/global/`→`~/.cco/global/`) ·
`docs/reference/project-yaml.md` (8,32,104-280: paths, `@local`, fix link to retired
`vault/local-path-resolution-design.md`) · `docs/maintainer/architecture/spec.md` (50,91,186
`project create` in FRs) · `docs/user-guides/{agent-teams.md,advanced/subagents.md,README.md,
structured-agentic-development.md}` (path mentions / "vault" word).

**Confirmed false positives (no action):** `browser-automation.md` (Chrome profile),
`development-workflow.md`/`configuring-rules.md` ("risk profile"), `installation.md:35-37`
(`~/.bash_profile`), `troubleshooting.md:31` (npm registry), `concepts.md:156` (agents "profiles").

### C.5 Roadmap (`docs/maintainer/decisions/roadmap.md`)
Section "Vault Simplification → Decentralized In-Repo Config" already exists (status "Design APPROVED
2026-06-15"). **Reconcile, don't rewrite**: bump ADR range 0001–0006 → **0001–0010**; mark RD-memory
+ RD-authoring **resolved** (only RD-triggers + review follow-ups remain); mark bug class #B13–#B23
(vault/`@local`/profile) as **mooted** by the removal; add implementation-phase status when impl starts.

---

## Cross-cutting patterns

1. **"Run `cco vault save`" reminders** recur in config-editor (`CLAUDE.md`, `config-safety.md`,
   both skills) → all become `cco config save`/git. A removed command instructed everywhere.
2. **`/workspace/user-config/...` layout** is hard-coded in the config-editor skills/diagram and the
   "contract" docs (context-hierarchy, architecture, docker/design) → systematic remap to `~/.cco` +
   `<repo>/.cco` + XDG.
3. **`memory/` described as "vault-tracked / syncs across machines"** in cli.md, context-hierarchy.md,
   architecture.md, docker/design.md, first-project.md, repo `CLAUDE.md`, and the **managed**
   `memory-policy.md` → ADR-0009 makes it STATE, no sync v1. A **capability promise that disappears** —
   change rationale, not just paths.
4. **`cco project create`** in every onboarding doc + repo `CLAUDE.md` → init/join/migrate.

---

## Open items to confirm during implementation

1. **`manifest.yml`**: ~~survives unchanged~~ → **REMOVED entirely (ADR-0012)**. R2 found every
   functional read is discovery/validation, replaceable by the Config Repo's directory structure
   (`templates/*/`, `packs/*/`); no manifest-exclusive datum is consumed (repo URLs travel in the
   published `project.yml`; descriptions in `pack.yml`; sharing tags/identity are write-only).
   `lib/manifest.sh` + `cco manifest` + all `manifest_refresh`/`manifest_init` call sites are
   dropped; the **structure-based-discovery refactor is DECIDED by ADR-0018** (sharing-repo layout =
   `packs/`+`templates/` only; `git ls-tree` over a treeless clone; init-at-first-publish + merge-on-
   existing) — **impl → E**. *(Cleanup of inert `manifest.yml` files rides the Phase-3 cutover.)*
2. **`llms/`** (refined by **ADR-0014**, conflict **C2** resolved; **scope finalized by ADR-0016/M**):
   only the **content/downloads** live in **CACHE** `~/.cache/cco/llms/<name>/` (ADR-0007), deduped per
   machine by name. The llms **coordinate** (`url`+`variant`) is **config** (user-known) and is
   **embedded per-unit in the versioned manifest** (`project.yml`/`pack.yml`, uniform schema —
   `package.json` model; ADR-0016 D2), **not** a central registry, **not** CACHE, **not** cat-4. Same
   category as project **repo URLs**: persist the URL as a manifest coordinate (closes the Axis-1
   auto-resolve gap; for repos the clone's git remote is the self-healing source of truth). Cross-unit
   consistency is **tooling-enforced** (`cco config coords`, ADR-0016 D3), not a central store. **Phase
   homes (Cluster 2, corrects the earlier "→ S" mis-routing — F36):** the `llms:`/`repos:` coordinate
   **schema + parsers** → **Phase 0** (substrate; by P11(a) they are needed without team-sharing —
   auto-resolve, clone-from-`url`, re-fetch); the **resolve mechanism** → **Phase 1**; **publish-
   boundary resolution** → **Phase 4** (sharing). Update base template comments accordingly. Hand-
   curated llms is **not** supported (content is re-fetchable).
3. **H5 project-config inventory — RESOLVED (ADR-0016 D7/D8)**: project `mcp.json`/`setup.sh`/
   `mcp-packages.txt` are **project config** → `<repo>/.cco/`; the framework-**generated** `.cco/managed/`
   (browser/github/policy JSON) follows F1 → **CACHE** `<cache>/cco/projects/<id>/managed/`, overlaid
   `:ro`. The remaining `project.yml` **container mount path** + `init-workspace` rw write-back
   (`/workspace/.claude/project.yml` vs `/workspace/project.yml`) → **Phase 0** (compose mount bucket
   map, BL3; the container side of `entrypoint.sh` is the preserved invariant).
4. **`.cco/claude-state/` (transcripts) and `memory/`** both become STATE under
   `<state>/cco/projects/<id>/` (ADR-0007 + 0009) — neither stays in the repo.
5. **Internal metadata (`source`, `base/`, `meta`, `pack-manifest`, remotes registry+tokens)**:
   **all internal → out of the config buckets**, centralized keyed-by-identity in STATE/CACHE/**DATA**
   (**ADR-0013**, resolves conflict **C4**). `base/`→STATE·`never`-sync (H6 merge-path refactor);
   `.cco/meta` split (`languages`→config/preference is the lone exception); `remote_cache`→CACHE;
   token→STATE·`never`; de-tokenized registry + `source`→**DATA** (cat-4, `required`-sync — **ADR-0015**
   resolved the verdict: the 4th category EXISTS = XDG **DATA** `~/.local/share/cco`; `source` syncs
   `required`); **`pack-manifest` removed outright** (no migrator). Team-sharing surface → S. **Byte-level
   layout RESOLVED (ADR-0016/M)**: DATA = `tags.yml` (typed keys) · `remotes` · per-identity standalone
   `source` files (upstream `url+ref` only, `required`); STATE `index` **subsumes** `@local` + per-repo
   `local-paths.yml` (D4); STATE `/update` (`base/`/`meta`, H6) vs `/session` (memory/transcripts);
   `backups/` → STATE (C1). **H6** merge-path remap + **M3** `cmd-remote.sh` decoupling → **Phase 0
   substrate** (§9, Cluster 2 — both are reused substrate: H6 by `cco update` + sync-before-publish,
   M3 satisfies the Phase-5 S8 no-token-leak invariant by construction; the 5 downstream callers
   consume the public helpers, unaffected).
6. **Pack references & lifecycle (ADR-0019)**: `packs:` join the **coordinate model** (`name` +
   optional `url`/`ref`/`resource`). **Phase homes (Cluster 2, open-closed):** the pack **schema +
   parser** → **Phase 0** (built once with repos/llms, so no parser rewrite); the bare-list→map
   **migration** (backfill `url`/`ref`/`resource` from the installed pack's DATA `source`, absent →
   authored-in-repo, F37) → **Phase 2** (one complete `project.yml` write, no double migration);
   pack **resolution behavior** → **Phase 4–5**. New optional **`<repo>/.cco/packs/<name>/`** location: project-local **authored** pack (no
   coordinate = source) **or** last-layer **cache** of a referenced pack (has coordinate). Resolution
   is **two-axis**: mount (`~/.cco/packs` → fetch-from-`url` → `<repo>/.cco/packs` cache) vs
   update/source-of-truth (sharing repo post-publish, **working-copy** model). **Defect to fix**:
   `cco pack publish` does a fast-forward push → must **sync-before-publish** (3-way merge). New:
   `cco project internalize`, `cco config validate` reachability contract, `export --bundle-packs`
   dependency-closure, internalize-as-cache prompt. Templates are scaffold-only (no coordinate). → **E**.
7. **Permissions (ADR-0020)**: enforcement **delegated to git** (no cco gatekeeper). Optional
   **`cco config protect`** scaffolds `<repo>/.cco/CODEOWNERS` + emits host ruleset instructions;
   document the sharing-repo (whole-repo split + repo-splitting for read granularity) vs project-repo
   (co-writable `<repo>/.cco`) governance. **S8 no-token-leak** = checklist + tests. → **E**.

---

## Sequencing recommendation
Treat this inventory as a **Phase-3 documentation/resource sweep** with two earlier touch-points:
(a) Phase 0 — repo `CLAUDE.md` + `.gitignore` + base-template comments for the in-repo `.cco/` layout
facts; (b) Phase 2 — memory relocation notes. The bulk (config-editor rewrite, managed
`memory-policy.md`, the vault/profile/`project create` doc surface) lands at the **Phase-3 cutover**,
since those commands and the `~/.cco`/`cco config` surface only exist then. The managed
`memory-policy.md` and repo `CLAUDE.md` are the highest-priority items because they are authoritative
and (for the managed rule) baked into the image.
