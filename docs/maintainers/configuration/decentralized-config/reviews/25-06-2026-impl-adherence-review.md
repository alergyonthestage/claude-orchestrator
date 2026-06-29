# Implementation-Adherence Review — decentralized-config v1 (pre-merge, whole-scope)

**Date**: 2026-06-25
**Scope**: the entire `decentralized-config` surface (design §2–§12, ADRs 0005–0027,
`guiding-principles.md` P1–P18) verified against the written code on branch
`feat/vault/decentralized-config` (build complete, phases P0–P5 all closed).
**Baseline**: `CCO_ALLOW_HOST_RESOLVE=1 ./bin/test` → **894 passed / 0 failed** (re-run for this
review; matches the §4 handoff baseline).
**Method**: 9 parallel review lenses (bucket-taxonomy · coordinate/index · phase-completeness ·
invariants · transitional-vs-error · test-contracts · doc-coherence · cutover/merge-safety ·
optimization-duplication) → adversarial verification (5 findings refuted) → completeness critic →
this synthesis. Every surviving claim was re-grounded by opening the cited files for this write-up.
**Source of truth precedence**: `guiding-principles.md` → ADRs 0005–0027 → `design.md` →
`requirements.md`. The §4 LIVE transitional set is **empty** at build-complete, so any remaining
hybrid/legacy/dual-read is 🔴 (a missed cleanup), except the KEEP-forever migrate-from-BACKUP
readers and the one already-logged `browser-mcp/design.md` doc gap.

---

## Top-line verdict

**Not yet merge-ready — one HIGH conformance divergence must be resolved (or explicitly
deferred-with-an-ADR) first.** The implementation is otherwise exemplary: the 4-bucket decentralized
model, the coordinate/index separation (AD3/G8 truthful diff), the P0–P5 phase deliverables, the
migration-safety machinery, and the removed-verb guards are all built in final form and
code-grounded conformant, with the suite green per phase.

The single blocking-class issue is **F1**: the personal flat store (`packs/`, `templates/`,
**`llms/`**) is still resolved out of the pre-refactor `$CCO_USER_CONFIG_DIR` flat root (default
`$REPO_ROOT/user-config`), **not** out of its decentralized-config homes — `~/.cco/{packs,templates}`
(CONFIG, design §2.3 / ADR-0016 D8) and **CACHE** for llms content + cache-state (design §2.2 line
201 / ADR-0016 D2/D7). For llms this is an unambiguous divergence (the design is explicit and a code
comment falsely asserts it is "already CACHE-split"). For packs/templates it is the same root not
being relocated. This needs a maintainer decision (real cleanup vs sanctioned dev-fallback indirection)
— hence **HITL**.

### Counts by four-state (deduped, this review)

| State | Count |
|---|---|
| ✅ implemented-conformant (representative, load-bearing) | 7 emitted (≈60 verified across lenses) |
| ❌ missing | 1 |
| 🟡 hybrid-intentional | 0 (LIVE set empty — correct) |
| 🔴 hybrid-divergent-error | 4 |

### Counts by severity (conformance findings only; optimization flags listed separately)

| Severity | Count |
|---|---|
| blocker | 0 |
| high | 1 (F1) |
| medium | 4 (F2 missing-test, F3 doc inconsistency, F4 pack-discriminator test gap, F5 test-isolation pollution) |
| nit | the representative ✅ set |

> **Maintainer-finalized (2026-06-25).** This synthesis was reviewed by the lead session after the
> workflow run: the baseline was re-confirmed 894/0; F1 was independently re-grounded (corroborating
> evidence added below — it tilts the intent question toward "missed cutover"); and **F5 (test-isolation
> pollution) was added** — discovered when the parallel lens agents' concurrent `./bin/test` runs
> corrupted tracked repo files (`changelog.yml`, the base-template `CLAUDE.md`), which the lead restored.

**Optimization flags (lens 9, flag-only, NOT for this review to fix): 13.**

---

## Per-lens conformance summary

- **Bucket-taxonomy** — XDG resolver (`lib/paths.sh`), the H4 anti-in-container guard, tags→DATA,
  remotes split (url→DATA / token→STATE, 0600), index→STATE, generated `.cco/managed`→CACHE, and
  memory→STATE are all conformant and code-grounded. **One HIGH divergence**: the personal flat store
  (packs/templates/llms) is not relocated to `~/.cco`/CACHE (F1). The lens originally scoped F1 to llms
  only; re-grounding shows the same `$CCO_USER_CONFIG_DIR` root governs packs and templates too.

