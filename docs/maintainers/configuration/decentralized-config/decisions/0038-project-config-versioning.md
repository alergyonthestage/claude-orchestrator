# ADR 0038 — Versioning and reading a project's committed config

**Status**: **Accepted (design)** — 2026-08-20. The eight decisions below were ruled by the maintainer
at the design gate the same day. **Implemented 2026-08-21** — see the *Open* section for the two
values it settled; none of D1…D8 changed on contact with the build. **Amendment A1** (D9…D12,
2026-08-21) adds the `status` pair: the write half had no preview, a cell D2's matrix left empty.
**Amendment A2** (D13…D15, 2026-08-21) corrects **D7**: the predicate chosen to measure gitignore
coverage answers a different question than D7 asks, and diverges from it in two opposite directions —
one false refusal, one false pass. Closes roadmap item **[A1](../../../roadmap.md)**.

**Design**: [Project config versioning and the history surface](../design/design-project-config-versioning.md).
The mechanism, the command surfaces and the test plan live there; this ADR records only what was
decided and why.

**Related ADRs**: 0008 (personal-store management — `cco config save` is the twin this verb is
symmetric with, and its *non-blocking* principle is what forbids turning any of this into a
precondition); 0042 (the agent↔cco interaction model — it already instructs edit-level agents to use
`cco project save`, a verb that until now did not exist); 0024 D6 + 0035 (the synced set and
`cco sync`'s command forms — the multi-repo shape D4 declines to copy); 0059 (message classification —
every message this verb emits is classified by that taxonomy, and `note()` exists only because of it);
0047 (the privilege boundary — why the shim classification in D8 is per-axis and not a blanket).

---

## Context

In the decentralized model (ADR-0001) a project's config lives in `<repo>/.cco/` and is versioned by
**the repo's own git**. There is no separate store to commit it to: the config is a subtree of the
user's code repository, and it is already tracked there — measured on this repo, **11 files under
`.cco/`**, of which the generated session artifacts are excluded by `.cco/.gitignore`.

To version *only* that config, the user must hand-stage `.cco/**` among unrelated working-tree
changes. `cco config save` gives exactly this ergonomics for the personal store `~/.cco` — allowlisted
staging, a secret scan, an explicit commit. The in-repo model never got its twin.

**This is a coherence debt already in production**, not a convenience gap. Two shipped surfaces name a
verb that does not exist:

- The baked managed rule `cco-config-interaction.md` tells edit-level agents to *"commit atomically"*
  and adds that *"a dedicated `cco project save` is forthcoming; until it lands, use git directly"*.
- [ADR-0042](../../agent-cco-access/decisions/0042-agent-cco-interaction-model.md) §Level-C names
  `cco config save` / `cco project save` as the pair an edit-level agent uses.

And one surface inside the product is already waiting for it. The non-blocking reminder aggregator
(`lib/reminders.sh`, ADR-0008) emits two sibling reminders whose remedies are **asymmetric**:

| Reminder | What it says today |
|---|---|
| (a) uncommitted `~/.cco` | `→ cco config save` |
| (b) uncommitted `<repo>/.cco` | `→ commit with your normal git flow` |

Reminder (b) is the one that has no verb to name. It is emitted at every `cco start` and every
`cco sync`, so the gap is in front of the user continuously.

**The reading half is missing on both sides.** A user who wants to know *how did my config change*
must know `git log -- <path>` and must know that `.cco/` is the path. cco owns the config model but
hands the user back to git to inspect it — for the personal store `~/.cco` there is not even a path
the user would guess.

## Principles

- **P-A — cco owns its config model end to end.** Where cco defines what config *is*, it also gives
  the user a way to write it and read its history without learning the storage mechanism. That the
  storage is git is an implementation detail of cco, not a prerequisite the user must acquire.
- **P-B — symmetry between the two stores.** `~/.cco` (personal) and `<repo>/.cco` (project) are two
  instances of one idea. A verb that exists for one and not the other is a gap, and the two must not
  drift into different spellings or different behaviour for the same operation.
- **P14 — awareness, never a block** (ADR-0008). Nothing here becomes a precondition of another
  command. The reminders stay reminders; the verbs are things the user chooses to run.
- **P-C — the user's repo is the user's.** This config is a subtree of a repository cco does not own.
  Every write is scoped to `.cco/**` and nothing else, and cco does not silently author files there.

## Decisions

### D1 — the verb is `cco project save`, not `cco save` *(maintainer, 2026-08-20)*

