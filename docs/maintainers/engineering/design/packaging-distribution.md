# Release engineering — npm packaging & distribution

> **Living design doc.** Reflects the current/target design for distributing `cco`
> as an npm package and releasing v1. Decisions are recorded in
> [ADR-0037](../decisions/0037-npm-packaging-distribution.md); this doc details the
> *how*. Rewritten in place as the design evolves (history in git).
> **Status**: design ready for implementation (2026-06-30). No code yet.

## 1. Goal & shape

Ship `@claude-orchestrator/cco` so users install with one command and get the
prefix-free `cco`:

```bash
npm i -g @claude-orchestrator/cco
cco init && cco start <project>
```

The package carries the **entire framework tree** (it is both the runtime *and* the
Docker build context). The image and the Go proxy are built **lazily on the host**,
never at `npm install`. Install location may be **read-only / root-owned** → cco
must never write inside it.

```mermaid
flowchart LR
  U["npm i -g @claude-orchestrator/cco"] --> NM["node_modules/@claude-orchestrator/cco/<br/>(bin lib config defaults internal<br/>templates migrations proxy<br/>docs/users Dockerfile changelog.yml)"]
  NM --> Shim["global bin: cco → bin/cco (symlink)"]
  Shim --> RR["readlink loop → REPO_ROOT = package root"]
  RR --> B["cco build: docker build REPO_ROOT<br/>(Dockerfile + config + proxy)"]
  RR --> S["cco start: mounts user repos + ~/.cco + docs/users"]
  B -. "no postinstall; lazy" .-> S
```

## 2. `package.json` shape

```jsonc
{
  "name": "@claude-orchestrator/cco",
  "version": "0.4.0",            // single source of truth (ADR-0037 D7)
  "description": "Isolated, preconfigured Claude Code sessions in Docker — multi-repo orchestration.",
  "bin": { "cco": "bin/cco" },   // global shim → package root via readlink loop
  "keywords": ["claude", "claude-code", "orchestrator", "docker", "cco", "ai", "agents"],
  "os": ["darwin", "linux"],
  "engines": { "node": ">=18" }, // node only provides the installer/shim, not the runtime
  "license": "MIT",
  "repository": { "type": "git", "url": "git+https://github.com/claude-orchestrator/claude-orchestrator.git" },
  "files": [
    "bin/", "lib/", "config/", "defaults/", "templates/", "internal/",
    "migrations/", "proxy/", "docs/users/",
    "Dockerfile", ".dockerignore", "changelog.yml", "README.md", "LICENSE"
  ]
}
```

Notes:
- `engines.node` only constrains the host that runs `npm`/the shim — `cco` itself
  is bash and shells out to `docker`. Keep the floor low (`>=18`).
- The `files` array is the **single authoritative mechanism** (default-deny). npm
  does **not** let `.npmignore` subtract from a path listed in `files`, so the few
  in-tree exclusions are done with `files` **negations**, not a second denylist:
  - `bin/cco` (not `bin/`) — keeps the `bin/test` runner out.
  - `!proxy/**/*_test.go`, `!proxy/**/cco-docker-proxy` — Go tests + any built
    binary stay out (the proxy is compiled in the image build, D4).
  - `!docs/README.md` — the docs root index lives outside `docs/users`.
  - `templates/project/base/secrets.env` is an intended scaffold **placeholder**
    and **must ship** — do not blanket-exclude `secrets.env`.
  - Junk (`.git`, `.DS_Store`, `node_modules`, `*.swp`) is covered by npm's
    built-in default ignores; no `.npmignore` is needed (a non-functional one would
    only mislead).

### 2.1 Hygiene gate

`npm pack --dry-run` must list **only** the allowlisted tree (verified: 182 files,
~402 kB). A CI check greps the pack manifest for forbidden paths (`tests/`,
`bin/test`, `_test.go`, `reviews/`, `secrets` other than the template placeholder,
`.git`, `user-config/`, `docs/maintainers/`, `docs/README.md`) and fails on any hit.

## 3. Read-only-`FRAMEWORK_ROOT` correctness

### 3.1 Symlink resolution matrix (verify before publish)

