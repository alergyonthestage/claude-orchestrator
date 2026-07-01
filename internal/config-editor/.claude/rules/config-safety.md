# Config Editor Safety Rules

## Before Modifying Files
- Check if the file exists before writing — show the diff if overwriting.
- For `project.yml` edits, validate YAML structure after changes; keep it
  machine-agnostic (logical names + coordinates, never real host paths).
- For `pack.yml` edits, run `cco pack validate <name>` (available in-session via
  the wrapped `cco` — see below).

## Two Edit Mechanisms
- **Hand-edit** the config files that live by convention as YAML/text: the
  personal store `~/.cco` (mounted at `/workspace/cco-config`) and any target
  project's `<repo>/.cco` (at `/workspace/<name>-config`).
- **Mutate framework-internal state only via `cco`** — the tags registry, remotes
  registry, the index, and install `source` records are NEVER hand-edited (they
  live in hidden XDG dirs and are corruption-prone). Use `cco tag …`,
  `cco remote add|remove`, `cco pack|template|llms …` instead.

## Wrapped `cco` in this session (ADR-0036 D4)
`cco` runs **inside this container** behind a whitelist shim (container-operator
mode), operating on the real, bind-mounted config buckets. You can run:
- **Read**: `cco list`, `cco … show`, `cco … validate`, `cco docs`,
  `cco path list`, `cco list remotes`, `cco project coords`.
- **Write** (this session is `edit-all`): `cco tag add|remove`,
  `cco remote add|remove`, `cco pack|template|llms create|update|remove|install|import`,
  `cco config save`.

**Host-only** verbs are refused in-session with a hint — show the user the exact
command to run on their **host** terminal (use the path map for the host path):
container-spawning (`cco start|stop|build|new`), path-resolving lifecycle
(`cco resolve|sync|init|join|forget|update|clean`, `cco project rename`), and
network/credential ops (`cco config push`/`pull`, `cco remote set-token`/`remove-token`).

## Protected Content
- **Never** write real secret values into a committed file. Real secret files
  (`secrets.env`, `*.env`/`*.key`/`*.pem`) are **filtered out** of every mount —
  you only ever see and edit the committed `*.example` skeletons. Remote tokens
  stay host-only. `secrets.env` is host-edited.
- **Never** delete projects or packs without explicit confirmation.

## Host Paths
- With `show_host_paths` on (default), read output and the session path map show
  the **user's host paths**, bind-mounted here at `/workspace/<target>`. They are
  the user's own machine paths — use them to hand the user copy-pasteable **host**
  commands.
- **Do NOT** paste host paths into commits, PRs, or external calls — committed
  config stays machine-agnostic (logical names + coordinates only).

## Versioning & Sharing Awareness
- After significant edits to `~/.cco`, run `cco config save` (in-session) or
  remind the user to run it on the host; **`cco config push`/`pull` are host-only**.
- To review pending changes: `git -C /workspace/cco-config status` / `diff`.
- For sharing/publishing, reference the **sharing repo** flow
  (`cco pack publish` / `cco pack install`) — there is no `manifest.yml`.
