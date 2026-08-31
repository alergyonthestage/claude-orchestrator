# ADR 0060 — Developer execution mode: `--dev`, a forked image identity, and a shared configuration protected by snapshots

**Status**: Accepted (2026-08-31)
**Deciders**: maintainer + design session (three decision rounds, 2026-08-31)
**Context docs**:
[`../analysis/dev-execution-mode.md`](../analysis/dev-execution-mode.md) (approved analysis,
2026-08-27) ·
[`../analysis/dev-execution-mode-decisions.md`](../analysis/dev-execution-mode-decisions.md)
(the decision clinic — the option space, the measurements, and what each ruling rejected) ·
[`../design/dev-execution-mode.md`](../design/dev-execution-mode.md) (the *how*)
**Related ADRs**: **0052 §7** (the `--dev-sandbox` this supersedes in part, and its WS-6
*"CONFIG stays shared"* annotation — **upheld here, for a different reason**) · **0037**
(npm packaging; `package.json` is the version SSOT) · **0045** (running registry — the orphan
class this must not add to) · **0047 / 0049** (the privilege boundary and `:ro` mounts that make
project config host-resolved) · **0059** (message classification — which producer level a
divergence belongs to)
**Supersedes in part**: ADR-0052 §7's flag surface. `--dev-sandbox` / `--dev-sandbox-seed`
become aliases; the isolation they perform is unchanged and is now one half of a larger identity.

---

## Context

On 2026-08-27 the maintainer ran `cco build` from the **npm-distributed CLI** instead of the
clone's `./bin/cco` — the third instance of the FI-16 class (2026-07-15, 2026-07-16, this one).
`--dev-sandbox` had shipped in ADR-0052 §7 and was believed to cover it. It does not, and the
approved analysis measured why. Three facts bound every decision below; all are cited in full in
the analysis and are **not** restated here:

- **M1** — the **image tag is the code identity of the in-session cco**. `Dockerfile:201-211`
  bakes `bin/` + `lib/` into `/opt/cco` and a normal session mounts no host `lib/`; `IMAGE_NAME`
  is hardcoded with no override, so both binaries tag **one global image** and overwrite each
  other. `--dev-sandbox` isolates STATE/DATA/CACHE — the half that does *not* decide which code
  runs.
- **M2** — **the clone has no name on PATH.** `which -a cco` printed one path twice (a duplicated
  PATH entry, not two installs). Coexistence is a state **to create**; nothing today can be
  "detected and warned about".
- **M3** — **the version gate is dormant, not bypassed.** Both binaries are `0.6.0`, both
  `CCO_INDEX_VERSION=2`, both max migration `017`, across 148 commits ⇒ `cco --version` is a
  **non-discriminating oracle** and no acceptance test may rest on it.

The direction gate had already ruled (analysis §11.0) that **both CLIs stay installed** and that
the identity oracle ships first — delivered as A11 (`cco whoami` host branch + `LABEL
cco.build-ref`).

## Decision

Ship a **developer execution mode** that is one mode of one binary: it forks the code identity
(the image) and the internal buckets, **shares the configuration**, and protects that shared
configuration with an automatic, restorable snapshot.

### D1 — `--dev` is the primitive; dispatch is a sub-case of it, not a second design

`--dev` is implemented **once, in `bin/cco`** — the same file in both copies of the code. When
`REPO_ROOT` already is the dev clone, the flag engages the dev identity directly. When it is not
(the published binary), the binary resolves the dev target and `exec`s into it, after which the
branch above runs in the clone.

⭐ **The published binary's only dev-mode responsibility is to resolve and hand off.** Every dev
*semantic* lives in the target, which is always the newest code — so a `0.7.0` published binary
can drive a dev clone of any future version. That forward-compatibility is the property that
decided D1 and it is the one a second shim binary cannot provide.

