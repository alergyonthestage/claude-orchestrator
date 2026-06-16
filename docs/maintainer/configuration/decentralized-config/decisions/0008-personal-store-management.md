# ADR 0008 — Config Versioning Model: Explicit Commits + Non-Blocking Reminders

**Status**: Accepted (2026-06-16)
**Deciders**: maintainer + design session
**Context docs**: `../requirements.md` (AD10, FR-C1/C3), `../design.md` §2.3, §4.4, §4.6, §6.1
**Related ADRs**: 0007 (`~/.cco` as git working tree), 0006 (breaking cutover — vault
retired, no branch switch), 0003 (sync-as-copy — explicit, no reconciliation engine),
0002 (machine-agnostic config + index)
**Resolves**: RD-home

---

## Context

ADR-0007 settled that `~/.cco` is a git working tree holding **only authored config**
(`packs/`, `templates/`, `global/.claude/`), with state/cache/index in XDG dirs.
RD-home must decide how that store — and, for coherence, the per-repo `<repo>/.cco/` —
is versioned: who commits, when, with what messages, and how cco conflict / divergence
is surfaced. FR-C3's hard rule stands: commit via an explicit allowlist, never
`git add -A`.

Two facts reshape the model (and correct an earlier draft):

1. **cco is almost never the mutator of `~/.cco`.** Its content — packs and project
   templates — is **authored by hand** (markdown/config files edited in an IDE or by the
   `config-editor` agent template). cco only **scaffolds** (`cco pack create`, template
   scaffolds); it offers no command that edits pack/template *content*. In particular
   `cco pack install` does **not** touch `~/.cco` — it installs into / edits the target
   **`<repo>/.cco/project.yml`**. So an "auto-commit on cco mutations" model both
   misfits (cco rarely mutates the store) and cannot deterministically catch the
   *primary* authoring path (direct IDE/agent edits), while flattening semantic history
   into generic messages — the opposite of the user-named snapshots authors want
   ("add my-pack", "edit another-pack with guidelines").

2. **The historical clean-tree constraint is now obsolete as a hard gate.** The old
   vault **required** a clean tree before `start` / profile `switch` / other sensitive
   ops, because those did a `git checkout` (branch switch) that could lose uncommitted
   files. Under ADR-0006 there is no branch switch, so the gate's reason is gone — it
   becomes a **non-blocking reminder**, and the user may knowingly proceed with
   uncommitted changes.

## Decision

**A single, explicit, manual commit model across both scopes, plus non-blocking
reminders at config-sensitive commands. No auto-commit in v1.**

1. **Unified explicit commits.** Both `~/.cco` and `<repo>/.cco/` are **versioned
   manually** with **semantic, user-named** commits / concrete snapshots. cco never
   auto-commits in v1.
   - `<repo>/.cco/` is committed with the user's **normal git flow** (it rides the
     repo's own remote, AD8; `git log -- .cco/` isolates config history).
   - `~/.cco` is committed with plain git or a thin **`cco config save [-m "msg"]`**
     wrapper (the `pass`/old-`vault save` UX) that does allowlist staging + secret scan;
     remote sync is **explicit** `cco config push` / `cco config pull`.
2. **Non-blocking reminders** at every config-sensitive command (the repurposed
   clean-tree check — now advisory, never blocking; the user may proceed uncommitted by
   choice). When the command involves/reads them, detect and warn about:
   - **(a)** uncommitted changes in `~/.cco`;
   - **(b)** uncommitted changes in the `<repo>/.cco/` of the involved repos;
   - **(c)** **diff / sync-state divergence between repos of the same project** — always
     when those repos are read, and specifically on `cco start` when they diverge — so
     the user knowingly picks the source (`--from`, the cwd repo, or runs `cco sync`).
     This unifies with the `cco start` divergence notice (§4.4) and the sync-state
     tracking (§4.6).
