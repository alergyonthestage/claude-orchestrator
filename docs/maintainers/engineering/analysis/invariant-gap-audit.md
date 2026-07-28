# The invariant-gap class — why the same defect keeps shipping

> **Raised**: 2026-07-28, consolidating e2e acceptance review **v3.1**
> ([`consolidated-review-v3.1.md`](../../configuration/agent-cco-access/e2e-review/results/consolidated-review-v3.1.md)).
> **Scope**: cross-cutting — the message layer (`lib/access-scope.sh`, the `project` verb family),
> the mount-composition layer (`Dockerfile`, `lib/cmd-start.sh`), and the config-editing layer
> (`lib/cmd-project-add.sh`). **Status**: analysis complete; it is the design input for **cycle-1.2**,
> sequenced in [`../../handoff.md`](../../handoff.md).
>
> Sibling of [`false-success-class-audit.md`](false-success-class-audit.md), and written for the same
> reason: the backlog convention requires re-deriving an item's real boundary before designing the
> fix. Eight v3.1 findings were raised as eight defects. The boundary is **one class in three
> layers**, and the unit of work is not the defect — it is the missing invariant.

## 1. The class

> **A predicate that every call site is free to compute for itself will diverge, and the divergence
> ships.** Where cco has bound a predicate to a single implementation *and enforced that binding with
> a static lint*, it has held. Where it has not, the same defect recurs every cycle, one sibling at a
> time.

The v3.1 symptom vocabulary is narrower than the class: *cco renders "I cannot see X from here" as "X
is not there", and computes the remedy without regard to where the message is printed.* Its mirror
image is in the same round — a **correct** exit rendered as a crash (`bin/cco:8`). Both are the same
absence: no single owner for the predicate.

### Why this codebase is structurally exposed

Three properties compound:

1. **cco is dual-context.** Every verb runs on the host *and* inside a container, where the same
   filesystem question has a different answer. A predicate written once, in the author's context, is
   silently wrong in the other. The `.claude/rules` already say this
   (`design-cli-environment-awareness.md`); nothing enforces it.
2. **The privilege boundary makes existence predicates lie by design.** ADR-0047's opaque store means
   `[[ -d ]]` on a confined path reads **false** for something that exists. INV-S6 states this and a
   CLASS lint enforces it — **for the store layer only**. The same physics apply to any bind whose
   ancestor the agent does not own.
3. **A section boundary, an availability state and a mountpoint ancestry are all "obvious" enough to
   re-derive inline.** They are each three lines. That is exactly why they get re-derived, and why
   the copies drift.

### The empirical case

| Layer | Invariant | Lint | Outcome |
|---|---|---|---|
| store mutations | INV-S1…S6 | `tests/test_invariants.sh` CLASS lint | **held** under `edit-all` probing (v3.1 W2/W3) |
| index writers | INV-IDX | yes | **held** |
| interactivity gate | single-spelling | `test_invariant_tty_gate_single_spelling` | **held** (closed a ~20-site class in one pass) |
| availability vocabulary | — | — | **8 divergent sites** (§2) |
| mountpoint ancestry | INV-MP, scoped to `/workspace/.claude` | — | **third recurrence** (§3) |
| YAML section boundary | — | — | **corrupts user config** (§4) |

The three layers that fail are precisely the three with no invariant. This is not a correlation worth
hedging: the same team, the same cycle discipline and the same review depth produced held invariants
and drifting non-invariants side by side.

---

## 2. Gap A — the availability predicate (**INV-AVAIL**)

### The state of the code

`lib/access-scope.sh` already provides the intended single source: `_env_member_state` /
`_env_project_state` implement D-M2's **three** states (mounted · known-but-not-bound · not
configured), and `access-scope.sh:753-755` carries the comment *"The not-mounted sentence deliberately
never says 'run cco resolve'."* The classifier is correct. **It is simply not the only implementation.**

| Site | What it does instead | Symptom |
|---|---|---|
| `cmd-project-query.sh:249-253` | its own two-way `[[ -d "$_probe" ]]` test | a not-mounted member renders `[missing]` + *"run 'cco resolve <p>'"*, which the same session refuses at exit 2 |
| `access-scope.sh:688` (`_env_require_visible`) | offers `read-global/read-all` for every kind | for a **project**, `read-global` reveals nothing — ADR-0043 defines it as the level that hides other projects |
| `access-scope.sh:785` (`_env_unavailable_warn`) | same string | same |
| the `project coords` lane | no scope consultation at all | answers store-wide from a 1-of-10 view, at exit 0, with no hidden-count notice |
| `cmd-pack.sh` (validate remedy) | prescribes `cco resolve` with no host qualifier | unfollowable in-session |

