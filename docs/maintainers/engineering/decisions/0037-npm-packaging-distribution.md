# ADR 0037 — npm packaging & distribution (the v1 public release vehicle)

**Status**: Accepted (2026-06-30)
**Deciders**: maintainer + design session
**Context docs**: `../npm-packaging-distribution-handoff.md` (Handover C) ·
`../design/packaging-distribution.md` (living release-engineering design) ·
official Claude Code docs (llms) on the native installer
**Related ADRs**: **0007 (XDG 4-bucket model — STATE/CACHE/DATA homes)** ·
**0015 (DATA bucket / bucket map)** · **0028 (flat `~/.cco/.claude`)** ·
**0039 (native Claude Code install in CACHE)** — packaging must not regress the
read-only-framework posture those established.
**Sequenced-before**: the opinionated-extraction + `cco update` refactor
([`../opinionated-extraction-and-update-refactor-handoff.md`]) — decoupled from
this ADR; packaging does not require it.

---

## Context

Today `cco` is installed by cloning the repo and putting `bin/cco` on `PATH`.
There are **no packaging artifacts** (no `package.json`, `install.sh`, Homebrew
formula, `.npmignore`). To ship v1 publicly the framework needs a distribution
vehicle. `bin/cco` is a **bash** CLI (bash 3.2+, macOS-safe), not a node program;
it resolves its own root via a readlink loop (`bin/cco:13-21`) → `REPO_ROOT`, and
already exposes a `CCO_FRAMEWORK_ROOT` seam (`bin/cco:28`) that points the shipped
read-only trees (`defaults/`, `templates/`, `migrations/`, `changelog.yml`) at an
overridable location. The Docker image is built on the **user's host** by
`cco build` (`docker build "$REPO_ROOT"`); the Go socket proxy (`proxy/`) is
compiled inside that image build.

This release **gates** the public `develop → main` cut: v1 cannot be distributed
without a package. The analysis session (2026-06-30, handoff §7) ran three audits
(distribution-gap, read-only-`FRAMEWORK_ROOT` write-risk, sharing-model) and took
the decisions recorded below.

### Registry facts (verified 2026-06-30)

- `claude-orchestrator` (unscoped) — **taken** (an unrelated `1.0.x` package
  published 2025-06, not ours).
- `cco` (unscoped) — **taken** ("color transfer", `0.0.1`).
- `@claude-orchestrator/cco` (scoped) — **free**.

A scoped name is therefore **forced**; the unscoped names are unavailable.

## Decision

Ship `cco` as a **scoped npm package that carries the whole framework tree**,
installed globally; build the Docker image and proxy **lazily** on the host;
publish via a CI-on-tag pipeline gated by a read-only-`FRAMEWORK_ROOT` test.

### D1 — Distribution shape: npm package, global install, lazy build

- `package.json` with `"bin": { "cco": "bin/cco" }`. npm creates the global `cco`
  shim as a symlink into `…/node_modules/@claude-orchestrator/cco/bin/cco`; the
  existing readlink loop resolves it back to the package root → `REPO_ROOT`. The
  install/runtime symlink-depth must be **verified on macOS and Linux** (design
  doc §3.1).
- **Global `npm i -g`** is the supported install (one install, prefix-free `cco`
  from any cwd — the natural model for a host-level orchestrator). `npx` is
  documented as **try-once only**, with an explicit warning (re-downloading the
  framework per invocation of a Docker orchestrator is pointless). Per-repo
  `npm i` is **not** supported (wrong model — version would diverge per repo).
- **No heavy `postinstall`.** The Docker image is **not** built on `npm install`
  (slow, needs Docker, may run in CI). It is built lazily by `cco build` / first
  `cco start`, unchanged.

### D2 — Name & ownership: `@claude-orchestrator/cco` under dedicated orgs

- Package = **`@claude-orchestrator/cco`**; the command stays the prefix-free
  **`cco`**. The scope carries the full project name (coherent with the repo,
  discoverable); the leaf is the binary name (memorable install).
