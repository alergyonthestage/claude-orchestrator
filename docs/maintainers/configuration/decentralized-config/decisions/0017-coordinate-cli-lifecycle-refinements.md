# ADR 0017 — Coordinate fields, CLI consolidation & lifecycle refinements (M review)

**Status**: Accepted (2026-06-17)
**Deciders**: maintainer + design session
**Context docs**: `../guiding-principles.md` (P3 Axis-1 public-repo — **resolved here**; P5/P12),
`../design.md` §2.4/§3/§4/§6/§7/§8/§9/§12, `../decisions/0016-…` (coordinate model — this ADR
**completes** its D2 field semantics and confirms ADR-0014's open `ref` question), `../reviews/
16-06-2026-design-coherence-review.md` (M6 J0 bootstrap, H8 join Case-C)
**Related ADRs**: 0002 (machine-agnostic config + index), 0003 (sync-as-copy), 0006 (breaking cutover,
J0/migration), 0007 (XDG bases incl. DATA; `~/.cco` dotdir-as-git-repo), 0008 (personal-store mgmt,
opt-in remote), 0014/0016 (referenced-resource coordinate model)
**Resolves**: a batch of M-review refinements raised by the maintainer (coordinate field semantics;
CLI consolidation; first-run lifecycle; `~/.cco` git/remote policy incl. the **P3 Axis-1 public-repo**
open question). **Hands off**: **S** (Domain-B Config-Repo realignment, coordinate CLI/validate
mechanism, public-remote warning), **T** (DATA/STATE sync-engine choice + daemon), **E** (impl).

> This ADR records *refinements*, not a new architecture: it completes the coordinate field semantics
> ADR-0016/0014 left open, consolidates the command surface onto the verb users already know, makes the
> first-run bootstrap account for the 4th bucket, and fixes the `~/.cco` git/remote policy.

---

## Context

The M consolidation (ADR-0016) settled the resource taxonomy and the coordinate *placement*. A
maintainer review then surfaced concrete gaps the taxonomy did not cover: the **field-level
semantics** of the embedded coordinate (is `url` mandatory? what is `ref`? may it differ from the
clone's actual remote?); a **command-surface drift** (`cco project resolve` vs the new `cco resolve`
vs `cco index refresh --scan`); an under-specified **first-run on a fresh machine** (who creates the
XDG dirs, including the new **DATA** bucket, and when); and the **`~/.cco` git/remote policy** (always
versioned? public remote allowed?). Each is decided below. Out-of-scope expansions the review raised
are recorded as futures (so the v1 design enables them) and handed to their owning analysis.

## Decision

### D1 — Coordinate field semantics (completes ADR-0016 D2 / confirms ADR-0014's open `ref`)

For the per-unit coordinate embedded in `project.yml`/`pack.yml` (uniform schema, ADR-0016 D2):

- **repo `url` is OPTIONAL.** It is a **persisted bootstrap pointer** (the canonical clone source for
  other PCs / teammates), not a hard requirement. Its presence drives `cco resolve` (D2):
  - `url` present → resolve offers **specify local path** *or* **auto-clone from `url`** into a chosen
    path;
  - `url` absent → resolve offers **specify local path** only.
- **repo `ref` is OPTIONAL** — the git ref (branch/tag/commit) to check out on **auto-clone** (the
  repo analog of llms `variant`). Default = the remote's **default branch** (no `ref` ⇒ clone
  default). It is machine-agnostic (a logical ref, not a path).
- **llms `url` is MANDATORY** in v1 (+ optional `variant`); a hand-curated, local-file llms with no
  `url` is **not supported** (ADR-0014 D1) — recorded as a future (§Futures).
- **Derivation convention = `origin`.** `cco join` and the integrity check derive a repo's canonical
  `url` from `git remote get-url origin` (reusing `_sanitize_project_paths`). If there is **no
  `origin`** or the choice is ambiguous (multiple remotes), derivation **prompts or leaves the field
  unset**; the user may set the canonical `url` explicitly. The manifest holds **exactly one**
  canonical `url` per repo.
- **The manifest `url` MAY differ from the local clone's actual remote** — and this is **allowed**.
  The manifest `url` is the *canonical source-for-sharing*; the clone's `origin` is *this machine's
  reality*. They legitimately diverge (ssh-vs-https of the same repo, a personal fork, a mirror).
  Therefore the integrity check (`cco config coords --diff` / `cco config validate`, ADR-0016 D3/D9)
  **warns on mismatch, never enforces equality** — a mismatch may flag a typo or an unintended fork,
  but is not an error. This is consistent with "repos self-heal": the `url` is a bootstrap pointer,
  not a rigid mirror.

### D2 — CLI consolidation onto `cco resolve`; `cco start --from`

Converge the path-resolution surface on the verb users already know (today `cco project resolve`),
replacing the M-era split (`cco resolve` + `cco index refresh --scan`):

- **`cco resolve [project]`** — interactively resolve each unresolved repo/mount of the project
  (specify local path · clone-from-`url` · skip). Default scope = the cwd/named project.
- **`cco resolve --scan <dir>`** — auto-discover by scanning `<dir>` for `.cco/project.yml` and
  (re)build the index. **Absorbs** `cco index refresh --scan` (drop that name; `--scan` is a flag of
  `resolve`).
- **`cco resolve --all`** — scope all known projects.
- **`cco path set/list`** — retained as the **low-level** index editor (move dirs, fix divergence,
  external installs).
- **`cco start [project] [--from <repo>]`** — `--from` explicitly selects which member's `<repo>/.cco`
  to use, mirroring `cco sync --from`. **Source precedence for Case C (divergent):** `--from` > the
  optional `entry` repo > prompt. (Cases A/B are unambiguous, ADR-0003.)
- **`cco start` with unresolved paths → explicit prompt**, not a silent launch: (a) **resolve now**
  (hand off to `cco resolve`), or (b) **proceed without mounting the unresolved entries** (with a
  warning). This differs from the silent-empty-mount bug #B17/#B18 forbade: here the skip is a
  **conscious user choice**, surfaced — not a silent `continue`.

> **`--scan` semantics SPECIFIED by ADR-0022 D3 (F38, 2026-06-19; the text above is kept as written):**
> `--scan` is an **upsert / reconcile**, **not** a wholesale rebuild — read "(re)build" as "reconcile". It
> upserts each discovered `name→path` + `repos[]`, **never deletes** out-of-`<dir>` mappings or `cco path set`
> overrides, and on a name-already-bound-to-a-different-path conflict applies **AD5**: warn + keep-existing
> (optionally prompt), never silent overwrite. Bootstrap (empty index) is the trivial degenerate case. No
> `--prune` in v1 (stale-entry GC reserved as a future enabler — would re-add surface this D2 is shrinking).

### D3 — First-run lifecycle (J0): any command bootstraps all 4 buckets

The first-run global bootstrap (journey J0, design §8) is refined for the 4-bucket model:

- **Any `cco` command** on a fresh machine (including `cco start` **and** `cco init`) runs the J0
  bootstrap **first**. `cco init` is **not special** — it does not own system-dir creation.
- J0 creates **all four** roots when missing: `~/.cco` (git-init'd, D4) **and** the three XDG internal
  bases **including DATA** (`~/.local/share/cco`) — not just STATE/CACHE (which predated the DATA
  bucket). Creation is **idempotent and per-root** (review M6): a missing single root is created
  without disturbing the others.
- **Packaging-forward (R-pkg).** When cco ships as an npx/npm package + image (users no longer clone
  `claude-orchestrator`; only maintainers do), J0-on-first-use remains the system-dir init point. An
  explicit `cco setup` command is an **optional future** convenience, not required by v1.

### D4 — `~/.cco` is always a git working tree; remote opt-in & private-default; public allowed with a warning (resolves P3)

- **`~/.cco` is ALWAYS `git init`'d and versioned** in place (ADR-0007's dotdir-as-git-working-tree).
  Versioning is not optional; what is optional is the **remote**.
- The remote is **opt-in and private by default** (ADR-0008). **A public remote is ALLOWED by
  explicit user choice, with a warning** — cco does not (and practically cannot) enforce privacy, and
  forbidding a public personal remote would be excessive. The guides **document and recommend** that
  team-sharing happens via dedicated **Config Repos** (Domain B), *outside* `~/.cco`, which holds the
  user's **personal global config** only.
- This **resolves the P3 open question** ("Axis-1 public-repo: forbid / allow / escape-hatch") →
  **allow + warn**. The warning mechanism is owned by **S**.

## Futures (recorded so the v1 design enables them; handed to owners)

| # | Future capability | Why deferred | Owner / enabler |
|---|---|---|---|
| F1 | **Local-file llms** (no download `url`; an existing local `.txt`) | no code path / no concrete need v1 (ADR-0014 D1) | future; the manifest schema is extensible (add a `path:`/`local:` field) |
| F2 | **Case-C convergence merge** — opt-in assisted merge to fold divergent `.cco/` back to B/A | v1 sync is deliberately copy-only (ADR-0003) | future; **reuses** `cco update`'s 3-way merge engine + sync-state tracking (§4.6) — v1 does not preclude it |
| F3 | **Domain-B Config-Repo structure realignment** — clean/align the team-shared repo layout to the decentralized model (manifest removed; coordinate resolve-at-publish; structure-based discovery) | not in this cycle | **S** (publish/install/update/export revision + opinionated-defaults-as-package) |
| F4 | **DATA/STATE sync-engine choice** — git is a *recommendation* (ADR-0015 D6), not a constraint; a more appropriate engine may exist | needs dedicated analysis | **T**, evaluated **transversally** with the project-sync **daemon** (RD-triggers) — different scopes, possibly shared infra |

## Alternatives Considered

| Alternative | Pros | Cons | Verdict |
|---|---|---|---|
| **Enforce manifest `url` == clone `origin`** | strong integrity | breaks ssh/https forms, forks, mirrors; the manifest is shared-truth, the local remote is per-machine reality | **Rejected** (warn, not enforce — D1) |
| **Keep `cco index refresh --scan` as a separate verb** | literal | a third path-resolution verb users must learn; `cco resolve` is the known one | **Rejected** (fold into `cco resolve --scan` — D2) |
| **`cco start` hard-fails on any unresolved path** (current #B17 guard) | no silent empty mounts | too rigid — a user may legitimately want to start with a subset mounted | **Refined** (explicit prompt: resolve | proceed-without+warn — D2) |
| **`cco init` owns system-dir creation; `cco start` assumes it ran** | one init entry | a fresh user who clones a shared repo and runs `cco start` never ran `init` → broken | **Rejected** (J0 on *any* command — D3) |
| **Forbid / enforce-private `~/.cco` remote** | "guaranteed" privacy | unenforceable in practice; excessive; blocks a legitimate explicit choice | **Rejected** (allow + warn — D4) |

## Consequences

**Positive** — the coordinate's field semantics are pinned (optional `url`/`ref`, mandatory llms
`url`, `origin` derivation, warn-not-enforce integrity), closing ADR-0014/0016's open `ref`/url
questions; the path-resolution surface collapses onto the familiar `cco resolve`; `cco start --from`
gives a no-prompt Case-C source; first-run is correct on a truly fresh machine and creates the DATA
bucket; `~/.cco` git/remote policy is fixed and **P3 is resolved**; four future capabilities are
recorded with enablers so v1 does not paint them out.

**Negative** — small CLI surface changes (rename/fold `index refresh`; add `--from` to `start`; add
the unresolved-start prompt) and the J0 DATA-bucket addition are impl work (→ E); the public-remote
warning and the Domain-B realignment are new work (→ S); the DATA/STATE engine choice stays open (→ T).

## Reuse / Drop / Build-new

| Element | Verdict |
|---|---|
| `_sanitize_project_paths` `git remote get-url origin` derivation | **Reuse** (for `join` + integrity warn) |
| existing `cco project resolve` interactive resolver (`_project_effective_paths`, `_assert_resolved_paths`) | **Reuse / rename** → `cco resolve`; add the proceed-without-unresolved branch |
| `cco index refresh --scan` as a standalone verb | **Drop** (fold into `cco resolve --scan`) |
| J0 bootstrap (design §8) | **Refactor** — add DATA; assert "any command, idempotent per-root" |
| `cco start --from`; the unresolved-start prompt; the `~/.cco` public-remote warning; `cco setup` (optional) | **Build-new** (mechanism → S/E) |

## Open (deferred, not unresolved)

- **S** — the public-remote **warning** copy/trigger; the Domain-B Config-Repo **realignment** (F3);
  the coordinate **CLI** (`cco repo/llms add`, `cco config coords`) + **`cco config validate`** from
  ADR-0016 D3/D9 (where these field semantics are enforced/warned).
- **T** — the DATA/STATE **sync-engine** choice (F4), evaluated with the daemon (RD-triggers).
- **E** — `cco resolve`/`--scan`/`--all` consolidation; `cco start --from` + unresolved-start prompt;
  J0 DATA bucket + per-root idempotency (M6); ref/`origin`-multiple-remote handling at impl.
