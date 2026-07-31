# Handoff — **every in-session item is done; what remains is host-side**

> **Ephemeral.** Delete this file before writing the next handoff. It links out only.
> Written 2026-07-31. Supersedes the handoff of 2026-07-31 (*"one in-session item stands between here
> and the merge"*). That item — **G2** — is done, and so is FI-44's parallel task.
> The gates live in the
> [gates runbook](configuration/agent-cco-access/e2e-review/fix-design-v3.1/08-gates-to-release.md),
> the plan in the [roadmap](roadmap.md). This file says where we stopped and how to start.

## Methodology / where we are

**Cycle-1.2 is ACCEPTED** (G3, 2026-07-31, `ACCEPTED with follow-ups`) and **G2 — the CLI-surface
documentation audit — is DONE**. Report:
[`cli/reviews/2026-07-31-cli-surface-audit.md`](cli/reviews/2026-07-31-cli-surface-audit.md).

**No session can advance this release further.** G4 (merge), G5 (verify on `develop`) and G6
(release) are all host-side. Two small decisions are owed by the maintainer first — see *Tasks*.

## How to resume

1. **If you are the maintainer at a host terminal**: open the
   [gates runbook](configuration/agent-cco-access/e2e-review/fix-design-v3.1/08-gates-to-release.md)
   at **G4** and work down. Read G2's two ▶ owed items first (below) — one of them changes a
   sentence in the **release notes**.
2. **If you are a session**: there is no in-session work left on this release. Do not start G4/G5/G6.
   The next *design* subject is **cycle-2** (config multiplicity, divergence awareness & mount
   topology) — start from
   [`analysis/config-mount-topology.md`](configuration/agent-cco-access/analysis/config-mount-topology.md)
   §3.3 and §8, and note the new fact G2 added to it (below).

## Tasks

The [roadmap](roadmap.md) is the single source of truth for status; this list only points at it.

- [ ] **▶ OWED BY YOU (1) — sign off the release-note sentence.** G6 step 5's known-issue wording was
      **factually wrong** and is corrected: it named `cco start config-editor --all --repo …`, an
      invocation `cco start` **refuses**. The reachable one is `--cco-access edit-all --repo …`. The
      correction is factual; the phrasing is yours.
- [ ] **▶ OWED BY YOU (2) — decide [FI-45](roadmap-backlog.md)**: `cco remote list` at `read-project`
      says *"widen your access to read-global"*, and at read-global+ says *"was removed"*. Its four
      sibling removed aliases refuse at the shim before any scope test. One `case` arm — but it edits
      a user-visible message and **two pinned tests**, so G2 did not touch it.
- [ ] **G4** — merge → `develop`, then verify the merge did nothing extra (tree-hash check).
- [ ] **G5** — verify **on `develop`**: the unmasked suite, and the **macOS host suite on this tree**
      (never run — the largest unknown left).
- [ ] **G6** — `develop → main` + release, carrying the FI-42 known-issue (wording above).
- [ ] **Host-side, owed**: `git push origin develop fix/release/cycle-1.2` — the branch is **20
      commits ahead** of origin.

## Context

### What this session produced

Seven commits — six docs, **one touching `lib/`** (the `cco start --help` text plus two stale
comments; behaviour unchanged). **Suite re-run on the final tree: 1617 passed / 7 failed of 1624,
with the `access: {claude: all}` mask ON** — identical to the cycle baseline, and the 7 are the
host-only set name for name (the six `test_as_*` plus `test_paths_symlink_safe_tool_root`):

- `e0606d1` — `cco start --help` corrected: config-editor is **min-privilege by mode**, not the old
  broad default; `--claude-access` no longer claims `repo` is the default.
- `2e5e54e` — the **canonical CLI-surface matrix** re-derived from the shim (4 wrong rows), plus the
  living design doc and a forward annotation on the A1 analysis.
- `b40b9e0` — **user docs**: the config-editor guide was still pre-ADR-0048; `cli.md`'s one
  self-contradicting line.
- `bb875d3` — the **release known-issue named an invocation `cco start` refuses** (4 documents).
- `eb1dec5` — G2's record: report, gate status, roadmap step 3, **FI-45**.
- `e0a591f` — **FI-44 class B**: 15 links to consumed handoffs de-linked; class D closed as *not a
  defect*.

### Decisions taken (rationale lives in the linked documents, not here)

- **G2's autonomy was applied as written**: objective drift corrected in place (8 items), anything
  touching user-facing wording or a pinned test raised instead of swept (2 items).
- **FI-44 class B repaired in the conservative form** proposed in the entry — de-link, keep prose,
  mark *(consumed)* — because it removes a broken promise without restating a decision, which is what
  makes it compatible with editing immutable documents.
- **FI-44 class D closed as a false positive**, not fixed: the three "placeholders" are
  `` `[name](url)` `` inside **code spans**, illustrating the llms.txt format.

### Open questions that need the human

The two ▶ items in *Tasks*. Neither blocks a session; both block the release.

### Non-obvious things worth not rediscovering

- 🔑 **`--all` and `--cco-access edit-all` are two spellings of one config-editor mode, and only the
  first is guarded.** `cmd-start.sh:2687` rejects `--all` with `--project`/`--repo`; the same guard
  never tests `cli_cco_access`. So the *unguarded* spelling is the one that reaches FI-42's fan-out.
  Annotated at the guard. **Do not fix it as a stray guard** — which spelling is canonical belongs to
  the cycle-2 topology decision, and cycle-2 inherits this fact.
- 🔑 **Three times this cycle, a confident classification derived by reading code was refuted by
  running it** (S7's dead fix site, S8's unreachable remedy, now this). G2's every behavioural claim
  was probed against the hermetic harness. `tests/helpers.sh`'s `setup_cco_env` +
  `_lane_operator_exports` give you a host run and an operator-lane run in ~10 lines — cheaper than
  the re-derivation they replace.
- ⚠ **The machine-read surface being right does not mean the human one is.** The config-editor's own
  agent-facing rules (`internal/config-editor/.claude/`) were **correct**; the user guide next to
  them was two ADRs stale and advertised three verbs the session refuses. Check both, always.
- ⚠ **A docs-link lint must skip inline code spans**, or it reports FI-44's own text — and every
  `[name](url)` format example — as broken forever. Recorded in FI-44.
- **The mask.** `access: {claude: all}` is uncommitted in `.cco/project.yml`; every suite figure in
  this cycle was measured with it **ON**. **State the mask state with any number.**
- **A count is not a fingerprint**: identify failing tests by name, never by how many there are.
- **Never edit `lib/`, `bin/test` or `tests/helpers.sh` while a suite run is in flight.**
- **Store-touching verbs in a session run the image-baked cco**, so `lib/` edits stay invisible
  in-session until `cco build`. On the **host**, `./bin/cco` reads the working tree.
- The working tree carries three untracked paths that are not this cycle's (`tmp`,
  `to-verify-guides-docs.md`, `.claude/worktrees/`) and one intentional uncommitted diff
  (`.cco/project.yml`). **Leave them alone unless asked.** ⚠ `.claude/worktrees/` holds full copies
  of the repo — exclude it from every repo-wide grep or you will "find" stale text that is not in the
  tree (it happened during this audit).
