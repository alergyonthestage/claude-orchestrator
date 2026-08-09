# Handoff — 2026-08-09

> **Ephemeral.** At most one of these exists; the previous was deleted before this was written. It
> links **out** to the roadmap, ADRs and reviews — nothing links back to it.

## Methodology / where we are

**Phase: between Implementation and the next Plan.** No gate is pending. The A4 unit closed
completely this session: merged, reviewed twice, its one open decision decided and implemented, and
the documentation swept behind it.

Nothing is half-done. The working tree is clean, `develop` is at **`d011640`**, and every unit of work
described below is committed.

The next decision is a **priority choice**, not an approval: which of the queued items to start. See
*How to resume*.

## How to resume

**1. Push, from the host** — this is the only owed action that cannot be done in a session (network
verb, host-only). `develop` is **40 commits ahead** of `origin/develop`:

```
cd /Users/alessandro/Projects/CaveResistance/Software/claude-orchestrator
git push origin develop
git push origin --delete feat/access/claude-md-axis
git push origin --delete fix/access/fi67-none-locks-repo-claude-md
git branch -d feat/access/claude-md-axis fix/access/fi67-none-locks-repo-claude-md
```

Both local branches are fully merged into `develop` (fast-forward, tree-identical), so deleting them
loses nothing.

**2. Then pick the next unit.** In the order the roadmap gives:

- 🔴 **[FI-58](improvements.md) — the delegation channel.** Ahead of Block A by the maintainer's own
  priority call, set on cost: a delegated task currently costs three executions and the surviving one
  is the worst of the three. ⚠ The roadmap states the first question explicitly and it must be
  answered before any hypothesis: **is this cco's surface at all?** Reproduce outside cco first.
- Then **Block A** → `0.7.0`: A1, A2, A3, A5, A6, A7, A8 (A4 is done). A5 and A8 share one short
  design over the same interactive surface — see the A8 entry.

**3. Housekeeping, small and safe**: `scratchpad/backlog.md` and `scratchpad/backlog-2.md` are both
fully absorbed into the tracker (v1 → FI-56…FI-61, v2 → FI-68…FI-70 and A8) and can be deleted. They
were left in place only because the maintainer asked to delete them personally.

## Tasks

The [roadmap](roadmap.md) is the single source of truth for status; this list points at it.

- [ ] **Push `develop` + delete the two merged remote branches** — host-only (see above)
- [ ] 🔴 **[FI-58](improvements.md)** — delegation channel; investigation session, ahead of the queue
- [ ] **[A1](roadmap.md)** — `cco save`, project-config versioning helper (needs a short design)
- [ ] **[A2](roadmap.md)** — per-project custom Docker image ([FI-49](improvements.md); short design)
- [ ] **[A3](roadmap.md)** — cross-scope collision warning ([FI-32](improvements.md)) + three open decisions
- [ ] **[A5](roadmap.md)** — `cco start` must pause on its own warnings ([FI-55](improvements.md))
- [ ] **[A6](roadmap.md)** — `.claude/worktrees` in the functional-write floor ([FI-56](improvements.md))
- [ ] **[A7](roadmap.md)** — the A4 review residue ([FI-62](improvements.md) … [FI-66](improvements.md))
- [ ] **[A8](roadmap.md)** — onboarding prompts + mount-declaration surface ([FI-68](improvements.md) … [FI-70](improvements.md))
- [ ] **[FI-71](improvements.md)** — config-editor design doc drift; a `documenter` task, out of sequence
- [ ] **macOS host suite (bash 3.2)** — last run was `1626 / 0` on the `v0.6.0` tree; **owed again**
      before the `0.7.0` release, since nothing has re-measured 3.2 on `develop`
- [ ] **Delete `scratchpad/backlog.md` and `scratchpad/backlog-2.md`** — fully absorbed

## Context

### Decided this session

