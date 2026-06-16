# ADR 0008 — Personal Store (`~/.cco`) Management Model

**Status**: Accepted (2026-06-16)
**Deciders**: maintainer + design session
**Context docs**: `../requirements.md` (AD10, FR-C1/C3), `../design.md` §2.3, §6.1
**Related ADRs**: 0007 (`~/.cco` as git working tree), 0006 (breaking cutover — vault
retired), 0003 (sync-as-copy — explicit, no reconciliation engine)
**Resolves**: RD-home

---

## Context

ADR-0007 settled that `~/.cco` is a git working tree holding **only authored config**
(`packs/`, `templates/`, `global/.claude/`), with state/cache/index evicted to XDG
dirs. What it deliberately left to RD-home is the **management depth**: does cco
auto-manage the git of `~/.cco` (pull-before-read / commit+push-after-write across
machines), or is sync manual? Plus conflict handling and the FR-C3 hard rule —
commit via an **explicit allowlist**, never `git add -A`.

Code-grounded analysis of the existing vault (`lib/cmd-vault.sh`, `lib/secrets.sh`,
`lib/cmd-project-publish.sh`) established three constraints:
- **Per-command foreground is already heavy** — `_check_vault` runs self-healing
  invariants and `docker ps` session guards on every vault command. Adding network git
  (fetch/pull/push) to every `cco *` would add a round-trip plus a possible blocking
  credential prompt. Synchronous per-command auto-sync is not viable.
- **Staging today is `git add -A`** (`cmd-vault.sh:140,658,2234`) with safety resting on
  a denylist `.gitignore`. The explicit allowlist FR-C3 mandates **does not exist** and
  must be built.
- **Cross-machine conflict handling is absent** — `git pull` (`cmd-vault.sh:1070`)
  trusts an implicit fast-forward; there is no merge/rebase/abort policy.
- Reusable, model-independent: `lib/secrets.sh` patterns, the 2-pass scan
  `_publish_scan_secrets` (`cmd-project-publish.sh:83`), and explicit-path staging
  (`git add -- <path>`). The profile-branch / `@local` / `switch` machinery is dropped
  by ADR-0006.

## Decision

**`~/.cco` management is manual in v1 — the `pass` model.** Local commits are
automatic; remote sync is explicit; network auto-sync is deferred.

1. **Local commits: automatic, on cco-driven mutations** (`cco pack install`, `cco
   config …`, J0 bootstrap), with structured messages — like `pass` auto-committing each
   change. Direct IDE edits are committed by the user or via `cco config save`. Staging
   is **explicit-path allowlist** (`git add -- packs/ templates/ global/.claude/`),
   **never `git add -A`**.
2. **Remote sync: explicit only** — `cco config push` / `cco config pull`, thin git
   wrappers (the `pass git push/pull` pattern). **No pull-before-read / push-after-write
   on any cco command.** Background best-effort auto-sync (detached, non-blocking,
   `GIT_TERMINAL_PROMPT=0`, skip-on-failure) is the only acceptable *managed* form and is
   **deferred to RD-triggers** (which owns auto-sync), so RD-home and RD-triggers do not
   overlap. This matches AD7 ("manual is the v1 default") and the explicit-over-magic
   spine of sync-as-copy.
3. **Allowlist enforcement — double barrier**:
   - a **committed whitelist `.gitignore`** (`*` ignored, then `!packs/`, `!templates/`,
     `!global/.claude/`, `!.gitignore`) — the canonical dotfiles pattern, stronger than
     the vault's denylist; it holds even if a user runs `git add -A` by hand;
   - **explicit-path staging** in cco's own commits.
   A path outside the allowlist is **warned, not silently skipped** (no silent caps).
   Together these guarantee machine-specific or secret files can never be pushed.
4. **Secret scan before commit/push**: reuse the 2-pass scan (filename + content) from
   `_publish_scan_secrets`, **adding an `.example` exemption** (absent today — content
   patterns like `API_KEY=` would false-positive on templates / `global/.claude`
   examples). On a hit: **block** (as publish does). The personal remote should be
   private, but the scan is defense-in-depth regardless.
5. **Cross-machine conflicts**: `cco config pull` attempts fast-forward; on non-FF or
   conflict it **aborts and notifies** ("resolve in your IDE / with git") — never an
   automatic merge or rebase. Consistent with AD8 (conflicts resolved natively) and
   sync-as-copy (no reconciliation algorithm). `~/.cco` is small and low-churn
   (authored-only), so conflicts are rare and ordinary.
6. **No active-session guard** for `~/.cco` git ops: the vault's guard existed because
   `git checkout` of a profile branch pulled the filesystem out from under a live
   session. Single-branch commit/push/pull on `~/.cco` does not move mounted files, so
   the guard is unnecessary here.
7. **Bootstrap (J0)**: first run `git init`s `~/.cco`, writes the whitelist `.gitignore`,
   and makes an initial commit. The remote is **opt-in** (`cco config remote add`); no
   credentials are assumed. Explicit `push`/`pull` use the user's normal git credential
   flow (like `pass git`).

## Alternatives Considered

| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Managed best-effort auto-sync from v1** | "Just works" cross-PC | Duplicates RD-triggers' scope; needs a daemon/lock + non-interactive auth before the manual model is even proven; per-command foreground already heavy | Rejected (deferred to RD-triggers) |
| **Manual default + `--managed` opt-in flag in v1** | Choice for power users | More surface now; the managed path still has to be designed (the non-trivial part defers to RD-triggers anyway) | Rejected |
| **Keep denylist `.gitignore` + `git add -A`** | No new code | Violates FR-C3 (explicit allowlist); weaker — one missing ignore line leaks a machine/secret file | Rejected |
| **Auto pull/push per command (synchronous)** | Always fresh | Network round-trip + blocking auth prompt on every `cco`; foreground already costly | Rejected |
| **Manual `pass` model; auto-sync → RD-triggers (chosen)** | Explicit, predictable, cheap; consistent with sync-as-copy and AD7; clean RD-home/RD-triggers split; double-barrier allowlist | No turnkey cross-PC auto-sync in v1 (acceptable — explicit `cco config push/pull` is one command) | **Accepted** |

## Consequences

**Positive** — predictable, cheap (no network on the hot path), and consistent with the
explicit-over-magic spine of the whole refactor; the double-barrier allowlist is
structurally safer than the current denylist; secret scan gains the missing `.example`
exemption; RD-home and RD-triggers have a clean boundary.

**Negative** — no turnkey background cross-PC sync in v1 (the user runs `cco config
push/pull`); a new allowlist-staging + whitelist-`.gitignore` path must be built (the
vault's `git add -A` is dropped); the `.example` exemption is new code.

## Reuse / Drop / Build-new

| Element | Verdict |
|---------|---------|
| `lib/secrets.sh` patterns; `_publish_scan_secrets` 2-pass | **Reuse** |
| Explicit-path staging (`git add -- <path>`, `git rm --cached`) | **Reuse (pattern)** |
| `git add -A` (init/save/profile-create); profile-branch/`@local`/`switch`; double-branch push/pull; `_check_no_active_sessions` for `~/.cco` | **Drop** |
| Allowlist staging (`add packs/ templates/ global/.claude/`); whitelist `.gitignore`; `.example` exemption; explicit `cco config push/pull` | **Build-new** |

## Open
None. RD-home is resolved. Background/managed auto-sync remains owned by **RD-triggers**.
