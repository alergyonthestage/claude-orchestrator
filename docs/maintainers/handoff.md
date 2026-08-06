# Handoff — **A4 is built, run and measured. One decision (FI-52) blocks acceptance; two checks need re-running.**

> **Ephemeral.** Delete this file before writing the next handoff. It links out only.
> Written 2026-08-06. Supersedes the handoff of the same day (*"decide FI-52, then run the runbook"*)
> — **the runbook has now been run**. Status SSOT: [roadmap](roadmap.md).

## Methodology / where we are

Phase: **Implementation complete, acceptance run, verdict recorded.** Nothing is half-done and
nothing is in flight.

The unit is **A4** (Block A → `0.7.0`): the `ask` enforcement plane and Axis-B resource classes,
[ADR-0057](configuration/agent-cco-access/decisions/0057-ask-enforcement-plane-and-resource-classes.md),
closing FI-18. Built in this cycle, then accepted against three real host sessions.

**Result: 3 pass · 1 fail · 2 measured nothing.** Full record:
[`acceptance/0057-acceptance-results.md`](configuration/agent-cco-access/acceptance/0057-acceptance-results.md)
(raw transcript preserved in its §6).

**Gates**: none pending on analysis or design. Pending is **one maintainer decision** and a short
re-run.

## How to resume

1. **Decide [FI-52](improvements.md).** Four options are written out there. This is the only thing
   genuinely blocking acceptance, and it is a decision, not a task.
2. **Re-run acceptance checks 1 and 3** — they measured nothing because two commands in the runbook
   were wrong. Both are **fixed in place**; the corrected forms are also in
   [results §5](configuration/agent-cco-access/acceptance/0057-acceptance-results.md).
3. **Decide whether the FI-25 mask goes back on.** `.cco/project.yml` has
   `access: {claude: all}` **commented out** and the edit is **uncommitted**. While it stays off,
   `internal/` and `defaults/` `.claude` are not writable in a self-dev session and in-container
   suite figures become `…/9` instead of the masked `…/7`.
4. **Push.** `feat/access/claude-md-axis` is **12 commits ahead of its own origin ref**, 19 ahead of
   `develop`. Host-side.

## Tasks

- [ ] **Decide FI-52** — 🔴 blocks A4 acceptance
- [ ] **Re-run checks 1 and 3** with the corrected commands
- [ ] **Decide the FI-25 mask** (uncommitted `.cco/project.yml` edit)
- [ ] **[FI-53](improvements.md)** — whoami reporting; Low effort, no enforcement impact, can ride
      the FI-52 fix
- [ ] **Push**, then **merge to `develop`** once accepted — ⚠ host-only, needs
      `--cco-access edit-project`
- [ ] **Block A → `0.7.0`** — A1 `cco save`, A2 ([FI-49](improvements.md)),
      A3 ([FI-32](improvements.md)) still open
- [ ] **Cross-cutting analysis** → **B** → **C** → **D** — unchanged

## Context

### What the acceptance actually established

- ✅ **The trigger case is closed** (check 2). A dialog on a nested `CLAUDE.md`, **no** honoured with
  the file left unchanged, and a sibling `README.md` edited with no dialog. That is the whole point
  of A4, measured end to end.
- ✅ **`none` is genuinely locked** (check 4): no rule emitted, both mounts `:ro`, the write refused
  with `EROFS`, no dialog. Declared autonomy works.
- ✅ **`whoami` reports both dimensions** (check 6).
- ❌ **Check 5 fails** — [FI-52](improvements.md), now *measured* rather than predicted.
- ⚠ **Checks 1 and 3 measured nothing** — my runbook's fault, not the implementation's.

### 🔴 FI-52, the blocker

The `claude_md` gate is **one glob over all of `/workspace`** (D8's deliberate choice — the repo set
is unbounded and enumeration cannot win). But a glob cannot discriminate by tree, so it also gates
trees whose cell resolved to `rw`, where D3 says a prompt is noise. Because `Cr` defaults to `ro` and
never derives up while `claude_md` defaults to `ask`, it fires in **every `--cco-access edit-project`
session** and every config-editor session. Four options, none taken.

