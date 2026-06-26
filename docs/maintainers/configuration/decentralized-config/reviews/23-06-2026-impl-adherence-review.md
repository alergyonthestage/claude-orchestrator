# P2 Adherence Audit — P2→P3 Boundary (2026-06-23)

**Type**: Recurring adherence/coherence audit, per `../implementation-review-handoff.md`.
**Read-only** — no production code written, no settled design re-opened. Run as the first step of
the Phase-3 session (a fresh session, more independent than the one that wrote P2).

**Scope**: the 5 Phase-2 commits `c1e0369`→`767de86` (J0 bootstrap + raw-tar backup; H6 base/meta →
STATE + global-meta decompose; eager global migration via `cco update`; `cco init --migrate` lazy +
`cco join`; D5 observability) and their tests. Spec side: `guiding-principles.md` P1–P18, ADRs
0006/0009/0010/0013/0016/0017/0021/0022/0024/0025, `design.md` §2.2/§3/§9 P2/§11 row 2.

**Method**: 4 parallel read-only lenses (multi-modal sweep, each blind to the others) →
adversarial verify → dedup → severity-rank → 4-state classify. Lenses: (1) bucket-taxonomy +
coordinate/index, (2) phase completeness vs §9/§11, (3) invariants + Transitional Registry +
masked-assertion, (4) P3 readiness + doc coherence. Every claim re-grounded against `file:line`.

```mermaid
flowchart LR
  P0["✅ P0 substrate"]
  P1["✅ P1 core local"]
  P2["✅ P2 migration & bootstrap — AUDITED, conformant"]
  P3["▶ P3 legacy cutover"]
  P0 --> P1 --> P2 --> P3
```

## Verdict

**P2 is fully conformant — 0 🔴 code errors, 0 blockers, 0 genuine HITL flags. Ready to launch
Phase 3.**

The 5 commits drive the suite **1043 → 1087 passed (+44 new tests)** while shrinking the FAIL set
**16 → 8 exactly as designed** (the 8 owned `test_update_*`/`test_merge`/`migration_005` flipped
❌→✅ at P2-2). Baseline confirmed: `CCO_ALLOW_HOST_RESOLVE=1 ./bin/test` → **1087 passed / 8
failed**, the 8 matching the §4 registry baseline **exactly** (5 P3 + 3 P4–5). No 9th red — no
regression. The Transitional Registry needs **one update**: **T5 (base/meta) retires this phase**.

## Baseline reconciliation (a methodology note worth recording)

The documented invocation `CCO_ALLOW_HOST_RESOLVE=1 ./bin/test` yields **1087/8**. Running the suite
**without** the host-resolve hatch yields **1084/11–12** — 3–4 extra reds:
`test_paths_project_meta_{default_new,new_path,old_fallback}` + `test_update_no_backup_skips_bak`.
These are pure unit tests that call the path resolvers directly (`_cco_state_dir`/`_cco_project_meta`),
which the **H4 host-side resolver guard** correctly refuses outside a container unless the hatch is set.
With the hatch (the standard invocation used by every prior review and both handoffs) they **pass**.
The "+3 failures / 5 test bugs" surfaced by one lens was therefore a **false alarm from a wrong test
invocation** — adversarially reproduced and rejected (see "Rejected findings"). **Authoritative
baseline = 1087/8, exact registry match.**

## Findings (✅ conformant · 🟡 sanctioned hybrid)

Line numbers drift — re-read before relying.

