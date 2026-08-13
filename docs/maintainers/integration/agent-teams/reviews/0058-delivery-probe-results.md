# ADR-0058 — delivery probe results (checks 1–5)

**Date**: 2026-08-13 · **Verdict**: **PASS**, with two checks declared unmeasured.
**Subject**: [ADR-0058](../decisions/0058-teammate-coordination-tools.md) D4/D5 + D6, as implemented
on `feat/delegation/return-channel`.
**Historical record** — a point-in-time measurement. Not rewritten; superseded by a later run if one
contradicts it.

> Taxonomy note: this lands in `reviews/` (a canonical leaf) rather than in an `acceptance/` leaf.
> The access domain invented `acceptance/` and whether that leaf is adopted is an **open taxonomy
> question for the maintainer** — propagating it into a second domain ahead of that decision would
> settle it by accident.

## What was run

A real session started from the host with `./bin/cco start` (no `cco build` — everything this unit
changes is produced at start time). Three teammates spawned with the same trivial task: reply with
one fixed string, nothing else.

The oracle is **not** whether the teammate did the work. It is whether the work **arrived**:
a delivery appears in the lead's conversation as a `<teammate-message>` carrying content; an
**idle notification alone means nothing was delivered**.

## Results

| # | Probe | Definition under test | Measured |
|---|---|---|---|
| 1 | `analyst` (pack role, restricted `tools:`, **normalized by cco**) | `~/.cco/packs/core-dev-framework/agents/analyst.md` | ✅ `ToolSearch` → `SendMessage` → `{"success":true,"message":"Message sent to team-lead's inbox"}`; the lead received `<teammate-message>` + content |
| 2 | `general-purpose` (unrestricted) | platform built-in | ✅ delivered — the pass-through is not regressed |
| 3 | `statusline-setup` (**restricted, NOT normalized** — `tools: Read, Edit`, a platform built-in cco does not touch) | platform built-in | ✅ **as expected: nothing delivered.** Zero `tool_use` records; the answer was produced as final text and discarded. The lead received an **idle notification only** |

Check 4 is **partly** covered: the pack producer is probe 1. The **global** producer was not measured
separately — `analyst` and `reviewer` exist in both trees and the project-level pack shadows the
global one, so a probe by name cannot address it. The start-time report shows both global
definitions normalized (`~/.cco/.claude/agents/{analyst,reviewer}.md`), which is the mount half, not
the delivery half.

Check 5 (the teams knob) does not exist yet — D7's knob is unbuilt.

## What this settles

- **The remedy works, and the negative control fell in the SAME session**, on the same Claude Code
  version, over the same transport. A restricted role that cco normalized delivers; a restricted role
  cco does not reach cannot even attempt it. That is the discrimination ADR-0058's check 3 demands,
  obtained without a second session: a platform built-in with an exhaustive `tools:` allowlist is a
  standing negative control, and a better one than a rebuilt session — nothing else varies.
- **D2's `ToolSearch` clause is confirmed empirically, not by reasoning.** Probe 1 called
  `ToolSearch` **before** `SendMessage`. Guaranteeing the channel alone — the obvious choice — would
  have handed the agent a tool it cannot find. The set is a set.
- **FI-58's failure mode was reproduced in vivo** by probe 3: the work is done, the answer is
  written, and it is thrown away with no error anywhere. The user sees "the agent went idle".

## Operational fact worth keeping

**The lead's inbox drains when the lead's turn ends**, not while it runs. Probe 1 and 2 reported
`success: true` and the messages were *not* in the lead's conversation through a long tool-calling
turn; they arrived together the moment the turn closed. A session inspecting its transcript mid-turn
will therefore see "delivered to inbox" and "nothing received" **simultaneously**, and both are
true. Do not read that gap as a second defect — it was nearly filed as one here.

## Not measured

- The **global** agent producer end-to-end (see check 4 above).
- **D10** (`entries.agents=rw` → no projection) and **D11** (unparsable pass-through) in a live
  session. Both are covered by `tests/test_agent_coordination.sh`, whose assertions compare the file
  the agent would read — but a suite cannot show a teammate failing to deliver.

## Defect found by this run

The report classified `.gitkeep` as a definition with no return channel: the committed-tree producer
binds each entry individually, so the placeholder every scaffolded `agents/` dir carries was scanned.
Fixed (`a8fdd62`) — only `*.md` in an `agents/` directory is a definition — with a regression test
proven to discriminate. Left unfixed it would have put noise in the one channel D6 depends on, and
after [A5](../../../roadmap.md) a session would pause on a placeholder file.