- **Ownership** (refined 2026-06-30 — the **GitHub org `claude-orchestrator` is
  already taken**, so the npm and GitHub namespaces are decoupled):
  - **Repo stays on the personal GitHub** `github.com/alergyonthestage/claude-orchestrator`
    (public, MIT). GitHub Pages → `alergyonthestage.github.io/claude-orchestrator`
    (free for public repos).
  - **npm scope is independent of GitHub**: create the **npm org
    `claude-orchestrator`** (verified free on npm — no package/org under it) to own
    `@claude-orchestrator/*`. npm-scope ≠ GitHub-owner is common and fine.
  - **Fallback** if managing an npm org is unwanted: **`@alergyonthestage/cco`**
    (auto-available under the npm username; fully coherent with the personal repo,
    but a cryptic handle — weaker discoverability). Recommended primary remains
    `@claude-orchestrator/cco`.
- Discoverability is recovered via `package.json` `keywords`
  (`claude`, `claude-code`, `orchestrator`, `docker`, `cco`), not via the name.

### D3 — `files` allowlist: ship the full build+runtime context, `docs/users` only

The package must carry the **whole Docker build context** (the host runs
`docker build` from the installed package) plus the runtime trees and the
**user-facing** docs subtree.

```
INCLUDE:  bin/ lib/ config/ defaults/ templates/ internal/ migrations/
          proxy/ docs/users/ Dockerfile .dockerignore changelog.yml
          package.json README.md LICENSE
EXCLUDE:  tests/ scripts/ user-config/ docs/maintainers/ docs/archive/
          .github/ .git/ .cco/ .claude/ CONTRIBUTING.md SECURITY.md reviews/
```

- `config/`, `proxy/`, `Dockerfile`, `defaults/managed/` are **build-time on the
  user's host** → they **must** ship (correcting a sub-audit slip that called them
  excludable).
- **`docs/users/` only** ships (config-editor mounts it, the tutorial references
  `docs/users/…`). `docs/maintainers/` and `docs/archive/` are human-only and not
  referenced at runtime → excluded. This requires pointing the config-editor mount
  + tutorial references at `docs/users` (they already use `users/…` paths).
- **`user-config/` is excluded** (legacy centralized vault, migration-only;
  decentralized-config replaced it — see D5).

### D4 — Go proxy: build-in-image (no host Go dependency)

The proxy is compiled inside the Docker image build, as today. A prebuilt darwin
binary would be **dead weight** (the proxy only runs in the Linux container);
build-in-image also keeps the host Go-free and lets the image handle arch.

### D5 — Read-only `FRAMEWORK_ROOT`: split the one violation, gate on a test

Audit result: **all** mutable writes already target `~/.cco` / XDG STATE·CACHE·DATA
**except one** — `USER_CONFIG_DIR` (`bin/cco:42`,
`USER_CONFIG_DIR="${CCO_USER_CONFIG_DIR:-$REPO_ROOT/user-config}"`) defaults
**inside the framework** and the tutorial/config-editor runtime setup writes under
it (`lib/cmd-start.sh:15,53`) → works from a clone, **fails read-only on npm**.

`USER_CONFIG_DIR` carries **two roles** (code-grounded refinement of handoff §7.3):

1. **Legacy-vault source** read by `cco init --migrate` (`lib/migrate.sh:120`) —
   read-only, may be absent (npm users never had a clone-era vault).
2. **Internal runtime root** for tutorial/config-editor (`lib/cmd-start.sh`) —
   **must be writable**.

**Decision — split the two roles** rather than relocate one mixed default:

- The **internal runtime dir** derives from **STATE** (writable, machine-local),
  e.g. `$(_cco_state_dir)/internal`, independent of the legacy pointer. This is
  what tutorial/config-editor write into.
- The **legacy-vault pointer** (`CCO_USER_CONFIG_DIR`) stays as the
  **migration-only read source**; its default no longer needs to sit inside the
  framework and nothing writes into `user-config/` anymore (maintainer directive:
  the legacy vault and the `claude-orchestrator` repo itself are no longer used by
  end users).
