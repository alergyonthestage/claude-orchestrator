# Handoff — the cycle is accepted; **one in-session item stands between here and the merge**

> **Ephemeral.** Delete this file before writing the next handoff. It links out only.
> Written 2026-07-31. Supersedes the handoff of 2026-07-31 (*"the next unit is an analysis"*).
> Nothing about future work lives *here*: the gates live in the
> [gates runbook](configuration/agent-cco-access/e2e-review/fix-design-v3.1/08-gates-to-release.md)
> and the plan lives in the [roadmap](roadmap.md). This file says where we stopped and how to start.

## Methodology / where we are

**Cycle-1.2 is ACCEPTED.** The block's single human gate **G3 passed on 2026-07-31**, verdict
`ACCEPTED with follow-ups`, written into the plan's §7 acceptance log. All five lanes L1–L5 are
accepted. **G1's residual host cleanup is done** — nothing from this cycle is left on the host.

**Roadmap step 2b closed with a decision, not a fix**: the config mount topology **does not change in
this release**; the whole block moves to **cycle-2**, and FI-40 / FI-42 / FI-43 are deferred with it.

**No gate is pending human approval.** The next phase is Review/Documentation, autonomous:
**G2, the CLI-surface documentation audit** — the only item left before the merge, and the only one a
session can finish alone.

## How to resume

1. Open the [gates runbook](configuration/agent-cco-access/e2e-review/fix-design-v3.1/08-gates-to-release.md)
   at **G2**. Its deferral is **lifted** (step 2b is closed, so the surface the audit documents is the
   shipped one). ⚠ **Audit today's behaviour — do not pre-document anything from the topology
   analysis.** Nothing from it ships.
2. G2 already has **two findings handed to it**, in its own section — do not re-derive them:
   the stale `cco start --help` text, and the ADR-0046 §6 ratification. Start from the canonical
   [`cli/reference/cli-surface-matrix.md`](cli/reference/cli-surface-matrix.md): a wrong row there is
   inherited by every downstream doc.
