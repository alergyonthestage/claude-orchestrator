# Cycle-1.2 — fix plan & multi-session handoff

> **Inputs (read in this order)**:
> 1. [`../results/consolidated-review-v3.1.md`](../results/consolidated-review-v3.1.md) — the v3.1
>    verdict (**NOT ACCEPTED**), the root map **R-A…R-J**, and the ratified decisions **D-V31-1…4**.
> 2. [`../../../../engineering/analysis/invariant-gap-audit.md`](../../../../engineering/analysis/invariant-gap-audit.md)
>    — the meta-root and the shape of each proposed invariant. **This is the design input.**
>
> **Gate**: closing this cycle unblocks the CLI-surface audit, then `develop → main`.
> **Branch**: `fix/release/cycle-1.2`, from `develop`. One branch, atomic commits, as cycle-1.1 did.
> **Status**: plan written 2026-07-28. **Nothing landed yet.** Session status table in §2 — keep it
> and [`../../../../roadmap.md`](../../../../roadmap.md) §B2-next in step; the roadmap is the SSOT,
> this file is the runbook.

Cycle 1 fixed the *model*. Cycle 1.1 fixed the *write path*. **Cycle 1.2 fixes the fact that three
layers have no owner** — and it is deliberately shaped that way. The v3.1 evidence is that fixing
these findings one at a time is *what produced them*: each past cycle patched the reported site and
left its siblings, and the `read-global`-for-a-project string was found independently by all four
sessions. **The unit of work here is the invariant plus its lint; the findings close as a
consequence.** A session that closes its findings without landing the lint has not finished.

No cycle-1 or cycle-1.1 design decision is reversed. Everything v3.1 classified as cycle-2 stays
cycle-2 (**FI-33…FI-36**).

---

## 1. Two rules that govern every session in this cycle

**Rule 1 — suite-green is not acceptance for S1 and S3.** The hermetic lane cannot observe
mount-time or container-context reality; that is RC-17, and this cycle contains its **fourth**
recurrence. Those two sessions are accepted on a **probe in a real container after `cco build`**,
pasted into §7's acceptance log. If you find yourself writing *"tests pass"* as the evidence for a
mount or context behaviour, stop — you are about to repeat the exact mistake the review names.

> **Corrected 2026-07-29 — S5 was in this list and should not have been.** The maintainer ruled
> that the **golden-file round trip IS sufficient acceptance for L4** (and the two arm tests for L5):
> S5 closes **in-session**, with no host-side probe. The rule's own criterion is what settles it —
> S5's surface is neither mount-time nor container-context. `_yml_append_coord` rewrites a file the
> suite can hand it, and the EXIT trap's misfire is observable from any `bin/cco` invocation; both
> defects reproduce identically on host and in session. The design input agrees and always did:
> `invariant-gap-audit.md` §5 names items **2, 3 and 4** as the ones invisible to the suite, and
> deliberately not item 5 (INV-YAML). §7's session table likewise already carried `n/a` in S5's
> container-probe column — Rule 1's list was the outlier, and it was simply too broad. The roadmap's
> lane-L4 warning is corrected in step. Recorded in §7's acceptance log.

**Rule 2 — design gate before implementation.** S2 is design-only and ends at a human gate. S1 has an
internal gate (design → approve → implement) marked in its brief. Per
the project `workflow.md` rule (pack `core-dev-framework`), a phase transition is
never crossed autonomously, and anything touching future extensibility, capabilities or user-visible
flows stops and asks even mid-implementation.

---

## 2. Session map and status

Ordered by **urgency × independence**, not by severity: S1 is the only lane actively breaking the
maintainer's daily work, and it depends on nothing.

| # | Session | Lane | Produces | Status |
|---|---|---|---|---|
| **S1** | Claude Code runtime paths | L3 (**R-D** + **R-F**) | ADR in `environment/decisions/`, Dockerfile + mount-generation fix, INV-MP lint, container probe | ✅ **accepted 2026-07-28** ([ADR-0055](../../../../environment/decisions/0055-claude-runtime-state-and-mountpoint-ancestry.md)) — both container probes green (§7): the `:ro` lane, then the `Cp=rw`+composing arm across a real restart. One residual, host-side: D7 with no packs at all |
| **S2** | The availability model — **design only** | L1 + L2 (**R-A** + **R-C**) | one ADR in `configuration/agent-cco-access/decisions/`; **no code** | ✅ **accepted 2026-07-29** ([ADR-0056](../../decisions/0056-availability-model-and-index-session-axis.md)) — D1–D9, six alternatives recorded. Two maintainer decisions inside it: R-B's count is host-computed at `cco start` (no new privileged surface), and `absent`-in-session gets **two** causes/sentences. S3 and S4 are unblocked |
| **S3** | Index-health session/host axis | L2 (**R-C** 🔴) | `index.sh` taxonomy + the `[unresolved]` conflation, container probe | ⬜ not started |
| **S4** | INV-AVAIL sweep | L1 (**R-A** 🔴, **R-B** 🔴) | one owner for availability answers + CLASS lint | ⬜ not started |
| **S5** | Two small classes | L4 (**R-E**) + L5 (**R-G**) | INV-YAML + golden-file lint; EXIT-trap sentinel + lint | 🟡 **landed 2026-07-29** on `fix/cycle-1.2/s5-inv-yaml` (own worktree, no ADR — see §6). Both lanes close **in-session** per the Rule-1 correction in §1; evidence in §7 |
| **S6** | Close-out | — | §10.9e/E6B-04, host cleanup, re-acceptance, README platform fix | ⬜ not started |

**Dependency**: S2 must precede S3 and S4 (it defines the states and the owner they both implement).
S1 and S5 are independent of everything — they may run in any order relative to the rest.

**Baseline to re-establish before touching anything**: the last recorded in-container suite result is
**1531/7** (the 7 are the pre-existing host-only artifacts — see the memory note *suite-7-host-only*;
do **not** try to fix them here). Run `./bin/test` once at the start of the cycle and record the
actual number in §7; if it is not 1531/7, find out why before proceeding.

> **Established 2026-07-28 — `1533/7`, reconciled.** The `+2` is `4b3679a` (the last ADR-0054
> follow-up), which added exactly two test functions after the 1531 was recorded. The 7 are the known
> host-only set, named here so a future run compares names and not just a count: the six
> `test_as_*` access-scope output-scoping tests (defeated in-container by the ADR-0047 privilege
> boundary) plus `test_paths_symlink_safe_tool_root`.

---

## 3. S1 — Claude Code runtime paths (**R-D** + **R-F**)

