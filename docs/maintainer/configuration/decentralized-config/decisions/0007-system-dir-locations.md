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
4. **CONFIG / personal store keeps the `~/.cco` dotdir as a git working tree**
   (Domain A): packs, templates, global `.claude` — a `git init`'d dir at `~/.cco/.git`
   with an opt-in personal remote, where `cco` thinly wraps git (the `pass` model). It
   is deliberately *not* moved under `$XDG_CONFIG_HOME/cco`. Rationale below (§"Personal
   store as a git working tree"). Clean UX split: **`~/.cco` = what you edit and version;
   `~/.local/state/cco` + `~/.cache/cco` = machine-internal plumbing you never touch.**
   Its *management depth* (who commits, allowlist enforcement, conflict UX) remains
   owned by RD-home.

## Personal store as a git working tree (`~/.cco`)

The personal store needs a cross-PC transport, and AD8 already fixes **git as the only
one** — so the store needs a git boundary. Making the `~/.cco` dotdir *itself* the
working tree (vs. a separate source repo, vs. living inside the user's own dotfiles
repo) is the right boundary for cco specifically:

- **Correct precedent is `pass`, not docker/cargo.** `~/.docker` / `~/.cargo` are dotdir
  *homes* but **not** git repos with remotes; they justify the *naming*, not the
  *git-repo* model. The battle-tested precedent for "a tool owns a dotdir, `git init`s
  it in place, auto-commits mutations, and offers `tool git push/pull` to a user-chosen
  remote" is **`pass`** (`~/.password-store` + `pass git`); a clean `~/.config/nvim`
  under a personal git remote is a second precedent.
- **Dotdir-as-repo is clean *only* when the dir holds authored content only.** The
  frictionless cases (pass, nvim config) commit only authored files and push state/cache
  elsewhere; the cases that fight `.gitignore` (oh-my-zsh) or need `showUntrackedFiles=no`
  crutches (yadm, bare-repo dotfiles) do so precisely because their work-tree mixes
  generated/foreign files — which is the whole reason chezmoi/yadm separate a source repo
  from the live dir. **RD-paths already evicted all state/cache/index to XDG**, so
  `~/.cco` holds *only authored config* — exactly the precondition that makes the
  in-place repo model clean, and which removes the main reason to adopt the
  chezmoi/yadm separation.
- **The project↔user asymmetry is the normal pattern, not a smell.** `<repo>/.cco/` is
  versioned *inside the code repo* (it piggybacks on a repo that already exists); `~/.cco/`
  is *its own repo* (because `$HOME` has no carrier repo). "Same name, scope decided by
  location; project config rides the project's VCS, user config gets its own
  persistence" is exactly how git (`<repo>/.git` vs `~/.gitconfig`), eslint, and vscode
  resolve dual-scope config. The shared `.cco` name is a coherence win. **Caveat:**
  `<repo>/.cco/` must never be `git init`'d (no nested repo); the only `.git` cco owns
  is `~/.cco/.git`.
- **Guardrails (owned by RD-home, noted here):** like `pass`, cco auto-commits its own
  mutations with structured messages and exposes `cco sync`/`cco <git-subcommand>`;
  stage **explicit paths, never `git add -A`**; ship a committed whitelist `.gitignore`
  in `~/.cco`; the remote is opt-in and should be **private**; the framework 3-way merge
  engine (`cco update`) stays pointed at defaults and **out** of the personal store's
  history.
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
| **Personal store as a separate source repo + deployed view (chezmoi/yadm)** | Strong source/live separation; per-machine templating | Render/apply step + drift; name-mangling or `--work-tree` plumbing; unjustified since `~/.cco` is already authored-content-only (nothing to template) | Rejected |
| **Personal store lives inside the user's own dotfiles repo (not its own repo)** | Zero new remote/auth for users who already sync dotfiles | Couples cco to a dotfiles setup most users lack; cco surrenders its own sync UX; `~/.cco` becomes a guest in a foreign whitelist | Rejected |
| **XDG state/cache/index; `~/.cco` dotdir-as-git-repo for config (chosen)** | Spec-correct STATE/CACHE; honors `XDG_*`; macOS parity; clean UX split; no legacy migration; `pass` precedent + authored-only precondition already met → clean in-place repo | Two conventions coexist (XDG plumbing + `~/.cco` store) — accepted as the clearest mental model | **Accepted** |

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