3. **In parallel** (maintainer's instruction, 2026-07-31): FI-44's **class-B** link repair —
   [`roadmap-backlog.md`](roadmap-backlog.md). Independent of G2, same pre-release window.
   ⚠ Read FI-44's warning first; the obvious repair is the wrong one.
4. Autonomy for both is `review-docs`-class: objective drift is corrected in place; **user-facing
   wording is a human gate**, not a sweep.

## Tasks

The [roadmap](roadmap.md) is the single source of truth for status; this list only points at it.

- [ ] **G2 — CLI-surface documentation audit** (roadmap step 3) ◀ *next, in-session*.
- [ ] **FI-44 class B** — links from immutable ADRs/reviews to consumed handoffs. Parallel to G2.
- [ ] **G4** — merge → `develop`, then verify the merge did nothing extra (tree-hash check).
- [ ] **G5** — verify **on `develop`**: the unmasked suite, and the **macOS host suite on this tree**
      (never run — the largest unknown left).
- [ ] **G6** — `develop → main` + release. ⚠ **Step 5 of G6 is new**: carry the **FI-42 known-issue**
      into the release notes; the wording is written out there, already reduced to what a user can act on.
- [ ] **Host-side, owed**: `git push origin develop fix/release/cycle-1.2` — the branch is **14 commits
      ahead** of origin. (G1's cleanup is done; nothing else is owed on the host.)

## Context

### What this session produced

Three commits, **all docs — no code was touched**, so every gate result from G0/G1 still stands:

- `241273e` — the **step-2b analysis**, persisted at
  [`configuration/agent-cco-access/analysis/config-mount-topology.md`](configuration/agent-cco-access/analysis/config-mount-topology.md).
  Home chosen deliberately (mounts are the mechanism, *which authoring path a verb may use at a given
  access level* is the subject), argued in its first paragraph.
- `30be1d8` — **step 2b's decision**: release as-is, block → cycle-2. Landed the ADR-0046 §6
  ratification, the three backlog deferrals, and unblocked G2.
- `fb9b796` — **G3's verdict** recorded, lanes marked accepted, plus the class-A link repair and
  **FI-44**.

### Decisions taken (rationale lives in the linked documents, not here)

- **The topology does not change in this release; FI-42 is deferred with it** — roadmap step 2b.
  The decisive reason is *conceptual, not economic*: **the fix cannot be taken without taking the
  contract decision it carries** (all-or-nothing vs all-or-declared-partial), and that decision is the
  cycle-2 subject. Implementing now would settle a contract by implementation.
- **G3 = `ACCEPTED with follow-ups`**, not plain `ACCEPTED` — three findings leave the cycle by
  decision and one ships as a known-issue, so **D-V31-4** requires the exception be written.
- **ADR-0046 §6 ratified in place** (annotation on the ADR, ADR-0056's established form), *not*
  deferred: the **normal** session already ships the wide `Pc` span unenforced.
- **Only class-A links repaired**; class B gets an entry instead of a sed — see FI-44.

### Open questions that need the human

**None blocking.** The six open questions of the topology analysis (§8) are **cycle-2's agenda**, not
this release's — they were deliberately left open when step 2b was decided.

### Non-obvious things worth not rediscovering

- 🔑 **The result that reframes the topology proposal**: *"the fan-out writer becomes correct
  verbatim"* and **soundness in `--all`** are **mutually exclusive**. `--all` exists to reach projects
  whose repos are **not** mounted, and a repo name is a **per-project label** (ADR-0051 D2), so `--all`
  structurally needs a project-keyed component; `<project>--<repo>` is layout 2 renamed. **The
  topology's residual value is UX — host/session path parity — not FI-42's correctness.** Recorded in
  the analysis and in FI-42; do not re-derive it as an argument *for* the change.
- 🔑 **Why deferring FI-42 is safe, established before deferring** (full table in FI-42): a **normal**
  session *is* layout 1, so the probe is correct there; `edit-project` and `config-editor --project`
  refuse at the access boundary (`pack rename` needs `G=rw`); `--all` without `--repo` refuses **before
  any mutation**. The **only** route reaching the fan-out is `config-editor --all --repo …`, and it
  exits **declared** — rc 1 plus the `failed` paths. Not silent corruption.
- ⚠ **FI-44's trap**: the dangling `implementation-handoff.md` links resolve *by basename* to
  `naming/implementation-handoff.md` — **another domain's file**. "Fixing" them that way replaces a
  dead link with a **misleading** one. There is no correct target: the handoffs were consumed.
- ⚠ **A relative link to a pack-supplied rule always dangles.** `documentation.md`, `workflow.md`,
  `testing.md`, `git-practices.md` come from the pack `core-dev-framework`, not from the repo's
  `.claude/rules/` (which holds only `documentation-lifecycle.md` + `update-system.md`). **Reference
  pack rules by name.** Caught live this session.
- 📝 **The link audit is ~20 lines** over markdown link targets. As a suite docs-lint it would make the
  ephemeral-link rule enforceable rather than aspirational — proposed in FI-44, not built.
- **The mask.** `access: {claude: all}` is uncommitted in `.cco/project.yml`; every suite figure in
  this cycle was measured with it **ON** (**1617/7 of 1624**). Unmasked adds two known failures.
  **State the mask state with any number** — this cycle has been wrong about it four times.
- **A count is not a fingerprint**: identify failing tests by name, never by how many there are.
- **Never edit `lib/`, `bin/test` or `tests/helpers.sh` while a suite run is in flight** — the runner
  is the script bash is executing.
- **Store-touching verbs in a session run the image-baked cco**, so `lib/` edits stay invisible
  in-session until `cco build`. On the **host**, `./bin/cco` reads the working tree.
- The working tree carries three untracked paths that are not this cycle's (`tmp`,
  `to-verify-guides-docs.md`, `.claude/worktrees/`) and one intentional uncommitted diff
  (`.cco/project.yml`). **Leave them alone unless asked.**
- `tests/test_start_dry_run.sh:1740` and `:1762` contain literal conflict markers as **fixture
  content** — a repo-wide grep for merge markers flags them as false positives.

## Reference documents

- [Roadmap](roadmap.md) — **G3's verdict** + lanes L1–L5 · **step 2b closed** + the **cycle-2 entry**
  (config multiplicity, divergence awareness & mount topology) · step 3 (G2) · step 4 (release) ·
  [backlog](roadmap-backlog.md) — FI-40, FI-42, FI-43 (all deferred), FI-41 (fixed), **FI-44** (new)
- [Gates runbook](configuration/agent-cco-access/e2e-review/fix-design-v3.1/08-gates-to-release.md) —
  G0…G6; **G2 unblocked with two ready findings**, **G6 step 5** carries the known-issue
- [Cycle-1.2 plan](configuration/agent-cco-access/e2e-review/fix-design-v3.1/00-plan.md) — **§7 the
  acceptance log**, now closing with **G3's verdict**
- [Config mount topology analysis](configuration/agent-cco-access/analysis/config-mount-topology.md) —
  this session's artifact; **cycle-2 starts here**, §3.3 (four blockers) and §8 (six questions)
- [ADR-0046](configuration/agent-cco-access/decisions/0046-unified-cco-access-model.md) — §6 + the
  **2026-07-31 ratification annotation**
- [ADR-0056](configuration/agent-cco-access/decisions/0056-availability-model-and-index-session-axis.md)
  · [ADR-0055](environment/decisions/0055-claude-runtime-state-and-mountpoint-ancestry.md) ·
  [ADR-0048](configuration/agent-cco-access/decisions/0048-config-editor-min-privilege-refinement.md)