> **This is the session that unblocks the maintainer's daily work.** Subagent/agent-team transcripts
> and workflow persistence are failing with `EACCES` right now.

**Read first**: `consolidated-review-v3.1.md` §7.1 · `invariant-gap-audit.md` §3 · ADR-0054 (INV-MP) ·
ADR-0049 §2/§5 (`claude_access`, the functional-write floor) · `Dockerfile:115-130` ·
`lib/cmd-start.sh:1720-1796`.

### 3.1 The two defects

**R-D — `~/.claude/projects` is materialised `root:root 0755`.** cco binds
`~/.claude/projects/-workspace` and `.../memory` (`cmd-start.sh:1793-1796`); the **parent**
`projects/` is absent from the image, so the runtime creates it root-owned. `claude` can traverse and
read it, and cannot create inside it. Claude Code keys per-project state by cwd
(`~/.claude/projects/<key>/`): `-workspace` works, **every other key fails** — a subagent or teammate
started from `/workspace/<repo>`, a worktree session, a background session.

Reproduced on `develop@8fd479c`, macOS — so it is **not** the Linux/DAC issue (the directory is
container-local, DAC applies normally, `fakeowner` is irrelevant):

```
drwxr-xr-x 3 root root 4096 /home/claude/.claude/projects
touch: cannot touch '/home/claude/.claude/projects/.wprobe': Permission denied
```

The decisive detail: **`Dockerfile:119-124` already documents this exact rule** and pre-creates
`.local/bin`, `.local/share`, `.local/state`, `.cache`, `.claude` on it. `.claude/projects` was not
added. Third recurrence of R1's mechanism (v3's STATE bucket, FI-31, now this).

**R-F — ADR-0049's `:ro` default clamps runtime state.** `/workspace/.claude` is `ro` whenever
`Cp≠rw`; the only functional-write floor is `settings.local.json` (§5). Official docs place
project-scope workflow saves in *"the closest existing `.claude/workflows/`"* — which is inside that
`:ro` tree.

### 3.2 The design decision (gate — approve before writing code)

> **Proposed axis**: `claude_access` governs **authoring** (CLAUDE.md, rules, agents, skills). It does
> **not** govern Claude Code's **runtime state**, which stays writable at every access level —
> exactly as `settings.json` already is (`cmd-start.sh:1738`, *"always rw (runtime prefs)"*).

Derive the floor from the **official** *application data* table (`claude-directory` in
`/workspace/.claude/llms/code-claude/llms-full.txt`; consult it directly, per the managed
`use-official-docs` rule — do not work from this list alone):

`~/.claude/projects/` · `history.jsonl` · `file-history/` ·
`{tasks,teams,sessions,session-env,shell-snapshots,backups,plans,paste-cache,image-cache,debug}/` ·
`stats-cache.json` · `remote-settings.json` · `plugins/` · project-scope `.claude/workflows/` and
`.claude/worktrees/`.

Two questions the design must answer explicitly, because both are user-visible:

1. **Where does project-scope runtime state live** when the committed tree is `:ro`? The
   `settings.local.json` precedent (a rw child overlay from per-project STATE) generalises, but
   ADR-0054 D4 already warns that a composed `/workspace/.claude` makes *new* files session-local.
   Decide whether workflow saves are session-local, STATE-persisted, or repo-persisted.
2. **Is the floor a fixed list or a declared contract?** A fixed list needs re-deriving on every
   Claude Code release. Record the provenance comment pointing at the official doc either way.

### 3.3 Work items

- **W1** — pre-create `/home/claude/.claude/projects` claude-owned in the Dockerfile, beside the
  existing XDG pre-creation, extending that comment to state the generalised rule.
- **W2** — **INV-MP generalised**: for every bind cco generates, every ancestor the runtime would
  have to materialise is pre-created by cco with the owner the writer needs — host-side in cco's own
  tree (ADR-0054 already), container-side in the image.
- **W3** — the lint: parse a **really generated** `docker-compose.yml`, derive every target's ancestor
  chain, assert each ancestor is either image-created and claude-owned or itself a cco-owned mount.
  ⚠ Against a real generated file, not a fixture.
- **W4** — the functional-write floor per §3.2, with its provenance comment.
- **W5** — ADR in `docs/maintainers/environment/decisions/`, forward-annotating ADR-0049 §5 and
  ADR-0054. Changelog entry (additive/behavioural — see `.claude/rules/update-system.md`).

### 3.4 Verification (Rule 1 applies — this lane is invisible to the suite)

⚠ **The maintainer's uncommitted `access: {claude: all}` block in `.cco/project.yml` MASKS R-F.**
It is the FI-25 workaround and it makes every `.claude` tree `rw`. To reproduce, stash it; to keep
working normally, restore it. Note this in the session log — a green probe with that block in place
proves nothing.

After `cco build`, in a **default** (`read-project`) session:

```bash
ls -ld /home/claude/.claude/projects                  # expect claude:claude, not root:root
touch /home/claude/.claude/projects/.probe && rm …    # expect success
grep '/workspace/.claude/workflows' /proc/self/mountinfo   # expect a rw entry (or the ratified alternative)
```

Then the real acceptance: **start a subagent / agent-team teammate from inside a repo directory** and
confirm its transcript is written. That is the reported symptom, and nothing short of it closes R-D.
Restart the container afterwards and confirm the transcript is still there — D5 persists every key,
and a probe that only proves *writable* would leave the ephemeral half untested.

> **Landed 2026-07-28** (branch `fix/release/cycle-1.2`, 4 commits `d550da8`, `3f27e39`, `918c8b1`,
> `57ab325`; suite **1549/7**). Two notes for whoever runs the probe:
>
> - **A second instance of R-D was found by the lint, in the DEFAULT lane**: `~/.cco` and
>   `~/.cco/packs` were `root:root` and unwritable, because project read scope binds the referenced
>   packs one by one and leaves both parents pass-through. Fixed in the same Dockerfile change, so
>   add `ls -ld /home/claude/.cco /home/claude/.cco/packs` to the probe.
> - **The probe list above is a lower bound** for `grep '/workspace/.claude/workflows'`: the mount is
>   present only when B2 is `:ro`. With the `access: {claude: all}` block still in `.cco/project.yml`
>   there is *correctly* no overlay and workflows land in the repo — so stashing that block is not a
>   nicety here, it decides which of two correct behaviours you are looking at.

---

## 4. S2 — the availability model (**design only**, no code)

