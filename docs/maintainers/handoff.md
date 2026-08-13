# Handoff — 2026-08-13 (evening)

> **Ephemeral.** At most one of these exists; the previous was deleted before this was written. It
> links **out** to the roadmap, ADRs and analyses — nothing links back to it.

## Methodology / where we are

**[FI-58](improvements.md) is CLOSED** — designed, implemented, **verified in a live session**, and
**merged into `develop`**. Nothing from it is half-done and the working tree is clean.

**Phase for the next session: Design (short), not Implementation.** The queue returns to
[Block A → `0.7.0`](roadmap.md), whose next item is **A5** (`cco start` must pause on its own
warnings, [FI-55](improvements.md)). The roadmap pairs **A5 with A8** in one short design over the
same interactive surface, and **A8 carries a decision only the maintainer can take** — so the gate
ahead is a design gate, not a build. Do not open the editor on `lib/cmd-start.sh` first.

- `develop` at **`979a0e4`**, **14 commits ahead** of `origin/develop`, **unpushed**.
- The feature branch is merged and deleted locally; `origin/feat/delegation/return-channel` still
  exists on the remote.

## How to resume

**1. Push, from the host** — the only owed actions that cannot run in a session (network verbs):

```
cd /Users/alessandro/Projects/CaveResistance/Software/claude-orchestrator
git push origin develop
git push origin --delete feat/delegation/return-channel
git push origin --delete feat/access/claude-md-axis     # merged long ago, still on the remote
```

**2. Answer A8's open decision before designing** ([FI-68](improvements.md)): add `--writable` to
`cco project add mount`, or fix only the help text and leave writable mounts to `project.yml`. It
grants a user-perceivable capability from a one-line command, so it is a human gate.
⚠ **FI-68 arrived with its premise inverted** — the report says "the default is rw"; the code
defaults `readonly` to **`true`** (`lib/local-paths.sh:312`), as documented. **The default is not in
scope.** An implementer taking the report at face value would invert a shipped security default.

**3. Then design A5 + A8 together** (one short design over the same surface — see the roadmap's A8
entry for why splitting them derives the TTY contract twice, and the second derivation is the one
that hangs the suite). Two constraints A5 must satisfy, both already paid for once:
- the prompt gates on `_cco_have_tty` and honours `CCO_NONINTERACTIVE=1`;
- **only `⚠ warn` gates**, never `note:`/`ℹ`. Classifying every start-time message honestly is the
  real work; the prompt itself is small.

**4. A5 now has a concrete warning waiting for it.** The FI-58 normalizer emits a real `⚠ warn` when
it widens a toolset or when it finds a definition it cannot fix — [ADR-0058
A2](integration/agent-teams/decisions/0058-teammate-coordination-tools.md#amendments) shipped it
knowing nobody can read it until A5 lands. That is the first message A5 should be tested against.

## Tasks

The [roadmap](roadmap.md) is the single source of truth for status; this list points at it.

- [ ] **Push `develop` + delete the two merged remote branches** — host-only (command block above)
- [ ] **[A5](roadmap.md)** — `cco start` must pause on its own warnings ([FI-55](improvements.md)) —
      **design first**, paired with A8
- [ ] **[A8](roadmap.md)** — onboarding prompts + mount-declaration surface
      ([FI-68](improvements.md) … [FI-70](improvements.md)) — **carries the open decision above**
- [ ] **[A1](roadmap.md)** — `cco save`, project-config versioning helper (needs a short design)
- [ ] **[A2](roadmap.md)** — per-project custom Docker image ([FI-49](improvements.md); short design)
- [ ] **[A3](roadmap.md)** — cross-scope collision warning ([FI-32](improvements.md)) + three open decisions
- [ ] **[A6](roadmap.md)** — `.claude/worktrees` in the functional-write floor ([FI-56](improvements.md))
- [ ] **[A7](roadmap.md)** — the A4 review residue ([FI-62](improvements.md) … [FI-66](improvements.md))
- [ ] **[FI-71](improvements.md)** — config-editor design doc drift; a `documenter` task, out of sequence
- [ ] **FI-58 leftovers** — ADR-0058's **D3** (cco's own two definitions in the subtractive form),
      **D7** (the teams knob) and **D8-as-amended** (fallback instruction in the `SubagentStart`
      hook) are unbuilt. ⚠ D8 touches a **baked** file (`config/hooks/subagent-context.sh`), so
      whichever unit takes it also takes a `cco build` in its acceptance lane
- [ ] **Report the upstream defect** — `llms-full.txt:543` states *"Team coordination tools such as
      `SendMessage` and the task management tools are always available to a teammate even when
      `tools` restricts other tools"*. **Measured false** on 2.1.220 and 2.1.226, and again this
      session. Needs a control run on a stock installation first (analysis-002 §12)
- [ ] **macOS host suite (bash 3.2)** — last full run `1626 / 0` on the `v0.6.0` tree; **owed again**
      before the `0.7.0` release. `lib/agents.sh` was parse-checked on real bash 3.2 via the Docker
      socket, but the *suite* has not run on 3.2 since

## Context

### Decided this session

