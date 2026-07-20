# Resume Handoff — cycle-1 review + RC-4 + final docs

> **Written 2026-07-20** for a fresh session (post-`/clear`). Self-contained: read this, check
> the prerequisites, review the cycle-1 implementation so far, then implement **RC-4** and the
> **docs** stage. Nothing below needs re-deriving — it is transcribed from the completed work.
>
> **Branch**: `fix/config-access/e2e-v2-cycle1`. **Tip**: `3c670e0`. **Suite**: **1403 passed /
> 9 failed** (the 9 are pre-existing FI-19 boundary artifacts — host-only tests defeated by the
> ADR-0047 privilege boundary and the self-dev `:ro` mounts, NOT regressions).

## 0. First actions in the new session (in order)

1. **Retrieve context.** Read this handoff in full, then memory `[[e2e-v2-review]]` (the RESUME
   POINT), then `00-overview.md` §5 (cross-cutting conventions) and §9 (the ratified decision
   table **D-M1…D-M11**).
2. **Check prerequisites** (§2 below) — do not skip; the last two sessions were interrupted and
   the tree state is the ground truth, not this doc.
3. **Review the current cycle-1 implementation** (§3) — a holistic pass over RC-17/1/6/2/3 as a
   coherent whole before adding the last two stages.
4. **Implement RC-4** (§4), then the **docs** stage (§5). Each is impl → adversarial-verify →
   (one repair round) → reverify, exactly as the five landed stages were run.

## 1. Canonical reading order (source-of-truth docs)

**The workstream (read as needed):**
- `00-overview.md` — cycle-1 index: §2 diagnosis, §3+§9 the **D-M1…D-M11** decisions, §5 the
  cross-cutting conventions (three availability states, 0/1/2 exit codes, positive assertions),
  §5.6 the doc/ADR reconciliation list the docs stage executes, §6 build ordering.
- `IMPLEMENTATION-HANDOFF.md` — §0 progress (5/6 stages done), §2 the decision table.
- `06-path-list-scoping.md` — **the RC-4 design** (root cause with `file:line`, the fix, rejected
  alternatives, blast radius, the §6 test plan). Read IN FULL before RC-4.
- `01-test-lane.md` §5.3 — the CAN/CANNOT boundary of the hermetic lane (verbatim into `testing.md`).
- `../results/consolidated-review.md` — the acceptance verdict, the 17-root map, D-M1…D-M3.
- `../handoff.md` §8 — the acceptance criteria A–G the eventual re-review re-runs.

**The settled model — ADRs (history; formalize, never re-litigate):** ADR-0042 (interaction
model), **ADR-0043** (output scoping, INV-A…E — RC-4's home; §4 mandated the opposite of the
shipped code comment at `cmd-resolve.sh:730-731`), ADR-0044 (built-in presets), ADR-0046 (the
`(G,Pc,Po)` model; §7 per-axis rules — RC-4 simply consults `Po` where it was skipped),
**ADR-0047** (the privilege boundary), ADR-0048 (config-editor min-privilege), **ADR-0049**
(concordant `claude_access`; §5 the functional floor), ADR-0050 (rename verbs), ADR-0051
(per-project name scoping). Paths: `../../decisions/…` and `../../../../{cli,naming}/decisions/…`.

**Living design docs the fixes keep true:** `../../design.md` §5, `design-cli-environment-awareness.md`,
`../../../../environment/design/design-docker.md` §1.2, `../../../../naming/design/design-resource-rename.md`,
`../../../../engineering/guides/testing.md`.

**Project principles / rules:** `.claude/rules/documentation-lifecycle.md` (history=annotate,
living=rewrite; **never rewrite user-facing docs ahead of the code**), `.claude/rules/update-system.md`
(additive/breaking/opinionated; cycle 1 is **code-only, no migration**), `.claude/rules/git-workflow.md`
(three-branch; **never commit to develop/main**), the global rules (Italian to the user, English in
code/docs, Mermaid not ASCII, options→decide→persist).

## 2. Prerequisites to verify on resume (ground truth)

```
git -C /workspace/claude-orchestrator status --short --branch    # expect: on fix/config-access/e2e-v2-cycle1,
                                                                  # clean but for ?? tmp and ?? to-verify-guides-docs.md
git log --oneline -1                                             # expect tip 3c670e0 (or later if work resumed)
git worktree list                                               # expect ONLY the main checkout (no stray revcheck-*)
wc -l tmp to-verify-guides-docs.md                              # maintainer's untracked notes: 28 + 19 lines, MUST be intact
./bin/test 2>&1 | tail -3                                       # expect 1403 passed / 9 failed
```

