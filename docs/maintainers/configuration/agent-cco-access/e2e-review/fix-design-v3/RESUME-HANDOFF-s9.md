# Resume Handoff — cycle-1.1, S9 (the last stage)

> ## ✅ CONSUMED 2026-07-21 — S9 landed (`fcfe058` + `55dee32`). Cycle-1.1 implementation is CLOSED.
>
> **There is no S10 and no successor handoff**, because nothing that remains can be done from a
> session. Read the sections below for the cycle's history and its do-not-re-litigate list — but for
> *what to do next*, go to:
>
> - **[`00-plan.md` §6.-1](00-plan.md)** — the **three** host-only `.claude`-payload patches, with
>   verbatim replacement text. §4 below predicted one; the S9 sweep found two more.
>   ⚠ **Apply them BEFORE `cco build`**, or the rebuilt image bakes a managed rule that *prescribes*
>   a verb D-V3-1 refuses.
> - **[`00-plan.md` §10](00-plan.md)** and §5 below — the out-of-session gates. ⚠ Gate 7 (the
>   provenance **value**) runs **first**: it is what makes every other result attributable.
> - **`docs/maintainers/roadmap.md` → B2** — the same list in release terms, plus the merge sequence.
>
> S9's own outcome is recorded in `00-plan.md` §11. The one lesson worth carrying: **a doc sweep's
> file list is a lower bound.** §11 named five living docs; three needed nothing (already written by
> S5/S7/S8 — verified before editing, not assumed) and three surfaces it did *not* name did. The
> sharpest was the second managed-rule spot: §6.-1 knew the rule under-reported the host-only set,
> but the same file's "editing config" bullet *prescribes* `cco remote remove` — so the rule injected
> into every session recommends the refused verb. That is S8's false-remedy lesson one document out,
> and it is why patches 1 and 2 must land as a single edit.
>
> Suite at close: **1463 passed / 9 failed**, baseline names identical. Nothing pushed.

> **Written 2026-07-21** for a fresh session (post-`/clear`). Self-contained: read this, check the
> prerequisites, review what landed, then continue.
> Supersedes [`RESUME-HANDOFF-s8.md`](RESUME-HANDOFF-s8.md) (whose §3 = S8 is now history), and with
> it `-s7` / `-s6` / `-s5` / `-s4`.
> The gate list (§5) and the do-not-re-litigate list (§6) are carried forward and restated here —
> still live.
>
> **Branch**: `fix/config-access/e2e-v3-cycle1.1` (from `develop` @ `f894245`).
> **Tip**: `a1e4c5e` + the S8 docs flip. **Suite**: **1463 passed / 9 failed** — the 9 are the
> pre-existing host-only artifacts (FI-19), names verified identical to baseline. NOT regressions.
> **Nothing is pushed.** Push and `develop → main` are maintainer-side and gated (§5).

## 0. First actions in the new session (in order)

