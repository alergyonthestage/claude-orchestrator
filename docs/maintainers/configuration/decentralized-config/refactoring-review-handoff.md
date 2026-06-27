# Handoff — Refactoring / Optimization Review (PRE-MERGE step 3)

> **✅ COMPLETED 2026-06-27.** This review ran and is done. Outcome + per-flag dispositions:
> [`reviews/27-06-2026-refactoring-review.md`](reviews/27-06-2026-refactoring-review.md).
> 8 commits `e65aa2f`→`0c3c822`, suite 914/0 → 921/0, behaviour-preserving. L6 deferred to the
> post-v1 backlog (positive `CCO_IN_CONTAINER` marker). Next cycle step = **UX-UI review**.
> This file is kept as the launcher's reference value; do not re-run it.

**Status**: Self-contained launcher for the **pre-merge refactoring/optimization review**
(roadmap "Pre-merge review cycle" step 3). Runs in its **own clean session**
after maintainer go-ahead. Branch `feat/vault/decentralized-config`, commits **LOCAL**
(push from the maintainer's Mac). Written 2026-06-27.

> **One-line goal.** Evaluate the shipped decentralized-config v1 code against
> software-engineering principles (S.O.L.I.D., DRY, Open/Closed, KISS, YAGNI), and
> **consolidate the 13 optimization flags** parked by the impl-adherence review plus the
> residual LOW/NIT polish from the migration review — into maintainable, reusable shape,
> without changing shipped behaviour or the frozen design.

---

## 0. TL;DR — what this session does

1. Read the source-of-truth (design + ADRs + principles + rules) and the **review playbook §3**.
2. Run the **refactoring review** read-only: find duplication, mixed responsibilities, and
   hard-to-extend/maintain/reuse code across `bin/` + `lib/`.
3. Carry the **two backlogs** below (the 13 optimization flags + the migration-review LOW/NIT),
   **code-grounding each** (line numbers drift) — several may already be resolved; re-verify.
4. Present findings + proposed refactors to the maintainer (options + recommendation), then
   **apply the approved ones**, green per step.

This is a **quality** pass: no behaviour changes, no new features, no design changes. The
design (ADRs 0005–0028, principles P1–P18) is FROZEN.

---

## 1. Reading order

1. `../../foundation/design/guiding-principles.md` (**P1–P18**, governing law).
2. **This file.**
3. `../../engineering/guides/review-playbooks.md` **§3 Refactoring review** (the method; this
   review's definition + principles). Note it is a TEMPORARY staging doc, promoted to the `cave`
   pack post-merge.
4. `design.md` (the living design) + the relevant ADRs for any module you touch.
5. `.claude/rules/` — `workflow.md` (phase discipline), `update-system.md` (migration/changelog
   rules — a refactor that moves a tracked file still needs a migration), `documentation-lifecycle.md`,
   `git-workflow.md`.
6. The two backlogs (§3, §4) and the shipped code they point at.

**Precedence on conflict**: guiding-principles → ADRs → design → shipped docs.

---

## 2. Method (review-playbooks §3)

- **Own clean session**, **read-only** w.r.t. production code until the maintainer approves changes.
- Goal: identify **duplicated** functionality/responsibility, components with **multiple mixed
  responsibilities**, and code hard to **extend/maintain/reuse**; propose patterns to refactor for
  maintainability, extensibility, reuse, testability. Principles: **S.O.L.I.D., DRY, Open/Closed,
  KISS, YAGNI**.
- **Behaviour-preserving.** Every refactor must keep the contract identical: same CLI surface, same
  files written, same exit codes. Tests are the guardrail.
- **Green per step.** `CCO_ALLOW_HOST_RESOLVE=1 ./bin/test` after each logical refactor. Current
  baseline **914/0** (post-flatten, 2026-06-27). Atomic LOCAL commits per logical unit.
- **Code-ground every site** (re-grep; the line numbers below WILL have drifted), and **re-verify
  each backlog item is still live** — F1–F5 of the 25-06 review and parts of the migration-review
  LOW/NIT have already landed (see notes), so some flags may be moot or partially done.
- A refactor that **renames/moves a tracked file or changes a `*_FILE_POLICIES` entry** still needs a
  migration (`.claude/rules/update-system.md`). Pure internal-helper extraction does not.

---

## 3. Backlog A — the 13 optimization flags

Parked (flag-only) by `reviews/25-06-2026-impl-adherence-review.md` §"Optimization & duplication
backlog". None are 🔴; all anticipate this review. Locations are as-flagged (re-grep):

1. **Tab-peel coordinate-read idiom** repeated ~12× — `cmd-resolve.sh`, `cmd-project-validate.sh`,
   `cmd-project-coords.sh` (+ mounts/llms/packs variants). → one `_peel_tab_field` helper.
2. **Index-enumeration loop** repeated 13× — `cmd-pack.sh`, `cmd-resolve.sh`, `cmd-clean.sh`,
   `cmd-config.sh`, `cmd-project-coords.sh`, `cmd-project-query.sh`, `cmd-start.sh`, `cmd-stop.sh`,
   `cmd-llms.sh`, `cmd-update.sh`, `cmd-project-validate.sh`. → a `_project_foreach` helper.
3. **Two 3-way mergers sharing a decision tree** — `cmd-pack.sh` (whole-file) vs `update-merge.sh`
   (line-level). → extract a shared `_3way_decide`.
4. **Mixed-responsibility `_pv_validate_unit`** (~190 lines) — `cmd-project-validate.sh`: split
   validate / probe / record.
5. **Per-section coordinate field-peeling** repeated 4× — `cmd-project-coords.sh`.
6. **Single-use helper `_pack_merge_put`** — `cmd-pack.sh` (3 call-sites); inline.
7. **324-line `cmd_update` dispatcher** — `cmd-update.sh`: split arg-parse vs mode handlers.
8. **By-hand key=value peel** — `update-merge.sh`: a `_kv_lookup` helper.
9. **`_pack_merge_eq`** context-specific equality — `cmd-pack.sh` (awareness only).
10. **Duplicated secret-scan** — `cmd-build.sh` (inline) vs `cmd-project-export-import.sh`;
    consolidate via `lib/secrets.sh`.
11. **`cmd_update` mode orchestration** — `cmd-update.sh`: per-mode handlers.
12. **Coordinate validation rules not data-driven** — `cmd-project-validate.sh`, `cmd-project-coords.sh`,
    `cmd-resolve.sh`: a `_COORD_RULES` schema would centralize.
13. **`_pack_resolve_dir` comment vs code** — `lib/packs.sh`: comment said layer 1 is `~/.cco/packs`
    but code read `$PACKS_DIR`. **Note**: this flag was contingent on F1 (flat-store relocation),
    which is now **resolved** (pre-merge fix session 2026-06-25 → `~/.cco` + CACHE). Re-verify: the
    comment/code likely just needs reconciling, or is already consistent.

> Several flags cluster on `cmd-update.sh` (#7, #11), coordinate-peeling (#1, #5, #12), and the
> pack/merge family (#3, #6, #8, #9). Group the work by cluster, not by flag number.

---

## 4. Backlog B — residual LOW/NIT (migration review)

From `reviews/26-06-2026-migration-impl-review.md` (BLOCKER + HIGH + MEDIUM all resolved; "a few
LOW/NIT polish items" remained). **Re-verify each — some have already landed via later sessions:**

- **L1** — `for b in $(git for-each-ref …)` word-splits — `migrate.sh`; use `while IFS= read -r`.
- **L2** — legacy `path:`-only repo entry silently dropped by `_migrate_legacy_repos` flush — warn on drop.
- **L3** — `vault|` arm in `_cco_first_run` dead code. **Likely already removed** — verify (the
  current `_cco_first_run` has no `vault|` arm; the flatten session edited this function).
- **L4** — `chmod 0600 … || true` swallows failure — `migrate.sh`.
- **L5** — `design.md §3` index-schema example diverges from the implemented `name: "space-separated"`
  format. (Living-doc fix.)
- **L6** — `_cco_in_container` HOME check false-positives for a host user named `claude` — `paths.sh`.
- **L7** — `_index_section_get` awk strips ALL quotes → paths with a single quote corrupted — `index.sh`.
- **L8** — `cco forget` on a half-migrated project; die message could suggest `cco join` recovery.
- **L9** — stale refs in `cmd-update.sh`: comment at `:140` (the flatten session repointed the path to
  `~/.cco/.claude`, but L9's point is it should name the **`global-migrated` marker**, not a path);
  TODO at `:218` references legacy `user-config/packs/*`. **Partially addressed** — finish.
- **NIT** — `tar … 2>/dev/null` swallows the cause in backup warnings; the "never fatal" comment at
  `bin/cco:156` describes only the backup step (bootstrap can abort under `set -e`); redundant
  `*/secrets.env` clause in the secret-scan loop; misleading config-editor index-write comment;
  `_index_section_get` exact-header fragility + `REPO_ROOT` symlink-safety (pre-existing).

---

## 5. Already resolved (do NOT re-open)

- **F1–F5** of `reviews/25-06-2026-impl-adherence-review.md` — fixed in the **pre-merge fix session
  (2026-06-25)**: F1 flat store → `~/.cco` + CACHE (new `_cco_llms_dir`); F5 broadened to all
  tracked-file mutations via the `CCO_FRAMEWORK_ROOT` seam (suite concurrency/abort-safe); F2/F4
  re-homed. Baseline moved to 897/0 then onward.
- **Migration review BLOCKER/HIGH/MEDIUM** (BL1/BL2, H1–H7, M1/M4–M10; M2/M3 verified no-op) — all
  fixed (review §"Resolution log").
- **Flatten (ADR-0028)** — `~/.cco/global/.claude` → `~/.cco/.claude` done this cycle (6 commits;
  suite 914/0); a check_global gate-ordering bug it surfaced is fixed via the shared
  `_cco_flatten_global_claude` self-heal in `_cco_first_run`.

---

## 6. Out of scope (later pre-merge steps / post-merge)

- **UX-UI review** (step 4) — command symmetry, no-multiple-paths, reachability, destructive-action
  confirmation. Separate session (review-playbooks §4).
- **Dogfooding e2e on Mac** (step 5) — `P2-dogfooding-validation.md`; also **re-validate the global
  build-extension reader fix** (`a92effc`) and the **flatten** (`cco update` lands config at
  `~/.cco/.claude` once) on a real install.
- **Merge / release v1** (step 6).
- **Post-merge doc ops** — per-domain split of `cli.md` / `context-hierarchy.md` / the
  `configuration-management.md` guide; by-domain redistribution of the `decentralized-config/`
  sprint folder (roadmap backlog).

---

## 7. Working agreement

- Workflow phases (`.claude/rules/workflow.md`): analysis (read-only, this review) → propose with
  options + recommendation → maintainer approves → implement, green per step. **Pause and discuss**
  if a refactor would change behaviour or design.
- Atomic LOCAL commits per logical unit; conventional-commit messages; never commit to `main`/`develop`
  (`.claude/rules/git-workflow.md` — feature branch only).
- Gate after each step: `CCO_ALLOW_HOST_RESOLVE=1 ./bin/test` (baseline **914/0**).
- Final: re-grep to confirm no behaviour drift; suite green; summarize what was consolidated and
  what (if anything) was deferred.

---

## 8. Reference paths

- Method: `../../engineering/guides/review-playbooks.md` §3
- Flag source: `reviews/25-06-2026-impl-adherence-review.md` §"Optimization & duplication backlog"
- LOW/NIT source: `reviews/26-06-2026-migration-impl-review.md` §LOW / §NIT / §"Resolution log"
- Governing law: `../../foundation/design/guiding-principles.md`; living design `design.md`
- Roadmap entry: `../../roadmap.md` → "Pre-merge review cycle" step 3
- Rules: `.claude/rules/{workflow,update-system,documentation-lifecycle,git-workflow}.md`

---

*Generated with Claude Code*