- The **9 failures are the accepted FI-19 baseline** (6 `test_as_*` list-scoping + `test_paths_symlink_safe_tool_root`
  + 2 `test_update_*`). `failed` must stay 9 through RC-4 and docs; `passed` only rises.
- **`tmp` and `to-verify-guides-docs.md` are the maintainer's untracked notes.** Never
  `git stash -u`, `git clean`, `git add -A`, or `git add .` — any of these can capture or destroy
  them. Stage only explicit paths. (An RC-6 agent stashed them once; recovered byte-intact. The
  workflow preamble now forbids it — keep that guard.)

## 3. Review the current cycle-1 implementation ("review attuale")

Before grafting the last two stages, review RC-17/1/6/2/3 as a coherent whole. **Scope**: the
`lib/` + `bin/` + `tests/` diff of this branch vs `develop` (the 5 implemented stages). This is a
*holistic coherence* review, not a re-review of each stage (each already passed an adversarial
revert-check). Confirm the pieces fit and nothing cross-stage regressed. Recommended: a small
review workflow (or a single high-effort reviewer agent) that checks:

- **Cross-stage invariants hold together.** INV-F (RC-2, probe vs display), INV-M1/M4 (RC-6, one
  mount source), INV-S1…S6 (RC-3, store boundary), the role-keyed nested-config axis (RC-1, D-M5),
  D-M11's Pc-follows-readonly for the config-editor target. No two stages contradict.
- **The D-M2 three-state vocabulary is consistent** where cycle-1 touched it: `"not mounted in
  this session"` is the shared string across RC-6's `_ce_skip_note` (`cmd-start.sh`), RC-2's
  `_env_note_unmounted` (`access-scope.sh`), and `cmd-project-query.sh`. (Verified once; confirm
  it still holds.)
- **RC-2's apply-order reversal is intact** (project.yml-FIRST-then-index-rekey, commit `216489b`;
  the recoverable half-state). RC-3's rename work must not have reverted it.
- **No dangling open-issue blocks RC-4 or docs.** Carried forward, all triaged (see §6): the
  `LLMS_DIR` taint minor (cycle-2), the §6.7 asserted-shape gap (→ docs cleanup), the once-WIP
  `05ab3af` stale label (cosmetic).
- **Suite integrity**: 1403/9, and no test asserts a negative-only rc (`test_invariants.sh` bans it).

