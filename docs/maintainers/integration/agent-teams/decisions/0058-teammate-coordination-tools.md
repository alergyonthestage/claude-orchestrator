# ADR 0058 — Guaranteed coordination tools for teammates

**Status**: **Accepted (design)** — 2026-08-13. Direction approved the same day; **D10 and D11 ruled
by the maintainer** on the two questions this ADR opened, and the sequencing question D6 raised is
ruled in **[A2](#a2--d6-ships-with-d4d5-ahead-of-a5-2026-08-13-maintainer)**. Implementation not
started.
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
📌 **Ruled by [A2](#a2--d6-ships-with-d4d5-ahead-of-a5-2026-08-13-maintainer)**: D6 ships with D4/D5
**ahead of** A5, emitted-but-unread for one release. The obligation to emit it is unchanged.

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
   is coupled, not constant;
6. **D10** — under `entries.agents=rw` **no** normalized copy is projected, the file the agent reads
   is byte-identical to the user's, and the warning is emitted;
7. **D11** — a deliberately malformed definition **starts** the session, is passed through unchanged,
   and is **named** in the warning.

⚠ Check 6 must compare the file **the agent actually reads** against the user's, not the mount mode
— the FI-25 mask makes every tree `rw` in this project, so a mode-based assertion here would pass
while measuring nothing.

⚠ Checks 1–5 are invisible to the hermetic suite by construction — they need a real session. This is
the same lane as ADR-0057's acceptance; budget for it as container checks, not as suite-green.

## D10 — the `entries.agents=rw` cell is warned, never rewritten

**Normalization applies only where the agents tree is mounted `ro`.** Where the user has asked for a
writable tree (`entries.agents=rw`, ADR-0057), cco does **not** project a normalized copy: it emits
D6's warning and leaves the file alone.

The reason is the asymmetry of the two cells, not a preference. Under `ro` the user is a *consumer*
of the definition and a projection is invisible and harmless. Under `rw` the user is **authoring**
it — so a warning is actionable (they can fix it in the file they are already editing), and a
projection would be actively harmful: they would edit an overlay, or read content that is not their
file, which is the *artefact differs from what runs* hazard in its worst form.

⚠ This leaves the `rw` cell **deliberately ungoverned**, exactly as ADR-0057 D8 leaves its mixed
cell. It is a known, published gap — not an oversight to be closed in passing. If Block D changes
the mount topology, revisit it there.

## D11 — an unparseable definition passes through, with a warning

If the normalizer cannot parse a definition, it **passes the file through unchanged and emits a
`⚠ warn` naming it** — it does not refuse the session.

cco must not make a session unstartable because of a stray character in someone's markdown. The
cost is real and is accepted: that one agent keeps the silent-failure behaviour this ADR exists to
close, which is why the warning must name the *file*, not just the condition.

📝 D11 is the one place where this ADR's guarantee does not hold, and D6's visibility is the entire
remedy. That makes D6 load-bearing twice over — once for D10, once here — and settles that it ships
with D4, not after it.

---

## Amendments

### A1 — D3 and D8 misidentified what cco authors (2026-08-13, same day)

**The error.** D3 listed *"the `core-dev-framework` pack agents"* among the definitions cco writes,
and the Context section says *"every agent definition cco ships — the six pack roles and the two
global ones"*. **Both are false.** cco ships exactly **two** agent definitions —
`defaults/global/.claude/agents/{analyst,reviewer}.md`. `core-dev-framework` is authored **outside
cco** and installed into the personal store like any other pack; it appears in this repository only
as a *reference* in `.cco/project.yml`. **The six roles that fail in practice are user content.**

**Why this is not bookkeeping.** The misattribution made D3 look like a *fix* — "rewrite the
definitions and the roles work today" — when it can only ever be a *convention*. Acting on it would
have meant editing a user's pack to work around a cco defect: exactly the remedy **P2** rejects,
putting the guarantee back into content cco does not control, and shifting the cost onto the person
the ADR exists to protect. It also implied a content-level quick win that **does not exist**.

**D3 restated.** Its scope is exactly what cco authors: the two shipped definitions and the agent
templates cco generates from. It is a **convention and a documentation item** — the form cco
recommends to pack and project authors — and it is **never part of the guarantee**. It unblocks
nothing on its own. Only D4/D5 do.

**D8 carried the same error** and is corrected further: the fallback instruction cannot live "in the
role definitions", which are user content. It belongs in the one channel cco owns into **every**
subagent regardless of authorship — the `SubagentStart` hook's `additionalContext`
(`config/hooks/subagent-context.sh`, already baked into managed settings and already carrying
`CCO_SUBAGENT_CONTEXT`). That home is strictly better than the original: it reaches agents cco never
wrote, needs no cooperation from their author, and is the only remedy that still applies in **D11**'s
pass-through case, where normalization has been declined.

**Consequence for the plan.** There is no content-level first step. The first implementable unit is
**D4/D5 with D6**.

📝 The general rule this ADR now states explicitly, because it was violated in its own first draft:
**cco's authorship surface is `defaults/`, `templates/` and `internal/`. Packs, project trees and
the global store are user content — cco reads and projects them, and never edits them.**

### A2 — D6 ships with D4/D5, ahead of A5 (2026-08-13, maintainer)

**The question.** D6 and D11 make the warning load-bearing twice, and D6 itself warns that `cco
start`'s warning stream is write-only until [A5](../../../roadmap.md)
([FI-55](../../../improvements.md)) lands. That left the first implementation unit undecided: pull A5
in, or ship D6 knowingly degraded.

**The decision.** **Ship D4/D5 + D6 now, without A5.** The warning is emitted as designed even while
the stream nobody reads is still the only place it lands. A5 stays a Block-A quick win and is
expected in the **same `0.7.0` release**, which closes the gap by itself — no follow-up work is
created here, and D6 needs no rewrite when it does: A5 changes the *stream*, never the message.

**What is accepted, precisely.** Between this unit shipping and A5 shipping, the start-time `⚠ warn`
is emitted-but-unread. That window is bounded by one release. **The degradation is partial, not
total** — D6's other two surfaces are readable the whole time and do not depend on A5:

- `cco whoami` reports the guarantee as part of the session's state — readable *in* the session,
  which is exactly where the affected user is;
- `--dry-run --dump` shows the normalized set, which is what keeps *"the artefact differs from what
  runs"* honest for anyone inspecting the compose.

**Why not the other way round.** Sequencing A5 first would hold the delegation fix — a **total**,
measured failure (0 deliverables of 17) — behind an ergonomics improvement to a stream. The
asymmetry decides it: without D4/D5 the work is silently thrown away; without A5 the remedy works
and one of its three announcements is merely late.

⚠ **This does not weaken D6.** Emitting the warning is still mandatory, still a `⚠ warn` and never a
`note:` — A5 gates on exactly that distinction, so a message misclassified now stays invisible after
A5 lands. D10's `rw` cell and D11's pass-through keep the warning as their entire remedy; that it is
briefly hard to read is not a licence to skip it.

### A3 — an explicit `disallowedTools` exclusion is honoured, never overridden (2026-08-13, maintainer)

**The case D4 did not cover.** A definition may name a member of the D2 set in `disallowedTools:`
instead of merely omitting it from `tools:` — the shipped definitions already carry both keys
(`tools: Read, Grep, …` **and** `disallowedTools: Write, Edit`), so the two-key shape is the normal
one, not a corner.

**The decision.** **The normalizer adds to `tools:` and never touches `disallowedTools:`.** Where a
member of the set is explicitly excluded, that agent keeps the pre-fix behaviour and is **named in
D6's warning**, exactly as D11's unparseable case is.

**Why.** Omission and exclusion are not the same act. An omitted tool is a **side effect** of the
allowlist form — the user never decided anything about `SendMessage`, which is the whole premise of
this ADR (P2: *a guarantee the user must remember is not a guarantee*). A named exclusion **is** a
decision, taken in the file the user owns (P3). Overriding it would put cco in the position of
silently reversing a line someone wrote on purpose — *the artefact differs from what runs*
([FI-64](../../../improvements.md)) in its sharpest form, on the one line where the user was explicit.
Refusing the session was also rejected, for D11's reason: cco does not become unstartable over the
contents of someone's markdown.

📝 **Consequence, stated plainly**: the guarantee is *"cco never leaves the channel missing by
accident"*, not *"the channel always exists"*. The second is not achievable without overriding user
intent. This is the third place where D6's visibility is the entire remedy — with D10's `rw` cell and
D11 — and the reason the warning must name the **file** and the **member**, so the reader can tell an
exclusion they chose from an omission they never noticed.

### A3 — the *widened* message is a `note`, not a `⚠ warn` (2026-08-18, by [ADR-0059 A1 §A2](../../../cli/decisions/0059-message-classification-and-the-start-warning-gate.md#a2--agentsshs-widened-message-becomes-a-note-amends-adr-0058-a2))

Forward annotation — **A2 is otherwise unchanged**, and its central claim is now discharged: the
start-time warning it shipped deliberately unread *is* read, on the first line of the gate's list
(host acceptance run, 2026-08-18).

What changed is the level of **one** of the two messages this ADR's normalizer emits. *"widened the
declared toolset of N definition(s)"* reports work cco **completed**, on files it did not modify, with
nothing left for the user to decide — an accepted divergence, which under ADR-0059 D2 is a `note` and
does not hold the launch. *"N definition(s) keep NO return channel"* is untouched: there cco could not
fix it, a teammate will finish its work and lose it, and it remains the `⚠ warn` this ADR was written
for.

A2's own wording anticipated the wrong half of this — it expected the gate to make the *widened*
notice matter. In the first real session it was the least actionable of fourteen entries. The gate is
what made that visible, which is what a decision surface is for.
