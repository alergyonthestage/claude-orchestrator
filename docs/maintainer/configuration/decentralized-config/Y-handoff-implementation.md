# Y — Implementation handoff (decentralized in-repo config)

**Status (2026-06-19):** the design is **CLOSED and READY**. All role-first analyses (R1–R4, Cat-4, M, S),
the sharing model, the impl-readiness review (V), and **all 5 of its clusters** are RESOLVED & PERSISTED —
ADRs **0001–0023**, living `requirements.md` + `design.md` are the single source of truth. **There is no
design work left.** This file launches the **implementation**, which runs along the `design.md` §9
**P0–P5** dependency-layer map. Produced on `feat/vault/decentralized-config` (commits **local** — pushed
from the maintainer's Mac).

> The per-cycle design/cluster scaffold handoffs (M/R3/S/V/W/X/Z*) were **consumed and removed** — their
> decisions live in the ADRs (`decisions/`) and the reviews (`reviews/`); their history is in git. **This
> file is the master implementation handoff.** Two companions: per-phase **launch** handoffs (e.g.
> `P2-handoff-migration-bootstrap.md`) and the recurring **`implementation-review-handoff.md`** (an adherence/gap
> audit to run at phase boundaries, before the next phase).

---

## 1. The build method (non-negotiable — Cluster 2 directive)

1. **Implementation order ≠ design chronology.** The design was *produced* ADR-0001→0023; the *build* is
   sequenced by **dependency + reuse + open-closed**. Build the most-depended-upon substrate first.
2. **Build every module ONCE, in its final form.** Never rework a component across phases; never
   schema-migrate a file twice (the Phase-2 migration writes the *complete final* `project.yml` in one
   pass because the Phase-0 parser already reads the final shape).
3. **Each phase leaves `cco` runnable + the test suite green.** The categorized teardown of the existing
   35-file suite (harness `helpers.sh`/`mocks.sh` migrates **first**, in P0) is in `design.md` §11 — it is
   what makes "green per phase" achievable. Write/port the phase's tests *with* the phase.
4. **Breaking cutover (AD12): no dual-read, no deprecation window.** Develop on `feat/*` → `develop`; only
   a working version reaches `main`. New layout only.
5. **Design & UX are frozen.** If implementation reveals a genuine design gap, **pause and discuss** —
   do not silently diverge (workflow rule). Otherwise follow the ADRs/design exactly.

## 2. Working agreement (project specifics)

- **Git** (project rule `.claude/rules/git-workflow.md`): branch from `develop`
  (`feat/<scope>/<description>`), atomic commits, merge to `develop`; `main` only for release. We are on
  `feat/vault/decentralized-config`. **Commits are local — the maintainer pushes from the Mac.**
- **Self-development caveat** (`/workspace/.claude/CLAUDE.md`): edits to `Dockerfile`, `config/entrypoint.sh`,
  `config/hooks/*` are **NOT active in the running session**. To test them: exit and `cco build && cco
  start` (or `docker build -t claude-orchestrator:latest .` from inside, with the awareness that it
  rebuilds the image the next `cco start` will use — the current container keeps the old image).
- **bash 3.2 / macOS `/bin/bash`** compatibility throughout: no `declare -A`; guard empty arrays under
  `set -u` (`${arr[@]+"${arr[@]}"}`); awk for parsing; no Homebrew-bash features. (`coding-conventions.md`.)
- **`cco` is one bash script** (`bin/cco`) sourcing `lib/*.sh`; no runtime deps beyond bash/docker/jq/sed/awk.
- **Doc lifecycle** (`.claude/rules/documentation-lifecycle.md`): design-intent docs are already current.
  **Shipped-behavior docs** (top-level `README.md`, user guides, `internal/tutorial/`, `concepts.md`/
  `knowledge-packs.md`, `spec.md`/`architecture.md` FRs, the docs index pages, the ~43-occurrence
  "Config Repo"→"sharing repo" sweep, the Section-D `_archive/` move) ride the **Phase-3 cutover sweep** —
  **never rewrite them ahead of the code**. The driver/checklist is **`resource-coherence-inventory.md`**.

## 3. The P0–P5 phase map (the spine — full detail in `design.md` §9, tests in §11)

Each phase consumes the one before it; nothing in an earlier phase is touched again.

- **P0 — Substrate** (foundations; everything reused, built once). The layer every later phase consumes.
  - **XDG 4-bucket resolver** `lib/paths.sh`: CONFIG `~/.cco` + DATA/STATE/CACHE (ADR-0007/0015);
    **host-side resolver guard H4** (refuse to compute bases in-container); **symlink-safe tool root L5**.
  - **Machine-agnostic `.cco/` layout + the STATE index** (logical names only; new-layout-only). The index
    **subsumes** `@local` + per-repo `local-paths.yml` (ADR-0016 D4) — delete that plumbing in
    `local-paths.sh` here. **Index atomicity (`mktemp`+`mv`, no lock) + global-flat (no namespacing) H7**
    (ADR-0022 D2).
  - **Full final `project.yml`/`pack.yml` schema + all `lib/yaml.sh` parsers** (F5): repos `name`+`url?`+
    `ref?`; llms `name`+`url`+`variant?`; **packs map** `name`+`url?`+`ref?`+`resource?`; **extra_mounts**
    `name`+`url?`+`ref?`+`target?`+`readonly` (ADR-0023 D5). *Build the pack-coordinate parser now* even
    though pack *behavior* lands in P4/P5.
  - **DATA/STATE registries, final form**: `tags.yml` (DATA); **remotes split** `<data>/cco/remotes`
    (name→url) + `<state>/cco/remotes-token` (0600) — **M3**, `cmd-remote.sh` rewritten once (5 callers
    consume the public helpers, unaffected — F6). *(The **`source` provenance → DATA + `publish_target`
    re-derivation (F4)** is **re-sequenced to P4**, not built here — confirmed Option B, 2026-06-19; its
    test surface is the sharing tests rewritten in P4–P5, and nothing in P0–P3 needs `source` in DATA.
    See `design.md` §9 P0 note / P4 and ADR-0022 D1 forward-annotation.)*
  - *(**Merge-engine artifact paths (H6)** — `.cco/base/` + `.cco/meta` → STATE `/update` — is
    **re-sequenced to P2**, not built here. Confirmed 2026-06-19. Its tests are hardcoded across P2
    (`test_update`) and P4–P5 (`test_publish_install_sync`); nothing in P0–P1 needs base/meta in STATE; the
    **P2 migration creates them** → relocate there in final form (build-once). The **global `.cco/meta` is
    a decompose**, not just a relocate (ADR-0013 D4) — global STATE home pinned `<state>/cco/global/update/`.
    See `design.md` §2.2 + §9 P2 + §11; ADR-0016 D6 forward-annotation.)*
  - **Compose generation, final mount map (BL3)**: per-mount bucket destinations; host-absolute mount
    sources; `GLOBAL_DIR`→`~/.cco` for **both `cco start` and `cco new`**. The **container side of
    `entrypoint.sh` is unchanged** — the compose↔entrypoint container-path contract is an invariant.
  - **Test-harness migration** (`tests/helpers.sh`, `tests/mocks.sh`) to the new model — **first**.
  - **Carried RD-claude-mount items** (ADR-0005 F1/F2/F3): generated `packs.md`/`workspace.yml`→CACHE `:ro`.
- **P1 — Core local commands** (consume the substrate): `lib/cmd-sync.sh` (4 command forms, diff+confirm,
  copy — no merge engine); **`cco resolve`/`cco path`** (index-backed, clone-from-`url`; `--scan` absorbs
  the retired `cco index refresh`, ADR-0017 D2); the **non-blocking reminder aggregator** (ADR-0008), all
  reminders **after** member resolution (H1). *`cco project add <res>` + `--path` and `cco project
  validate`/`coords` (ADR-0023 D1–D3) are built generically here on the P0 index/coordinate substrate; the
  pack resolution **backend** is added in P4/P5 (ADR-0022/F15 — generic loop from P1).*
- **P2 — Migration & bootstrap** (writes the complete final config once): **J0** first-run bootstrap of
  the 4 roots on any command (ADR-0017 D3); legacy-vault **backup** + instructions; **`cco init --migrate
  <project> [--sync]`** (lazy, per-project, from the backup) + `cco init`/`cco join`. Migration writes the
  **complete final `project.yml` in one pass** (repos+llms+**packs** coords; pack `url` backfilled only
  from the installed pack's recorded `source` read **in place** — `source`→DATA relocation is P4 — **never
  fabricated** — F37/P15). Create `migrations/pack/` + `migrations/template/` scope dirs. **Merge-engine
  artifact paths → STATE (H6, re-sequenced from P0)**: `.cco/base`/`meta` → `<state>/cco/{projects/<id>,
  packs/<name>,global}/update/`, helpers re-pointed, merge *logic* unchanged; **global `.cco/meta`
  decompose** (`languages`→`~/.cco`, markers→STATE top-level, `schema_version`/policies→global STATE update
  meta; ADR-0013 D4). **Memory relocation** (ADR-0009, non-clobber F11). **Profile→tag** CLI prompt
  (ADR-0010, lossless).
- **P3 — Legacy cutover** (the big breaking deletion, *after* migration exists): delete profile/switch/
  shadow machinery, `cco vault *`, `cco project create`, the sanitize/virtual-diff/extract-restore. Wire
  `cco tag add/rm` + `cco list --tag` over `<data>/cco/tags.yml`. Rehome the `config-editor` template to
  `~/.cco`; `cco config save/push/pull` + allowlist staging + whitelist `.gitignore`. Drop the vault
  memory auto-commit. **This is the shipped-behavior doc cutover sweep** (inventory-driven). GATE BL2
  satisfied (ADR-0009).
- **P4 — Sharing core** (behavior on the final substrate): **manifest removal = code/data split** (F14) —
  **discovery before delete**: build structure-based discovery (`git ls-tree packs/*/`,`templates/*/`),
  rewrite the manifest-gated call-sites, delete `lib/manifest.sh` + `cco manifest` **last**; new `cco
  init` never emits a manifest. **sync-before-publish fix** (the data-loss defect) — consolidated
  publish-path (§6.2 / ADR-0022 D5): pull + 3-way merge against the **pack-scoped STATE `base/`** (reusing
  the P2-relocated merge engine, H6), never clobber a co-maintainer (P16). **2×2 verb wiring**
  (publish/install + export/import; projects-don't-publish guard, P13). **Nomenclature migration**
  ("config repo"→"sharing repo"). **`source` provenance → DATA (re-sequenced here from P0; ADR-0022 D1)**:
  relocate `<repo|pack>/.cco/source` → `<data>/cco/{projects,packs,templates}/<id>/source`, rename
  `source:`→`url:` / `path:`→`resource:` (`ref:` kept), move `commit`/`version`→STATE `/update` meta,
  **drop `publish_target`** (re-derive via `remotes` reverse-lookup, F4); all read/write sites flip
  together with their tests + a relocation step migrates existing old-location `source`. llms `source`
  excluded (already CACHE/coordinate-split).
- **P5 — Sharing extensions & lifecycle**: **three-layer pack resolution** (one deterministic resolver
  from the §2.4 table, cache-iff-coordinate ADR-0022 D4); **internalize** (pack/template cut-url + `--as`
  fork — ADR-0023 D4) + internalize-as-cache prompt + `export --bundle-packs`; **`cco update --check`**
  (DATA-driven 3-state, ADR-0022 D6); **lifecycle** (`cco forget`, delete-cascade — ADR-0021);
  **`cco project validate`** (share-readiness, full contract ADR-0023 D2) **+ `cco config validate
  [--fix]`** (orphan prune, ADR-0021 §5); **`cco config protect`** = **docs only in v1** (helper deferred,
  ADR-0023 D6); **S8 no-token-leak checklist** (M3 from P0 satisfies it by construction).

## 4. Cross-cutting invariants (never violate)

- **4-bucket taxonomy** (ADR-0007/0015/0016): CONFIG `~/.cco` (authored, versioned) · DATA
  `~/.local/share/cco` (internal, synced) · STATE `~/.local/state/cco` (machine-local, never-sync) · CACHE
  `~/.local/cache/cco` (regenerable). Each datum's home is the **authoritative table** in ADR-0016.
- **Coordinate model** (ADR-0016 D2 / 0019 / 0022): coordinate (`name`+`url`) is **per-unit, embedded in
  the versioned manifest** (no central registry); the **index** maps `name→path` (STATE). **AD3/G8 — no
  real path ever enters committed config; `git diff` is always truthful.**
- **P14 reachability**: layered **embed-at-add → heal-at-resolve → `cco project validate` → opt-in hook →
  passive ⚠** — **never a hard block**. `cco project validate` is exit-code-only, never the git push path.
- **P15**: a shared resource's local copy is **never** its source; cache-vs-source discriminator = the
  coordinate's presence in the manifest entry (ADR-0022 D4 invariant + the §2.4 resolver table).
- **P17**: permissions **delegated to git**; cco assists, never gatekeeps.
- **Host-side resolver guard (H4)** and the **compose↔entrypoint container-path contract** are invariants.

## 5. Command surface target (ADR-0023 — the v1 CLI)

- `cco config save/push/pull` (`~/.cco`) · `cco config validate [--fix]` (**orphan-sanitization**, global)
  · `cco config protect` (**docs-only v1**).
- `cco project validate [--all] [--reachable]` (**share-readiness**) · `cco project coords --diff [--sync
  --from]` · `cco project add repo|mount|llms|pack <name> [--url --ref --variant --readonly] [--path]`
  (**embed-at-add** + one-shot path) · `cco project resolve` · `cco project export|import` · `cco project
  internalize [--as]` (pack/template cut-url; **project = Case-C, post-v1**).
- `cco start [--from]` · `cco new [--repo …]` (**index-less ephemeral**) · `cco sync` · `cco resolve
  [--scan]`/`cco path set|list` · `cco list [--tag]`/`cco tag add|rm` · `cco forget` · `cco init [--migrate]`/
  `cco join`.
- `cco pack|template publish|install|export|import` · `cco pack internalize` · `cco llms install|…` ·
  `cco remote …` · `cco update [--check|--diff|--dry-run|--news|--sync]`.

## 6. Explicitly DEFERRED — do NOT build in v1

`cco project internalize` (Case-C solo-adopter, reserved name) · the `cco config protect` **helper** (docs
only; contract pinned ADR-0023 D6) · **extra_mounts vendor/cache** (repo no-cache rule) · index
**per-project namespacing** (global-flat v1, ADR-0022 D2) · `--reachable` may stay minimal · **T**
state-sync (DATA/STATE cross-PC, R-state-sync) · local-file llms (F1) · Case-C convergence merge (F2) ·
`coords-lookup` persistence (on-demand only).

## 7. Reading order for the fresh implementation session

1. `guiding-principles.md` (**P1–P17**). 2. **This file.** 3. `design.md` **§2** (layout/buckets/schema),
   **§3** (index), **§9** (the P0–P5 phases — your build script), **§11** (test plan + existing-suite
   teardown). 4. The load-bearing ADRs: **0007/0015/0016** (buckets+taxonomy), **0017** (CLI lifecycle),
   **0019** (reachability + pack lifecycle), **0022** (coordinate model/resolution), **0023** (command
   surface), **0021** (migration/lifecycle), **0006/0009/0010** (backup/memory/tags). 5.
   `resource-coherence-inventory.md` (the P3 cutover-sweep driver). 6. The code: `bin/cco` dispatcher,
   `lib/paths.sh`, `lib/local-paths.sh`, `lib/yaml.sh`, `lib/cmd-*.sh`, `lib/update*.sh`, `lib/remote.sh`,
   `lib/cmd-start.sh`/`lib/cmd-new.sh`, `config/entrypoint.sh`.

## 8. Current position & how to start a phase

**Phase 0 (substrate) + Phase 1 (core local) are ✅ CLOSED** (`feat/vault/decentralized-config`, local).
P0: T1 resolver+H4+L5 · T2a index API · T3 coordinate parsers · T4-remotes M3 split · Commit A
(repos/mount → STATE index) · Commit B (session-mount bucket re-point + harness HOME flip) · T8 (`.claude`
overlays → CACHE `:ro`, ADR-0005 F1/F2/F3). P1: 6 commits `56ca45c`→`e48abdd` (cco resolve/path ·
sync-meta fingerprint · reminder aggregator · cco sync · cco start aggregator+H1 · cco project add), with
3 maintainer scope-forks (legacy resolve/validate/add-pack → P3; D-start source-selection → P2;
cco project validate → P5 / coords → P4-5). Suite **1043/16** delta-green. **Next = Phase 2** (migration &
bootstrap).

To start any phase: (1) run **`implementation-review-handoff.md`** (read-only adherence/gap audit) at the
phase boundary; (2) open that phase's **launch handoff** (`P2-handoff-migration-bootstrap.md` for Phase 2)
for the preliminary analysis + exact scope; (3) build on the substrate, keep the suite green (delta-based;
in P2 the FAIL set shrinks from 16 toward 8 as the owned update tests are rewritten), commit atomically. The live cursor is in `decentralized-config-impl-progress.md` + the roadmaps. Pause and discuss
if a real design gap surfaces; otherwise the ADRs/design are the spec.
