# ADR 0059 — Message classification and the start-time warning gate

**Status**: **Accepted (design)** — 2026-08-13. Direction and the three questions this ADR opened
(D9, D10, D12) ruled by the maintainer the same day. Implementation not started.
Closes **[FI-55](../../improvements.md)**, **[FI-68](../../improvements.md)**,
**[FI-69](../../improvements.md)**, **[FI-70](../../improvements.md)** — roadmap items
**A5** and **A8**.

**Design**: [The start-time warning gate and the onboarding prompts](../design/design-warning-gate-and-onboarding-prompts.md).
The mechanism, the full message-classification table and the test plan live there; this ADR records
only what was decided and why.

**Related ADRs**: 0058 A2 (the D6 normalizer warning ships *ahead* of this gate, emitted-but-unread
for one release — it is the first message the gate must be tested against); 0047 (the privilege
boundary — INV-S1 is why the capture buffer may not live in STATE); 0027 D2 (`--mount
<src>:rw` — the ad-hoc mount spec whose asymmetry with `project add mount` D12 closes);
0051 D4 (the reuse-or-homonym prompt D14 re-renders); 0049 §7 (an extra_mount is reference
material — the reasoning that relies on the `readonly: true` default D12 must not touch).

---

## Context

`cco start` emits warnings and then hands the terminal to `docker compose run`. The Claude Code TUI
opens over them and the scrollback is gone: **the entire warning surface of the command is
write-only**. This is measured, not supposed — [FI-54](../../improvements.md) sat in that stream, on
the **first line** after the start command, through a complete six-check acceptance run, and was read
by nobody.

