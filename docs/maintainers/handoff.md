# Handoff — every cycle-1.2 gate is green; the next unit is an **analysis**, not the audit

> **Ephemeral.** Delete this file before writing the next handoff. It links out only.
> Written 2026-07-31. Supersedes the handoff of 2026-07-30.
> Nothing about future work lives *here*: the remaining gates live in the
> [gates runbook](configuration/agent-cco-access/e2e-review/fix-design-v3.1/08-gates-to-release.md)
> and the plan lives in the [roadmap](roadmap.md). This file only says where we stopped and how to start.

## Methodology / where we are

**Cycle-1.2's Implementation + Test is complete, and every probe it owed has now been run.** L1, L2 and
L3 have their Rule-1 container evidence; L4 and L5 closed in-session by an earlier ruling. The gate
sequence G0–G1 is green.

**The next unit is an Analysis**, not the next gate — a maintainer decision of 2026-07-31. Two refusals
hit while running G1 exposed a design question about *how a project's committed config is mounted and by
which path a verb reaches it*, big enough that auditing the CLI's documentation first would document a
surface that may move. Roadmap **step 2b**.

**Pending human gate: G3**, the block's single human gate (the per-phase gates for S3→S4→S5 were relaxed
to one at the end). It has **not** been taken, and it must now also absorb the findings below.

## How to resume

1. Read **roadmap step 2b** ([roadmap.md](roadmap.md)) and the three findings it feeds on —
   **FI-42**, **FI-43**, **FI-40** in [roadmap-backlog.md](roadmap-backlog.md). FI-42 is the concrete
   defect the topology question explains; do not re-derive it.
2. Run the analysis (`/analyze`). It is **read-only** — the analyst returns the document and the lead
   persists it once the direction is approved. Suggested home:
   `docs/maintainers/configuration/agent-cco-access/analysis/config-mount-topology.md`. ⚠ The subject
   straddles the `configuration/agent-cco-access` and `environment` domains (it is about mounts *and*
   access); pick the home deliberately and say why in the first paragraph.
3. **Do not start G2** (the CLI-surface audit). It is deferred behind 2b, on purpose.

If the maintainer instead wants to close the cycle first, the entry point is the runbook's **G3**.

## Tasks

The [roadmap](roadmap.md) is the single source of truth for status; this list only points at it.

- [ ] **Step 2b — config mount topology analysis** ◀ *next*. Weigh: system impact · ADR conformance
      (which decisions it honours and which it would **supersede**, explicitly) · UX across the real
      launch modes (mono/multi-repo, config-editor, tutorial, standard, `--repo`/`--mount`) ·
      `cco sync` in-container. → then the maintainer's decision, including whether any of it ships in
      this release.
- [ ] **G3 — the block's single human gate.** Checklist in the
      [gates runbook](configuration/agent-cco-access/e2e-review/fix-design-v3.1/08-gates-to-release.md).
      It now also has to rule on FI-40, FI-42, FI-43 and on FI-41's in-cycle fix.
- [ ] **G2 — CLI-surface documentation audit** (roadmap step 3), *after* 2b.
- [ ] **G4 / G5 / G6** — merge → verify on `develop` → release.
- [ ] **Residual host cleanup** from G1, if not already done: `rm -rf /tmp/cco-scratch`,
      `rm -rf ~/.cco/packs/scratch-pack*`, `cco forget proj-a`, `cco forget proj-b`, and the four stale
      remotes `probe-2`, `x`, `probe-3`, `probe-3b`.

## Context

### What this session actually produced

- **S3's probe passed on both arms** — the *split* gate (host `mv`, in-session observations). Evidence
  in the plan's §7. It was mislabelled *host-only* for a round, which is the session's first lesson:
  **classify a gate by where its observations live, not by where its most privileged step runs.**
- **G1 passed**: **E6B-04** ran for the first time in any round and the fan-out re-keyed **both**
  referring `project.yml` copies with no `failed` tag; **D7**'s view composed for a pack-less project
  with both floor entries writable. ⚠ E6B-04's third post-condition (provenance/tags/meta) is recorded
  as **vacuous** — the pack was created locally, so the sidecar re-key had nothing to move.
- **FI-41 fixed in-cycle** (`1814ba3`, changelog 60) with the maintainer's approval, plus a **fourth
  INV-AVAIL arm** and two regressions that fail on the pre-fix tree. Suite **1617/7 of 1624, mask ON**;
  the 7 are the documented host-only set, name for name.
