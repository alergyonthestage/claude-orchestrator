# Resume Handoff — cycle-1.1, from S2b-P + S5 onward

> **Written 2026-07-21** for a fresh session (post-`/clear`). Self-contained: read this, check the
> prerequisites, review what landed, then continue. Nothing below needs re-deriving.
> Supersedes [`RESUME-HANDOFF-s4.md`](RESUME-HANDOFF-s4.md), whose §3/§4 are now history — but whose
> §6 gate list and §7 do-not-re-litigate list are still live and are restated here.
>
> **Branch**: `fix/config-access/e2e-v3-cycle1.1` (from `develop` @ `f894245`).
> **Tip**: `d821815`. **Suite**: **1428 passed / 9 failed** — the 9 are the pre-existing host-only
> artifacts (FI-19), verified identical on a pristine HEAD checkout of the touched files. NOT
> regressions.
> **Nothing is pushed.** Push and `develop → main` are maintainer-side and gated (§8).

## 0. First actions in the new session (in order)

1. **Retrieve context**: this handoff → memory `[[e2e-v3-cycle11]]` → `00-plan.md` §1 (stage table)
   and §6 (S5's design) → `engineering/analysis/false-success-class-audit.md` §5 (why primitives
   come before call sites).
2. **Check prerequisites** (§2). The tree is the ground truth, not this doc.
3. **Read §4 before touching S5** — the stage order below **departs from `00-plan.md` §1**, on a
   finding made while planning it. The reason is in §4; do not silently revert to the plan's order.
4. **Implement S2b-P** (§5), then **S5** (§6). Each stage: impl → adversarial revert-check → (one
   repair round) → reverify → commit. That is how S1–S4 were run and it is what makes the guards
   trustworthy.

## 1. Canonical reading order

**This workstream:**
- `00-plan.md` — the staged plan. §1 stage table with live status; **§2.1 is mandatory before
  touching mount generation**; **§3b** is S2b's design; **§6** is S5's; §10 the out-of-session gates.
- `engineering/analysis/false-success-class-audit.md` — the codebase-wide audit of the
  false-success class. **§5 is the load-bearing part**: fixing call sites before primitives yields an
  audit that reads as closed while the defect persists.
- `../results/consolidated-review-v3.md` — the verdict, roots **R1…R7**, the findings→RC→ADR map
  (§5), the ratified **D-V3-1** (§3), and §6 the process findings for a future v4 matrix.
- `../handoff-v3.md` §8 — the acceptance criteria **B/C/D/E/F/G** the eventual re-review re-runs.

**The settled model — ADRs (history; formalize, never re-litigate):** ADR-0042, **0043**, 0044,
**0046**, **0047** (the privilege boundary), 0048, **0049**, 0050, 0051. Cycle-1 fixes are
forward-annotated into each; read the annotation, not just the original.

**Living docs these fixes keep true:** `design-docker.md` §1.2.2, `design-cli-environment-awareness.md`,
`../../design.md` §5, `design-resource-rename.md`, `cli.md` (S5 changes it — remote verbs go host-only).

## 2. Prerequisites to verify before writing code

```bash
cd /workspace/claude-orchestrator
git branch --show-current      # expect fix/config-access/e2e-v3-cycle1.1
git log --oneline -6           # expect d821815 at the tip
git status --short             # expect ONLY: M .cco/project.yml, ?? tmp, ?? to-verify-guides-docs.md
./bin/test 2>&1 | tail -3      # expect 1428 passed / 9 failed
```

⚠ **The three working-tree entries are the maintainer's and must never be touched**: the
`.cco/project.yml` modification is their port edit (8081→8082), and `tmp` /
`to-verify-guides-docs.md` are their untracked notes. **Never `git stash -u`, `git clean`, or
`git add -A`** — a previous session nearly destroyed them.

⚠ **The suite runner is `./bin/test [--file <name>]`.** Running `bash tests/<file>.sh` directly is a
**false green**: the test files are function libraries sourced by `bin/test`, so run alone they exit
0 having executed nothing.

⚠ **Store-touching verbs run the IMAGE-BAKED `cco`** (`/opt/cco`), not the working tree, so `lib/`
edits are invisible in-session until a `cco build`. Verify behaviour through the test suite, not by
running `cco` in this session. (S4 confirmed this the hard way: `cco path list` in-session read the
live store and ignored every working-tree edit.)

⚠ **To prove a failure set is pre-existing**, back the touched files up, `git checkout --` **only
those paths**, run, then restore from the backup. Never `git stash`.

## 3. What landed — review this before extending it