| # | Area | Location | Class |
|---|------|----------|-------|
| F1 | **J0 four-root bootstrap** on any command, per-root idempotent (M6), host-side guard | `migrate.sh:33-52`, `bin/cco:158` | ✅ |
| F2 | **Legacy-vault backup** — raw tar incl. `.git`+profile-shadows, F44 atomic-staged, M8 verify-before-read, 0600, F43 marker→STATE `backups/` | `migrate.sh:59-143` | ✅ |
| F3 | **H6 — base/meta → STATE keyed by identity**; `_cco_project_id` = `project.yml` `name:` (basename fallback) | `paths.sh:86-96,100-116,144-150` | ✅ |
| F4 | **Merge LOGIC unchanged** — `update-merge.sh` untouched in P2 (`git log c1e0369^..HEAD` empty); path-agnostic (base/meta passed as args) | `update-merge.sh` (no P2 commit) | ✅ |
| F5 | **Pack merge helpers created** for build-once (`<state>/cco/packs/<name>/update/{meta,base}`); writers flip in P4 | `paths.sh:144-150` | ✅ |
| F6 | **Global `.cco/meta` decompose** — `languages`→`~/.cco`, `last_seen`/`last_read`→STATE top-level, `schema_version`/policies/flags→global STATE meta | `paths.sh:63-73`, `update-meta.sh:14-39,59-112` | ✅ |
| F7 | **Hash `manifest:` block KEPT** (travels whole into STATE meta, ADR-0013 D3/0025) — only the separate `manifest.yml` is removed | `update-meta.sh:97-101` | ✅ |
| F8 | **Migration ownership split** — global EAGER via `cco update`; per-project LAZY via `cco init --migrate`; **no `cco migrate` verb** | `cmd-update.sh:125-130`, `cmd-init.sh:49-54`, `bin/cco` dispatcher | ✅ |
| F9 | **Complete final `project.yml` in ONE pass** (repos+llms+packs coords); real paths → STATE index only, not `project.yml` (AD3/G8) | `migrate.sh:397-465,547-549` | ✅ |
| F10 | **Pack `url` backfilled from `.cco/source` read IN PLACE; absent→authored; never fabricate** (P15/F37) | `migrate.sh:426-427,452-458` | ✅ |
| F11 | **Memory relocation** backup→`<state>/cco/projects/<id>/memory/`, non-clobber `cp -rn` (F11/ADR-0009) | `migrate.sh:522-527` | ✅ |
| F12 | **Profile→tag** — atomic shared seed (global) + per-project prompt → `<data>/cco/tags.yml` typed keys | `migrate.sh:171-195,235-262,541-554` | ✅ |
| F13 | **Name-uniqueness assert** (F12) + index-register last + F44 atomic-staged per-project migrate | `migrate.sh:484-489,537` | ✅ |
| F14 | **Migration scope dirs** `migrations/pack/` + `migrations/template/` created (F37); `packs:` list→map = project-scope migration | `migrations/{pack,template}/.gitkeep`, `migrations/project/013_packs_list_to_map.sh` | ✅ |
| F15 | **D5 observability** — `_index_repos_get_projects` reverse helper; `cco project show` member roles + referenced-by + repo-centric view + passive ⚠ | `index.sh:202-210`, `cmd-project-query.sh:45-81,138-154` | ✅ |
| F16 | **D-start RE-SEQUENCED to P3** — `cco start` still mounts the CENTRAL layout (`_start_generate_compose` emits `${project_dir}/.claude`+`project.yml`, `project_dir=$PROJECTS_DIR/$project`); decentralized read-path is P3's cutover | `cmd-start.sh:516-517`, design §9 P3 | 🟡 |
| F17 | **Remotes split (M3)** — registry `<data>/cco/remotes` + token `<state>/cco/remotes-token` (0600) | `paths.sh:44-52` | ✅ |
| F18 | **Index** in STATE, `mktemp`+`mv` atomic, no lock, global-flat; members space-separated (§3; comma→space fix in `767de86`) | `index.sh:32-34,77-134` | ✅ |
| F19 | **Invariants** — H1 (reminders after resolution), H4 (host-side guard), compose↔entrypoint contract (`entrypoint.sh` untouched in P2), build-once | `cmd-start.sh:195-229`, `paths.sh:175-193`, `config/entrypoint.sh` | ✅ |
| F20 | **Still-live hybrids** (Commit A `@local`/schema-bridge; Commit B dual-seed/`CCO_*_DIR`/vault-git; T4-source `.cco/source` in place→P4; T4-tags seeded-not-wired→P3; legacy `cco vault`/`project create`/`manifest`/profile machinery) — all present, retiring phase ahead | `local-paths.sh`, `tests/helpers.sh`, `paths.sh:137-139`, `cmd-vault.sh`, `manifest.sh` | 🟡 |
| F21 | Baseline 1087/8; the 8 FAIL match §4 registry exactly (5 P3 + 3 P4–5); no 9th | live run | ✅ |

## Rejected findings (adversarially verified false alarms — do NOT action)

