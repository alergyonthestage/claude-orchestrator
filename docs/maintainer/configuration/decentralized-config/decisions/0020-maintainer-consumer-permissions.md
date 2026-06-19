# ADR 0020 — Maintainer vs consumer permissions: delegate enforcement to git, cco assists

**Status**: Accepted (2026-06-18)
**Deciders**: maintainer + design session (S), with git-platform research
**Context docs**: `../guiding-principles.md` (P7 sync mechanics / access delegated to git — **P17 added
by this cycle**), `../decisions/0008-…` (access delegated to git), `../decisions/0018-…` (sharing
surface), `../decisions/0019-…` (pack lifecycle)
**Related ADRs**: 0008 (sync transports commits; access delegated to git — the principle this ADR
extends from *auth* to *write*), 0018 (sharing repo vs project repo), 0013/0015 (de-tokenized remotes
→ DATA; token → STATE `0600` `never`)
**Resolves**: how cco expresses the **maintainer (write) vs consumer (read)** distinction for shared
cco resources, distinguishing the **sharing repo** (clean split) from the **project repo**
(co-writable `<repo>/.cco`). **Hands off**: **E** (optional `cco config protect` scaffold; guide copy),
**S8 audit** (no-token-leak — confirmed here, executed in E).

> The take-away in one line: **cco delegates permission *enforcement* to the git host (exactly as it
> delegates *auth* — P7); cco's value-add is setup *assistance*, never a parallel gatekeeper.**

---

## Context

Team work needs a way to choose who may **write** (maintainers) vs who may only **read/consume**
(consumers) cco resources. The decentralized model has **two** repo kinds with different governance:

1. **Sharing repo** — a dedicated repo for packs/templates (ADR-0018). It has its **own** access
   control: read/write at the git-host level. Natural and clean.
2. **Project repo** — the application code repo, where `<repo>/.cco/` lives **co-mingled** with the
   code (P5, team-shared by construction). Here `<repo>/.cco/` is **writable by anyone who can write
   the code**; there is no cco-level distinction between editing the cco config and editing the code.

The maintainer asked whether per-resource granularity is achievable, and how any cco permission
mechanism would intersect with the **already-approved plain-git sync** (P7/ADR-0008). Research into
GitHub/GitLab/Gitea established the enforcement realities; this ADR settles the design stance.

---

## Decision

### D1 — Enforcement is delegated to the git host (P17); cco is never a gatekeeper

cco **does not** and **must not** implement its own write-permission enforcement. The approved sync is
**plain git + remote** (P7/ADR-0008): cco is **not in the push path**, so it *cannot* gate a push
without becoming a server-side hook — which would **contradict** the plain-git model. This is the same
delegation cco already uses for **auth** (tokens / SSH): now extended to **write access** (P17). The
git host enforces; cco delegates. Concretely, this *already works*:

- **Sharing repo:** a consumer holding a **read-only token** simply **cannot push** — the host rejects
  it. The maintainer/consumer split is enforced by the host, with **zero** cco machinery.
- **Project repo:** the developer's git credentials (plus any host rulesets) decide whether they may
  push a `<repo>/.cco/` change — governed by the **code repo's** existing rules.

### D2 — Sharing repo: whole-repo read/write is primary; granularity via repo-splitting + token scope

- **Whole-repo read/write** is the primary, cross-platform model (simplest mental model). Write =
  maintainer (push token), read = consumer (read token / public).
- **Granular *read* hiding** is achieved by **splitting into multiple sharing repos** per audience
  (different resources for different teams in different repos) — a host-native, portable mechanism, no
  cco feature needed.
- **Granular *write*** (per-pack maintainership inside one repo) is possible via host path-rules
  (GitHub Rulesets, Gitea protected-path patterns) but is **advanced/optional** and **documented**, not
  cco-enforced (**YAGNI** for v1).

### D3 — Project repo: accept co-writability of `<repo>/.cco/`; config is intentionally unified

- **Accept co-writability** of `<repo>/.cco/` by design: it is co-committed with the code (P5), with
  no publish boundary — the precedent is Claude Code's own `.claude/`, which rides repo governance
  as-is. Project config is **intentionally unified**: one project may serve one *or more* teams, but
  the config stays a single shared surface (1 project = 1+ teams, unified config).
- The **only** distinction a team may want is **who may edit `<repo>/.cco/`** (a cco-maintainer role
  within the code repo). This is achievable with the **host's** path-scoped rules + **CODEOWNERS**
  (review routing) on a protected branch — **delegated to git**, not a cco mechanism.

### D4 — cco's value-add = setup assistance, not enforcement

cco may help a team **set up** the host's protection without ever enforcing it:

- **`cco config protect`** (optional, → E) — scaffolds a **`<repo>/.cco/CODEOWNERS`** and **prints
  platform-specific instructions** to protect `.cco/**` (GitHub Rulesets + required CODEOWNERS review;
  Gitea protected-branch file patterns; GitLab pre-receive / push rules). It **configures**, the host
  **enforces**.
- **Baseline = documentation** of the manual setup; the helper is a convenience.
- **Footgun** (a developer with code-write silently alters `<repo>/.cco/`, affecting teammates' cco
  sessions) is mitigated by: (a) `cco config validate` (ADR-0019 D2) surfacing breakage; (b) the change
  being a **visible diff in the PR** (truthful `git diff`, G8); (c) the recommended CODEOWNERS
  convention. cco surfaces; it does not block.

