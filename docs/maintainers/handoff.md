# Handoff — 2026-08-13

> **Ephemeral.** At most one of these exists; the previous was deleted before this was written. It
> links **out** to the roadmap, ADRs and analyses — nothing links back to it.

## Methodology / where we are

**Phase: Design complete for [FI-58](improvements.md), implementation not started.**
[ADR-0058](integration/agent-teams/decisions/0058-teammate-coordination-tools.md) is **Accepted
(design)** with D1…D11 and one same-day amendment. The analysis that produced it is persisted and
approved.

Nothing is half-done. The working tree is clean.

- Branch **`feat/delegation/return-channel`** at `9ebe0fa`, 3 commits, **unpushed** — carries the
  whole FI-58 line.
- `develop` at `23f0a33`, **1 commit ahead** of `origin/develop`, **unpushed** — a status
  realignment only.

**The pending gate is a sequencing decision, not an approval**: see *How to resume* item 2.

## How to resume

**1. Push, from the host** — the only owed actions that cannot run in a session (network verbs):

```
cd /Users/alessandro/Projects/CaveResistance/Software/claude-orchestrator
git push origin develop
git push origin feat/delegation/return-channel
git push origin --delete feat/access/claude-md-axis     # merged long ago, still on the remote
```

**2. Decide the first implementation unit.** ADR-0058's **D6** (announce the change, naming the
agents affected) is load-bearing **twice** — it is the entire remedy in D10's `rw` cell and in
D11's pass-through case. But `cco start`'s warning stream is write-only today, which is what
[A5](roadmap.md) / [FI-55](improvements.md) exists to fix: **a warning emitted before A5 lands is a
warning nobody reads** ([FI-54](improvements.md) proved this by sitting unread through a full
acceptance run). So the choice is:

- **D4/D5 + D6 together with A5** — one larger unit, D6 actually works; or
- **D4/D5 + D6 without A5** — smaller, and D6 ships knowingly degraded.

There is **no third option that starts with content**: see *Context* below.

**3. Then implement**, against ADR-0058's Verification section — checks 1–7, which are container
checks, **not** suite-green (the lane is invisible to the hermetic suite by construction).

**4. Nothing to clean up.** No scratch files, no stray branches: the two merged branches from the
A4 line were deleted in-session.

## Tasks

The [roadmap](roadmap.md) is the single source of truth for status; this list points at it.

- [ ] **Push `develop` + the feature branch, delete `origin/feat/access/claude-md-axis`** — host-only
- [ ] 🔴 **[FI-58](improvements.md)** — implement ADR-0058 **D4/D5 + D6** (design done; sequencing
      decision above)
- [ ] **[A5](roadmap.md)** — `cco start` must pause on its own warnings
      ([FI-55](improvements.md)) — **now coupled to FI-58 through D6**
- [ ] **[A1](roadmap.md)** — `cco save`, project-config versioning helper (needs a short design)
- [ ] **[A2](roadmap.md)** — per-project custom Docker image ([FI-49](improvements.md); short design)
- [ ] **[A3](roadmap.md)** — cross-scope collision warning ([FI-32](improvements.md)) + three open decisions
- [ ] **[A6](roadmap.md)** — `.claude/worktrees` in the functional-write floor ([FI-56](improvements.md))
- [ ] **[A7](roadmap.md)** — the A4 review residue ([FI-62](improvements.md) … [FI-66](improvements.md))
- [ ] **[A8](roadmap.md)** — onboarding prompts + mount-declaration surface ([FI-68](improvements.md) … [FI-70](improvements.md))
- [ ] **[FI-71](improvements.md)** — config-editor design doc drift; a `documenter` task, out of sequence
- [ ] **Report the upstream defect** — the agent-teams docs claim coordination tools are always
      available to a restricted teammate; **measured false** on 2.1.220 and 2.1.226. Needs a control
      run on a stock installation first (see the analysis §12)
- [ ] **macOS host suite (bash 3.2)** — last run `1626 / 0` on the `v0.6.0` tree; **owed again**
      before the `0.7.0` release, since nothing has re-measured 3.2 on `develop`

## Context

### Decided this session

- **[ADR-0058](integration/agent-teams/decisions/0058-teammate-coordination-tools.md)** — Accepted,
  D1…D11 plus **Amendment A1**. Read the ADR, not this line. Its evidence is
  [analysis-002](integration/agent-teams/analysis/analysis-002-delegation-return-channel.md).
- The maintainer ruled the two questions the ADR opened: **D10** (the `entries.agents=rw` cell is
  warned, never rewritten — deliberately ungoverned, like ADR-0057 D8's mixed cell) and **D11** (an
  unparseable definition passes through with a named warning rather than blocking the session).

### 🔑 Non-obvious things the next session would otherwise rediscover

