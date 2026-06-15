# ADR 0003 — Config Sync Model: Sync-as-Copy

**Status**: Accepted (2026-06-15)
**Deciders**: maintainer + design session
**Context docs**: `../requirements.md` (AD6, AD7, AD8, FR-Y-S), `../design.md` §4
**Evidence**: `../reviews/15-06-2026-sync-adversarial-review.md` (refutes the custom
engine), `../reviews/15-06-2026-simplification-analysis.md` (Part B, axes)
**Related ADRs**: 0001 (decentralization), 0002 (machine-agnostic config)

---

## Context

A multi-repo project shares project-scope config (`project.yml`, `.cco/claude/**`)
across sibling repos that have **independent git remotes and histories** — plain `git`
of one repo never touches another. An initial design kept this coherent with a custom
**3-way merge engine + committed `sync-base/` ancestor + commit-time
"last-commit-wins"**, in dual peer/root modes.

An adversarial review refuted that engine: the existing merge engine is
framework-directional (not reusable unchanged — finding C1); N≥3 peer merges are
order-dependent/non-deterministic (C2); the committed `sync-base` drifts across
independent remotes, silently invalidating future merges (C3); commit-time is not a
reliable cross-machine key (H1); "atomic" N-repo writes are impossible in bash (H4);
off-branch `git show` reads contradict the working-tree model (H5); cross-process
re-entrancy is unguarded (H6). In short, the reconciler re-imported the opaque-failure
class the refactor set out to remove.

## Decision

Replace reconciliation with a **plain copy**:

1. **Sync = copy.** `cco sync` copies a chosen **source** repo's committed `.cco/` set
   (`project.yml` + `claude/**` + `secrets.env.example`) into **target** repos on the
   **same machine** (filesystem copy). No merge engine, no `sync-base`, no commit-time,
   no peer/root modes, no confirm/last-commit-wins policies.
2. **Command forms** (positional = target, `--from` = source; default source = cwd):
   `cco sync` (cwd→all), `cco sync <repo>` (cwd→that repo), `cco sync --from <r>`
   (r→all), `cco sync <A> --from <B>` (B→A). Default behavior: show a **truthful diff +
   confirm** (`--auto-approve` skips; `--dry-run` previews; `--check` exit-code only).
3. **No privileged repo.** Any repo with `.cco/` is a valid source. `cco start` uses
   the **invoking repo** (cwd) or a flag; an optional per-project `entry` repo is only
   a tie-breaker for name-based `cco start <project>`. Divergence is allowed and
   visible; `cco start` prints a non-blocking notice and never silently reconciles.
4. **Git is the only cross-PC transport.** Each repo's `.cco/` rides its own remote;
   concurrent cross-PC edits are ordinary git conflicts resolved in the IDE. Repos
   need not be git for same-machine sync; git is required only to travel across PCs.

## Alternatives Considered

| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Custom 3-way merge + `sync-base` + commit-time engine** (peer/root, confirm/LCW) | Auto-reconciles without choosing a source | Non-reusable engine (C1); non-deterministic N≥3 (C2); sync-base drift (C3); commit-time unreliable (H1); non-atomic (H4); off-branch (H5); re-entrancy (H6) | Rejected (review) |
| **Primary-holds-config** (only the primary repo carries project config) | Eliminates copies; matches single mount slot | Privileges one repo; cannot edit config from any repo's IDE; no holder in peer workflows | Rejected |
| **Symlink members to one `.cco/`** | One physical copy | Breaks clone/push portability; couples repos on the filesystem | Rejected |
| **`~/.cco` as project-config source-of-truth hub** | One place to edit | Re-centralizes (undoes ADR-0001); two diverging cross-PC sources; silent last-write-wins | Rejected |
| **Sync-as-copy (chosen)** | No reconciliation algorithm → C1/C2/C3/H1/H3/H4/H5/H6 dissolve; works on non-git repos; divergence explicit and user-resolved; trivial to reason about | User chooses the source (no auto "newest"); multi-repo changes mean N commits; cross-PC conflicts handled by git, not cco | **Accepted** |

## Consequences

**Positive** — the largest cluster of review findings dissolves (no algorithm to get
wrong); sync works for non-git repos (same-machine copy); divergence is a visible,
intentional, user-resolved state; the planned `lib/cmd-sync.sh` is a copy + diff, not a
reconciler; the `cco sync`/`cco config sync` verb collision is gone.

**Negative** — the user picks the source instead of an automatic "most recent"
(deliberate: no unreliable timestamp heuristic); multi-repo config changes require
committing N repos (`git log -- .cco/` isolates config history; `cco sync` reports
changed repos); cross-PC concurrent edits require git literacy (documented).

## Open
RD-syncmeta (optional last-synced snapshot for fast rollback + user-vs-sync change
detection), RD-triggers (future opt-in daemon/hooks; manual is v1). Neither blocks
Phase 0.
