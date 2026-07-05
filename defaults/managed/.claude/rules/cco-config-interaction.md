# cco Config Interaction

How to interact with cco's own configuration from inside a session — through the
**wrapped `cco`** (the CLI available in-container behind a whitelist shim) and the
mounted config trees. Your session's access level is stated in the cco session
context (`<CcoSessionInfo>`): `cco_access` is one of `none` · `read-project` (the
normal default) · `read-global` · `read-all` · `edit-project` · `edit-global` ·
`edit-all`. Apply the sections below according to that level. `cco whoami` reports
your session's own access state (levels + which config trees are rw vs ro).

## When `cco_access = none`

The wrapped `cco` is **not available** — every invocation is refused (exit 2). Do
not attempt cco commands; the session context lists your resources directly. If you
genuinely need cco introspection/config, ask the user to restart with
`--cco-access read-project` (the default) or higher.

## Access-scope awareness (any read level)

The wrapped `cco`'s read verbs (`cco list`, `cco <kind> show`, `cco … validate`,
`cco path list`, `cco project coords`) scope their **output** to your access
level, **symmetric** with the write side on `{project, global, all}` — each level
reads at its matching scope (ADR-0043):

- **project scope** (`read-project` **and** `edit-project`): a
  **project-scoped view** of `~/.cco` — read verbs show only the current project and
  the packs/llms it references. Templates, other projects, and unreferenced packs are **hidden — a
  subset, not the whole store.** A one-line count-only notice on stderr says how
  many were hidden. **A hidden resource is not a missing one:** never conclude "it
  does not exist" from an empty or short result. To see more, start a `read-global`
  session (`cco start <project> --cco-access read-global`) or run `cco` on your host.
- **global scope** (`read-global` / `edit-global`): the whole personal store
  (packs/llms/templates/remotes) is visible, but **other projects stay hidden** —
  that is the *only* difference from `all`. Use `read-all` to see other projects.
- **all scope** (`read-all` / `edit-all`): everything, including other projects.

Note `edit-project` READS at project scope (like `read-project`); it does not see
the whole store. Its edit power is over the project's own `<repo>/.cco`, nothing
global (a global-store write needs `edit-global`+, refused otherwise at exit 2).

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
- **config-editor: introspect the TARGET, not `PROJECT_NAME`.** In a config-editor
  session `PROJECT_NAME` is always `config-editor`; the projects you may edit are
  named in `CCO_CONFIG_TARGETS` (set by `cco start config-editor --project <name>`)
  and their `.cco` is mounted at `/workspace/<name>-config/`. When validating or
  reasoning about a target, use its name (`cco project show <target>`,
  `cco project validate <target>`), never `PROJECT_NAME`.

## Host-only verbs (any level)

Container-spawning, path-resolving, and network/credential verbs are refused
in-session with a hint: `cco start|stop|build|new`, `cco resolve|sync|init|join|
forget|update|clean`, `cco project rename`, `cco config push|pull`, and
`cco remote set-token|remove-token`. When one is needed, hand the user the exact
command to run on their **host** terminal (use the session path map for the host
path when `show_host_paths` is on). Never paste host paths into commits, PRs, or
external calls — committed config stays machine-agnostic.
