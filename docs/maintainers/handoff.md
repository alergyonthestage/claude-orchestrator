# Handoff — 2026-09-01 · A10 design approved and **merged**. Next session builds A10.1.

> **Ephemeral.** The previous handoff was deleted before this was written. It links **out** to the
> roadmap, ADRs, design and analysis — nothing links back to it.
>
> Written for a session that remembers **nothing** of the one that produced it. Everything below is
> either measured and cited, or named as unmeasured.

## Where we are

**Phase: Design → CLOSED AND APPROVED (2026-09-01, with three amendments, all already applied).
Next is Implementation + Test of A10.1.** No decision is left open for the maintainer before
implementation starts. The maintainer's instruction closing the design session was explicit:
*"procediamo con l'implementazione in una nuova sessione, design approvato."*

```mermaid
flowchart LR
    AN["analysis approved ✅<br/>2026-08-27"] --> CL["decision clinic ✅<br/>3 rounds · 6 rulings<br/>now HISTORICAL"]
    CL --> ADR["ADR-0060 + design ✅"]
    ADR --> GATE["design gate ✅ 2026-09-01<br/>approved · 3 amendments"]
    GATE --> A101["A10.1 · identity<br/>⬅ BUILD THIS"]
    A101 --> A102["A10.2 · protection + tooling"]
    A102 --> A9["A9 · FI-77"]
```

Order inside Block A: **A1 → A11 → A10.1 → A10.2 → A9**, then A2 · A3 · A6 · A7, with **A12**
(`cco doctor`, split out of A10 at its design gate) schedulable independently.
⚠ **The numbers are identifiers, not the order.**

### State, measured

| Claim | Measured |
|---|---|
| Branch | `feat/devmode/dev-execution-mode` — ✅ **MERGED into `develop` on 2026-09-01**, after the maintainer approved the gate. Merged with `--no-ff`, so the gate is visible in history. ⚠ **No sha or commit count is stated here on purpose** — the commit that states one invalidates it. Measure: `git log --merges -1 develop` and `git rev-list --count origin/develop..develop` |
| ⚠ The branch is **NOT deleted**, deliberately | `rules/git-practices.md`: the consolidation trigger is *"the branch appears among the merged"*, and deleting makes it unreachable **forever**. **A1 was deleted before its consolidation and its roadmap entry is still stranded** because of exactly this. The next `/handoff` consolidates first, **then** deletes with `git branch -d` (never `-D`) |
| Push | 🔴 **STILL OWED.** `develop` was level with `origin/develop` before the merge and is now **ahead of it**. Push is **not possible from a session** — `origin` is SSH, `credential.helper` unset, `gh auth status` → not logged in. **Host step**: `git push origin develop` |
| Pre-merge verification | the suite was run **on the branch before the merge**, not assumed from the previous session |
| Suite | Unchanged since A11: **1787 passed / 7 failed / 1794**, the 7 the documented host-only set **name for name**. Run it with `bin/test` (dry-run, no Docker). ⚠ Verify the `Results:` line exists — an aborted run reads green *and prints no summary* |
| What this branch contains | A11's code (2 commits) **plus documents only**. The design sessions changed **no code** |
| git in this container | needs `safe.directory`: `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=/workspace/claude-orchestrator git …` |

⚠ **`feat/claude-view-file-overlays` is rares' branch and stays untouched.**

## Gates still open