- **[ADR-0058 A2](integration/agent-teams/decisions/0058-teammate-coordination-tools.md#amendments)**
  — D6's warning ships **ahead of A5**, emitted-but-unread for one release. Read the ADR, not this
  line.
- **[ADR-0058 A3](integration/agent-teams/decisions/0058-teammate-coordination-tools.md#amendments)**
  — a coordination tool named in `disallowedTools:` is **honoured**, never overridden.
- **Unit scope** was fixed to D4/D5 + D6 only, keeping a baked file (and therefore a `cco build`)
  out of the acceptance lane.
- **Taxonomy, provisional and worth ratifying**: the probe record went to
  `integration/agent-teams/reviews/`, a **canonical** leaf — deliberately **not** the `acceptance/`
  leaf the access domain invented, because propagating that leaf into a second domain would settle
  an open taxonomy question by accident. Still listed under *Open questions*.

### 🔑 Non-obvious things the next session would otherwise rediscover

- 🔑 **The lead's inbox drains when the lead's TURN ENDS**, not while it runs. Mid-turn, a teammate
  transcript saying `{"success":true,"message":"Message sent to team-lead's inbox"}` and a lead
  conversation containing nothing are **both true simultaneously**. This was one step from being
  filed as a second defect. Close the turn before concluding anything about delivery.
- 🔑 **A standing negative control for delegation exists and needs no restart**: a *platform
  built-in* with an exhaustive `tools:` allowlist — `statusline-setup` (`tools: Read, Edit`) — is
  restricted exactly like a cco role agent and is a definition **cco never touches**. Spawn it beside
  a normalized role: it makes **zero tool calls**, its answer is produced as text and discarded, and
  the lead gets an **idle notification with no content**. Nothing else varies, which is stronger
  discrimination than rebuilding a session with the fix disabled.
- 🔑 **Delivery is a `<teammate-message>` carrying content. An idle notification alone is a
  non-delivery.** That is the oracle; `success: true` in the sender's transcript is not.
- 🔑 **`ToolSearch` in the guaranteed set is measured, not argued** — the restricted role called
  `ToolSearch` *before* `SendMessage`. Guaranteeing the channel alone would grant a tool the agent
  cannot find.
- 🔑 **The agent-mount producer list was a lower bound — the fifth recurrence in this repo.** ADR-0058
  D5 names two; the code has **four**: the global tree (`lib/cmd-start.sh`, whole-directory mount),
  pack agents (`lib/packs.sh`, per-file), the **committed project tree** (per-entry through
  `_emit_claude_view`, or whole through the no-injection arm), and the **repo-native** trees
  (`<repo>/**/.claude`, recursive). The last two are empty in this repo and populated in an adopting
  one. `INV-AGN` therefore keys on the mount **target**, not a call-site list, and **declares its own
  limit**: a static lint cannot see a fully dynamic target.
- ⚠ **`lib/cmd-start.sh` now depends on `lib/agents.sh`.** A context that sources the former without
  the latter emits mounts with an **EMPTY source** — not merely unnormalized ones. It surfaced as two
  `test_start_claude_view` failures; the fix is to source it exactly as `bin/cco` does.
- 📝 **`cco start` is host-only in a session**, so no in-container check can exercise the compose
  generator end to end. What *can* be run in-session: source the lib modules and call
  `_generate_pack_mounts` directly against the real pack (that is how the six roles were confirmed
  before the live run).
- 📝 **No `cco build` was needed for any of this** — the projection is produced at start time by
  `./bin/cco` on the host. The rule stands: only baked files (image, `config/`, `defaults/managed/`)
  force a rebuild.
- 📝 **Two collateral defects remain recorded, not tracked as FIs**: `run_in_background: false` is
  silently ignored under agent teams, and a team stays pinned to the session that created it. Rule
  the second in or out first if [FI-61](improvements.md) recurs.

### Open questions needing a human

- **[FI-68](improvements.md)'s capability question** — the A8 gate, restated in *How to resume* item 2.
- **The `acceptance/` leaf** — invented in the access domain relative to the pack's canonical set
  (`analysis/ design/ decisions/ reviews/`). This session put its probe record in `reviews/` rather
  than spread the contested leaf. Ratify one way or the other; moving existing files breaks links.
- The four **open decisions** already listed in the roadmap (bash-3.2 fixtures, the `cco init`
  `$HOME` guard, the duplicated `pack internalize` section, the tutorial preset's "no write risk"
  wording), plus the fifth (does the worktree design move up?).

## Reference documents

- [roadmap.md](roadmap.md) — the living SSOT for status and priorities
- [improvements.md](improvements.md) — the `FI-*` tracker (`FI-1 … FI-71`)
- [ADR-0058](integration/agent-teams/decisions/0058-teammate-coordination-tools.md) — guaranteed
  coordination tools, D1…D11 + amendments A1/A2/A3
- [Delivery probe results](integration/agent-teams/reviews/0058-delivery-probe-results.md) — the live
  verification **(produced this session)**
- [analysis-002](integration/agent-teams/analysis/analysis-002-delegation-return-channel.md) — the
  evidence behind ADR-0058
- [ADR-0057](configuration/agent-cco-access/decisions/0057-ask-enforcement-plane-and-resource-classes.md)
  — Axis-B resource classes; `entries.agents` is the cell ADR-0058 D10 rules on
- [ADR-0054](configuration/decentralized-config/decisions/0054-framework-owned-mountpoints.md) — the
  overlay-and-mount mechanism the normalizer reuses