- **Coordinate model & index** — Fully conformant. `project.yml`/`pack.yml` carry logical names +
  machine-agnostic coordinates only (no real paths; AD3/G8); the STATE index maps name→path with
  atomic `mktemp`+`mv`, no lock, global-flat (H7/ADR-0022 D2); final-form parsers
  (`yml_get_{repo,mount,pack}_coords`, `yml_get_llms`); legacy parsers removed; the P15
  coordinate-presence discriminator + cache-iff-coordinate (D4) + non-destructive `--scan` upsert (D3)
  + AD5 keep-existing are all in place. Zero coordinate leak into the index.

- **Phase completeness vs §9** — All P0–P5 deliverables built in final form (substrate · core-local ·
  migration · legacy cutover · sharing core · sharing extensions). 2×2 verbs (pack/template
  publish/install/export/import) + projects-no-publish guard; structure-based discovery (no
  `manifest.yml`); source→DATA + publish_target re-derive; 3-layer pack resolution; internalize +
  `export --bundle-packs`; `update --check` 3-state; `project validate`/`coords`; `config validate`;
  `forget`; delete-cascade. No double schema-migration; schema_version stays 14, no new P5 migration.

- **Invariants** — H1 (resolution before notices), H4 (host-side resolver guard), H6/H7 (merge
  artifacts in STATE, atomic index), the compose↔entrypoint fixed-container-path contract, P14
  (reachability layered, never hard-block), P15 (local copy never source; discriminator = coordinate),
  and P17 (permissions delegated to git; `config protect` is docs-only) are all implemented-conformant.

- **Transitional vs error** — Whole-codebase sweep: the LIVE transitional set is correctly empty. The
  KEEP-forever readers (`_local_paths_get`/`_local_paths_get_section`/`_project_effective_paths`/
  `_resolve_entry_index`/`_prompt_for_path`) are isolated to migrate-from-BACKUP paths. Removed verbs
  (vault, manifest, project create/publish/install/update/internalize, tier-2 verbs) all give explicit
  AD12 "was removed" rejections at dispatch with ADR citations. Central-layout enums
  (`$PROJECTS_DIR`/`$CCO_PROJECTS_DIR`) are gone. (Note: the `$CCO_USER_CONFIG_DIR` flat root is a
  *different* legacy persistence — covered by F1.)

- **Test-contract adherence** — 894/0 green and stable; the §11 per-phase rows are honored; the
  `bin/test` `ASSERTION FAILED` sentinel and the `|| return 1` multi-assert guards are present;
  removed-feature test files (`test_vault_profiles.sh`, `test_project_create.sh`, `test_manifest.sh`)
  are gone. Two *confirmatory* coverage gaps surfaced (F2 H1-ordering, F4 pack-discriminator) — the
  behavior is correct in code but not pinned by an explicit test that would fail if the contract broke.
  **One test-isolation defect (F5)**: a few tests mutate tracked repo files in place (`changelog.yml`,
  the base template), which corrupts the working tree under concurrent or interrupted runs — so the
  "stable 894/0" holds only for a single sequential run.

- **Doc coherence** — Living docs (design.md, requirements.md, ADRs) are coherent and
  forward-annotated; shipped-behavior docs correctly document removed verbs. **One MEDIUM
  inconsistency**: `configuration-management.md` shows `cco template update` as a working example while
  the same file's reference table marks it 🚧 planned (F3). The `browser-mcp/design.md` pre-refactor
  prose is the already-logged, separately-tracked doc gap (not a new finding).

- **Cutover / merge safety** — No half-migrated paths. J0 four-root bootstrap is per-root idempotent;
  M8 backup-verified-before-read; F44 atomic-staged migration write (mktemp → stage → secret-scan →
  atomic mv → index-register-last); ADR-0026 migration-state marker gates fresh-init vs silent
  vault-skip; F12 name-uniqueness guard; F11 non-clobber memory relocation; delete-cascade; changelog
  entry #15 lists all 9 P5 verbs. Merge-readiness gated only on F1.

- **Optimization & duplication** — 13 non-blocking flags (DRY tab-peel idiom across
  resolve/validate/coords, index-enumeration loop repeated ~13×, two 3-way mergers sharing a decision
  tree, mixed-responsibility `_pv_validate_unit`, the 324-line `cmd_update`, a single-use
  `_pack_merge_put`, duplicated secret-scan, coordinate-rules-not-data-driven). All feed the dedicated
  refactoring review; none are 🔴.