Two of these are the **unswept siblings of fixes that did land**: B-DF1 corrected *which path*
`project show` probes but left the `else` branch two-way; S8's `221d8fb` corrected the **aggregate**
hidden-count notice (`_env_flush_hidden_notice:632-637`) and left the two **per-resource** call sites.

### Shape of the invariant

> **INV-AVAIL** — no verb computes an availability or scope-widening answer for itself. Every such
> answer is produced by `lib/access-scope.sh`, which owns (a) the three-state classification, (b) the
> sentence, (c) the remedy, and (d) the exit code. A verb may *ask*; it may not *decide*.

Three sub-rules the v3.1 evidence forces:

- **A remedy is a function of the print site.** A sentence emitted in a container may never prescribe
  a verb that is host-only there. Mechanically checkable: the refusal builder knows the context.
- **The widening offered is a function of what is hidden.** Projects-only → `read-all`; store kinds →
  `read-global`; mixed → both, with `read-all` attached to the projects clause. The aggregate notice
  already does this; the per-resource paths must share the implementation, not the intent.
- **The `unknown` arm exists, and is enabled only at read scope `all`** (ratified as **D-V31-1**).
  At `all` nothing can be hidden, so distinguishing costs no opacity; below `all` one non-disclosing
  sentence that **asserts nothing** — *"no project 'X' is available at this access scope"*, never
  *"it exists on this machine"*.

### Shape of the lint

Mirror the INV-S6 CLASS lint: a static scan that fails the suite when a file outside
`lib/access-scope.sh` (a) tests a member/mount/project path for existence in order to render
availability, or (b) emits any of the reserved strings — `[missing]`, `[unresolved]`,
`not mounted in this session`, `not available at this access scope`, `cco resolve` — outside the
sanctioned builder. The tty-gate lint is the closest working precedent: it bans the raw spelling
outright and routes everything through one helper.

---

## 3. Gap B — mountpoint ancestry (**INV-MP**, generalised)

### The state of the code

**ADR-0054 / INV-MP already states the rule**, and solved it host-side for `/workspace/.claude`: a
child bind needs its mountpoint to pre-exist inside the parent, and the runtime creating it through a
`:ro` bind fails (`EROFS`), so cco owns the parent in a CACHE view and re-binds the committed tree
entry by entry.

The **container-side** half of the same physics was never generalised. The Dockerfile documents it
verbatim (lines 119-124):

> *"if the base dir doesn't already exist the container runtime auto-creates it as a root-owned mount
> point — blocking any sibling … from being created by claude"*

…and pre-creates `.local/bin`, `.local/share`, `.local/state`, `.cache` and `.claude` on that
reasoning (`Dockerfile:127-129`). **`.claude/projects` was not added**, and it is exactly where cco
nests a bind (`cmd-start.sh:1793-1796`).

Reproduced live on `develop@8fd479c`, macOS:

```
drwxr-xr-x 3 root root 4096 /home/claude/.claude/projects
touch: cannot touch '/home/claude/.claude/projects/.wprobe': Permission denied
```

Consequence: Claude Code keys its per-project state by cwd (`~/.claude/projects/<key>/`). `-workspace`
is bound and works; **every other key** — a subagent or teammate started from `/workspace/<repo>`, a
worktree session, a background session — needs a `mkdir` in a root-owned directory and gets `EACCES`.
That is the reported failure of agent-team / subagent transcripts.

This is the mechanism's **third** recurrence: v3's STATE bucket (R1), FI-31, now `~/.claude/projects`.
Each time it was fixed where it was found.

### Shape of the invariant

> **INV-MP (generalised)** — for every bind cco generates, every ancestor of the target that the
> runtime would have to materialise is **pre-created by cco, with the owner the writer needs** —
> host-side in cco's own tree, container-side in the image. No mountpoint ancestor is ever left to
> the container runtime.

### Shape of the lint

The compose generator already knows the full target list. A test that parses the generated
`docker-compose.yml`, derives every target's ancestor chain, and asserts each ancestor is either an
image-created claude-owned directory or itself a cco-owned mount, is mechanical and cheap. ⚠ It must
run against a **real generated compose file**, not a fixture — the hermetic suite is blind to
mount-time reality by construction (RC-17, now on its fourth recurrence).

### The adjacent contract — **the functional-write floor** (R-F)

ADR-0049 §5 introduced a *"functional-write floor"* so `settings.local.json` stays writable when
`/workspace/.claude` is `:ro`. The concept is right; its **derivation** was not: one known write path,
discovered by a bug report, instead of the documented set. So project-scope workflow saves — which
the official docs place in *"the closest existing `.claude/workflows/`"* — hit a `:ro` tree.

