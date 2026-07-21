# Resume Handoff — cycle-1.1, from S6 onward

> **Written 2026-07-21** for a fresh session (post-`/clear`). Self-contained: read this, check the
> prerequisites, review what landed, then continue.
> Supersedes [`RESUME-HANDOFF-s5.md`](RESUME-HANDOFF-s5.md) (whose §5/§6 are now history) and
> [`RESUME-HANDOFF-s4.md`](RESUME-HANDOFF-s4.md). The gate list (§7) and the do-not-re-litigate list
> (§8) are carried forward and restated here — they are still live.
>
> **Branch**: `fix/config-access/e2e-v3-cycle1.1` (from `develop` @ `f894245`).
> **Tip**: `2f2b560`. **Suite**: **1434 passed / 9 failed** — the 9 are the pre-existing host-only
> artifacts (FI-19), names verified identical to baseline. NOT regressions.
> **Nothing is pushed.** Push and `develop → main` are maintainer-side and gated (§7).

## 0. First actions in the new session (in order)

1. **Retrieve context**: this handoff → memory `[[e2e-v3-cycle11]]` → `00-plan.md` §1 (stage table)
   and §7 (S6's design).
2. **Check prerequisites** (§1). The tree is the ground truth, not this doc.
3. **Implement S6** (§3). Then S2b (rest) / S7 / S8 / S9 per the order in §4.
4. Each stage: impl → **adversarial revert-check** → (one repair round) → reverify → commit. That is
   how S1–S5 were run and it is what makes the guards trustworthy.

## 1. Prerequisites to verify before writing code

```bash
cd /workspace/claude-orchestrator
git branch --show-current      # expect fix/config-access/e2e-v3-cycle1.1
git log --oneline -6           # expect 2f2b560 at the tip
git status --short             # expect ONLY: M .cco/project.yml, ?? tmp, ?? to-verify-guides-docs.md
./bin/test 2>&1 | tail -3      # expect 1434 passed / 9 failed
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
running `cco` in this session.

⚠ **To prove a failure set is pre-existing**, back the touched files up, `git checkout --` **only
those paths**, run, then restore from the backup. Never `git stash`.

⚠ **Run the full suite ALONE and capture FAIL NAMES, not just the count.** S5 learned this the hard
way — see §2's lessons.

## 2. What landed — review this before extending it

| Stage | Commit | What it does |
|---|---|---|
| **S1** | `517014b` | STATE crosses via a **`state/cco/shared/` directory bind** instead of file binds. Migration `017`. `INV-STATE` pins the allow-list `{shared, running}`. |
| **S2** | `4aefc2f` | `_index_mktemp` fails loudly; `_index_ensure_file`/`_index_rename_path`/`cmd-repo.sh` propagate. `INV-IDX` lint + `T-R2` guard. |
| **S3** | `582347d` | `_rename_assert_index_writable` — the fail-closed pre-flight probes **both** stores, each at its own identity. |
| **S4** | `501567b` | Read-path honesty: `_index_read_state` (ok\|absent\|unreadable\|truncated\|stale) + `_index_assert_readable`, on four call sites. |
| **S2b-P** | `2177858` | The two **token primitives** can now fail. `_remote_token_remove`: `0` removed / `1` absent / **`2` failed**. |
| **S5** | `9e2496d` | **D-V3-1**: `remote remove\|rename` host-only. STATE-root probe dropped. Dup-check + store refusal now truthful. |
| **INV-S3b** | `2f2b560` | The store/rename **exit-code taxonomy**, unified. |

**Five things to understand before changing any of it:**

1. **The STATE allow-list is fail-safe by construction and must stay that way** (`00-plan.md` §2.1).
   To expose something new to sessions, **move it under `shared/`** — never widen the mount.
2. **Errexit is not available in command bodies.** `bin/cco` dispatches as `cmd_foo "$@" ||
   _cco_rc=$?`, and a `||` context disables `set -e` for the entire call tree. Explicit `||` / `if !`
   propagation is the only mechanism that works.
3. **`die` inside a process substitution exits only the subshell.** Guards belong in the parent
   shell, at verb entry. Check the call context of any function you add a `die` to.
4. **`_remote_token_remove`'s third exit code is load-bearing.** Callers that tolerate absence must
   test `-le 1`, never `|| true` — folding a failed removal into `1` reports a revocation as
   complete on a credential still on disk.
5. **INV-S3b — read it in `lib/store.sh`'s header before touching any refusal exit code.**
   `in-session pre-flight → 2` · `host pre-flight → 1` · `write that started and failed → 1`.
   ⚠ Do **not** re-derive it from D8 alone ("session shape → 2") nor INV-S3 alone ("store failure →
   1"): each is half the rule. S5 shipped the wrong code by applying only the first.

**Two process lessons from S5 — they cost a full debug cycle:**

- **Enumerate test files, never guess them.** S5 probed guessed filenames after a change and missed
  `tests/test_store_writes.sh` — the file testing exactly what it changed. `ls tests/` first.
- **A low failure count from a run with concurrent load is not evidence.** S5 read a 6-failure run as
  reassuring; it had `--file` probes running alongside. The clean run showed 17.

## 3. S6 — one predicate, one spelling (next task)

Design: `00-plan.md` §7. Three work items:

1. **`lib/cmd-project-query.sh:192`** hardcodes a scope-widening remedy and bypasses the shared
   resolver. `_env_unavailable_sentence` (`access-scope.sh:736`) is already correct at **every**
   level, including `edit-all` where no widening exists. Replacing the branch closes
   **V2-F04 ≡ V4-F-V4-02 ≡ V5-04** in one edit — three sessions, three vantages, one call site.
2. **V1-F1** (adjacent): bare `cco project validate` at `/workspace` does not resolve the session's
   project while `cco project show` does (it has the R4 WORKDIR-root fallback). `/workspace` is the
   agent's default cwd, so two sibling introspection verbs disagree about whether the session has a
   project. Give `validate` the same fallback.
3. **The lint**: *no verb may spell an availability state locally* — the three states come from
   `access-scope.sh` or nowhere. This is the class RC-4 was created to eliminate (*"one predicate,
   four spellings, one of which drifted"*), and it has now recurred twice. Model it on `INV-IDX` /
   the `INV-S` CLASS lint in `tests/test_invariants.sh` (both carry a planted-violation self-test —
   a static invariant must prove its own discrimination, since it cannot "fail on reverted lib/").

## 4. Remaining stages, in the recommended order

| Stage | Why here | Design |
|---|---|---|
| **S6** | one predicate, one spelling; also V1-F1 | §7 |
| **S2b** (rest) | `_yaml_rename_list_ref` (closes S1–S3's acknowledged residual gap — the project.yml half of `repo rename`), then `cmd-join.sh`/`cmd-init.sh` (their damage escapes the machine), then the remaining `_index_*` modules. Widen `INV-IDX`'s `scoped` list as each closes | §3b + `engineering/analysis/false-success-class-audit.md` |
| **S7** | config-editor announces every drop; includes a **decision** (does config-editor mount a target's `extra_mounts`? recommendation: no, but announce) | §8 |
| **S8** | minor + doc debt | §9 |
| **S9** | changelog **47**, ADR forward-annotation (ADR-0047 gains the STATE allow-list + D-V3-1 + INV-S3b), living-doc sweep, migration checklist per `.claude/rules/update-system.md`. ⚠ **Includes a host-only part** — see §5 | §11 |

## 5. ⚠ Carried debt that a SESSION CANNOT CLOSE

**The managed rule** `defaults/managed/.claude/rules/cco-config-interaction.md` must add
`remove|rename` to its host-only verb list (S5/D-V3-1). Until it does, the rule injected into every
future session under-reports the host-only set. **Exact patch in `00-plan.md` §6.-1.**

Every `.claude` tree is clamped `:ro` in a session, including `defaults/managed/.claude/` even though
`defaults/managed/` itself is rw. **Why is a finding in its own right — `FI-25`** in
`roadmap-backlog.md`: the nested-`.claude` sweep (`_find_nested_config_dirs`, `cmd-start.sh:507`) is
correct for a normal project's authoring trees but also catches cco's OWN shipped `.claude` payload
(`defaults/`, `templates/`, `internal/` are tool source, not authoring trees).

**Two ways to close it**: apply the patch on the host, or run a self-dev session with
`--claude-access all` (FI-25 option (d)). **S9 must check for any other `defaults/**/.claude/` or
`templates/**/.claude/` edit this cycle needs and route it the same way.**

## 6. Out-of-session gates (maintainer, on the Mac)

1. **`cco remote remove v5probe`** — V5 left a registry entry it could not remove. **Do this before
   the next `cco build`**: after it, S5's refusal is live and the cleanup is host-only for good.
2. `cco build` from the cycle-1.1 tip, then **re-run V3 and V5**. V1/V2/V4 need no re-run — except
   gate 7.
3. **V4b** — the D-M11 escalation test. Highest value of the remaining runs: every other v3 probe
   fails *safe* if the fix is wrong; this one fails **open**.
4. **V5b** — bare global `(rw,none,none)`.
5. **§7 / E6B-04** — the pack-rename fan-out atomicity gate, still never executed, now unblocked by
   S1. Substrate already exists: `cave-core` is referenced by two mounted projects.
6. **D-M6 Linux write-path check-in — a HARD gate.** macOS `fakeowner` makes the fail-closed
   pre-validation unfalsifiable (V3-02 ran `chmod 500 .cco && mktemp .cco/.x.XXXXXX` and it
   **succeeded**), so criterion F cannot be signed off from a macOS run.
7. **From S4** — the `stale` arm (nlink 0) cannot be synthesized without a real mount, so its
   hermetic test mocks `stat` on PATH. The kernel side rides the **V2 re-run**: re-check that a
   stranded index now fails loud instead of reporting 0 rows at rc=0.
8. **NEW (S5)** — re-check on the rebuilt image that `cco remote remove|rename` refuse at exit 2 with
   the host hint, and that `cco remote add` still works. The in-session half is hermetically guarded
   (`test_operator_blocks_remote_remove_and_rename`), but the refusal only goes live after a build.

## 7. Do not re-litigate

RC-4 (confirmed on both halves across three projects, discriminating against both rejected
implementations), RC-1's D-M5 arms, RC-6 repos, the ADR-0047 boundary, criterion E, and
`lib/store.sh`'s fail-closed contract. The standing triage rule from V5's note 2: **"fix the mount +
fix the message, not reconsider RC-3."**

**Settled by S4, do not re-open:** `absent` is benign while `truncated` is diagnostic (a real index
is never 0 bytes); the retired-`cco resolve` rule is **contextual, not a ban** (the host arm keeps
it); V2-F03's detector belongs at verb entry, not in `cco whoami`.

**Settled by S2b-P/S5/INV-S3b, do not re-open:** `_remote_token_remove`'s three-valued contract (a
`die` from inside the primitive was considered and rejected — `store.sh`'s cascades legitimately
treat absence as a no-op and `exit` cannot be caught by their `||`); `chmod` failure stays a `warn`
because the token IS persisted; D-V3-1's scope (`remote add` stays in-session, it writes only the url
registry); and **INV-S3b**, which was decided with the maintainer after two wrong attempts — the
discriminator is pre-flight-vs-write crossed with session-vs-host, not the module.

**Out of scope** — everything `handoff-v3.md` §9 defers: the RC-5 vocabulary sweep, RC-7…RC-16,
Q-10 provenance writers, FI-21/22/23, E4-02/RC-16 mis-ownership, and **FI-24** (the update engine,
`pack`/`template publish`, the local-destructive set). **FI-25** (the self-dev `.claude` clamp) is
likewise out of cycle-1.1 — it is recorded, not fixed here.

**Open by decision, not residue:** D-M8's **Q-11** — routing `_index_rename_path` through a
`store-op` crossing. S3 delivers the same guarantee via the cheaper shape.
