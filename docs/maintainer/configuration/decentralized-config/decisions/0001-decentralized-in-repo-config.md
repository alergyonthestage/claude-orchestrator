# ADR 0001 — Decentralized In-Repo Configuration

**Status**: Accepted (2026-06-12)
**Deciders**: maintainer + design session
**Context docs**: `../requirements.md`, `../design.md`
**Supersedes**: `../../vault/profile-isolation-design.md` (branch-switch real isolation)

---

## Context

The central git-backed vault stored all projects under `user-config/projects/` and
used **git branches as profiles**: switching profile did a `git checkout` that
swapped which projects existed on disk. This coupled two orthogonal concerns —
*config storage* and *workspace selection* — and produced:

- A recurring, structural bug class (#B13, #B16–#B23) in the
  switch / `@local`-sanitize / gitignored-shuffle machinery (~60% of
  `cmd-vault.sh`).
- Opaque failures (`cco vault move` no-op while `cco vault diff` shows clean,
  because the diff hides `@local` differences).
- A hard UX limit: only one profile's projects on disk at a time → no concurrent
  cross-profile sessions on one machine.
- Friction with the developer's IDE-centric workflow (config versioned separately
  from the code it configures; constant IDE↔terminal↔vault context switching).

## Decision

Move to a **decentralized, in-repo configuration** model:

1. Each project's cco config lives in `<repo>/.cco/`, versioned with the code; the
   central vault is retired.
2. Profiles are removed; optional **tags** (registry metadata) provide grouping.
   The IDE is the project browser. Projects run concurrently.
3. `.cco/` uses a **hybrid layout** (RD10): `project.yml` + `secrets.env.example`
   flat for discoverability; `claude/`, `tracked/`, `state/`, `secrets/` grouped;
   `state/` + `secrets/` blanket-gitignored (structural secret safety).
4. The `@local` path contract is retained and reused; the host repo is implicit.
5. Multi-repo projects keep config as **explicit synced copies** (T3) in each
   repo's `.cco/`, kept identical by `cco sync`, which **reuses the existing 3-way
   merge engine** plus a committed `sync-base/` ancestor. Dual-mode
   (root / peer+confirm, default peer+confirm).
6. Sync is triggered **auto-on-`cco`-command + opt-in git hooks** (RD9); a
   background daemon is a possible future evolution.
7. A central **`~/.cco/`** holds the registry + caches + global config, with
   **cco-managed**, best-effort, non-blocking multi-PC auto-sync.
8. Two strictly-separated sync domains: **A** personal multi-PC (`~/.cco` managed +
   per-repo git) and **B** team/external sharing (Config Repos, unchanged).

## Alternatives Considered

| Alternative | Why not |
|-------------|---------|
| **Keep branch-switch, harden it** (worktree sync #6b/#6c) | Leaves the structural fragility and the no-concurrent-sessions limit; patches symptoms. |
| **Single filesystem + tags on the *central* vault** | Removes switch fragility and fixes concurrency, but keeps a manually-managed central repo and gives no per-project history / IDE-locality. Was the initial decision (2026-06-11); superseded by full decentralization. |
| **Decentralized with live multi-repo auto-sync daemon** | The sync-divergence risk and daemon complexity are unjustified up front; explicit copy-sync (manual trigger / hooks / on-command) achieves coherence more simply. Daemon kept as a future option. |
| **Per-repo config only, no `~/.cco` central store** | Loses cross-project sharing (packs/templates/global) and multi-PC sync of those resources; they have no natural per-repo home. |
| **`.cco/config/` subdir for `project.yml`** | Buries the entry-point file the user wants immediately visible; the hybrid layout keeps secret-safety without that cost. |
| **Symlink member repos to a primary `.cco/`** | Breaks clone/push portability and couples repos on the filesystem; explicit copies are clone-safe. |

## Consequences

**Positive**
- Removes the entire fragile switch/sanitize/shadow subsystem (~1900 lines + a
  2391-line test file); net complexity goes down.
- Concurrent cross-project sessions; IDE-first ergonomics; per-project config
  history versioned with code.
- Reuses proven machinery (`@local`, merge engine, secret-scan, gitignore-heal).
- Cleanly separates tool from user data → enables future npm/npx + image packaging.

**Negative / costs**
- A large, mostly-subtractive refactor across `cmd-vault.sh`, `local-paths.sh`,
  `cmd-start.sh`, and tests; a phased teardown + a one-time interactive migration.
- Multi-PC sync of central resources is now cco-managed git on `~/.cco` (not the
  old monolithic vault) — a new, slim subsystem (low risk: single-branch git).
- `.git/hooks` are not cloned → opt-in hooks must be re-installed per machine
  (mitigated by auto-on-`cco`-command as the default trigger).
- A deprecation window with dual-read fallback must be maintained for 1-2 releases.

## Follow-ups (separate workstreams)
- cco packaging (npm/npx + image registry).
- Persistent `/workspace` root via `.cco/workspace/`.
- Background sync daemon (evaluate if on-command proves insufficient).