**Read first**: `consolidated-review-v3.1.md` §3, §4 (R-A/R-B/R-C), §6 (**D-V31-1**, **D-V31-2**) ·
`invariant-gap-audit.md` §2 · ADR-0043 (symmetric read scoping) · ADR-0047 §INV-S6 ·
`lib/access-scope.sh` (esp. `_env_member_state`, `_env_project_state`, `:632-637`, `:688`, `:785`) ·
`lib/index.sh:104-180`.

This session produces **one ADR** covering both halves, because they meet in the same renderer:
`project show`'s `[unresolved]` marker answers *"the index did not tell me a path"* and prints it as
*"no path is bound"*. Splitting them would put one predicate in two ADRs.

### 4.1 What the ADR must settle

**INV-AVAIL** — no verb computes an availability or scope-widening answer for itself.
`lib/access-scope.sh` owns (a) the three-state classification, (b) the sentence, (c) the remedy, and
(d) the exit code. A verb may *ask*; it may not *decide*. Three sub-rules the evidence forces:

- **A remedy is a function of the print site** — a sentence emitted in a container may never
  prescribe a verb that is host-only there (`cco resolve` is the specific string).
- **The widening offered is a function of what is hidden** — projects-only → `read-all`; store kinds
  → `read-global`; mixed → both. The aggregate notice already does this; the per-resource sites must
  share the *implementation*, not merely the intent.
- **The `unknown` arm exists and is enabled only at read scope `all`** (**D-V31-1**). Below `all`,
  one non-disclosing sentence that **asserts nothing**.

**The index-health session/host axis** — `_index_health`'s taxonomy (`ok | absent | unreadable |
truncated | stale`) treats `absent` as the only benign state. A session is *launched from* the index,
so in-container `absent` can only mean the bind broke or host state was destroyed. Settle:

- `absent` **in a session** is non-benign and must be reported as a read failure, not as *"nothing is
  registered on this machine yet"* (whose remedy — *"run cco on your host to populate it"* — is false
  where it is printed: that is where the index came from).
- `stale` does not cover it: that arm was designed against the pre-S1 **file** bind; S1's directory
  bind makes a host-side `mv` present as plain `absent`.
- ⚠ **This is also the default state of every session on native Linux** (consolidated review §5:
  0700 host buckets, `cco-svc` uid 900, so `[[ -e ]]` fails on the parent). The fix converts Linux
  from *silently wrong* to *honestly refusing* — the precondition for stating a verified platform.
- Decide what `[unresolved]` means, and give the *"I could not read the index"* case its own
  rendering. A card that badges bound, readable mounts `[unresolved]` is worse than a degraded
  answer: it is a fabricated one.

**Also record D-V31-2's amendment**: INV-S3b's text in `lib/store.sh`'s header restated as
*pre-flight-vs-write × session-vs-host*, without the bucket example that has now been misread three
times.

### 4.2 Exit criteria

ADR written, alternatives and rejected options recorded, forward-annotations identified — and
**approved by the maintainer**. No implementation. The next two sessions consume it.

---

## 5. S3 — index-health session/host axis (**R-C** 🔴) · S4 — INV-AVAIL sweep (**R-A**, **R-B** 🔴)

Both implement S2's ADR. Kept as separate sessions because their blast radii differ: S3 is one file
and one taxonomy; S4 is a sweep across a verb family plus a lint.

### 5.1 S3 work items

- The taxonomy gains the session/host axis; `absent`-in-session becomes a reported read failure with
  a remedy that is true where it is printed.
- The `[unresolved]` conflation in `cmd-project-query.sh` is split: *not bound* and *index unreadable*
  render differently.
- Regression test reproducing §10.9d (index moved aside under a live session) — per
  the project `testing.md` rule (pack `core-dev-framework`), every fixed bug gets one.
- **Container probe** (Rule 1): after `cco build`, move `~/.local/state/cco/shared/index` aside from
  the host with a session live, re-run `cco path list` / `cco list` / `cco list projects` /
  `cco project show <p>`, confirm each reports a read failure, then restore and confirm recovery.
  ⚠ The path is `state/cco/`**`shared/`**`index` — the pre-S1 `state/cco/index` no longer exists and a
  copy-paste of the older command moves nothing and produces a **false pass**.

### 5.2 S4 work items

- Route every availability/widening answer through the single owner. Known sites:
  `cmd-project-query.sh:249-253` (the two-way `[[ -d probe ]]` test), `access-scope.sh:688` and
  `:785` (the `read-global`-for-a-project string), the `project coords` lane (scope-blind, exit 0
  where its siblings are exit 2, and it silently discards an argument it does not take),
  `cmd-pack.sh`'s validate remedy (no host qualifier).
  **Treat that list as a lower bound** — S9's lesson from cycle-1.1 was that a named file list always
  is. Enumerate by grepping the reserved strings, do not work from this list alone.
- **R-B**, and read its diagnosis carefully: the session report says packs are not wired into the
  scope layer; that is **wrong**. `cmd-pack.sh:116` does call `_env_note_hidden pack` and `:134`
  flushes. The real cause is that at `G=none` `~/.cco` is not mounted, so the enumeration loop never
  iterates and there is nothing to count. **You cannot count what you cannot enumerate** — the count
  must come from the elevated side, not from a mounted directory.
- **D-V31-3**: `cco project show` badges a config-editor target's dropped `extra_mounts`
  `[not mounted in this session]`. The managed rule stays as defense-in-depth.
- The **CLASS lint**, modelled on INV-S6's: fail the suite when a file outside `lib/access-scope.sh`
  either tests a member/mount/project path for existence in order to render availability, or emits
  any reserved string (`[missing]`, `[unresolved]`, `not mounted in this session`,
  `not available at this access scope`, `cco resolve`) outside the sanctioned builder.

---

## 6. S5 — two small classes (**R-E**, **R-G**)

Independent of everything else; one session covers both.

### 6.1 INV-YAML (**R-E**) — config-structure corruption

`_yml_append_coord` (`cmd-project-add.sh:70-75`) ends a section at *"the first top-level line that is
not a comment"*, so a comment block does not close the section and the insertion slides **past** it,
landing after the next section's header. Observed on the maintainer's `cave-ensemble`.

**Rule**: buffer the trailing run of top-level comment and blank lines; on the next top-level key,
emit before the buffered run, then flush. Indented commented examples (`  # - name: my-repo`) stay
inside the section — correct, the new entry lands after them.

**Surface**: one function, four verbs — `cco project add {repo,mount,llms,pack}` (`:203`), `cco init`
(`cmd-init.sh:390`), `cco join` (`cmd-join.sh:164`). The same `/^[^ #]/` idiom is also in
`lib/index.sh` (harmless there — a generated file with no comments), which is exactly why this lands
as one spelling plus a lint rather than a local patch.

