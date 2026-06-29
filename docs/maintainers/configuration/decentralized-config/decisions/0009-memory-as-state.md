# ADR 0009 — Auto-Memory Is Machine-Local STATE (cross-PC sync deferred)

**Status**: Accepted (2026-06-16)
**Deciders**: maintainer + design session
**Context docs**: `../requirements.md` (AD9, FR-S), `../design.md` §2.2, §9
**Related ADRs**: 0004 (config/state/cache separation), 0007 (system-dir locations / XDG
STATE), 0006 (breaking cutover — vault retired), 0008 (config versioning — `~/.cco` /
`<repo>/.cco` hold authored config only, no state)
**Resolves**: RD-memory — **satisfies the Phase-3 gate** (coherence review BL2)

> **Forward annotation (2026-06-29, Round 3 / S2 — migration completeness).** Decision points 2
> and 7 defer **cross-PC *sync*** of state (memory **and** transcripts) to a future opt-in feature;
> this is unchanged. They do **not** authorize discarding state during a **same-machine
> legacy→new migration** — §6 already makes this explicit for memory ("migration preserves it,
> lossless, AD12"), and the **same lossless contract applies to transcripts**
> (`session/claude-state`): `cco init --migrate` must copy them from the backup, exactly like
> memory (non-clobber, F11). The S2 audit found transcripts were not being copied (the destination
> helper existed but had no caller) and wired the missing copy. Read "not synced cross-PC" (still
> true) as distinct from "migrated locally" (required). See `../s2-migration-completeness-handoff.md`.

---

## Context

Claude Code's **auto-memory** (`MEMORY.md` + per-fact files, first 200 lines primed into
every session) is, today, the single project artifact that is both **per-project** and
**cross-PC synced**:

- it lives at `user-config/projects/<name>/memory/`, **inside the vault git work-tree**;
- it is **auto-committed** by the framework (`_auto_resolve_framework_changes`, D33,
  `cmd-vault.sh:1645-1665`, message `"vault: auto-save memory"`) and a `.gitkeep` keeps it
  tracked when empty (D32);
- it rides the vault's git remote, so it **syncs across the user's machines**;
- it is the **only** non-gitignored per-project dir (`cmd-vault.sh:43`), distinct from
  `.cco/claude-state/` (session **transcripts** — machine-local, gitignored);
- it is **excluded from `cco project publish`** (`cmd-project-publish.sh:111,475`) — so it
  has **never** been team-shared (managed policy `memory-policy.md`: *per-user, transient,
  vault-synced, **never published***).

The decentralized model separates data **by location** (ADR-0004): committed `<repo>/.cco/`
= machine-agnostic config only; per-machine **state** and regenerable **cache** move to XDG
system dirs (ADR-0007). `memory/` fit none of the new buckets — not machine-agnostic config
(it mutates every session), not `.cco/claude/` (config-only, synced by copy), not in the
ADR-0007 STATE inventory (which listed `claude-state/` but **not** `memory/`). The coherence
review flagged this as **BL2**: Phase 3 deletes the vault — i.e. the *only* mechanism that
versions and syncs `memory/` — so without a decision the cutover would be a **silent
regression** of cross-PC auto-memory. RD-memory must assign `memory/` a home (location +
versioning + transport) **before** the cutover.

A second framing question (requirements §8): *teams may want shared memory for project
state/decisions.* This is already answered by the framework's own docs-vs-memory policy:
**shared project knowledge belongs in committed docs/rules** (`<repo>/.cco/claude/rules/`,
repo `docs/`), which already ride the repo and publish via Domain B. `memory/` is the
explicitly **personal, transient** overflow — not a second team-knowledge channel.

## Decision

**Auto-memory is machine-local STATE, exactly like session transcripts. No cross-PC sync in
v1; cross-PC / cross-user state sync becomes a dedicated future opt-in feature.**

1. **memory is STATE, co-located with transcripts.** Semantically both auto-memory and
   transcripts are session/runtime **state**, not config. `memory/` joins `claude-state/`
   under the project's STATE dir (ADR-0007):
   `<state>/cco/projects/<id>/memory/` next to `<state>/cco/projects/<id>/claude-state/`.
   This **extends ADR-0007's STATE inventory** (which had listed transcripts but not memory).
2. **No versioning, no sync in v1.** memory is plain persisted files in STATE, machine-local
   and non-portable — like transcripts, which carry no git. The vault's auto-commit (D33) and
   `.gitkeep` (D32) machinery is **dropped** with the vault in Phase 3. memory simply persists
   on disk per machine; it is not committed anywhere.
3. **CONFIG stores stay state-free.** `~/.cco` and `<repo>/.cco/` hold **only** cco config the
   user authors and versions explicitly (ADR-0008). State (memory, transcripts) never enters
   them — this is the responsibility separation the whole refactor is built on. memory is
   therefore **not** placed in `~/.cco/memory/` nor committed into `<repo>/.cco/` (both were
   considered and rejected — see Alternatives).
4. **Mount.** The child-mount target is unchanged
   (`/home/claude/.claude/projects/-workspace/memory`); the **source** moves from the
   repo-relative `./memory` (`cmd-start.sh:459`) to the **host-absolute** STATE path
   `<state>/cco/projects/<id>/memory/` (coherent with the Phase-0 absolute-mounts action item
   BL3, and with transcripts already moving to STATE).
