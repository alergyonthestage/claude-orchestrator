# ADR 0001 — Decentralized In-Repo Configuration

**Status**: Accepted (2026-06-15)
**Deciders**: maintainer + design sessions
**Context docs**: `../requirements.md`, `../design.md`
**Related ADRs**: 0002 (machine-agnostic config), 0003 (sync-as-copy),
0004 (config/state/cache separation)
**Supersedes**: the central git-backed vault (projects + branch profiles) and
`../../vault/profile-isolation-design.md`.

> Scope of this ADR: the **foundational** decision to decentralize config into each
> repo and retire the vault. The *how* of paths, sync, and storage layout is in the
> sibling ADRs 0002–0004.

---

## Context

The central git-backed vault stored all projects under `user-config/projects/` and
used **git branches as profiles**: switching profile did a `git checkout` that swapped
which projects existed on disk. This coupled two orthogonal concerns — *config
storage* and *workspace selection* — and produced:

- A recurring structural bug class (#B13, #B16–#B23) in the switch /
  `@local`-sanitize / gitignored-shuffle machinery (~60% of `cmd-vault.sh`).
- Opaque failures (`cco vault move` no-op while `cco vault diff` shows clean).
- A hard UX limit: only one profile's projects on disk at a time → no concurrent
  cross-profile sessions on one machine.
- Friction with the IDE-centric workflow (config versioned separately from the code
  it configures; constant IDE↔terminal↔vault context switching).

## Decision

Move to a **decentralized, in-repo configuration** model:

1. Each project's cco config lives in `<repo>/.cco/`, versioned with the code; the
   central vault is retired.
2. Profiles are removed; optional **tags** (metadata) provide grouping. The IDE is
   the project browser; projects run concurrently.
3. A central `~/.cco/` is kept only for the user's **global resources** (authored
   packs/templates/global-claude), not project config (see ADR-0003 for why `~/.cco`
   is not a project-config hub).

## Alternatives Considered

| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Keep the vault (branch-switch), harden it** (worktree sync #6b/#6c) | Smaller change | Leaves storage/selection coupling, the no-concurrent-sessions limit, and the sanitize fragility; patches symptoms | Rejected |
| **Single filesystem + tags on the *central* vault** | Removes switch fragility; fixes concurrency | Keeps a manually-managed central repo; no per-project history / IDE-locality | Rejected (was the 2026-06-11 interim decision; superseded) |
| **Per-repo config only, no `~/.cco`** | Maximally simple | Loses cross-project sharing (packs/templates/global) and their multi-PC sync — they have no per-repo home | Rejected |
| **Decentralized in-repo config (chosen)** | Removes the whole switch/sanitize subsystem; concurrent sessions; per-project history with code; IDE-first | A large mostly-subtractive refactor + one-time migration | **Accepted** |

## Consequences

**Positive** — removes the fragile switch/sanitize/shadow subsystem (~1900 lines + a
2391-line test file); concurrent cross-project sessions; IDE-first ergonomics;
per-project config history with code; cleanly separates tool from user data (enables
future packaging).

**Negative** — a large, mostly-subtractive refactor across `cmd-vault.sh`,
`local-paths.sh`, `cmd-start.sh`, and tests; a phased teardown + a one-time
interactive migration; a deprecation window with dual-read for 1–2 releases.

## Follow-ups
ADR-0002/0003/0004 (the mechanics). Separate workstreams: cco packaging (R-pkg),
`cco update` native publish/install (R-update-native), persistent `/workspace` root.