**Test**: golden-file round trip against the shipped `templates/project/base/project.yml` with its
full comment furniture — the only form that catches placement, since a YAML parse would call every
variant equivalent.

> **Landed 2026-07-29** (`fix/cycle-1.2/s5-inv-yaml`, commit `71ee8e7`). Three notes.
>
> - **The scale of the defect on a scaffolded project**, measured rather than assumed: on the shipped
>   base template a second `cco project add repo` put its entry at **line 114**, 68 lines below
>   `repos:` (line 46) and immediately above `docker:` — because `extra_mounts`, `packs`, `llms`,
>   `github` and `browser` all ship commented out, so `docker:` is the first top-level *key* after
>   `repos:`. The golden fixture is `tests/golden/project-add-base-template.yml`.
> - **The lint's class is INSERTION, not the raw idiom.** `/^[^ #]/` occurs ~40 times across `lib/`,
>   and all but a handful are READERS. For a reader the rule is unobservable — a top-level comment run
>   holds no `  - name:` line, so treating it as inside the section reads the same set. The flagged
>   shape is therefore an awk section-end rule that *emits* at the boundary **and does not `exit`
>   there*; the `exit` clause is what separates a rewriter (must copy the rest of the file) from a
>   parser that has found its answer. A lint over every reader would be ~40 lines of noise on day one,
>   and noise gets silenced rather than heeded.
> - **`lib/index.sh` is allowlisted as the runbook says — and so are `lib/tags.sh` and
>   `lib/migrate.sh`**, which the runbook did not name. `tags.sh` is the same case as `index.sh`
>   (generated DATA registry, no comments). `migrate.sh` is **not clean**: its `llms` url-recovery
>   rewriter (`:773`) drops top-level comments inside the block outright (`inblk { next }`) — a
>   *different* defect from the misplacement INV-YAML names, in a one-shot migration. It is
>   allowlisted **with that reason recorded in the lint** rather than silently, and reported to the
>   maintainer instead of being fixed inside S5's scope.

### 6.2 EXIT-trap sentinel (**R-G**)

`bin/cco:8`'s trap fires unless `_cco_completed=true` (`:534,541,542,568,711`). The group-help paths
of `cco project` and `cco pack` exit without setting it, so a **successful** run prints
`✗ cco exited unexpectedly (exit 0)`. **Arm 2 is why this is in-cycle and not deferred**: it also
fires on the **host**, appended to a well-formed INV-2 refusal — the default path a user hits when
mistyping `--cco-access`. After S2 taught this codebase that a `✓` must not survive a failure, an `✗`
surviving a correct refusal is the same defect read backwards, and it masks real crashes.

Fix the sentinel discipline, then add the lint that no early exit path skips it.

> **Landed 2026-07-29** (`fix/cycle-1.2/s5-inv-yaml`, commit `e468b01`). Two notes.
>
> - **The discipline is one primitive, not a patch per site.** `_cco_exit <code>` joins `die` (1) and
>   `refuse` (2) in `lib/colors.sh`, and every raw shell `exit` outside those three is gone — the two
>   group-help arms, the five that already set the sentinel inline (a spelling the lint cannot verify),
>   and the **eleven** `|| exit $?` propagation sites in `cmd-start.sh`. Arm 2's mechanism is not
>   specific to `--cco-access`: the *claude*-access resolver at `:395-399` has the identical shape, so
>   the fix covers both resolvers.
> - **Only shell exits count.** The ~70 `exit` tokens in `lib/` are almost all awk program text, which
>   terminates awk, not cco. The lint strips quoted regions, comments and heredoc bodies before
>   matching. Four hazards each produced a false positive while it was written and are handled
>   explicitly: the close-literal-reopen quote token (`llms.sh`, `paths.sh`), an apostrophe in a prose
>   comment, a heredoc body (`cco update --help` prints the literal text *"(… exit 0)"*), and a
>   heredoc delimiter that is itself quoted. The quote character is passed via `awk -v` because an
>   `"\x27"` escape is a gawk extension that would silently not fire on the BSD awk this project
>   targets.

---

## 7. S6 — close-out

- **§10.9e / E6B-04** — the pack-rename fan-out scratch procedure, **never executed in any round**.
  ⚠ Clear the stale `scratch-pack` and the `scratch-a`/`scratch-b` projects first, or the fan-out
  result is ambiguous to read.
- **Host cleanup** (`remote remove` is host-only by design):
  `cco remote remove probe-2 && cco remote remove x && cco remote remove probe-3 && cco remote remove probe-3b`
- **README platform statement** — `README.md:59` and `README.md:220` contradict each other on Linux
  support; the table is stale. Correct it before the release states a platform (roadmap step 4).
- **Handoff corrections** for the next review round: W1-05 (§3 item 7 is a `G=rw` claim; scope it
  there) and W2-07 (V5b's prescribed launch is refused by INV-2 — reach `config_editor_mode=global`
  by invoking `./bin/cco` by absolute path from **outside** any configured repo). Drop a
  `HOST-provenance.txt` beside the session reports.
- **Acceptance log** — paste each container probe's output here, per Rule 1.

### Acceptance log

#### S1 container probe — 2026-07-28

Run in a **default** session on a real container. Provenance `cco whoami` →
`image built from: fix/release/cycle-1.2@9ee07c2`; the `access: {claude: all}` block was
**commented out** in `.cco/project.yml` first, so the session resolved `Cp=ro` — without that, the
R-F arm proves nothing.

```
1. R-D — ownership          drwxr-xr-x claude claude  /home/claude/.claude/projects   (was root:root)
2. R-D — the actual symptom mkdir  ~/.claude/projects/-workspace-claude-orchestrator  → OK
3. R-D, 2nd instance        drwxr-xr-x claude claude  ~/.cco  and  ~/.cco/packs — both writable
4. R-F — the save target    …/state/cco/projects/<id>/workflows  /workspace/.claude/workflows  rw
5. B2 parent                …/cache/cco/projects/<id>/claude-view  /workspace/.claude  ro
6. D5 — projects TREE       …/session/claude-state  /home/claude/.claude/projects        rw
   memory as grandchild     …/session/memory        …/projects/-workspace/memory         rw
7. D6 — self-heal on REAL data: 91 transcripts + memory now under -workspace/,
   0 files stranded at the old depth, memory readable.
```