5. **Publish stays excluded** — now **structurally**: memory is no longer in the repo, so it
   cannot be published. The Domain-B exclusion is preserved by construction.
6. **Migration preserves it (lossless, AD12).** The vault backup (a raw archive of the whole
   vault dir incl. `.git` + `profile-state` shadows — ADR-0006 Dec-2, refined by V) contains
   `projects/<name>/memory/`; `cco init --migrate <project>` (Phase 2, ADR-0021) copies that
   project's memory into `<state>/cco/projects/<id>/memory/`. A one-time per-project file copy —
   no versioning. **Non-clobbering on re-run (F11).** Because memory is STATE with no sync, the
   STATE copy accumulates machine-local auto-memory after the first migrate and is the **only**
   copy; the migrate copy is therefore **copy-if-missing with confirm-gated overwrite** (the same
   non-clobbering guard the design applies to `<repo>/.cco/`, extended to the STATE target) —
   "idempotent" means a safe no-op on re-run, never a blind re-copy that overwrites newer memory.
7. **Cross-PC / cross-user state sync → future opt-in feature (R-state-sync).** The two useful
   scenarios are recorded but **deliberately deferred** and to be designed separately:
   (a) sync of memory **and** transcripts across one user's machines; (b) sync of memory among
   team members on a shared project. Treating both memory and transcripts uniformly as *state*
   means a single future opt-in transport can serve both; keeping it out of the CONFIG sync
   (ADR-0008) keeps responsibilities clean and avoids fabricating state commits in an
   author-authored history.

## Alternatives Considered

| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **memory in `~/.cco/memory/<project>/`** (rides personal store + `cco config push/pull`; memory-specific auto-commit carve-out) | Preserves cross-PC sync via Domain A with least new machinery | Injects auto-churning, machine-generated state into a store ADR-0008 defines as **authored config only**; pollutes the clean semantic history; needs an auto-commit exception ADR-0008 just rejected; conflates state with config | Rejected |
| **memory committed in `<repo>/.cco/memory/`** (rides the repo remote) | Cross-PC sync "for free"; versioned with code | Violates AD3/G8 (memory mutates every session → untruthful config diff); contaminates the sync-as-copy set (AD7) — copying memory between sibling repos is wrong; reintroduces per-repo auto-commit; duplicates the docs/rules team channel | Rejected |
| **Dedicated personal memory store** (own git + own remote + own auto-commit, decoupled from `~/.cco`) | Cleanest separation; keeps `~/.cco` history clean while preserving sync | New store + remote + sync verb = more machinery (against G4); premature before the sync feature is actually scoped | Rejected (folded into the future R-state-sync) |
| **memory is STATE, machine-local, sync deferred (chosen)** | Coherent with ADR-0004/0007/0008 (state≠config); unifies memory+transcripts as state; removes auto-commit/`.gitkeep` machinery (net reduction, G4); no diff pollution, no sync-set contamination; unblocks Phase 3 cleanly | v1 drops the vault's cross-PC auto-memory sync (accepted, reframed as a future opt-in feature); managed `memory-policy.md` must be updated at impl | **Accepted** |

## Consequences

**Positive** — clean state/config responsibility split (memory and transcripts on one side,
authored config on the other); auto-memory and transcripts are unified as STATE and live
together under `<state>/cco/projects/<id>/`; the D33 auto-commit and D32 `.gitkeep` machinery
is removed (net reduction, G4); no machine-specific churn pollutes any `git diff` and nothing
contaminates the sync-as-copy set; the Phase-3 gate (BL2) is satisfied without weakening any
prior ADR.

**Negative (the accepted regression — records BL2 / coherence review M11)** — v1 **drops** the
cross-PC auto-memory sync the vault provided (`cmd-vault.sh:1645-1665`). This is **intentional**,
not silent: state sync is reframed as a dedicated future opt-in feature (R-state-sync). Until
then auto-memory is per-machine. The managed rule
`defaults/managed/.claude/rules/memory-policy.md` (and the docs in
`docs/reference/context-hierarchy.md`) describe memory as *"vault-synced"* / list it under
`user-config/projects/<n>/memory/`; both **must be updated at implementation** (Phase 2/3) to
*"machine-local STATE; cross-PC sync = future opt-in"*.

## Reuse / Drop / Build-new

| Element | Verdict |
|---------|---------|
| Child-mount of `memory/` into `~/.claude/projects/-workspace/memory` (structure) | **Reuse** (source path → absolute STATE) |
| `_auto_resolve_framework_changes` memory auto-commit (D33); `.gitkeep` tracking (D32); vault memory tracking (`cmd-vault.sh:43`) | **Drop** (with the vault, Phase 3) |
| STATE memory path in `lib/paths.sh` (`<state>/cco/projects/<id>/memory/`); migrate-from-backup memory copy | **Build-new** |

## Open
None for v1. Deferred: **R-state-sync** — opt-in cross-PC / cross-user sync of *state*
(auto-memory **and** transcripts), scenarios (a) one user's multiple machines, (b) team members
on a shared project. To be designed separately (future evolution; not a Phase gate).
