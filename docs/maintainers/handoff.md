# Handoff — **the plan is re-ordered and persisted; nothing is in flight. Next: merge this branch, then open Block A.**

> **Ephemeral.** Delete this file before writing the next handoff. It links out only.
> Written 2026-08-05. Supersedes the handoff of 2026-08-04 (*"next is cycle-2, and it starts with an
> analysis"*) — **that pointer is now wrong**: cycle-2 is still planned, but it is **Block D**, last of
> four, not next. Status SSOT: [roadmap](roadmap.md).

## Methodology / where we are

Phase: **Plan — complete and persisted.** No code was touched this session; nothing is half-done.

`v0.6.0` is released and its cycle is closed. A planning session compared the roadmap against a batch
of newly surfaced needs (some blocking external projects and packs) and the maintainer **ratified a
priority order on 2026-08-04**. That order, and every item's context, is now written into the
[roadmap](roadmap.md), which was restructured from 1459 to 538 lines around it.

**Gates**: none pending on the analysis/design side. What is pending is a **merge** — the human review
point per `.claude/rules/git-practices.md` — and then approval to open the first implementation unit.

## How to resume

1. **Merge `docs/roadmap/restructure` → `develop`.** Four commits, documentation only: no code, no
   tests, no suite impact, working tree clean. Then push.
   ⚠ **This branch is currently checked out in the shared working tree.** The host and the container
   share one tree; the Mac had `main` checked out at the start of this session and it was switched to
   `develop` and then to this branch, with the maintainer's go-ahead. Nothing was running at the time.
2. **Read [`roadmap.md`](roadmap.md)** — it is the plan, in order, and each item carries its
   references, its context and the notes needed to open its session. Read nothing else first; the
   roadmap points at what each item needs.
3. **Open Block A, item A1 (`cco save`).** Its first move is not code: it is **choosing the verb name**,
   because three surfaces already disagree (the maintainer's note says `cco save`; ADR-0042 and the
   baked managed rule assume `cco project save`; `cco config save` is taken by the personal store).
   That name has to be settled before anything is written, because the injected session context and the
   managed rule must name the real verb.

## Tasks

Status lives on the [roadmap](roadmap.md); this is the checklist, not a second source of truth.

- [ ] **Merge + push** `docs/roadmap/restructure` → `develop`
- [ ] **Block A → `0.7.0`** — [roadmap §Block A](roadmap.md)
  - [ ] **A1** `cco save` — short design (verb name + 5 listed decisions), then implement
  - [ ] **A2** per-project custom Docker image — [FI-49](improvements.md); do sub-problem 3 (the
        `setup.sh` root-vs-`claude` contradiction) **first**, by running it, because the answer changes
        what the guide should recommend for the other two
  - [ ] **A3** cross-scope collision warning — [FI-32](improvements.md) — plus the three open decisions
        below
- [ ] **Cross-cutting analysis** — resource taxonomy + configuration-scope model. Read-only, no
      release, and it **gates the design of both B and C**
- [ ] **Block B → `0.8.0`** — `cco update` responsibilities + orchestration + post-install · `cco attach`
      · [FI-30](improvements.md) docs coherence
- [ ] **Block C → `0.9.0`** — the shared-resource platform: [FI-47](improvements.md) templates →
      [FI-48](improvements.md) enforcement transport → [FI-28](improvements.md)/[FI-29](improvements.md)/[FI-51](improvements.md)
      → [FI-50](improvements.md) publish sources + workstream F
- [ ] **Block D → `1.0.0`** — cycle-2: config multiplicity, divergence awareness, mount topology, with
      [FI-40](improvements.md)/[FI-42](improvements.md)/[FI-43](improvements.md) and the Linux write-path ADR

## Context

### What was decided this session, and why

No ADR was produced: the decisions are **plan** decisions, whose home is the roadmap (SSOT), not an
architectural record. Two rulings are worth not re-litigating, and both are written into the roadmap:

- **No interim `cco upgrade` verb.** The option of shipping a narrow orchestration verb now and
  refactoring later was put to the maintainer and **rejected**: a temporary reshuffle of `cco update`
  that a later refactor revisits costs more than one cycle of waiting. `cco update` becomes the
  orchestrator (`npm update → migrations → cco build`) and **loses** the opinionated-content update
  responsibility entirely, because that content leaves the core with workstream F.
- **The resource-taxonomy analysis was pulled ahead of Block B's design**, for the same reason: B has
  to declare the core/opinionated boundary, and *what an opinionated resource is* is that analysis's
  output. Designing B first would settle the boundary by implementation.

### Open questions that need a human

Three are recorded in full on the [roadmap](roadmap.md) and are A-sized — take them whenever:
the 180 latent bash-3.2 fixtures · the missing `$HOME` guard on `cco init` · the duplicated
`cco pack internalize` section. Two more came out of this session:

1. **Does the documentation-layout convention go into the `core-dev-framework` pack?** The pack's rule
   is *"exactly one `roadmap.md`"*, and this project now runs one roadmap + a historical companion + an
   issue tracker. The maintainer raised the idea of integrating that split into the pack. Until then it
   is recorded only in this project ([roadmap](roadmap.md) header + [README](README.md)) — an ADR or a
   pack change would make it a convention rather than a local habit.
2. **Stale in-cycle handoffs are still on disk.** `configuration/agent-cco-access/e2e-review/handoff-v3.md`
   and the `fix-design-v3/RESUME-HANDOFF-s*.md` set were resume documents for a cycle that is now
   closed. The roadmap no longer links to them. Deleting them is a decision, not a cleanup — they are
   adjacent to the [FI-44](improvements.md) class (historical docs linking to ephemeral ones).

### Non-obvious things the next session would otherwise rediscover

- ⚠ **`scratchpad/` is gitignored.** The three external pack-line handoffs — the input for the whole of
  Block C — were sitting there unversioned. They are now persisted verbatim under
  [`packs/analysis/`](packs/analysis/). Check that directory before concluding an input was lost.
- ⚠ **ADR-0038 and ADR-0040 do not exist as documents.** They are numbers reserved by older roadmap
  entries for workstreams D and F. Whoever writes them writes them for the first time. **Next free ADR
  number is 0057.**
- 📝 **`roadmap-backlog.md` no longer exists** — it is [`improvements.md`](improvements.md). A stale
  path in a frozen ADR or an old plan is a dangling link, not a missing file.
- 📝 **Two things believed open are already shipped**: `.claude` write access for workflows and
  transcripts landed in `0.6.0` (ADR-0055; only [FI-37](improvements.md)/[FI-38](improvements.md)
  residue remains), and developer mode ships as `cco --dev-sandbox` / `--dev-sandbox-seed`, snapshot
  seeding included, documented at `docs/users/reference/cli.md` §3.34.
- 📝 **`main` is an ancestor of `develop`** — no divergence, no backmerge owed, both at `0.6.0`.
- ⚠ **Every in-container suite figure is masked.** `access: {claude: all}` is committed in
  `.cco/project.yml` as a self-dev workaround for [FI-25](improvements.md): expect `…/7`, never `…/9`.
  Unmasked baseline for this tree is **1616/9 of 1625**; macOS host is **1626/0**.
- 🔑 **A process note from this session, since it recurred**: the first attempt at the rename commit
  staged the `git mv` but not the reference sweep, so three commits carried dangling links. The commits
  were rebuilt. `git commit -m` after a `sed` sweep commits **only what was staged** — a rename and its
  sweep are one logical change and must be staged together.

## Reference documents

- [Roadmap](roadmap.md) — **start here**: the four blocks in order, each with references and session
  notes · [improvements.md](improvements.md) — the issue tracker, `FI-1 … FI-51` ·
  [roadmap-history.md](roadmap-history.md) — cycle 1 and everything before it
- [`packs/analysis/input-pack-templates-and-scope-resolution.md`](packs/analysis/input-pack-templates-and-scope-resolution.md)
  and [`input-pack-enforcement-transport.md`](packs/analysis/input-pack-enforcement-transport.md) —
  the inputs for Block C; [`input-subagent-role-memory.md`](packs/analysis/input-subagent-role-memory.md)
  is the field measurement behind [FI-39](improvements.md)
- [`configuration/agent-cco-access/analysis/config-mount-topology.md`](configuration/agent-cco-access/analysis/config-mount-topology.md)
  §3.3 and §8 — **Block D starts here**, four blockers and six open questions, already code-grounded
- [`engineering/opinionated-extraction-and-update-refactor-handoff.md`](engineering/opinionated-extraction-and-update-refactor-handoff.md)
  — gaps G1–G7, input to both the shared analysis and Block C stage C4
- [Gates runbook](configuration/agent-cco-access/e2e-review/fix-design-v3.1/08-gates-to-release.md) —
  complete; the template for the next release