**⚠ One arm landed AFTER this probe.** `/review-implementation` found that under `Cp=rw` *and*
composing, a saved workflow went into the CACHE view and was destroyed by the next start's `rm -rf`;
the fix (`aa97b3b`) materialises the committed `workflows/` directory instead. The probe above was run
at `Cp=ro`, so **none of its assertions are invalidated** — that lane's code paths are untouched — but
the new arm is unprobed. It needs one `cco build` and a session with `--claude-access all` on a
project that adopts a pack: expect `<repo>/.cco/claude/workflows` bound rw at
`/workspace/.claude/workflows`, and the saved file still present after a restart.

**What this probe did NOT observe** — stated so the next round does not read it as more than it is:

- **Cross-restart persistence of a non-`-workspace` key.** The mount shape implies it (everything
  under `projects/` is inside the STATE bind), but no key other than `-workspace` had yet been
  written by a real session at probe time.
- **D7's "composes with no packs at all".** This project references `core-dev-framework`, so the view
  would have been composed regardless; only `test_claude_view_composed_for_the_write_floor_without_packs`
  covers that arm.
- **A real subagent from a repo cwd.** Step 2 reproduces the mechanical core (the `mkdir` Claude Code
  performs), not the end-to-end write.

#### S1 container probe — the `Cp=rw` arm — 2026-07-28

The arm the first probe could not reach, plus two of the three items it did not observe. Provenance
`cco whoami` → `image built from: fix/release/cycle-1.2@c40e556` (branch tip). Here the
`access: {claude: all}` block was deliberately **left in place**: at `Cp=rw` it is not the mask, it is
the *subject* — the only configuration in which this code path runs. The project adopts
`core-dev-framework`, so the view **is** composed, which is the other half of the defect's condition.

Before the restart:

```
1. save target         …/claude-orchestrator/.cco/claude/workflows  /workspace/.claude/workflows  rw
                       the COMMITTED tree, no `ro,` flag — not the CACHE view, not the STATE overlay
2. repo dir            drwxr-xr-x claude claude  <repo>/.cco/claude/workflows
3. marker + git        echo '// probe' > /workspace/.claude/workflows/probe.js
                       md5 848a03c7ccd2da1a46a36303a5ff64c0 · git: `?? .cco/claude/workflows/`
                       — i.e. "shared via git" in changelog #52 is literally what git reports
4. a non-`-workspace` key written by a REAL session (`claude -p`, cwd /workspace/claude-orchestrator):
                       ~/.claude/projects/-workspace-claude-orchestrator/b95c09bd-….jsonl  22569 B
```

After the restart:

```
5. marker SURVIVED     /workspace/.claude/workflows/probe.js  md5 848a03c7… unchanged
6. and the test is NOT vacuous — the view really was rebuilt at this start:
                       /workspace/.claude        mtime 16:01:23  (the restart)
                       …/workflows/probe.js      mtime 15:57:55  (pre-restart, preserved)
                       parent mount id 456 → 417 (new container)
                       `rm -rf "$_claude_view"`  lib/cmd-start.sh:1905
                       the destructive step ran and the save outlived it, because after aa97b3b the
                       save target is the committed tree instead of the view
7. transcript SURVIVED …/-workspace-claude-orchestrator/b95c09bd-….jsonl  22569 B, unchanged
```

Marker deleted afterwards; the tree is clean.

**Two of the three "not observed" items above are closed by this run** — cross-restart persistence of
a non-`-workspace` key, and a real session writing from a repo cwd (step 4 is the end-to-end write,
not the `mkdir` the first probe reproduced). **D7's "composes with no packs at all" stays open and is
host-side**: it needs a project referencing no pack, so it is unreachable from a session where
`cco start` is refused. Only `test_claude_view_composed_for_the_write_floor_without_packs` covers it.

📝 Observed en passant, then **corrected the same day** — the first wording of this note claimed more
than the run showed, and is restated here rather than left standing. What was actually observed: an
**empty** `memory/` directory appeared under the new key and was gone again minutes later. Nothing was
ever written to it, so the run demonstrates no memory split; the first note inferred one and recorded
the inference as an observation.

The mechanism, checked against the official docs afterwards, is also not what that note implied: project
auto-memory is **not** per-agent and not per-cwd — it lives at `~/.claude/projects/<project>/memory/`
with `<project>` derived from the **git repository**. A cco session splits because `/workspace` is not a
git repo (so the project root is used → `-workspace`) while `/workspace/<repo>` is (→ its own key). A
subagent inherits the session's cwd and therefore shares the main session's memory. Both this and a
second, unrelated hole — eight agents declare `memory: user`, whose target `~/.claude/agent-memory/` is
bound nowhere and dies with the `--rm` container — are filed together as
**[FI-39](../../../../roadmap-backlog.md)**, to be settled in one ADR **after** this cycle.

#### S5 — the Rule-1 ruling, and what closes L4/L5 in-session — 2026-07-29

**Maintainer ruling, 2026-07-29 (recorded, not re-litigated): the golden-file round trip IS
sufficient acceptance for L4.** S5 closes **in-session**, with no host-side probe; §1's Rule 1 named
S5 and has been corrected, as has the roadmap's lane-L4 warning. The rule's own criterion is what
settles it — S5's surface is neither mount-time nor container-context. `_yml_append_coord` rewrites a
file the suite can hand it, and the EXIT trap's misfire is observable from any `bin/cco` invocation;
both defects reproduce identically on host and in session, so a container adds no observation the
hermetic lane lacks. The design input agreed from the start: `invariant-gap-audit.md` §5 names items
**2, 3 and 4** as invisible to the suite and deliberately excludes item 5 (INV-YAML), and the session
table below already carried `n/a` in S5's container-probe column. Rule 1's list was the outlier.

**What was measured instead** (branch `fix/cycle-1.2/s5-inv-yaml`, three commits `71ee8e7`,
`e468b01`, `a167fd6`):

```
1. R-E, the defect reproduced   two `cco project add repo` on the shipped base template:
                                pre-fix `beta` landed at line 114 — past the
                                `# ── Extra mounts` banner (line 54), immediately above
                                `docker:` — 68 lines below its own `repos:` (line 46)
2. R-E, the fix                 same run, post-fix: line 53, inside `repos:`, after the
                                indented commented examples. Golden fixture:
                                tests/golden/project-add-base-template.yml
3. R-E regression proof         3 of the 5 new tests FAIL on the pre-fix code:
                                golden round trip · placement-by-rule · the EOF arm
4. R-G arm 1                    pre-fix `cco project` → help, exit 0, then
                                "✗ cco exited unexpectedly (exit 0)". Post-fix: gone
