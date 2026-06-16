# ADR 0007 — System-Dir Locations (state / cache / index, XDG)

**Status**: Accepted (2026-06-16)
**Deciders**: maintainer + design session
**Context docs**: `../requirements.md` (AD5, AD9, FR-S), `../design.md` §2.2-2.3, §3
**Related ADRs**: 0002 (machine-agnostic config + index), 0004 (config/state/cache separation), 0005 (dual-claude scope — RD-claude-mount F1)
**Resolves**: RD-paths (open item of ADR-0002 and ADR-0004)

---

## Context

ADR-0004 mandates that per-machine **state** and regenerable **cache** live in system
directories outside the repo, and ADR-0002 puts the machine-local **index** in a
system dir too — but both left the *exact* per-OS locations open (RD-paths). cco is a
pure-bash CLI run from a terminal on macOS and Linux, and partly from inside the
orchestrator Docker container. Today it has **zero XDG awareness**: by default the
whole `user-config/` tree (config + state + cache + index, separated only by a
`.gitignore`) lives *inside the cco git clone* (`$REPO_ROOT/user-config`,
`bin/cco:22`). The decentralized model dissolves that single root — committed config
moves in-repo (`<repo>/.cco/`) and to the personal store (`~/.cco`); state/cache/index
need concrete homes.

Two data points framed the decision: (1) the XDG Base Directory Specification's own
semantic split (CONFIG / DATA / STATE / CACHE) maps cleanly onto cco's classes, and
its STATE definition — "persist between restarts, but not portable enough … current
state reused on a restart" — is an exact fit for the index, generated compose, and
transcripts; (2) the dominant convention among CLI-native cross-platform tools (gh,
neovim, modern git) is to **reuse XDG paths on macOS too** and honor `XDG_*`, rather
than Apple's `~/Library/...` (awkward from a shell, no boot-time env on macOS).

## Decision

**XDG layout on both OSes** (no `~/Library` on macOS), one `cco/` parent per base,
identical Linux/macOS. Resolution precedence per base: a cco-specific override, then
the generic XDG var, then the spec default.

| Class | Resolution | Default (Linux + macOS) |
|-------|-----------|-------------------------|
| **STATE** | `$CCO_STATE_HOME` → `$XDG_STATE_HOME/cco` → `~/.local/state/cco` | `~/.local/state/cco` |
| **CACHE** | `$CCO_CACHE_HOME` → `$XDG_CACHE_HOME/cco` → `~/.cache/cco` | `~/.cache/cco` |

1. **INDEX lives in STATE**: `<state>/cco/index`. The index is machine-local, never
   committed, never synced, holds host-absolute paths, and is rebuildable by
   `cco index refresh --scan` — the textbook STATE definition, *not* CONFIG (it is
   neither user-authored nor portable; ADR-0002). Putting it in CONFIG would wrongly
   invite hand-editing and cross-machine syncing — the coupling ADR-0002 exists to break.
2. **STATE contents** (`<state>/cco/`): `index`; `projects/<id>/` (generated
   `docker-compose.yml`, `claude-state/` transcripts, `meta`, `.tmp/`); sync-metadata
   (§4.6); the remotes registry + tokens; global `last_seen`/`last_read` trackers;
   seeded `claude.json` / `.credentials.json`.
3. **CACHE contents** (`<cache>/cco/`): `llms/` downloads; `installed/` Config-Repo
   clones; dry-run/`.bak` artifacts; and `projects/<id>/` **generated `.claude`
   overlays** (`packs.md`, `workspace.yml`) — the concrete home for RD-claude-mount's
   F1 (generated files overlaid `:ro` into `/workspace/.claude`, never written into the
   committed `.cco/claude/`).
