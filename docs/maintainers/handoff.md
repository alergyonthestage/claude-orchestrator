# Handoff — **A4 is built and green, and one decision blocks its acceptance. Decide FI-52, then run the runbook.**

> **Ephemeral.** Delete this file before writing the next handoff. It links out only.
> Written 2026-08-06. Supersedes the handoff of 2026-08-05 (*"push, then open an implementation
> unit"*) — **both are done**. Status SSOT: [roadmap](roadmap.md).

## Methodology / where we are

Phase: **Implementation — complete; acceptance blocked on a design decision.**

The unit opened was **A4** (Block A → `0.7.0`): the `ask` enforcement plane and Axis-B resource
classes, [ADR-0057](configuration/agent-cco-access/decisions/0057-ask-enforcement-plane-and-resource-classes.md),
closing FI-18. It is implemented, documented and green.

**Gates**: none pending on analysis or design. What is pending is **one maintainer decision**
([FI-52](improvements.md)) and then the acceptance run.

## How to resume

1. **Decide [FI-52](improvements.md).** Four options are written out there; none was taken because
   the choice changes user-visible behaviour and sits between two decisions the ADR already ratified.
   This is the only thing genuinely blocking.
2. **Run the [acceptance runbook](configuration/agent-cco-access/acceptance/0057-ask-plane-runbook.md).**
   Hybrid by construction: three sessions started from the host with `./bin/cco`, each carrying a
   paste-in block that delegates the mechanical checks to that session's own agent. Only the
   permission **dialogs** are manual.
3. **Push.** `feat/access/claude-md-axis` is **8 commits ahead of its own origin ref** and 14 ahead
   of `develop`. Host-side.

## Tasks

- [ ] **Decide FI-52** — 🔴 blocks A4 acceptance
- [ ] **Run the six acceptance checks** — ⚠ check 5 is expected to FAIL as written (that IS FI-52)
- [ ] **Push** `feat/access/claude-md-axis` (host-side)
- [ ] **Merge to `develop`** once accepted — ⚠ host-only, and needs `--cco-access edit-project`
      (a merge writes the working tree and `.cco` is `:ro` at the default level)
- [ ] **Block A → `0.7.0`** — [roadmap §Block A](roadmap.md): **A4 built**; A1 `cco save`,
      A2 per-project image ([FI-49](improvements.md)), A3 cross-scope warning
      ([FI-32](improvements.md)) still open
- [ ] **Cross-cutting analysis** → **Block B** → **C** → **D** — unchanged

## Context

### What was built

Eight commits, `b324c0e` → `57eab7f`. The core is `b324c0e` (resolver + the `ro < ask < rw` lattice +
the `entries` class dimension + both emitters + D13 seeding), `24ec2fb` (INV-P), `be2cc9e` (schema,
CLI, user docs, `changelog.yml` #62), `190f8cd` (golden), `5eeafdf` + `23cddea` + `57eab7f`
(roadmap, runbook, FI-52).

**Suite 1626/7 of 1633.** The 7 are the known host-only set, unchanged **name for name** against a
HEAD baseline measured in an isolated worktree (1619/7 of 1626 — the figure the previous handoff
recorded). Zero regressions. Every changed file parses on the real bash 3.2 interpreter.

### 🔴 The blocker, in one paragraph

The `claude_md` gate is **one glob over all of `/workspace`** — D8's deliberate choice, because
`<repo>/**/CLAUDE.md` is unbounded and enumeration cannot win. But the glob cannot discriminate by
tree, so it also gates trees whose cell resolved to `rw`, where D3 says a prompt is noise. Measured:
a `current=rw` session mounts `/workspace/.claude` **rw** and gates it anyway. Because `Cr` defaults
to `ro` and never derives up while `claude_md` defaults to `ask`, this fires in **every
`--cco-access edit-project` session** and every config-editor session. Full write-up, blast radius
and the four options: [FI-52](improvements.md).

### Non-obvious things the next session would otherwise rediscover

- 📝 **`cco build` is NOT required for A4** — the ADR says it is; measured otherwise. The diff touches
  no image-baked file (`Dockerfile`, `config/`, `defaults/`, `proxy/` untouched) and both planes are
  produced at **start time** by `./bin/cco` on the host. What survives: the `cco` on the container
  `PATH` is the image-baked build, so in-session always call
  `/workspace/claude-orchestrator/bin/cco`.
- ⚠ **The FI-25 mask makes acceptance checks 1–3 measure nothing.** `.cco/project.yml` commits
  `access: {claude: all}` → every tree `rw` → `max()` absorbs `ask` → **no rule emitted**. The runbook
  therefore pins every shape with an explicit `--claude-access`.
- ⚠ **Check 2 must be driven through the Edit tool, not Bash.** The rule covers the built-in
  modifying tools and the file commands Claude Code recognises, but `dd`, `truncate` and any
  interpreter pass straight through (FI-48). A silent success through one of those proves nothing.
- 📝 **A default session no longer reports `claude_access: none`.** Its trees match that preset but
  `claude_md` is `ask`, so the label would understate its reach. The label now compares resolved
  **matrices**, which also means a tuple resolving cell-for-cell to `all` is still called `all`.
- 📝 **INV-P checks structure, not agreement.** It enforces one producer and two pure emitters — and
  it cannot see FI-52, which is a semantic divergence between the planes. Worth knowing before
  trusting it to catch the next one.
- 📝 **Next free ADR number is 0058.** ADR-0038 and ADR-0040 still do not exist as documents.
- 🔑 **Two process failures worth not repeating.** A pre-existing invariant (`INV-LOCAL`) caught a
  real bug I had just written — `local a="$2" out="$a"` reads the CALLER's variable, invisible
  because the caller happened to have a same-named local holding the same value. And I reported a
  suite as clean by reading a results file a later commit had already invalidated; the docs commit
  had broken two golden tests (`tests/golden/project-add-base-template.yml` pins the base template
  byte-for-byte, so touching its comments breaks it).

## Reference documents

- [Roadmap](roadmap.md) — **start here** · [improvements.md](improvements.md) — the tracker,
  `FI-1 … FI-52` (**FI-52 is the blocker**; FI-18 is ✅ closed by A4) ·
  [roadmap-history.md](roadmap-history.md) — cycle 1 and before
- **A4's documents, in reading order**:
  [ADR-0057](configuration/agent-cco-access/decisions/0057-ask-enforcement-plane-and-resource-classes.md)
  (the decision and why) →
  [`design.md` §4bis.1 + INV-P](configuration/agent-cco-access/design.md) (what was built, and where
  each piece lives) →
  [the probe record](configuration/agent-cco-access/analysis/probe-ask-enforcement-plane.md) (what
  was proven before implementation) →
  [the acceptance runbook](configuration/agent-cco-access/acceptance/0057-ask-plane-runbook.md)
  (what is still owed)
- [`configuration/agent-cco-access/analysis/config-mount-topology.md`](configuration/agent-cco-access/analysis/config-mount-topology.md)
  §3.3 and §8 — **Block D starts here**
- [Gates runbook](configuration/agent-cco-access/e2e-review/fix-design-v3.1/08-gates-to-release.md) —
  the template for the next release