| Stage | Commit | What it does |
|---|---|---|
| **S1** | `517014b` | STATE crosses the ADR-0047 boundary via a **`state/cco/shared/` directory bind** instead of individual file binds. `_cco_state_shared_dir()` in `paths.sh`; index + pack/template update sidecars re-homed; `cmd-start.sh` binds the one directory; `entrypoint.sh` pre-chowns the per-bucket parents to `cco-svc`; migration **`017`**. `INV-STATE` pins the allow-list `{shared, running}`. |
| **S2** | `4aefc2f` | `_index_mktemp` fails loudly and names the cause; `_index_ensure_file` and `_index_rename_path` propagate; `cmd-repo.sh` dies naming **which** store already changed. `INV-IDX` lints bare index writes in container-reachable modules; `T-R2` is the behavioural guard. V3-P shipped here. |
| **S3** | `582347d` | `_rename_assert_index_writable` — the fail-closed pre-flight probes **both** stores, so the rename refuses before Phase 1. |
| **S4** | `501567b` | Read-path honesty. `_index_read_state` (ok\|absent\|unreadable\|truncated\|stale) + `_index_assert_readable` fail-closed entry guard + one shared sentence, on four call sites (`path list`, `cco list projects`, compact `cco list`, `cco config validate`). |

**Four things to understand before changing any of it:**

1. **The STATE allow-list is fail-safe by construction and must stay that way** (`00-plan.md` §2.1).
   Two v3 sessions recommended binding `state/cco` whole; that mounts the 0600 `remotes-token`,
   transcripts and memory into every session and flips the boundary to fail-open. To expose
   something new to sessions, **move it under `shared/`** — never widen the mount.
2. **Errexit is not available in command bodies.** `bin/cco:657-658` dispatches as
   `cmd_repo "$@" || _cco_rc=$?`, and a `||` context disables `set -e` for the entire call tree.
   Explicit `||` / `if !` propagation is the only mechanism that works. This constrains every stage
   below and is why S2 is an invariant rather than a patch.
3. **`die` inside a process substitution exits only the subshell.** S4 hit this: the guard was first
   placed in `_list_collect`, which `cmd_list` consumes via `< <(…)`, so the loop would have carried
   on at rc=0 — the very shape being closed. **Guards belong in the parent shell, at verb entry.**
   Check the call context of any function you add a `die` to.
4. **S3's two probes use OPPOSITE identities, deliberately.** project.yml is written de-elevated to
   ruid=claude (D-M4) → probe via `_rename_deelevated`; the index is written at euid=cco-svc (the
   verb trampolines wholly) → probe with a plain `mktemp`. Swapping them refuses every legitimate
   rename, or passes on a tree the write cannot touch.

## 4. ⚠ The stage order below DEPARTS from `00-plan.md` §1 — read this first

`00-plan.md` orders **S5 before S2b**, on the ground that S5 keeps an acceptance criterion red while
S2b blocks nothing. The plan's own stage table nonetheless flags *"S5 depends on the token
primitive"*. That tension was resolved on 2026-07-21 by reading the code, and it resolves **against**
the plan's order. Three findings, in increasing severity:

**(a) S5 does not need the primitive for its own correctness.** All four of S5's work items
(`bin/cco` refusal, the bucket list, the dup-check message, the R5 refusal split) are independent of
whether `_remote_token_set` can report failure. The dependency in the plan is real but is *not* of
the form "S5 breaks without it".

**(b) S5 makes the defect invisible to the acceptance matrix.** After D-V3-1, `remote remove|rename`
run **only on the host**. The v3/v3.1 e2e sessions all run in-container. So the silent token-orphan
stops being reachable by any probe in the matrix that would catch it, while remaining fully live for
the user on the host.

**(c) — the decisive one — S5's work item 2 REMOVES A GUARD that is currently the only thing
standing over a live host write path.** `00-plan.md` §6.2 item 2 says to drop `remote-drop` /
`remote-rekey` from the STATE entry of `_store_op_buckets` (`lib/store.sh:137-140`) because *"they no
longer run in-container"*. That premise is true and the conclusion does not follow:

- `_cco_remotes_token_file` is `$(_cco_state_dir)/remotes-token` — the STATE **root**, deliberately
  NOT under `shared/` (S1 left it there; 0600 auth never crosses).
- On the host, `cco remote remove|rename` still go through `_store_check` → `_store_apply` →
  `_store_do_remote_drop` / `_store_do_remote_rekey` (`cmd-remote.sh:196,230,257,270`), and **those
  cascades still write STATE** via `_remote_token_remove` / `_remote_token_set`.