- **The gates were extracted into one operational runbook** (G0…G6) — §8 of the plan is now a pointer.

### Decisions taken (rationale lives in the linked documents, not here)

- **E6B-04 before the merge**, and **on the host** — runbook G1.
- **G2 sequential after G1**, then **deferred behind step 2b** — roadmap step 2b.
- **FI-41 fixed narrowly at the consumer**, leaving `_project_member_status` untouched — FI-41.
- **The merge needs no re-ordering to be verifiable**: both `develop → main` and the cycle merge are
  content fast-forwards (measured tree hashes in runbook **G4**), so the tree verified on the branch *is*
  the released tree. What that cannot promise became **G5**.

### Open questions that need the human

- **FI-40** — may a refusal name the unmounted projects instead of counting them? D-V31-1's axis says
  naming is safe at read scope `all`. Affects **two** guards; decide once.
- **FI-42** — write through the reachable config mount and declare the unreachable copies, or keep
  refusing but for the right reason? It changes `pack rename` from all-or-nothing to
  all-or-declared-partial, which is a **contract** change.
- **FI-43** — `--repo` mounts the code `rw` while RC-6 §3.7's rationale says the built-in mounts repos
  to *read* code. Two files disagree about intent; the default is user-visible.

### Non-obvious things worth not rediscovering

- ⚠ **A correction that a future session would otherwise re-derive wrongly.** It is recorded twice
  (runbook G1.3 and FI-42) because it was asserted confidently and was wrong: config-editor's
  `--repo <name>` **composes with `--all`** — its collector loop runs after the mode chain,
  unconditionally. So `--all --repo a --repo b` *does* bind repos at `edit-all`. E6B-04 still belongs on
  the host, but because the built-in forces the repo-path `.cco` overlay `:ro` (`cmd-start.sh:1898`) —
  not because the arm is unreachable.
- **Lane-fixture trap**: in operator mode `_project_iter_members` enumerates from the reachable
  `project.yml`, **not** the index (`index.sh:1456-1468`). A fixture that seeds only the index is
  vacuous, and looks like a product bug for a while.
- **The mask.** `access: {claude: all}` is uncommitted in `.cco/project.yml` and every suite figure in
  this cycle was measured with it **ON**. Unmasked adds two known failures. **State the mask state with
  any number** — this cycle has been wrong about it four times.
- **A count is not a fingerprint**: identify failing tests by name, never by how many there are.
- **Never edit `lib/`, `bin/test` or `tests/helpers.sh` while a suite run is in flight** — the runner is
  the script bash is executing.
- **Store-touching verbs in a session run the image-baked cco**, so `lib/` edits stay invisible
  in-session until `cco build`. On the **host**, `./bin/cco` reads the working tree — no rebuild needed.
- The working tree carries three untracked paths that are not this cycle's (`tmp`,
  `to-verify-guides-docs.md`, `.claude/worktrees/`) and one intentional uncommitted diff
  (`.cco/project.yml`). **Leave them alone unless asked.**
- `tests/test_start_dry_run.sh:1740` and `:1762` contain literal conflict markers as **fixture
  content** — a repo-wide grep for merge markers flags them as false positives.

## Reference documents

- [Roadmap](roadmap.md) — **step 2b** (next), step 3 (audit), step 4 (release); lanes L1–L5 ·
  [backlog](roadmap-backlog.md) — FI-40, FI-41 (fixed), FI-42, FI-43
- [Gates runbook](configuration/agent-cco-access/e2e-review/fix-design-v3.1/08-gates-to-release.md) —
  G0…G6, the operational file for everything from here to the release
- [Cycle-1.2 plan](configuration/agent-cco-access/e2e-review/fix-design-v3.1/00-plan.md) — §1 the two
  governing rules · **§7 the acceptance log** (S1, S3 both arms, S4 round 3, S5's ruling, G1)
- [ADR-0056](configuration/agent-cco-access/decisions/0056-availability-model-and-index-session-axis.md)
  — the availability model + its ratified implementation annotations
- [ADR-0055](environment/decisions/0055-claude-runtime-state-and-mountpoint-ancestry.md) — D3/D7, the
  functional-write floor and the view-composition trigger
- [ADR-0048](configuration/agent-cco-access/decisions/0048-config-editor-min-privilege-refinement.md) ·
  [ADR-0046](configuration/agent-cco-access/decisions/0046-unified-cco-access-model.md) — the
  config-editor modes and the `(G,Pc,Po)` ladder that step 2b must weigh against
