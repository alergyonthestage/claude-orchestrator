# ADR 0058 — Guaranteed coordination tools for teammates

**Status**: **Proposed** — 2026-08-13. Direction approved by the maintainer; the numbered decisions
below and the two questions in *Open for the maintainer* still need a ruling before implementation.
Closes **[FI-58](../../../improvements.md)**.

**Evidence**: [analysis-002 — the delegation return
channel](../analysis/analysis-002-delegation-return-channel.md). Every claim of fact in this ADR is
measured there; it is not restated here.

**Related ADRs**: 0057 (Axis-B resource classes — `entries.agents` is the tree this touches, and
D10's *one assembly point* is the rule D2 and D7 apply); 0054 (framework-owned mountpoints — the
overlay-and-mount mechanism D4 reuses); 0055 D5 (subagent transcript persistence — the prior
suspect, measured and **excluded**); 0019 D5 (three-layer pack resolution — pack agents are one of
the two producers D5 must cover); 0044 (built-in presets — the tutorial and config-editor sessions
inherit whatever this decides).

---

## Context

cco enables agent teams for every session, at the **managed** layer where the user cannot turn them
off (`defaults/managed/managed-settings.json:5`), and puts teammates in tmux panes
(`defaults/global/.claude/settings.json:46`). Upstream ships the feature **disabled** by default.

Enabling it changes the contract of the `Agent` tool: it no longer runs an in-session subagent
whose final text is the return value, it spawns a **separate process** whose deliverable reaches
the lead **only** through `SendMessage`. Ending a turn produces an idle notification carrying no
content.

Every agent definition cco ships — the six pack roles and the two global ones — declares a
restrictive `tools:` allowlist, and none of them lists `SendMessage`. Per the official reference,
`tools` *"inherits all tools if omitted"*; specifying it makes the list exhaustive. So the return
channel does not exist for any cco role agent. Measured: **0 deliverables out of 17 teammates**,
across two Claude Code versions. The work is done, visible in the pane, and thrown away.

Two properties of the failure decide the shape of the remedy:

- **It is silent and misattributed.** The user sees *"the agent went idle"*, never *"a tool is
  missing"*. The maintainer's framing is the requirement: *the user sees an error, does not
  understand it, and blames cco.*
- **It cannot be fixed by instruction.** A probe agent was explicitly ordered to deliver via
  `SendMessage`, tried, and could not. Prompt-level remedies are inert on a restricted agent.

And the users cco must protect are not only its own: packs, project trees and the global store may
each carry arbitrary agent definitions, authored by people who have never heard of `SendMessage`
and have no reason to.

## Principles

- **P1 — what cco enables, cco makes work.** Shipping a feature on by default and leaving its
  operating conditions to the user is not a division of responsibility; it is a defect with a
  blame-shifting story attached.
- **P2 — a guarantee the user must remember is not a guarantee.** The remedy must hold for
  definitions cco never sees before they are written.