- So the ops keep touching the STATE root on the host. Dropping it from the probe list removes the
  (coarse) pre-flight over that root **while the primitive underneath still cannot report its own
  failure**. Net effect: a strictly wider silent-failure window on the host.

**Therefore: fix the token primitives FIRST, then land S5.** With the primitive able to fail, item 2
becomes safe — the cascade reports its own failure and no longer leans on a root probe.

> **Do NOT read this as "do all of S2b first".** The slice that must precede S5 is exactly the two
> **token primitives**. The rest of S2b (`_yaml_rename_list_ref`, `cmd-join.sh`/`cmd-init.sh`, the
> remaining `_index_*` modules) stays where the plan put it, after S5/S6. The reorder is surgical
> and minimal on purpose, so it stays justifiable.

**Also reconcile while in there:** `lib/store.sh:136-139` already carries the comment *"Both verbs
are host-only in-container (D-V3-1, bin/cco)"* — written in anticipation — while `bin/cco:403` still
routes `remove|rename` through `_op_write`. The comment is **ahead of the code**, so a reader today
would believe D-V3-1 shipped. S5 closes the gap; until it does, treat that comment as a promise, not
a fact.

## 5. S2b-P — the token primitives (first task)

Design: `00-plan.md` §3b work item 1 + `false-success-class-audit.md` §5. Scope: **two functions.**

**`_remote_token_set` (`lib/cmd-remote.sh:16-27`)** — cannot fail. Its tail statement is
`if ! chmod 600 "$tf" 2>/dev/null; then warn …; fi`, which yields 0 on both branches, so the function
**always returns 0**. This voids the correctly-written `store.sh:370` `_remote_token_set "$new" "$tok" || return 1`.
Three unchecked writes inside it, all of which must propagate:
- the dedup branch's `mktemp` / `grep` / `mv` trio,
- the `echo "${name}=${token}" >> "$tf"` append,
- `mkdir -p "$(dirname "$tf")"`.

**`_remote_token_remove` (`lib/cmd-remote.sh:30-37`)** — bare `mktemp`/`grep`/`mv`, then an explicit
`return 0`. This voids `cmd-remote.sh:295`'s `if ! _remote_token_remove`.

⚠ **Keep the existing return-1-means-absent contract.** `_remote_token_remove` currently returns 1
for *"no token existed"*, and `_cmd_remote_remove_token` renders that as `die "No token found…"`.
A write failure must be **distinguishable** from that, not folded into it — otherwise a failed
removal reports "no token found", which is a *new* lie in place of the old one. Either a distinct
exit code or a `die` from inside the primitive; decide and record it.

⚠ **`_store_do_remote_drop` treats an absent token as a valid no-op** (`store.sh:355`,
`_remote_token_remove "$name" 2>/dev/null || true`). That stays correct — but once the primitive can
distinguish absent from failed, this line must stop swallowing the failure case.

**Guard to write**: a token store made unwritable → the verb exits non-zero, no success tick, the
message names the token store, and the registry is provably unchanged. Model it on `T-R2`
(`tests/test_repo_rename.sh:395`). Revert-check it: on the pre-fix primitive it must report success.

**Then widen the audit's tracking** — mark these two closed in
`false-success-class-audit.md` so the report tracks the work rather than documenting a permanent
exemption.

## 6. S5 — D-V3-1 + the truthful store refusal (second task)

Design: `00-plan.md` §6. Four work items:

1. **`bin/cco:403`** — split `remove|rename` out of the `_op_write "remote $sub" global` line into a
   refusal in the existing family (*"secrets stay off the container"*), exit **2**, not 1.
   `remote add` stays functional (DATA-only).
2. **`lib/store.sh:137-140`** — drop `remote-drop`/`remote-rekey` from the STATE bucket entry.
   **Only after §5 has landed** (see §4(c)), and update the anticipatory comment to describe what is
   then actually true.
3. **V5-03** — `cmd-remote.sh`'s dup-check says *"Remove it first with `cco remote remove <name>`"*,
   a command that is now host-only. Make it name the **host** remedy.
4. **R5 / V5-02** — `lib/store.sh:243-245` collapses two conditions into one string
   (*"the store is not writable in this session"*), demonstrably false at `edit-all` where `whoami`
   says rw and `pack create` works. Split it:
   - **scope refusal** — the session's triple does not grant `G=rw` → exit **2**, name the axis;
   - **not bound in this container** — the bucket is not mounted → D-M2's *"not mounted in this
     session"* vocabulary + a host remedy. **Reuse the string `project validate` already speaks;
     do not write a fourth spelling** — that is the R4 class this cycle is also fixing, and S4 added
     `_index_unreadable_sentence` to the shared-vocabulary set, so check there first.