1. **Retrieve context**: this handoff → memory `[[e2e-v3-cycle11]]` → `00-plan.md` §11 (S9's design)
   and §9 (what S8 just landed, including what it deliberately did NOT fix).
2. **Check prerequisites** (§1). The tree is the ground truth, not this doc.
3. **S9 is the docs/release stage** — but it is not clerical: it has a **host-only part** (§4) and
   it must decide what S7's and S8's user-visible behaviour changes mean for the user docs.
4. S9 closes the cycle. After it, everything remaining is a §5 gate on the Mac.

## 1. Prerequisites to verify before writing anything

```bash
cd /workspace/claude-orchestrator
git branch --show-current      # expect fix/config-access/e2e-v3-cycle1.1
git log --oneline -8
git status --short             # expect ONLY: M .cco/project.yml, ?? tmp, ?? to-verify-guides-docs.md
./bin/test 2>&1 | tail -3      # expect 1463 passed / 9 failed
```

⚠ **The three working-tree entries are the maintainer's and must never be touched**: the
`.cco/project.yml` modification is their port edit (8081→8082), and `tmp` /
`to-verify-guides-docs.md` are their untracked notes. **Never `git stash -u`, `git clean`, or
`git add -A`** — a previous session nearly destroyed them. Stage with explicit paths.

⚠ **The suite runner is `./bin/test [--file <name>]`**, and `--file` takes the file's BASE NAME
including the prefix (`--file test_join`, not `--file join`) — a wrong name runs **0 tests and
still prints a green summary**. Running `bash tests/<file>.sh` directly is likewise a false green.

⚠ **Store-touching verbs run the IMAGE-BAKED `cco`** (`/opt/cco`), not the working tree. Verify
through the suite, not by running `cco` in this session. (S8 added a way to *see* this: once the
image is rebuilt, `cco whoami` reports `image built from: <branch>@<sha>`.)

⚠ **Run the full suite ALONE and capture FAIL NAMES, not just the count.** Grep for `FAIL` loosely
— an `^\[FAIL\]` anchor missed three of the nine in one S7 run. The baseline set is: 6× `test_as_*`,
`test_paths_symlink_safe_tool_root`, `test_update_new_file_added`, `test_update_dry_run`.

## 2. What landed — review this before extending it

| Stage | Commit | What it does |
|---|---|---|
| **S1** | `517014b` | STATE crosses via a **`state/cco/shared/` directory bind**. Migration `017`. `INV-STATE`. |
| **S2** | `4aefc2f` | `_index_mktemp` fails loudly; callers propagate. `INV-IDX` lint + `T-R2` guard. |
| **S3** | `582347d` | `_rename_assert_index_writable` — fail-closed pre-flight, both stores, each at its own identity. |
| **S4** | `501567b` | Read-path honesty: `_index_read_state` (ok\|absent\|unreadable\|truncated\|stale). |
| **S2b-P** | `2177858` | The two **token primitives** can fail. `_remote_token_remove`: `0`/`1`/**`2`**. |
| **S5** | `9e2496d` | **D-V3-1**: `remote remove\|rename` host-only. Truthful dup-check + store refusal. |
| **INV-S3b** | `2f2b560` | The store/rename **exit-code taxonomy**, unified. |
| **S6** | `987e38b` | **R4 + V1-F1**: shared classifier + shared WORKDIR-root fallback. `INV-ENV` lint. |
| **S2b** | `be1032c` `cf9a3e5` `578e755` | The unchecked-write class **closed** across every module. |
| **S7** | `097ef61` | config-editor **announces every drop**; decision **(b)** on a target's extra_mounts. |
| **S8** | `8843680` `221d8fb` `16a129b` `535a99b` `a1e4c5e` | Minor findings + doc debt — see below. |

**S8 in detail** (all five items; V3-P had already shipped in S2):

- `8843680` **V4-F-V4-04** — D-M9's Q-8 clause annotated stale (the impl re-overlays `:ro` and is
  strictly safer); D-M11's precedent followed.
- `221d8fb` **V4-F-V4-03** — a **projects-only** hidden notice now offers `read-all`, not
  `read-global` (which reveals no project). Mixed sets keep both — a converse guard pins that.
- `16a129b` **V3-03** — Q-6's ambiguity refusal made reachable at the WORKDIR root. Exit **1**, not
  2, and INV-S3b is untouched (see below).
- `535a99b` **V1-F2** — `cco project show` lists extra_mounts by **logical name**, `[unresolved]`
  when unbound. `cli.md` updated in the same commit.
- `a1e4c5e` **V1-F3** — `/opt/cco/BUILD` baked (`<branch>@<shortsha>`), surfaced by `cco whoami`.

**Five things to understand before changing any of it:**

1. **The STATE allow-list is fail-safe by construction** (`00-plan.md` §2.1). To expose something
   new, **move it under `shared/`** — never widen the mount.
2. **Errexit is not available in command bodies** (`cmd_foo "$@" || _cco_rc=$?` disables `set -e`
   for the whole call tree), and **`die` inside a process substitution exits only the subshell**.
   Explicit propagation, and guards in the parent shell at verb entry.
3. **INV-S3b governs STORE pre-flights**, and S8 did **not** extend it. Its axis is
   pre-flight-vs-write × session-vs-host, for refusals whose remedy is "run it on the host". V3-03's
   ambiguity die is a **usage** fact, fixable in-session by cd'ing → exit 1, like every other usage
   die in that engine. Do not "unify" the two.
4. **INV-ENV is a budgeted allow-list, not a flat ban**, and `cmd-resolve.sh`'s local `read-all` is
   the **correct** one. S8's V4-F-V4-03 was kept deliberately separate from any INV-ENV tightening.
5. **`INV-F`: never existence-test an index path directly** — `_cco_member_probe_path` is the single
   source. This is exactly what makes **FI-26** (below) a design pass rather than an edit.

**The three lessons that generalise past this cycle.** S2's: its primitive already printed the right
error loudly and the verb **still exited 0 with a ✓** — *the defect was never the message, it was the
discarded status.* S7's, one layer out: **a fix at a site that cannot execute is indistinguishable
from a fix, until something makes it run.** S8's is the same axis, inverted: **a remedy that points
at an action which cannot succeed from where the message is printed is a fix that reads correct and
strands the reader.** V3-03's message deliberately does not advise the 2-arg form for that reason,
and a guard pins it.

## 3. S9 — the remaining stage

Design: `00-plan.md` §11. Four parts.

| Part | What |
|---|---|
| **changelog 47** | One grouped entry for cycle-1.1, following cycle-1's id-46 shape (D-M10/Q-C1). ⚠ **Must cover S8's two user-visible additions** (`project show` extra_mounts, and build provenance in `whoami`) — `.claude/rules/update-system.md` classifies both as additive. Also S5's `remote remove\|rename` host-only (a **behaviour change** a user will hit), S7's config-editor announcements, and S1's migration 017. |
| **ADR forward-annotation** | Append-only, per `documentation-lifecycle.md`. **ADR-0047** gains the STATE allow-list refinement (S1) + **D-V3-1** (S5) + **INV-S3b**. **ADR-0045** is unaffected (`running/` keeps its own `:ro` bind). |
| **Living-doc sweep** | `design-docker.md` §1.2.2, `02-mount-generation.md`, `05-store-write-path.md`, `03-config-editor-repos.md` §3.9, `cli.md` (remote verbs host-only). ⚠ `cli.md`'s `project show` flow is **already done** (S8). ⚠ **S7's decision (b) is user-visible** — check whether `cli.md` and the config-editor built-in docs need it stated, not just the design doc. |
| **Migration checklist** | Per `.claude/rules/update-system.md`. Migration **017** already exists (S1). Verify no OTHER migration is owed: S8 added no schema change and no `*_FILE_POLICIES` entry, so the answer is probably "none" — but S3/S4/S5/S2b should be re-checked against the checklist rather than assumed. |

## 4. ⚠ Carried debt that a SESSION CANNOT CLOSE

**The managed rule** `defaults/managed/.claude/rules/cco-config-interaction.md` must add
`remove|rename` to its host-only verb list (S5/D-V3-1). Until it does, the rule injected into every
future session under-reports the host-only set. **Exact patch in `00-plan.md` §6.-1.**

Every `.claude` tree is clamped `:ro` in a session, including `defaults/managed/.claude/`. Why is a
finding in its own right — **`FI-25`** in `roadmap-backlog.md`.

**Two ways to close it**: apply the patch on the host, or run a self-dev session with
`--claude-access all` (FI-25 option (d)). **S9 must check for any other `defaults/**/.claude/` or
`templates/**/.claude/` edit this cycle needs and route it the same way** — the config-editor
built-in docs named in §3 may well live there.

## 5. Out-of-session gates (maintainer, on the Mac)

1. **`cco remote remove v5probe`** — V5 left a registry entry it could not remove. **Do this before
   the next `cco build`**: after it, S5's refusal is live and the cleanup is host-only for good.
2. `cco build` from the cycle-1.1 tip.
3. **NEW (S8/V1-F3) — verify the provenance VALUE.** `cco whoami` → `image built from:` must read
   the cycle-1.1 branch and tip sha, and match what you built. Do this **before** the re-runs: it is
   what makes their results attributable, and it is the exact failure that voided v2's cycle-0.
4. Re-run **V3** and **V5**. V1/V2/V4 need no re-run — except gate 8.
5. **V4b** — the D-M11 escalation test. Highest value of the remaining runs: every other v3 probe
   fails *safe* if the fix is wrong; this one fails **open**.
6. **V5b** — bare global `(rw,none,none)`.
7. **§7 / E6B-04** — the pack-rename fan-out atomicity gate, still never executed, now unblocked by
   S1. Substrate exists: `cave-core` is referenced by two mounted projects.
8. **D-M6 Linux write-path check-in — a HARD gate.** macOS `fakeowner` makes the fail-closed
   pre-validation unfalsifiable (V3-02), so criterion F cannot be signed off from a macOS run.
   ⚠ **S2b widened what this covers**: every guard it added is a `chmod`-driven unwritable-bucket
   test, so the caveat applies to all of them.
9. **From S4** — the `stale` arm (nlink 0) cannot be synthesized without a real mount, so its
   hermetic test mocks `stat`. The kernel side rides the **V2 re-run**.
10. **From S5** — re-check that `cco remote remove|rename` refuse at exit 2 with the host hint, and
    that `cco remote add` still works.
11. **From S2b** — the host-only verbs it touched (`join`, `init`, `forget`, `project import`,
    `resolve --scan`, `path set`, `migrate`) now die where they used to continue. One live
    happy-path run of each: the suite covers the failure arms, the success arms are the daily path.
12. **From S7** — `cco start config-editor --all` on the real store (the 8-project set V5 used):
    every project the index knows is either mounted **or** announced, and the two remedies land on
    the right projects (`cco init` vs `cco resolve`). Also confirm a target with `extra_mounts:`
    announces them and mounts none.
13. **NEW (S8/V1-F2)** — `cco project show <a project with extra_mounts>` in a session: names,
    targets, and the `[unresolved]` arm. Cheap, and it is the surface gate 12's announcement now
    points people at.

## 6. Do not re-litigate

RC-4, RC-1's D-M5 arms, RC-6 repos, the ADR-0047 boundary, criterion E, and `lib/store.sh`'s
fail-closed contract. The standing triage rule from V5's note 2: **"fix the mount + fix the message,
not reconsider RC-3."**

**Settled by S4:** `absent` is benign while `truncated` is diagnostic; the retired-`cco resolve` rule
is **contextual, not a ban**; V2-F03's detector belongs at verb entry, not in `cco whoami`.

**Settled by S2b-P/S5/INV-S3b:** `_remote_token_remove`'s three-valued contract; `chmod` failure
stays a `warn` because the token IS persisted; D-V3-1's scope (`remote add` stays in-session); and
**INV-S3b**, decided with the maintainer after two wrong attempts — the discriminator is
pre-flight-vs-write crossed with session-vs-host, **not** the module.

**Settled by S6:** `INV-ENV`'s five ratified exceptions each own a *different* predicate.
`cmd-resolve.sh`'s local `read-all` is **right**; the shared notice was the stale one.

**Settled by S2b:** `lib/index.sh` stays outside `INV-IDX` (tail position IS the propagation); the
sibling "helper whose tail cannot return non-zero" lint is retired with it; `cco resolve --scan`
counts failures instead of dying on the first.

**Settled by S7:** decision **(b)** — config-editor never mounts a target's `extra_mounts`, and
announces them. `_project_foreach` stays silent and config-editor computes its own
declared-vs-effective diff.

**Settled by S8 (maintainer, 2026-07-21):** all three judgement calls were put as options and
decided — **move** the V3-03 guard (not record-only), **take** V1-F2 in this cycle, **take**
V4-F-V4-03 here rather than in cycle-2. Also settled: V3-03's exit code is **1** and does not touch
INV-S3b; V1-F2 reads the declarative source rather than `_effective_extra_mounts`.

**Out of scope** — everything `handoff-v3.md` §9 defers: the RC-5 vocabulary sweep, RC-7…RC-16,
Q-10 provenance writers, FI-21/22/23, E4-02/RC-16 mis-ownership, **FI-24** (the update engine),
**FI-25** (the self-dev `.claude` clamp), and **FI-26** (new — see below).

**Open by decision, not residue:** D-M8's **Q-11** — routing `_index_rename_path` through a
`store-op` crossing. S3 delivers the same guarantee via the cheaper shape.

## 7. New finding recorded this stage

**FI-26** (`roadmap-backlog.md`) — `repo`/`extra-mount rename` resolves `$unit` from cwd via
`_resolve_find_unit_dir`, so in a session it runs **only from the hosting repo's mount**. The
fully-specified 2-arg form dies at the WORKDIR root advising the user to pass `<old> <new>`, which
they just did. S8's V3-03 fixed the **bare** form's diagnosis (what Q-6 governs) and deliberately
left this: the fix means resolving `$unit` from the SESSION's project, which requires routing
`_resolve_unit_dir_for_project` through `_cco_member_probe_path` (INV-F) inside a fail-closed
pre-flight. ⚠ `_resolve_find_unit_dir` has **nine** other callers — enumerate them before designing;
`project show`/`project validate` already route around it via `_project_session_fallback` (S6/R4),
which is evidence the gap is being closed piecemeal. **Not gating** cycle-1.1.