| Gate | What unblocks it |
|---|---|
| ✅ ~~**Merge this branch**~~ | **CLOSED 2026-09-01** — approved by the maintainer and performed |
| 🔴 **Push `develop`** | **not possible from a session** (measured above). **Host step**: `git push origin develop` |
| **Delete the merged branch** | owed to the **next** `/handoff`, which must consolidate A11 + the A10 design into `roadmap-history.md` and memory **first**. Deleting before that makes the trigger unreachable, as it did for A1 |
| **[FI-83](improvements.md)** direction | trigger measured; the cheap candidate touches no security surface. Needs one more observation and a call — see *Context* |
| **[FI-84](improvements.md)** | free to relieve locally (move `user-config/`); the design half must be decided **with [FI-16](improvements.md)** |
| **[FI-78](improvements.md)** | the 2 macOS test-portability failures. ⚠ **Host-only measurable**. **Owed before `0.7.0`** |
| **[FI-81](improvements.md)** | now **two** measured instances (`/analyze` **and** `/design`). Fixing it needs approval — skills/agents are user-owned config **and** `defaults/global/` is shipped content. ⚠ The fix must be a **sweep with a stated enumeration command**, not the two known cases |
| **[FI-82](improvements.md)** | the `docker run` stdout swallow is **measured, not diagnosed** |
| **[FI-73](improvements.md)** | the SIGPIPE sentinel — a maintainer's call, unchanged |
| 📝 **the `_secret_scan_staged` pipefail contract** | raised by A2's review as `minor`, **still never ruled** |
| **A1's roadmap entry → [roadmap-history.md](roadmap-history.md)** | ~450 lines of a closed unit. ⚠ Its branch was deleted 2026-08-26, so the automatic trigger (*the branch appears among the merged*) **can never fire again**. A maintainer's call now |
| **[FI-74](improvements.md)** · **[FI-76](improvements.md)** | A1's review residue, none blocking |
| **[A2](roadmap.md)** · **[A3](roadmap.md)** · **[A6](roadmap.md)** · **[A7](roadmap.md)** · **[A12](roadmap.md)** | the rest of Block A. ⭐ A2: start from sub-problem 3 |
| **FI-58 leftovers** | ADR-0058's **D3**, **D7** and **D8-as-amended** are unbuilt. ⚠ D8 touches a **baked** file |
| **[FI-72](improvements.md)** | nothing detects the *next* unclassified `warn` producer |

## How to resume

**First command**: `git branch --show-current` — host and container share one working tree, so the
host can move this session's branch under it.

**Then read, in this order** (and re-derive none of it):

1. **[ADR-0060](engineering/decisions/0060-developer-execution-mode.md)** — the six rulings + three
   amendments, what each rejected, and the consequences. **This is the contract.**
2. **[`engineering/design/dev-execution-mode.md`](engineering/design/dev-execution-mode.md)** — the
   *how*. For A10.1 you need **§3** (the flag, dispatch, resolution order), **§4** (image mapping),
   **§6.1** (in-container refusal), **§10** (staging + DoD) and **§11** (the acceptance lane and the
   oracles that must be shown to discriminate).
3. §*Traps that bind this build* below.

⚠ **Do NOT read the decision clinic to find out what to build.**
[`engineering/analysis/dev-execution-mode-decisions.md`](engineering/analysis/dev-execution-mode-decisions.md)
is **historical**: three rounds in which the `D1` recommendation **changed twice**, plus a dated
correction. Rounds 1 and 2 are superseded and marked so. Read it only to see *why* an alternative was
rejected.

### A10.1 — the concrete surface to touch

Everything below is from the design; it is listed here so the first hour is not spent locating it.

| Site | What changes |
|---|---|
| `bin/cco:141-153` | the dev-flag block: parse `--dev` / `--dev=<path>` / `CCO_DEV`, **stop the scan at the first `--`**, refuse in-container, resolve the target and `exec`. Runs **post-source** and **after** the `cco_access=none` refusal at `:128` — both deliberate, design §3.1 |
| `bin/cco:37` | `IMAGE_NAME="${CCO_IMAGE_NAME:-claude-orchestrator:latest}"` — **the default does not move** |
| new helper `_cco_dev_image` | design §4 has the mapping table and the digest case. Its home is an implementation choice; the dev block in `lib/paths.sh:562-650` is the natural one |
| `lib/cmd-start.sh:1589-1590` | map **only** a `docker.image` that was actually set — when unset it inherits the already-mapped `$IMAGE_NAME`. The rule that avoids double-mapping is written out in §4 |
| `lib/utils.sh:379-383` | `check_image` dies naming **both** images and the two ways out |
| `lib/cmd-build.sh:163` | no change — it tags `$IMAGE_NAME` and inherits the mapping |
| `tests/test_dev_sandbox.sh` | 9 existing tests. ⭐ **`:75-86` (`test_dev_sandbox_config_stays_shared`) must stay green AS WRITTEN** — it is the check that the default did not move |
| docs, at the end of A10.1 | `docs/users/reference/cli.md` §3.34 (the flag becomes an alias) · `CONTRIBUTING.md:12-35` (the two substitutive setups are replaced) · `changelog.yml` |

