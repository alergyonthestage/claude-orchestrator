# cco Config Interaction

How to interact with cco's own configuration from inside a session — through the
**wrapped `cco`** (the CLI available in-container behind a whitelist shim) and the
mounted config trees. Your session's access level is stated in the cco session
context (`<CcoSessionInfo>`): `cco_access` is one of `read-project` (the normal
default) · `read-global` · `read-all` · `edit-project` · `edit-global` ·
`edit-all`. Apply the sections below according to that level.

## Access-scope awareness (any read level)

The wrapped `cco`'s read verbs (`cco list`, `cco <kind> show`, `cco … validate`,
`cco path list`, `cco project coords`) scope their **output** to your access
level (ADR-0043):

- At **`read-project`** you get a **project-scoped view** of `~/.cco`: read verbs
  show only the current project and the packs/llms it references. Templates,
  other projects, and unreferenced packs are **hidden — a subset, not the whole
  store.** A one-line count-only notice on stderr says how many were hidden.
  **A hidden resource is not a missing one:** never conclude "it does not exist"
  from an empty or short result. To see everything, start a `read-global` /
  `read-all` session (`cco start <project> --cco-access read-global`) or run
  `cco` on your host.
- At **`read-global` / `read-all`** (and any `edit-*`) the read verbs show the
  full set.

## Editing config (only at an `edit-*` level)

Only when `cco_access` is an edit level may you modify cco config. Then:

- **Verify before you edit and before you commit.** Check `git status` / `git
  diff` of the tree you are touching — a project's committed `<repo>/.cco/` (in
  its repo) or the personal store `~/.cco` — so you never commit unrelated or
  unintended changes.
- **Commit atomically.** One logical config change per commit; leave the tree in
  a working state. Use `cco config save` for the personal store `~/.cco`. For a
  project's committed `<repo>/.cco/`, commit with the repo's own git (a dedicated
  `cco project save` is forthcoming; until it lands, use git directly or hand the
  user the commit to run on the host).
- **Keep committed config machine-agnostic.** `project.yml` carries logical names
  + coordinates (`url` / `ref` / `variant`), never real host paths. Validate YAML
  after edits (`cco project validate`, `cco pack|template validate`).
- **Never write secrets into a committed file.** Real secret files
  (`secrets.env`, `*.env` / `*.key` / `*.pem`) are filtered out of every mount —
  you only ever see and edit the committed `*.example` skeletons. `secrets.env`
  is host-edited; remote tokens stay host-only.
- **Mutate framework-internal state only via `cco`.** The machine-local index,
  the tags registry, the remotes registry, and install `source` records live in
  hidden XDG dirs and are corruption-prone — never hand-edit them. Use
  `cco tag …`, `cco remote add|remove`, `cco pack|template|llms …` instead.

## Host-only verbs (any level)

Container-spawning, path-resolving, and network/credential verbs are refused
in-session with a hint: `cco start|stop|build|new`, `cco resolve|sync|init|join|
forget|update|clean`, `cco project rename`, `cco config push|pull`, and
`cco remote set-token|remove-token`. When one is needed, hand the user the exact
command to run on their **host** terminal (use the session path map for the host
path when `show_host_paths` is on). Never paste host paths into commits, PRs, or
external calls — committed config stays machine-agnostic.
