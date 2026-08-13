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