**Tests come from the design, by an independent role** (`rules/testing.md`) — not from the code as
written. ⚠ **Check `/implement`'s frontmatter before relying on it**: `/analyze` and `/design` both
fork to agents without `Write`/`Edit` ([FI-81](improvements.md), two measured instances), and
`/implement` was **not** checked. If it forks to a write-less agent, the lead does the work.

## Tasks

The [roadmap](roadmap.md) is the single source of truth for status; this list points at it.

- [ ] ▶ **Implement [A10.1](roadmap.md)** — design §3, §4, §6.1, to the table above
- [ ] **Tests for A10.1**, derived from the design by an independent role. Each new guard must be
      shown to **fail when neutralised** before its pass is believed
- [ ] **Acceptance for A10.1** — a **host** `cco build` in dev mode, then `docker image inspect` on
      **both** tags. ⚠ Never `docker run` (FI-82); never `cco --version` (non-discriminating)
- [ ] **Living docs for A10.1** — `cli.md` §3.34, `CONTRIBUTING.md`, `changelog.yml`
- [ ] **[A10.2](roadmap.md)** — snapshot store · the `<repo>/.cco` restorability guard (ADR-0060
      D4.8) · `cco dev restore|list|reset|seed` · migration routing · fixtures · `project.dev.yml` ·
      `clean` scoping + `--images`
- [ ] **Push `develop`** from the host — `git push origin develop` (the merge is done; the push is not)
- [ ] **Consolidate, then delete** `feat/devmode/dev-execution-mode` — at the next `/handoff`, in that
      order (`git branch -d`, never `-D`)
- [ ] **Decide [FI-83](improvements.md)'s direction** — capture the one missing observation first
- [ ] **Move `user-config/` out of the checkout** — [FI-84](improvements.md), free, host-side
- [ ] **[FI-78](improvements.md)** — the two macOS failures, host-verified only, owed before `0.7.0`
- [ ] **[FI-81](improvements.md)** — propose the sweep (both instances + the enumeration command)
- [ ] **[FI-82](improvements.md)** — diagnose *why* `docker run` stdout is swallowed
- [ ] **Decide**: move A1's ~450-line closed entry into [roadmap-history.md](roadmap-history.md)
- [ ] **Rule the `_secret_scan_staged` pipefail contract** — open since A2's review
- [ ] **[FI-73](improvements.md)** · **[FI-74](improvements.md)** · **[FI-76](improvements.md)**
- [ ] **[A2](roadmap.md)** · **[A3](roadmap.md)** · **[A6](roadmap.md)** · **[A7](roadmap.md)** ·
      **[A12](roadmap.md)**, then **FI-58 leftovers** (D3, D7, D8-as-amended) and
      **[FI-72](improvements.md)**

## Context

### What the design sessions produced

Documents only. A **three-round decision clinic**, then
[ADR-0060](engineering/decisions/0060-developer-execution-mode.md) and
[the design](engineering/design/dev-execution-mode.md). The rulings are in the ADR and are **not
restated here**.

⭐ **The one sentence worth carrying**, because it reversed two earlier recommendations:
*configuration is the test's **input**, not its target.* Rounds 1 and 2 both weighed **how cheap is
it to isolate `~/.cco`** (measured: 3 code sites) without asking **whether isolating it serves the
mode's purpose**. It does not — a dev run against a different configuration is not testing the user's
setup. So `~/.cco` **and** `<repo>/.cco` stay shared, and what dev mode protects is the survival of a
**bad write**. This upholds ADR-0052 §7's WS-6 call **for a stronger reason than WS-6 gave**.

### The three amendments at the approval gate — do not re-open them

All are in the ADR and the design; here only so nobody relitigates.

1. 🔴 **A failed snapshot is FATAL, not a warning.** The step is **unconditional** — every `--dev`
   engage, before the verb — and if the restore point cannot be taken the run **dies**: the safety
   property was never established. Deliberately unlike `_cco_dev_sandbox_seed`'s `warn` — a partial
   seed is a convenience, a missing restore point **is** the protection. An absent `~/.cco` is a
   **no-op**, not a failure.