> **CONTRACT PINNED + ship-in-v1 RESOLVED by ADR-0023 D6 (2026-06-19; the D4 text above is kept as
> written):** v1 ships **documentation only**; the `cco config protect` helper is **deferred (post-v1)**
> (confirms the §Open recorded preference). **Location corrected**: the scaffolded CODEOWNERS goes to a
> **host-recognized** path — repo-root `CODEOWNERS` or `.github/CODEOWNERS`, **never**
> `<repo>/.cco/CODEOWNERS` (GitHub does not honor `.cco/`) — with `/.cco/** @org/cco-maintainers`,
> host-detected from `origin` (`lib/remote.sh`). The footgun-surfacing check is **`cco project validate`**
> (the share-readiness verb renamed by ADR-0023 D1), not `cco config validate`.

### D5 — No-token-leak invariant (S8, confirmed; executed in E)

The maintainer/consumer split must not leak the auth token. Confirmed invariants (audit in E):

- Token lives **only** in STATE (`remotes-token`, `0600`, `never`-sync — ADR-0013/0015); never in a
  config bucket, a bundle, the DATA `remotes` registry, or a `source` file.
- Coordinates in manifests, the DATA `remotes` registry, and `source` files are **de-tokenized** (url
  only); auth is resolved at git-invocation time by `url → token` lookup (reuse `_build_git_auth`,
  credential-helper disabled).
- A published bundle is **config-only** (ADR-0016 D8) → DATA/STATE are never copied → no leak by
  construction. S8 = a **checklist + tests**, not a new mechanism.

---

## Principles & method-lessons (persisted — guiding-principles P17)

- **P17 (delegate enforcement to git; cco assists, never gatekeeps)** — permission enforcement (write
  vs read) is the git host's job, exactly as auth is (P7). cco must not build a parallel permission
  system: it is not in the push path, and doing so would contradict the approved plain-git sync.
- **Method:** the two repo kinds map to two governance models — sharing repo = its own clean read/write
  split; project repo = the code repo's existing governance (co-writable `.cco/`, optional CODEOWNERS).
  This mirrors the **resource asymmetry** (P13): governance follows the resource's home.
- **Bias to avoid:** "team needs granular permissions → cco should implement them." The intersection
  with plain-git sync makes a cco-native enforcer self-defeating. The right move is *assist setup*,
  *delegate enforcement*.

## Facts (git-host enforcement reality, 2026-06-18 research)

| Platform | Per-path **hard** write block | CODEOWNERS nature |
|---|---|---|
| **GitHub** | **Yes** — Rulesets (fnmatch path) + required CODEOWNERS review on protected branch | **Review routing**, not a raw write gate; enforced only via branch protection |
| **Gitea** | **Yes** — protected-branch file-pattern (glob) | No native CODEOWNERS; use protected-path patterns |
| **GitLab** | Partial — push rules are filename-regex only; path-scoped block needs a **pre-receive hook** | Code Owners **advisory**, bypassable with push&merge |
| **generic git** | Yes via server-side `pre-receive` hook | n/a |

**Key fact:** CODEOWNERS is *review routing*, **not** a hard write gate by itself. Hard per-path
enforcement requires Rulesets / protected-path patterns / pre-receive hooks — all **host** features.

## Alternatives Considered

| Alternative | Pros | Cons | Verdict |
|---|---|---|---|
| **cco-native permission enforcement** (cco gates writes/pushes) | uniform across hosts | cco isn't in the push path; would require a server-side hook → **contradicts plain-git sync (P7)**; reinvents what the host already does | **Rejected** (D1/P17) |
| **Per-pack write granularity inside one sharing repo as a v1 feature** | fine control | host-specific, advanced; whole-repo + repo-splitting covers real needs | **Rejected for v1** (YAGNI; documented as advanced — D2) |
| **Forbid co-writable `<repo>/.cco`** (separate cco-config repo per project) | strict maintainer/consumer split | re-introduces a central/separate project store (vault-like); contradicts P5 decentralization | **Rejected** (D3) |
| **Delegate to git + optional `cco config protect` assist (chosen)** | coherent with P7/plain-git; zero gatekeeper; gives teams the "official cco method" as setup help | enforcement quality varies by host (documented) | **Accepted** |

## Consequences

**Positive** — the permission model is coherent with the approved plain-git sync (no conflict); the
clean maintainer/consumer split is *already* enforced for the sharing repo by token scope; teams get
granular read-hiding via repo-splitting and an optional `cco config protect` helper for the project-
repo case; the token-leak invariant is pinned. **Negative** — enforcement quality varies by git host
(documented, not cco's to fix); `cco config protect` is net-new (optional, → E); the project repo's
`<repo>/.cco/` remains co-writable by design (mitigated, not eliminated).

## Reuse / Drop / Build-new

| Element | Verdict |
|---|---|
| token scope for sharing-repo read/write (host-enforced) | **Reuse** (already the model) |
| `_build_git_auth` (token at git-invocation, credential-helper disabled) | **Reuse** (de-tokenized coordinates, D5) |
| `cco config protect` (scaffold CODEOWNERS + emit host instructions) | **Build-new** (optional, → E) |
| S8 no-token-leak checklist + tests | **Build-new** (verification, → E) |

## Open (deferred, not unresolved)

- **E** — optional `cco config protect` (CODEOWNERS scaffold + platform instructions); guide copy for
  the sharing-repo vs project-repo governance split; the S8 no-token-leak checklist + tests.
- **Decision (maintainer):** ship `cco config protect` in v1, or document the manual setup only and
  record the helper as a near-term addition. *(Recorded preference: documentation baseline + the helper
  as an opt-in addition.)*
