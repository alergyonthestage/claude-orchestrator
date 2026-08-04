# Resume Handoff — cycle-1.1, from S4 onward

> **Written 2026-07-21** for a fresh session (post-`/clear`). Self-contained: read this, check the
> prerequisites, review what landed, then continue. Nothing below needs re-deriving.
>
> **Branch**: `fix/config-access/e2e-v3-cycle1.1` (from `develop` @ `f894245`).
> **Tip**: `659a60d`. **Suite**: **1417 passed / 9 failed** — the 9 are the pre-existing host-only
> artifacts (FI-19: host-only tests defeated by the ADR-0047 boundary and the self-dev `:ro`
> mounts), an unchanged set, NOT regressions.
> **Nothing is pushed.** Push and `develop → main` are maintainer-side and gated (§6).

## 0. First actions in the new session (in order)

1. **Retrieve context**: this handoff → memory `[[e2e-v3-cycle11]]` → `00-plan.md` (the stage table
   and §2.1, the constraint that rules out the obvious fix) → `../results/consolidated-review-v3.md`
   §2 (root R1) and §4 (roots R2…R7).
2. **Check prerequisites** (§2). The tree is the ground truth, not this doc.
3. **Review what landed** (§3) as a coherent whole before adding stages — S1/S2/S3 interlock, and
   S3's value depends on S2 still being there.
4. **Implement S4** (§4), then continue down §5. Each stage: impl → adversarial revert-check →
   (one repair round) → reverify → commit. That is how S1–S3 were run and it is what makes the
   guards trustworthy.

## 1. Canonical reading order

**This workstream:**
- `00-plan.md` — the staged plan. §1 stage table with live status; **§2.1 is mandatory before
  touching mount generation**; §3b is S2b's design; §10 the out-of-session gates.
- `../results/consolidated-review-v3.md` — the verdict, roots **R1…R7**, the findings→RC→ADR map
  (§5), the ratified **D-V3-1** (§3), and §6 the process findings for a future v4 matrix.
- `../handoff-v3.md` §8 — the acceptance criteria **B/C/D/E/F/G** the eventual re-review re-runs.
- `/review-v3/V{1..5}-*.md` — the raw session reports, if a finding needs its original evidence.
  (Mounted read-only; not in the repo.)

**The settled model — ADRs (history; formalize, never re-litigate):** ADR-0042, **0043**, 0044,
**0046**, **0047** (the privilege boundary — S1 refines its STATE allow-list), 0048, **0049**, 0050,
0051. Cycle-1 fixes are forward-annotated into each; read the annotation, not just the original.

**Living docs these fixes keep true:** `design-docker.md` §1.2.2 (the bucket-ownership invariant —
v3 R1 is its first real instance), `design-cli-environment-awareness.md`, `../../design.md` §5,
`design-resource-rename.md`, `cli.md`.

## 2. Prerequisites to verify before writing code