| Claimed | Why rejected |
|---|---|
| "3 test_paths.sh tests are bugs (missing `CCO_ALLOW_HOST_RESOLVE=1`)" | They **pass** under the documented invocation `CCO_ALLOW_HOST_RESOLVE=1 ./bin/test`. The runner is always invoked with the hatch; the H4 guard refusing direct resolver calls without it is **by design**, not a bug. Reproduced both ways. |
| "test_project_internalize_updates_base / test_publish_ignore_path_patterns are new base-path test bugs" | Both are **known §4 registry baseline failures** (the 3 P4–5 sharing-rewrite set). They are in the sanctioned 8 and get rewritten when sharing is rebuilt in P4–P5. Not new, not P2 regressions. |
| "Suite is 1084/11 — drift from the 1087/8 record" | Artifact of running without the hatch (above). Authoritative run = **1087/8**. |
| "test_vault_switch_to_main_shared_only / test_resolve_name_from_full_variant_url are bugs to fix now" | Both are **known §4 baseline failures** (P3 / P4–5). Removed/rewritten in their phase. |

## Transitional Registry — refresh

**RETIRE this phase (landed in P2 — move OUT of the registry):**

- **T5 — merge-engine base/meta → STATE (H6).** ✅ **Done.** `_cco_{global,project,pack}_{meta,base_dir}`
  resolve to `<state>/cco/.../update/{meta,base}`; global `.cco/meta` decomposed; merge logic
  (`update-merge.sh`) untouched. **No production code writes base/meta to the old `.cco/` location.**
  Residual `.cco/meta`/`.cco/source` *reads* remain only inside legacy machinery that is itself
  separately registered (legacy vault → P3; pack source/provenance → P4) — correctly 🟡, not 🔴.

**KEEP (retiring phase still ahead — unchanged):**

- **Commit A** — `@local`/sanitize/extract/restore + `local-paths.yml` plumbing; per-section schema
  bridge (`_effective_repo_mounts`/`_effective_extra_mounts`). Dies **P3/P4**.
- **Commit B** — dual-seed harness (`setup_global_from_defaults` → legacy `GLOBAL_DIR` **and**
  `~/.cco/global`); legacy `CCO_*_DIR` kept; `check_global` not re-pointed; vault-git mirror. Dies **P3/P4**.
- **T4-source → P4** — `source` provenance stays at `<repo|pack>/.cco/source`, read in place
  (`_cco_pack_source` dual-read, `paths.sh:137-139`); →DATA relocation + `url`/`ref`/`resource` rename +
  `publish_target` re-derivation lands P4.
- **T4-tags → P3** — `<data>/cco/tags.yml` seeded at migration; `cco tag add/rm` + `cco list --tag`
  consumers not built yet (P3).
- **Legacy commands still live** — `cco vault *`, `cco project create`, `cco manifest`, the legacy
  `cco project resolve`/`validate <name>`/`add-pack`/`remove-pack`, profile/switch/shadow. Cut at **P3/P4**.
- **Known baseline failures — 8** (was 16; the 8 owned update/merge/migration tests flipped ❌→✅ at
  P2-2): **P3 (5)** `test_vault_switch_to_main_shared_only`, `test_profile_show_active_profile`,
  `test_vault_move_preserves_unaccounted_files`, `test_vault_push_with_profile_syncs_shared`,
  `test_profile_create_preserves_unaccounted_files`; **P4–P5 (3)** `test_resolve_name_from_full_variant_url`,
  `test_publish_ignore_path_patterns`, `test_project_internalize_updates_base`. Each ❌→✅ (or removed) when
  its phase lands. **New baseline = 1087/8** (delta-green measured against these 8).

## Doc coherence

- **Living design / ADRs match the code.** `design.md` §2.2/§9 P2 and ADR-0024/0025 describe what P2
  built (migration ownership split, base/meta→STATE keyed by `name`, hash `manifest:` kept, decompose,
  D5, D-start re-seq→P3). The P2-handoff §P2-5 OUTCOME note (D5 ships, D-start→P3) matches design §9 P3. ✅
- **Shipped-behavior docs NOT rewritten ahead of code** (doc-lifecycle rule). Spot-checked
  `docs/user-guides/`, top-level `README.md`, `CLAUDE.md`: no premature "sharing repo" / `~/.cco` /
  `cco config save` / `cco tag` / decentralized-start terms. They still describe the current
  (pre-cutover) shipped behavior. ✅ These ride the **P3 cutover sweep**, inventory-driven.
- **`resource-coherence-inventory.md`** remains accurate as the P3 cutover driver — its deletion list
  matches the P3 readiness inventory below. ✅