---

## Findings (grouped by severity, then lens)

### 🔴 F1 — HIGH — Personal flat store (packs/templates/**llms**) not relocated to `~/.cco`/CACHE

- **Lenses**: bucket-taxonomy (raised, llms-scoped) + (re-grounded here to packs/templates).
- **Location**:
  - `bin/cco:32` `USER_CONFIG_DIR="${CCO_USER_CONFIG_DIR:-$REPO_ROOT/user-config}"`
  - `bin/cco:38-40` `PACKS_DIR/$USER_CONFIG_DIR/packs`, `LLMS_DIR=$USER_CONFIG_DIR/llms`,
    `TEMPLATES_DIR=$USER_CONFIG_DIR/templates`
  - `lib/cmd-llms.sh:110` `target_dir="$LLMS_DIR/$name"` (content) + `lib/cmd-llms.sh:717`
    `_llms_write_source` writes `$LLMS_DIR/$name/.cco/source` (cache-state: url/variant/downloaded
    timestamp/resolved_url/etag)
  - `lib/packs.sh:22-29` `_pack_resolve_dir` reads `$PACKS_DIR/$name` (its own comment, lines 12-13,
    claims layer 1 is `~/.cco/packs/<name>`)
  - `lib/paths.sh:154` comment: *"llms `source` is NOT relocated (already CACHE-split, ADR-0016 D2/D7)"*
    — this assertion is **false** in the code.
- **Observed**: All three personal stores resolve under one pre-refactor flat root
  (`$CCO_USER_CONFIG_DIR`, default `$REPO_ROOT/user-config`), established by the v0 migration
  `migrations/global/003_user-config-dir.sh` ("Run 'cco vault init'"). No code path resolves
  `~/.cco/packs`, `~/.cco/templates`, or `<cache>/cco/llms` (zero hits for
  `_cco_config_dir.*pack|llms|templates`). The test harness pins the same flat root
  (`tests/helpers.sh:33,38-40`).
- **Corroborating evidence (lead session, re-grounded)**: `$CCO_USER_CONFIG_DIR` is *also* used as the
  **legacy-vault pointer** by the migrator — `lib/migrate.sh:103` `local vault="$USER_CONFIG_DIR"`,
  `:344` *"Legacy vault preserved as a fallback at $USER_CONFIG_DIR"*, `:346` `rm -rf $USER_CONFIG_DIR`.
  So `$CCO_USER_CONFIG_DIR` **cannot** be repointed to `~/.cco` in production (that would make
  `cco update` treat the new personal store as the legacy vault and instruct `rm -rf ~/.cco`). This means
  the packs/templates/llms rooting at `$USER_CONFIG_DIR` is a **genuinely incomplete cutover**, not an
  "export the var in production" indirection — it tilts the HITL-1 intent question toward *missed cleanup*
  (Option 1) over *sanctioned indirection* (Option 2). A second remnant of the same conflation:
  `lib/update.sh:143-146` still re-points `GLOBAL_DIR`/`PACKS_DIR`/`TEMPLATES_DIR` to
  `$USER_CONFIG_DIR/{global,packs,templates}` (the central layout) under a migration-003 fallback guard.
- **Expected**:
  - **packs/templates → `~/.cco/{packs,templates}`** (CONFIG): design §2.3 layout (lines 233-234);
    ADR-0016 D8; design §9 P3 line 950 *"rehome the config-editor template to mount `~/.cco` (was
    `user-config/`)"*; the resolver table (design §2.4 lines 356-365) is written against `~/.cco/packs`.
  - **llms content + cache-state → CACHE**: design §2.2 line 201 explicitly lists
    `<cache>/cco/llms/<name>/   # llms CONTENT download + cache-state (etag, resolved_url, downloaded)`;
    ADR-0016 D2/D7; the §2.3 "Moved OUT" note (line 245) — *"llms **content** → **CACHE** (C2)"*.