- `tests/test_start_dry_run.sh:1740` and `:1762` contain literal conflict markers as **fixture
  content** — a repo-wide grep for merge markers flags them as false positives.

## Reference documents

- [Roadmap](roadmap.md) — G3's verdict + lanes L1–L5 · step 2b closed + the **cycle-2 entry** ·
  **step 3 (G2) closed** · step 4 (release) ·
  [backlog](roadmap-backlog.md) — FI-40/42/43 (deferred to cycle-2), **FI-44 (B done, D closed)**,
  **FI-45 (new, needs your decision)**
- [Gates runbook](configuration/agent-cco-access/e2e-review/fix-design-v3.1/08-gates-to-release.md) —
  G0…G6; **G2 done with two owed items**, **G6 step 5** carries the corrected known-issue
- [G2 audit report](cli/reviews/2026-07-31-cli-surface-audit.md) — method, the 8 corrections, the
  release-artefact finding, and what was verified correct
- [CLI-surface matrix](cli/reference/cli-surface-matrix.md) — the canonical verb table, re-derived
- [Config mount topology analysis](configuration/agent-cco-access/analysis/config-mount-topology.md) —
  **cycle-2 starts here**, §3.3 (four blockers) and §8 (six questions)
- [Cycle-1.2 plan](configuration/agent-cco-access/e2e-review/fix-design-v3.1/00-plan.md) — §7 the
  acceptance log
