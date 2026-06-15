# ADR 0001 — Decentralized In-Repo Configuration (sync-as-copy)

**Status**: Accepted (2026-06-15)
**Deciders**: maintainer + design sessions
**Context docs**: `../requirements.md`, `../design.md`
**Decision history**: `../reviews/15-06-2026-sync-adversarial-review.md`
**Supersedes**: the central git-backed vault (projects + branch profiles + custom
config diff/save) and `../../vault/profile-isolation-design.md`.

---

## Context

The central git-backed vault stored all projects under `user-config/projects/` and
used **git branches as profiles** (checkout swapped which projects existed on disk).
Two structural problems followed:

1. **Storage coupled to selection** → a recurring bug class (#B13–#B23), opaque
   failures, and no concurrent cross-profile sessions on one machine.
2. **Committed config was machine-specific** → real paths in `project.yml` were
   rewritten to `@local` on save and back on read, so a plain `git diff` was
   untruthful. The vault carried a **custom diff/save/sanitize/virtual-diff** layer
   purely to hide that discrepancy — a large, fragile subsystem in its own right.

An adversarial review of an initial decentralized design (which kept a custom 3-way
merge/`sync-base`/commit-time sync engine for multi-repo config) found that engine to
be non-reusable, non-deterministic for N≥3 repos, and prone to silent
ancestor-drift — i.e. it re-imported the very opaque-failure class being removed.

## Decision

Adopt **decentralized, in-repo configuration with machine-agnostic committed files,
plain git as the only cross-PC transport, and sync-as-copy**:

1. Each project's cco config lives in `<repo>/.cco/`, versioned with the code; the
   central vault is retired.
2. **Committed config is 100% machine-agnostic**: `project.yml` references repos and
   extra mounts by **logical name** only (no real paths) and is identical across a
   project's repos. Real absolute paths live in a **machine-local index** (never
   committed/synced). Therefore a plain `git diff` is always truthful, and the entire
   custom diff/save/sanitize/virtual-diff layer is **deleted**.
3. Profiles are removed; optional **tags** provide grouping. Projects run
   concurrently; the IDE is the project browser.
4. **No privileged repo.** Any repo with a `.cco/` is a valid entry point; `cco
   start` uses the **invoking repo's** config (cwd) or a flag. An optional per-project
   `entry` repo is only a tie-breaker for name-based `cco start <project>`.
5. **Sync = copy.** `cco sync` copies a chosen source repo's `.cco/` set into target
   repos on the same machine (filesystem copy). No merge engine, no `sync-base`, no
   commit-time, no peer/root modes, no confirm/last-commit-wins policies. Divergence
   is allowed and visible; the user picks the source. Default is diff + confirm
   (`--auto-approve` to skip).
6. **Git is the only cross-PC transport.** A repo's `.cco/` rides its own remote;
   concurrent cross-PC edits are ordinary git conflicts resolved in the IDE. Repos
   need not be git for core operation or same-machine sync; git is required only to
   travel across machines.
7. **Config/state/cache separated by location.** The committed `<repo>/.cco/` holds
   only machine-agnostic config. State (generated compose, claude-state, the index,
   temp) and cache live in **system directories** outside the repo, hidden.
   `secrets.env` is the one in-repo exception (gitignored, user-edited).
8. A central **`~/.cco/`** holds authored packs/templates/global-claude as a personal
   git store (Domain A; management depth deferred). Team sharing stays on Config Repos
   (Domain B, unchanged).
9. The 3-way merge engine is **kept unchanged** for `cco update` (framework→user
   template/pack updates); it was never config-sync machinery.

## Alternatives Considered

| Alternative | Why not |
|-------------|---------|
| **Keep the vault (branch-switch), harden it** | Leaves storage/selection coupling, the no-concurrent-sessions limit, and the custom-diff fragility; patches symptoms. |
| **Decentralize but keep machine-specific committed paths (@local rewrite-on-save)** | Re-imports the untruthful-`git diff` problem → still needs a custom diff/save layer. Rejected: machine-agnostic committed config removes the need entirely. |
| **Custom 3-way merge + `sync-base` + commit-time sync engine for multi-repo config** | The adversarial review showed it non-reusable (the existing engine is framework-directional), non-deterministic for N≥3, and prone to silent ancestor-drift across independent remotes — re-importing opaque failures. Replaced by sync-as-copy. |
| **Primary-holds-config (only one repo carries project-scope config)** | Simpler, but makes one repo privileged: the user could not edit config from any repo's IDE, and peer-style workflows have no defined config holder. Rejected in favor of "any repo is a source; cwd decides; sync = copy". |
| **`~/.cco` as a source-of-truth hub that repos copy from** | Reintroduces a central source of truth for project config (undoes decentralization) and, cross-PC, creates two diverging sources (repo remote + per-machine hub). Rejected. |
| **Symlink member repos to one `.cco/`** | Breaks clone/push portability and couples repos on the filesystem; explicit copies (via `cco sync`) are clone-safe. |
| **Per-repo config only, no `~/.cco`** | Loses cross-project sharing (packs/templates/global) and multi-PC sync of those resources, which have no per-repo home. |

## Consequences

**Positive**
- Removes the fragile switch/sanitize/shadow subsystem **and** the custom config
  diff/save/merge layer; net complexity drops sharply.
- A plain `git diff` on `.cco/` is always truthful (no cco-specific diff to learn).
- Concurrent cross-project sessions; IDE-first ergonomics; per-project config history
  with code; no privileged repo.
- Sync is a copy — the review's C1/C2/C3 and H1/H3/H4/H5/H6 dissolve (no
  reconciliation algorithm exists).
- Cleanly separates tool from user data → enables future npm/npx + image packaging.

**Negative / costs**
- Concurrent **cross-PC** edits surface as ordinary git merge conflicts the user
  resolves with git tooling (acceptable for an IDE-first audience; must be documented).
- Multi-repo config changes mean committing N repos (config rides with code, G6);
  `git log -- .cco/` isolates config history; `cco sync` prints which repos changed.
- A new machine-local index must be maintained (CLI-managed; rebuildable by scan).
- A deprecation window with dual-read must be kept for 1–2 releases.

## Open (dedicated follow-up analyses; do not block Phase 0 except RD-claude-mount)
RD-syncmeta (last-synced snapshot/rollback), RD-home (`~/.cco` management depth),
RD-authoring (global pack/template authoring), RD-paths (system-dir locations),
RD-memory (`memory/` handling), RD-triggers (future auto-sync), RD-claude-mount
(Phase-0 mount vs pack-injection check). See `../requirements.md` §8 and
`../design.md` §13.

## Follow-ups (separate workstreams)
cco packaging (R-pkg); `cco update` native publish/install (R-update-native);
persistent `/workspace` root (R-workspace).