`cco-dev` is therefore a shell alias (`alias cco-dev='cco --dev'`), not a shipped file — which
also removes the packaging trap a shipped shim would have carried (`package.json` `files` lists
`"bin/cco"`, not `"bin/"`, while `Dockerfile:201` does `COPY bin/`, and
`scripts/check-pack-hygiene.sh` is a denylist that would not have caught the omission).

**Bootstrapping**: A10 sits in Block A, which ships `0.7.0`, so the release carrying the
dispatcher is **this block's own deliverable**. Until it ships the clone is invoked by path,
exactly as today.

### D2 — The dev identity is: internal buckets + the image. Configuration is **not** in it

| Namespace | In the dev identity? | Why |
|---|---|---|
| STATE / DATA / CACHE | **yes** — unchanged from ADR-0052 §7 | already shipped and correct |
| **the image** | **yes** — new | M1: it is the code identity of the in-session cco |
| global CONFIG `~/.cco` | **no** | see D4 |
| project config `<repo>/.cco` | **no** | see D4 |
| container / network names | **no** — deferred to **B2** | the collision they would prevent is a **legible Docker refusal** today, not corruption; B2 (`cco attach`) owns that namespace |

### D3 — The image identity forks on the **repository name**, not the tag

`_cco_dev_image "<image>"` appends `-dev` to the repository part and keeps the tag:
`claude-orchestrator:latest` → `claude-orchestrator-dev:latest`. It is applied to the default and
**after** `project.yml`'s `docker.image` is resolved, so a project pin is mapped too and the
**committed file is never touched** — dev mode must not require a config change, because
`project.yml` is shared with the team.

⭐ Forking the repository rather than the tag leaves the **tag axis completely free**, so
[`../design/packaging-distribution.md`](../design/packaging-distribution.md) §4's deferred
`:<package.version>` refinement applies unchanged to both repositories. The two axes are
**orthogonal**; §4 needs a clarifying sentence, not a reservation. It also leaves
`FROM claude-orchestrator:latest` in the user-facing custom-image guide untouched.

When the mapped image does not exist, `check_image` **dies**, naming both images and the two ways
out. A fallback to the unmapped image would run **published code in a dev session** — the original
incident, with a warning on top.

### D4 — Configuration is shared, and protected by an unconditional snapshot

⭐ **Configuration is the test's input, not its target.** A dev run against a different
configuration is not testing the user's setup. Both earlier rounds of the clinic weighed *how
cheap is it to isolate* without asking *whether isolating serves the mode's purpose*; it does not.
This upholds ADR-0052 §7's WS-6 call — **for a different and stronger reason than WS-6 gave**.

What dev mode protects is therefore not the location of the configuration but the survival of a
**bad write** to it:

1. **An unconditional, git-based snapshot** of the real `~/.cco`, taken at the start of every
   dev-mode run when the tree has changed since the last one. Unconditional, because a **named
   list of config-writing verbs is a lower bound** — a class this repo has paid for four times.
2. **In a separate `GIT_DIR`**, never `~/.cco/.git`. `cco config save`'s contract is explicit —
   *"Explicit and manual: cco never auto-commits"* — and an automatic commit into that history
   would break it and pollute `cco config history`. The separate store also lives in the
   **sandboxed STATE** bucket (so it is dev state, reaped with the dev environment) and is
   **structurally unpushable**: `_config_push` operates on `$cfg/.git` and cannot see it.
3. **Complete, not allowlisted.** The snapshot stages everything (`git add -A` against its own
   store), because `_CONFIG_ALLOWLIST` omits `access.yml` and `claude-version` — exactly the two
   members with no other recovery path. A *publish* save wants a curated subset; a *safety*
   snapshot wants the whole tree. Different scopes, deliberately.
4. **Secrets are excluded.** `~/.cco/secrets.env` and the known secret patterns stay out, so no
   secret material is duplicated to a second location on disk. ⚠ The accepted cost, stated rather
   than hidden: `lib/migrate.sh:382` (`cp "$f" "$cfg/secrets.env"`) is a measured writer, so a
   broken dev migration can clobber `secrets.env` **irrecoverably**. Documented, not silent.