If the review finds a real cross-stage defect, **surface it and decide before RC-4** (it may change
RC-4's foundation) — do not silently absorb it.

## 4. RC-4 — `cco path list` fail-closed (design: `06-path-list-scoping.md`)

**Root**: owner-less index pins are exempt from scoping, so `cco path list` is byte-identical
across access levels — the defect. **Builds on RC-2** (landed): extend `lib/access-scope.sh` in the
region RC-2 settled; read RC-2's commits (`git show 757b0fc..9dc2a3a`) and rebase onto its header.

- **Owns**: `_env_owner_in_scope`, `_env_in_scope`'s `path` kind, the **deletion of `_scope_paths`**.
- **Does NOT own**: mis-owned rows (RC-16, cycle 2), notice unification (D-M10/Q-C3 deferred).
- Both halves of criterion **B** must hold: no leaking false negative AND no hiding false positive.
  **INV-B**: newly-hidden rows are COUNTED in the notice, never silently dropped. **Criterion G**:
  host output and `read-all` output byte-identical.
- **D-M9/Q-9**: a project-less config-editor global session gets the honest empty path list + notice.
- **D-M10/Q-C3**: `path list` KEEPS its dedicated notice (the shared `_env_flush_hidden_notice`
  hardcodes a `read-global`-first hint at `access-scope.sh:584`, wrong for path rows which always
  need `read-all`). Do NOT parameterise the hint per kind — that touches five listers' stderr and
  is deliberately not smuggled into a confidentiality fix.
- **D-M10/Q-C2**: the ADR-0043 forward annotation suffices — no new ADR (the docs stage writes it).
- ADR-0046 §7's per-axis rules are applied UNCHANGED — `Po` is simply consulted where it was
  skipped (the reversed decision lives only in the code comment at `cmd-resolve.sh:730-731`; ADR-0043
  §4 mandated the opposite).
- **Tests must prove the outputs DIVERGE by level, positively** — not merely that some row is absent.

## 5. Docs stage — the final ADR/living-doc sweep (`00-overview.md` §5.6 + each cluster §7)

Run **after** RC-4 is green. Per `documentation-lifecycle.md`: ADRs are HISTORY → forward-annotate
(append, never rewrite); living docs → rewrite to truth. English; Mermaid not ASCII.

**Forward annotations** (append only): ADR-0049 §5 (RC-17 prediction came true again; the
hermetic/e2e split is now the lane + `01-test-lane.md` §5.3), ADR-0049 §7, ADR-0048 §4/§5 (**incl.
D-M11**: the config-editor target mount root's readonly follows Pc, closing the escalation D-M1's
self-clamp removal would open), ADR-0051, ADR-0046 §6/ADR-0047, ADR-0047 §2/§3 (primitive-granularity
elevation; INV-S6; **D-M4's de-elevated config-tree write and WHY it is POSIX-correct by
construction**; a pointer to the open Linux-DAC question — D-M6 kept it a separate gate before
develop→main), ADR-0050 D5/D7 (pre-validation now includes physical write capability; in-container
rename is name-only, `--move-dir` host-only refused exit 2 per D-M9/Q-5), ADR-0043 §1/§4 (the `path`
kind completes the taxonomy — annotation SUFFICES, no new ADR), ADR-0042 §8/ADR-0044 §3 (declared
but not delivered until RC-6; now delivered).

**Living docs** (rewrite to truth): `engineering/guides/testing.md` (the container-operator lane
subsection: the helpers + the single `_lane_operator_exports` source of truth; "assert an outcome,
never `rc -ne 2`"; "assert EVERY store a verb writes"; the host-shaped-absent-path topology; the
`dummy-repo` unscoped-seed masking trap; VERBATIM the CAN/CANNOT boundary from `01-test-lane.md`
§5.3; add `lib/paths.sh`, `lib/cmd-repo.sh`, `lib/store.sh` rows to the Selective Execution table),
`design-cli-environment-awareness.md` (INV-F, the three-state table, probe-vs-display),
`design-docker.md` §1.2.2/§1.2.3 (nested-config governance table role-keyed per D-M5; the two
boundary-crossing modes: whole-verb for reads, per-op plan+apply for mixed writes),
`design-resource-rename.md` (the D-M9 refusals), `agent-cco-access/design.md` §5 (the INV-S
invariants — no code outside the primitives mutates OR predicates a confined path),
`docs/users/reference/cli.md` (`config_access_policy` governs nested trees only; `--move-dir`
host-only; `path list` scoping; **and honestly**: `pack install` is an in-container refusal until
cycle 2 per D-M8/Q-10), root `CLAUDE.md` Key Files (add `lib/store.sh`).

**Changelog / backlog / roadmap:**
- `changelog.yml` — exactly **ONE grouped entry, id 46** (max is 45; verify), `type: additive`,
  dated the cutover day. Per D-M10/Q-C1 — do NOT split per root. User-visible content: store-mutating
  verbs now fail with exit 1 instead of a false success when the internal store is unwritable, and
  report the real reason instead of a spurious "not found"; `path list` output now respects access
  scope; config-editor now mounts its target repos.
- `pre-revalidation-backlog.md` — record the cycle-2 residue so the re-review does not re-discover
  it: the `-ne 0` negative-space sweep (46 sites, `01-test-lane.md` §3.5), Q-10 provenance-writer
  conversion, Q-15 the unscoped `dummy-repo` seed, the RC-5 full sweep + RC-7…RC-16, and the
  **`LLMS_DIR` taint-set minor** (RC-3 §6.5 lint blind spot; direct `$(_cco_llms_dir)` forms ARE
  caught). **Do NOT list Q-12** (D-M11 closed it in cycle 1) **or Q-11** (a §3.8 no-op, not residue).
- `docs/maintainers/roadmap.md` — flip cycle-1 to complete; keep the out-of-session gates (§7).

**THREE folded cleanups (small, verified — land with docs):**
1. `bin/test`: `--file` takes a single value (last wins), so `testing.md`'s multi-file
   Selective-Execution rows silently run only the last file. Make `--file` **accumulate**
   (repeatable) and run all named files; keep single `--file` working. Verify
   `./bin/test --file test_paths --file test_invariants` runs BOTH.
2. `tests/test_paths.sh` `test_operator_lane_boundary_seam_denies_store_read` asserts on `cat`'s
   localized `"Permission denied"` — wrong under a non-C locale. Force `LC_ALL=C` on that one `cat`;
   keep the `assert_rc 1`.
3. `tests/test_invariants.sh` `test_invariant_index_resolver_host_only` — RC-2 (04 §6.7) should have
   given `cmd-resolve.sh` a narrow ASSERTED operator-branch-shape exemption but silently omitted it.
   Add the asserted-shape exemption, or (if too brittle to assert statically) record it in the
   backlog as cycle-2. Do not leave it silently omitted.

**Cycle 1 is code-only**: no migration, no schema change, no `*_FILE_POLICIES` change, no
`defaults/global/` change. Confirm and state it. Run `./bin/test` at the end (a docs edit can move
`test_invariants`/`test_managed_scope` numbers since they hash `defaults/` — but you changed no
`defaults/`, so `failed` must stay 9; investigate if it moves).

## 6. State carried forward (accepted, triaged — not to be re-discovered)

- **Q-11 = a §3.8 no-op**, already closed by RC-2's D-M4 de-elevation (`bash -c` ruid=claude write
  of `project.yml`; `cco-svc` never writes the claude-owned tree). The residual whole-verb elevation
  covers only the STATE index re-key, which §3.8/§1.5-row-12 keep as a primitive. Not cycle-2 residue.
