# ADR 0038 — Versioning and reading a project's committed config

**Status**: **Accepted (design)** — 2026-08-20. The eight decisions below were ruled by the maintainer
at the design gate the same day. **Implemented 2026-08-21** — see the *Open* section for the two
values it settled; none of D1…D8 changed on contact with the build. **Amendment A1** (D9…D12,
2026-08-21) adds the `status` pair: the write half had no preview, a cell D2's matrix left empty.
Closes roadmap item **[A1](../../../roadmap.md)**.

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