```bash
cd /workspace/claude-orchestrator
git branch --show-current      # expect fix/config-access/e2e-v3-cycle1.1
git log --oneline -6           # expect 659a60d at the tip
git status --short             # expect ONLY: M .cco/project.yml, ?? tmp, ?? to-verify-guides-docs.md
./bin/test 2>&1 | tail -3      # expect 1417 passed / 9 failed
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

## 3. What landed — review this before extending it

| Stage | Commit | What it does |
|---|---|---|
| **S1** | `517014b` | STATE crosses the ADR-0047 boundary via a **`state/cco/shared/` directory bind** instead of individual file binds. `_cco_state_shared_dir()` in `paths.sh`; the index and the pack/template update sidecars re-homed; `cmd-start.sh` binds the one directory; `entrypoint.sh` pre-chowns the per-bucket parents to `cco-svc`; migration **`017`** (idempotent, new-wins on a partial run). `INV-STATE` pins the allow-list `{shared, running}` **and** that the index is never file-bound again. Also fixed a real bug the move surfaced: `cco config validate` scanned the old sidecar paths, so post-move it would have found **no** sidecar orphan at all. |
| **S2** | `4aefc2f` | `_index_mktemp` fails loudly and names the cause (all 7 writer sites); `_index_ensure_file` and `_index_rename_path` propagate; `cmd-repo.sh` checks and dies naming **which** store already changed. `INV-IDX` lints bare index writes in container-reachable modules; `T-R2` is the behavioural guard. V3-P (restart note after a successful rename) shipped here. |
| **S3** | `582347d` | `_rename_assert_index_writable` — the fail-closed pre-flight now probes **both** stores, so the rename refuses before Phase 1. |

**Three things to understand before changing any of it:**

1. **The STATE allow-list is fail-safe by construction and must stay that way** (`00-plan.md` §2.1).
   Two v3 sessions recommended binding `state/cco` whole; that mounts the 0600 `remotes-token`,
   transcripts and memory into every session and flips the boundary to fail-open. To expose
   something new to sessions, **move it under `shared/`** — never widen the mount. `INV-STATE`
   enforces this.
2. **Errexit is not available in command bodies.** `bin/cco:657-658` dispatches as
   `cmd_repo "$@" || _cco_rc=$?`, and a `||` context disables `set -e` for the entire call tree.
   Explicit `||` / `if !` propagation is the only mechanism that works. This is why S2 is an
   invariant and not a patch, and it constrains every stage below.
3. **What S1–S3 did NOT close, stated plainly** so the commit messages are not read as broader than
   they are: they closed the **index** half of `repo rename`. The **project.yml** half retains a
   narrower form of the same defect — `_yaml_rename_list_ref` (`rename.sh:66-72`) does
   `mv "$tmp" "$file"` then an unconditional `return 0`, so `rename.sh:230`'s correctly-written
   `if _rename_yaml_write_owned …; then` cannot see a failed `mv`. S3's pre-flight mitigates the
   dominant cause (an unwritable tree) but probes only the **cwd unit's** `.cco`. This is S2b's
   work, not a new discovery.
4. **S3's two probes use OPPOSITE identities, deliberately.** project.yml is written de-elevated to
   ruid=claude (D-M4) → probe via `_rename_deelevated`; the index is written at euid=cco-svc (the
   verb trampolines wholly) → probe with a plain `mktemp`. Swapping them refuses every legitimate
   rename, or passes on a tree the write cannot touch. And S2/S3 are **not** redundant: S3 makes the
   failure not happen, S2 makes it loud and recoverable if the probe passes and the write still
   fails. `T-R2` assertion (e) pins the pair.

## 4. S4 — read-path honesty (next stage)

Closes **V2-F02** and **V2-F03**; the read half of the R1 symptom set. Design: `00-plan.md` §5.

`lib/cmd-resolve.sh:869` gates the "empty" message on `count -eq 0 && hidden -eq 0` — a correct
discriminator for *empty-vs-all-hidden*, with **no third arm for "the read failed"**. A zero-byte,
permission-denied or stranded index all render as a cheerful success at rc=0. It additionally
re-emits `run 'cco resolve'` — the exact string RC-2 claims to have retired — from a path cycle 1
never audited.

Work items:

1. Add the third arm: unreadable/unparseable → **error, exit 1, the real reason**. Never rc=0.
2. Remove the retired vocabulary; route through `_env_unavailable_sentence`
   (`access-scope.sh:736`) or an equivalent shared string. **Do not write a fourth spelling** —
   that is the R4 class this cycle is also fixing.
3. `cco list projects` degrades even more quietly (bare header, no message). Same treatment.
4. **V2-F03** — surface the staleness rather than only failing honestly on read: a `stat`-based
   liveness check at verb entry, or a line in `cco whoami`. S1 removes the *cause*; a file-shaped
   bind may return elsewhere, so this is the detector.

Guard to write: a test where the index is present but unreadable → exit 1, message names the real
reason, and the string `cco resolve` does **not** appear. Revert-check it.

## 5. Remaining stages, in the recommended order

| Stage | Why here | Design |
|---|---|---|
| **S4** | closes the read half of R1's symptoms; criterion **B** stays formally broken while the "empty" branch can absorb a failure | §5 |
| **S5** | D-V3-1 (`remote remove\|rename` → host-only) + the truthful store refusal. Settles the store-refusal taxonomy, which **S3 defers to** — if it lands on exit 1 for "bucket not writable", move `_rename_assert_index_writable` and its sibling together | §6 |
| **S6** | one predicate, one spelling: `cmd-project-query.sh:192` bypasses the correct shared resolver. Three v3 sightings, one call site. Also V1-F1 | §7 |
| **S2b** | the same unchecked-write class, **re-scoped 2026-07-21** after a codebase-wide audit. Two-layered: fix the failure-incapable primitives FIRST, then the call sites — §5 of the audit explains why the reverse order yields an audit that reads as closed while the defect persists. **Includes a residual gap in what S1–S3 shipped** (the rename's project.yml half). Note **S5 depends on the token primitive** | §3b + `engineering/analysis/false-success-class-audit.md` |
| **S7** | config-editor announces every drop; includes a **decision** (does config-editor mount a target's `extra_mounts`? recommendation: no, but announce) | §8 |
| **S8** | minor + doc debt | §9 |
| **S9** | changelog **47**, ADR forward-annotation (ADR-0047 gains the STATE allow-list + D-V3-1), living-doc sweep, migration checklist per `.claude/rules/update-system.md` | §11 |

S4→S5→S6 first is deliberate: they are the three that keep an acceptance criterion red. S2b and S7
are real but block nothing.

## 6. Out-of-session gates (maintainer, on the Mac) — unchanged from `00-plan.md` §10

1. **`cco remote remove v5probe`** — V5 left a registry entry it could not remove. Unrelated to the
   fix, but the store is currently grown by one.
2. `cco build` from the cycle-1.1 tip, then **re-run V3 and V5**. V1/V2/V4 need no re-run — their
   results are independent of R1 and reconciled against the host oracle.
3. **V4b** — the D-M11 escalation test. Highest value of the remaining runs: every other v3 probe
   fails *safe* if the fix is wrong; this one fails **open**.
4. **V5b** — bare global `(rw,none,none)`.
5. **§7 / E6B-04** — the pack-rename fan-out atomicity gate, still never executed, now unblocked by
   S1. Substrate already exists: `cave-core` is referenced by two mounted projects.
6. **D-M6 Linux write-path check-in — now a HARD gate.** macOS `fakeowner` makes the fail-closed
   pre-validation unfalsifiable (V3-02 ran `chmod 500 .cco && mktemp .cco/.x.XXXXXX` and it
   **succeeded**), so criterion F cannot be signed off from a macOS run.

## 7. Do not re-litigate

RC-4 (confirmed on both halves across three projects, discriminating against both rejected
implementations), RC-1's D-M5 arms, RC-6 repos, the ADR-0047 boundary, criterion E, and
`lib/store.sh`'s fail-closed contract. The standing triage rule from V5's note 2: **"fix the mount +
fix the message, not reconsider RC-3."**

**Out of scope** — everything `handoff-v3.md` §9 defers: the RC-5 vocabulary sweep, RC-7…RC-16,
Q-10 provenance writers, FI-21/22/23, E4-02/RC-16 mis-ownership. Two findings sit adjacent to
cycle-2 and are pulled **in** deliberately, on D-M2 rule 3 (cycle 1 must not emit text contradicting
the ratified vocabulary): **S6** and **S8**'s Q-C3 line if free.

**Open by decision, not residue:** D-M8's **Q-11** — routing `_index_rename_path` through a
`store-op` crossing. S3 delivers the same guarantee via the cheaper shape; Q-11 remains a
larger refactor of a write path S1+S2 had just rewritten.
</content>