- **Why it matters**: P6 (hide internal/regenerable files) + G8 (truthful `git diff`). llms content
  and machine-specific cache-state (an HTTP etag, a download timestamp) are regenerable internal data;
  placing them in a non-CACHE, non-bucketed root means they are neither managed as cache (re-fetchable,
  never-sync) nor as CONFIG (authored, versioned). The host CLI and the config-editor session disagree
  on where the personal store lives — the config-editor mounts the real CONFIG bucket
  (`cmd-start.sh:67,71` `cco-config → _cco_config_dir`), so a pack authored inside the editor lands in
  `~/.cco/packs` but is invisible to the host `cco pack`/`_pack_resolve_dir` which look in
  `user-config/packs`. That is a concrete split-brain at merge.
- **Classification**: 🔴 hybrid-divergent-error (a missed relocation; the LIVE transitional set is
  empty so the pre-refactor `user-config/` layout has no sanctioned future-retiring phase). The
  llms→CACHE half is the clearest sub-claim; the packs/templates→`~/.cco` half is the same root.
- **Adversarial-verify verdict**: **confirmed (mechanism), broadened (scope), HITL-on-intent.** The
  original lens-1 finding (llms→CONFIG) was confirmed in mechanism but mis-stated the destination as
  the CONFIG bucket `~/.cco`; the real destination is `$CCO_USER_CONFIG_DIR` (a third root). The same
  root governs packs/templates, which other lenses called conformant — that inconsistency is resolved
  here in favor of "all three diverge from their design homes." The *intent* (genuine cleanup vs a
  sanctioned dev-only indirection where production is expected to export `CCO_USER_CONFIG_DIR`) is not
  derivable from the code: no README/installer/Dockerfile/profile sets it to `~/.cco`, and the progress
  note schedules no such relocation in P0–P5. → **HITL (see H1 below).**