- **[ADR-0057 Amendment A2](configuration/agent-cco-access/decisions/0057-ask-enforcement-plane-and-resource-classes.md#amendments)**
  closes [FI-67](improvements.md) on **options 1+2 together**. Read the amendment, not this line, for
  the reasoning. The one thing worth carrying: the deny and the *rewording* had to ship together,
  because on `<repo>/**/CLAUDE.md` cco holds a **gate**, not a boundary — emitting the deny alone
  would have replaced a false claim with a subtler one.
- **[FI-10](improvements.md) is answered** after six weeks: a managed `deny` **is** enforced under
  `--dangerously-skip-permissions`. A2 depends on this and cites it.

### Non-obvious things the next session would otherwise rediscover

- 🔑 **`_claude_matrix_locks` requires ALL in-reach trees to resolve `ro`, not ANY — and that
  asymmetry with `_claude_matrix_asks` is load-bearing, not style.** One glob spans both in-reach
  trees and precedence is `deny → ask → allow`, so an ANY spelling emits a deny in the mixed cell
  (`entries.claude_md=ro` with `Cp=rw`) and **revokes a write the user granted**. The ANY variant was
  planted deliberately and **passes** `test_access_none_denies_repo_claude_md`; only
  `test_access_deny_absent_in_mixed_cell` catches it. Do not "simplify" the two predicates into one.
- 🔑 **The mixed cell is ungoverned on purpose**, and now published as such in `cli.md`. It is A1's
  residue and waits on per-tree rules (Block D may move the mount). It is not a bug to fix in passing.
- 🔑 **A `deny` is not a boundary.** It covers the built-in modifying tools and the Bash file commands
  Claude Code recognizes — never `dd`, `truncate`, or an interpreter. Docker remains the boundary.
  Any future wording must not promise more; that is exactly what FI-67 was.
- ⚠ **Measuring A4 behaviour inside *this* project needs an explicit `--claude-access`.** The FI-25
  mask (`access: {claude: all}` in `.cco/project.yml`) is ON deliberately, and it makes every tree
  `rw`, so `max()` absorbs `ask` and **no rule is emitted** — checks pass while measuring nothing.
- ⚠ **A pipeline's exit status is the last command's.** `docker … && echo OK | head` printed a green
  OK over a failed `docker run` during this session. Report `rc=$?` explicitly.
- ⚠ **`bash -n file1 file2` only checks the first file.** One invocation per file.
- 🔑 **The in-container `docker run` for bash-3.2 checks needs the proxy's name prefix**:
  `--name cc-claude-orchestrator-<something>`, or it is refused.
- 🔑 **A merge is host-only when its diff touches `.cco/`, not because of the branch.** Both merges
  this session ran in-session at the default access level, because neither diff touched `.cco/`.
  Check the diff, not the branch identity.
- 📝 **[FI-68](improvements.md) arrived with its premise inverted** — the report says extra_mounts
  default to `rw`; they default to `readonly: true`, documented and implemented. Only the *flag*
  surface is wrong. An implementer taking the report at face value would invert a security default.

### Open questions needing a human

- **[FI-68](improvements.md)'s capability question**, deliberately left open at design time: add
  `--writable` to `cco project add mount`, or fix only the help text and leave writable mounts to
  `project.yml`. It grants a user-perceivable capability from a one-line command.
- **The `acceptance/` leaf** in the access domain is invented relative to the pack's canonical set
  (`analysis/ design/ decisions/ reviews/`). Moving it would break links from ADRs and the roadmap —
  a taxonomy decision, not a fix.
- The four **open decisions** already listed in the roadmap (bash-3.2 fixtures, the `cco init` `$HOME`
  guard, the duplicated `pack internalize` section, the tutorial preset's "no write risk" wording).

## Reference documents

- [roadmap.md](roadmap.md) — the living SSOT for status and priorities
- [improvements.md](improvements.md) — the `FI-*` tracker (`FI-1 … FI-71`)
- [ADR-0057](configuration/agent-cco-access/decisions/0057-ask-enforcement-plane-and-resource-classes.md)
  — the `ask` plane and Axis-B resource classes, with **A1** (FI-52) and **A2** (FI-67) in *Amendments*
- [design.md §4bis.1](configuration/agent-cco-access/design.md) — the living design for both planes
- [Pre-merge gate review, 2026-08-09](configuration/agent-cco-access/reviews/2026-08-09-a4-pre-merge-gate-review.md)
- [Post-merge docs review, 2026-08-09](configuration/agent-cco-access/reviews/2026-08-09-post-merge-docs-review.md)
- [Implementation review, 2026-08-08](configuration/agent-cco-access/reviews/2026-08-08-a4-ask-plane-implementation-review.md)
- [Acceptance results](configuration/agent-cco-access/acceptance/0057-acceptance-results.md) — historical,
  now carrying a forward annotation on what check 4 actually covered