- **Publish gate**: a suite run with `CCO_FRAMEWORK_ROOT` pointed at a
  `chmod 0555` (read-only) tree must be **green**. This re-uses the existing
  framework-root test seam and is the **mandatory pre-publish gate** (run in CI).

Everything else is already clean: `cco build` uses the context read-only; generated
compose / `packs.md` / `workspace.yml` go to CACHE; `defaults/global` is read and
copied into `~/.cco`; `changelog.yml` is read-only at runtime.

### D6 — Release pipeline: `release.sh` + CI-on-tag (npm token in CI)

- **`release.sh`** (local, maintainer-run): bump `package.json` version + update
  `changelog.yml` + create an annotated git tag + push.
- **CI-on-tag** (GitHub Actions, triggered by the tag): run the full suite + the
  **read-only-`FRAMEWORK_ROOT` gate** (D5) + `npm publish`.
- The **npm publish token lives in CI** (Actions secret). Preferred over
  pure-manual publish because the read-only gate then runs automatically on every
  release.

### D7 — Version coupling: `package.json` `version` is the single source of truth

- `package.json` `version` → drives the **Docker image tag**
  (`claude-orchestrator:<version>`, alongside `:latest`) and is the cco release
  version surfaced by the CLI.
- The **pinned Claude Code version** stays an independent knob
  (`~/.cco/claude-version` / `cco build --claude-version`, ADR-0039) — Claude Code
  auto-updates in the CACHE install and is **not** coupled to the package version.
- `cco update` migrations and `changelog.yml` are unaffected by the package living
  under `node_modules`: the update engine writes only to `~/.cco` / STATE / the
  user's repos, **never** into the package (guaranteed by the D5 gate).

### D8 — `cco update` becomes provenance-aware (full orchestration deferred)

