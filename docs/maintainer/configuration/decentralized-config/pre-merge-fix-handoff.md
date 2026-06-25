# Pre-merge Fix Session — Handoff (decentralized-config v1)

> **✅ RESOLVED 2026-06-25.** All five fixes applied in this dedicated session, each delta-green;
> new baseline **897/0** (+3 pinning tests), the F1 merge-gate is cleared. Commits LOCAL:
> **F5** `72a6253` · **F3** `d641528` · **F2+F4** `ab64f1b` · **F1** `392f12e`. Notable, maintainer-
> confirmed deviations from the literal plan: **F5 scope broadened** to ALL tracked-file mutations via one
> `CCO_FRAMEWORK_ROOT` seam (not just the 2 enumerated sites) so the suite is genuinely
> concurrency/abort-safe; **F1 needed no relocation migration** (unmerged branch, migration already targets
> `~/.cco`, llms re-fetchable) and additionally removed a dead `cmd-pack` cross-branch check; **F4/F2 tests
> re-homed** to `test_project_validate.sh` / `test_start_reminders.sh` for coherence. Roadmap "Pre-merge
> fix backlog" flipped to RESOLVED. **Next (pending maintainer go-ahead): documentation review.** The body
> below is the original launcher, kept as the record.

**Status**: Self-contained launcher for the **dedicated pre-merge fix session**. It actions the 🔴/❌
findings of the **whole-scope pre-merge implementation-adherence review** (2026-06-25,
`reviews/25-06-2026-impl-adherence-review.md`) so the decentralized-config v1 branch becomes
merge-ready. **This session WRITES production code** — it is an *implementation* phase, distinct from the
read-only review that produced the findings. **Phase transition needs maintainer go-ahead** (never
auto-advance; `.claude/rules/workflow.md`).

> **Branch** `feat/vault/decentralized-config` · **baseline 894/0** (`CCO_ALLOW_HOST_RESOLVE=1 ./bin/test`,
> the hatch is required in the container) · commits **LOCAL** (maintainer pushes from Mac) · ADRs
> 0005–0027 · next free ADR **0028**.

---

## 0. TL;DR