The authoritative source is Claude Code's own *application data* table (`claude-directory`):
`~/.claude/projects/`, `history.jsonl`, `file-history/`,
`{tasks,teams,sessions,session-env,shell-snapshots,backups,plans,paste-cache,image-cache,debug}/`,
`stats-cache.json`, `remote-settings.json`, `plugins/`, plus project-scope `.claude/workflows/` and
`.claude/worktrees/`.

> **The axis to ratify**: `claude_access` governs **authoring** (CLAUDE.md, rules, agents, skills).
> It does **not** govern Claude Code's **runtime state**, which is writable at every access level —
> exactly as `settings.json` already is (`cmd-start.sh:1738`, *"always rw (runtime prefs)"*).

The floor becomes a derived list with a provenance comment pointing at the official doc, plus a
container probe in the acceptance record. Re-deriving it is a maintenance task tied to Claude Code
releases, not a one-off.

---

## 4. Gap C — the YAML section boundary (**INV-YAML**)

`lib/cmd-project-add.sh:70-75` (`_yml_append_coord`):

```awk
$0 == sec":"        { in_sec=1; print; next }
in_sec && /^[^ #]/  { if (!ins) { print BLK; ins=1 } in_sec=0; print; next }
{ print }
END { if (in_sec && !ins) print BLK }
```

The section-end detector is *"the first top-level line that is not a comment"*. Comments therefore do
not close the section: they fall through to `{ print }` with `in_sec` still set, so the insertion
point slides **past** the comment block and lands immediately before the next key — i.e. **after that
key's header comment**. Observed on the maintainer's `cave-ensemble`: a repo appended after the
`# ── Extra mounts ──` banner and before `extra_mounts:`.

The `#` in the character class was almost certainly defensive — stopping a top-level comment from
terminating the section early. It trades one misplacement for a worse one: **a comment block
contiguous with the following key is that key's header by universal YAML convention, not the previous
section's footer.**

> **INV-YAML** — one spelling of "where does a section end", comment-block aware: buffer the trailing
> run of top-level comment and blank lines; on the next top-level key, emit before the buffered run,
> then flush. No verb re-implements it.

**Surface**: one function, four verbs — `cco project add {repo,mount,llms,pack}`
(`cmd-project-add.sh:203`), `cco init` (`cmd-init.sh:390`), `cco join` (`cmd-join.sh:164`). The same
`/^[^ #]/` idiom also appears in `lib/index.sh` (harmless — a generated file with no comments), which
is the reason the fix must be *one spelling plus a lint* rather than a local patch: the idiom is
already spreading.

**Test shape**: a golden-file round trip. Take the shipped `templates/project/base/project.yml` with
its full comment furniture, append to each section, and assert byte-equality against a fixture — the
only form that catches placement, since a YAML parse would call all these variants equivalent.

---

## 5. What this analysis asks cycle-1.2 to do

The unit of work is the invariant, not the finding. Three invariants and two contracts:

| # | Deliverable | Closes |
|---|---|---|
| 1 | **INV-AVAIL** + lint | W1-01, W1-02, W2-01, W2-02, W2-03, W2-08, W3-F01, W3-F02, W3-F05, W4-F03, W4-F04, W4-F05 |
| 2 | **index-health session/host axis** (contract) | W4-F06 🔴 — **and every Linux session's read path** |
| 3 | **INV-MP generalised** + lint | R-D (Claude Code transcripts / agent teams) |
| 4 | **functional-write floor derived from official docs** (contract) | R-F (workflow persistence) |
| 5 | **INV-YAML** + golden-file lint | R-E (config structure corruption) |
| — | *sentinel discipline on `bin/cco`'s EXIT trap* + lint | W2-06, W4-F02 |

**Non-negotiable acceptance note.** Items 2, 3 and 4 are invisible to the hermetic suite by
construction. Each needs a probe in a **real container after `cco build`**, recorded in the acceptance
log. Treating suite-green as evidence for them is precisely the mistake RC-17 named, and this is its
fourth recurrence.

## Related

- [`consolidated-review-v3.1.md`](../../configuration/agent-cco-access/e2e-review/results/consolidated-review-v3.1.md) — the findings, root map and ratified decisions D-V31-1…4
- [`false-success-class-audit.md`](false-success-class-audit.md) — the sibling class, and the template this analysis follows
- ADR-0043 (symmetric read scoping), ADR-0047 (privilege boundary, INV-S6), ADR-0049 (`claude_access`, the §5 floor), ADR-0054 (INV-MP)