The global `cco` shim is a symlink whose depth differs by platform/prefix. The
readlink loop (`bin/cco:13-21`) must land `REPO_ROOT` on the package root in all of:

| Platform | Install prefix | Shim location |
|---|---|---|
| macOS (system node) | `/usr/local` | `/usr/local/bin/cco` → `../lib/node_modules/@claude-orchestrator/cco/bin/cco` |
| macOS (nvm) | `~/.nvm/versions/node/<v>` | `…/bin/cco` → `../lib/node_modules/…/bin/cco` |
| Linux (system node) | `/usr` | `/usr/bin/cco` → `../lib/node_modules/…/bin/cco` |
| Linux (nvm/`npm prefix`) | `~/.npm-global` | `…/bin/cco` → `../lib/node_modules/…/bin/cco` |

Verification = `npm i -g ./<tgz>` on macOS **and** Linux, then `cco --version` and a
no-op command from an arbitrary cwd; assert `REPO_ROOT` equals the package root.

### 3.2 The one write violation and its split fix (ADR-0037 D5)

`USER_CONFIG_DIR` (`bin/cco:42`) is the only default pointing inside the framework,
and it mixes two roles. Split them:

```mermaid
flowchart TD
  V["USER_CONFIG_DIR (today: $REPO_ROOT/user-config)"]
  V --> R1["Role 1: legacy-vault SOURCE<br/>(cco init --migrate reads it)"]
  V --> R2["Role 2: internal runtime ROOT<br/>(tutorial/config-editor WRITE here)"]
  R1 --> F1["keep as CCO_USER_CONFIG_DIR<br/>read-only, migration-only, may be absent"]
  R2 --> F2["new: internal runtime → STATE<br/>$(_cco_state_dir)/internal  (writable)"]
```

- **Role 2 → STATE.** `lib/cmd-start.sh` `_setup_internal_tutorial` /
  `_setup_internal_config_editor` build their `runtime_dir` under a new
  STATE-derived path (a `paths.sh` helper, e.g. `_cco_internal_runtime_dir`), not
  under `USER_CONFIG_DIR`. The `{{CCO_USER_CONFIG_DIR}}` template token kept for
  back-compat is repointed accordingly.
- **Role 1 stays** as the migration read-source; its default leaving the framework
  is harmless (reading a non-existent dir is a no-op; npm users have no legacy
  vault).

### 3.3 Read-only test (the publish gate)

A suite test stages the framework tree into a throwaway dir, `chmod -R 0555` it,
runs the relevant commands with `CCO_FRAMEWORK_ROOT` (and `CCO_USER_CONFIG_DIR`)
pointed appropriately and STATE/CACHE/DATA on a writable tmp, and asserts:

1. `cco build` (build-context read), `cco start tutorial`, `cco start
   config-editor`, `cco update` all succeed.
2. **No file under the read-only tree is created/modified** (a post-run
   `find <ro-tree> -newer <marker>` is empty; the `0555` mode itself would also
   reject any write).

This green run is the **mandatory CI pre-publish gate** (§5). Implemented as
`tests/test_readonly_framework.sh` (stages a `chmod -R a-w` copy of the shipped
trees, runs `cco start tutorial|config-editor --dry-run` from it, asserts success +
no writes under the read-only root + the runtime landing in STATE).

**Bug the gate caught:** `cp -r` of the internal `.claude/` content preserves the
source mode, so on a read-only (npm) framework the STATE runtime copy was itself
read-only — the *next* start's `rm -rf "$runtime_dir/.claude"` refresh then failed.
Fixed by restoring the write bit on both the stale and fresh copies in
`_setup_internal_tutorial` / `_setup_internal_config_editor`.

## 4. Docker build context from an npm install

`cco build` runs `docker build "$REPO_ROOT"` — the context is the installed package
dir. Confirm every build/runtime path derives from `FRAMEWORK_ROOT` / `REPO_ROOT`
(never cwd):

- `Dockerfile`, `config/` (entrypoint, hooks, tmux), `proxy/` (Go source),
  `defaults/managed/` are all in `files` (ADR-0037 D3) → present in context.
