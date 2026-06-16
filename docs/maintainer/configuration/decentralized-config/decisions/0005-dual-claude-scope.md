# ADR 0005 — Dual `.claude` Scope (project vs repo-local)

**Status**: Accepted (2026-06-15)
**Deciders**: maintainer + design session
**Context docs**: `../requirements.md` (AD4), `../design.md` §2.1
**Related ADRs**: 0001 (decentralization), 0003 (sync-as-copy), 0004 (separation)
**Open question owned**: RD-claude-mount (Phase-0 mount-resolution detail) — **resolved 2026-06-16**, see Resolution below

---

## Context

Claude Code loads `.claude` config from two places in a cco session: the WORKDIR
`/workspace/.claude` (always loaded) and each nested `/workspace/<repo>/.claude`
(on-demand). A decentralized model must decide where a project's **cross-repo** Claude
config lives (shared rules/agents/skills for the whole session) versus a repo's **own**
Claude config (specific to that one repo), and how each maps into the container.

The adversarial review (finding C4) noted that `/workspace/.claude` is a **single mount
slot** (`lib/cmd-start.sh:454`) and that packs already inject files into that same tree
(`lib/packs.sh`), so the *mount-resolution mechanics* need care. That mechanics detail
is deferred to RD-claude-mount; the *scoping decision* itself is settled here.

## Decision

Two distinct `.claude` trees with distinct scope and mapping:

1. **Project / cross-repo Claude config** lives at `<repo>/.cco/claude/` and maps to
   `/workspace/.claude`. It is part of the committed, sync-as-copy project config
   (ADR-0003) and is the cross-repo session scope.
2. **Repo-local Claude config** stays at `<repo>/.claude/` (repo root, Claude Code
   native) and maps to `/workspace/<repo>/.claude`. It is committed in that repo, is
   **never** part of project config, and is **never** synced across repos.
3. Under sync-as-copy + no-privileged-repo (ADR-0003), the `/workspace/.claude` mount
   source is the **invoking (cwd) repo's** `.cco/claude/`. The exact mechanics of
   composing that single mount with pack-injected files in the same tree are owned by
   **RD-claude-mount** (a Phase-0 check), not decided here.

## Alternatives Considered

| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Single `.claude` per repo, no project scope** | One tree to reason about | No place for cross-repo session config; every repo would duplicate shared rules/agents | Rejected |
| **Project Claude config only in a central store (`~/.cco`)** | One copy | Re-centralizes project config (contradicts ADR-0001/0003); not versioned with the code | Rejected |
| **Dual scope: `.cco/claude/` (project) + `<repo>/.claude/` (repo-local) (chosen)** | Maps cleanly onto Claude Code's WORKDIR + nested loading; cross-repo config versioned with code and sync-as-copy'd; repo-local config stays put and unsynced | Two trees to understand; single `/workspace/.claude` mount slot needs careful composition with packs (→ RD-claude-mount) | **Accepted** |

## Consequences

**Positive** — cross-repo config has a clear home (versioned with code, synced by
copy); repo-local config is unambiguous and never leaks across repos; the model maps
directly onto Claude Code's native resolution.

**Negative** — the single `/workspace/.claude` mount must compose the cwd repo's
`.cco/claude/` with pack-injected files without bind-mount shadowing; this is an
explicit Phase-0 item (RD-claude-mount), not a silent risk.

## Resolution — RD-claude-mount (2026-06-16)

Code-grounded verification (`lib/cmd-start.sh`, `lib/packs.sh`, `lib/llms.sh`).

**Mechanism.** `/workspace/.claude` is a single **rw directory** bind-mount
(`cmd-start.sh:454`). Pack/llms resources are **nested bind-mounts** overlaid at
deeper paths inside that tree — `/workspace/.claude/{packs/<n>, llms/<n>, rules/<f>,
agents/<f>, skills/<d>}`, all `:ro` (`packs.sh:98-130`, `llms.sh:118`). Docker Compose
applies mounts ordered by destination-path depth (parent before child), so the nested
overlays compose *on top of* the parent without hiding its sibling content. **This is
the behavior today and is proven.**

**Shadowing verdict: NEGATIVE.** This ADR + ADR-0003 change only the *source* of the
parent mount (central `projects/<name>/.claude/` → cwd repo's `.cco/claude/`). The
nested-overlay composition is **source-agnostic**, so changing the source introduces
**no new bind-mount shadowing**. RD-claude-mount does not block Phase 0 as a shadowing
risk.

The single-mount move does, however, surface three adjacent items the central model hid:

- **F1 — derived files must leave the committed tree.** `_start_generate_metadata`
  writes `.claude/packs.md` (`cmd-start.sh:586`) and `.claude/workspace.yml`
  (`648-649`) *into* the mount-source dir. Under the decentralized model the source is
  the committed, sync-as-copy `.cco/claude/` (ADR-0003), which must stay
  machine-agnostic (ADR-0002) and config-only (ADR-0004). **Decision:** generated files
  are NOT written into `.cco/claude/`; they are produced in a machine-local **cache**
  dir (location → RD-paths) and overlaid with the same nested `:ro` mechanism as packs
  (`<cache>/packs.md:/workspace/.claude/packs.md:ro`, idem `workspace.yml`). Keeps the
  committed tree pristine and the `git diff` truthful.
- **F2 — reserved namespaces.** `packs/` and `llms/` (and pack-supplied filenames in
  `rules/`/`agents/`/`skills/`) are **framework-reserved** within `/workspace/.claude`;
  committed config must not author into them. Within-pack collisions are warned by
  `_detect_pack_conflicts`; cross-tree (committed-config vs pack) collisions are not
  detected today — add a warning at implementation time. Precedence: a pack `:ro`
  overlay wins over a committed file of the same path.
- **F3 — parent stays rw.** In-session edits to cross-repo config must land in the cwd
  repo's `.cco/claude/` for commit, so the parent mount stays rw; pack/llms overlays
  stay `:ro` (central registry, not editable in-session).

F1 has a soft dependency on RD-paths (the cache location) but the *decision* — never
generate derived files into committed config — is independent and locked here. F1/F2
become Phase-0/early-impl action items; F3 is a recorded invariant.

**Status: resolved.** Open question owned by this ADR is closed.