- 🔑 **cco authors exactly TWO agent definitions** — `defaults/global/.claude/agents/{analyst,
  reviewer}.md`. `core-dev-framework` is the maintainer's **own pack, authored outside cco** (it is
  in this repo only as a reference in `.cco/project.yml`), so **the six roles that fail are user
  content.** This was gotten wrong once in this very session and caught by the maintainer: it
  invents a content-level "quick win" that does not exist, and acting on it means editing a user's
  pack to route around a cco defect. **cco's authorship surface is `defaults/`, `templates/`,
  `internal/`; everything else it reads and projects, never edits**
  ([A1](integration/agent-teams/decisions/0058-teammate-coordination-tools.md#amendments)).
- 🔑 **No prompt-level remedy can work** — measured, not argued. A probe agent *ordered* to call
  `SendMessage` tried and got `No such tool available`. "Instruct the agent better" is inert on a
  restricted toolset. Do not re-propose it.
- 🔑 **ADR-0055 D5 is excluded by measurement**, not by reasoning: no `EACCES` anywhere, transcripts
  persist under the teammate's own cwd key, the lead's socket is bound and listening, inboxes are
  written and drained. **The transport is healthy — do not go back to mounts.**
- 🔑 **Two producers emit agent mounts**: `lib/cmd-start.sh:2220` (global tree) and
  `lib/packs.sh:192` (pack agents, individual file mounts). The failing roles come from the
  **second**. A normalizer wired into one misses the agents that motivated it — that is
  [FI-63](improvements.md)'s second clause, and the fourth recurrence of *a named list is a lower
  bound*.
- 🔑 **`SendMessage` is a *deferred* tool** in current builds: the unrestricted probe had to call
  `ToolSearch` first. Granting the name without the discovery path grants a tool the agent cannot
  find. The guaranteed set is a **set** (ADR-0058 D2), never one name.
- 🔑 **The channel cco owns into every subagent regardless of authorship** is the `SubagentStart`
  hook `config/hooks/subagent-context.sh`, which emits `additionalContext` from
  `CCO_SUBAGENT_CONTEXT` and is baked into managed settings. That is where instructions to
  arbitrary agents belong (ADR-0058 D8 as amended) — not in definitions cco does not own.
- ⚠ **Counting attempts answers a different question than counting outcomes.** Counting
  `SendMessage` *invocations* across teammate transcripts showed a ~60% delivery rate and an
  "intermittent" defect; reading the matching **tool_results** showed **0 of 17** — every call had
  errored. When the question is *did it work*, read the result, never the call.
- 📝 **The reproduction harness is three probes**, and it is the acceptance oracle for the fix:
  spawn the same trivial task as (a) a restricted role, (b) the same role with the normalizer
  disabled, (c) an unrestricted `general-purpose` agent. Delivery arrives as a
  `<teammate-message>`; an idle notification alone means nothing was delivered.
- ⚠ **Verification check 6 must compare the file the agent actually reads**, not the mount mode —
  the FI-25 mask makes every tree `rw` in this project, so a mode-based assertion passes while
  measuring nothing.
- 📝 **Two collateral defects**, recorded but not tracked as separate FIs:
  `run_in_background: false` is **silently ignored** under agent teams (no synchronous run exists),
  and the team stays **pinned to the session that created it** — after a `/clear` the live session
  has a new id while the team is still `session-<old>`, contradicting the documented *"one team per
  session"*. Rule that second surface in or out first if [FI-61](improvements.md) recurs.

### Open questions needing a human

- **The FI-58 sequencing** in *How to resume* item 2 — whether the first unit pulls A5 in.
- **[FI-68](improvements.md)'s capability question**: add `--writable` to `cco project add mount`, or
  fix only the help text. It grants a user-perceivable capability from a one-line command.
- **The `acceptance/` leaf** in the access domain is invented relative to the pack's canonical set
  (`analysis/ design/ decisions/ reviews/`). Moving it would break links — a taxonomy decision.
- The four **open decisions** already listed in the roadmap (bash-3.2 fixtures, the `cco init`
  `$HOME` guard, the duplicated `pack internalize` section, the tutorial preset's "no write risk"
  wording), plus the fifth (does the worktree design move up?).

## Reference documents

- [roadmap.md](roadmap.md) — the living SSOT for status and priorities
- [improvements.md](improvements.md) — the `FI-*` tracker (`FI-1 … FI-71`)
- [ADR-0058](integration/agent-teams/decisions/0058-teammate-coordination-tools.md) — guaranteed
  coordination tools for teammates, D1…D11 + Amendment A1 **(produced this session)**
- [analysis-002 — the delegation return channel](integration/agent-teams/analysis/analysis-002-delegation-return-channel.md)
  — the evidence behind ADR-0058 **(produced this session)**
- [ADR-0057](configuration/agent-cco-access/decisions/0057-ask-enforcement-plane-and-resource-classes.md)
  — Axis-B resource classes; `entries.agents` is the tree ADR-0058 D10 rules on, and D10 borrows its
  mixed-cell shape
- [ADR-0055](environment/decisions/0055-claude-runtime-state-and-mountpoint-ancestry.md)
  — D5, the prior suspect for FI-58, **measured and excluded**
- [ADR-0054](configuration/decentralized-config/decisions/0054-framework-owned-mountpoints.md) — the
  overlay-and-mount mechanism ADR-0058 D4 reuses
