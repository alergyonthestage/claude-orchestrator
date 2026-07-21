# Resume Handoff — cycle-1.1, from S7 onward

> **Written 2026-07-21** for a fresh session (post-`/clear`). Self-contained: read this, check the
> prerequisites, review what landed, then continue.
> Supersedes [`RESUME-HANDOFF-s6.md`](RESUME-HANDOFF-s6.md) (whose §3 = S6 and §4 S2b row are now
> history), and with it [`-s5`](RESUME-HANDOFF-s5.md) / [`-s4`](RESUME-HANDOFF-s4.md). The gate list
> (§6) and the do-not-re-litigate list (§7) are carried forward and restated here — still live.
>
> **Branch**: `fix/config-access/e2e-v3-cycle1.1` (from `develop` @ `f894245`).
> **Tip**: `7d447fd`. **Suite**: **1447 passed / 9 failed** — the 9 are the pre-existing host-only
> artifacts (FI-19), names verified identical to baseline. NOT regressions.
> **Nothing is pushed.** Push and `develop → main` are maintainer-side and gated (§6).

## 0. First actions in the new session (in order)

1. **Retrieve context**: this handoff → memory `[[e2e-v3-cycle11]]` → `00-plan.md` §1 (stage table)
   and §8 (S7's design).
2. **Check prerequisites** (§1). The tree is the ground truth, not this doc.
3. **S7 opens with a DECISION, not code** (§3). Settle it with the maintainer first.
4. Then S8 / S9 per §4. Each stage: impl → **adversarial revert-check** → (one repair round) →
   reverify → commit. That is how S1–S6 and S2b were run, and it is what makes the guards
   trustworthy.

## 1. Prerequisites to verify before writing code

```bash
cd /workspace/claude-orchestrator
git branch --show-current      # expect fix/config-access/e2e-v3-cycle1.1
git log --oneline -8           # expect 7d447fd at the tip
git status --short             # expect ONLY: M .cco/project.yml, ?? tmp, ?? to-verify-guides-docs.md
./bin/test 2>&1 | tail -3      # expect 1447 passed / 9 failed
```

⚠ **The three working-tree entries are the maintainer's and must never be touched**: the
`.cco/project.yml` modification is their port edit (8081→8082), and `tmp` /
`to-verify-guides-docs.md` are their untracked notes. **Never `git stash -u`, `git clean`, or
`git add -A`** — a previous session nearly destroyed them. Stage with explicit paths.

⚠ **The suite runner is `./bin/test [--file <name>]`**, and `--file` takes the file's BASE NAME
including the prefix (`--file test_join`, not `--file join`) — a wrong name runs **0 tests and
still prints a green summary**. Running `bash tests/<file>.sh` directly is likewise a false green:
the test files are function libraries sourced by `bin/test`.

⚠ **Store-touching verbs run the IMAGE-BAKED `cco`** (`/opt/cco`), not the working tree, so `lib/`
edits are invisible in-session until a `cco build`. Verify behaviour through the test suite, not by
running `cco` in this session.

⚠ **To prove a failure set is pre-existing**, back the touched files up, `git checkout --` **only
those paths**, run, then restore from the backup. Never `git stash`.

⚠ **Run the full suite ALONE and capture FAIL NAMES, not just the count.** S5 learned this the hard
way. The baseline set is: 6× `test_as_*`, `test_paths_symlink_safe_tool_root`,
`test_update_new_file_added`, `test_update_dry_run`.

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
| **S6** | `987e38b` | **R4 + V1-F1**: `project show` asks the shared classifier; `project validate` gains the shared WORKDIR-root fallback. `INV-ENV` lint. |
| **S2b** | `be1032c` `cf9a3e5` `578e755` | The unchecked-write class **closed**: the `_yaml_rename_list_ref` primitive, then `join`/`init`, then the remaining five modules. `INV-IDX` covers them all. |

**Seven things to understand before changing any of it:**

1. **The STATE allow-list is fail-safe by construction and must stay that way** (`00-plan.md` §2.1).
   To expose something new to sessions, **move it under `shared/`** — never widen the mount.
2. **Errexit is not available in command bodies.** `bin/cco` dispatches as `cmd_foo "$@" ||
   _cco_rc=$?`, and a `||` context disables `set -e` for the entire call tree. Explicit `||` / `if !`
   propagation is the only mechanism that works.
3. **`die` inside a process substitution exits only the subshell.** Guards belong in the parent
   shell, at verb entry. S2b's fan-outs therefore carry the failure out as **tagged data**
   (`changed\t` / `failed\t`), never a `die` from inside.
4. **`_remote_token_remove`'s third exit code is load-bearing.** Callers that tolerate absence must
   test `-le 1`, never `|| true`.
5. **INV-S3b — read it in `lib/store.sh`'s header before touching any refusal exit code.**
   `in-session pre-flight → 2` · `host pre-flight → 1` · `write that started and failed → 1`.
   ⚠ Do **not** re-derive it from D8 alone nor INV-S3 alone: each is half the rule.
6. **INV-ENV is a budgeted allow-list, not a flat ban** (S6). Five modules legitimately spell the
   availability vocabulary because each owns a *different* predicate. Read the lint's header before
   "cleaning up" any of them.
7. **`lib/index.sh` is deliberately outside `INV-IDX`'s `scoped` list** (S2b) — it is the writer
   layer, where a call in TAIL position **is** the propagation. This also retired the sibling lint
   the plan once proposed; do not resurrect it without re-deriving.

**Three process lessons that each cost a debug cycle:**

- **Enumerate test files, never guess them.** S5 probed guessed filenames and missed
  `tests/test_store_writes.sh` — the file testing exactly what it changed. `ls tests/` first.
- **A low failure count from a run with concurrent load is not evidence.** S5 read a 6-failure run
  as reassuring; it had `--file` probes running alongside. The clean run showed 17.
- **Read the failure text before suspecting the code.** S6's first V1-F1 assertion failed because
  the *fixture* manifest carries no `url` (rc=1 for an unrelated reason) — the fix was already
  working.

**The one lesson that generalises past this cycle** (S2b's revert-checks proved it): S2's primitive
already printed *"Cannot write the cco index … Nothing was changed"* — loudly, correctly, at the
right moment — and the verb **still exited 0 and printed its tick**. **The defect was never the
message; it was the discarded status.** Do not "fix" a future instance of this class by improving
its wording.

## 3. S7 — config-editor announces every drop (next task)

Design: `00-plan.md` §8. **Item 2 is a decision before it is code — settle it with the maintainer
first.**

1. **V5-05** (code) — `lib/cmd-start.sh`, the `--all` branch: `[[ -d "$path/.cco" ]] || continue` is
   a bare `continue`. Route it through `_ce_skip_note`, which the sibling repo path already uses and
   which speaks the right vocabulary. One index-known project was dropped from 8 with no
   announcement on any in-container surface. ⚠ Line numbers in the plan predate S1–S2b — locate
   `_start_collect_config_editor_targets` and `_ce_skip_note` by name.
2. **V4-F-V4-01** (**DECISION**) — `_start_collect_config_editor_targets` never consults the
   target's `extra_mounts:`. Either **(a)** mount them like the target's repos (RC-6's shape), or
   **(b)** decide config-editor never mounts them and **announce** them as not-mounted via
   `_ce_skip_note`.
   **The plan recommends (b)**: config-editor exists to author *config*; a target's extra_mounts are
   reference material for a working session, not authoring surface, and mounting them widens the
   built-in's blast radius for no authoring gain. What is **not** acceptable is the current state —
   neither delivered nor decided — while `cco path list` prints both bindings as live host paths and
   implies they are reachable. Whichever way it goes, record it in `03-config-editor-repos.md` §3.9,
   whose drop-case table does not currently enumerate this class.

⚠ `_ce_skip_note` is one of `INV-ENV`'s five ratified exceptions (`cmd-start.sh`, budget **2**).
Extending it with a new `<reason>` arm is fine — the budget counts *spellings of the vocabulary*,
not arms — but adding a second `warn` that spells a state itself will fail the lint. That is
intended: route it through `_ce_skip_note`.

## 4. Remaining stages

| Stage | Why here | Design |
|---|---|---|
| **S7** | config-editor announces every drop; includes the extra_mounts **decision** | §8 |
| **S8** | minor + doc debt: V3-03 (Q-6 unreachable at the WORKDIR root), V4-F-V4-04 (stale D-M9/Q-8 record), V4-F-V4-03 (notice ordering — cycle-2 unless free), V1-F3≡V5-8 (bake `/opt/cco/BUILD` so launch rule 0 self-verifies), V1-F2 (proposal: extra_mounts in `project show`). V3-P already shipped in S2 | §9 |
| **S9** | changelog **47**, ADR forward-annotation (ADR-0047 gains the STATE allow-list + D-V3-1 + INV-S3b), living-doc sweep, migration checklist per `.claude/rules/update-system.md`. ⚠ **Includes a host-only part** — see §5 | §11 |

## 5. ⚠ Carried debt that a SESSION CANNOT CLOSE

**The managed rule** `defaults/managed/.claude/rules/cco-config-interaction.md` must add
`remove|rename` to its host-only verb list (S5/D-V3-1). Until it does, the rule injected into every
future session under-reports the host-only set. **Exact patch in `00-plan.md` §6.-1.**

Every `.claude` tree is clamped `:ro` in a session, including `defaults/managed/.claude/` even though
`defaults/managed/` itself is rw. **Why is a finding in its own right — `FI-25`** in
`roadmap-backlog.md`: the nested-`.claude` sweep (`_find_nested_config_dirs`, `cmd-start.sh`) is
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
   **succeeded**), so criterion F cannot be signed off from a macOS run. ⚠ **S2b widened what this
   gate covers**: every new guard it added is a `chmod`-driven unwritable-bucket test, so the same
   `fakeowner` caveat applies to all of them. They pass in this Linux container; a macOS run proves
   nothing about them.
7. **From S4** — the `stale` arm (nlink 0) cannot be synthesized without a real mount, so its
   hermetic test mocks `stat` on PATH. The kernel side rides the **V2 re-run**: re-check that a
   stranded index now fails loud instead of reporting 0 rows at rc=0.
8. **From S5** — re-check on the rebuilt image that `cco remote remove|rename` refuse at exit 2 with
   the host hint, and that `cco remote add` still works.
9. **NEW (S2b)** — the host-only verbs it touched (`join`, `init`, `forget`, `project import`,
   `resolve --scan`, `path set`, `migrate`) now die where they used to continue. Worth one live
   happy-path run of each after `cco build`, since the hermetic suite covers the failure arms but the
   success arms are what a user hits daily.

## 7. Do not re-litigate

RC-4 (confirmed on both halves across three projects, discriminating against both rejected
implementations), RC-1's D-M5 arms, RC-6 repos, the ADR-0047 boundary, criterion E, and
`lib/store.sh`'s fail-closed contract. The standing triage rule from V5's note 2: **"fix the mount +
fix the message, not reconsider RC-3."**

**Settled by S4, do not re-open:** `absent` is benign while `truncated` is diagnostic; the
retired-`cco resolve` rule is **contextual, not a ban** (the host arm keeps it); V2-F03's detector
belongs at verb entry, not in `cco whoami`.

**Settled by S2b-P/S5/INV-S3b, do not re-open:** `_remote_token_remove`'s three-valued contract;
`chmod` failure stays a `warn` because the token IS persisted; D-V3-1's scope (`remote add` stays
in-session); and **INV-S3b**, decided with the maintainer after two wrong attempts — the
discriminator is pre-flight-vs-write crossed with session-vs-host, not the module.

**Settled by S6, do not re-open:** `INV-ENV`'s five ratified exceptions each own a *different*
predicate and are not violations. `cmd-resolve.sh`'s entry says `read-all` where the shared notice
says `read-global`, and the **local one is right** (other projects need Po≥ro) — so it is evidence
the *shared* notice is stale, tracked as V4-F-V4-03 / Q-C3. Do not fold that into an INV-ENV
tightening.

**Settled by S2b, do not re-open:** `lib/index.sh` stays outside `INV-IDX` (tail position IS the
propagation), and the sibling "helper whose tail statement cannot return non-zero" lint is retired
with it; `cco resolve --scan` counts failures instead of dying on the first, because a best-effort
sweep must not abandon the remaining units.

**Out of scope** — everything `handoff-v3.md` §9 defers: the RC-5 vocabulary sweep, RC-7…RC-16,
Q-10 provenance writers, FI-21/22/23, E4-02/RC-16 mis-ownership, and **FI-24** (the update engine,
`pack`/`template publish`, the local-destructive set). **FI-25** (the self-dev `.claude` clamp) is
likewise out of cycle-1.1 — recorded, not fixed here.

**Open by decision, not residue:** D-M8's **Q-11** — routing `_index_rename_path` through a
`store-op` crossing. S3 delivers the same guarantee via the cheaper shape.
