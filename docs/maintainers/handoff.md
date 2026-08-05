# Handoff — **A4 is designed, measured and scheduled. Nothing is in flight. Next: push, then open an implementation unit in Block A.**

> **Ephemeral.** Delete this file before writing the next handoff. It links out only.
> Written 2026-08-05. Supersedes the handoff of the same day (*"merge this branch, then open Block A"*)
> — **that merge is done**. Status SSOT: [roadmap](roadmap.md).

## Methodology / where we are

Phase: **Design — complete, accepted, and persisted.** No code was touched this session; nothing is
half-done and the suite was not run (there was nothing to run it against).

A design dialogue with the maintainer settled the question FI-18 had been holding since 2026-07-15,
and did it across a wider scope than the note anticipated. The outcome is
**[ADR-0057](configuration/agent-cco-access/decisions/0057-ask-enforcement-plane-and-resource-classes.md)**,
accepted, with its four gating measurements **run on the host and passed** the same day.

**Gates**: none pending on analysis/design. What is pending is a **push** — and then approval to open
an implementation unit.

## How to resume

1. **Push.** `develop` is **6 commits ahead** of `origin/develop` (the whole `docs/roadmap/restructure`
   branch, now merged fast-forward and deleted — note it was **6** commits, not the four the previous
   handoff claimed). `feat/access/claude-md-axis` is **6 commits ahead of `develop`** and exists only
   locally. Both pushes are host-side.
2. **Read [`roadmap.md`](roadmap.md)** — the plan, in order. Block A now has a fourth item.
3. **Choose which unit opens.** Block A's items are self-contained and its internal order was never
   ratified as a priority, so this is a real choice and it is **not** made here:
   - **A1 (`cco save`)** — what the previous handoff designated. Its first move is not code: it is
     choosing the verb name, because three surfaces disagree.
   - **A4 (the `ask` plane)** — the only unit in the block whose **design is finished and whose
     preconditions are already measured**, so it can start with code on day one.

## Tasks

Status lives on the [roadmap](roadmap.md); this is the checklist, not a second source of truth.

- [ ] **Push** `develop` and `feat/access/claude-md-axis` (host-side)
- [ ] **Block A → `0.7.0`** — [roadmap §Block A](roadmap.md)
  - [ ] **A1** `cco save` — verb name + 5 listed decisions, then implement
  - [ ] **A2** per-project custom Docker image — [FI-49](improvements.md); sub-problem 3 first, by
        running it
  - [ ] **A3** cross-scope collision warning — [FI-32](improvements.md)
  - [ ] **A4** `ask` plane + Axis-B resource classes — **design done**
        ([ADR-0057](configuration/agent-cco-access/decisions/0057-ask-enforcement-plane-and-resource-classes.md)),
        build from [`design.md` §4bis.1](configuration/agent-cco-access/design.md)
- [ ] **Cross-cutting analysis** — resource taxonomy + configuration-scope model; gates B and C
- [ ] **Block B → `0.8.0`** · **Block C → `0.9.0`** · **Block D → `1.0.0`** — unchanged

## Context

### What was decided this session, and why

All of it is in ADR-0057; do not re-derive it from this file. The three things most likely to be
re-litigated by someone who has not read it, each recorded there **as a principle**:

- **`ask` does not weaken minimum privilege.** It grants the capability to *request*, never to write
  unilaterally — so the default `entries.claude_md: ask` is not a widened default in P3's sense.
- **Axis A (`cco_access`) never accepts `ask`.** ADR-0047's setuid enforcement point lives in a
  different trust domain and has no channel to a dialog; a third value in the session descriptor could
  only be mapped fail-open or incoherently.
- **`settings.json` and hooks stay outside the class set** — they *are* the enforcement plane. This
  narrows the guarantee sentence [FI-48](improvements.md) was going to publish, and the narrower,
  true version is written in ADR-0057 D4 so C2 does not publish the wider one by accident.

### Measured, not deduced — do not re-run before designing on it

Record: [`probe-ask-enforcement-plane.md`](configuration/agent-cco-access/analysis/probe-ask-enforcement-plane.md)
(2026-08-05, macOS host, purpose-built image, each probe with a negative control).

- A generated file **can** overlay the baked `/etc/claude-code/managed-settings.json`.
- A **managed** `ask` prompts under `bypassPermissions`, in the tmux TUI, on a `**` glob matching a
  **nested** file; a non-matching sibling stays silent; a refusal is honoured.
- A lower-layer `allow` does **not** remove it — which is what lets cco stop merging its rules with
  pack- and user-authored ones and let the layers compose.
- An unanswered dialog **blocks**: no timeout, no self-resolution. Autonomy is therefore **declared**
  (`claude_access: none|repo|all`), never inferred — cco cannot detect that nobody is watching.

### Non-obvious things the next session would otherwise rediscover

- 📝 **`changelog.yml` is owed AT implementation, not now.** It is shipped-behaviour documentation and
  A4 does not exist yet. Writing it early lies in the direction the lifecycle rule calls worse than lag.
- ⚠ **A4's behaviour change runs in two directions**: `Cp`'s `CLAUDE.md` opens (gated), and
  `<repo>/**/CLAUDE.md` **tightens** from silent `rw` to prompted. The second is the one users notice.
- ⚠ **Acceptance for A4 is not suite-green** — the lane is invisible to the hermetic suite by
  construction (RC-17, fourth recurrence). Six container checks are listed in the ADR's Verification.
- 📝 **Next free ADR number is 0058.** ADR-0038 and ADR-0040 still do not exist as documents — they are
  numbers reserved by older roadmap entries.
- 📝 **The probe protocol was re-homed out of `scratchpad/`** (gitignored) into
  `configuration/agent-cco-access/analysis/`. Check there before concluding a measurement was lost.
- 📝 **`defaults/` is pristine.** The maintainer baked a probe rule into `managed-settings.json`, then
  un-baked it and rebuilt; verified — `git diff` under `defaults/` is empty. The image carries no
  probe rule.
- ⚠ **`git stash -u` half-applies in-container.** Promoted to a [standing operational
  note](roadmap.md#standing-operational-notes) rather than left here, since it will recur: the stash is
  created complete, the cleanup aborts on the read-only `.cco` mountpoints, and the tracked
  modifications stay in the tree.
- 📝 **Test baseline unchanged** — no code touched. In-container `1619/7` masked, macOS host `1626/0`.

## Reference documents

- [Roadmap](roadmap.md) — **start here** · [improvements.md](improvements.md) — the tracker,
  `FI-1 … FI-51` ([FI-18](improvements.md) is now ✅ Designed) ·
  [roadmap-history.md](roadmap-history.md) — cycle 1 and before
- **A4's three documents, in reading order**:
  [ADR-0057](configuration/agent-cco-access/decisions/0057-ask-enforcement-plane-and-resource-classes.md)
  (the decision and why) →
  [`design.md` §4bis.1 + INV-P](configuration/agent-cco-access/design.md) (what the implementer builds) →
  [the measurement record](configuration/agent-cco-access/analysis/probe-ask-enforcement-plane.md)
  (what is already proven)
- [`configuration/agent-cco-access/analysis/config-mount-topology.md`](configuration/agent-cco-access/analysis/config-mount-topology.md)
  §3.3 and §8 — **Block D starts here**
- [Gates runbook](configuration/agent-cco-access/e2e-review/fix-design-v3.1/08-gates-to-release.md) —
  the template for the next release