3. **Allowlist + secret scan** (for `~/.cco`; FR-C3): a committed **whitelist
   `.gitignore`** (`*` then `!packs/ !templates/ !global/.claude/ !.gitignore`) plus
   explicit-path staging in the `cco config save` wrapper; a **2-pass secret scan**
   (filename + content, reused from `_publish_scan_secrets`) with a new **`.example`
   exemption**, blocking on hit. Never `git add -A`.
4. **No auto-commit in v1.** A dedicated **future sub-analysis** may add auto-commit on
   *atomic cco commands that modify config* (e.g. `cco pack install` / `cco join`
   editing `<repo>/.cco/project.yml`), where cco knows the exact semantic and could emit
   a meaningful message. Deferred — not part of v1.
5. **Sync transports commits, never fabricates them.** `cco config push/pull` (and any
   future background auto-sync, owned by **RD-triggers**) move *already-made* commits.
   This is what keeps convenient cross-PC sync and semantic snapshots from conflicting:
   auto-sync never invents commits, so history stays author-authored. No per-command
   network sync; pull non-fast-forward → **abort + notify** (resolve in IDE), no
   auto-merge (AD8, sync-as-copy).

## Alternatives Considered

| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Auto-commit on cco-driven mutations** | "Hands-off" history | cco rarely mutates `~/.cco` (hand-authored); cannot catch direct IDE/agent edits; generic messages destroy the semantic, user-named snapshots authors want | Rejected |
| **Keep the clean-tree gate as blocking** | Forces commits | Obsolete without branch switch (ADR-0006); blocks legitimate "proceed uncommitted"; hostile UX | Rejected (downgraded to reminder) |
| **Different commit model per scope** (`~/.cco` vs `<repo>/.cco`) | Each "optimal" | Incoherent mental model; two things to learn | Rejected (unify) |
| **Managed background auto-sync in v1** | Turnkey cross-PC | Duplicates RD-triggers; needs daemon/lock + non-interactive auth before manual is proven; per-command foreground already heavy | Rejected (→ RD-triggers) |
| **Unified explicit commits + non-blocking reminders (chosen)** | Coherent across scopes; semantic user-named snapshots; advisory not blocking; sync transports (never fabricates) commits; allowlist double-barrier | No turnkey auto-sync / auto-commit in v1 (acceptable; one explicit command each) | **Accepted** |

## Consequences

**Positive** — one coherent versioning model for both scopes; authors keep semantic,
named history; the reminder is helpful but never in the way; convenient sync and clean
history are decoupled (sync moves commits, never fabricates them); the allowlist
double-barrier is structurally safer than the old denylist; secret scan gains the
missing `.example` exemption.

**Negative** — no turnkey background sync or auto-commit in v1 (the user runs explicit
commits + `cco config push/pull`); a reminder aggregator (uncommitted `~/.cco`,
uncommitted involved `<repo>/.cco`, cross-repo divergence) must be built; the allowlist
staging + whitelist `.gitignore` + `.example` exemption are new code (the vault's
`git add -A` is dropped).

## Reuse / Drop / Build-new

| Element | Verdict |
|---------|---------|
| `vault save` explicit-named-snapshot UX (message, change detection via `git status`) | **Reuse** (→ `cco config save`) |
| `lib/secrets.sh` patterns; `_publish_scan_secrets` 2-pass; explicit-path staging | **Reuse** |
| Clean-tree check (`_check_no_active_sessions`/dirty-tree) | **Reuse, downgraded** to a non-blocking reminder |
| `git add -A`; profile-branch/`@local`/`switch`; double-branch push/pull | **Drop** |
| Allowlist staging; whitelist `.gitignore`; `.example` exemption; reminder aggregator (uncommitted ×2 + cross-repo divergence); `cco config push/pull` | **Build-new** |

## Open
None for v1. Deferred: **auto-commit on atomic config-mutating cco commands** (future
sub-analysis); **background/managed auto-sync** (owned by **RD-triggers**).
