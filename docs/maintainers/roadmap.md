# Roadmap

> **The living single source of truth** for status and priorities. Cross-cutting by nature — it spans
> every domain — and kept current: updated at `/plan`, when `/implement` closes a unit, at
> `/review-docs`, and at `/handoff`.
>
> **Last updated: 2026-08-09** — **A4** was added to Block A on 2026-08-05, implemented the same day,
> **accepted on 2026-08-06 after a re-run** (5 pass · 1 measured-and-amended), and its
> **implementation review passed on 2026-08-08** with two objective defects fixed in place — both on
> the security surface, both in shapes the acceptance run structurally could not reach.
> [FI-52](improvements.md) is **decided** (options 1+4) and no longer blocks. Thirteen items entered
> the tracker across the two days (`FI-54 … FI-66`): two are new Block A quick wins, five are the
> review residue (A7), and one — **FI-58**, subagent deliverables never reaching the lead — is
> **pulled ahead of the queue**. The **block order** below was ratified on **2026-08-04** and replaces
> every prior sequencing note; none of this changes it.
>
> **2026-08-09** — a **pre-merge gate review** of the whole A4 branch found no new objective defect and
> fixed nothing in place, but raised one **REVIEW NEEDED**: [FI-67](improvements.md), where
> `claude_access: none` did **not** lock `<repo>/**/CLAUDE.md` while three living documents said it did.
> ✅ **Closed the same day** as
> [ADR-0057 A2](configuration/agent-cco-access/decisions/0057-ask-enforcement-plane-and-resource-classes.md#amendments)
> — options 1+2 together: `none` now emits the **deny** half of D8, **and** the three claims were
> reworded, because on that surface cco holds a **gate**, not a boundary. The measurement A2 rests on
> also closed [FI-10](improvements.md), open since 2026-06-30. **A4 and the FI-67 fix are merged into
> `develop`** (`3ca4cfa`) — see *Where the project stands* for the push that is still owed.
> Three field reports the same day became **A8** ([FI-68](improvements.md) … [FI-70](improvements.md)),
> in Block A: the onboarding prompts and the mount-declaration surface. ⚠ One of the three
> (**FI-68**) arrived with its premise **inverted** — the read-only default it asks for is already
> shipped; only the flag surface is wrong. The entry says so, because acting on the report as written
> would invert a security default.
>
> **2026-08-09, `/review-docs`** — the post-merge docs pass realigned the surfaces A4/A2 had left
> behind: the `project.yml` reference and the `~/.cco/access.yml` scaffold (neither knew about `ask`
> or `entries`), the repo `CLAUDE.md` and the CLI-surface matrix (two-valued Axis-B lattice),
> `cco start --help` (still *"`none` (locked)"* after A2 renamed it *refused*), `design.md` §4bis's
> header, and a forward annotation on the acceptance record's check 4. It raised three items:
> ✅ `cli.md`'s guarantee block read *"a refusal when it is `ro`"* while A2's predicate denies only
> when **every** in-reach tree resolves `ro` — the FI-67 failure mode one level down, in text written
> the same day. **Fixed** (`32f15c8`): the block now names the combination that gets neither rule and
> why, leaving the *code* gap where it already was, as A1's residue for Block D.
> ✅ `handoff.md` was stale — rewritten by this `/handoff`.
> 📄 [FI-71](improvements.md) — `design-config-editor.md` still describes an access model **replaced
> twice** (ADR-0048, ADR-0049 §8) and overstates the built-in's privilege. Filed, scheduled at the top
> of *Not in the sequence*, and left to the `documenter`: the doc predates two ADRs, so the three
> flagged lines are a lower bound.
> Full record: [post-merge docs review](configuration/agent-cco-access/reviews/2026-08-09-post-merge-docs-review.md).

## The planning documents — and why there are three

The pack convention is **exactly one `roadmap.md`**. The other two are not competing plans; each is a
different document class, and the roadmap links out to both.

| File | Class | Holds |
|---|---|---|
| **`roadmap.md`** (this file) | living | The only roadmap: current state, the ordered plan, open decisions |
| [`improvements.md`](improvements.md) | living notes + closed records | The issue tracker, `FI-1 … FI-70`, each with its own analysis. **Not a roadmap** — it is the detail the roadmap cites |
| [`roadmap-history.md`](roadmap-history.md) | historical | Immutable chronology: closed cycles, completed sprints, the resolved-bug log |
| `handoff.md` | ephemeral | Session state; deleted before the next one is written. **Deliberately not linked** — an inbound link would dangle the moment it is consumed |

Before 2026-08-04 the issue tracker was named `roadmap-backlog.md`, which made it read as a second
plan. Git holds the rename.

## Where the project stands

**`v0.6.0` is released** (2026-08-04) on npm as
[`@claude-orchestrator/cco`](https://www.npmjs.com/package/@claude-orchestrator/cco), published by CI
through OIDC trusted publishing. It closed the whole agent↔cco access line: the acceptance rounds
(e2e v2 → v3 → v3.1) and their fix cycles (1 → 1.1 → 1.2) are **finished and accepted**; the
narrative, the lessons, and the per-stage records live in
[roadmap-history.md](roadmap-history.md).

- **The upgrade is three commands**, in this order:
  `npm update -g @claude-orchestrator/cco && cco update && cco build`. `cco update` has never rebuilt
  the image and nothing else does, so a session started without the rebuild silently runs the previous
  release. **Block B exists to end this.**
- **Branches**: `main` is an *ancestor* of `develop` (no divergence, no backmerge owed); both carry
  `0.6.0`. ✅ **`develop` is level with `origin/develop`** at `c93ea38` (the FI-58 merge and its
  history are pushed), and both stale remote branches — `feat/delegation/return-channel`,
  `feat/access/claude-md-axis` — are **deleted**. Nothing is owed to the remote on `develop`.
  ⚠ **`feat/cli/start-warning-gate` is 7 commits ahead and unpushed** — the A5/A8 design phase
  (ADR-0059 + its design doc, 3 commits) and **U1's implementation** (4 commits, 2026-08-14). It is
  the branch U2 continues on. Push it from the host before anything else.
  📝 Its local deletion needed `-D`, not `-d`: the branch was fully merged into `develop` but *ahead*
  of its own stale remote-tracking ref, and `-d` reads that ref, not `develop`. Verify with
  `git log develop..<branch>` (empty = safe), never by trusting `-d`'s refusal.
  ⚠ **Push with `--follow-tags`** when a tag is involved — a bare `git push` leaves the tag behind
  and `release.yml` never fires.
- **Test baseline**: in-container **1654 passed / 7 failed of 1661**, measured on `develop` after the
  FI-58 merge (2026-08-13, mask on) — +21 over the previous baseline, all from that unit. Previously
  **1633 passed / 7 failed of 1640** on `develop` at `3ca4cfa` (2026-08-09, mask on) — the 7 verified **name for name** as the known host-only set
  (6 `test_as_*` + `test_paths_symlink_safe_tool_root`, defeated by the ADR-0047 boundary,
  [FI-19](improvements.md)). +2 against A4's `1631/7 of 1638`: the FI-67 regression pair. The last
  macOS host run (bash 3.2) was **1626 / 0** on the `v0.6.0` tree — **owed again** before the `0.7.0`
  release, since nothing has re-measured 3.2 since. Unmasked the count is `…/9` (the 7 plus 2 update
  tests the mask hides).
  📝 **The FI-25 mask (`access: {claude: all}` in `.cco/project.yml`) is ON** — commented out on
  2026-08-06 to run the A4 acceptance, then **deliberately restored** once it was done, so that
  `defaults/` and `templates/` stay editable in self-dev sessions until [FI-25](improvements.md) gives
  them a narrower grant. The working tree is clean; masked in-container figures are the `…/7` ones.
  ⚠ **Consequence for any future A4 measurement in this project**: the mask makes every tree `rw`, so
  `max()` absorbs `ask` and no rule is emitted — pin the shape with an explicit `--claude-access`
  instead, exactly as the runbook does.
- **Next free ADR number: 0060** (0059 = message classification + the start warning gate,
  **Accepted (design)** with D1…D15; 0058 = teammate coordination tools, **implemented** for D4/D5+D6,
  D1…D11 + amendments A1–A3). ⚠ **ADR-0038 and
  ADR-0040 do not exist as documents** — they are
  numbers reserved by earlier roadmap entries for workstreams D and F. Whoever writes them writes them
  for the first time; do not go looking for a file.

## The plan — order ratified 2026-08-04

Four blocks, sequenced **A → B → C → D**, with one shared analysis pulled ahead of B. The criterion is
not size but **which layer an item touches**, because that is where items collide with each other.

| Block | Subject | Release | Why here |
|---|---|---|---|
| **A** | Quick wins and coherence debts | `0.7.0` | Each item is self-contained; three of them close inconsistencies already shipped |
| **—** | **Cross-cutting analysis**: resource taxonomy + scope model | *none* | Read-only. Feeds B, C and D; moving it earlier costs no release |
| **B** | Lifecycle & distribution | `0.8.0` | The upgrade UX, and splitting `cco update`'s conflated responsibilities |
| **C** | Shared-resource platform (packs & config) | `0.9.0` | **This is what unblocks external projects and packs** |
| **D** | Cycle-2: config multiplicity, divergence, mount topology | `1.0.0` | The last open architectural debt |

```mermaid
flowchart LR
  A["Block A<br/>quick wins<br/>0.7.0"] --> AN["Cross-cutting analysis<br/>resource taxonomy + scope model"]
  AN --> B["Block B<br/>lifecycle and distribution<br/>0.8.0"]
  AN --> C["Block C<br/>shared-resource platform<br/>0.9.0"]
  AN --> D["Block D<br/>cycle-2 topology<br/>1.0.0"]
  B --> C
  C --> D
  B -. "declares the boundary,<br/>C implements the other side" .-> C
```

Two ordering constraints are load-bearing:

- **`cco attach` goes before Block D.** Both rewrite `lib/cmd-start.sh` — one the container lifecycle,
  the other the mount composition. Sequential either way; the smaller one first.
- **The shared analysis goes before B's design.** B must strip `cco update` of the opinionated-content
  responsibility, and *what an opinionated resource is* is decided by that analysis. Designing B first
  would settle the boundary by implementation.

---

### ✅ Closed — the delegation channel ([FI-58](improvements.md))

**DONE 2026-08-13**: implemented, verified in a live session, and **merged into `develop`**
(`979a0e4`, a `--no-ff` merge of 13 commits; the feature branch is deleted locally and
`origin/feat/delegation/return-channel` still needs deleting from the host). Suite **1654/7 of
1661** (mask on), the 7 the known host-only set. The detail below is kept because the *unfinished*
parts of ADR-0058 are listed in it — D3, D7 and D8-as-amended are unbuilt.

**Investigation DONE 2026-08-13 — the fix is now a Block-sized unit.** Priority set by the
maintainer 2026-08-06, on cost.
📄 [analysis-002](integration/agent-teams/analysis/analysis-002-delegation-return-channel.md) ·
📌 [ADR-0058](integration/agent-teams/decisions/0058-teammate-coordination-tools.md) — **Accepted
(design) 2026-08-13**, D1…D11. Design gate passed; implementation not started.

**The gating question is answered: it IS cco's surface**, and not the one anyone expected. cco
enables agent teams at the **managed** layer, which turns the `Agent` tool into a teammate spawner
whose deliverable travels **only** through `SendMessage` — and `SendMessage` is absent from the
`tools:` allowlist of every cco role agent. Measured **0 deliverables out of 17 teammates** across
two Claude Code versions: not intermittent, total, and tracking the *agent type*.

⚠ Two things a fix session must not re-derive. **ADR-0055 D5 is excluded by measurement** — no
`EACCES`, transcripts persist, socket listening, inboxes drained: the transport is healthy. And
**no prompt-level remedy works** — a probe ordered to call `SendMessage` tried and could not.

✅ **D4/D5 + D6 IMPLEMENTED 2026-08-13** on `feat/delegation/return-channel` — `lib/agents.sh` (the
D2 set + the normalizer), all **four** producers routed, `INV-AGN`, `cco whoami`, the report mounted
at `/etc/cco/agents-report`, user docs + `changelog.yml` #64. Suite **1653/7 of 1660** in-container
(mask on), the 7 verified name for name as the known host-only set; +20 tests, zero regressions. The
19 new tests were shown to **discriminate**: with the projection neutralised, 8 of them fail.
✅ **VERIFIED IN A LIVE SESSION 2026-08-13 — checks 1–3 PASS**
([results](integration/agent-teams/reviews/0058-delivery-probe-results.md)). A restricted pack role
delivered (`ToolSearch` → `SendMessage` → `success:true` → `<teammate-message>` at the lead); the
unrestricted agent still delivered; and the **negative control fell in the same session** — a
platform built-in with an exhaustive `tools:` allowlist, which cco does not touch, made **zero tool
calls** and reached the lead as an **idle notification with no content**. That is FI-58 reproduced in
vivo beside its fix, with nothing else varying.
🔑 **D2's `ToolSearch` clause is now measured, not argued**: the restricted role had to search for
`SendMessage` before it could call it. Guaranteeing the channel alone would have granted a tool the
agent cannot find.
📝 **Check 4 is only half done** (the *pack* producer; the global one is shadowed by the pack and
cannot be addressed by name), and **checks 6–7 (D10/D11) were not run live** — the suite covers them.
📝 **Operational fact**: the lead's inbox drains when the lead's **turn ends**, not while it runs. A
mid-turn transcript read shows "delivered to inbox" and "nothing received" at once, and both are
true — this was nearly filed as a second defect.

**What it needs now**: implementation, and **there is no content-level quick win** — see
[A1](integration/agent-teams/decisions/0058-teammate-coordination-tools.md#amendments). The first
unit is **D4/D5 + D6**: the normalizer, a lint over **every** producer of an agent mount
(`lib/cmd-start.sh:2220` and `lib/packs.sh:192` are the two the ADR names — [FI-63](improvements.md)'s
clause — and they are a **lower bound**, see below), and the warning.

✅ **The sequencing question is answered (2026-08-13, maintainer):
[ADR-0058 A2](integration/agent-teams/decisions/0058-teammate-coordination-tools.md#amendments)** —
**D4/D5 + D6 ship now, without A5**. The `⚠ warn` is emitted as designed even though the start-time
stream stays write-only until A5, which is a Block-A quick win expected in the **same `0.7.0`
release**. The degradation is partial and bounded by one release: `cco whoami` and `--dry-run --dump`
carry the same information and are readable throughout. A5 changes the stream, not the message, so
nothing here is rewritten when it lands — but the message must be classified honestly as a `⚠ warn`
**now**, or A5 will not gate on it later.

**Unit scope, fixed 2026-08-13**: **D4/D5 + D6 only**. D3 (cco's own two definitions in the
subtractive form) and D8-as-amended (the fallback instruction in the `SubagentStart` hook) are
separate later units — D8 in particular touches a **baked** file (`config/hooks/subagent-context.sh`),
which would add a `cco build` to this unit's acceptance lane. As scoped, the unit is verified by a
plain `cco start` from the host: everything it changes is produced at start time by `./bin/cco`.
📌 **[A3](integration/agent-teams/decisions/0058-teammate-coordination-tools.md#amendments)** rules
the case the design left open: a member of the set named in `disallowedTools:` is **honoured**, the
agent is named in D6's warning, and `disallowedTools:` is never rewritten.

⚠ **The producer list is a lower bound** — the same shape that has already cost this project four
times. An agent definition reaches a session through **four** paths today, not two: the global tree
(`~/.cco/.claude/agents`, whole-directory mount, `lib/cmd-start.sh:2220`), pack agents (per-file
mounts, `lib/packs.sh:199`), the **committed project tree** (`<repo>/.cco/claude/agents/`, bound
entry-by-entry through `_emit_claude_view` or whole through the no-injection arm at
`lib/cmd-start.sh:2286`), and the **repo-native trees** (`<repo>/**/.claude/agents`, recursive, at
`lib/cmd-start.sh:2511`). The last two are empty in this repo and populated in an adopting one, which
is precisely how they stay invisible to a fix that enumerates producers. **So D5's lint keys on the
mount TARGET** (`*/.claude/agents/*`), not on a list of call sites: a fifth producer is then covered
the day it is written.

### Block A — quick wins and coherence debts → `0.7.0`

Minor bump, not a patch: it introduces new verbs and a new access knob. Nothing here needs an analysis
phase; A1 and A2 need a short design, A3 needs none, and **A4's design is already done and accepted**
([ADR-0057](configuration/agent-cco-access/decisions/0057-ask-enforcement-plane-and-resource-classes.md)).
✅ **A5 and A8's shared design is done and accepted** (2026-08-13,
[ADR-0059](cli/decisions/0059-message-classification-and-the-start-warning-gate.md) D1…D15 +
[design](cli/design/design-warning-gate-and-onboarding-prompts.md)) — it decomposes into **three
ordered units, U1 → U2 → U3**, listed under A5. **U1 landed 2026-08-14; U2 is the next work in the
block.**

#### A1 — `cco save`: project-config versioning helper

**Problem.** In the decentralized model, project config lives in `<repo>/.cco/` and is versioned by the
repo's own git. To version *only* the config, the user must hand-stage `.cco/**` among unrelated repo
changes. `cco config save` gives exactly this ergonomics for the personal store `~/.cco`; the in-repo
model never got its twin.

**Why it is first.** It closes a coherence debt **already in production**: the baked managed rule
`cco-config-interaction.md` and ADR-0042's Level-C guidance tell edit-level agents to version config
atomically with `cco project save` — a verb that does not exist. Today the rule degrades gracefully by
calling it *forthcoming* and pointing at plain git. When this ships, that text is restored to the real
verb.

**Scope (v1).** Stage **exclusively** `<repo>/.cco/**`, never the rest of the working tree; secret
detection before commit, reusing `lib/secrets.sh` as `cco config save` does; `secrets.env` stays
gitignored and is never staged; an isolated-history read (`git log -- <repo>/.cco/` already
path-filters, regardless of how a commit was made).

**Decisions the session owes.**
- **The verb name.** The maintainer's note says `cco save`; ADR-0042 and the managed rule assume
  `cco project save`; `cco config save` is taken by the personal store. Pick once — the injected
  context and the managed rule must name the real verb.
- Path-filtered history vs a commit trailer (`Cco-Save: true` + `git log --grep`), and whether a
  companion read verb (`cco project history`) exists at all.
- `--amend` / message templating: in or out.
- **Multi-repo**: commit the invoking repo's `.cco/` only, or fan out to every config-bearing member
  the way `--sync` does?
- **Operator-shim classification**: in-container write verb at `cco_access ≥ edit-project`, or
  host-only? Confirm the secret scan and the path scoping hold under container-operator mode.

**References.** ADR number **reserved as 0038, never written**. Twins to read first: `lib/cmd-config.sh`
(`cco config save`), `lib/secrets.sh`, `bin/cco` `_cco_operator_shim`. Integration contract:
[ADR-0042](configuration/agent-cco-access/decisions/0042-agent-cco-interaction-model.md).

#### A2 — Per-project custom Docker image ([FI-49](improvements.md))

**What already exists**: `project.yml` accepts `image:` (`templates/project/base/project.yml:113`) and
`cco start` honours it (`lib/cmd-start.sh:1682`). **What is missing** is everything around it.

Three sub-problems, all raised from real use on an adopting project:

1. **Maintenance is manual and silent.** The docs say a base `cco build` obliges you to rebuild the
   derived image too. Forget, and you run yesterday's entrypoint with no signal. `lib/cmd-build.sh`
   has no project awareness at all. Options to weigh: `cco build` rebuilding the derived images it
   knows about · an explicit `cco build --project <name>` · a lazy prompt at `cco start` (*"the custom
   image is older than the base — rebuild?"*).
2. **A missing image gives no actionable error.** A project declaring an image nobody built should say
   so and name the fix, not fail deep inside compose.
3. **The `setup.sh` docs contradict themselves**: the generated script header says *runs as root*, the
   guide says *runs as user `claude` — cannot install system packages*, and the decision matrix then
   recommends that same file for *"an apt package for one project"*. One of these is wrong; find out
   which by running it, not by reading further.

**Note for the session.** Sub-problem 3 is a doc fix gated on a measurement, and it is the cheapest of
the three — do it first, because the answer changes what the guide should recommend for 1 and 2.

#### A3 — Cross-scope collision warning ([FI-32](improvements.md)) + the three open decisions

**FI-32** is Low effort and directly protects work on adopting projects.
`_detect_cross_tree_conflicts` (`lib/packs.sh:106`) compares a pack's `rules`/`agents`/`skills` against
the **committed project tree** only; the global store `~/.cco/.claude/{rules,agents,skills}` — mounted
user-level into *every* session — is never consulted. Real instance: `core-dev-framework` duplicates
three of the four shipped global rules and overlaps the shipped skills and agents, and the agent then
reads two possibly divergent copies with **no signal at all**.

⚠ **This is the detection half of [FI-51](improvements.md)** (Block C). Keep it a *warning, never a
block* (P14) and make the message name the **scopes and the resolution order** — cross-scope
duplication is legitimate when a project deliberately overrides a global rule, so a message implying
an error would be wrong.

The **three open decisions** in the section below are also A-sized: take them here, or answer them
inline.

#### A4 — `ask`: the second enforcement plane + Axis-B resource classes ([FI-18](improvements.md))

**Design accepted, IMPLEMENTED, host acceptance PASSED, reviewed twice, MERGED into `develop`**
(2026-08-05 → accepted 2026-08-06 → merged 2026-08-09).
[ADR-0057](configuration/agent-cco-access/decisions/0057-ask-enforcement-plane-and-resource-classes.md);
its four gating measurements ran on the host the same day and **all passed**
([record](configuration/agent-cco-access/analysis/probe-ask-enforcement-plane.md)). This entry does
**not** restate the model; read the ADR, then `design.md` §4bis.1.

Built on `feat/access/claude-md-axis`. Implementation: `b324c0e` (resolver, lattice, `entries`, both
emitters, seeding) · `24ec2fb` (INV-P) · `be2cc9e` (schema, CLI, user docs, `changelog.yml` #62) ·
`190f8cd` (golden). Post-acceptance: `3be2466` (FI-54) · `66a446c` (the FI-52 notice). Post-review:
`dd06757` (entries reach) · `d6a49de` (fail-closed propagation). Post-merge-gate, on
`fix/access/fi67-none-locks-repo-claude-md`: `b12709c` (A2 — the deny half of D8) · `e4bbfbb`
(A2 — the wording the deny alone would have left subtly false, plus `changelog.yml` #63).

Suite **1631/7 of 1638** in-container with the FI-25 mask on — the 7 verified **name for name** as
the known host-only set (6 `test_as_*` + `test_paths_symlink_safe_tool_root`, [FI-19](improvements.md)),
against the pre-A4 baseline of 1626/7 of 1633. **Zero regressions**, +5 tests.

✅ **ACCEPTED 2026-08-06**, after a same-day re-run of the two checks that had measured nothing —
[results](configuration/agent-cco-access/acceptance/0057-acceptance-results.md) (§7 is the re-run),
[runbook](configuration/agent-cco-access/acceptance/0057-ask-plane-runbook.md). **5 pass · 1
measured-and-amended.**

- ✅ **1, 2, 3, 4, 6.** The trigger case is closed: a dialog on a nested `CLAUDE.md`, a refusal
  honoured, no dialog on a sibling. The mount half is proven both ways — `/workspace/.claude` `:ro`
  with its `CLAUDE.md` punched through `rw`, and the `rules` tree refusing with `EROFS` on five files
  for five, no dialog. `whoami` reports both dimensions. ⚠ **Check 4's *"`none` is genuinely
  locked"* held only for the `.claude` trees it probed** — `<repo>/**/CLAUDE.md` was outside it and
  stayed writable ([FI-67](improvements.md), closed by
  [ADR-0057 A2](configuration/agent-cco-access/decisions/0057-ask-enforcement-plane-and-resource-classes.md#amendments)).
  `none` now emits a deny there; on that surface it is a **gate**, not a boundary.
- 🔄 **5 — measured, then amended.** [FI-52](improvements.md) is **decided: options 1+4**
  ([ADR-0057 A1](configuration/agent-cco-access/decisions/0057-ask-enforcement-plane-and-resource-classes.md#amendments)).
  D8's single glob out-reaches the matrix that produced it, by construction; the divergence is
  **accepted** and `cco start` now **announces it** (`note: … FI-52 …`, naming the over-reached
  trees). Check 5's expectation is inverted, not dropped: `CLAUDE.md` prompts there, no other class
  does. Option 2 (per-tree rules) stays open and waits for Block D, which may move
  `/workspace/<name>-config`.
- 📝 **[FI-53](improvements.md) stays open** — and check 6 **cannot** close it: a class resolving
  *upward* equals its tree, so the "cells that differ from their tree" block can never show it. The
  session agent concluded otherwise; the record now says why that is wrong.
- 📝 Two defects came out of the run itself, not the checks: [FI-54](improvements.md) (✅ fixed —
  `[debug]` leaked into every `cco start` and nobody read it) and the runbook's **third** wrong
  instruction (an `Access:` line that only a `--dry-run` prints).

📝 **`cco build` is NOT a prerequisite** (measured): the diff touches no image-baked file, and both
planes are produced at start time by `./bin/cco` on the host. What survives is that the `cco` on the
container `PATH` is the image-baked build — hence `/workspace/claude-orchestrator/bin/cco` in-session.

🔑 **Do not run checks 1–3 on this project as it stands.** `.cco/project.yml` commits
`access: {claude: all}` (the FI-25 mask), which makes every tree `rw`; `max()` then absorbs `ask`
and **no rule is emitted at all**, so those checks would pass while measuring nothing — the failure
mode this cycle already paid for twice. Use a project without the mask, or force the default shape
with `--claude-access repo=ro,current=ro,global=ro,others=ro`.

Two implementation decisions the ADR left open, both recorded in `design.md` §4bis.1: the overlay
**replaces** the baked `managed-settings.json` rather than merging with it (P1 measured a whole-file
substitution, so it must carry the baked hooks/env/statusLine/deny forward, and it fails closed if
it cannot); and D13's stub is seeded **only** into the B2 tree, never into a user's repos.

**What it delivers.** A middle value on Axis B's lattice (`ro < ask < rw`) — mount `rw` plus a managed
`permissions.ask` rule, so the write is possible but never silent — and a second dimension of the axis,
`entries.{claude_md,rules,agents,skills}`, reaching `Cr` and `Cp`. Default: `claude_md: ask`, the other
three `ro`. cco gains a **second enforcement plane** (mount = boundary, permissions = gate) and, with
it, a graduated configuration: hard for unattended work, gated for interactive work, chosen by the user.

**Why it is in this block.** It closes a coherence debt already in production — `<repo>/**/CLAUDE.md`
is governed by **nothing** today, so one class of file has three regimes, one by omission. And it is
the daily friction that opened FI-18 twice: a session refused while updating a `CLAUDE.md` its own work
had made stale, where the only remedy is restarting the session.

**Why before B2 and D**, on the roadmap's own criterion: A4 rewrites mount generation in
`lib/cmd-start.sh`, the same file `cco attach` and Block D rewrite. Sequential either way; the smallest
first.

**Scope of the implementation session.**
- Extend the resolver to produce the **access matrix** `(tree × class) → {ro, ask, rw}` — one producer,
  no consumer re-derives (ADR-0057 D10).
- New **permissions emitter** + the per-session managed-settings overlay (D9).
- Mount-generation changes for the class dimension, plus the `CLAUDE.md` seeding (D13).
- **INV-P** static CLASS lint in `tests/test_invariants.sh` — the thing that keeps *"one point of
  change"* true rather than intended.
- Schema (`project.yml`, `access.yml`, `--claude-access` dotted key), `cco whoami` reporting both
  dimensions, user docs, and the **`changelog.yml` entry — owed at implementation, not before**: it is
  shipped-behaviour documentation and the feature does not exist yet.

⚠ **Acceptance is not suite-green.** This lane is invisible to the hermetic suite by construction
(RC-17, fourth recurrence): it needs `cco build` plus the six container checks listed in the ADR's
Verification section. And ⚠ the behaviour change runs in **two directions** — `Cp`'s `CLAUDE.md` opens
(gated), `<repo>/**/CLAUDE.md` tightens from silent `rw` to prompted. The second is the one users
notice.

✅ **Implementation review passed 2026-08-08** —
[report](configuration/agent-cco-access/reviews/2026-08-08-a4-ask-plane-implementation-review.md).
**Two objective defects found and fixed in place**, both on the security surface, both realignments
to what ADR-0057 had already decided — neither was a design change, so neither needed a gate:

- **The `entries` dimension escaped its declared reach.** D2 states *"reach: {Cr, Cp} only"*; the cell
  rule applied `max()` to all four trees and clamped only the token `ask`, so a class value of `rw`
  lifted `global`/`others` **above** their tree axis. Measured: `--claude-access repo` — whose triple
  ADR-0049 §3 fixes at `(rw,rw,ro,ro)` — mounted the whole of `~/.cco/.claude` **rw**, and the
  `entries.claude_md=rw` exit advertised as opening *"every CLAUDE.md under /workspace"* also opened
  `~/.cco/.claude/CLAUDE.md`, which is not. ⚠ **Why the acceptance run could not see it**: `ask` on a
  two-valued tree clamps back to `ro`, so the default path looked right while every `rw` class value
  escalated — and the three sessions run were default, `none` and config-editor. **No `repo`/`all`
  session was ever measured**, which is exactly the shape the defect lived in.
- **The permissions emitter was not fail-closed, despite documenting itself as such.** It runs inside
  `$( )`, so its `die` exited only that subshell; the caller tested the rc as a boolean and could not
  tell a refusal from *"no gate needed"* — and went on emitting `CLAUDE.md` binds already projected
  `rw` with **no rule bound**. That is the silent `rw` the emitter exists to refuse.

**What A4 still owes**: nothing on the enforcement plane. ✅ **Merged into `develop` on 2026-08-09**,
together with the FI-67 fix (tip `3ca4cfa`); what is left is the **push**, which is host-side.
[FI-53](improvements.md) rides the next docs/reporting pass; the review's residue is A7.

#### A7 — the A4 review residue ([FI-62](improvements.md) … [FI-66](improvements.md))

Five items the review left for a **decision** rather than a patch. Grouped here because they share an
origin, **not** because they must ship together — each is independent, and deferring any of them costs
nothing. Placement is a default, not a ruling.

- 🔴 **[FI-62](improvements.md)** — `_claude_matrix_get`'s *"fail loudly"* `die` is **fail-open** at
  every mount call site: it exits the substitution, the expansion is empty, and empty renders as `rw`.
  Latent (the producer emits every row), but pointing the wrong way. ⚠ **This is the second
  `die`-inside-`$( )` in one review, and the first was live** (`d6a49de`) — so the real question is
  whether cco wants a **stated convention** for a `die` that must cross a command substitution, and
  whether it can be linted. That is the design work; the ~10 call sites are not.
- 🔴 **[FI-63](improvements.md)** — INV-P's *published* second clause (*"no compose volume for a
  `.claude` path outside the mount emitter"*) is neither true (`lib/packs.sh:178-210`) nor checked.
  Reconcile text and lint in whichever direction; an invariant believed but unenforced is worse than
  one never claimed.
- 🔴 **[FI-64](improvements.md)** — `--dry-run --dump` under-reports the mount set when the project
  has no `CLAUDE.md` yet. Small, but it is the *artefact differs from what runs* hazard — and A4's own
  pre-flight reasoned about six session shapes from that artefact.
- 🔴 **[FI-65](improvements.md)** — `bin/test` does not neutralise `CCO_CLAUDE_ENTRIES` / `_TRIPLE`,
  so a self-dev run can measure the session it runs inside. Nothing depends on it today, which is what
  was true of `CCO_STORE_TOTALS` before the incident INV-DESC exists for.
- 🔴 **[FI-66](improvements.md)** — ADR-0044 calls the tutorial preset *"no write risk"*; D7's class
  default now applies to it. Net effect is arguably safer, but the published guarantee is literally
  false. Reword (forward annotation) or pin `claude: none`. **Listed in the open decisions below.**

#### A5 — `cco start` must pause on its own warnings ([FI-55](improvements.md))

🟡 **In implementation — U1 done 2026-08-14, U2 is the next work in Block A.**
📌 [ADR-0059](cli/decisions/0059-message-classification-and-the-start-warning-gate.md) (D1…D15) ·
📄 [design](cli/design/design-warning-gate-and-onboarding-prompts.md) — carries the mechanism, the
full message-classification table and the 13-test plan. **Read the design, not this entry**, before
opening an editor; what follows is status and order only.

**The whole warning surface of `cco start` is currently write-only.** The warnings print, then
`docker compose run` takes the terminal and the TUI opens over them — the user never gets the chance
to read them, let alone act. This is not a hypothesis: [FI-54](improvements.md) sat in that stream,
on the **first line** after the start command, through a complete six-check acceptance run, read by
nobody.

**Behaviour**: after emitting warnings, and only if there are any, stop and ask — start, or abort.
A clean start stays silent and immediate. The prompt should carry the warning list, because the
natural next step (offering `cco config save`, committing `.cco`, …) grows out of it.

📌 **Coupled to [FI-58](#-ahead-of-the-queue--the-delegation-channel-fi-58improvementsmd), and the
coupling is one-way.** ADR-0058 D6's warning ships **before** this
([A2](integration/agent-teams/decisions/0058-teammate-coordination-tools.md#amendments)), so from the
moment D4/D5 land there is a real `⚠ warn` in the start stream that nobody can read — A5 is what
makes it arrive. That does not make A5 a blocker for FI-58, and it does not change A5's design; it
raises its priority **inside** Block A, and it adds one classification to get right (the normalizer's
warning is a `⚠ warn`, never a `note:`).

⚠ **The two things this design had to get right**, both already paid for once, are settled in
ADR-0059 D11 and D1/D2: the prompt gates on `_cco_have_tty` and honours `CCO_NONINTERACTIVE=1` (or the
suite and every output-capturing caller hang on a question whose text the capture swallowed —
`test_invariant_tty_gate_single_spelling`); and **only `⚠ warn` gates**, never `note:`/`ℹ`.
Classifying every start-time message honestly was the real work, and the audit is done: **3 sites
change level, 3 blocks merge, 1 double `⚠` badge is stripped** — everything else was already honest.

##### The three units — the ordered plan for A5 + A8

Ordered by dependency. **U1 → U2 is load-bearing**: the gate must not ship while a message that
should *not* gate still can. **U1 → U3 is a file conflict**, not a preference: both edit
`lib/local-paths.sh:445,450`, so doing U3 first means doing it twice.

| # | Unit | Item | Scope | Self-verified by | Status |
|---|---|---|---|---|---|
| **U1** | capture + taxonomy | A5 | `note()` in `lib/colors.sh`; the file-backed warn buffer (D5/D6); the reclassifications of design §3.3; the `INV-WG1`/`INV-WG2` lints | T1–T3, T7, T9, T11 — **no user-visible change yet** | ✅ **done** 2026-08-14 |
| **U2** | the gate | A5 | the prompt in `_start_launch` (D7) + the same in `cco new` (D9) | T4–T6, T8, T10 + the **live check** below | ▶ next |
| **U3** | the three surface fixes | A8 | `--writable` (+ `changelog.yml` + user docs), the clone destination (D13), the reuse tokens (D14) | T12–T13 | pending |

✅ **U1 shipped.** The whole §3.3 table is applied (3 sites changed level, 3 blocks merged, 1 double
badge stripped), `note()` is a real emitter with the five bare `note:` echoes converted, and
`tests/test_warn_capture.sh` (12 tests) + `INV-WG` cover it. U1 **arms the capture from nowhere** —
`_cco_warn_capture_begin`/`_end` have no call site yet, because their placement *is* D7/D9, which is
U2's scope. Two things U2 inherits:

- 📌 **T3's driver moved, D5 did not** — see [design §6.1](cli/design/design-warning-gate-and-onboarding-prompts.md).
  D4 removes every `warn` from `_prompt_for_path`, so the test drives `$(_parse_bool …)` instead;
  measured to fail against a shell-array buffer while the rest of the file passes.
- 📝 **One living-doc sentence goes false the day U2 lands**:
  [decentralized-config design.md](configuration/decentralized-config/design.md) calls the passive
  unresolved badge *"awareness, never a block (P14)"*. Under D1 it gates. Deliberately **not** rewritten
  ahead of the code (`documentation-lifecycle.md`: never document behavior the shipped code does not
  expose) — U2's documentation step owns it.

⭐ **T3 is the test the design exists for**: a `warn` emitted from inside `$( )` must reach the buffer.
It is what discriminates the file-backed buffer from the shell-array one that would look correct
everywhere except on the interactive surface A8 is fixing. Drive it through `_prompt_for_path`, not a
synthetic subshell.

✅ **The live check for U2 is already waiting**: a session whose agent definitions keep no return
channel must stop and show [ADR-0058 A2](integration/agent-teams/decisions/0058-teammate-coordination-tools.md#amendments)'s
warning — the message that shipped deliberately unread, one release early, for exactly this moment.

📝 **No unit touches a baked file**, so **no `cco build`** enters the acceptance lane; everything is
verified by a plain `cco start` from the host. `cco start` is host-only in a session, so an
in-container lane can exercise the capture and the lints but not the prompt end to end.

#### A6 — `.claude/worktrees` belongs in the functional-write floor ([FI-56](improvements.md))

Sessions that open a worktree hit a non-writable `.claude/worktrees`. The floor's own provenance
comment says why it was excluded — *"the docs place it at the repository root, which is inside the
repo's own rw mount"* — and the field says otherwise. The likely mechanism is **the one the workflows
floor exists for**: from WORKDIR `/workspace`, the "closest existing `.claude/`" resolution lands on
`/workspace/.claude`, which is `:ro` by default.

Third recurrence of *a named list is a lower bound*. So: capture the failing path from a live session
first (the report does not carry it), then **re-derive the whole floor** against the current
`llms/code-claude` docs — not just this entry. The remedy's shape already exists
(`_emit_workflows_overlay`). This is the quick win; the full **worktree design** (Sprint 10, *Git
worktree isolation*) stays a separate, larger unit and is now pulled by real demand.

#### A8 — the onboarding prompts and the mount-declaration surface ([FI-68](improvements.md) … [FI-70](improvements.md))

🟡 **Design ACCEPTED 2026-08-13, jointly with A5** — same ADR, same design doc, and the whole of A8
is **unit U3** in [A5's table](#the-three-units--the-ordered-plan-for-a5--a8). It runs **after** U1:
U1 and U3 both edit `lib/local-paths.sh:445,450`.

**Three field reports from 2026-08-09, all on the surface a user meets *first*** — the prompts that
resolve an unregistered path, and the command that declares a mount. None is deep, none blocks
anything, and all three cost a user their first impression of the tool.

| | Defect | Site |
|---|---|---|
| [FI-68](improvements.md) | `--readonly` is a **no-op** (the default is already read-only), and **no flag declares a writable mount** | `lib/cmd-project-add.sh:162,235` |
| [FI-69](improvements.md) | option `(c)` **never asks where to clone** — and `(p)` cannot answer for it, since it demands an existing path | `lib/local-paths.sh:126-132,150` |
| [FI-70](improvements.md) | the reuse prompt prints `[1-n]`, a **range** among literal keys; typing back `1-1` is rejected | `lib/local-paths.sh:438,445` |

⚠ **FI-68 arrived inverted, and the correction is the load-bearing part.** The report read *"the
default is rw"*; the code defaults `readonly` to **`true`** (`lib/local-paths.sh:312`), as documented
and as the secure-defaults policy requires. **The default is not in scope** — what is wrong is only
the *surface*: a flag that cannot change an outcome, and no way to express the permissive case at all.
An implementer who takes the report at face value would invert a shipped security default.

**Sequence it with [A5](#a5--cco-start-must-pause-on-its-own-warnings-fi-55improvementsmd).** FI-69 and
FI-70 live in `lib/local-paths.sh`'s interactive prompts, under the same `_cco_have_tty` /
`CCO_NONINTERACTIVE=1` constraint A5 must satisfy — and A5 is *adding* a prompt to the same start-time
flow. Done together the TTY contract is derived once; done apart it is derived twice, and the second
derivation is the one that hangs the suite.

✅ **The decision is taken (2026-08-13, maintainer): add `--writable`, and keep `--readonly`** as an
explicit affirmation that keeps writing `readonly: true`
([ADR-0059 D12](cli/decisions/0059-message-classification-and-the-start-warning-gate.md#d12--cco-project-add-mount-gains---writable---readonly-stays-and-states-the-default-maintainer-2026-08-13)).
The two are mutually exclusive; the `readonly: true` **default is untouched**. This closes an
asymmetry rather than inventing a capability — `--mount <src>:rw` has expressed exactly this since
ADR-0027 D2, so cco had two spellings of one concept and one of them could not say half of it.

📌 The maintainer's own restatement is narrower than the original report and is the one to build
from: *the CLI with no flag writes only the mount's name, without `readonly: true` — which is the
default anyway; the real problem is that `--readonly` is useless because it is already the default,
and no flag sets `rw` from the CLI.*

`--writable` is an **additive** change → `changelog.yml` entry + a line in
[`cli.md`](../users/reference/cli.md), per `.claude/rules/update-system.md`.

---

### Cross-cutting analysis — resource taxonomy & the configuration-scope model

**One analysis session, read-only, no release.** It exists because three separate blocks are each
about to decide the same thing, and deciding it three times guarantees divergence.

**What it must settle.**

- **What a shareable configuration resource is**: what it may contain, where it installs, at which
  scope, and how it is instantiated and updated. Today packs carry knowledge/skills/agents/rules and
  nothing else; templates, llms and the personal store each hold a partial answer; the recommended
  vehicle on record is a new **`config` resource kind**, pending exactly this taxonomy.
- **The configuration-scope model**: what governs a session when several scopes carry a file of the
  same name, and whether the session can *say* which one is in force.
- **What `<repo>/.cco` actually is** ([FI-57](improvements.md), added 2026-08-06). It is not project
  content and not code: it is *session configuration that happens to be versioned with the repo so it
  can be shared*. The access model therefore protects it from the agent (`:ro` at any read level),
  while git needs the working tree to write it — so **a commit or merge that touches `.cco` fails
  in-session**, often enough that "do it on the host" has silently become a rule. Both readings are
  correct, which is why this is taxonomy work and not a wider mount. Second question in the same
  neighbourhood, currently unanswered: `.cco` can **diverge across branches** — feature, or footgun
  where a checkout silently changes what the next session mounts? Either way it should be a decision.
  Sibling: [FI-20](improvements.md), the same collision seen as a single symptom.
- ⚠ **Fix the two senses of "scope" in the first paragraph** — the recursive *scope level* (task ·
  feature · module · app) and the *configuration scope* (global · project · repo-native · managed).
  In one sentence they look like the same word and are not. The input document flags this explicitly.

**Preconditions the inputs state, and that are not optional.**

- **Measure before sizing.** The collision problem was found by *measuring* a live session, not by
  reasoning — three name collisions were in context while it was being debated whether they could
  exist. Repeat that measurement on a few real configurations before designing.
- **A documentary source is not a verified outcome.** Three claims in the originating pack turned out
  false because they were deduced from documentation and never executed.

**Inputs — do not re-derive.**

- [`packs/analysis/input-pack-templates-and-scope-resolution.md`](packs/analysis/input-pack-templates-and-scope-resolution.md)
  — §1 the measurement, §4 the three directions for scope resolution, §5 the hardest template
- [`packs/analysis/input-pack-enforcement-transport.md`](packs/analysis/input-pack-enforcement-transport.md)
  — §2 what is already verified, §3 the composition question
- [`engineering/opinionated-extraction-and-update-refactor-handoff.md`](engineering/opinionated-extraction-and-update-refactor-handoff.md)
  — gaps G1–G7 of the axis-2 sharing model (ADR number reserved as **0040**, never written)
- [FI-28](improvements.md) global adoption · [FI-29](improvements.md) `commands/` ·
  [FI-32](improvements.md) detection · [FI-47](improvements.md) templates ·
  [FI-48](improvements.md) enforcement · [FI-50](improvements.md) publish sources ·
  [FI-51](improvements.md) scope resolution

**Output**: an analysis document — suggested home
`configuration/analysis/resource-taxonomy-and-scope-model.md` — persisted by the lead when the
direction is approved. Per the workflow, `/design` for B and C does not begin until that file exists.

---

### Block B — lifecycle & distribution → `0.8.0`

The maintainer's ruling (2026-08-04): **one definitive design, no interim verb.** A temporary reshuffle
of `cco update` that a later refactor revisits costs more than waiting one cycle — the three commands
have been three commands until now, and one more cycle changes little.

#### B1 — `cco update`: responsibilities, orchestration, post-install

**The direction, ratified.** `cco update` becomes the **orchestrator** of
`npm update → migrations → cco build`. Updating **opinionated content** leaves it entirely: that
content is leaving the core (workstream F, Block C), so it deserves its own update path rather than
sharing a verb with migrations.

**What `cco update` conflates today** — read the code before designing: `lib/cmd-update.sh` plus
`lib/update*.sh`, already split by responsibility into hash-io, merge, meta, discovery, sync, changelog
and remote. It runs migrations, discovers framework and remote changes, reports the changelog, applies
a 3-way merge of opinionated defaults via `--sync`, and is provenance-aware. **It has never built the
image.**

**Decisions the design owes.**
- Always unified, or are the single steps still separately invocable?
- If `cco update` becomes the orchestrator, do migrations need their own on-demand verb, or is a flag
  enough? (The same question decides whether the current name still fits.)
- What the **npm post-install hook** does: notify that steps are pending, or execute them?
- **Where the boundary is declared** toward the opinionated-resource update path — B names the
  boundary; C implements the other side of it.

**References.** ADR **0040 reserved, unwritten** · the opinionated-extraction handoff ·
`.claude/rules/update-system.md` (the changelog/migration conventions any new verb must respect) ·
the post-v1 *"`cco update` responsibility re-analysis"* note, now folded into this item.

#### B2 — `cco attach` and session persistence

**Goal.** When a session is interrupted abruptly (IDE or terminal closed without `/exit`), the
container keeps running and `cco attach <project>` resumes it, instead of losing in-progress work.

**Why the substrate is nearly there.** The container runs `tmux` with `claude` inside it, so
detach/reattach is native; sessions already carry the `cco.project` label; the running registry
([ADR-0045](environment/decisions/0045-session-running-registry.md)) already tracks live sessions with
a host-side reconcile reaper for orphans.

**The blocker.** `cco start` runs `docker compose run --rm --service-ports claude` — foreground **and
`--rm`**, so an abrupt disconnect stops *and removes* the container. Persistence means detached and
named (`up -d`), then attaching into it.

**Shape to ratify in a short ADR.** Opt-in `session.persist: true|false`, precedence mirroring the
access knobs (CLI > `project.yml` > `~/.cco` global default > built-in). Default likely `false`;
**open**: default-off vs default-on-with-`cco stop`-cleanup. `cco attach <project>` cwd-first,
resolving through the label / running registry, refusing gracefully with a `cco start` hint. Lifecycle
leans on the ADR-0045 reaper; decide the idle-timeout and max-persistent-count policy.

**Trade-off to weigh explicitly**: persistence holds RAM/CPU and risks orphans, against losing work.
That asymmetry is the whole argument for opt-in.

**Effort**: Med — touches compose generation in `cco start`, a new verb, the settings-precedence
resolver, and `cco stop`/registry cleanup. Needs `cco build` to test.

#### B3 — Install / init / configuration coherence review ([FI-30](improvements.md))

**Sequenced last in the block on purpose**: the guides are rewritten once the procedure is decided,
never before.

The README quick start presents `cco init` as a global bootstrap runnable from anywhere; it is the
**project entry verb** and acts on `$PWD` (`lib/cmd-init.sh:270-282`), with the `~/.cco` seed and the
image build as first-run side effects (`:104-112`). The living-docs sweep already fixed the README's
own contradiction; what is owed is the coherence pass across README, the user guides (installation,
project-setup, configuration-management), the tutorial, and the maintainer docs — **shipped-behavior
docs, so they track what works today, not a target model.**

#### B4 — the temp-session and self-update lane ([FI-59](improvements.md), [FI-60](improvements.md))

Two field reports from 2026-08-06, both on the install/lifecycle substrate this block owns:

- **`cco new` temp sessions** appear to have no tmux, and each one **re-installs Claude Code into the
  cache** — three consecutive sessions, three installs — where ADR-0039's whole design is a persistent
  CACHE mount that installs once and updates in place. Probable shared root: the temp path composes a
  different mount/env set than a named project's, and a nameless session gets a fresh cache key each
  time. **Read `cco new --dry-run --dump` against a named project's compose before designing** — the
  answer is likely visible there without starting anything.
- **Claude's auto-update reports `failed`** in some sessions, intermittently, not yet captured. Same
  substrate; ⚠ a *stale launcher* in that shared cache dir once made `cco start` fatal, so check that
  neighbourhood first. Needs the verbatim message before it can be told apart from a network failure.

---

### Block C — shared-resource platform (packs & config) → `0.9.0`

**This is the block that unblocks external projects.** Four stages, in dependency order. C1 is a
declared prerequisite of C2, not a preference: shipping enforcement without parametrization produces
one `settings.json` for every project, and *how much* enforcement to want is per-project by nature.

#### C1 — `*.template.md` in packs, instantiated at install ([FI-47](improvements.md))

A pack may carry `*.template.md`; cco instantiates them **at pack install**, writing the result into
the user's configuration — never inside the pack.

**Constraints the analysis must not rediscover** (all from the input document):
- The instance does **not** live in the pack: the pack mounts `:ro` and a reinstall would overwrite it.
- The instantiation scope is the scope the pack is active in — global install → global instance,
  project install → project instance.
- Override on a more specific scope, through a dedicated post-install command.
- Repo-native (`<repo>/.claude/`) is a valid home with a caveat: it loads **on demand**, when the agent
  reads a file there — so a decision taken before the first read was never governed by it, and a
  multi-repo project can end up with two peer policies and no criterion between them.
- **An instantiated template is a user file.** A pack update must never silently overwrite it; at most
  report that the upstream template changed.

**Parameters and prompts** (the second half): every template declares its parameters and how to ask
for each; install and re-instantiation run them interactively. Every parameter has a default equal to
**current behaviour**, so pressing enter through the whole thing changes nothing. Prompts must be
skippable non-interactively and re-runnable on an existing instance. Some cells are structurally
**not** parameters, and the template must be able to mark them so with the reason beside them.

**Already-existing use cases to count** (the mechanism was missing before anyone asked for it):
`maintenance-policy` was already a copy-by-hand template in the pack, and **`language` was already a
cco rule** — which is the decisive clue that the missing layer is cco's, not the pack's. There is a
standing note to move the language rule into the Level-A/C injection model and retire its template
path; **decide it here**, in the same design, rather than as a separate item.

#### C2 — `settings.json` and hooks transported by packs ([FI-48](improvements.md))

Packs ship prose; **the only real enforcement available to a method pack lives in `permissions` and
`hooks`**, which packs cannot carry. The project-scope channel already exists and is empty:
`<repo>/.cco/claude/settings.json`. The ask is not a new channel but that a pack may write to it, with
a declared composition semantics.

**The field precondition is satisfied** (measured 2026-08-04, not deduced): the hook denies under
`bypassPermissions` — which is how cco launches every session — and sees `agent_type` inside a
subagent. Both halves of the request therefore have value under cco.

**The hard question is composition.** Markdown rules concatenate; `settings.json` is a structured
object, and two packs carrying one must be **composed**, not concatenated. The existing *last pack in
the list wins, with a warning* rule would be **worse than the problem**: a pack overwriting another's
`deny` rules removes them. Proposed starting point — `deny` union always, `ask` union, `allow` union
*with a warning*, `hooks.<event>[]` concatenated by matcher group; conflicts made **visible**, never
silently resolved.

**Mechanics not to underestimate — where the hook script lives.** A `type: command` hook points at an
executable. If the pack ships the rule but not the script, the rule is broken; if it ships the script,
that script lives in the pack's **read-only mount**. Open: can `command` point at the pack's mounted
path, and is it stable across sessions? What does `$CLAUDE_PROJECT_DIR` resolve to under cco? Is the
exec bit preserved through the mount? And a hook with state or a log **needs a declared writable
destination**, because `.claude` is `:ro` — the same STATE treatment the lead's auto-memory already has.

⚠ **Two things to carry into any hook template cco ships.** An enforcement hook **evaluates its deny
before it logs, and logging is never fatal** — the test hook printed to its log first under
`set -euo pipefail`, and with the log unwritable it aborted **fail-open**, leaving no trace. And
whatever ships must be presented as **surface reduction, not a guarantee**: an arbitrary subprocess
launched from `Bash` is not covered, and the measurement bypassed the hook in two moves by writing a
script inside the permitted directory and running it from there.

📝 **A doc item that stands on its own, whatever else is decided.** cco already gives a guarantee it
states nowhere: `<repo>/.claude` and `<repo>/.cco` mount `:ro`, so **a session cannot tamper with its
own hooks, agents, skills and settings**. That is OS-level, therefore independent of permission mode —
it holds under `bypassPermissions` — and not bypassable by a subprocess, i.e. precisely the gap no hook
can close. Documenting it is also the strongest argument for pack transport: a `settings.json` mounted
by cco is *harder* to neutralize than one copied into the repo by hand.

#### C3 — Global adoption, slash commands, scope resolution

- **[FI-28](improvements.md) — global pack adoption.** A settings surface in `~/.cco` declaring a pack
  adopted across projects, with **filters** (tags/attributes) to scope it to a subset; the CLI verb is
  a thin editor of that config. Second mode: **materialize** the adoption into every matching
  `project.yml`. Today there is no default-pack mechanism at all — `packs:` is per-project only.
- **[FI-29](improvements.md) — `commands/` has no home.** No handling of `commands/` anywhere in
  `lib/`, `config/` or `defaults/`: the global `.claude` mount is entry-by-entry and would silently
  ignore it, and `pack.yml` declares only knowledge/skills/agents/rules. Only the project tree works,
  and only incidentally.
- **[FI-51](improvements.md) — scope resolution and marking.** Three non-exclusive directions, from
  strongest to weakest: **(1) resolve at mount** — cco already materializes the rule set, so on a
  *name* collision it could mount only the most specific version; real enforcement, the agent never
  sees two conflicting rules. **(2) mount everything but generate a precedence header** into the
  session preamble, the way the knowledge list already is — still prose, but framework-generated, so
  it cannot diverge from reality. **(3) `scope:` frontmatter** on every config file — a declarative
  mitigation: it makes the ambiguity *readable*, it does not remove it. Direction 3 is needed even if 1
  is taken, because legitimate coexistence still requires the reader to tell the files apart.
  ⚠ Direction 1 needs a **proof on a real configuration as a precondition, not a follow-up.**

#### C4 — Publish sources, and the opinionated extraction (workstream F)

- **[FI-50](improvements.md) — publish from an arbitrary directory.** `cmd_pack_publish` takes a pack
  **name** resolved from the personal store, so today the source must be a store pack or an archive;
  publishing a directory straight to a remote — the shape a team wants for shared config — is not
  supported. Decide the target model too: sharing **repo** vs **package**.
- **Workstream F — opinionated extraction + the update split.** Make the cco core agnostic of
  opinionated config: `managed/` stays baked, and the opinionated defaults (workflow/git/documentation
  rules, agents, skills, the global `CLAUDE.md`, parts of `settings.json`) move into a separate
  official sharing repo, installable like any shared resource. **This is the other side of the boundary
  Block B declared**, and the first consumer of the resource kind the shared analysis defines.
  ADR **0040 reserved, unwritten**. Reference:
  [`engineering/opinionated-extraction-and-update-refactor-handoff.md`](engineering/opinionated-extraction-and-update-refactor-handoff.md).
- Also here, as shipped-surface gaps in the same family: `cco template update` as the symmetric twin of
  `cco pack update`, and making `cco pack update` a **3-way merge** (it currently overwrites local
  edits).

---

### Block D — cycle-2: config multiplicity, divergence awareness, mount topology → `1.0.0`

Analysis → design, subject fixed by the maintainer 2026-07-31. ⚠ **The subject is wider than the mount
topology, and the topology is downstream of it.**

**The prior question.** A session cannot ask **how many config copies exist for a project, nor whether
they diverge.** Mechanically: `sync-meta` never crosses **INV-STATE**, so `_sync_is_divergent` always
returns false and every owned member reports `synced`. The question is not badly answered — it is
**unaskable**.

Three consequences, in this order:

1. **config-editor is the authoring tool** and must therefore *know* a project's sync/divergence state
   and let the user handle it explicitly — which implies `cco sync`, or a successor, being reachable in
   that session. Its blocking prerequisite is **the STATE crossing, not the mounts.**
2. **A standard session is right to see only the config of the project it was launched from.** The two
   modes have different needs, and today a single mechanism serves both by accident.
3. **Then, and only then, the topology**: validate or discard the two-path model
   (`/workspace/<name>-config` vs `/workspace/<repo>/.cco`).

**Start from the analysis, which is already written and approved**:
[`configuration/agent-cco-access/analysis/config-mount-topology.md`](configuration/agent-cco-access/analysis/config-mount-topology.md)
§3.3 and §8 — four blockers and six open questions, all code-grounded. It is not a dead end even if the
topology is discarded: it either validates the current design or names what is wrong with it.

**Results already derived — do not re-litigate.**
- The proposal is structurally *"delete layout 2"*, and under it FI-42's fan-out writer becomes correct
  **verbatim** — a fix by removing a special case.
- 🔑 But *"the writer becomes correct verbatim"* and **soundness under `--all`** are **mutually
  exclusive**: `--all` exists to reach projects whose repos are not mounted, and a repo name is a
  per-project label (ADR-0051 D2), so `--all` structurally needs a project-keyed component.
  **The topology's residual value is UX — host/session path parity — not FI-42's correctness.**
- The four blockers: **(a)** INV-MP — a passed-through `/workspace/<repo>` ancestor materializes
  root-owned and would fail `test_invariant_mount_ancestry_owned`, so an ADR-0054-style framework-owned
  scaffold is mandatory · **(b)** ADR-0051 homonyms are sound in project mode, **unsound under `--all`**
  where N×M collisions are the expected case · **(c)** no ADR states which of N replicated copies is
  canonical in-session — glob order decides today · **(d)** a `.cco`-only stub trips three dir-test
  predicates into *absent-reported-as-present*, landing on `cco project show`, the very verb the
  proposal designates as the mapping surface.
- Supersessions to make explicit if the topology is taken: **RC-6 §3.7** and **ADR-0046 §6** (already
  ratified in place — a normal `edit-project` session ships `include_member_configs`' span unenforced
  at `cmd-start.sh:1885-1887`, so config-editor is the stricter of the two).

**Carried into this block:**

| Item | Note |
|---|---|
| [FI-42](improvements.md) | The fan-out resolves its WRITE path by member probe while its READ path is operator-aware. **Cannot be fixed without taking the contract decision it carries** — all-or-nothing vs all-or-declared-partial. Reachability is bounded and documented: the only path reaching the fan-out is `config-editor --cco-access edit-all --repo …`, and it exits **declared** (rc 1 + the failed paths), not silently. Shipped as the `0.6.0` known-issue |
| [FI-43](improvements.md) | `--repo` mounts the code **rw** while its stated purpose is to read it. A **sub-question of the topology decision**, not a standalone flag |
| [FI-40](improvements.md) | A fail-closed refusal states a count where naming is safe (`pack rename` unmounted census). **Topology-independent** — it could have shipped on either side of the gate; deferred only to keep the release tree unchanged |
| **Linux write path** | ⚠ **An ADR, not a patch.** The conflict is structural: the agent's uid must equal the host user's or it cannot write the repos; the store content is owned by that same uid; the elevated identity must **not** be that uid. Candidates — a dedicated host group + setgid dirs with the gid joined in the entrypoint · POSIX ACLs granting uid 900 · dropping the boundary on Linux (a security regression). All imply host-side setup. ⚠ Criterion F is signed off as **macOS-verified only**: macOS `fakeowner` makes the fail-closed pre-validation unfalsifiable, so every `chmod`-driven unwritable-bucket test passes in the Linux container and proves nothing from a macOS run |

---

## Not in the sequence — schedule when convenient

Each is independent and rides the shipped substrate. None blocks anything in A–D.

| Item | Why it is not in a block |
|---|---|
| [FI-71](improvements.md) — the config-editor design doc describes an access model replaced twice | 📄 **A `documenter` task, and the only one here on a security surface.** ADR-0048 replaced `edit-all` with min-privilege-by-mode, ADR-0049 §8 removed the bespoke Axis-B floor, ADR-0057 added the `CLAUDE.md` prompt — the doc predates all three and overstates the built-in's privilege *in the permissive direction*. Nothing depends on it, which is why it is here rather than in a block; but it is the copy a maintainer reaches through the config-editor's own design tree, so it outranks the rest of this table. ⚠ Re-derive the whole model, not the three flagged lines |
| [FI-37](improvements.md) — no working workflow-save path in the repo lane (`<repo>/.claude`, axis `Cr`) | Usability, no data loss. ADR-0055 gave the *project* tree a functional-write floor; the repo tree deliberately did not get one, because a repo's native `.claude/` is cross-cutting config shared with everyone who clones it. The fix is a mechanism choice, not a patch |
| [FI-38](improvements.md) — workflows STATE overlay hygiene | Two policy choices, not bugs: a stub outlives the entry that justified it, and a collision with a later-committed workflow is resolved silently. ⚠ The emitting function runs inside `$( )` and its stdout **is** compose YAML — any notice must go to stderr or be emitted by the caller |
| [FI-39](improvements.md) — Claude Code memory state cco does not persist | **One ADR covering both halves; do not split it.** (a) per-agent `memory:` is declared on eight agents and evaporates — measured: of four declared scopes only the lead's works, and six pack agents produced **zero bytes** in weeks. (b) `autoMemoryDirectory` — a simplification. ⚠ **Weigh it together with cross-PC state sync, never before**: role memory becomes an object to sync, with its own ownership/conflict/confidentiality questions, and deciding it first means deciding it without its most binding requirement. ⚠ And the fix **cannot be "make `.claude` writable"** — that would buy a low-priority feature by selling the security guarantee named in C2 |
| **Report the upstream documentation defect** (agent teams) | `llms-full.txt:543` states that *"Team coordination tools such as `SendMessage` and the task management tools are always available to a teammate even when `tools` restricts other tools"*. **Measured false** on 2.1.220, 2.1.226 and again on 2026-08-13 — it is the sentence that made FI-58 invisible for weeks, and ADR-0058 exists because it is wrong. Evidence: [analysis-002 §12](integration/agent-teams/analysis/analysis-002-delegation-return-channel.md). ⚠ **Needs a control run on a stock installation first** — every measurement so far was taken inside cco, so the report must rule cco's own managed layer out before it is filed. Recorded here 2026-08-13 because it had only ever lived in an ephemeral handoff |
| **State sync (cross-PC / cross-team)** | The largest deferred item; needs its own design. Boundary to preserve: git stays the one engine for vault sync and resource sharing; a daemon would own only what git carries badly (append-heavy, machine-local STATE) |
| #10b — statusline | Show session usage/limit percentage instead of (or beside) the dollar cost; fix stale ctx% after `/compact`; configurable format. Low effort, fits any release |
| FI-4 — per-project `model:` · `cco project edit` | Quick wins: `model:` in `project.yml` → `claude --model`; open `project.yml` in `$EDITOR` and regenerate compose |
| **Developer-mode residue** | ✅ **Mostly shipped**: `cco --dev-sandbox` / `--dev-sandbox-seed` isolate STATE/DATA/CACHE and seed them one-shot from the real buckets (`docs/users/reference/cli.md` §3.34). What remains is ergonomics — running the local `bin/` build against an npm-installed cco without typing the path |
| [FI-61](improvements.md) — bypass-permissions mode vanished mid-session, once | 📝 **Watch, not work.** One occurrence, no reproduction, cause unknown. Recorded so a second one is a pattern rather than a rediscovery. If it recurs: A4 now writes a **per-session** `managed-settings.json` overlay (ADR-0057 D9) where there used to be a baked constant — that is the surface deciding permission mode, so rule it in or out first |
| Name/id validation hardening · `cco config protect` · `cco project internalize` (Case-C) · `cco clean` redesign · the deferred doc splits | Post-v1 backlog, unchanged. Detail in [roadmap-history.md](roadmap-history.md) |

## Open decisions for the maintainer

None blocking. Each is cheap to answer and expensive to discover later.

1. **180 latent bash-3.2 fixtures in `tests/`.** Argument-position `"$(cat <<YAML` sites that parse
   today and abort the **whole host suite** the day one gains an apostrophe. Options: leave the
   two-arm INV-B32 as shipped · refactor them and tighten to one arm · make the **bash-3.2 parse sweep
   a gate**. ⚠ The sweep answers *"should the host suite be a gate?"* more cheaply but **not the same
   way**: it proves the suite is *readable* on 3.2, never that it *passes*.
2. **`cco init` has no `$HOME` guard.** It scaffolds `$PWD/.cco`, and in a home directory that is the
   personal store's own path. On a fresh machine the outcome is a confusing `refusing to clobber`, not
   corruption — but it is exactly the mistake the old README invited. A guard is a code change.
3. **`cco pack internalize` is documented twice** (`cli.md` §3.23 unified, §3.27 dedicated). The
   divergence is fixed; the duplication is not. Merging sections in a shipped reference is editorial.
4. **The tutorial preset's "no write risk" claim** ([FI-66](improvements.md), added 2026-08-08).
   ADR-0044 §2 says it; ADR-0057 D7's class default now makes it literally false, in a direction that
   is arguably *safer* (its own `CLAUDE.md` opens behind a prompt; every `<repo>/**/CLAUDE.md`
   tightens). Reword the claim, or pin the preset at `claude: none` if it was meant literally.
5. **Does the worktree design (Sprint 10) move up?** Added 2026-08-06. Its priority is 5, set before
   sessions started hitting the wall on their own ([FI-56](improvements.md)) and before this project
   adopted *worktree per agent* as its rule for parallel work. A6 removes the immediate symptom, which
   is exactly why the question should be answered deliberately rather than by the next incident.
6. **Ratify or retire the `acceptance/` docs leaf.** Added 2026-08-13 (until then it had only ever
   lived in an ephemeral handoff). The pack's canonical set is `analysis/ design/ decisions/
   reviews/`; the access domain invented a sixth, `acceptance/`, and it exists in **exactly one**
   domain (`configuration/agent-cco-access/`). The FI-58 probe record was deliberately filed under
   `integration/agent-teams/reviews/` rather than spread the contested leaf into a second domain —
   which would have settled this question by accident. Ratify it into the taxonomy, or fold it into
   `reviews/`. ⚠ Moving the existing files breaks inbound links from ADRs and `improvements.md`, so a
   decision to fold must schedule the link sweep with it.
7. **Should `cco clean` sweep the warn-capture buffers?** Added 2026-08-14 (U1). The buffer is an
   `mktemp` file under `${TMPDIR:-/tmp}` (ADR-0059 D6); cleanup is explicit, so only a hard kill leaves
   one behind, and what it leaves is inert — an unread list of strings the OS reclaims on its usual
   schedule. The design claimed `cco clean --tmp` sweeps them; it does not (that flag removes
   `<project>/.cco/.tmp/` dry-run dirs), and the claim is now corrected in
   [design §4.2](cli/design/design-warning-gate-and-onboarding-prompts.md). Adding a `$TMPDIR/cco-warn.*`
   sweep is a **user-visible change to `cco clean`**, so it was not folded into U1 silently.

## Long-term planned work

Full descriptions in [roadmap-history.md → Planned Sprints](roadmap-history.md#planned-sprints).

| Item | Priority | Effort | Summary |
|---|---|---|---|
| **Design-doc consolidation review** | 2 | Med | Sweep the maintainer docs for long-living concepts reused by several features but scattered across per-sprint ADRs, and decide which deserve a consolidated living design doc. Known case: the CLI surface/UX conventions, spread across four ADRs with no unified `cli/design/` reference |
| AI-assisted merge (Update System Phase 4) | 2 | Low–Med | `(I)` AI-merge option for `.md` files on `cco update --sync`. ⚠ Overlaps Block B — re-check it there |
| Sprint 6C — Network hardening | 2/3 | Med–High | Squid sidecar + `internal: true` network, SNI domain filtering (Phases A/B shipped, C pending). Required pre-open-source |
| Sprint 8 — E2E integration tests | 3 | Med | `bin/test-e2e` verifying real container behaviour (mounts, socket, auth, entrypoint). ⚠ Every acceptance round of cycle 1 was blocked on exactly this gap |
| Sprint 9 — Linux OAuth | 4 | Med | OAuth on Linux without Keychain. ⚠ Same platform as Block D's Linux write path — consider pairing them |
| Sprint 10 — Git worktree isolation | 5 ⚠ **demand rising** | Med | Opt-in per-session worktrees on `cco/<project>` branches. ⚠ Sessions are **already trying** to open worktrees and failing ([FI-56](improvements.md), now A6) — and this project's own git rule makes a worktree per agent the default for parallel work. Priority 5 predates that; **re-prioritizing it is an open decision** (below). A6 unblocks the symptom, not the feature |
| #9 — Pack inheritance / composition | 5 | Med | `extends:` in `pack.yml`. ⚠ Re-evaluate **after** Block C: the taxonomy may subsume it |
| Sprint 12 — Project RAG | Exploratory | High | Built-in opt-in RAG MCP, auto-generated config at `cco start` |

## Exploratory (long-term)

Uncommitted ideas — evaluate demand before scheduling. Detail in
[roadmap-history.md → Long-term / Exploratory](roadmap-history.md#long-term--exploratory).

- Native installer migration · hot-reload for in-container configuration (`cco reload`)
- Remote sessions (SSHFS-mounted repos) · multi-project sessions
- System notifications for human-in-the-loop · web UI dashboard

## Declined / Won't do

Decisions preserved in [roadmap-history.md](roadmap-history.md#declined--wont-do).

- **PreToolUse safety hook as a cco default** — Docker is the sandbox (ADR-1). ⚠ Note the distinction
  Block C draws: what is declined is cco *imposing* one, not a pack being *able* to ship one.
- **claude-mem integration** — heavy deps, per-tool-call overhead, AGPL.
- **claude-context (Zilliz) as the default RAG** — cloud dependency + key + privacy; optional provider
  only.

## Standing operational notes

Cheap to read, expensive to rediscover. The full release procedure is the gates runbook
[`08-gates-to-release.md`](configuration/agent-cco-access/e2e-review/fix-design-v3.1/08-gates-to-release.md),
kept as the template for the next release.

- **`git push` without `--follow-tags` leaves the tag behind**, and then `release.yml` never fires
  while `pages.yml` does. **The release workflow not firing is the signal that the tag never left.**
- **A `develop → main` merge is host-only when its `.cco/` diff is non-empty** — a merge writes the
  working tree, and `.cco` is `:ro` at the default access level. The fix is the designed knob, not a
  workaround: `--cco-access edit-project`.
- ⚠ **`git stash -u` half-applies in-container** (observed 2026-08-05, same family as the note above).
  Framework-generated **empty** mountpoint dirs under the `:ro` `.cco` (`claude/llms/*`,
  `claude/workflows/`) are untracked, so `-u` tries to remove them and fails with
  `Read-only file system`. The stash **is created with everything in it**, but the cleanup aborts and
  the tracked modifications **stay in the working tree** — so a later `pop` collides with itself. `git
  status` never shows the offenders (git does not track empty directories; `git clean`, which `-u`
  calls, does try to remove them). Recovery: confirm the stash holds the work
  (`git stash show --name-only` **and** `git show --name-only stash@{0}^3` for the untracked half),
  then `git checkout --` the tracked files and `pop` onto a clean tree. Prefer committing on a scratch
  branch over stashing.
- **The host and the container share one working tree.** Never switch branches while something is
  running on the host — it produces failures that are artefacts, not data.
- **Prove a check's input is non-empty before believing its PASS.** A green check that measured nothing
  recurred twice in the last cycle: a host log reading `0 failed` **with no `Results:` line** was an
  abort, and a coverage check reported "no gaps" because its extraction returned nothing.
- **A named list is a lower bound.** Three separate sweeps missed a site their file list did not name.
  Ask what actually executes in the hostile environment.
- **The container is NOT blind to bash 3.2.** The Docker socket reaches the public `bash:3.2` image:
  `docker run --rm --name cc-<project>-b32 -v <host-repo>:/src bash:3.2 bash -n <file>` is a real parse
  oracle in-session. ⚠ Two constraints: the proxy demands the `cc-<project>-` name prefix and
  **swallows container stdout** — read results from exit codes or a file written into the mounted repo.
  What stays true is narrower: the *suite's* interpreter is bash 5.2, so a behavioural regression test
  proves nothing about 3.2.

## History

Full chronology — closed cycles, the phase-by-phase build log, completed sprints and the resolved-bug
log: [roadmap-history.md](roadmap-history.md).