5. R-G arm 2                    pre-fix `--cco-access read-projekt` → the correct refusal
                                WITH the crash line appended. Post-fix: refusal only
6. R-G regression proof         both arm tests FAIL on the pre-fix tree
7. lint discrimination          against a STAGED copy of the real tree with only the fixed
                                sources reverted, not a synthetic fixture:
                                INV-EXIT  → 18 sites: bin/cco:534,541,542,569,631,677,712
                                            + cmd-start.sh:360-365,395-399
                                            (631/677 = arm 1; the eleven = arm 2)
                                INV-YAML  → 1 site: cmd-project-add.sh:72, the defect line
                                Both lints also carry in-test plants in BOTH directions
                                (must fire / must NOT fire), so neither can go inert.
8. no lint dead zone            a raw `exit 0` appended to EVERY scanned file (bin/cco,
                                lib/*.sh, migrations/*/*.sh) is detected in all of them —
                                the quote/comment/heredoc stripper never desyncs
```

#### S4 container probe — **FAILED, then fixed** — 2026-07-30

The first of the post-build probes, and it did what Rule 1 says a probe is for: it failed on a lane the
suite had certified green. Provenance `cco whoami` → `image built from: fix/release/cycle-1.2@e27ad6e`
(the branch tip; `/opt/cco/lib` verified **byte-identical** to the working tree, so the probe is
observing this block's code and not an older image). Session at the **default** `read-project`, mask
`access: {claude: all}` in place — irrelevant to this lane, which is a `cco_access` axis, but stated
because §7 requires it.

```
1. the signal EXISTS       CCO_STORE_TOTALS=pack=6,template=0,llms=2,remote=0
                           (in the agent's env, and in /etc/cco/session-access)
2. and it does NOTHING     cco list packs  →  1 row (core-dev-framework), exit 0
                           stderr: <empty>          ← R-B, verbatim: 5 packs unaccounted for
3. cco list (unified)      note: 9 projects, 1 template hidden by access scope
                           — per-row notes only; NO pack count, though 6-1 are unreachable
4. A/B, same session       CCO_STORE_ELEVATED=1 cco list packs   (skips the trampoline)
                           stderr: note: 5 packs, 2 llms hidden by access scope …
                           → the supplement is CORRECT and REACHABLE; what is missing is the input
5. root cause              config/cco-svc-helper.c ALLOWED_KEYS[] does not list CCO_STORE_TOTALS
                           (`strings /usr/local/bin/cco-svc-helper` confirms it in the BAKED binary)
                           while cmd-start.sh:1837 writes it, under a comment that reads
                           "Keys mirror the helper's whitelist"
```

**Mechanism.** Every store-touching read verb `exec`s the setuid helper, which rebuilds the child
environment **from scratch** (ADR-0047 R2) and copies over whitelisted descriptor keys only. An
un-whitelisted key is dropped in **silence** — no error, no exit code — so `_env_apply_store_supplement`
returned at its `CCO_STORE_TOTALS` guard on every real invocation. **D5 shipped inert**, which means
**R-B shipped unfixed**: the finding S4 was accepted for.

**Why the suite could not see it, and now can.** `tests/test_access_scope.sh:952+` exercises the
supplement by exporting the signal and calling the consumer in-process — a path that never crosses the
boundary. The gap is now a static lint over the two source files:
**INV-DESC** (`test_invariant_descriptor_keys_whitelisted`). It reports `CCO_STORE_TOTALS` on the
pre-fix tree and is clean on the fixed one, so its discrimination is proved against the **real** defect,
not only against a plant.

**The same omission had TWO more instances, found by asking where else this signal family is
registered.** A descriptor key is not one fact in one file — it is a key set that **three** registries
must agree on, and S4 updated one of them:

| Registry | What it is for | State before |
|---|---|---|
| `config/cco-svc-helper.c` `ALLOWED_KEYS[]` | what may cross the privilege boundary | ❌ missing → **D5 inert** |
| `bin/test`'s ambient-env `unset` | make a self-dev run behave like a host run | ❌ missing → 3 spurious failures |
| `tests/helpers.sh` `_lane_operator_exports` | the per-lane sanitiser, pinned deterministically | ❌ missing → latent, same leak |

The `bin/test` gap is the one that had already cost a measurement: the real value leaked in and added a
hidden-count supplement three notice tests never asked for
(`test_as_hidden_notice_counts_and_stderr`, `test_as_hidden_notice_projects_only_leads_with_read_all`,
`test_hidden_notice_unchanged`) — **10 failures in-session where 7 were documented**, and the three
extra were indistinguishable from the host-only set until the names were diffed. The
`tests/helpers.sh` gap had not fired yet only because `bin/test` unsets globally — which is precisely
what that file's own comment (c) says a lane must never rely on.

All three are now one lint: **INV-DESC**, two test functions, each arm proved against the **real**
pre-fix file rather than only a plant (`CCO_STORE_TOTALS` is reported for all three; clean after).

⚠ **Carry-forward, two lessons.** (i) The count-vs-name discipline §2 states for the host-only 7 applies
to *any* in-session figure: a count alone reads a real regression as environmental noise. (ii) When a
fix adds a member to an existing family, the question is not "is the new member correct" but **"how many
registries name this family"** — S9's lower-bound lesson from cycle-1.1, one level up: it holds for
registries as well as for call sites.

**Ratified and recorded**: ADR-0056's annotation section (D5 entry, 2026-07-30) + changelog **59**.

#### S4 container probe — round 2, after the rebuild — 2026-07-30

The maintainer rebuilt and restarted. ⚠ **Provenance still reads `…@e27ad6e`** because the fix was
uncommitted at build time — `/opt/cco/BUILD` records a git ref, and a docker build takes the working
TREE. So the ref was not evidence here and the binary was checked instead:
`strings /usr/local/bin/cco-svc-helper | grep CCO_STORE_TOTALS` → present. **Check the artefact, not the
provenance line, whenever the tree is dirty.**

```
1. THE LANE IS FIXED       cco list packs → 1 row + note: 5 packs … hidden   ← was silence
2. and the unified view    cco list       → note: 9 projects, 5 packs, 1 template hidden
3. ⚠ BUT A FALSE CLAUSE    cco list llms  → note: 6 packs hidden        (llms are all shown)
                           cco list packs → note: 5 packs, 2 llms hidden (those 2 are shown)
                           cco path list  → note: 32 paths, 6 packs, 2 llms hidden
                           cco project show → store counts, on a verb that lists no store
```

**The second defect, and it was D5's own.** `_env_apply_store_supplement` looped over **every** store
kind on **every** flush, so each verb's notice carried counts for kinds it had never enumerated. Two
things made it unmistakable rather than cosmetic: the claims were **false where printed** (`cco list
llms` shows both llms and called them hidden) — the exact R-A class ADR-0056 exists to end — and the
**same session answered 6 or 5 to the same question** depending on the verb, because the count is
total-minus-enumerated and a verb listing llms enumerates no packs. It had never been observable before,
for the simple reason that until round 1 the supplement never ran at all.

**Ratified 2026-07-30 — a notice is per-invocation, not per-session.** A verb declares the kinds it
enumerates exhaustively (`_env_store_subject`, in the owner); only those are supplemented; **not
declaring means no supplement**, so an omission is honest silence instead of a fabricated count — the
inverse of the shipped default. Four sites declare, and they are exactly the four the new lint names on
the pre-fix tree: `cmd_pack_list`, `cmd_pack_validate`'s `--all` arm, `_llms_list`, and `cmd_list`
(all kinds when unified, the requested kind when scoped).

*Rejected*: supplement only kinds with `seen>0` — needs no declaration anywhere, but goes silent exactly
when nothing was enumerable (a project referencing no packs, an absent mount), which is R-B returning
through the back door.

**Cover**: three unit tests for the scoping rule (two of them fail on the unscoped code — verified by
removing the two guard lines and re-running), the five pre-existing D5 tests updated to declare a
subject (two would otherwise have passed **vacuously**, asserting silence that now has a second possible
cause), and **INV-AVAIL/D5** — `test_invariant_store_subject_declared_where_counted`, pairing every
`_env_note_seen` with an `_env_store_subject` in the same function. On the pre-fix tree it names all
four enumerators; clean after.

#### S4 container probe — round 3 — ✅ **PASSED** — 2026-07-30

Provenance `cco whoami` → `image built from: fix/release/cycle-1.2@d01d42a`, and this time the
**artefact agrees with the line**: `/opt/cco/lib` byte-identical to the working tree, `_env_store_subject`
present in all four baked files, `CCO_STORE_TOTALS` in the baked helper's strings. Default
`read-project` session, mask `access: {claude: all}` in place (irrelevant to this axis, stated per §7).

```
1. cco list packs        1 row  +  note: 5 packs hidden by access scope (…) — start a
                                  read-global session or run cco on your host.
                         → the count is right AND there is no llms clause
2. cco list llms         both rows, stderr EMPTY
                         → the verb that showed every llms no longer calls any of them hidden
3. cco list              4 rows +  note: 9 projects, 5 packs, 1 template hidden …
                         → the unified index still speaks for every kind, and the pack number is
                           5 (six minus the one bound), not the 6 the unscoped code produced
4. cco path list         2 rows +  note: 32 paths hidden … (other projects need Po≥ro)
                         → paths only; no store counts on a verb that lists no store
5. cco pack validate     ✓ core-dev-framework is valid + note: 5 packs hidden …
   (the --all arm)       → the fourth declared site, pack only
6. cco project show      stderr EMPTY
   (control)             → no store claim from a verb that enumerates no store
```

Both defects are closed on evidence: **row 1 is R-B fixed** (it was silence in round 1), and **rows 2, 4
and 6 are the false-clause defect fixed** (they each carried a fabricated cross-kind count in round 2).
Every number matches the behaviour ratified before the fix was written, so this is a confirmation, not a
re-specification.

**L1's Rule-1 evidence is complete.** What remains for the lane is the block's single human gate.

📝 Also settled the same day: the stray OAuth authorize URL at `.cco/project.yml:37` (pasted by
accident, uncommented, inside the pack-schema comment block) was removed host-side — 0 occurrences, and
the file's residual diff is exactly the intended `access:` block, the `8081→8082` port change and the
`packs:` entry.

#### S3 container probe — ✅ **PASSED, both arms** — 2026-07-30

A **split** gate — the shape §5.1 prescribes — run by maintainer and session together: the maintainer moved
`~/.local/state/cco/shared/index` aside from the host **with this session live**; every observation
below is from inside that session. Provenance `cco whoami` →
`image built from: fix/release/cycle-1.2@d01d42a`, `/opt/cco/lib` byte-identical to the working tree.
Default `read-project` session; the `access: {claude: all}` mask was in place and is irrelevant to this
axis (stated per §7's rule).

```
$ cco whoami                            rc=0   ← renders the session's own state, reads no index
$ cco path list                         rc=1
$ cco list                              rc=1
$ cco list projects                     rc=1
$ cco project show claude-orchestrator  rc=1
$ cco project validate --all            rc=1

all five failing verbs, identical text:
  ✗ the cco index at /var/lib/cco-internal/state/cco/shared/index cannot be read: the file is
    gone. This session was LAUNCHED from the index, so it was readable when the session started
    and is no longer — the bind has been severed, or the host-side state was removed. No entries
    were listed — this is NOT an empty index. Run cco on your host to inspect or rebuild it.
```

Arm by arm, what this actually proves:

- **The session axis, not merely the cause.** The discriminator in the text is *"this session was
  LAUNCHED from the index"* — the very same missing file is a legitimately benign `absent` on the host.
  That is ADR-0056's axis, observed rather than inferred.
- **W4-F06's benign sentence is unreachable from a session.** Pre-S3 it is still there to compare
  against: `git show develop:lib/index.sh:189` → *"the path index is empty — nothing is registered on
  this machine yet"*. §10.9d's **rc=0 is now an rc=1 refusal**, and the new text denies the reading
  explicitly (*"this is NOT an empty index"*).
- **The remedy is true where it is printed.** *"Run cco on your host"* names the only place a severed
  bind can be repaired — and deliberately not a verb the session could run.
- **`cco whoami` at rc=0 is correct, not a leak.** It reports the resolved session descriptor, which
  crossed the ADR-0047 boundary at start-up and needs no index read. A session must still be able to
  say what it is while its store is unreachable.

**The recovery arm — run immediately after, same session, index restored host-side:**

```
$ cco path list                         rc=0  2 rows + note: 33 paths hidden …
$ cco list                              rc=0  4 rows + note: 9 projects, 5 packs, 1 template hidden …
$ cco list projects                     rc=0  1 row  + note: 9 projects hidden …
$ cco project show claude-orchestrator  rc=0  full render (repos/mounts/packs/docker/status)
$ cco project validate --all            rc=0  [claude-orchestrator] + note: 9 projects hidden …
```

Recovery is **not** merely "the error stopped": every verb is back to its **fully scoped** behaviour,
with the per-invocation notices of S4's round 3 intact and the same numbers — 9 projects / 5 packs /
1 template, `list llms` still unmentioned by the verbs that do not enumerate it. So the guard added in
front of these enumerators (`cmd-project-validate.sh:308`, `_index_assert_readable` — *"classify BEFORE
the loop, so a read failure is never rendered as 'nothing to validate'"*) is proven in **both**
directions: it refuses when the read fails and gets out of the way when it succeeds. A guard only ever
tested on the failing side is how a lane ships fail-closed *and* unusable.

📝 `path list` reports **33** paths hidden where round 3 reported 32. The delta is host-side registration
between the two probes (the count is total−enumerated, so it tracks the real store); the visible rows are
the same 2. Recorded rather than smoothed over — an unexplained count is how the 10-vs-7 episode started.

⚠ `project validate --all` printing only `[claude-orchestrator]` and the notice is **correct**, not a
truncation: `_pv_validate_unit` is quiet on a unit with no findings when `--verbose` is absent.

📝 **Observation for the CLI-docs audit (roadmap step 3), not a defect claim.** The message names the
**internal** path `/var/lib/cco-internal/state/cco/shared/index` — the agent's side of the bind, which
is accurate — while its remedy is host-side, and this session has `show_host_paths: true`. A reader who
follows the remedy cannot act on the path they were given. Carry it into step 3's pass over refusal
wording; changing user-facing text is a human gate, not a sweep.

| Session | Suite | Container probe | Date |
|---|---|---|---|
| baseline | ⚠️ **1533/7 — measured under the mask** (see note) | n/a | 2026-07-28 |
| S1 | ✅ **1551/9** unmasked, total 1560 (after the review fixes; was 1547/9 of 1556 before) | ✅ **passed** — the `:ro` lane (first block) *and* the `Cp=rw` arm (second block). Remaining gap: D7 without packs, host-side | 2026-07-28 |

> ⚠ **Correction — both earlier numbers were taken with `access: {claude: all}` active.** Re-run in a
> real default session (`Cr=ro`) the suite is **1547/9, total 1556** — the same 1556 tests, with two
> more failing: `test_update_new_file_added` and `test_update_dry_run`, which write fixtures into
> `defaults/global/.claude/rules/`. That path is tracked *and* mounted `:ro` whenever `Cr=ro`, so they
> pass only when the `.claude` trees are writable. Nothing was lost and no test regressed — the delta
> is environmental, the same category as the seven host-only ones.
>
> The point worth carrying forward is the **third** occurrence of one pattern in this cycle: the
> plan already warns that the mask hides R-F, and it hid a suite number too. **Any figure recorded
> from a self-dev session must state whether the block was in place.** These two are *not* to be
> chased inside S1 — the same rule as the seven.
| S3 | ✅ **1614/7 of 1621** (same tree as S4's row — ⚠️ mask ON) | ✅ **PASSED, both arms** — run as a *split* gate (host `mv`, in-session observations). Severed: all five read verbs refuse at **rc=1** with the session-axis cause, and §10.9d's benign rc=0 sentence is unreachable. Restored: all five back at **rc=0** with their fully scoped notices and the same counts as S4's round 3 — the entry guard proven in both directions | 2026-07-30 |
| S4 | ✅ **1614/7 of 1621** — ⚠️ **measured with the mask ON**. Closes on the baseline with no slack: 1608/7 of 1615 **+6** (2 INV-DESC · 1 INV-AVAIL/D5 · 3 scoping). The 7 are the known host-only set, name for name | ✅ **PASSED at round 3** — ⚠️ it took three rounds and two builds: **round 1 FAILED** (D5 inert, the key never crossed the boundary) → fixed; **round 2** showed the lane fixed *and* exposed a second defect (a fabricated cross-kind clause in every notice) → fixed; **round 3 green on all six arms**, every number matching the behaviour ratified before the fix was written | 2026-07-30 |
| S5 | ✅ **1562/7, total 1569** — ⚠️ **measured with the mask ON** (`access: {claude: all}` active for this session). The 7 are the known host-only set, unchanged: the six `test_as_*` plus `test_paths_symlink_safe_tool_root`. Baseline for the same mask state was **1553/7 of 1560**; the delta is exactly the **+9** tests S5 adds | n/a — see the ruling above | 2026-07-29 |

---

## 8. Out-of-session gates → [`08-gates-to-release.md`](08-gates-to-release.md)

The gates that remain — and the whole path from here to the published release — live in their own
**operational runbook**, [`08-gates-to-release.md`](08-gates-to-release.md). It is the file to keep open
at the terminal; this plan stays the *design + evidence* document, and every probe result still goes into
**§7** above.

Moved there rather than restated here, so there is one home for a command and one place to fix it: a gate
whose command has to be reassembled from three documents is how a copy-paste false pass happens — S3's own
trap (the pre-S1 `state/cco/index` spelling, which moves nothing) is exactly that failure.

| Gate | What | Where it runs | State |
|---|---|---|---|
| **G0** | `git push origin develop fix/release/cycle-1.2` | host | ✅ done 2026-07-30 |
| **G1** | S6's host half (**E6B-04**) + **D7**'s residual — one scratch setup serves both | host + an `edit-all` session | ◀ current |
| **G2** | CLI-surface documentation audit (roadmap step 3) | in-session, **sequential after G1** | owed |
| **G3** | the block's **single human gate** | maintainer | owed |
| **G4** | merge → `develop` + the merge tree-hash check | host | owed |
| **G5** | verification **on `develop`** (unmasked suite · macOS host suite · `cco build` + smoke) | host | owed |
| **G6** | `develop → main` + `scripts/release.sh` | host | owed |

Two probes that used to live in this section are **done** and recorded in §7: S3's severed-index arm plus
its recovery (a **split** gate — host `mv`, in-session observations), and S4's round 3.

---

## 9. What this cycle does **not** do

- **The Linux write path.** Criterion F stays signed off as macOS-verified. The fix is an ADR, not a
  patch — the conflict is structural (the agent's uid must equal the host user's or it cannot write
  the repos; the store content is owned by that same uid; the elevated identity must **not** be that
  uid). Cycle-2. What *this* cycle does is make Linux fail **honestly** (S3).
- **FI-33…FI-36**, and everything v3 classified as cycle-2.
- **The pre-existing host-only suite failures** (the 7). See the *suite-7-host-only* memory note —
  two refuted hypotheses are recorded there; do not retry them.
