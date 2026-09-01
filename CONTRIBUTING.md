# Contributing to claude-orchestrator

Thank you for your interest in contributing! This guide will help you get started.

## Getting Started

1. **Fork** the repository
2. **Clone** your fork locally
3. **Set up local development** — see [Local development](#local-development) below
4. **Read** the [architecture docs](docs/maintainers/foundation/design/architecture.md) to understand the system design

## Local development

End users install the published CLI with `npm install -g @claude-orchestrator/cco`.
To hack on cco itself, use the **developer execution mode** (`--dev`,
[ADR-0060](docs/maintainers/engineering/decisions/0060-developer-execution-mode.md))
instead of pointing your global `cco` at the clone. `--dev` forks the **Docker
image** your session runs (`claude-orchestrator-dev` instead of
`claude-orchestrator`) and the **internal buckets** (STATE/DATA/CACHE, isolated
under `~/.cco-devsandbox`), while leaving your real `~/.cco` and every repo's
`<repo>/.cco` **shared** with your normal sessions — so a dev run still tests
your actual configuration, and never clobbers the image or state a real session
depends on. Both CLIs — the published one and your clone — stay installed side
by side; you never need your global `cco` to *become* the clone:

```bash
git clone https://github.com/<you>/claude-orchestrator.git ~/claude-orchestrator
cd ~/claude-orchestrator

bin/cco --dev build          # build claude-orchestrator-dev:latest from your working tree,
                              # leaving claude-orchestrator:latest (your real image) untouched
bin/cco --dev start <project>  # run a session on the dev image + isolated buckets,
                                # against your real ~/.cco and <repo>/.cco
bin/test                     # run the full test suite (dry-run, no Docker needed)
```

⚠ **This is today's shape, not the target one.** `--dev` ships in `0.7.0`
([ADR-0060 D1](docs/maintainers/engineering/decisions/0060-developer-execution-mode.md)),
and until that's the version you have installed globally, the **published**
`cco` doesn't understand `--dev` at all — invoke your clone **by path**, as
above (`bin/cco --dev …` from inside the clone, or the full path from
anywhere). Once `0.7.0` is published, any `cco --dev <verb>` — run from your
globally-installed `cco`, from any cwd — resolves your clone and hands off to
it automatically, so `bin/cco --dev …` becomes optional rather than required.
That resolution checks, in order: `--dev=<path>`, `$CCO_DEV_REPO`, walking up
from your cwd to an enclosing clone, then a `~/.cco/dev-repo` file holding the
path — so setting one of those now (e.g. `echo ~/claude-orchestrator >
~/.cco/dev-repo`) means you're ready the moment you upgrade. A shell alias such
as `alias cco-dev='cco --dev'` is a convenience you set up yourself, not
something cco ships.

Running your clone's `bin/cco` **without** `--dev` is legitimate (it's how you'd
build the real, published image from your working tree) but tags
`claude-orchestrator:latest` — the image your real sessions use — with clone
code; cco prints a one-line reminder each time you do this, precisely so it's
never a surprise.

`cco` resolves its framework root from the script location (a `readlink` loop in
`bin/cco`), so it works from any clone path or symlink. The framework tree is
treated as **read-only at runtime** — never write into it; machine-local state
lives under `~/.local/state/cco`, `~/.cache/cco`, and `~/.local/share/cco`.

## Reporting Bugs

Open a [GitHub Issue](../../issues/new?template=bug_report.md) with:
- Steps to reproduce
- Expected vs actual behavior
- Your environment (OS, Docker version, Claude Code version)

For security vulnerabilities, see [SECURITY.md](SECURITY.md).

## Proposing Features

Open a [GitHub Issue](../../issues/new?template=feature_request.md) describing:
- The problem you're trying to solve
- Your proposed solution
- Alternatives you considered

**Tip:** Run `cco start tutorial` to launch an interactive session with an agent that knows the full codebase and documentation. Use it to explore architecture, clarify design decisions, evaluate ideas for consistency with the current design, or get guidance before writing a proposal.

## Submitting Changes