5. **A restore verb, which does not exist today.** Measured: `cco config` offers
   `save · status · history · push · pull · validate` and **no restore**. It lands as
   `cco dev restore`, because the store is dev-mode state, not `~/.cco`'s curated history.
6. **Project config is not relocated either.** Reads are shared in both modes — that is the point.
   Relocating it was priced and rejected: it is composed inline at ~64 sites across 16 files (a
   resolver exists, `_resolve_project_cco_dir`, with **2 callers**) and it **rides the repo mount**
   (`_compose_vol "${repo_path}" "/workspace/${repo_name}"`), so moving it is a mount-topology
   change (ADR-0047/0049). It is also **versioned in the user's repo**, so an ordinary bad write is
   recoverable without any mechanism. No `--allow-project-writes` gate is introduced.
7. **`project.dev.yml`** — optional, gitignored, and deliberately **`project.yml`-only**. What
   legitimately varies per mode is runtime wiring (the image, a port, a network) and it all lives
   there; the rest of `<repo>/.cco` is *the content under test*. ⚠ Identity fields are **not**
   overridable: `project.yml`'s `name:` keys the index, the per-project scoping (ADR-0051) and the
   provenance records.

### D5 — The one class a remedy cannot cover routes to a fixture

With CONFIG shared and STATE sandboxed, `_run_migrations` runs **target-shared /
marker-sandboxed**: a dev-run migration mutates the real `~/.cco/.claude` and records that it ran
in a bucket the published binary never reads, so the published binary **runs it again**. A restore
puts the files back and leaves the bookkeeping wrong.

⇒ Under `--dev`, migrations whose target is the real CONFIG **refuse** unless an isolated config
dir is in use — two call sites (`lib/update.sh:138`, `lib/cmd-init.sh:268`). The refusal names the
escape. Accordingly `CCO_CONFIG_HOME` is **built as a resolver seam and left disengaged**: `--dev`
never sets it; the dev tooling and the developer do.

### D6 — The mode is the **context**, not a flag on every verb

`cco --dev clean` cleans the dev environment; `cco clean` cleans the real one. No verb grows a
`--dev` variant and nothing is documented twice. Four verbs, four responsibilities:

| Verb | Owns |
|---|---|
| `whoami` | **who am I** — identity (A11, extended with the active environment) |
| `doctor` | **is anything wrong** — diagnose. ⚠ **Out of scope here**: user-facing, independently useful, and its own roadmap entry |
| `clean` | **remove what cco created** — scoped to the active environment, plus `--images` |
| `dev` | **manage dev environments** — `seed · reset · list · restore`, and the fixtures |

### D7 — Fail loud at both boundaries

- **In-container**: `--dev` **refuses** (exit 2), naming the host — the precedent is `bin/cco:128`.
  The existing silent swallow of `--dev-sandbox` (accepted, stripped, ignored) is fixed in the same
  change: a flag that does nothing is the false-success shape this repo keeps an audit of.
- **CLI ↔ image divergence**: `cco start` **warns** (does not refuse) when the image's
  `cco.build-ref` label differs from the CLI's own tree. Warn, because the divergence is often
  intended and ADR-0059's taxonomy puts an accepted divergence the user can act on at `warn`. It
  closes the second of A11's three deliberate residues, and it is the **only** cover for a project
  that pins `docker.image`, which the tag mapping does not reach.
- **Legacy flags**: `--dev-sandbox` / `--dev-sandbox-seed` become aliases of `--dev` /
  `cco dev seed`, each emitting a superseded note. ⚠ This is a behaviour change to a documented
  flag (`docs/users/reference/cli.md` §3.34), accepted deliberately: it removes a half-identity
  rather than perpetuating two modes that isolate different things.

### D8 — Staged delivery