4. **CONFIG / personal store keeps the `~/.cco` dotdir** (Domain A): packs, templates,
   global `.claude`, a git working tree with an opt-in remote that the user authors in
   directly. It is deliberately *not* moved under `$XDG_CONFIG_HOME/cco` — it is
   user-facing and git-versioned (docker `~/.docker` / cargo `~/.cargo` precedent for a
   tool home the user opens directly), giving a clean UX split: **`~/.cco` = what you
   edit and version; `~/.local/state/cco` + `~/.cache/cco` = machine-internal plumbing
   you never touch.** Its *management depth* remains owned by RD-home.
5. **Override env vars** `CCO_STATE_HOME` / `CCO_CACHE_HOME` rank **above** `XDG_*` so a
   user can relocate cco alone without perturbing every XDG tool (precedent:
   `GH_CONFIG_DIR`, `DOCKER_CONFIG`). They supersede the legacy `CCO_USER_CONFIG_DIR` /
   `CCO_*_DIR` overrides removed by the teardown (design §9).

**Robustness rules** (resolver, host-side):
- Treat an XDG var that is **unset, empty, or non-absolute** as absent and fall back to
  the default (spec compliance — `${VAR:-default}` covers unset/empty; add an explicit
  `[[ $v == /* ]]` guard for the relative case).
- Resolve bases on the **host only**; never compute `$XDG_*` inside the container
  (`$HOME=/home/claude` there). The index stores host-absolute paths that get
  bind-mounted to fixed container paths — the two namespaces must never be conflated.
- Create dirs `mkdir -p` with mode `0700` (the index can reveal project layout). Quote
  every expansion; route values through the existing `expand_path()` (no `~` expansion
  inside quotes). Refuse or warn under root/`sudo` (per-user, not root).

## Alternatives Considered

| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **`~/Library/Application Support` + `~/Library/Caches` on macOS** | Apple-native | Awkward from a shell (spaces), no boot-time env on macOS, breaks one-mental-model parity; CLI users don't expect it | Rejected |
| **Index in CONFIG (`~/.cco` or `$XDG_CONFIG_HOME`)** | "Authoritative" feel | Index is non-portable, generated, scan-rebuildable = STATE not CONFIG; invites hand-edit + cross-machine sync (the exact coupling ADR-0002 breaks) | Rejected |
| **Scatter (no single `cco/` parent per base)** | — | Clutters home with multiple entries per base | Rejected |
| **Move `~/.cco` config store to `$XDG_CONFIG_HOME/cco`** | Uniform XDG everywhere | A git working tree with a remote under `~/.config/cco` is non-idiomatic; loses the clean "yours vs plumbing" UX split | Rejected |
| **XDG state/cache/index; `~/.cco` dotdir for config (chosen)** | Spec-correct STATE/CACHE; honors `XDG_*`; macOS parity; clean UX split; no legacy migration (state/cache/index are new locations) | Two conventions coexist (XDG plumbing + `~/.cco` store) — accepted as the clearest mental model | **Accepted** |

## Consequences

**Positive** — state/cache/index leave the repo clone and the home root stays clean
(at most `~/.local/state/cco` + `~/.cache/cco`, one entry per existing XDG base);
macOS/Linux parity; honors user-set `XDG_*` and cco-specific overrides; pins
RD-claude-mount's F1 location; the index sits where the spec says machine-local
non-portable state belongs.

**Negative** — two location conventions coexist (`~/.cco` config dotdir + XDG
plumbing); a host-side resolver with XDG-validation must be added (natural home:
`lib/paths.sh`); the legacy in-repo `user-config/` default and its `CCO_*_DIR`
overrides are superseded (handled by the breaking-cutover teardown, design §9).

## Notes / out of scope
- **`~/.cco` management depth and any migration from a legacy location** → RD-home.
- **Symlink-installed `cco`** (`bin/cco:11` uses `BASH_SOURCE` without `realpath`, so a
  PATH symlink mis-resolves the *tool* root — distinct from these *data* paths) is a
  pre-existing latent bug worth fixing when path code is touched, but not part of RD-paths.

## Open
None. RD-paths is resolved; closes the open item of ADR-0002 and ADR-0004.
