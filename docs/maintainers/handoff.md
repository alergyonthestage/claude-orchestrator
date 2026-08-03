# Handoff — **the release is BLOCKED**: the host suite aborted, and the docs sweep comes before G6

> **Ephemeral.** Delete this file before writing the next handoff. It links out only.
> Written 2026-08-03. Supersedes the handoff of 2026-07-31 (*"every in-session item is done; what
> remains is host-side"*). That handoff was right about the work and **wrong about the risk**: the
> host-side step it deferred is the one that failed.
> Gates: [runbook](configuration/agent-cco-access/e2e-review/fix-design-v3.1/08-gates-to-release.md).
> Status SSOT: [roadmap](roadmap.md).

## Methodology / where we are

Phase: **Implementation + Test**, at the release gates of cycle-1.2.

- ✅ **G4 done** — `fix/release/cycle-1.2` merged into `develop` as `b3e3496`; the tree-identity check
  passed (`tree(branch) == tree(develop) == 73987ab5…`). All three branches pushed and level with origin.
- 🔴 **G5 blocked** — 3 of 4 items pass; the **macOS host suite aborted** on a bash 3.2 parse error.
- 🔴 **G6 must not start.**

**No gate is pending human approval.** What is pending is *work*, plus three small decisions listed
under *Open questions*.

## How to resume

Do these in order. Steps 1–2 are the blocker; step 3 is what the maintainer asked for next.

1. **Read [FI-46](roadmap-backlog.md)** — the diagnosis is complete, the fix is prescribed, nothing
   needs re-deriving. Three sites in `tests/test_invariants.sh` (**1398, 1520, 1651**) write
   `prog=$(cat <<'AWK' … AWK\n)`. Bash 3.2's `$( … )` scanner does not skip heredoc bodies, so it never
   finds the closing `)`. **The rule is already in this repo**, at `bin/cco:181-186`, with the fix:
   move each heredoc into its own function and call `$(_fn)` — the shape is in the tree at
   `_cco_usage_text`.
2. **Fix it on a branch off `develop`** (`fix/tests/bash32-heredoc-substitution`), and add the
   regression cover as a **static CLASS lint** rejecting `=$(cat <<` across `bin/`, `lib/`, `tests/`,
   beside the existing `INV-S6` / `INV-YAML` / `INV-AVAIL` lints in `tests/test_invariants.sh`.
   ⚠ **A behavioural test cannot cover this** — there is no bash 3.2 in the image (`bash 5.2.15`), so
   any run in any session or in CI would be green regardless. The lint is the cover.
   Then hand the maintainer the host re-run; **the fix is not verified until a macOS run prints a real
   `Results:` line.**
3. **The docs sweep** the maintainer asked for (this is the next *session's* main subject): review and
   update the **stale long-living docs** — maintainer design/reference, user guides, CLI help — against
   the current state, so that **shipped** docs are coherent before G6. One concrete item is already
   found and waiting: `CLAUDE.md:134` (see *Context*). Start from
   [`cli/reference/cli-surface-matrix.md`](cli/reference/cli-surface-matrix.md) and the
   [G2 audit report](cli/reviews/2026-07-31-cli-surface-audit.md), which record what was *already*
   corrected on 2026-07-31 — do not redo that work, extend past it.
4. **Then G6**, then delete the merged `feat/*` branches.

## Tasks

The [roadmap](roadmap.md) is the single source of truth for status; this list only points at it.

- [x] ✅ **G4** — merged, tree-identity verified. Details in the [runbook](configuration/agent-cco-access/e2e-review/fix-design-v3.1/08-gates-to-release.md) §G4.
- [ ] 🔴 **[FI-46](roadmap-backlog.md)** — fix the three heredoc-in-substitution sites + the CLASS lint.
- [ ] 🔴 **G5's fourth item** — re-run the macOS host suite to completion. **Check for the `Results:`
      line**; its absence is what made the last run look green.
- [ ] **Docs sweep** — stale long-living docs → current state; shipped docs coherent before G6.
- [ ] **G6** — `develop → main` + release, carrying the approved FI-42 known-issue sentence verbatim.
- [ ] **Housekeeping at G6** — delete `suite-macos-b3e3496.log` from the repo root (untracked host
      artefact); delete the merged `feat/*` branches; **restore the `access: {claude: all}` mask** in
      `.cco/project.yml` (removed for G5's honest measurement — without it, dev sessions cannot author
      `.claude` trees).

## Context

### What this session produced

**G4's merge** (`b3e3496`, on `develop`) and this docs commit (on `docs/release/cycle-1.2-gates`).
No code changed.

**G5's measurements**, all recorded in the [runbook](configuration/agent-cco-access/e2e-review/fix-design-v3.1/08-gates-to-release.md) §G5:
unmasked suite **1616/9 of 1625**, npm-pack hygiene clean, dogfood green on `develop@b3e3496`, host
suite **aborted**.

### Open questions that need the human

1. **Should the host suite be a gate rather than a manual step?** Every other release check runs where
   this failure mode is unobservable. Logged inside FI-46; it is a process decision, not part of the fix.
2. **Does a `read-all` smoke dogfood belong in G5?** The run done was at `read-project`, so it exercised
   the scoped output path only.
3. **This branch (`docs/release/cycle-1.2-gates`) needs merging into `develop`** — it carries the gate
   records, FI-46 and this handoff. Nothing depends on it, but a next session that starts on `develop`
   will not see any of it until it is merged.

### Non-obvious things worth not rediscovering

- 🔑 **The mask is a MOUNT property, not a file property.** Removing `access: {claude: all}` from
  `.cco/project.yml` while a session is live changes **nothing** — the `:ro` overlays are resolved at
  `cco start`. The session must be **restarted** for an unmasked measurement. Confirmed both directions
  via `/proc/self/mountinfo` and the writability of `defaults/global/.claude/rules`.
- 🔑 **A host log with `0 failed` and no `Results:` line is an ABORT, not a pass.** This is how a
  bash parse error reads at a glance. **Check for the summary line before believing any figure.**
- 🔑 **The container is structurally blind to bash 3.2 defects** (`bash 5.2.15`, no 3.2 available). The
  two fixes that landed *after* G3's acceptance — FI-41 (`1814ba3`) and FI-45 — were verified
  in-container only, and FI-41 is what introduced FI-46. **A late fix verified only in-session is a
  fix verified on one of the two platforms this project supports.**
- ⚠ **`.cco/project.yml` carries three uncommitted changes, not one**: the `access:` mask (currently
  **removed** for G5 — restore it), the port `8082:8080`, and `packs: - name: core-dev-framework`.
  **Never `git checkout .cco/project.yml`** — it would discard the last two as well.
- ⚠ **`.claude/worktrees/` holds full copies of the repo.** Exclude it from every repo-wide grep or you
  will "find" stale text that is not in the tree.
- ⚠ **A `grep -v` filter can hide the very line you are looking for.** Searching for the stale
  `claude_access` default with `grep -v cco_access` suppressed the one real hit, because the sentence
  names both axes together. Narrow the haystack, not the needle.
- `tests/test_start_dry_run.sh:1740` and `:1762` contain literal conflict markers as **fixture
  content** — a repo-wide grep for merge markers flags them as false positives.
- **Store-touching verbs in a session run the image-baked cco**, so `lib/` edits stay invisible
  in-session until `cco build`. On the **host**, `./bin/cco` reads the working tree.

### The one drift already found for the docs sweep

`cco whoami` reports `claude_access: none` where **`CLAUDE.md:134`** says *default `repo`*. The **code
is right** — `lib/cmd-start.sh:256-257`: Axis B *"no longer has a fixed preset default — it DERIVES from
the resolved cco triple (ADR-0049 §2)"*. G2 already fixed the user-facing copy
(`docs/users/reference/cli.md:350` is correct); `CLAUDE.md` was not among its four subjects. It does
**not** ship (absent from `package.json`'s `files` allowlist, verified against the `npm pack` manifest),
so it is agent-facing drift only — real, but not release-blocking.

## Reference documents

- [Roadmap](roadmap.md) — G4 ✅ / G5 🔴 / G6 blocked · lanes L1–L5 accepted ·
  [backlog](roadmap-backlog.md) — **FI-46 (new, blocking)**, FI-40/42/43 (deferred to cycle-2), FI-44, FI-45
- [Gates runbook](configuration/agent-cco-access/e2e-review/fix-design-v3.1/08-gates-to-release.md) —
  G0…G6; **G4 done**, **G5 3-of-4**, **G6 blocked**; G6 step 5 carries the approved known-issue sentence
- [G2 audit report](cli/reviews/2026-07-31-cli-surface-audit.md) — what the docs sweep should build on
- [CLI-surface matrix](cli/reference/cli-surface-matrix.md) — the canonical verb table
- [Cycle-1.2 plan](configuration/agent-cco-access/e2e-review/fix-design-v3.1/00-plan.md) — §7 acceptance log
- [Config mount topology analysis](configuration/agent-cco-access/analysis/config-mount-topology.md) —
  **cycle-2 starts here**, §3.3 and §8
