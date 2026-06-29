# Simplification Analysis — Diff Archaeology & Plain-Git Feasibility

**Date**: 2026-06-15
**Type**: Historical analysis (decision evidence). Not a living spec.
**Method**: two code-grounded analyst investigations (diff/sanitize archaeology;
plain-git feasibility across sync axes), synthesized.
**Drove**: ADR-0002 (machine-agnostic config), ADR-0003 (sync-as-copy). Complements
`15-06-2026-sync-adversarial-review.md` (which refuted the custom merge-engine sync).

> This document records *why* the refactor dropped the custom config diff/save/merge
> layer in favor of machine-agnostic committed config + plain git + sync-as-copy. It
> is preserved as decision history; the living design is in `../design.md`.

---

## Part A — Diff-divergence archaeology (what `cco vault diff` hid, and why)

**A1 — The real↔committed delta is tiny and confined to `project.yml`.**
The only content that differs between on-disk (real) config and committed (vault)
config is in `project.yml`: two fields — `repos[].path` and `extra_mounts[].source`
— reduced to the `@local` marker on save and re-expanded to real paths on read, plus
a synthetic `url:` injected for git-remote siblings. **Every other committed file is
byte-identical to disk.** (`lib/local-paths.sh` sanitize/resolve path.)

**A2 — `cco vault diff` exists essentially to hide that delta.** Because the committed
`project.yml` differs from its on-disk form, a plain `git diff` would show spurious
`@local`↔real-path churn. The vault therefore wraps git with a "virtual diff" that
re-sanitizes before diffing and suppresses `@local` noise. This is the documented
cause of opaque failures (e.g. `cco vault move` no-op while `cco vault diff` shows a
clean tree — the diff deliberately ignores `@local` differences).

**A3 — The 3-way merge engine is NOT vault/sync machinery.** `_merge_file`,
`_resolve_with_merge`, `_interactive_sync`, `_collect_file_changes`
(`lib/update-merge.sh`, `lib/update-sync.sh`, `lib/update-discovery.sh`) exist for
**framework→user template/pack updates** (`cco update --sync`). Evidence: every caller
is update-family (`lib/update.sh:179,232,477,579`, `lib/cmd-project-update.sh:161,183`,
`lib/cmd-project-publish.sh:59`); the engine is template-directional (interpolates
`{{PROJECT_NAME}}`), hard-bound to `scope ∈ {global, project}`
(`update-discovery.sh:23-34`), and **explicitly excludes `project.yml`**
(`lib/update.sh:34`). Conclusion: it stays unchanged for `cco update`; it was never
config-sync, so "reusing it for sync" would have saved nothing.

**A4 — No git assumption on repos today.** Repo validation uses the filesystem
(`_path_exists`); the only git touches on repo paths are best-effort and guarded by
`[[ -d "$repo/.git" ]]`. A non-git repo does not break anything today; only a
"config-versioned-in-repo-git" model would introduce a git dependency — and only for
cross-PC travel, not for core operation.

**A5 — What machine-agnostic committed config makes eliminable.** If committed files
carry no real paths (logical names only; real paths in a machine-local index), the
following become unnecessary: `_sanitize_project_paths`, the resolve-rewrite of
`project.yml`, the extract/restore + pre-save backup + ERR-trap protocol,
`_normalize_committed_paths`, the virtual-diff suppression, and the gitignore patterns
for sanitize "ghost" tempfiles. Survives: a machine-local path index + logical→real
resolution at consumption time. → **ADR-0002.**

---

## Part B — Plain-git feasibility across the sync axes

The key analytical move: separate the axes instead of conflating them.

**B1 — Axis 1: per-repo `.cco/` across the same user's PCs → plain git is sufficient.**
The synced set is committed files on a single repo with a single remote: textbook
`git pull/push`. Given machine-agnostic content (Axis precondition), there is nothing
for a custom diff to compensate for. Concurrent cross-PC edits are ordinary git merge
conflicts resolved in the IDE — simpler than a bespoke wizard, no `sync-base`, no
commit-time heuristic.

**B2 — Axis 2: cross-repo within one project → plain git alone does NOT solve it.**
Sibling repos have independent remotes/histories; `git pull` of A never touches B.
Two options keep sibling `.cco/` identical: (a) a custom reconciler (the rejected
merge engine — source of review findings C1/C2/C3/H1/H3/H4/H5/H6), or (b) eliminate
the reconciliation. The chosen model is **sync-as-copy**: `cco sync` copies a
**user-chosen source** repo's `.cco/` to targets on the same machine. Because the
source is chosen (not auto-reconciled), no merge/ancestor/timestamp logic is needed —
it is a filesystem copy. This also works for non-git repos (same-machine copy) and
makes divergence an explicit, visible, user-resolved state. → **ADR-0003.**

(Primary-holds-config — only the primary repo carries project config — was also
considered and rejected: it privileges one repo and blocks editing config from any
repo's IDE. See ADR-0003 alternatives.)

**B3 — Axis 3: `~/.cco` across the same user's PCs → auto-managed plain git is
feasible.** Unlike Axis 2, `~/.cco` is a single directory with a single personal
remote — plain git fits cleanly. The only hard rule: commit via an explicit
**allowlist** (`packs/ templates/ global/.claude/`), never `git add -A`, so
machine-specific/secret files never push. Concurrency is the old vault's problem minus
the branch-switch/sanitize machinery; git's own merge handles non-overlapping changes
and surfaces true conflicts (rare for one user). Management depth deferred to RD-home.

**B4 — Net effect on the adversarial-review findings.** Under machine-agnostic config
+ sync-as-copy + plain git: Criticals **C1** (engine-reuse), **C2** (N-way topology),
**C3** (sync-base drift) and Highs **H1** (commit-time), **H3** (partial-push
coherence), **H4** (atomic N-write), **H5** (off-branch read), **H6** (re-entrancy)
**dissolve** — there is no reconciliation algorithm to get wrong. Surviving items are
orthogonal to the transport: **C4/RD-claude-mount** (Phase-0 mount vs pack injection),
**C5** (`*.example` secret-scan exemption), registry bootstrap (now the rebuildable
machine-local index), and memory cross-PC (RD-memory).

**B5 — Cost of plain git (honest).** Cross-PC concurrent edits require git literacy
(acceptable for an IDE-first audience; documented). Multi-repo config changes mean
committing N repos (config rides with code, a goal); `git log -- .cco/` isolates
config history; `cco sync` reports which repos changed.

---

## Evidence index
- `lib/local-paths.sh` — `@local` sanitize/resolve (the only real↔committed delta).
- `lib/update-merge.sh:13,52`, `lib/update-sync.sh:45`, `lib/update-discovery.sh:9,23-34` — merge engine (framework-directional; `cco update` only).
- `lib/update.sh:34,179,232,477,579`, `lib/cmd-project-update.sh:161,183`, `lib/cmd-project-publish.sh:59` — engine callers (all update-family) + `project.yml` exclusion.
- `lib/cmd-start.sh:454`, `lib/packs.sh:91-130` — single `/workspace/.claude` mount vs pack injection (RD-claude-mount).
- `lib/secrets.sh:24-82` — secret filename + content scan (`*.example` exemption needed).
- Companion: `15-06-2026-sync-adversarial-review.md` (full finding list).
