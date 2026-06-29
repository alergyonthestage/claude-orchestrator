# ADR 0039 — Install Claude Code via the native installer (auto-update in place)

**Status**: Accepted (2026-06-29)
**Deciders**: maintainer + implementation session
**Context docs**: `../design/design-docker.md` §1.2.1; `../native-claude-install-handoff.md`
(Handoff E); official Claude Code docs (llms) on the native installer and the npm
deprecation
**Related ADRs**: **0007 (XDG 4-bucket model — CACHE home)**, **0015 (DATA bucket /
bucket map)**, **0028 (flat `~/.cco/.claude`)**, **0027 D3 (`<repo>/.cco` :ro overlay)**
**Origin**: re-implementation of Rares' `feature/roadmap-item-#B2` (legacy single
commit `c3624f4` on base `d30b82f`/v0.3.0), re-homed onto develop's architecture.

---

## Context

`cco` baked Claude Code into the image with `npm install -g @anthropic-ai/claude-code`
plus `ENV DISABLE_AUTOUPDATER=1`. This method is **officially deprecated** (Claude
Code's own `/doctor` warns about `~/.local/bin/claude`, and the docs emit a
"deprecation notification for npm installations — run `claude install`"). The npm
layout has two structural problems:

1. The npm global dir is **root-owned**, so the non-root `claude` user cannot write
   to it — the auto-updater is disabled and every upgrade requires
   `cco build --no-cache` (a full image rebuild).
2. With npm the OS auth-grant does **not** persist across updates; with the native
   installer it does.

The official method is `curl -fsSL https://claude.ai/install.sh | bash`, which
accepts a release channel (`latest` / `stable`) or a specific version via
`bash -s <value>`. Rares' approach (install at runtime into a persistent dir) is
correct and aligned with this; it could not be cherry-picked because it was written
~360 commits back, before the decentralized-config XDG buckets replaced `$GLOBAL_DIR`.

## Decision

Install Claude Code **at first container start**, into a persistent host-side CACHE
dir bind-mounted into the container, and let it **auto-update in place**.

### D1 — Install home = CACHE, bind-mounted into `~/.local`

A new helper `_cco_claude_install_dir()` → `$(_cco_cache_dir)/claude-install`. Its
`bin/` and `share/` subdirs are bind-mounted (`rw`) to `/home/claude/.local/bin` and
`/home/claude/.local/share/claude`. CACHE is the right bucket: the install is fully
**re-fetchable** from `install.sh`, and `cco clean` never scans CACHE — so the
install survives `cco clean --all` (decision 3 of the handoff). The dirs are
pre-created host-side by `cmd-start` (so the mount attaches to a dir, not a file) and
defensively by the entrypoint, which also `chown`s them to `claude` (the host uid may
differ; on macOS Docker Desktop the `chown` is a harmless no-op).

### D2 — Dockerfile no longer bakes the binary

Remove `RUN npm install -g @anthropic-ai/claude-code` and `ENV DISABLE_AUTOUPDATER=1`.
Keep `ARG CLAUDE_CODE_VERSION=latest`, promote it to `ENV` (the baked channel/version
default the entrypoint forwards to the installer), and add
`ENV PATH="/home/claude/.local/bin:${PATH}"`. The auto-updater is left **enabled** —
the writable persistent mount means Claude Code updates itself across restarts with no
rebuild.

### D3 — Channel/version is a CONFIG knob, default `latest`

The persistent preference lives in `~/.cco/claude-version` (CONFIG bucket,
git-versioned), a single value: a channel (`latest`/`stable`) or a pinned `x.y.z`.
`_cco_claude_version_pref` reads it (default `latest`). The maintainer wants new
models immediately, so `latest` is the shipped default; `stable`/pinning is opt-in.

`cco start` forwards the knob as `CLAUDE_CODE_VERSION` **only when the knob file
exists**. When it is absent the container uses the image's baked default. This makes
the precedence coherent:

- knob set → the knob wins (the explicit, persistent user preference);
- knob absent → the baked image default wins, so `cco build --claude-version X`
  re-pins a knob-less install (the "one-off override").

`cco build` bakes the effective default into the image: `--claude-version` flag, else
the knob, else `latest`.

### D4 — Re-pin via a channel marker

Installing only "when the binary is absent" (Rares' v1) cannot switch an
already-installed version. The entrypoint persists the last-installed request in
`.local/bin/.cco-claude-channel` and reinstalls when the binary is **absent** OR the
marker **differs** from the requested `CLAUDE_CODE_VERSION`. The marker is compared
(not `claude --version`) because a bare channel string like `latest` is not a version
number — a naive version compare would reinstall on every start. The marker lives in
`bin/` (a bind-mounted, persistent dir); the install-dir root is not mounted.

### D5 — `cco build --no-cache` resets the install cache

A pure image rebuild no longer affects the binary (it lives in CACHE, not the image),
so `--no-cache` also `rm -rf`s `$(_cco_claude_install_dir)` → the next start performs
a clean install of the current default.

## Alternatives considered

- **Keep npm + `DISABLE_AUTOUPDATER`** — rejected: officially deprecated, no in-place
  auto-update, rebuild required for every upgrade, `/doctor` warning.
- **Install into the image at build via the native installer** — rejected: defeats
  the auto-update-in-place goal; the binary would be immutable in the image layer and
  upgrades would still need a rebuild.
- **Install-only-if-absent (Rares' v1)** — rejected: cannot re-pin an installed
  version; D4's marker compare fixes this.
- **Marker = `claude --version` compare** — rejected: a channel request (`latest`) is
  not a version string, so it would never match and reinstall every start.
- **Env-only knob (no config file)** — rejected (decision 1): no persistent per-host
  preference; the CONFIG knob versions the choice with `~/.cco`.
- **A migration to pre-create the install dir** — dropped (handoff re-evaluation):
  nothing migrates (no file moves); the XDG buckets are bootstrapped by J0 and the
  dir is created defensively by `cmd-start` + the entrypoint. The change is purely
  additive (changelog #24).

## Consequences

- First start on a fresh machine adds ~30s for the one-time install (acceptable;
  once per cache). Network is required at first start — the entrypoint fails loud
  (`exit 1`) if the fetch fails.
- Upgrades no longer require `cco build`; the auto-updater keeps `latest`/`stable`
  current in place.
- `cco build --no-cache` becomes "reset + reinstall on next start" in addition to
  rebuilding image layers.
- The image is smaller and builds faster (no npm install of Claude Code).

## Implementation

- `lib/paths.sh` — `_cco_claude_install_dir` (CACHE), `_cco_claude_version_file` +
  `_cco_claude_version_pref` (CONFIG knob).
- `Dockerfile` — drop npm install + `DISABLE_AUTOUPDATER`; `ENV CLAUDE_CODE_VERSION`;
  `ENV PATH` prepend.
- `config/entrypoint.sh` — install/re-pin block (gosu claude, marker compare, fail
  loud).
- `lib/cmd-start.sh` — pre-create install dirs; bind-mount `bin`/`share`; forward
  `CLAUDE_CODE_VERSION` when the knob is set.
- `lib/cmd-build.sh` — bake the effective channel/version; `--no-cache` wipes the
  install cache.
- Tests: `test_paths` (helpers), `test_start_dry_run` (mounts + env), `test_build`
  (build-arg precedence + cache reset), `test_clean` (install survives `--all`).
- changelog.yml #24 (additive). No migration (purely additive).