- The image tag encodes the version: `claude-orchestrator:<package.version>` plus a
  moving `:latest`. The proxy compiles inside the image build (ADR-0037 D4); the
  host stays Go-free.

## 5. Release pipeline

```mermaid
sequenceDiagram
  participant M as Maintainer (Mac)
  participant G as GitHub (tag + Actions)
  participant N as npm registry
  M->>M: release.sh — bump package.json + changelog.yml + annotated tag
  M->>G: git push --follow-tags  (develop→main already merged)
  G->>G: CI on tag v* — full suite
  G->>G: read-only FRAMEWORK_ROOT gate (§3.3)
  G->>G: npm pack hygiene check (§2.1)
  G->>N: npm publish --access public  (token = Actions secret)
  G->>G: (optional) GitHub Release notes from changelog
```

- **`release.sh`** (local): validates clean tree + on `main`, bumps the version,
  appends/edits `changelog.yml`, creates the annotated tag, pushes.
- **CI-on-tag** (`.github/workflows/release.yml`): matrix or at least Linux runner
  → suite + read-only gate + hygiene check → `npm publish --access public`
  (scoped packages default to restricted; `--access public` is required).
- The **npm token** is a GitHub Actions secret. No token on the maintainer's Mac is
  needed for publish.

## 6. `cco docs` (D9 local renderer)

A thin command that surfaces the packaged `docs/users` on the host:

- `cco docs` → list the user-doc sections (the `docs/users/**` index).
- `cco docs <topic>` → print/page the matching guide (resolve under
  `$REPO_ROOT/docs/users`).
- Read-only, offline, always matched to the installed version. No new dependency
  (use `${PAGER:-less}` / plain `cat` fallback).

The same `docs/users/` tree feeds three consumers: the internal agent mount (the
config-editor/tutorial mount stays at `$REPO_ROOT/docs` → `/workspace/cco-docs`, but
the package ships only `docs/users` so an installed user sees only user docs —
ADR-0037 D3), local `cco docs`, and the Pages source (§7).

## 7. GitHub Pages renderer (additive, free)

A GitHub Action builds a static site from `docs/users/` on `main` and deploys to
Pages (free for public repos). One source, separate renderer — no second copy.

- v1 scope: **`docs/users/` only**.
- Reserved post-v1: an "Architecture/Contributing" section sourced selectively from
  `docs/maintainers/foundation/design` + ADRs (excluding handoffs/reviews/archive).
- The site shows **latest-on-`main`**; the local `cco docs` shows the **installed**
  version — intentional (web = discovery, local = version-accurate).

## 8. Definition of done (traceable to ADR-0037)

- [ ] `package.json` + `files`/`.npmignore`; `npm pack --dry-run` clean (§2, D3).
- [ ] `npm i -g ./<tgz>` yields a working `cco` on macOS **and** Linux (§3.1, D1).
- [ ] `USER_CONFIG_DIR` split; internal runtime → STATE; nothing writes in
      `FRAMEWORK_ROOT` (§3.2, D5).
- [ ] `docs/users`-only contract met by the `files` allowlist; runtime mount
      unchanged (D3).
- [ ] Read-only-`FRAMEWORK_ROOT` test green (§3.3, D5) — the publish gate.
- [ ] `cco docs` surfaces `docs/users` locally (§6, D9).
- [ ] `cco update` provenance-aware: prints the right engine-update command (D8).
- [ ] `release.sh` + CI-on-tag workflow + npm-pack hygiene check (§5, D6).
- [ ] Pages action publishing `docs/users` (§7, D9).
- [ ] Version coupling documented: `package.json` → image tag; Claude pin
      independent (§4, D7).
- [ ] Release: `develop → main`, tag, `npm publish` — the v1 public release.

## 9. Out of scope / deferred

- Homebrew (post-v1).
- `cco update` engine-update orchestration + responsibility-axis split →
  update-refactor workstream.
- `defaults/global/.claude/settings.json` decomposition — **resolved (ADR-0037
  D10)**: 3-class classification done; the functional layer is already immutable in
  `managed-settings.json` so **C ships settings unchanged**; Class-O extraction is
  workstream F.
- npm org creation (maintainer action; ADR-0037 O2; GitHub org taken → repo stays
  personal, D2).