`npm update -g @claude-orchestrator/cco` updates the **engine**; `cco update` runs
**migrations + discovery**. The confusion is real. v1 minimum: `cco update` detects
the **install provenance** (clone / npm / brew) and **prints the right
engine-update command** ("installed via npm → run
`npm update -g @claude-orchestrator/cco`, then `cco update --migrate`"). The full
orchestration (cco update runs the engine update itself) + the split of update
responsibilities belongs to the **update-refactor workstream**, not here.

### D9 — Docs: single source `docs/users/`, three consumers

One home — the repo's **`docs/users/`** tree — serves all readers:

1. **Internal agent mounts** (config-editor, tutorial) — `docs/users` only
   (decision 1a: user guides suffice; agents help a *user* configure, they do not
   need maintainer docs/source).
2. **Local human reader** — a light **`cco docs`** surfaces the packaged
   `docs/users` on the host (offline, always matched to the installed cco version).
   This is the v1 "single home" baseline.
3. **Public web** — a GitHub Pages renderer publishes the **same** `docs/users/`
   from `main` (free for public repos). One *source*, multiple *renderers* → no
   second copy, no drift (aligns with `documentation-lifecycle.md`).

- **Pages content in v1 = `docs/users/` only.** `docs/maintainers/` stay public
  and navigable on the GitHub repo (normal contributor workflow) but are not
  rendered as a polished site (they hold WIP handoffs/reviews/in-progress ADRs and
  would muddy the user audience). A separate "Architecture/Contributing" Pages
  section, sourced selectively from `foundation/design` + ADRs (excluding
  handoffs/reviews/archive), is **reserved as a post-v1 additive**.

## Alternatives considered

- **Unscoped `claude-orchestrator` / `cco`** — both taken on npm; not available.
- **Prebuilt proxy binary in the package** — dead weight (Linux-container-only),
  adds a multi-arch matrix; rejected (D4).
- **`postinstall` Docker build** — slow, needs Docker, breaks in CI; rejected (D1).
- **Per-repo `npm i`** — version diverges per repo, wrong model for a host-level
  orchestrator; rejected (D1).
- **Relocate the single `USER_CONFIG_DIR` default** (handoff §7.3 literal) —
  conflates migration-source and writable-runtime roles; superseded by the
  **split** in D5.
- **Two docs sources (package copy + hand-maintained Pages site)** — drift risk;
  rejected in favour of one source / many renderers (D9).
- **Homebrew for v1** — deferred post-v1 (npm-only first).

## Consequences

- **Positive**: one `npm i -g` install; read-only-safe package; automated,
  gated release; a single docs source that serves agents, the local user, and the
  public web; clean separation of engine-update vs cco-update responsibilities.
- **Cost / follow-ups**:
  - Implementation must add `package.json` + `files`/`.npmignore`, the
    `USER_CONFIG_DIR` split (D5), `cco docs` (D9), the read-only test (D5), the CI
    workflow + `release.sh` (D6), the Pages action (D9), and re-point the
    config-editor mount + tutorial at `docs/users` (D3).
- **Deferred / out of scope**: Homebrew (post-v1); the `cco update` orchestration
  + responsibility-axis split (update-refactor workstream). The
  `defaults/global/.claude/settings.json` decomposition (§7.6) is now **resolved in
  D10** (classification done; Class-O extraction handed to workstream F; no v1
  settings change).

## D10 — `settings.json` decomposition (resolves O1, §7.6)

Design session 2026-06-30 classified every key across both settings files into
three classes (code-grounded; cco always launches `claude --dangerously-skip-permissions`,
`config/entrypoint.sh:261,267`):

| Class | Keys | Home | Lifecycle |
|---|---|---|---|
| **F — Functional/immutable** | `hooks` (SessionStart, SubagentStart, PreCompact, UserPromptSubmit) · `statusLine` · `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` · `permissions.deny` | `defaults/managed/managed-settings.json` (baked, non-overridable) | **Already correct** — this IS cco's operation; a user override would break it. |
| **D — Functional default** | `teammateMode: tmux` · `enableAllProjectMcpServers: true` | `defaults/global/.claude/settings.json` (copied to `~/.cco`, user-editable) | cco needs a sane value; user may change. Stays in global (decision below). |
| **O — Opinionated** | `permissions.allow[…]` · `attribution.commit/pr` · `cleanupPeriodDays` · `alwaysThinkingEnabled` | `defaults/global/.claude/settings.json` today | Extraction target for **workstream F** (opinionated-extraction). |

**Decisions:**
- **The functional/immutable layer is already correctly in `managed`** → **C/packaging
  changes no settings file for correctness.** This decomposition is design input,
  not v1 code.
- **`enableAllProjectMcpServers` stays in global (Class D), not promoted to managed.**
  The primary MCP path (entrypoint injects into `~/.claude.json`, `config/entrypoint.sh:118`)
  works regardless; immutability would remove user choice for little gain. The key
  only supports the `.mcp.json` *fallback*.
- **`permissions.allow` is left intact in v1** and its extraction/removal is deferred
  to **workstream F**. Finding: it is **inert inside cco sessions** —
  `--dangerously-skip-permissions` bypasses the permission prompt gate (official
  Claude Code docs: managed/user `allow` lists feed the permission system, which
  bypass mode skips), so the allow-list is vestigial. It is the prime Class-O
  removal target for F, not a C concern.

**Carried out of this ADR:**
- **Class O extraction → workstream F** (`../opinionated-extraction-and-update-refactor-handoff.md`,
  ADR-0040): make the public default *neutral*, opinions become an opt-in layer.
- **Security finding → backlog** (`../roadmap-backlog.md`): verify whether managed
  `permissions.deny` is actually enforced under `--dangerously-skip-permissions`
  (bypassPermissions). If not, the security backstop is decorative and cco would
  need `allowManagedPermissionRulesOnly` / `permissions.disableBypassPermissionsMode`
  (official docs) — or accept that Docker-is-the-sandbox is the real boundary and
  the deny is informational. Investigate separately; does not block packaging.

## Open items (carried, not blocking the design)

- **O2 — npm org creation** is a maintainer action (free; requires an npm account).
  The package name `@claude-orchestrator/cco` is reserved by this decision but must
  be claimed (the GitHub org is taken → repo stays personal, see D2). Fallback
  `@alergyonthestage/cco` needs no org.