The surface is not idle. [ADR-0058 A2](../../integration/agent-teams/decisions/0058-teammate-coordination-tools.md#amendments)
deliberately shipped a real `⚠ warn` into it — *"N agent definition(s) keep NO return channel — a
teammate using one will finish its work and lose it"* — knowing it could not be read until this gate
landed. A warning that says a teammate's work will be silently discarded is exactly the class of
message the stream exists for, and exactly the class that the stream currently loses.

Three field reports from 2026-08-09 sit on the same first-contact surface: the flags that declare a
mount ([FI-68](../../improvements.md)) and the two interactive prompts that resolve an unregistered
path ([FI-69](../../improvements.md), [FI-70](../../improvements.md)). They are grouped here because
they share one constraint with the gate — the `_cco_have_tty` / `CCO_NONINTERACTIVE=1` contract — and
deriving that contract twice is how a suite acquires a silent hang.

⚠ **FI-68 arrived with its premise inverted, and the correction is load-bearing.** The report read
*"the default is rw"*; `lib/local-paths.sh:312` resolves an absent `readonly:` key to **`true`**, which
is the documented contract and the secure default ADR-0049 §7 reasons from. What is actually wrong is
only the *surface*: `--readonly` cannot change an outcome, and the permissive case has no CLI spelling
at all. An implementer taking the report at face value would invert a shipped security default.

## Principles

- **P1 — a message nobody can read is not a message.** Emitting it discharges no duty; it only moves
  the failure from "cco did not say" to "cco said it into a stream it had already decided to
  destroy".
- **P2 — a guarantee that depends on a maintained list is not a guarantee.** In this repo a named
  list has been a lower bound **five** times (ADR-0058 D5 is the most recent). A gate driven by a
  curated set of "important" messages is that shape again, and it fails silently: the message that
  should have stopped the launch simply does not.
- **P3 — the CLI must be able to express every state the runtime accepts.** A runtime that binds a
  mount `rw` and a CLI that cannot say `rw` is not a secure default; it is an incomplete surface that
  pushes the user into hand-editing the file the CLI exists to write.
- **P4 — a secure default is not revised by a field report.** It is revised, if ever, by a decision
  that names it. The default stays; the surface changes.

## Decisions

### D1 — every `⚠ warn` gates the launch

After all start-time work and immediately before the container runs, if one or more `warn()` messages
were emitted, `cco` stops and asks: start, or abort. A clean start stays silent and immediate.

There is **no curated list of gating messages** and no second warning function. The rule is a
property of the level, so a `warn` written six months from now gates on the day it is written, with
nobody remembering this ADR (**P2**).

### D2 — four message levels, exactly one of which gates

| Level | Spelling | Meaning | Gates |
|---|---|---|---|
| **warning** | `warn "…"` → `⚠` | a condition of *this session* the user may want to act on before working inside it | **yes** |
| **note** | `note "…"` → `note:` | an accepted divergence or an explanation; nothing is wrong | no |
| **chronicle** | `info "…"` → `ℹ`, `ok "…"` → `✓` | what the command did | no |
| **prompt-local** | plain `echo … >&2` inside an interactive prompt | validation feedback inside a conversation the user is already having | no |

The corollary is the whole point and must be quoted when this ADR is applied: **if a message must not
stop the launch, it must not be a `warn`.** D1 does not make messages louder; it makes miscataloguing
one visible.

### D3 — `note:` becomes a real function

`note()` joins `info`/`ok`/`warn`/`error` in `lib/colors.sh`, and the four existing bare `note:`
echoes convert to it. Without this, D2's non-gating level exists only in prose, and the first author
who needs a non-gating message reaches for `warn` because it is the only function that looks like
one.

This also resolves the one message that currently spells both at once — `warn "note: '$abs' does not
exist on this machine yet"` (`lib/cmd-resolve.sh:841`), which under D1 would gate on a text that
announces it is not worth gating.

### D4 — prompt-local validation feedback is not a session warning

Six sites in `lib/local-paths.sh` (`109`, `120`, `151`, `164`, `445`, `450`) report *"Invalid choice
'x'"* or *"Path '…' does not exist"* — feedback the user reads and answers within the same prompt,
typically before correcting the input and moving on. Under D1 a corrected typo would hold the launch
hostage at the end of the run. They become part of the prompt's own output stream, which is already
plain `echo … >&2` for every other line it prints.

This is a **reclassification, not a demotion of importance**: what makes them non-gating is that they
have already been read, by construction, by a user who was looking at them.

### D5 — the capture buffer is file-backed, not a shell array

Measured, not argued: `_prompt_for_path` and `_resolve_disambiguate` are invoked inside command
substitution (`lib/local-paths.sh:474`, `:497`), so every `warn` they emit runs in a **subshell**. A
global array would lose exactly those — the warnings raised on the interactive surface this same unit
is fixing — while appearing to work everywhere else. Same class as the `die`-inside-`$( )` defect
(FI-62), which is already recorded as costing one live and one latent bug.

### D6 — the buffer lives outside the confined buckets

`${TMPDIR:-/tmp}` via an `mktemp` **template** (`mktemp "…/cco-warn.XXXXXX"` — the portable spelling
BSD and GNU agree on, and the one `lib/sync-meta.sh` already uses). Never STATE, DATA or CACHE: those
are confined by the ADR-0047 privilege boundary, where **INV-S1** forbids any code outside
`lib/store.sh` from mutating *or predicating* a path. A warning buffer is not worth a `store-op`
crossing.

### D7 — the gate sits immediately before `docker compose run`

Inside `_start_launch`, after secrets are loaded and before the running-registry marker is written.
Rationale is coverage, not taste: `load_global_secrets` / `load_secrets_file` warn about malformed
lines (`lib/secrets.sh:102`) **after** every other step of the command, so a gate placed at the end of
`cmd_start` would miss them. Placing it before the marker means an abort leaves no registry entry to
reap.

### D8 — `--dry-run` does not gate

Nothing takes the terminal; the summary is printed and stays on screen. The warnings are already
readable, which is the entire objective. A prompt there would make the inspection path more
interactive than the real one.

### D9 — the gate covers `cco new` as well *(maintainer, 2026-08-13)*

`cco new` has its own launch path (`lib/cmd-new.sh:205`) and takes the terminal identically. Once the
capture exists the addition is a few lines, and excluding it would leave the same write-only stream in
the twin verb — the one that mounts ad-hoc repos and is therefore *more* exposed to path-resolution
warnings.

⚠ `cco new` installs its own `EXIT` trap (`lib/cmd-new.sh:75`), which **replaces** the sentinel trap
armed in `bin/cco:14`. The buffer's cleanup must therefore not be built on an `EXIT` trap alone.

### D10 — the prompt defaults to start: `[S/a]`, bare Enter starts *(maintainer, 2026-08-13)*

The warning is advisory; the user who has read it and accepts it continues with one key. Aborting a
session the user explicitly asked for, on a stray Enter, is the worse of the two errors.

### D11 — the prompt gates on `_cco_have_tty` and honours `CCO_NONINTERACTIVE=1`

No controlling terminal → no prompt, and the launch proceeds exactly as today. This is not a
nicety: a prompt whose text is swallowed by a capturing caller still blocks on `/dev/tty`, which is a
silent unattributable hang — the failure `test_invariant_tty_gate_single_spelling` exists to prevent
and that `bin/test` disarms globally by exporting `CCO_NONINTERACTIVE=1`.

### D12 — `cco project add mount` gains `--writable`; `--readonly` stays and states the default *(maintainer, 2026-08-13)*

- `--writable` writes `readonly: false`. It is the **only** CLI spelling of a writable extra mount;
  today the case is reachable only by hand-editing `project.yml` (**P3**).
- `--readonly` is kept and keeps writing an explicit `readonly: true`. It stops reading as an opt-in
  to a restriction that is already unconditional, and becomes an affirmation the file records; the
  flag *pair* is what teaches the default.
- The two are mutually exclusive; together they are an error, not a precedence puzzle.
- **The `readonly: true` default is untouched** (**P4**), and the help text says so in words.

This closes an asymmetry rather than inventing a capability: `--mount <src>:rw` has expressed exactly
this since ADR-0027 D2 (`_parse_user_mount_spec`, read-only by default with an explicit `:rw`
opt-in). Two spellings of one concept, one of which could not say half of it.

### D13 — the clone prompt offers its destination and accepts an override

Option `(c)` currently clones to `${suggested:-$HOME/Projects/$name}` with no chance to intervene
(`lib/local-paths.sh:126-132`), and `suggested` is computed **only** for `repos` — so an `extra_mount`
is hard-wired to `~/Projects/<name>`, a location with no relation to where the user keeps mounts.
Option `(p)` is not an escape: it requires the path to exist already (`:150-153`), so no path through
the prompt clones anywhere the user chose.

`(c)` shows the computed destination and accepts an override in the same keystroke shape as the rest
of the prompt (Enter accepts). The override is absolutized through `_resolve_to_abs`, as `(p)`
already does — a relative answer stored in the index resolves wrong from any other cwd.

### D14 — the reuse prompt enumerates the tokens it accepts

`[1-${#cands[@]}]` (`lib/local-paths.sh:438`) is **range notation rendered among literal keys**
(`[d]`, `[q]`), and with one candidate it renders `[1-1]` — which the parser then rejects, because a
`-` fails the `*[!0-9]*` test (`:445`). The user who types back the token they were shown is told
their choice is invalid.

The line renders the literal tokens instead. No range notation, no upper-bound special case: the
candidate list is names bound in *other* projects, and enumerating three of them is not a problem
worth a fallback (YAGNI).

### D15 — two exact lints, and a declared limit

- **INV-WG1**: no `warn` message body begins with `⚠`. The badge is `warn`'s job; the double badge
  exists today at `lib/cmd-start.sh:3134` and `lib/update-merge.sh:151` and renders `⚠ ⚠`.
- **INV-WG2**: the producer is not cloned — the `warn()` body's emit shape appears only in
  `lib/colors.sh`.

**The limit is declared, in the style ADR-0058 D5 established**: a static lint cannot tell a
*decorative* `⚠` inside a table row or a menu line (legitimate — `lib/cmd-resolve.sh:480`,
`lib/cmd-project-query.sh:293`, `lib/local-paths.sh:412`) from a warning written as a raw `echo`
(which would bypass the buffer). The two shapes above are enforced; the residue is a review concern,
and this sentence is the record that it was seen rather than missed.

## Alternatives considered

**A curated gating list (`gate_warn()`).** Rejected under **P2**. It changes no existing message —
its only real advantage — at the cost of making every future warning non-gating by default. The
defect then returns silently, in the exact shape this repo has already paid for five times.

**Capture by teeing stderr.** Rejected: it changes the semantics of every caller that captures
output, and cannot distinguish levels without re-parsing the badges it just wrote.

**Leave `cco new` out** (FI-55's literal scope). Rejected by the maintainer under D9.

**Enter = abort.** Considered and rejected under D10: it teaches reading by confiscating a session the
user asked for, and penalises the legitimate case of a user who already knows the warning.

**Documentation-only for FI-68** — correct the help text and leave writable mounts to `project.yml`.
Rejected by the maintainer under D12: it leaves a runtime state the CLI cannot express (**P3**) and
leaves `--readonly` a flag that cannot change an outcome.

## Consequences

- Every start-time message must be classified honestly, once. The table is in the design document;
  the reclassifications are D3 (one site), D4 (six sites), and three cosmetic merges where one
  condition is currently emitted as two or three separate `warn`s.
- A user who has never seen a warning notices nothing: the gate is silent on a clean start.
- Unattended and captured runs are unaffected by construction (**D11**), and the suite disarms the
  prompt globally.
- ADR-0058 A2's warning becomes readable — the first thing the gate should be tested against, and the
  reason A2 was allowed to ship unread.
- `--writable` is an **additive** change: it needs a `changelog.yml` entry and a line in the user CLI
  reference, per `.claude/rules/update-system.md`.

---

## Amendments

### A1 — the gate's output model, after the first real project (2026-08-18)

**Status**: Accepted. Ruled by the maintainer on the evidence of the first host acceptance run
(`cco start cave-auth`, **14 warnings**). D1…D15 are unchanged; A1 amends what the gate *emits*.

The gate worked. Its output did not survive contact with a real project: 14 flat lines, each printed
**twice** — once inline at emission and once in the list — and 9 of those 14 were three *conditions*
emitted one line per item by a loop (5 rule collisions from one pack overlay, 3 missing llms, 2 repos
with an uncommitted `.cco`). The mechanism the ADR is about was correct; the surface it produced was
not readable, which for a message the user is meant to *act on* is the same failure by a shorter route
(**P1**).

⚠ **The §3.3 audit was a lower bound — the sixth time in this repo.** `lib/reminders.sh` and
`lib/llms.sh` are reachable from a host `cco start` and appear nowhere in its table. They were
captured anyway: **D1 keys on the level, never on a list**, so the mechanism held exactly where the
enumeration failed. This is **P2 paying itself back** rather than being asserted. What the omission
did cost is *classification* — four messages never went through §3.2's decision tree — and a full
reclassification of every producer is scheduled before this cycle merges (see D19).

#### D16 — one condition, one warn, inside loops too

D2's rule was applied to the three multi-`warn` blocks §3.3 happened to name; the **loop** producers
were never looked at. A producer that iterates emits **one** aggregated warning naming its items, not
one warning per item. Five rule collisions from one pack overlay are one thing the user must decide
about, and the gate lists entries — so N items read as N problems.

Sites: `lib/packs.sh` (rules/agents/skills collisions), `lib/llms.sh` (missing entries),
`lib/reminders.sh` (repos with an uncommitted `.cco`). The aggregation happens **at emission**, so it
shortens the inline stream and the gate's list from one change.

#### D17 — the gate groups by an area DERIVED from the producer

The list is grouped, with a count per group, and the groups are emitted in a fixed declared order so
two runs of the same project read the same way.

The area is **derived**, not declared: `warn` records `${BASH_SOURCE[1]}` — the file that called it,
which is correct inside a command substitution too (measured) — and the renderer maps file → label.
No tag at any of the ~130 call sites, and nothing to remember when writing warning number 131.

The file→label table is a maintained list, and that is admissible **here** precisely where a gating
list was not (**P2**): a file missing from it falls through to `other` and the warning is still shown,
still counted, still gates. The list can only cost a label. A *gating* list costs the guarantee.

#### D18 — a warning is printed exactly once

While the capture is armed, `warn` **defers**: it appends and does not print. The buffer is flushed —
rendered to stderr and then emptied — by whichever of these comes first:

| Path | Flushed by |
|---|---|
| interactive launch | the gate, immediately before its question |
| no TTY · `--dry-run` · abort | `_cco_warn_capture_end`, same view, no question |
| `die` / `refuse` / `_cco_exit` | the exit primitive, **before** the `✗`, so an error path never swallows the warnings |
| the buffer cannot be written | nobody — `warn` prints immediately, exactly as before |

That last row is the invariant that makes the rest safe: **deferral is conditional on the append
having succeeded.** A capture that fails degrades to today's behaviour instead of losing the message —
the same fail-soft rule D5 already stated, now load-bearing rather than merely polite.

Flushing empties the buffer, so a second flush prints nothing and a warning emitted *after* one is
still captured and still shown.

**Rejected: repaint the terminal** — erase the already-printed lines and replace them with the gate's
view. It requires knowing how many *physical rows* the earlier output occupied, which depends on the
terminal width, on wrapping, and on any interleaved output including a subprocess's; a miscount erases
the wrong lines. It destroys scrollback, and it does nothing at all under a pipe, a redirect, or CI —
where `cco start` still has to be readable.

**The cost, stated**: warnings no longer appear next to the step that produced them. The group label
replaces that context, and is more useful than pipeline order to a reader deciding what to do.

#### A2 — `agents.sh`'s *widened* message becomes a `note` (amends [ADR-0058 A2](../../integration/agent-teams/decisions/0058-teammate-coordination-tools.md#amendments))

Two messages ship from that normalizer and §3.3 classified them as one:

- *"widened the declared toolset of N definition(s)"* — cco **resolved** it, the user's files are
  unchanged, and there is nothing to do. That is the definition of an accepted divergence (**D2**), so
  it is a `note`. It was the least actionable of the 14 in the live run and it gated.
- *"N definition(s) keep NO return channel"* — cco could **not** resolve it and a teammate will lose
  its work. Unchanged: a `warn`, and the flagship case the gate exists for.

The distinction is not "how loud", it is **whether anything is left for the user to decide**.

#### D19 — the full reclassification is scheduled, not assumed

A1 fixes the two classifications the live run exposed. It does **not** claim the rest are right: the
audit is now known to have covered 12 of the ~36 files that call `warn`. Before this cycle merges, one
session runs §3.2's decision tree over **every** producer reachable from `cco start` / `cco new`,
enumerated by running the command rather than by reading a list. Recorded here so the gap is a
scheduled item and not a discovery someone repeats.

### A2 — the pause is what makes the output readable (2026-08-18)

**Status**: Accepted. Ruled by the maintainer at the D19 analysis gate, on the evidence in
[the D19 analysis](../analysis/d19-warn-producer-reclassification.md). D1…D18 stand; A2 amends
**what the pause keys on**, and closes D19.

#### D19 is discharged — and it changed no producer's level

The reclassification ran by **executing** `cco start` and `cco new` — 15 hermetic scenarios with
`docker` mocked, `warn` instrumented in its own frame, `set -x` for what executed and
`shopt -s extdebug` for which function owns a line. **184 call sites; 46 reached in 12 files; 24
fired.** Method and per-site verdicts:
[the analysis](../analysis/d19-warn-producer-reclassification.md).

**Every reached producer is correct at its level. Nothing is reclassified.** What the enumeration
found is *coverage*, not error:

- The audit's twelve files and the measured twelve are **not the same twelve**. `lib/reminders.sh`,
  `lib/llms.sh` and — named by nobody, not even by D19 — **`lib/migrate.sh`** were never classified.
  `_cco_first_run` runs on every host command, so `_cco_backup_legacy_vault` and
  `_cco_flatten_global_claude` were entered in **all 15** scenarios: their five `warn`s gate a launch
  for any user still carrying the legacy vault.
- `lib/cmd-resolve.sh` had **one** site in the audit and has **six** reachable.
- `index.sh:489,504` are *not* reachable from a start (`_index_rehome_*` is never entered);
  `access-scope.sh:1422-1425` measured **0 reached** in 15 host-lane runs, confirming §3.3's
  "container-operator only".

**ADR-0008 was NOT contradicted, and the reading that said so was wrong.** Its *non-blocking* forbids
a precondition that refuses the command until the tree is clean — it rejects the old clean-tree gate
because it *"forces commits"*. D1's gate forces nothing and a bare Enter starts, which is ADR-0008's
own *"the user may knowingly proceed with uncommitted changes"*. The reminders stay `warn`.

#### D20 — the pause is a property of the RUN, not of the warning level

`cco start` takes under five seconds and then Claude Code owns the terminal. Everything cco printed —
`⚠`, `note:`, `ℹ`, `✓` alike — is gone before it can be read. So the pause's **primary** job in the
field is not *confirm a condition*: it is **holding the terminal long enough for the run's output to
be read at all**. D1 keyed it on `warn`, which fused two independent questions:

| Job | Answers | Keyed on, from now |
|---|---|---|
| **level** | how serious, how presented | `warn` / `note` / `ℹ`·`✓` — unchanged |
| **pause** | may the user read what this run printed | **the run reached the launch**, nothing else |

So: **on an interactive terminal, `cco start` and `cco new` always stop before the container runs and
wait.** What the level changes is what the pause *says*, never whether it happens.

The corollary is why this is not merely nicer: under D1, `note()` and `info()` were **write-only** —
a note printed, was never captured (the gate keyed on the warn count alone), and was overwritten
seconds later. D3 created `note()` so the non-gating level would have a spelling in code; a level
whose messages cannot be read is not a level, and the next author facing that reaches for `warn` for
the very reason D3 exists.

#### D21 — three graduated forms, one prompt

The body above the prompt is graduated; the answer is not.

| The run emitted | The pause shows | The prompt |
|---|---|---|
| chronicle only (`ℹ`/`✓`) | nothing extra | `→ Press Enter to start the session.` |
| notes, no warnings | the notes, grouped by area | `→ Press Enter to start the session.` |
| one or more warnings | `⚠ N warnings … in M areas`, grouped (D17) | `Start the session anyway? [S/a]:` |

`a`/`A` aborts in **all three** — the affordance is uniform even where the clean form does not
advertise it, because a user who picked the wrong project must be able to back out of the one they
did pick. Bare Enter starts everywhere (D10 unchanged).

#### D22 — the buffer carries the level

`note()` is captured like `warn()`, and the buffer record gains a leading level field
(`<level>\t<source>\t<message>`; the records stream becomes `<level>\t<area>\t<message>`). The
renderer emits warnings first, then notes, each grouped by the area derived from `${BASH_SOURCE[1]}`
(D17 unchanged).

**Deferral stays conditional on the append succeeding** (D18): a buffer that cannot be written makes
`note` print immediately, exactly as before. Do not simplify that into an unconditional defer — it is
what keeps a capture problem from eating the message it was built to deliver.

#### D23 — `CCO_ASSUME_YES=1` and `--yes` answer the pause

D20 makes every interactive start pause, so automation driven **from a real terminal** needs a way to
answer rather than a way to pretend there is no terminal. Two spellings, neither new in kind:

- **`CCO_NONINTERACTIVE=1`** — unchanged, already the single opt-out every prompt honours: behave as
  if no terminal existed. The gate prints the list and launches (D11).
- **`CCO_ASSUME_YES=1`** — already means *answer the prompt yes* elsewhere in the codebase
  (`lib/migrate.sh`). The gate now honours it: the list is rendered, the question is not asked.
- **`--yes` on `cco start` / `cco new`** — the same, reachable without env plumbing.

The distinction is the one `_cco_have_tty`'s own contract already draws, and it is worth keeping:
`CCO_NONINTERACTIVE` says *there is nobody there*; `CCO_ASSUME_YES` says *somebody is there and has
already answered*.

#### D24 — one condition, one sentence, across producers too

D16 aggregated a loop's items into one warning. It did not reach the case where **two different
producers describe one condition in two different sentences**, which the deduplication cannot catch
because it keys on the message text. Measured: one uninstalled llms yields *"llms 'X' not installed —
run 'cco resolve' on a terminal"* (`cmd-resolve.sh:319`) **and** *"llms 'X' is not installed (looked
in …) → cco llms install"* (`llms.sh:133`), in two different areas; one unresolved pack does the same
through `cmd-resolve.sh:345` and `packs.sh:195`.

**The downstream sentence survives** — it names where cco looked and the exact remedy, and it is
stated in terms of the session rather than of the resolution attempt. So the resolve pass stays
silent for **llms and packs** when it is about to be restated downstream.

⚠ **Repos and extra_mounts are deliberately untouched**: they have **no** downstream producer, so
`cmd-resolve.sh:271,294` are the only statement of that condition. The rule is therefore not uniform
across the four kinds, and the asymmetry is commented at the sites — a later "tidy-up" that extends
the silence to all four deletes the message.

#### D25 — the passive residue badge is removed

`cmd-start.sh:3155` (*"N reference(s) unresolved — run 'cco resolve'"*) counted only what
`_project_effective_paths` returns (repos + mounts), while `cmd-resolve.sh:383` counts all four kinds.
The first is always a **subset** of the second — there is no case where it fires alone — so the gate
showed two contradictory counts of one condition (measured: *"3 reference(s) still unresolved"* beside
*"1 reference(s) unresolved"*).

It is removed. Its own comment described it as a *"passive ⚠ badge"* that *"never blocks the launch"* —
a pre-gate device for warnings that scrolled past, which is the job D1 took over and, under D20, the
job the pause now does for everything.