The maintainer's original roadmap note said `cco save`. Three arguments carried the other way:

- **Two shipped surfaces already name `cco project save`** — the baked managed rule and ADR-0042.
  Choosing it costs **zero rewrites**: the rule's *"is forthcoming; until it lands, use git directly"*
  clause is simply deleted. Choosing `cco save` means editing a file under `defaults/managed/`, which
  is **baked into the image**, so the correction would additionally owe a `cco build`.
- **It keeps P-B's symmetry visible in the spelling**: `config save` for the personal store,
  `project save` for the project. A top-level `cco save` does not say what it saves, and would leave
  its twin at two words.
- An **alias** for both spellings was considered and declined: ADR-0029 D1 removed CLI aliases in this
  project for the opposite reason, and a second spelling is a second thing the docs must rank.

### D2 — reading the history is a cco verb, on both stores *(maintainer, 2026-08-20)*

`cco project history` and `cco config history` are added as read verbs. Wrapping git is an internal
detail; what is decided here is that **the user gets an official cco command** and never needs to know
git, a pathspec, or where the store physically lives.

This is P-A and P-B applied together, and it is why the unit is two verbs wider than the roadmap entry
described: the roadmap asked whether a companion read verb should exist *for the project*. The answer
is that it should exist **for both**, because the personal store is the side where the user is least
able to construct the git command themselves.

The unit therefore closes a 2×2 matrix:

| | personal `~/.cco` | project `<repo>/.cco` |
|---|---|---|
| **write** | `cco config save` *(shipped)* | **`cco project save`** |
| **read** | **`cco config history`** | **`cco project history`** |

### D3 — the history is path-filtered, never trailer-marked

`git log -- <repo>/.cco/` already path-filters correctly however the commit was made. The alternative
— stamping a `Cco-Save:` trailer on the verb's own commits and reading them back with `--grep` — was
declined because it answers a different and weaker question.

**Measured on this repo**: five commits touch `.cco/`, and all five were made **by hand**, before any
such verb existed. A trailer-based history would show **none of them**. A history that is blind to
changes made outside its own verb is a history that misleads, and config edited by hand, by another
session, or by `cco sync` is the normal case, not the exception.

### D4 — `save` commits the invoking repo only, and names the others *(maintainer, 2026-08-20)*

A project may have N member repos, and **each may carry its own `.cco/`** — that is precisely what
`cco sync` converges. Three shapes were weighed; the verb takes the cwd-first one:

- It commits the `.cco/` of the repo the command is invoked from (cwd-first, like the rest of the CLI,
  resolved by `_resolve_find_unit_dir`).
- When **other member repos have an uncommitted or divergent `.cco/`, it says so and names them**,
  reporting which of the divergent configs are committed and which are not, and pointing at
  `cco sync` when the divergence is in content rather than in commit state. The counting and naming
  logic already exists in `_emit_config_reminders`.

A **fan-out** over every member (the `cco sync --all` shape) was declined: `sync` copies files, and a
copy is inspectable and revertible from the diff. This verb writes **history into N repositories**,
each with its own branch and its own state, from a single command. The asymmetry in blast radius is
the reason, not the implementation cost.

Silently committing only the cwd repo was also declined: in a multi-repo project it leaves the user
believing the config is saved when part of it is not.

### D5 — the write surface is `-m` and nothing else *(maintainer, 2026-08-20)*

Identical to the twin: `-m <msg>`, and a default message when it is omitted. No `--amend`, no derived
message template.

`--amend` was declined on a specific ground rather than on minimalism: it rewrites history, and once
the amended commit is already pushed the resolution is a force-push that cco will not perform. The
verb would be able to create a state it cannot resolve. Anyone who genuinely wants to amend has git.

> ⚠ **2026-08-26 (A4)** — an **empty** `-m` is now refused rather than silently replaced by the
> default. The surface is unchanged; what changed is that `-m ""` and no `-m` at all are no longer
> the same request.

### D6 — `history` shows a compact summary, with `--full` for the diff *(maintainer, 2026-08-20)*

The default output is one line per commit carrying **date, author, message, and which parts of the
config changed** (`project.yml`, `claude/rules`, …), with a default limit and `-n` to change it.
`--full` adds the diff.

The naming of *what changed* is the part that earns the verb. A bare `--oneline` equivalent would send
the user back to git to answer the only question they asked, which is the thing D2 exists to prevent.

### D7 — the secret scan always runs; a missing barrier refuses and names the fix *(maintainer, 2026-08-20)*