**S3 defers to this**: if item 4 lands on exit 1 for "bucket not writable", move
`_rename_assert_index_writable` and its sibling onto the same convention together.

## 7. Remaining stages, in the recommended order

| Stage | Why here | Design |
|---|---|---|
| **S2b-P** | unblocks S5's item 2 safely; see §4 | §3b item 1 |
| **S5** | D-V3-1 + the truthful store refusal; keeps criterion B red until done | §6 |
| **S6** | one predicate, one spelling: `cmd-project-query.sh:192` bypasses the shared resolver. Three v3 sightings, one call site. Also V1-F1. Add the lint: **no verb may spell an availability state locally** | §7 |
| **S2b** (rest) | `_yaml_rename_list_ref` (closes S1–S3's acknowledged residual gap — the project.yml half of `repo rename`), then `cmd-join.sh`/`cmd-init.sh` (their damage escapes the machine), then the remaining `_index_*` modules. Widen `INV-IDX`'s `scoped` list as each closes | §3b + the audit |
| **S7** | config-editor announces every drop; includes a **decision** (does config-editor mount a target's `extra_mounts`? recommendation: no, but announce) | §8 |
| **S8** | minor + doc debt | §9 |
| **S9** | changelog **47**, ADR forward-annotation (ADR-0047 gains the STATE allow-list + D-V3-1), living-doc sweep (`cli.md` — remote verbs host-only), migration checklist per `.claude/rules/update-system.md` | §11 |

## 8. Out-of-session gates (maintainer, on the Mac) — unchanged

1. **`cco remote remove v5probe`** — V5 left a registry entry it could not remove. Unrelated to the
   fix, but the store is currently grown by one. **Do this before S5 lands**, or it becomes a
   host-only cleanup you cannot do from a session at all.
2. `cco build` from the cycle-1.1 tip, then **re-run V3 and V5**. V1/V2/V4 need no re-run — except
   see gate 7.
3. **V4b** — the D-M11 escalation test. Highest value of the remaining runs: every other v3 probe
   fails *safe* if the fix is wrong; this one fails **open**.
4. **V5b** — bare global `(rw,none,none)`.
5. **§7 / E6B-04** — the pack-rename fan-out atomicity gate, still never executed, now unblocked by
   S1. Substrate already exists: `cave-core` is referenced by two mounted projects.
6. **D-M6 Linux write-path check-in — a HARD gate.** macOS `fakeowner` makes the fail-closed
   pre-validation unfalsifiable (V3-02 ran `chmod 500 .cco && mktemp .cco/.x.XXXXXX` and it
   **succeeded**), so criterion F cannot be signed off from a macOS run.
7. **NEW (S4)** — the `stale` arm (nlink 0) cannot be synthesized without a real mount, so its
   hermetic test mocks `stat` on PATH. The kernel side rides the **V2 re-run**: re-check that a
   stranded index now fails loud instead of reporting 0 rows at rc=0.

## 9. Do not re-litigate

RC-4 (confirmed on both halves across three projects, discriminating against both rejected
implementations), RC-1's D-M5 arms, RC-6 repos, the ADR-0047 boundary, criterion E, and
`lib/store.sh`'s fail-closed contract. The standing triage rule from V5's note 2: **"fix the mount +
fix the message, not reconsider RC-3."**

**Settled by S4, do not re-open:** `absent` is benign while `truncated` is diagnostic (a real index
is never 0 bytes); the retired-`cco resolve` rule is **contextual, not a ban** (the host arm keeps
it — deleting the phrase everywhere fails the guard); V2-F03's detector belongs at verb entry, not
in `cco whoami` (which declares no filesystem probing and runs de-elevated, so it cannot reach the
index behind the ADR-0047 boundary without a `store-op` crossing).

**Out of scope** — everything `handoff-v3.md` §9 defers: the RC-5 vocabulary sweep, RC-7…RC-16,
Q-10 provenance writers, FI-21/22/23, E4-02/RC-16 mis-ownership, and **FI-24** (the update engine,
`pack`/`template publish`, the local-destructive set). Two findings sit adjacent to cycle-2 and are
pulled **in** deliberately, on D-M2 rule 3: **S6** and **S8**'s Q-C3 line if free.

**Open by decision, not residue:** D-M8's **Q-11** — routing `_index_rename_path` through a
`store-op` crossing. S3 delivers the same guarantee via the cheaper shape; Q-11 remains a larger
refactor of a write path S1+S2 had just rewritten.
