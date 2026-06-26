# ADR 0006 — Breaking Cutover & Lazy Per-Project Migration

**Status**: Accepted (2026-06-16)
**Deciders**: maintainer
**Context docs**: `../requirements.md` (AD12, FR-S5, FR-M1, FR-M2), `../design.md` §7-§9
**Related ADRs**: 0001 (decentralization), 0002 (machine-agnostic config), 0009 (memory/secrets in backup), 0010 (profile→tag lazy/optional), 0015/0016 (backup→STATE, id-keyed state), 0021 (entry verbs / forget / cleanup)
**Refined by**: ADR-0021 + impl-readiness review V (Cluster 1: F1/F9/F10/F11/F12/F42/F43/F44);
**ADR-0025** (migration ownership — global cutover EAGER via `cco update`, per-project LAZY via
`cco init --migrate`; backup on any command; vault **removal offered only at `cco update`, default
keep**, refining D2's generic "offers to remove")

---

## Context

Moving from the central vault to decentralized in-repo config is a structural change.
A common safeguard is a **deprecation window**: keep the old layout readable at runtime
(dual-read) for 1–2 releases so existing installs keep working during a gradual cutover.
That safeguard has a real cost: dual-read code paths, "which layout wins" precedence
rules, boot warnings, and a longer-lived legacy surface — exactly the kind of
compatibility machinery this refactor is trying to delete.

The actual user base is **tiny and fully known**: two git users, both already aware of
and migrating to the new version; the repo is public but unadvertised, with no unknown
users. Migration is **lossless** (the legacy vault is archived; per-repo `.cco/` is in
git). So the usual justification for a deprecation window does not apply here.

## Decision

1. **Breaking cutover, no legacy runtime support.** The new version reads the **new
   layout only**. No dual-read, no deprecation window, no `cco vault *` alias. Legacy
   vault/profile/switch/save/diff/sanitize code is removed outright (design.md §9
   Phase 3).
2. **First-run safety net.** On first run with a legacy vault present, cco **archives
   the vault** to **`<state>/cco/backups/vault-<date>.tar.gz`** (STATE — machine-local,
   never synced, `0600`; moved out of the authored-config-only `~/.cco`, fixes C1 /
   ADR-0016 D6), informs the user, prints migration instructions, and offers to remove
   the old vault. Nothing is migrated automatically.
   **Backup form (refined by V — F1/F9).** The archive is a **raw filesystem `tar` of the
   whole vault directory as-is**, **including `.git` and the `.cco/profile-state/<branch>/`
   stash shadows** (excluding only `.cco/backups/` to avoid self-nesting). Because the
   legacy vault keeps **every** profile's gitignored secrets/local-paths on disk — the
   active profile in the working tree, the inactive profiles in their `profile-state`
   shadows (`cmd-vault.sh:1291`) — and `tar` ignores `.gitignore`, this single archive
   captures **all profiles' committed config (via `.git`) AND all profiles' secrets**.
   It is NOT a git-tree serialization (which would miss every gitignored secret) and it
   is NOT a flatten-at-save: the profile→tag flatten happens **at read time** inside the
   migrate reader. This makes the "preserves full vault history" rollback promise literally
   true. (The only inherent, accepted limit: a profile materialized only on *another*
   machine has no secrets on this disk — the multi-PC regression already accepted by
   ADR-0009.)
3. **Lazy, per-project migration.** `cco init --migrate <project> [--sync]` (ADR-0021 — the
   legacy bring-over is a **mode of `cco init`**, not the dropped top-level `cco migrate`) is
   run **inside an already-cloned repo** and is an alternative to a clean `cco init`: it
   hydrates that repo's `.cco/` from the **backup's** project config (machine-agnostic,
   read from the archived branches + shadows) and registers it in the index. The repo
   lands in **Case A** (single-config); `--sync` propagates the migrated `.cco/` to the
   project's other member repos (symmetric to `cco join [--sync]`). The user then opts into
   Case B (`cco sync`) or Case C (`cco init` other repos), or stays in A. The only reader of
   the legacy format lives inside this migrate mode. Profile→tag conversion is **lazy +
   optional** for projects (ADR-0010 §5); shared resources (packs/templates) convert
   **atomically** when `~/.cco` is populated. Write is **atomic & staged** (build under temp
   → secret-scan + gitignore-heal → atomic move into `<repo>/.cco/` → index-register last;
   cleanup partials on failure) and **non-clobbering** for both `.cco/` and STATE `memory/`
   (F11/F44). A first-run idempotency marker lives in a dedicated global STATE file
   `<state>/cco/migration-state`, with the verified `backups/` archive as the authoritative
   signal (F43). A defensive cross-resource name-uniqueness assert guards hand-edited vaults
   (F12). Resource removal/deregistration and orphan cleanup → **ADR-0021**.
4. **`cco init --migrate --all` is optional and discouraged.** It would migrate every project
   at once with no per-project A/B/C control (defaulting to B), high error risk and no
   user oversight — evaluate before adding, not part of v1.
5. **Release discipline.** Work on `feat/*` → `develop`; merge to `main` only when a
   working version is ready to release.

## Alternatives Considered

| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Deprecation window + dual-read (1–2 releases)** | Existing installs keep working during a gradual cutover | Dual-read paths + precedence rules + longer-lived legacy surface — the compatibility machinery the refactor removes; unjustified for a 2-user, known base | Rejected |
| **Eager migrate-all on upgrade** | One step, everything moved | No user control; can't choose Case A/B/C per project; high error/surprise risk; mass uncontrolled `.cco/` writes across repos | Rejected (kept only as a discouraged optional `--all`) |
| **Breaking cutover + lazy per-project migrate from backup (chosen)** | Removes all legacy machinery now; lossless backup safety net; per-project user control over A/B/C; granular and reversible | Each legacy project migrated individually (acceptable for a small base); a minimal legacy reader remains inside `cco migrate` | **Accepted** |

## Consequences

**Positive** — no dual-read/precedence/legacy-runtime code; the teardown (Phase 3) is a
clean removal; users control migration per project with a guaranteed backup; smaller,
clearer surface and test matrix.

**Negative** — a hard break: an un-migrated install of the new version will not read old
config until `cco init --migrate` is run (mitigated: known users, backup, instructions); a
minimal legacy-vault reader must live inside the migrate mode. **Plaintext secrets at rest:**
the raw backup archive (Decision 2) contains real `secrets.env`/`*.key`/`*.pem` in cleartext —
mitigated by `0600` perms and the STATE location (machine-local, never synced); must be
documented at impl. **Capability regression:**
removing the vault (Phase 3) also removes the only mechanism that today versions and
syncs `memory/` across machines (vault auto-commit). The new layout has no home for
`memory/` yet → its cross-PC sync regresses unless **RD-memory** resolves a home first.
This is recorded as an explicit **Phase-3 gate** (design §9): Phase 3 does not proceed
until RD-memory decides `memory/`'s transport + versioning.

## Open
None blocking for the cutover itself. **RD-memory gates Phase 3** (memory/ home, see
Consequences). `cco init --migrate --all` deferred (optional/discouraged). Entry-verb naming,
the `cco forget` deregister verb, the delete-cascade, and orphan sanitization are owned by
**ADR-0021** (V Cluster 1).