2. **The `<dev-root>` is not a new XDG bucket, and never was.** Dev mode adds none: it **re-points
   three of the existing four** at children of `~/.cco-devsandbox`. The snapshot store and the
   fixtures are **siblings** of those three — design §5.0. ⚠ **Measured reason**:
   `_cco_dev_sandbox_seed` (`lib/paths.sh:606-628`) does `cp -a "$real_state" "$root/state"` behind a
   one-shot guard, so anything under `state/` is either overwritten by a re-seed or blocks the seed.
   The default **path does not move** — renaming it would strand every existing sandbox.
3. 🔴 **`<repo>/.cco` is GUARDED, not snapshotted** (ADR-0060 **D4.8**), added when the maintainer
   asked what protects project config. **The answer as the design stood was: nothing** — the
   snapshot's work-tree is `~/.cco` alone, and two sentences claiming project writes were *"doubly
   recoverable"* / *"recoverable without any mechanism"* were **overstated** (the clinic carries a
   dated correction). Project config is protected by **the user's own repo git**, complete only for a
   committed, clean tree in a git repo — and **a non-git repo is a supported case**
   (`lib/cmd-project-save.sh:452`). ⇒ Under `--dev` a writer that can **destroy uncommitted content**
   refuses when the tree is not restorable. ⭐ **The criterion is the ruling, not the list**: a writer
   whose only effect is a *commit* is exempt — which is why **`cco project save` must be**, since it
   only acts on a dirty `.cco` and a dirty-check would make it permanently untestable.

### Measurements a session must not argue away

- 🔴 **The version gate is DORMANT, not bypassed.** npm `latest` and the clone are both `0.6.0`, both
  `CCO_INDEX_VERSION=2`, both max migration `017`, across 148 commits ⇒ **`cco --version` is a
  NON-DISCRIMINATING oracle** and any acceptance test built on it is a false pass by construction.
  The oracles that do discriminate: `cco whoami` (`REPO_ROOT` + provenance, shipped by A11) and
  `docker image inspect … cco.build-ref`.
- 🔴 **The image tag IS the code identity of the in-session cco** — `Dockerfile:201-211` bakes
  `bin/`+`lib/` into `/opt/cco` and a normal session mounts **no host `lib/`**. This is why A10.1 is
  the half that closes the incident.
- 🔴 **The clone has no name on PATH.** Coexistence is a state **to create**; a design that "detects
  the other install and warns" has, today, nothing to detect.
- 🟢 **Nothing does `rm -rf` of the whole `~/.cco`** anywhere in `lib/` — `cco init --force` removes
  `~/.cco/.claude`. This is the measurement the entire protection design rests on.
- 🔴 **`cco config` has no `restore`** (`save · status · history · push · pull · validate`) — the
  restore verb is new work, not a wiring job.
- 🔴 **`cco config save` promises *"cco never auto-commits"***, and `_config_push` operates on
  `$cfg/.git` — which is why the snapshot store is a **separate `GIT_DIR`**, structurally unpushable.
- 🔴 **`_CONFIG_ALLOWLIST` omits `access.yml` and `claude-version`** ⇒ the snapshot uses `git add -A`.
- ⚠ `grep -n '"--")' lib/*.sh bin/cco` → **zero** hits: no verb handles a `--` terminator. Today's
  flag strip is harmless **by luck**; `--dev` carries the fix.
- ⚠ **The project-writer list is a lower bound, demonstrated within one session**: the clinic's round
  3 named four, a re-grep found a fifth (`cco project add`, `lib/cmd-project-add.sh:206,261`) and a
  probable sixth (`cco repo rename`). Design §5.2 records the **enumeration command** — re-run it and
  classify every hit; do not inherit the table.

### Two findings still open

- **[FI-83](improvements.md) — an interactive trust prompt stalls a delegated run.** 🔴 Trigger
  **measured**: a teammate is a separate `claude` process whose `cwd` is the repo while the lead's is
  `/workspace`, and workspace trust is **directory-scoped**. `--dangerously-skip-permissions` does
  **not** cover it (measured). Cheapest candidate: start teammate panes in the lead's cwd — **no
  security surface**. ⚠ Still not observed: **which directory the dialog named**.