### Two session-agent claims, adjudicated — do not re-litigate

- **REFUTED** — *"`rules=ro` is not enforced"*. D3: a class never reduces below its tree.
  config-editor derives `Cp=rw`, so `cell(current, rules) = max(rw, ro) = rw`. The write was correct.
- **REAL, but reporting only** — the misreading is [FI-53](improvements.md): `whoami` prints the
  class **axis inputs** where a reader expects effective cells, and omits classes that resolve
  *upward*. A trained reader got it wrong in minutes, in writing, on a security surface.
- **BY DESIGN** — *"the rule only covers `Edit`"*. FI-48 measured that `Edit` rules do cover the
  built-in modifying tools and the Bash file commands Claude Code recognises, while `dd`, `truncate`
  and interpreters pass. That residue is ADR-0057 **P6**, stated before implementation: `permissions`
  is a **gate**, not a boundary, and `ask` needs the mount `rw` — the trade is the design, and it
  cannot be closed on the permissions plane. This answers the question raised during check 2.

### Non-obvious things the next session would otherwise rediscover

- ⚠ **Never grep `mountinfo` for `rw,`.** Every line ends with the shared host mount's own
  `rw,fakeowner` superblock options, so a greedy match reports `rw` for a `:ro` mount. Field 6 is the
  per-mount flag set: `awk '$5=="/path" {print $5, $6}'`.
- ⚠ **A glob in a redirect target is an *ambiguous redirect*** in bash — it fails in the shell,
  before the filesystem, and the non-zero exit looks exactly like the `EROFS` you were hoping to see.
- 📝 **`cco build` is NOT required for A4** (the ADR says it is; measured otherwise). No image-baked
  file is touched and both planes are produced at start time by `./bin/cco` on the host. What
  survives: the `cco` on the container `PATH` is the image-baked build, so in-session always call
  `/workspace/claude-orchestrator/bin/cco`.
- 📝 **INV-P checks structure, not agreement.** It enforces one producer and two pure emitters, and
  it cannot see FI-52 — a semantic divergence between the planes. Know that before trusting it to
  catch the next one.
- 📝 **Suite baseline** unchanged by the acceptance run: in-container **1626/7 of 1633** with the
  mask on, zero regressions against a HEAD baseline measured in an isolated worktree. ⚠ With the mask
  now commented out, expect `…/9`.
- 📝 **Next free ADR number is 0058.** ADR-0038 and ADR-0040 still do not exist as documents.

## Reference documents

- [Roadmap](roadmap.md) — **start here** · [improvements.md](improvements.md) — the tracker,
  `FI-1 … FI-53` (**FI-52 blocks**; FI-53 is the reporting fix; FI-18 is ✅ closed by A4) ·
  [roadmap-history.md](roadmap-history.md) — cycle 1 and before
- **A4's documents, in reading order**:
  [ADR-0057](configuration/agent-cco-access/decisions/0057-ask-enforcement-plane-and-resource-classes.md)
  (the decision and why) →
  [`design.md` §4bis.1 + INV-P](configuration/agent-cco-access/design.md) (what was built, and where
  each piece lives) →
  [the probe record](configuration/agent-cco-access/analysis/probe-ask-enforcement-plane.md)
  (proven before implementation) →
  [the runbook](configuration/agent-cco-access/acceptance/0057-ask-plane-runbook.md) and
  [the results](configuration/agent-cco-access/acceptance/0057-acceptance-results.md) (proven after)
- [`configuration/agent-cco-access/analysis/config-mount-topology.md`](configuration/agent-cco-access/analysis/config-mount-topology.md)
  §3.3 and §8 — **Block D starts here**
- [Gates runbook](configuration/agent-cco-access/e2e-review/fix-design-v3.1/08-gates-to-release.md) —
  the template for the next release