The review found v1 **not yet merge-ready**: **1 HIGH 🔴 (F1) + 3 MEDIUM 🔴 (F3 doc · F4/F5 test) + 1
MEDIUM ❌ (F2 test)**, **0 blockers**, plus **13 optimization flags** (flag-only — they are NOT this
session's job; they feed the later refactoring review). The rest of the v1 surface is code-grounded
conformant and the §4 Transitional Registry LIVE set stays **empty**. Apply F1–F5 here (delta-green vs
894/0), then the pre-merge review cycle continues: **documentation review → refactoring/optimization
review [consumes the 13 flags] → UX-UI review → dogfooding e2e (Mac) → merge/release v1**.

The maintainer already decided (2026-06-25): **F1 = Relocate (Option 1)** and **action all five fixes in
this dedicated session** (the review itself stayed read-only).

---

## 1. Reading order

1. `guiding-principles.md` (**P1–P18**) — the law. Esp. **P1** (config vs internal = edit criterion),
   **P2** (bucket taxonomy), **P6** (hide internal files; never in a config bucket), **P10** (classify by
   role; maintainer-confirm UX choices), and **G8** (truthful `git diff` on config buckets).
2. **This file.**
3. The review report **`reviews/25-06-2026-impl-adherence-review.md`** — the *spec* for the fixes
   (per-finding location · observed vs expected · proposed resolution · adversarial-verify verdict).
4. `design.md` **§2.1/§2.2/§2.3/§2.4** (layout + the 4 buckets + the resolver table) and **§9/§11**
   (phase map + test contracts), plus the load-bearing ADRs **0007** (XDG bucket locations), **0014**
   (llms = referenced-resource coordinate), **0015** (DATA bucket), **0016** (the authoritative
   resource→(bucket,sync) table — **D7 llms content → CACHE**, **D8 packs/templates → `~/.cco`**).
5. The personal progress note `decentralized-config-impl-progress.md` (tail = latest cursor).
6. The code (re-grep — the `file:line` in this handoff and the report **drift**; re-read before editing).

**Precedence when docs disagree**: `guiding-principles.md` P1–P18 → ADRs 0005–0027 → `design.md` →
`requirements.md`. Record any reconciliation; do not silently pick one.

---

## 2. Method / working agreement

- **Delta-green per commit vs 894/0** — every commit leaves the full suite green
  (`CCO_ALLOW_HOST_RESOLVE=1 ./bin/test`); **any** failure is a regression (the baseline is now ZERO
  failures, not a known-failure set). Run with the hatch (this container looks like a session container).
- **Build-once, final form** — no transitional/dual-read state. The LIVE Transitional Registry set is
  **empty and must stay empty**; a new hybrid would need an explicit maintainer sanction + a registry
  entry + a retiring phase (don't introduce one).
- **Design + ADRs + principles are the law.** The fixes *implement existing design* (esp. F1 implements
  §2.2/§2.3/ADR-0016 D7/D8) — they do not re-open settled design. F1 likely needs **no new ADR**; if the
  (probably-unneeded) data-relocation mechanism turns into a decision, ADR-0028 is free.
- **Atomic commits, LOCAL** on `feat/vault/decentralized-config` (conventional messages; maintainer
  pushes from Mac). Follow `.claude/rules/git-workflow.md` (feature branch → develop; never commit to
  main/develop directly).
- **Maintainer-confirm before coding** any choice that affects UX / interface / bucket placement / the
  build sequence (P10 method-lesson b) — use AskUserQuestion, as every prior phase did. **Confirm the
  build sequence (§6) before starting.**
- **Code-ground every change** (re-grep; build the full writer/reader map before repointing a path var).
- **Dogfooding safety**: never accept the legacy-vault offer-to-remove until the branch is merged AND
  validated on the Mac (`P2-dogfooding-validation.md`).

---

## 3. What is being fixed (the review results)

| ID | Sev | State | Summary |
|----|-----|-------|---------|
| **F1** | HIGH | 🔴 | Personal flat store **packs/templates/llms** still resolve under `$CCO_USER_CONFIG_DIR` (default `$REPO_ROOT/user-config`), not `~/.cco/{packs,templates}` (CONFIG) + **CACHE** for llms — a missed cutover. **Gates merge.** |
| **F3** | MED | 🔴 | `cco template update` shown as a working example in `configuration-management.md:346` but marked 🚧 in the table (`:576`); the verb is deferred post-v1. |
| **F4** | MED | 🔴 | The P15 coordinate-presence discriminator (cache vs authored, incl. the §2.4 ERROR collision row) is implemented but **not pinned by an explicit test**. |
| **F5** | MED | 🔴 | `test_update.sh` / `test_publish_install_sync.sh` mutate **tracked repo files** (`changelog.yml`, the base template) in place → corrupt the working tree under concurrent/interrupted runs. |
| **F2** | MED | ❌ | No explicit test for the **H1 ordering** invariant (resolution before notices). |

**13 optimization flags = OUT OF SCOPE here** (DRY tab-peel, the index-enum loop repeated ~13×, two
3-way mergers, `_pv_validate_unit`/`cmd_update` size, etc.). They are a non-blocking backlog for the
**refactoring review** — see the report §"Optimization & duplication backlog". Do **not** refactor them in
this session (it would dilute the fix focus and expand scope).

---

## 4. F1 — relocate the personal flat store (HIGH, gates merge). Code-grounded.

**The split-brain (three independent code sites confirm it):**
- **Migration writes to `~/.cco`** — `lib/migrate.sh:220-222` copies the backup's `templates/`+`packs/`
  into `cfg="$(_cco_config_dir)"` = `~/.cco/{templates,packs}` (the profile→tag seed at `:255-256` too).
- **`cco config` versions `~/.cco`** — `lib/cmd-config.sh` operates on `_cco_config_dir` (`~/.cco`), and
  its allowlist (`:42+`) commits `packs`/`templates` from there.
- **But the runtime reads `$USER_CONFIG_DIR`** — `bin/cco:38-40`
  `PACKS_DIR=$USER_CONFIG_DIR/packs`, `LLMS_DIR=$USER_CONFIG_DIR/llms`,
  `TEMPLATES_DIR=$USER_CONFIG_DIR/templates`, with `USER_CONFIG_DIR=${CCO_USER_CONFIG_DIR:-$REPO_ROOT/user-config}`
  (`bin/cco:32`). So a migrated user has packs/templates in `~/.cco` but `cco pack list` /
  `_pack_resolve_dir` look in `user-config` → empty. The config-editor mounts `~/.cco`
  (`cmd-start.sh`), the host CLI reads `user-config` → split-brain.

**Root cause**: in P3-3b the **global** home was cut over (`GLOBAL_DIR` default → `~/.cco/global`,
`bin/cco:37`), but the **flat stores were not** — they still hang off the legacy `USER_CONFIG_DIR`.
`USER_CONFIG_DIR` now carries **two conflated roles**: (a) the **legacy-vault pointer** for the migrator
(`migrate.sh:103` `vault="$USER_CONFIG_DIR"`, `:344/:346` "preserved … `rm -rf $USER_CONFIG_DIR`") — this
role is **correct and must stay**; (b) the **live flat-store root** (`bin/cco:38-40`, the
`update.sh:143-146` fallback) — this role is the **bug**.

**Maintainer decision (2026-06-25): Relocate (Option 1)** — align the runtime to the design and to where
migration + `cco config` already operate.

**Fix (align runtime readers; disentangle the dual role):**
- `bin/cco:38` `PACKS_DIR` default → `$(_cco_config_dir)/packs` (`~/.cco/packs`).
- `bin/cco:40` `TEMPLATES_DIR` default → `$(_cco_config_dir)/templates` (`~/.cco/templates`).
- `bin/cco:39` `LLMS_DIR` default → `$(_cco_cache_dir)/llms` (CACHE) — llms content + cache-state
  (etag/resolved_url/downloaded in `<name>/.cco/source`) is re-fetchable internal data (design §2.2 line
  ~201; ADR-0016 D7). It is **not** in the `cco config` allowlist (correct — it must not be), so moving it
  out of `~/.cco`-adjacent into CACHE is clean. Consider adding a `paths.sh` helper (`_cco_llms_dir` →
  `$(_cco_cache_dir)/llms`) for symmetry, mirroring `_cco_pack_source`/`_cco_data_dir`.
- Keep `USER_CONFIG_DIR` **only** as the legacy-vault pointer (the `migrate.sh` role). Do not delete it;
  do not let any live flat-store path derive from it.
- **Fix the false comment** `lib/paths.sh:154` (*"llms `source` is NOT relocated (already CACHE-split)"*)
  — it is currently false; make it true after the move (or correct the assertion).
- **Remove/realign the legacy fallback** `lib/update.sh:143-146` (re-points GLOBAL/PACKS/TEMPLATES to
  `$USER_CONFIG_DIR/...` under a migration-003 guard — a central-layout remnant).
- **Reconcile `cmd-remote.sh:167-169,221-222`** — it adds/removes git remotes on `$USER_CONFIG_DIR/.git`,
  but `cco config push/pull` uses `~/.cco/.git` (`cmd-config.sh`). Verify whether the remotes registry
  (DATA, M3) + `cco config` remote already cover this; if so, drop the `USER_CONFIG_DIR/.git` mirror,
  else repoint it to `_cco_config_dir`. (This is part of disentangling the dual role.)
- **Align the test harness** `tests/helpers.sh:33,38-40` to the new homes (interacts with F5 — see §5).

**No data-relocation migration is needed.** The branch is unmerged with **no users on the broken code
path** (progress note), and the eager global migration **already** targets `~/.cco` (`migrate.sh:220-222`)
— so once the runtime defaults are repointed, fresh installs and migrated users are correct. **Verify
this** before deciding (do not add a `user-config/* → ~/.cco`/CACHE relocation step unless a real need
surfaces; if it does, it must not collide with `USER_CONFIG_DIR`'s legacy-vault role). **Confirm with the
maintainer** that no relocation migration is wanted.

**Design references**: design §2.2 (CACHE holds llms content + cache-state), §2.3 (lines ~233-234
packs/templates in `~/.cco`; line ~245 "llms content → CACHE"), §2.4 resolver table; ADR-0016 D7/D8;
ADR-0007 (bucket locations); ADR-0014/0015 (llms coordinate vs content/cache); P2/P6/G8.

**Caveat for the implementer**: build the **complete writer/reader map** of `PACKS_DIR`/`TEMPLATES_DIR`/
`LLMS_DIR`/`USER_CONFIG_DIR` (grep `lib/ bin/ tests/`) before repointing — this handoff's list is
code-grounded but **may not be exhaustive**; line numbers drift. Watch consumers in `cmd-pack.sh`,
`cmd-template.sh`, `cmd-llms.sh`, `packs.sh` (`_pack_resolve_dir` layer-1 `:22-29` + its comment `:12-13`),
`cmd-update.sh`, `cmd-start.sh`, `cmd-remote.sh`, `migrate.sh`, `update.sh`.

---

## 5. F3 / F4 / F5 / F2 — the smaller fixes

- **F3 (doc, 🔴)** — `docs/user-guides/configuration-management.md:346` shows `cco template update` as a
  working example while `:576` (the reference table) marks it 🚧 planned, and `lib/cmd-template.sh` has no
  `update)` case. **Fix**: remove the `cco template update` line from the §7.3 example (keep the
  implemented `cco pack update` lines), or move it under a 🚧 "planned" subhead matching the table.
- **F4 (test, 🔴)** — add explicit tests for the **P15 coordinate-presence discriminator** in
  `tests/test_pack_resolution.sh`: `test_pack_with_coordinate_is_cache_not_source` /
  `test_pack_without_coordinate_is_authored_source`, plus a row-by-row check of the design §2.4 table incl.
  the **ERROR** collision (authored no-url pack ALSO present as `~/.cco/packs/<name>`). Behavior is correct
  in code (`lib/cmd-project-validate.sh:~199-206`, `lib/packs.sh:22-29`) — this pins the contract so
  delta-green can't mask a regression.
- **F5 (test-isolation, 🔴)** — `tests/test_update.sh` (`:699-809,2034-2283`: `cp "$REPO_ROOT/changelog.yml"
  …; cat > "$REPO_ROOT/changelog.yml"`) and `tests/test_publish_install_sync.sh:330`
  (`with_framework_change "templates/project/base/.claude/CLAUDE.md"`) mutate **tracked** repo files in
  place, relying on a teardown restore. Concurrent runs race on the shared real file; an interrupted run
  skips restore → tree corruption (it happened during the review; the lead restored via `git checkout`).
  **Fix**: redirect these tests to operate on a **sandbox copy** (the harness already flips `HOME` + the
  XDG buckets — stage `changelog.yml`/the base template into that sandbox, or a `mktemp -d`, and point the
  code at it), removing every `cat > "$REPO_ROOT/…"` / in-place mutation of a tracked file. Until fixed,
  do **not** run the suite concurrently. **Do F5 first** so the suite is concurrency/abort-safe for the
  rest of the session.
- **F2 (missing test, ❌)** — add `test_start_resolution_before_notices` (e.g. in `tests/test_start_*`):
  with an unresolved repo, assert the resolve prompt/notice **precedes** any divergence notice in the
  output stream (H1, design §4.4 / §11 P1). Code is correct at `lib/cmd-start.sh:~1116-1131`; this pins
  the ordering so a future refactor can't silently reverse it.

---

## 6. Proposed build sequence (CONFIRM with the maintainer before coding)

Each step delta-green vs 894/0; atomic commit; LOCAL.

1. **F5** — test-isolation fix first (makes the suite safe to run concurrently/abort during the rest).
2. **F3** — doc one-liner.
3. **F2 + F4** — the two pinning tests (H1 ordering; P15 discriminator).
4. **F1** — the substantive relocation (may split into sub-commits: (a) repoint defaults +
   `paths.sh`/`update.sh`/`cmd-remote` disentangle; (b) align `tests/helpers.sh` + any fixtures; (c)
   verify-no-migration / optional relocation). Largest + most co-dependent → last, with full context.

Rationale: small isolated fixes lock green first; F1 (touches `bin/cco` path resolution + harness + many
consumers) lands last as the careful change. (The maintainer may prefer F1-first since it gates merge —
ask; both are defensible.)

---

## 7. Invariants to preserve (do not break while fixing)

- **4-bucket taxonomy** (CONFIG `~/.cco` · DATA `~/.local/share/cco` · STATE `~/.local/state/cco` ·
  CACHE `~/.cache/cco`); internal/regenerable data never in a config bucket (P6/G8).
- **AD3/G8** — `project.yml`/`pack.yml` carry logical names + coordinates only; no real paths; truthful
  `git diff`.
- **H1** (resolution before notices), **H4** (host-side resolver guard + `CCO_ALLOW_HOST_RESOLVE` hatch),
  **H6/H7** (merge artifacts in STATE keyed by id; atomic index `mktemp`+`mv`).
- **compose↔entrypoint container-path contract** — `config/entrypoint.sh` is **read-only**; only
  host-source mount paths may change, container paths are fixed.
- **P14** reachability is layered, **never a hard block**; **P15** a local copy is never its source
  (discriminator = coordinate presence); **P17** permissions delegated to git.
- **No new sanctioned hybrid** — the §4 LIVE Transitional Registry set stays empty.

---

## 8. After the fixes — close out + continue the gate

1. Suite green at 894/0 (or higher if F2/F4 add tests — that becomes the new baseline; record it).
2. Optional: a **targeted re-check** of the files F1 touched (the review's completeness critic suggested a
   light re-verify of F1's surface after the fix — not a full re-audit).
3. Update the **roadmap** (move F1–F5 out of the "Pre-merge fix backlog" once done) + the **progress
   note** (`decentralized-config-impl-progress.md`) + this handoff's status.
4. Continue the maintainer's **pre-merge review cycle**: documentation review (the global
   `decisions/roadmap.md` §73 mega-block + `browser-mcp/design.md` deep rewrite + `review-playbooks.md` →
   `cave` pack are known candidates) → **refactoring/optimization review** (consumes the 13 optimization
   flags) → **UX-UI review** → **dogfooding e2e on Mac** (`P2-dogfooding-validation.md` §3; restart-from-
   zero = `rm -rf ~/.cco ~/.local/share/cco ~/.local/state/cco ~/.cache/cco`) → **merge → v1 release** →
   distribution/packaging.

---

## 9. Reference paths

- **Review report (the fix spec)**: `reviews/25-06-2026-impl-adherence-review.md`
- **Recurring review playbook**: `implementation-review-handoff.md` (§4 RUN-COMPLETED note records this
  review; LIVE registry stays empty)
- **Roadmaps**: global `docs/maintainer/decisions/roadmap.md` §"Pre-merge fix backlog (decentralized-config)";
  `analysis-roadmap.md` (pre-merge-gate status)
- **Design / law**: `design.md` (§2/§9/§11), `guiding-principles.md` (P1–P18), `requirements.md`,
  ADRs `decisions/0005`–`0027`
- **Build method (master)**: `Y-handoff-implementation.md`
- **Dogfooding**: `P2-dogfooding-validation.md`
- **Personal cursor**: memory `decentralized-config-impl-progress.md` (tail)
- **Rules**: `.claude/rules/{workflow,git-workflow,documentation-lifecycle,update-system}.md`

---

## 10. Out of scope (do NOT do here)

- The **13 optimization/duplication flags** (refactoring review owns them).
- The **post-v1 backlog** (`cco template update`, `cco pack update` 3-way, `cco config protect` helper,
  internalize-as-cache prompt, T state-sync, index namespacing, etc. — global roadmap §"Post-v1 backlog").
- The critic's **low-severity confirmatory items** (exhaustive migration-idempotency sweep,
  deferred-item absence grep, full compose-mount audit) — optional; fold into a later review-cycle step if
  wanted, not required for merge.
- Re-opening settled design; expanding scope; rewriting shipped-behavior docs ahead of code.

---

*Generated with Claude Code*