- **Proposed resolution**: Maintainer decides (HITL). If "real cleanup": point `LLMS_DIR` content to
  `$(_cco_cache_dir)/llms` and the cache-state sidecar into CACHE (delete the `.cco/source` write in
  CONFIG); point `PACKS_DIR`/`TEMPLATES_DIR` (and `_pack_resolve_dir` layer 1) to `_cco_config_dir`
  (`~/.cco/{packs,templates}`); add a one-time relocation in `lib/migrate.sh` (user-config/* →
  `~/.cco`/CACHE); fix the false comment at `paths.sh:154`; align `tests/helpers.sh`. If "sanctioned
  dev-fallback": record an ADR/design note making `$CCO_USER_CONFIG_DIR`→`~/.cco`/CACHE mapping the
  production contract, document it in the install path, and correct the design §2.3/§2.2 prose + the
  `paths.sh:154` comment so the code and the explicit "content → CACHE" design statement no longer
  contradict.

### 🔴 F3 — MEDIUM — `cco template update` documented as both shipped and 🚧 planned

- **Lens**: doc-coherence.
- **Location**: `docs/user-guides/configuration-management.md:346` (working code example, no marker) vs
  `docs/user-guides/configuration-management.md:576` (reference table: *"🚧 planned, ships in a later
  release"*). Code: `lib/cmd-template.sh` has no `update)` case; `lib/cmd-pack.sh` implements
  `cmd_pack_update`.
- **Observed**: §7.3's bash block shows `cco template update acme-service` alongside the implemented
  `cco pack update` lines, implying it works; the table 230 lines later marks it deferred.
- **Expected**: shipped-behavior docs must describe what the code actually does (doc-lifecycle rule);
  `cco template update` is deferred post-v1 (ADR-0023 D4 / design §12).
- **Why it matters**: a dogfooding user runs the example and hits "unknown template command". Low risk,
  but a coherence defect that should not ship.
- **Classification**: 🔴 hybrid-divergent-error (doc ahead of code in one spot, correct in another).
- **Adversarial-verify verdict**: **confirmed** — line 346 present without a marker; line 576 marks it
  planned; no `update)` case in `cmd-template.sh`.
- **Proposed resolution**: remove `cco template update acme-service` from the §7.3 example (leaving the
  implemented `cco pack update` lines), or move it under a "Planned" subhead with a 🚧 marker matching
  the table. Recommend removal.

### 🔴 F4 — MEDIUM — Pack coordinate-presence discriminator (P15) not pinned by an explicit test

- **Lens**: test-contracts (raised), coordinate-index (P15 confirmed in code).
- **Location**: behavior in `lib/cmd-project-validate.sh:199-206` (no-url ⇒ authored) +
  `lib/packs.sh:22-29` (mount order); gap in `tests/test_pack_resolution.sh` (four resolution tests,
  none assert the cache-vs-authored *discriminator* principle) + `tests/test_project_validate.sh:179-219`
  (two pack-collision tests, but not the full §2.4 discriminator table).
- **Observed**: the P15 discriminator (coordinate present ⇒ cache; absent ⇒ authored source) and the
  design §2.4 resolver table (incl. the bold ERROR collision row) are implemented but not covered by a
  test that would fail if a future change treated a url-bearing pack as a source.
- **Expected**: design §11 P5 row contracts the 3-layer resolution incl. ERROR-on-collision /
  WARN-on-reachability; the discriminator is the load-bearing P15 invariant.
- **Why it matters**: delta-green could mask a regression of the discriminator (a silent-wrong-build
  risk) since no test asserts it directly.
- **Classification**: 🔴 hybrid-divergent-error (missing test contract for a load-bearing invariant;
  the *code* is conformant, the *contract coverage* is not). Note the original lens called this
  hybrid-divergent-error and the adversarial pass *adjusted* (confirmed the code is correct, the gap is
  test-only) — retained as a MEDIUM coverage 🔴, not a code bug.
- **Adversarial-verify verdict**: **adjusted (high confidence)** — code conformant; explicit
  discriminator test absent.
- **Proposed resolution** (pre-merge or first hardening pass): add `test_pack_resolution.sh` cases
  `test_pack_with_coordinate_is_cache_not_source` and
  `test_pack_without_coordinate_is_authored_source`, plus a row-by-row check of the §2.4 table incl. the
  ERROR collision. **HITL** (test scope is a maintainer call — pre-merge vs hardening backlog).

### ❌ F2 — MEDIUM (missing) — No explicit test for the H1 ordering invariant (resolution before notices)

- **Lens**: test-contracts (with invariants confirming the code is correct).
- **Location**: code correct at `lib/cmd-start.sh:1116-1131` + documented at `:519-525`; no test —
  `tests/test_start_reminders.sh` uses only `assert_output_contains` (substring, lines 48/76), and the
  only line-ordering (`grep -n`) tests are mount-order in `tests/test_start_dry_run.sh` (not H1).
- **Observed**: H1 (any divergence/reminder is computed AFTER member resolution, never against an
  unresolved/empty index) is enforced by execution order + the reminder signature, but no test would
  fail if a future refactor reversed the order.
- **Expected**: design §11 P1 / design §4.4 / invariant H1.
- **Why it matters**: an ordering regression would silently mask drift (reminders against an empty
  index) and slip past delta-green.
- **Classification**: ❌ missing (test contract designed-implied for a load-bearing invariant, not
  built). Owning phase: P1/P3 (start read-path) per design §11.
- **Adversarial-verify verdict**: **confirmed (high confidence)** — no ordering assertion exists.
- **Proposed resolution**: add `test_start_resolution_before_notices` (unresolved repo → assert the
  resolve prompt precedes any divergence notice in the output stream). **HITL** (pre-merge vs backlog).

### 🔴 F5 — MEDIUM — Tests mutate tracked repo files in place; unsafe under concurrent/interrupted runs

- **Lens**: test-contracts (surfaced by the lead session — the workflow's parallel lens agents each ran
  `CCO_ALLOW_HOST_RESOLVE=1 ./bin/test` concurrently and **corrupted the working tree**: `changelog.yml`
  was overwritten with a fixture (`"Dual tracker test feature"`) and `templates/project/base/.claude/
  CLAUDE.md` got test markers (`"Sync divergence test change"`, `"Framework improvement for projects"`).
  The lead restored both via `git checkout`).
- **Location**: `tests/test_update.sh:699-809,2034-2283` (`cp "$REPO_ROOT/changelog.yml" "$saved" ; cat >
  "$REPO_ROOT/changelog.yml" <<'YML'` — saves and overwrites the **real** repo `changelog.yml`, relying
  on a teardown restore) and `tests/test_publish_install_sync.sh:330` (`with_framework_change
  "templates/project/base/.claude/CLAUDE.md"` mutates the **real** base template). The `$REPO_ROOT/...`
  paths point at the live tracked files, not a sandbox copy.
- **Observed**: a single sequential `./bin/test` run restores cleanly, but two concurrent runs race on the
  same real `$REPO_ROOT/changelog.yml` (run B's "save" captures run A's already-overwritten fixture, so
  the restore writes garbage back), and an aborted/interrupted run skips the teardown restore entirely —
  either way the tracked file is left corrupted. This is exactly what happened during this audit.
- **Expected**: tests must be hermetic — operate on temp copies (the harness already flips `HOME` and the
  XDG buckets to a sandbox), never `cat >` / mutate a tracked `$REPO_ROOT/...` file the rest of the repo
  depends on. (Project testing rule: tests verify behavior without side effects on the source tree.)
- **Why it matters**: a developer running tests while another run is in progress — or Ctrl-C'ing a run —
  silently corrupts `changelog.yml` / the base template and may commit the garbage. It also makes the
  suite non-parallelizable and undermines "delta-green" trust (a polluted `changelog.yml` could flip
  unrelated update tests).
- **Classification**: 🔴 hybrid-divergent-error (a test-contract conformance bug; not design-sanctioned).
- **Adversarial-verify verdict**: **confirmed (high confidence)** — reproduced by `grep` of the write
  sites; the corruption was observed and restored this session.
- **Proposed resolution**: redirect these tests to operate on a temp copy of `changelog.yml` / the base
  template (e.g. stage into the sandbox `$HOME`/XDG tree the harness already provides, or `cp` into a
  `mktemp -d` and point the code at it), removing every `cat > "$REPO_ROOT/..."` / in-place mutation of a
  tracked file. Until fixed, **do not run the suite concurrently**. (Refactoring/hardening item; the lead
  has already restored the tree.)

### Representative ✅ implemented-conformant (load-bearing; full conformant coverage in the per-lens summaries)

- **C1 — 4-bucket XDG resolver + H4 guard** — `lib/paths.sh:200-293` (XDG precedence
  `$CCO_*_HOME`→`$XDG_*_HOME/cco`→default, 0700) + `:228-233` (anti-in-container guard with
  `CCO_ALLOW_HOST_RESOLVE` hatch). Foundational; correct.
- **C2 — Coordinate ⇄ index separation (AD3/G8)** — `lib/yaml.sh` final-form parsers; `lib/index.sh`
  name→path only, atomic `mktemp`+`mv`, no coordinates in the index;
  `lib/cmd-project-add.sh:186-210` writes coordinates→manifest, `--path`→index only. Truthful diff
  guaranteed by construction.
- **C3 — Remotes M3 split** — `lib/paths.sh:_cco_remotes_file` (url→DATA) /
  `_cco_remotes_token_file` (token→STATE, 0600). S8 no-token-leak by construction.
- **C4 — Migration safety** — `lib/migrate.sh` J0 per-root idempotent bootstrap, M8
  backup-verified-before-read, F44 atomic-staged write, ADR-0026 marker gate, F11 non-clobber memory,
  F12 name-uniqueness.
- **C5 — Removed-verb guards** — `bin/cco:180-187,241` explicit AD12 rejections with ADR citations.
- **C6 — Sharing 2×2 + projects-no-publish** — pack/template publish/install/export/import;
  projects export/import only (P13 asymmetry); structure-based discovery (no `manifest.yml`).
- **C7 — P14 reachability never hard-blocks** — `lib/cmd-resolve.sh:79-151` + `cmd-start.sh:501-516`
  warn + conscious-skip + passive ⚠ badge; no die on unresolved refs.

---

## Optimization & duplication backlog (flag-only — NOT for this review to fix)

Anticipates the dedicated refactoring review (SOLID/DRY/KISS/YAGNI). Locations + one-line why:

1. **Tab-peel coordinate-read idiom** repeated ~12× — `lib/cmd-resolve.sh:97-118`,
   `lib/cmd-project-validate.sh:128-143`, `lib/cmd-project-coords.sh:35-40` (+ mounts/llms/packs
   variants). One `_peel_tab_field` helper would consolidate.
2. **Index-enumeration loop** repeated 13× — `cmd-pack.sh:244,297`, `cmd-resolve.sh:252`,
   `cmd-clean.sh:139`, `cmd-config.sh:222`, `cmd-project-coords.sh:62`, `cmd-project-query.sh:52`,
   `cmd-start.sh:1184`, `cmd-stop.sh:65`, `cmd-llms.sh:560,758`, `cmd-update.sh:233`,
   `cmd-project-validate.sh:291`. A `_project_foreach` helper would centralize semantics.
3. **Two 3-way mergers sharing a decision tree** — `lib/cmd-pack.sh:975-1008` (whole-file) vs
   `lib/update-merge.sh:13-49` (line-level). Extract a shared `_3way_decide`.
4. **Mixed-responsibility `_pv_validate_unit`** (~190 lines) — `lib/cmd-project-validate.sh:111-300`:
   split validate / probe / record.
5. **Per-section coordinate field-peeling** repeated 4× — `lib/cmd-project-coords.sh:35-62`.
6. **Single-use helper `_pack_merge_put`** — `lib/cmd-pack.sh:957-960` (3 call-sites only); inline.
7. **324-line `cmd_update` dispatcher** — `lib/cmd-update.sh:8-332`: split arg-parse vs mode handlers.
8. **By-hand key=value peel** — `lib/update-merge.sh:199-204`: a `_kv_lookup` helper.
9. **`_pack_merge_eq`** context-specific equality — `lib/cmd-pack.sh:949-954` (awareness only).
10. **Duplicated secret-scan** — `lib/cmd-build.sh:74` (inline) vs
    `lib/cmd-project-export-import.sh:20`; consolidate via `lib/secrets.sh`.
11. **`cmd_update` mode orchestration** — `lib/cmd-update.sh:84-332`: per-mode handlers.
12. **Coordinate validation rules not data-driven** — `cmd-project-validate.sh:127-213`,
    `cmd-project-coords.sh:35-62`, `cmd-resolve.sh:96-141`: a `_COORD_RULES` schema would centralize.
13. **`_pack_resolve_dir` comment vs code** — `lib/packs.sh:12-13` says layer 1 is `~/.cco/packs` but
    the code reads `$PACKS_DIR`; resolves itself once F1 is decided (comment will become true or the
    code will move). Flagged so it is not lost.

---

## HITL flags for the maintainer

### HITL-1 — F1 intent: genuine cleanup or sanctioned dev-fallback? (HIGH — gates merge)

- **Why not derivable from spec**: the design (§2.2/§2.3, ADR-0016 D2/D7/D8, §9 P3 line 950) is
  explicit that packs/templates live in `~/.cco` and llms content lives in CACHE — but the code keeps
  all three in `$CCO_USER_CONFIG_DIR`, and nothing in the repo (README/installer/Dockerfile/profile)
  sets that variable to `~/.cco`. The progress note schedules no such relocation in P0–P5. So whether
  this is a forgotten cutover or a deliberate self-dev indirection is a genuine intent question, and
  the resolution changes user-visible bucket placement (P10 method-lesson b).
- **Options**:
  1. **Relocate (treat as missed cleanup)** — point packs/templates → `_cco_config_dir`, llms content
     + cache-state → CACHE; add a user-config→`~/.cco`/CACHE migration; fix `paths.sh:154` + the
     `packs.sh` comment; align `tests/helpers.sh`. *Trade-off*: most code churn, but makes code match
     the design and removes the config-editor/host split-brain. **Recommended** — the design statement
     "llms **content** → **CACHE**" is unambiguous and the falsely-reassuring `paths.sh:154` comment
     indicates the intent was to relocate.
  2. **Sanction the indirection** — add an ADR/design note that `$CCO_USER_CONFIG_DIR` is the
     production hook expected to root at `~/.cco` (packs/templates) with a CACHE split for llms;
     document it in the install path; correct §2.2/§2.3 prose and `paths.sh:154` to stop claiming a
     CACHE split that the default layout does not implement. *Trade-off*: least churn, but the llms
     content + etag/timestamp still sit in a versionable root unless the install actively redirects —
     so the P6/G8 concern only partly closes.
- **Spec-grounded recommendation**: **Option 1 for llms** (the design is explicit and the
  `paths.sh:154` comment is currently false) and **Option 1 for packs/templates** to keep the host CLI
  and the config-editor agreeing on the personal-store home. If churn must be minimized for v1, at
  minimum fix the false `paths.sh:154` comment and relocate llms content+cache-state to CACHE, and file
  an ADR deferring the packs/templates relocation explicitly (re-opening one LIVE transitional entry,
  which the registry currently — and otherwise correctly — holds empty).
- **Decision (maintainer, 2026-06-25): Option 1 — Relocate** all three to `~/.cco/{packs,templates}` +
  CACHE for llms (treat as the missed cutover it is). The registry LIVE set therefore stays empty (F1 is
  a 🔴 to fix, not a sanctioned hybrid). The fix is **scheduled for a dedicated implementation session
  before merge** (the review stays read-only); tracked in the global roadmap "Pre-merge fix backlog".

### HITL-2 — F2 / F4 test scope: add the H1 + P15 contract tests pre-merge or as a hardening backlog?

- **Why not derivable from spec**: the design contracts the behavior but not the test granularity; both
  invariants are correct in code today, so this is a risk-appetite call, not a bug.
- **Options**: (a) add both tests pre-merge (closes the delta-green blind spot before the cutover
  merges) — recommended; (b) log them as a hardening backlog item and merge now (acceptable since the
  code is conformant and the suite is green). **Recommendation**: (a) — they are small, and H1/P15 are
  exactly the kind of ordering/discriminator invariants a future refactor could silently break.
- **Decision (maintainer, 2026-06-25)**: action F2/F4 (with F5) in the same dedicated pre-merge
  implementation session as F1 — close the review loop read-only now, fix separately. Tracked in the
  global roadmap "Pre-merge fix backlog".

---

## Transitional Registry refresh note

The §4 **LIVE transitional set is empty** and should stay empty. **F1 is the one item that may force a
single new LIVE entry**: if the maintainer chooses HITL-1 Option 2 (or Option 1's "defer
packs/templates" sub-path), the `$CCO_USER_CONFIG_DIR` personal-store layout becomes a *sanctioned*
hybrid and MUST be added to the registry with an explicit retiring phase / ADR — otherwise it remains
🔴. No other registry change: the RETIRED list is accurate, the KEEP-forever readers are correctly
isolated, and the central-layout teardown is complete.

---

## Completeness critic results

The critic ran and rates coverage **strong**. Its actionable residue, reconciled against this synthesis:

- **llms bucket placement** — the critic asked for line-by-line re-verification; **done in this
  write-up** (`bin/cco:32,39`, `cmd-llms.sh:110,717`, `paths.sh:154`, `packs.sh:22-29`,
  `helpers.sh:33,38-40`). Result: confirmed + broadened to packs/templates → **F1 / HITL-1**.
- **fingerprint contract test (F39)** — critic flagged as a possible gap; the **adversarial pass
  refuted it** (see refuted appendix R4): `tests/test_sync_meta.sh` has 11 explicit tests covering
  compute/write/lazy-compare/pristine. No gap.
- **H1 / P15 explicit tests** — confirmed gaps → **F2 / F4 / HITL-2**.
- **doc §7.3 inconsistency** — confirmed → **F3**.
- **test stability** — re-run this session: **894/0**, stable; the "893/1 / 891/3" observations were
  refuted (transient temp-dir/env, not in current code) — see R1/R2/R3/R5.
- **Low-severity confirmatory items** (migration idempotency exhaustive sweep; deferred-post-v1
  absence grep; full compose-mount audit; internalize end-to-end) — not re-run here; the sampled
  evidence is conformant and these are confirmatory, not blocking.
- **Second round?** The critic advised a second light round chiefly to re-verify the llms placement;
  that is now done. **A second full round is NOT required** — the one HIGH (F1) is a maintainer
  decision, not a further-investigation item. Recommend: resolve HITL-1, then a targeted re-check of
  only the files F1 touches.

---

## Refuted findings appendix (adversarial pass — shows rigor)

1. **"Baseline regressed to 891/3"** (invariants) — **refuted**: `CCO_ALLOW_HOST_RESOLVE=1 ./bin/test`
   → 894/0. The handoff §4 baseline holds.
2. **"Stale hardcoded `workflow.md` hash in `test_invariants.sh`"** (transitional) — **refuted**: the
   test computes hashes dynamically (lines 17-24); no hardcoded SHA1 in source; test passes; the
   invariant (init reads defaults, never writes them) is correctly tested.
3. **"`test_update_no_changes` fails with 'opinionated updates available'"** (transitional) —
   **refuted**: test passes; init copies defaults to installed AND saves base from the same source in
   one pass, so hashes match; manually reproduced "up to date".
4. **"Fingerprint contract (F39) untested"** (test-contracts) — **refuted**: `tests/test_sync_meta.sh`
   has 11 explicit fingerprint tests (compute / written-after-sync / lazy-compare / pristine /
   ignores-secrets / machine-agnostic), importing `lib/sync-meta.sh`.
5. **"893/1 — `test_update_refreshes_cco_base` regression"** (cutover) — **refuted**: re-run shows
   894/0; the test passes consistently in isolation; transient temp-dir/env condition, not a code
   defect.

---

*Generated with Claude Code*
