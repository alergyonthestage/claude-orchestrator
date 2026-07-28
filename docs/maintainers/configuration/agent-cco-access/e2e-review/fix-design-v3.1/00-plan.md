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

**Rule 1 — suite-green is not acceptance for S1, S3 and S5.** The hermetic lane cannot observe
mount-time or container-context reality; that is RC-17, and this cycle contains its **fourth**
recurrence. Those three sessions are accepted on a **probe in a real container after `cco build`**,
pasted into §7's acceptance log. If you find yourself writing *"tests pass"* as the evidence for a
mount or context behaviour, stop — you are about to repeat the exact mistake the review names.

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
| **S1** | Claude Code runtime paths | L3 (**R-D** + **R-F**) | ADR in `environment/decisions/`, Dockerfile + mount-generation fix, INV-MP lint, container probe | 🟢 code + docs landed ([ADR-0055](../../../../environment/decisions/0055-claude-runtime-state-and-mountpoint-ancestry.md), 4 commits) — **awaiting `cco build` + the §3.4 container probe, which is what accepts it** |
| **S2** | The availability model — **design only** | L1 + L2 (**R-A** + **R-C**) | one ADR in `configuration/agent-cco-access/decisions/`; **no code** | ⬜ not started |
| **S3** | Index-health session/host axis | L2 (**R-C** 🔴) | `index.sh` taxonomy + the `[unresolved]` conflation, container probe | ⬜ not started |
| **S4** | INV-AVAIL sweep | L1 (**R-A** 🔴, **R-B** 🔴) | one owner for availability answers + CLASS lint | ⬜ not started |
| **S5** | Two small classes | L4 (**R-E**) + L5 (**R-G**) | INV-YAML + golden-file lint; EXIT-trap sentinel + lint | ⬜ not started |
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

### 6.2 EXIT-trap sentinel (**R-G**)

`bin/cco:8`'s trap fires unless `_cco_completed=true` (`:534,541,542,568,711`). The group-help paths
of `cco project` and `cco pack` exit without setting it, so a **successful** run prints
`✗ cco exited unexpectedly (exit 0)`. **Arm 2 is why this is in-cycle and not deferred**: it also
fires on the **host**, appended to a well-formed INV-2 refusal — the default path a user hits when
mistyping `--cco-access`. After S2 taught this codebase that a `✓` must not survive a failure, an `✗`
surviving a correct refusal is the same defect read backwards, and it masks real crashes.

Fix the sentinel discipline, then add the lint that no early exit path skips it.

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

**What this probe did NOT observe** — stated so the next round does not read it as more than it is:

- **Cross-restart persistence of a non-`-workspace` key.** The mount shape implies it (everything
  under `projects/` is inside the STATE bind), but no key other than `-workspace` had yet been
  written by a real session at probe time.
- **D7's "composes with no packs at all".** This project references `core-dev-framework`, so the view
  would have been composed regardless; only `test_claude_view_composed_for_the_write_floor_without_packs`
  covers that arm.
- **A real subagent from a repo cwd.** Step 2 reproduces the mechanical core (the `mkdir` Claude Code
  performs), not the end-to-end write.

| Session | Suite | Container probe | Date |
|---|---|---|---|
| baseline | ✅ **1533/7** (two identical runs) | n/a | 2026-07-28 |
| S1 | ✅ **1549/7** (+16 new, same 7 host-only) | ✅ **passed** — see below | 2026-07-28 |
| S3 | ⬜ | ⬜ **required** | |
| S4 | ⬜ | ⬜ | |
| S5 | ⬜ | n/a | |

---

## 8. Out-of-session gates (host, in order)

Everything below needs the **host** terminal; a session cannot do any of it.

1. `git push` — `develop` is currently level with `origin/develop`; the cycle branch and every merge
   are pushed from the Mac.
2. `cco build` — **required before S1's, S3's and S4's probes**. `lib/` and `Dockerfile` are baked
   into the image, so their edits are invisible in-session until a rebuild. Record the provenance
   (`cco whoami` → `image built from:`) alongside each probe.
3. Merges into `develop` — per [`.cco/claude/rules/git-workflow.md`](../../../../../../.cco/claude/rules/git-workflow.md),
   and note **FI-20**: merges touching `.cco` are host-only.
4. After the cycle: the **CLI-surface documentation audit** (roadmap step 3), then
   `develop → main` + release (step 4).

---

## 9. What this cycle does **not** do

- **The Linux write path.** Criterion F stays signed off as macOS-verified. The fix is an ADR, not a
  patch — the conflict is structural (the agent's uid must equal the host user's or it cannot write
  the repos; the store content is owned by that same uid; the elevated identity must **not** be that
  uid). Cycle-2. What *this* cycle does is make Linux fail **honestly** (S3).
- **FI-33…FI-36**, and everything v3 classified as cycle-2.
- **The pre-existing host-only suite failures** (the 7). See the *suite-7-host-only* memory note —
  two refuted hypotheses are recorded there; do not retry them.