The twin has a **double barrier**: a whitelist `.gitignore` in `~/.cco` (`*` then `!`-re-include) plus
explicit-path staging, never `git add -A`. In the project the first barrier is **weaker by
construction** — `.cco/.gitignore` is a *blacklist* (`secrets.env`, `*.env`, `*.key`, …), it lives in
the user's own repository, and it may be absent or edited.

So:

- The 2-pass scan of `lib/secrets.sh` (filename + content, `*.example` exempt) runs on the staged set
  **always**, exactly as in the twin, and a hit unstages and refuses.
- Explicit-path staging is kept: only `.cco/**` is ever staged.
- When `.cco/.gitignore` is **missing or does not cover the secret patterns**, the verb **says so and
  refuses**, naming the fix.

cco does **not** write that `.gitignore` itself, which is where this deliberately diverges from
`_config_ensure_gitignore`. In `~/.cco` cco owns the tree and creating the file is housekeeping. In
`<repo>/.cco` the file is a **versioned file in the user's repository**, and authoring it would put an
unrequested change into the very commit the user asked for (P-C).

> **Amended 2026-08-21 by [A2](#a2--2026-08-21-the-d7-barrier-measures-the-wrong-thing-in-two-states)
> (D13, D15).** What is decided above stands — the scan always runs, staging stays explicit-path, and
> cco still does not author that file. What A2 corrects is how *"does not cover the secret patterns"*
> is **measured**: `git check-ignore` answers a different question than this decision asks, and the two
> diverge in two states — a tracked file (false refusal) and a root rule that swallows `.cco/` whole
> (false pass).

### D8 — shim classification: `save` is a project-axis write, `config history` needs read-global

Derived from the measurements, not chosen freely:

| Verb | Classification | Why |
|---|---|---|
| `cco project save` | `_op_write "project save" project` → **Pc=rw** (edit-project+) | Symmetric with `config save`'s `_op_write … global` |
| `cco project history` | free at every level | Reads the repo's own git, like `project show\|validate\|coords` |
| `cco config history` | `_op_read_scope global` | Measured: at `read-project` `~/.cco` **is not mounted as a store** — only the referenced pack is bind-mounted under `~/.cco/packs/`. There is no `.git`, so the verb is structurally unable to answer. Exact precedent: `template show\|validate` |

⚠ **The `save` gate is policy, not mechanism, and the record must say so.** It was measured that
committing a **read-only** `.cco/` *succeeds*: `git add -- .cco/` returns 0 because git reads the
worktree and writes to `.git/`, which is `rw` — the `.cco` bind is a separate read-only child mount
inside a read-write repo. The twin's ro-mount guard exists because `~/.cco` **contains its own
`.git`**; that reason does not transfer here.

The gate is therefore a deliberate choice — *a session that may not edit the project's config may not
fix that config into the repository's history either* — and not a consequence anyone can re-derive
from the filesystem. A future reader who tries will find the mount permits it, so the reason is
recorded here rather than left to be rediscovered as a bug.

## Alternatives considered

| Alternative | Why not |
|---|---|
| `cco save` as a top-level verb | Does not say what it saves; breaks the `config save` symmetry; forces a rewrite of a **baked** managed rule, adding a `cco build` to the unit |
| Both spellings, one aliasing the other | ADR-0029 D1 removed aliases in this project; two spellings is a ranking the docs then owe |
| `Cco-Save:` trailer for the history | Blind to config changed by hand, by another session, or by `cco sync`. Measured: it would show **0 of the 5** real config commits in this repo |
| No read verb (path-filter only, documented) | Leaves the user needing git and needing to know the path — and for `~/.cco` the path is not guessable. Contradicts P-A |
| Fan-out `save` across member repos | Writes history into N repos from one command. `sync`'s precedent does not carry: copying files is inspectable and revertible, commits are not |
| `--amend` | Can create a pushed-and-amended state whose only resolution is a force-push cco will not do |
| Auto-create `.cco/.gitignore` | Puts an unrequested authored file into the user's repo and into the commit they asked for (P-C) |
| Make `save` host-only, like `project add` | Would make ADR-0042's Level-C instruction unexecutable **for exactly the agents it is written for**, and contradicts the twin, which is available in-container |

## Consequences

- The baked managed rule `cco-config-interaction.md` loses its *"forthcoming"* clause and names the
  real verb. ⚠ It is **image-baked**, so that edit lands with a `cco build` in its acceptance lane —
  the only part of this unit that does.
- Reminder (b) in `lib/reminders.sh` gains a remedy that names a verb, closing the asymmetry with (a).
- The 2×2 matrix in D2 is closed, and the CLI surface grows by **three verbs**, of which one was
  already promised in two shipped documents.
- `cco project history` and `cco config history` are new read surfaces, so `cco --help`, the CLI
  reference and the user guide gain entries; the `changelog.yml` entry is owed **at implementation**,
  not before.
- A session at `read-project` that sees a dirty `.cco` is refused by D8 with a message that names how
  to widen access. This is a visible behaviour, and it is the one place where the policy in D8 is felt.

## Open

- **The default commit message.** D5 fixes the surface (`-m` only) but not the string the verb uses
  when `-m` is absent; the twin uses `config update`. Settled at implementation, and cheap to change.
- **The default limit of `history`.** D6 fixes the shape, not the number. Settled at implementation.

### Settled at implementation *(2026-08-21)*

- **The default commit message is `project config update`**, not the twin's bare `config update`.
  The two commits do not land in the same place: the twin's goes into `~/.cco`, a log that holds
  nothing but config, while this one goes into the **user's own repository**, among their code
  commits. There, `config update` does not say *which* config.
- **`history`'s default limit is `-n 10`.**

One thing D7 left implicit and the build had to decide: **which** patterns the `.cco/.gitignore`
coverage check demands. The full `_SECRET_FILENAME_PATTERNS` list carries `.netrc` and `.cco/remotes`,
and cco's own project scaffold (`_cco_write_project_gitignore`) has never written either — so keying
the check to that list would refuse `cco project save` on **every project cco itself created**. The
floor is therefore the class set the scaffold declares, held in step with it by a mechanical invariant
(INV-GIF). Nothing is lost: the 2-pass scan still runs against the **full** list on every save, so a
`.netrc` under `.cco/` is caught and refused — the floor decides what must be barred before staging,
the scan is what reads the files.

---

## Amendments

### A1 — 2026-08-21: the write half has no preview (`cco project status` / `cco config status`)

Raised by the maintainer **during implementation**, against the finished three verbs. Not a defect —
a cell of the model this ADR itself defines, which D2 did not notice it was leaving empty.

**The gap.** `save` is a write with two refusal paths (the D7 barrier and the secret scan) and a
`.cco/**`-scoped commit set that is not obvious from the outside. There is no way to ask *what would
`save` commit, and would it succeed* short of running it. `history` does not answer it: history is
what **was** saved, status is what is **not saved yet** — the same distance `git log` keeps from
`git status`. Folding it into `history`'s output was considered and declined for that reason: two
questions, two answers, and a read verb that prepends a different question to its own output is one
users cannot pipe.

`cco project show` does not answer it either, and must not be extended to: it is the **topology**
card (which repos are members, who else references them). Working-tree state is a different subject.

### D9 — the verb is `status`, on **both** stores *(maintainer, 2026-08-21)*

`cco project status` **and** `cco config status`. This is P-B applied a third time, and the argument
is the one that already turned D2 from one read verb into two: a verb that exists for one store and
not the other is a gap, and `cco config save` has exactly the same missing preview. The matrix D2
closed is now 2×3.

The name is `status` rather than `diff` because the default answer is *which files*, not *what
changed inside them*; `--full` adds the diff, symmetric with `history --full`.

### D10 — `status` reports the barrier, it never enforces it *(maintainer, 2026-08-21)*

A missing or insufficient `.cco/.gitignore` makes `save` **refuse** (D7). `status` must **say so and
exit 0** — it is a read verb, and a preview that dies is a preview nobody can use to find out why
their save would die. It names the same fix, in the same words, and still lists what would be
committed, so one invocation answers both halves of the question.

This is also why `status` emits no `warn`: same reasoning as the design's §2.6.

### D11 — each `status` mirrors ITS OWN save's rule, not a generic `git status`

The two stores decide "what would be committed" differently, and the preview is worthless if it does
not reproduce that decision exactly:

| Store | What `save` commits | What `status` must therefore list |
|---|---|---|
| `<repo>/.cco` | everything under `.cco/**` that git does not ignore | changes under `.cco/**`, gitignored files excluded |
| `~/.cco` | only `_CONFIG_ALLOWLIST` entries | changes under those entries — a stray `~/.cco/scratch.txt` is **not** listed, because `save` would not commit it |

A plain `git status` on either root would name files neither verb would commit. That is the failure
this decision exists to prevent, and it is the same class as the design's warning against
`_sync_synced_files`: the *nearly* right list is the dangerous one.

### D12 — shim: `project status` free, `config status` needs `read-global`

Identical to D8's reasoning for the `history` pair, from the same measurement: `project status` reads
the repo's own git; `config status` cannot answer at `read-project`, where `~/.cco` is not mounted as
a store.

### A2 — 2026-08-21: the D7 barrier measures the wrong thing in two states

Raised by **`/review-implementation`** against the accepted A1 branch, from two measurements. Neither
is a defect of the build — the implementation is faithful to D7 as written. What A2 corrects is D7
itself: it says *"when `.cco/.gitignore` is missing or does not cover the secret patterns"*, and the
mechanism chosen to measure that — `git check-ignore` — answers a **different question** than the one
D7 asks. D7 asks *does a rule protect this class*; `check-ignore` answers *would git ignore this path
right now*. The two diverge in exactly two states, and they diverge in **opposite directions**:

| State | D7's question | What `check-ignore` answers | Consequence |
|---|---|---|---|
| the file is already **tracked** | protected — the rule is there | **not** ignored (git consults the index) | refusal loop: the remedy is a line already in the file |
| the root `.gitignore` ignores **`.cco/` entirely** | not protected — no class-specific rule exists | ignored, for all four probes | barrier passes vacuously, and nothing is ever saved |

Both were measured. The first is a **false refusal**, the second a **false pass** — which is why one
amendment covers them: a single predicate is answering for two questions, and correcting only the
direction that annoys would leave the direction that silently loses data.

### D13 — the barrier asks whether a rule EXISTS, not whether git applies it today *(maintainer, 2026-08-21)*

`_project_gitignore_gaps` probes with **`git check-ignore --no-index`**. Without that flag git
consults the index first, so a file the user committed *before* adding the rule reports as *not
ignored* — and the refusal then prints, as its remedy, a line that is **already in the file**. The
save is refused permanently and the instruction cannot be followed. `status` repeats the same
unfollowable remedy. `--no-index` is not a loosening: it is what the design's own words —
*"a rule that matches, however it is spelled and wherever in the ignore chain it lives"* — already
specify. The index is not part of the ignore chain.

A **tracked** secret is still reported, as a `note`, and the save proceeds:

- **The save is not the event that exposes the secret.** The file is already in the repository's
  history; it got there in an earlier commit. Refusing forever punishes a past act, blocks the user
  from versioning their config at all, and un-exposes nothing.
- **The floor still holds where it can act** (measured): `_secret_scan_staged` reads
  `git diff --cached --name-only`. Tracked **and modified** → `git add -- .cco` stages it → the scan
  **refuses**. Tracked and unmodified → it is not in the commit at all. Neither path lets *new* secret
  content through, which is the only thing `save` is in a position to prevent.
- **The `note` must not imply that untracking cleans the past**, or it trades one false belief for
  another: `git rm --cached` stops future commits, it does not rewrite the ones already made. The
  message says so.

> ⚠ **2026-08-24 ([A3, D19](#d19--the-secret-remedy-branches-on-whether-the-path-is-already-tracked))**:
> letting the barrier pass on a tracked file makes the SCAN reachable for `.cco/secrets.env`, where the
> scan's own remedy — *"move the secret into `<repo>/.cco/secrets.env`"* — names where it already is.
> D19 branches that remedy. A2 opened this path; it did not create the wording.

**Level: `note`, never `warn`** — §2.6 of the design, unchanged and load-bearing. A `⚠ warn` gates a
launch (ADR-0059 D1); nothing this verb observes should stop a session from starting.

**No confirmation prompt.** Considered and rejected on three grounds, the first mechanical:

1. `_cco_warn_gate` has **exactly two call sites**, both launches, and
   `test_warn_gate_is_reached_only_through_the_two_launch_paths` asserts that set by name. A third
   site is an amendment to ADR-0059, not a code change.
2. The gate exists because `cco start` hands the terminal to the TUI and the scrollback is destroyed
   (ADR-0059 P1). `project save` is a foreground command that ends and leaves its output on screen —
   the message is readable without a pause, so the pause buys nothing.
3. A tracked file **stays tracked** until the user acts. The prompt would fire on every save,
   forever, which is precisely how a real refusal is trained into reflex. A prompt fits a one-shot
   irreversible act; this is a standing state.

*(A fourth, minor: `save` can run from automation, and a prompt would derive the
`_cco_have_tty` / `CCO_NONINTERACTIVE` / `CCO_ASSUME_YES` contract a second time — which ADR-0059
names as how this suite acquires a silent hang.)*

> ⚠ **2026-08-26 (A4 D21)** — read the sentence above about what the floor can act on **literally**:
> the scan answers for content **entering** the commit. It does **not** answer for a path being
> **deleted**, and until A4 it did — refusing the one action that removes a secret from the config.
> A reader who reaches this decision without D21 will rebuild that refusal.

### D14 — `status` previews BOTH refusal paths *(maintainer, 2026-08-21)*

A1's own premise was that `save` has **two** refusal paths and no way to ask *what would it commit,
and would it succeed*. What A1 built anticipates one: with a `.cco/.netrc` present, `status` lists it
as `A .netrc` and closes with `→ cco project save`, and the save then refuses on the 2-pass scan. The
preview promises a save that will fail.

`status` therefore runs the scan over the set it would commit and reports the outcome. D10 is
unchanged and governs it: **report, never enforce, rc 0** — a preview that dies is a preview nobody
can use to find out why their save would die. Same words as the refusal, from the same source, per
D11's rule that the remedy may never name a different set than the one that refused.

### D15 — a barrier satisfied because `.cco/` is wholly ignored is not satisfied *(maintainer, 2026-08-21)*

> ⚠ **AMENDED 2026-08-24 by [Amendment A3, D16](#a3--2026-08-24-a2s-own-barrier-repeated-the-defect-a2-removed).**
> The key below is kept; its **conclusion is not**. *"`.cco/` is ignored in its entirety"* is not what
> `.cco/project.yml` being ignored proves — measured, a root `.gitignore` of merely `*.yml` satisfies
> the key while git still stages two files, so the refusal named a rule that did not exist. Implement
> D16, not the paragraph below, or you will rebuild the unfollowable remedy D13 exists to abolish.


When the repository's root `.gitignore` ignores `.cco/` in its entirety, every class probe reports
*ignored*, the barrier passes, `git add -- .cco` stages nothing, and the verb reports
`ℹ <repo>/.cco is already up to date — nothing to save` while `status` reports it clean and never
committed. Measured. The config is **never saved**, and both verbs affirm that all is well — the
worst available outcome, because it is silent, total, and indistinguishable from success.

The barrier passed for a reason that has nothing to do with protection, so the passing is void. The
discriminator is a **non-secret** path: if the probes pass *and* `.cco/project.yml` is also ignored,
the coverage is vacuous. That state **refuses**, naming the root `.gitignore` as the file to fix —
and `status` reports it at rc 0, per D10.

This is P2 of ADR-0059 in a new guise: a barrier whose pass condition can be satisfied by an unrelated
rule is not a barrier. It fails silently, which is the only failure mode this project treats as
disqualifying.

### A3 — 2026-08-24: A2's own barrier repeated the defect A2 removed

Raised by **`/review-implementation`** against the built A2, from four measurements. A2's code was
faithful to D13/D14/D15 as written; what A3 corrects is what those decisions turned out to assert.

The through-line is one failure and it is D13's own: **a message that claims more than its mechanism
proves, and a remedy the user cannot follow.** D13 removed one instance of it and D15's refusal
reintroduced another, one screen away.

| # | Measured | Why it is the same defect |
|---|---|---|
| a root `.gitignore` of merely `*.yml` | refuses with *"ignores `.cco/` entirely… would commit nothing at all"*, and *"remove the rule that ignores .cco/"* — while git stages **two** files and **that rule does not exist** | a remedy naming a line that is not in the file — verbatim D13 |
| a root rule of just `.cco/.gitignore` | the save reports **`✓ saved`** on a config whose **barrier never landed**; every clone starts unprotected | a silent, total failure that both verbs affirm — verbatim D15 |
| root swallows `.cco/` **and** `.cco/.gitignore` is missing | `status` says **"is clean"** over 4 unsaveable files; `save`'s two remedies arrive one round trip apart | "clean" claims the config is saved — the falsehood D15 exists to stop |
| `status --full` on a `.cco/.netrc` | prints `a secret-like file would be staged`, then the password **24 lines below** | the verb publishes what it just called a secret |

#### D16 — the barrier reports what it can prove, and `save` proves the outcome *(maintainer, 2026-08-24)*

D15's key — *`.cco/project.yml` is also ignored* — is kept, because the harm it detects is real. Its
**conclusion** is not: that key does not prove `.cco/` is ignored in its entirety, and no finite set
of probes could. The finding is renamed to what it establishes — **an ignore rule keeps an essential
file out of the commit, so the save would be partial** — and it names the **rule that actually
fires**, via `git check-ignore -v --no-index`, at a path the user can open.

It is widened on two axes, both from measurement:

- **From one path to an ESSENTIAL SET** — `project.yml` (identity, and the cwd-first anchor) and
  `.gitignore` (the D7 barrier every clone inherits). The second is what caught the `✓ saved` above.
- **From prediction to post-condition** — after `git add -- .cco`, `save` asserts each essential is in
  the index the commit is built from. Unreachable while the barrier holds, and that is its purpose:
  it converts a future hole in the barrier into a refusal instead of a wrong commit. ⚠ It is
  therefore **untestable through the CLI**, and is pinned by a direct call — a guard nothing can
  reach is a guard nothing has measured.

⚠ **Refusing when `.cco/` is ignored wholesale stays, and is not a fallback.** It is the documented
path for a solo adopter who deliberately keeps their cco config out of git; for them the save must
**abort**, never half-succeed. The refusal says so in as many words, so the state does not read as an
error to be worked around.

#### D17 — the findings are independent, and "clean" is not available while one stands

Returning early on `missing` sent the user to create `.cco/.gitignore` and only then meet the second
refusal: two round trips for one broken state, each remedy correct and neither sufficient. All
findings are computed and rendered together, by **one** renderer that `save` sends to stderr and
`status` prints to stdout.

And `status` must not say **"is clean"** while any finding stands. Nothing to *commit* is not the same
as *saved*, and AT5 already forbade the word in the adjacent state — the composite state slipped
through only because of the early return this decision removes.

#### D18 — `--full` withholds the diff of a file it has just called secret-like

A preview that names a file secret and prints its contents four lines below has published exactly what
it warned about. The diff is replaced by one line naming the pattern that matched. **`*.example` is
exempt**, on the same terms as the scan (FR-S3): a skeleton exists to be read, and withholding it
would hide the one file whose purpose is to be committed and inspected.

⚠ The question is asked **per file**, not reused from the scan: the scan stops at its first hit, while
every listed file is rendered. This reaches `cco config status` too, which shares the renderer.

*(This behaviour predates A2 — A1's `--full` already diffed the file. A2 is what made the verb know it
was a secret in the same run, so the inconsistency is A2's to close.)*

#### D19 — the secret remedy branches on whether the path is already tracked

*"Move the secret into `<repo>/.cco/secrets.env`"* names where the file already is when the offending
path **is** `secrets.env`. That state is reachable **because of D13**: before it, a tracked secret was
stopped by the false barrier refusal and never reached the scan. A tracked path is told to
`git rm --cached` it instead, with the same caveat D13's note carries — untracking stops future
commits, it does not rewrite the ones already made.

⚠ The test is `git cat-file -e HEAD:<path>`, **not** `git ls-files`: `save` has already staged by the
time it refuses, so the index would report a brand-new file as tracked too.

> ⚠ **2026-08-26 (A4 D21)** — this branch is correct and stays, but it was **unreachable from the
> state that needed it most**: when the user *deleted* the tracked secret, the save refused before the
> remedy could help, and the refusal's own `git reset` undid the `git rm --cached` it prescribes. The
> remedy did not change; what changed is that the save no longer refuses there.

### A4 — 2026-08-26: the same defect, two states further out, and one verb that could not be asked

Raised by **`/review-implementation`** over the whole finished cycle — six verbs, both stores —
rather than over the A3 delta. That scope is what found these: A1's review produced A2, A2's produced
A3, and each pass looked only at the delta in front of it, so a defect present since A1 was never in
anyone's frame.

Two of the three are **A3's own through-line** — *a message that claims more than its mechanism
proves, and a remedy the user cannot follow* — in states A3 did not look at. The third is the
`P-B` parity rule broken inside the reviewed surface.

| # | Measured, with a discriminating control | Why it is the same defect |
|---|---|---|
| `.cco/` **one directory below** the git top-level | `✓ saved svc/.cco @ 7504a11`, and `git show HEAD:svc/.cco/…/leak.md` prints `API_KEY=sk-ant-…`. The flat control refuses. | a `✓` over a committed secret — verbatim the D15 measurement, one *topology* over |
| a save that **deletes** `.cco/secrets.env` | refused as *"a secret-like file is staged"*; its remedy prescribes `git rm --cached`, and the refusal's own `git reset` restores the index entry — the follow-up commit says `no changes added to commit` | a remedy the verb itself makes unreachable — verbatim D13 |
| `cco config save --help` | `✗ Unknown option: --help` — the only verb of the six without the arm, so the house gate probe could not be run on it at all | the two stores drifted into different spellings (P-B) |

#### D20 — the project verbs anchor on the git top-level, not the unit dir *(maintainer, 2026-08-26)*

`.cco/project.yml` may sit in a **subdirectory** of the repository that versions it — a service inside
a monorepo, a repo adopted below its root — and nothing ever required the two to coincide. The
maintainer's ruling is to **support that topology**, not to refuse it: `save` works from any path.

The mechanism is one asymmetry that had gone unnoticed. **Pathspecs are cwd-relative**, so `git -C
<unit dir> … -- .cco` selected the right files; but **every git OUTPUT path** — `status --porcelain`,
`diff --cached --name-only`, `ls-files`, `show --name-only`, and `check-ignore -v`'s *source* — is
reported relative to the **top-level**. Joining those onto the unit dir failed silently, three ways:

- the secret scan's **content pass was skipped for every file**, on **both** save gates, because
  `[[ -f "$root/$f" ]]` was false — only the filename pass survived;
- `status --full` printed **no diffs at all** — half the verb, silently dead;
- D13's tracked finding could never fire, and D6's changed-parts column degraded to raw paths.

One resolver now answers with the top-level, the `.cco` path **relative to it**, and the repo name to
print. At the top level the prefix is empty, so every message is byte-identical to before — which is
why the existing tests pass unchanged, and also **why they could never have caught this**: a test
written only at the top level cannot see the defect. The pair is pinned flat **and** nested.

#### D21 — a deletion is not a leak *(maintainer, 2026-08-26)*

`git diff --cached --name-only` lists a deleted path exactly like an added one, so the filename pass
refused the single most desirable action a user can take. D13's own rationale already drew the line —
*neither path lets **new** secret content through, which is the only thing `save` is in a position to
prevent* — and a path being removed carries no content into the commit. The content pass never saw a
deleted file anyway (`[[ -f ]]` is false), so what changes is the **filename pass, for deletions only**.

Both **gates** filter with `--diff-filter=d`, and both **previews** filter identically: a preview that
scanned a different set than the refusal is the drift D11 exists to prevent, in whichever direction it
moves. The deletion is still **listed** as `D <file>` — what is dropped is the scan's set, not the
user's view of the commit.

⚠ It holds on **both stores** or on neither. On `~/.cco` the refusal's reset is the *bare* `git reset`,
so there the false refusal also unstaged everything else.

#### D22 — `cco config save` answers `--help`, like its five siblings *(maintainer, 2026-08-26)*

It died on `--help`, which is the drift P-B forbids between the two stores. It had a second cost that
is not cosmetic: the house gate probe **drives `<verb> --help`** and requires a usage line back —
precisely so a verb with no handler fails the probe instead of passing vacuously — so this one verb's
access gate could only ever be asked *negatively*. It is now asserted positively at `edit-all` too.

#### Realignments this review made that needed no decision

Recorded so a later reader does not mistake them for drift. Each was an objective defect against a
document already approved, or a test whose oracle did not discriminate.

| What | Against |
|---|---|
| `status` in the `excluded` state now **lists the rest of the config** | §5b.3, verbatim: it reports the barrier *"and still lists what would be committed"*. The early return made the message say "part of the config" and never name the other part |
| `save` reports D4's member facts on the **`already up to date`** path | `status` already did on its clean path; that is the state in which believing the whole project is saved is likeliest |
| the personal store's leak remedy is printed from **one** place | the project half factored `_project_secret_remedy` for exactly this reason; this was a second inline copy of the same sentence |
| an **empty** `-m` is refused, on both stores | D5 fixes the write surface at `-m`; silently substituting the default records a message the user did not write, in *their* git log |
| the content pass no longer goes **silent** where `file(1)` is absent | it returned "clean" on both gates; `grep -I` answers the same question with a tool the scan already needs |
| AT9's oracle measures the **emitter's shape**, not the `⚠` glyph | an indented `⚠` is an existing house idiom, so the glyph oracle measured the idiom as much as the emitter — AT9 passed only because its scenarios missed that branch. It is now also exercised on the branch that prints it |
| the missing-barrier test asserts **its own** refusal | `.gitignore` appears in nearly every refusal this verb emits, so it could not tell that refusal from any other |