- **Nit (optional, no action)** — comment drift: several `lib/update-*.sh` comments still name
  `.cco/base`/`.cco/meta` when describing what are now STATE paths (the merge engine is path-agnostic —
  behavior unaffected). Could be swept opportunistically in P2-touched files; not required.

## Phase-3 readiness — deletion / rewire inventory

P3 prerequisites are in place: **the migration exists** (eager global via `cco update` + lazy
`cco init --migrate`), the **backup is universal + verified** (M8), so the breaking deletion is safe.
Concrete P3 surface (code-grounded; line numbers drift):

- **`cco start` → decentralized read-path (D-start, re-seq from P2-5).** Replace central mounts
  (`cmd-start.sh:516-517` `${project_dir}/.claude`+`project.yml`, `_start_resolve_project`
  `project_dir=$PROJECTS_DIR/$project`) with cwd-first → hosted `<repo>/.cco/`; add `--from`
  precedence, F49 unresolved prompt, divergence notice + source-transparency line (design §4.4).
- **Delete `cco vault *`** — `lib/cmd-vault.sh` (init/save/diff/log/restore/status + profile
  create/list/show/switch/rename/delete/add/remove/move); remove the `vault)` case in `bin/cco`.
- **Delete profile/switch/shadow machinery** + any `_cco_profile_*` in `paths.sh`; drop the vault memory
  auto-commit (`_auto_resolve_framework_changes`, D33) and `.gitkeep` tracking (D32).
- **Delete `cco project create`** (`lib/cmd-project-create.sh`) — entry is now `cco init`/`join`/`--migrate`.
- **Delete the superseded legacy `cco project resolve`/`validate <name>`/`add-pack`/`remove-pack`**
  (`cmd-project-query.sh`, `cmd-project-pack-ops.sh`) — replaced by index-backed `cco resolve`/`cco path`
  + generic `cco project add`. Update the `cco project resolve` pointers in `local-paths.sh` error
  messages (~`:903,943,1014,1359`).
- **Delete the `@local` sanitize/extract/restore/virtual-diff block** in `local-paths.sh`; keep the
  index-backed resolve/assert helpers.
- **Wire `cco tag add/rm` + `cco list --tag`** over `<data>/cco/tags.yml`; **wire `cco config
  save/push/pull`** + allowlist staging + whitelist `.gitignore` (+ `.example` exemption).
- **Rehome the `config-editor` template** to mount `~/.cco`; update its `setup-pack`/`setup-project`
  skills + `config-safety` rule (`cco vault save`→`cco config save`).
- **Shipped-behavior doc cutover sweep** (inventory-driven): README, user guides, tutorial,
  concepts/knowledge-packs, spec/architecture FRs, index pages, the "Config Repo"→"sharing repo"
  sweep, the Section-D `_archive/` move, **and the managed `defaults/managed/.claude/rules/memory-policy.md`
  + `docs/reference/context-hierarchy.md`** ("vault-synced" → "machine-local STATE; cross-PC = future
  opt-in"). Managed-rule change requires a `cco build` to take effect (self-development caveat).

## HITL flags

**None blocking.** Two items surfaced by the lenses, both resolved within spec — recorded for awareness:

1. **`memory-policy.md` "vault-synced" wording** (flagged HIGH by a lens). **Not a finding.** Per
   doc-lifecycle it is **shipped-behavior** describing what is still true pre-cutover (the vault and its
   auto-commit are live until P3). design §9 P3 **already** lists updating this exact file in the cutover
   sweep. Correctly deferred → 🟡.
2. **"Should the test failures be fixed before P3?"** (raised by a lens). **Moot** — there are no real
   test bugs (the apparent ones were the wrong-invocation artifact; see Rejected findings). The 8 are the
   sanctioned baseline that retire in P3/P4–P5. Nothing to fix.

## Loop closure (playbook §7)

- **Gap report**: this file.
- **Transitional Registry (§4)**: **T5 retires** (base/meta → STATE landed); the 16→8 baseline
  re-statement; all other hybrids unchanged, retiring phases ahead. → apply to
  `implementation-review-handoff.md` §4.
- **Roadmap/memory**: P2→P3 boundary cleared; **next = Phase 3 (legacy cutover)**; baseline 1087/8.
- **Next-phase handoff**: the deletion/rewire inventory above feeds the P3 launch handoff.
- **No 🔴 to schedule; no HITL to resolve.**