**A10.1 — identity**: `--dev` + the dispatcher contract · `_cco_dev_image` at its two application
points · the in-container refusal · a `--` terminator fix (measured: `grep -n '"--")' lib/*.sh
bin/cco` returns **zero** hits, and a flag that changes which *binary* executes must not inherit
that) · the legacy aliases. After A10.1 a dev run **cannot overwrite the real image** — the
incident is closed and verifiable with no new verb.

**A10.2 — protection and tooling**: the snapshot store · `cco dev restore|list|reset|seed` · the
migration routing · the fixtures · `clean` environment-scoping and `--images`.

## Alternatives considered and rejected

The full option space, with pros and cons per option, is in the decision clinic; recorded here is
only what was rejected and why, so it is not re-litigated.

- **A second shim binary `bin/cco-dev`** — bound to whichever clone owns the PATH symlink, so the
  worktree-per-agent workflow this project mandates needs one name per worktree; forces a
  `package.json` `files` and `.dockerignore` ruling; and makes every future verb documentable
  twice. Its only real advantage was working before an npm release, worth weeks of Block A.
- **A sourced profile (`activate.sh` / direnv shape)** — prior art exists in
  `scripts/cco-sandbox-e2e.sh`, whose own header names the trap: the state is **active but
  invisible**. Rejected as the shape most likely to produce the next incident.
- **Forking CONFIG** (a `CCO_CONFIG_HOME` engaged by `--dev`) — costs only 3 code sites, and was
  recommended in the clinic's round 2 before being refused: it isolates the test's *input*, so a
  dev run would no longer test the user's configuration.
- **Relocating project config**, whole-tree overlay or otherwise — priced at ~64 inline sites and
  a mount-topology change, against a tree that is already versioned.
- **`:dev` as an image tag** — occupies the tag axis that `packaging-distribution.md` §4 has
  reserved for `:<package.version>`.
- **A snapshot triggered by a list of config-writing verbs** — a named list is a lower bound.
- **A `cco dev snapshot`/`restore` pair for *mutated* dev state** — YAGNI: reset + re-seed is
  already the re-iteration loop, because the restore source is the real config, which nothing in
  dev mode may destroy unnoticed.
- **`cco doctor` inside A10** — a new user-facing verb (the surface would go 25 → 27 in one step)
  inside a maintainer-tooling unit; it is independently useful and gets its own entry.

## Consequences

- **For a user: nothing changes.** No default moves — `IMAGE_NAME` still resolves to
  `claude-orchestrator:latest`, `~/.cco` and `<repo>/.cco` stay where they are, and `project.yml`
  is never rewritten. The one new user-perceivable surface is the `cco start` divergence **warning**
  (D7), which fires only when the image and the CLI genuinely disagree.
- **For a developer**: `cco --dev <verb>` from any cwd; a dev build can no longer overwrite the
  image a real session uses; the real configuration is what is under test, with a restore point
  behind every run.
- **A new orphan class is created and reaped in the same design**: a dev image is gigabytes, and
  `clean --images` + `cco dev reset` are what discharge the obligation. ADR-0045's running registry
  is the precedent for not shipping an identity without a reaper.
- ⚠ **Both stages are baked**: each takes a real `cco build` in its acceptance lane. In-session
  `docker run` returns rc 0 with **empty stdout** (FI-82), so `docker image inspect` — and the
  `cco.build-ref` label A11 shipped — is the only identity channel that works from a session.
- ⚠ **A named sequencing obligation**: A10's image axis, **B1** (`cco build` inside `cco update`)
  and **B2** (container naming) touch one namespace. D3's orthogonality sentence in
  `packaging-distribution.md` §4 is what B1 and B2 inherit instead of rediscovering it.
- **Unrepaired, deliberately**: a broken dev migration can clobber `~/.cco/secrets.env` (D4.4);
  `cco project save` in dev mode commits into the user's repo, recoverable but noisy; and M3's
  dormant version gate stays dormant — nothing here wakes it.