- **P3 — user files stay user-owned.** cco may *project* a different view of a file at mount time;
  it may not rewrite the file the user committed (`CLAUDE.md`, *"all installed files are
  user-owned"*).
- **P4 — one producer.** The guaranteed set, and the condition under which it applies, are computed
  once and consumed everywhere (ADR-0057 D10).
- **P5 — a silent remedy is half a remedy.** Anything cco changes about a user's declared toolset
  must be visible to the user.

## Decision

### D1 — the coordination surface is cco's responsibility, not the user's

While cco enables agent teams, cco guarantees that every agent it can spawn can deliver. This holds
whether teams stay always-on or become a configurable knob; the knob changes D7's *condition*, never
D1's *ownership*.

### D2 — the guarantee is a **set**, computed once, not a tool name

The guaranteed set is the **coordination surface**, not `SendMessage` alone:

| Member | Why it is in the set |
|---|---|
| `SendMessage` | the return channel itself |
| the task tools (`TaskCreate`/`TaskUpdate`/`TaskList`/`TaskGet`) | the documented *"teammates sometimes fail to mark tasks as completed, which blocks dependent tasks"* becomes an *always* when the tools are absent |
| the discovery path (`ToolSearch`) | in current builds `SendMessage` is a **deferred** tool: granting it without discovery grants a tool the agent cannot find — measured |

⚠ A remedy that enumerates one name is a partial remedy that still fails. The set is defined in
**one** place and every consumer reads it from there (P4).

### D3 — cco's own definitions move to the subtractive form

Where cco is the author — the `core-dev-framework` pack agents, `defaults/global/.claude/agents/`,
the project templates, and this repository's own roles — restrictions are expressed as
`disallowedTools:` over an inherited toolset, instead of an exhaustive `tools:` allowlist.

`analyst`, for example, states what it must not do (write, edit) rather than enumerating what it
may. Under that form the coordination set is present **by construction**, and a future
infrastructure tool does not silently break the definition — Open-Closed, with no mechanism at all.

📝 D3 alone does **not** satisfy P2: it covers only what cco writes. It is here because it is free,
it fixes cco's own agents immediately, and it is the convention D6 documents.

### D4 — for definitions cco does not author: normalize at `cco start`

cco composes the session's `.claude` view by generating artefacts into session STATE and mounting
them over the real paths — `_emit_managed_settings_overlay`, `_emit_class_overlays`,
`_emit_workflows_overlay`, `_emit_local_settings_overlay`. The normalizer is the same shape: read
each agent definition; if it declares a `tools:` allowlist missing any member of the D2 set, emit a
normalized copy carrying those members and mount **that** copy.

The committed file is never modified (P3). The normalizer is a **pure projection**: same file,
different view, decided at start time.

### D5 — every producer of an agent mount goes through the normalizer

Agent mounts are emitted from **two** places today: `lib/cmd-start.sh:2220` (global tree) and
`lib/packs.sh:192` (pack agents, individual file mounts). The six roles that fail in practice come
from the **pack** — the producer that sits outside the mount emitter, which is also the second
clause of [FI-63](../../../improvements.md).

Normalizing at one producer ships a fix that misses the very agents that motivated it. Both go
through one path, and a **static lint** keeps it that way — the same instrument as INV-P and the
`store-op` CLASS lint, for the same reason: *an invariant believed but unenforced is worse than one
never claimed.*

### D6 — the change is announced, never silent

When cco widens a declared toolset, it says so, naming the agents affected and the reason. The
message is a `⚠ warn`, not a `note:`.

⚠ **Sequence with [A5](../../../roadmap.md)** ([FI-55](../../../improvements.md)): `cco start`'s
warning stream is write-only today — the TUI opens over it and nobody reads it, which
[FI-54](../../../improvements.md) already demonstrated by sitting unread through a full acceptance
run. A warning emitted before A5 lands is a warning that does not exist.

`cco whoami` reports the guarantee as part of the session's state, alongside the two A4 dimensions.

### D7 — the injection is a function of the teams knob, from one source

If agent teams become configurable, the same resolved value decides both *"are teams on"* and
*"is the coordination set guaranteed"*. A session with teams off must not carry a cross-session
messaging tool it has no use for, and no call site re-derives the condition (P4).

### D8 — the file fallback is a documented degraded mode, not the fix

*"If you cannot deliver, write your report to a file with `Bash` and say where"* stays in the role
definitions: `Bash` is in every allowlist, so it survives any future regression of the tool
registry, at the cost of one `Read` for the lead. It is a belt, not the braces — it leaves the lead
unable to distinguish an agent that finished from one that died.

### D9 — the granted capability is declared

Injecting `SendMessage` gives every restricted agent a cross-session communication channel, in a
product whose model is explicit access boundaries and where upstream has hardened messaging against
*permission laundering*. The grant is justified — it is what makes the declared feature work — but
it is written down in the access documentation, not left as a side effect.

## Alternatives considered

| Alternative | Why not |
|---|---|
| **Instruct the agents to deliver** (prompt-level) | measured inert: an agent ordered to call `SendMessage` cannot, because the tool is not registered for it |
| **Document the requirement** and let users list `SendMessage` | violates P2 directly: it is a technical detail the user is not aware of, and the failure is silent |
| **Disable agent teams** (revert to in-session subagents, whose final text returns automatically) | rejected by the maintainer: the feature is used daily and is wanted for cco's users. Remains the fallback if D4 proves too costly |
| **Only fix cco's own definitions** (D3 alone) | leaves every pack, project and user-authored agent broken — the majority case once cco is adopted |
| **Wait for the upstream fix** | the documentation already promises this behaviour and the promise is false in 2.1.220 and 2.1.226; cco cannot ship on a promise. If upstream lands it, D4 becomes a no-op that can be retired — which argues for keeping D4 small and dated, not for skipping it |

## Consequences

- Delegation to a restricted role delivers again; the three-executions cost disappears.
- A user's declared toolset is, in one narrow respect, **not** what runs. That is a real cost: it is
  the *artefact differs from what runs* hazard this project has paid for before
  ([FI-64](../../../improvements.md)). D6 is what keeps it honest, which is why D6 is not optional.
- `--dry-run --dump` must show the normalized set, or it reproduces exactly that hazard.
- One more start-time transformation on the `.claude` view, in a file Block D may rewrite; the
  normalizer must be small enough to move.
- D3 changes shipped opinionated content → `cco update --diff`/`--sync` discovery, per the update
  system rules. D4 is a new code path with no user-visible config → additive, `changelog.yml`.

## Verification

The oracle is the probe triad from the analysis, and it must be shown to **discriminate** before any
result is believed:

1. a **restricted** role (`analyst`, from the pack) delivers to the lead — currently fails;
2. an **unrestricted** agent (`general-purpose`) still delivers — guards against a regression in the
   normalizer's pass-through;
3. the same restricted role with the normalizer **disabled** still fails — proves the test is
   measuring the fix and not the weather;
4. a **pack** agent and a **global** agent both pass — D5's two producers, separately;
5. with teams off (once D7's knob exists), the coordination set is **absent** — proves the condition
   is coupled, not constant.

⚠ Checks 1–5 are invisible to the hermetic suite by construction — they need a real session. This is
the same lane as ADR-0057's acceptance; budget for it as container checks, not as suite-green.

## Open for the maintainer

1. **The `entries.agents=rw` cell.** When the user has asked for a writable agents tree, a
   normalized projection means they edit an overlay rather than their file. Same shape as A4's mixed
   cell. Proposal: normalize only where the tree is mounted `ro`, and in the `rw` cell fall back to
   D6's warning alone — there the user is actively authoring, so a warning is actionable and a
   silent rewrite would be worse.
2. **Unparseable definitions: refuse or pass through?** Refusing blocks a session on a malformed
   user file; passing through re-opens the silent failure the ADR exists to close. Proposal: pass
   through **with a `⚠ warn` naming the file**, on the grounds that cco must not make a session
   unstartable because of a comment in someone's markdown.
