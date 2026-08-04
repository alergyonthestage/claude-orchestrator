# Config Editor Safety Rules

## Before Modifying Files
- Check if the file exists before writing — show the diff if overwriting.
- For `project.yml` edits, validate YAML structure after changes; keep it
  machine-agnostic (logical names + coordinates, never real host paths).
- For `pack.yml` edits, run `cco pack validate <name>` (available in-session via
  the wrapped `cco` — see below).

## Two Edit Mechanisms
- **Hand-edit** the config files that live by convention as YAML/text: a target
  project's `<repo>/.cco` (at `/workspace/<name>-config`) and — **only when the store
  is writable in this session** — the personal store `~/.cco` (at
  `/workspace/cco-config`). In the default **project mode the store is mounted
  read-only** (you reference it, don't edit it); editing it needs global/all mode or
  `--cco-access edit-global`. Run `cco whoami` if unsure.
- **Mutate framework-internal state only via `cco`** — the tags registry, remotes
  registry, the index, and install `source` records are NEVER hand-edited (they
  live in hidden XDG dirs and are corruption-prone). Use `cco tag …`,
  `cco remote add|remove`, `cco pack|template|llms …` instead.

## Wrapped `cco` in this session (ADR-0036 D4)
`cco` runs **inside this container** behind a whitelist shim (container-operator
mode), operating on the real, bind-mounted config buckets. You can run:
- **Read** (any mode): `cco list`, `cco … show`, `cco … validate`, `cco docs`,
  `cco path list`, `cco list remotes`, `cco project coords`.
- **Write**: gated by this session's mode.
  - *Project writes* (`cco tag add|remove` on the current project) work in project
    mode (`Pc=rw`).
  - *Store writes* (`cco pack|template|llms create|update|remove|install|import`,
    `cco remote add|remove`, `cco config save`) need **`G=rw`** — global/all mode, or
    project mode started with `--cco-access edit-global`. Otherwise refused with a
    "needs edit-global" hint (the store is mounted read-only).

config-editor always **reads** the whole store (its `G` is floored to `≥ ro`), so the
read verbs above are never scope-hidden for global-class resources. If a session is
explicitly narrowed with `--cco-access` to a read level, read output is scoped
(ADR-0043) with a count-only "hidden by access scope" notice on stderr — a hidden
resource is not a missing one (widen or run on the host).

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
- `cco config save` writes the store → needs a store-writable session (global/all, or
  project mode + `--cco-access edit-global`); in default project mode it is refused.
  After significant store edits (in the right mode), run `cco config save` in-session
  or remind the user to run it on the host; **`cco config push`/`pull` are host-only**.
- To review pending changes: `git -C /workspace/cco-config status` / `diff`.
- For sharing/publishing, reference the **sharing repo** flow
  (`cco pack publish` / `cco pack install`) — there is no `manifest.yml`.