### Branch Strategy

- **`main`**: stable releases only. Never push directly.
- **`develop`**: active development. PRs go here.
- Feature branches: `feat/<scope>/<description>` (e.g., `feat/cli/add-edit-command`)
- Fix branches: `fix/<scope>/<description>` (e.g., `fix/entrypoint/socket-gid`)

### Workflow

1. Create a feature branch from `develop`
2. Make your changes
3. Run `bin/test` and ensure all tests pass
4. Commit using [conventional commits](#commit-messages)
5. Push to your fork
6. Open a PR targeting `develop`

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add user authentication
fix: resolve race condition in queue processor
docs: update API endpoint documentation
refactor: extract validation logic to shared module
test: add integration tests for payment flow
chore: update dependencies
```

### Code Style

- **Bash 3.2 compatible** — must work with macOS default `/bin/bash`
- Guard empty arrays: `[[ ${#arr[@]} -gt 0 ]]` or `${arr[@]+"${arr[@]}"}`
- Code comments and variable names in **English**
- Documentation files in **English**

### Testing

- Run the full test suite: `bin/test`
- Run one file: `bin/test --file test_<name>` (repeatable; `bin/test --list` shows every test name)
- Run matching tests: `bin/test --filter <substring>`
- Tests are dry-run (no Docker required) — they validate config generation and CLI behavior
- Add tests for new features; update tests for changed behavior

## Project Structure

| Directory | Purpose |
|-----------|---------|
| `bin/cco` | CLI entrypoint |
| `lib/` | CLI modules (one per command group) |
| `config/` | Docker entrypoint, hooks, tmux config |
| `proxy/` | Go Docker socket proxy |
| `defaults/managed/` | Framework infrastructure (baked in image) |
| `defaults/global/` | User defaults (copied on init) |
| `templates/` | Project and pack templates |
| `tests/` | Bash test suite |
| `docs/` | Documentation (user guides, reference, maintainer) |

For detailed architecture, see [docs/maintainers/foundation/design/architecture.md](docs/maintainers/foundation/design/architecture.md).

## Releasing (maintainers)

cco is published to npm as [`@claude-orchestrator/cco`](https://www.npmjs.com/package/@claude-orchestrator/cco).
Releases are cut from `main` with the helper script — **no npm token is needed
locally**; CI publishes via npm Trusted Publishing (OIDC).

```bash
# From a clean `main` (merge develop → main first), with the new semver:
scripts/release.sh <x.y.z>            # bump package.json + tag + push (fast pre-flight)
scripts/release.sh <x.y.z> --dry-run  # preview every step, change nothing
```

What happens:

1. `scripts/release.sh` verifies a clean tree on `main`, that `<x.y.z>` is greater
   than the current `package.json` version, runs the read-only publish gate +
   `npm pack` hygiene check, then bumps `package.json`, commits a
   `chore(release): vX.Y.Z` and **annotated tag**, and pushes with `--follow-tags`.
2. The tag push triggers [`.github/workflows/release.yml`](.github/workflows/release.yml),
   which re-runs the full suite + the read-only `FRAMEWORK_ROOT` gate + the pack
   hygiene check, then `npm publish --access public` using OIDC (short-lived
   credential minted from the GitHub OIDC token + provenance — no stored secret).

Notes:

- **`package.json` `version` is the single source of truth.** Changelog entries
  are added per-feature **during development** (`changelog.yml`), not at release.
- The npm `files` allowlist + `scripts/check-pack-hygiene.sh` keep tests,
  maintainer docs, and build artifacts out of the published tarball.
- The pinned Claude Code version is an **independent** knob (`~/.cco/claude-version`).
- First-ever publish of the package is manual (to configure the Trusted
  Publisher); every subsequent tag publishes with no token.

For the full design and rationale see
[ADR-0037](docs/maintainers/engineering/decisions/0037-npm-packaging-distribution.md)
and the [packaging & distribution design](docs/maintainers/engineering/design/packaging-distribution.md).

## Code of Conduct

Be respectful, constructive, and collaborative. We're building something useful together.