- **[FI-84](improvements.md) — the fresh-HOME legacy-vault toll.** `_cco_first_run` archives the
  legacy vault for every verb except `help`; with the git-versioned 454MB `user-config/`, every test
  with a fresh `$HOME` pays ~13s. **Idempotent per STATE root ⇒ not a shipped defect.**

### Traps that bind this build

- 🔴 **In a session, `docker run` returns rc 0 with EMPTY stdout; only the exit code crosses.**
  `docker image inspect` **does** work — that is the channel, and the reason A11 carries a label.
- 🔴 **`docker run <image> <cmd>` does NOT replace an ENTRYPOINT** (`Dockerfile:233`). The wrong form
  installs Claude Code and prints plausible output. Use `--entrypoint`.
- 🔴 **Never write `git -C <unit-dir> … -- .cco`.** Every git **output** path (`status --porcelain`,
  `ls-files`, `diff --cached --name-only`, `check-ignore -v`'s source) is reported relative to the
  **top level**, never to cwd — joining those onto the unit dir failed silently and **a secret under a
  nested `.cco/` was committed under `✓ saved`**. Use `_project_resolve_unit`
  (`lib/cmd-project-save.sh:86-97`) and anchor on `$_PROJECT_GITROOT` + `$_PROJECT_SPEC`. **A10.2's
  D4.8 guard sits squarely in this blast radius.**
- 🔴 **A missing `Results:` line is the signal.** An aborted suite reads green and prints no summary.
- 🔴 **A mutation that PASSES = untested behaviour**, and **an unreachable guard is an unmeasured
  guard**. Prove each new guard fails when neutralised before believing its pass.
- 🔴 **A named list is a lower bound.** It is why the snapshot trigger is unconditional rather than a
  list of config-writing verbs, and why D4.8 states a **criterion** as well as a table.
- ⚠ **An ordering that is a false pass in waiting** (A10.2): the snapshot store's `info/exclude` must
  be written **before** the first `git add -A`. A test asserting the exclusions exist would pass on a
  store whose *first commit* already contained `secrets.env`.
- ⚠ **Concurrent agents share one index.** Commit with the **pathspec form**
  (`git commit <paths> -m …`), never `git add` + bare `git commit`. A **new** file needs
  `git add <path>` first, then the pathspec commit.
- ⚠ **The host can change this session's branch under it** — one working tree, two writers.

### Still unmeasured — say so, do not assume

- The **`unknown` half** of the `/opt/cco/BUILD` + `cco.build-ref` oracle is **asserted, not
  measured**: only `branch@sha` has ever been executed; no npm-provenance build has been made.
- **Which directory FI-83's trust dialog named.**
- **Why `docker run` stdout is swallowed** — measured, never diagnosed.
- **Whether `/implement` forks to a write-capable agent.**
- The **bash 3.2 lint** was not verified in the session that first recorded it (proxy container limit).

## Reference documents

- [roadmap.md](roadmap.md) — the SSOT; **A10** (designed, split into **A10.1** / **A10.2**),
  **A11** (closed but unmerged), **A12** (new: `cco doctor`)
- [engineering/decisions/0060-developer-execution-mode.md](engineering/decisions/0060-developer-execution-mode.md) — **the contract**
- [engineering/design/dev-execution-mode.md](engineering/design/dev-execution-mode.md) — the *how*
- [engineering/analysis/dev-execution-mode.md](engineering/analysis/dev-execution-mode.md) — the
  approved analysis (§12.1 the host probes)
- [engineering/analysis/dev-execution-mode-decisions.md](engineering/analysis/dev-execution-mode-decisions.md)
  — the decision clinic, **historical**: the option space and what was rejected
- [engineering/design/packaging-distribution.md](engineering/design/packaging-distribution.md) §4 —
  now carries the tag-namespace orthogonality sentence B1/B2 inherit
- [improvements.md](improvements.md) — FI-79 · FI-80 · **FI-81** (two instances) · FI-82 · FI-83 ·
  FI-84 · FI-16
- [roadmap-history.md](roadmap-history.md) — where A1's closed entry goes, if the maintainer says so