- **Q-12 = closed in cycle 1** by D-M11 (RC-1). Not cycle-2 residue.
- **Q-10 provenance writers = cycle 2** (D-M8/Q-10 OUT). Cycle 1 gave them a fail-fast
  `_store_provenance_guard` so `pack install` refuses up front in-container instead of losing provenance.
- **RC-3 §6.5 lint `LLMS_DIR` taint minor** = cycle-2 hardening (documented in the test header).
- **Once-WIP commit `05ab3af`** carries a stale "do not build on" label — it was built upon and
  verified. Cosmetic; an optional interactive squash could tidy it, but history-rewrite is not
  required and not worth the risk mid-branch.

## 7. Out of session reach — gates the RELEASE, not the implementation (maintainer, on the Mac)

- **`cco build` from `develop`** after cycle 1 merges — store-touching verbs exec the image-baked
  `/opt/cco/bin/cco`, so every `lib/` fix is invisible in-session until rebuilt.
- **Targeted e2e re-run**: E5/E6A/E6B for criteria D+E, E4 for F, E1–E3 only for RC-4.
- **E6B-04 `pack rename` half-apply scratch reproduction** with `-y` — 🔴 data-loss if confirmed;
  the reviewers never ran it. Reproduce on a throwaway project, pre- and post-fix.
- **Linux write-path check-in** (D-M6) before `develop → main` — the D-M4 shape is POSIX-correct by
  construction (never `fakeowner`-dependent), but the native-Linux write path is a separate gate.
- **`git push`** — both branches, from the Mac, per the established working style.
- **Do NOT** merge to `develop` until cycle 1 is green AND the maintainer has run the above.

## 8. Workflow mechanics (how the five stages were run)

- Orchestration script: `scratchpad/wf/e2e-v2-cont.js` (this session's scratchpad — **may not
  survive `/clear`**). A durable copy is at
  **`~/.claude/projects/-workspace/memory/e2e-v2-cont.js`** (machine-local). It runs ONE stage per
  launch: `Workflow({scriptPath, args:{stage:"RC-4"}})`, then `{stage:"docs"}`. It also carries a
  used `RC-3-cont` branch. Each stage = impl → adversarial-verify (git-worktree **revert-check**:
  the stage's tests must FAIL on pre-fix `lib/`) → one repair round → reverify.
- If the script is gone, re-authoring is cheap: the RC-4 and docs task text is §4/§5 above; the
  COMMON preamble + `IMPL_SCHEMA`/`VERIFY_SCHEMA` + the impl/verify/repair loop are in the durable
  copy. Or run RC-4 and docs as two direct high-effort agents with a manual revert-check.
- **`args` reaches the script as a JSON STRING** — the script `JSON.parse`s it; guard
  `typeof args === 'string'` in any new workflow.
- **Run stages one at a time** with a git + suite checkpoint between — this workstream was
  interrupted twice by session limits, and per-stage commits are what made every interruption
  recoverable.
- **Git hygiene (mandatory)**: never `git stash -u` / `git clean` / `git add -A` / `git add .`
  (the maintainer's untracked notes). Stage explicit paths only.
