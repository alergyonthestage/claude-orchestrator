# Config-Editor — Hands-On Configuration

> A built-in session that helps you create and edit your configuration — packs,
> templates, global rules/skills/agents, and project config — with the agent
> writing files for you.
>
> Related: [tutorial.md](./tutorial.md) | [knowledge-packs.md](../../packs/guides/knowledge-packs.md) | [configuration-management.md](../../configuration/guides/configuration-management.md) | [project-setup.md](../../configuration/guides/project-setup.md)

---

## 1. Launch It

```bash
# Global mode: edit your personal config store
cco start config-editor

# Project mode: also edit a specific project's committed config
cco start config-editor --project <name>

# Project mode, repeatable: edit several projects' committed config
cco start config-editor --project <a> --project <b>

# All projects: mount every resolvable project's committed config
cco start config-editor --all
```

`config-editor` is a built-in session — nothing to install or scaffold, and it
never appears in `cco list`. It always reflects your installed version of
claude-orchestrator.

Under the hood, config-editor runs as a **write preset** of the session capability
model (`claude_access=all`), resolved to the **least edit level its scope needs**
(ADR-0044): `cco_access=edit-global` — your personal store `~/.cco` plus, when in
scope, one project's config, all mounted read-write — unless you widen it to
`edit-all` with `--all`. A whitelisted `cco` runs inside the session (see §4). You
can narrow it for a session with an explicit `--cco-access` (e.g. `--cco-access
read-global` for a look-only pass).

Scope is **minimum-privilege by default**:

- **Bare, outside any project** (`cco start config-editor`) → `~/.cco` **only**
  (`edit-global`). No project trees, no code repos.
- **Inside a project** — a cwd hosting a configured repo, or `--project <name>`
  (**repeatable**) → `~/.cco` **plus** that project's `<repo>/.cco/` **and its code
  repos** (still `edit-global`; the project's `.cco` is the `current` tree, so the
  agent can author config against the real repo layout). `--repo <name>` adds a
  single resolvable repo to the mount set.
- **Every project at once** — the **explicit widener** `--all` (or `--cco-access
  edit-all`) → `~/.cco` plus **every** resolvable project's committed `<repo>/.cco/`
  (no code repos; unresolvable projects are skipped), at `edit-all`.

To exit, end the session as usual (or `cco stop config-editor` from another
terminal).

---

## 2. What You Can Safely Do

Unlike the tutorial, config-editor has **read-write** access to your personal
config store, so the agent can create and edit files for you:

- **Knowledge packs** — create a new pack, edit an existing one, add knowledge
  files and rules. Try the `/setup-pack` wizard.
- **Templates** — create and edit project/pack templates.
- **Global config** — refine your global rules, skills, agents, and instructions.
- **Project config** (in project mode) — edit a project's committed `project.yml`,
  its `claude/` tree, CLAUDE.md, and the `secrets.env.example` skeleton. Try the
  `/setup-project` wizard.

The agent works as a careful assistant: it explains what it intends to change and
why, asks before anything destructive, and shows you the exact `cco` commands to
run on your host to validate and save your work.

---

## 3. Modes at a Glance

| Mode | Command | Editable config (level) |
|------|---------|-------------------------|
| **Global** (default, outside a project) | `cco start config-editor` | `~/.cco` only — global config, packs, templates (`edit-global`) |
| **Focused** (inside a project) | `cco start config-editor --project <name>` (repeatable; or run from the repo) | `~/.cco` + that project's committed `<repo>/.cco` **plus its code repos** (`edit-global`) |
| **Broad** (explicit widener) | `cco start config-editor --all` | `~/.cco` + **every** resolvable project's `<repo>/.cco` (no code repos) (`edit-all`) |
| **Add a repo** | `… --repo <name>` | Adds one resolvable code repo to the mount set |

The official documentation is also available to the session (read-only), so the
agent grounds its suggestions in the current docs rather than guesswork.

---

## 4. Saving and Activating Your Changes

A **whitelisted `cco`** runs inside the config-editor session (wrapped-`cco`),
operating on your real, mounted config buckets. So many commands the agent needs
now run in-session — you don't have to shuttle everything to your host terminal.

**Runs inside the session** (edit level = `edit-global` by default, `edit-all` with `--all`):

```bash
cco list                    # discover projects/packs/templates/llms
cco pack validate <name>    # validate a pack you just authored
cco pack create <name>      # author packs/templates/llms (create/update/remove/install/import)
cco tag add <name> <tag>    # organize with per-user tags
cco remote add <name> <url> # register a sharing-repo remote (URL only)
cco config save             # version your personal store ~/.cco (local git commit)
cco … show                  # inspect any resource
```

At the default `edit-global` your whole personal store `~/.cco` (plus the in-scope
project) is in view, with **other projects hidden**; `--all` (`edit-all`) brings
every project into view and edit. If you narrow the session (e.g. `--cco-access
read-global` or `read-project`), the read verbs **scope their output** to that level
(ADR-0043) and print a count-only "hidden by access scope" notice on stderr for
anything outside it — a hidden resource is not a missing one.

**Host-only** — the agent will show you the exact command for your host terminal
(using the host path map, since `show_host_paths` is on):

```bash
cco start <name>            # session/image lifecycle (start/stop/build/new)
cco resolve / sync / init / join / update / clean   # path-resolving lifecycle
cco config push / pull      # network + credentials — sync ~/.cco across machines
cco remote set-token <n> <t># tokens never reach the container
```

For project config, the committed `<repo>/.cco/` is versioned with the repo's
normal git — review and commit it like any other change in that repo.

---

## 5. How It Differs from the Tutorial

| | **tutorial** | **config-editor** |
|--|--------------|-------------------|
| Goal | Learn and understand | Create and edit |
| Your config store | Read-only (safe to inspect) | Read-write (the agent edits it) |
| Agent posture | Teacher — explains, never edits | Assistant — writes files, with your approval |
| Best for | Onboarding, questions, examples | Authoring packs/templates, tuning config |

Think of the tutorial as "show me how" and config-editor as "do it with me."
See [tutorial.md](./tutorial.md).

---

## 6. Safety Notes

config-editor is the **recommended, sanctioned** place for agent-assisted config
editing. A few things to know:

- **Secrets stay out of committed files.** The agent will never write real secret
  values into committed config. Real secrets live in a gitignored `secrets.env`
  that you edit on your host; only `*.example` skeletons are committed.
- **Nothing is deleted without your say-so.** The agent confirms before deleting a
  pack or project, and shows you a diff before overwriting an existing file.
- **Internal cco state is off-limits.** Machine-local data (the project index,
  tags, remotes, caches, transcripts) is not exposed here — it is managed only
  through `cco …` commands, never hand-edited. It sits behind an OS-level
  **privilege boundary** (ADR-0047): a `cco-svc`-owned directory the session user
  cannot traverse, reached only through a setuid helper that enforces this session's
  resolved access — so even config-editor cannot read or corrupt the raw store.
- **Real secrets and tokens never reach the session.** Real secret files
  (`secrets.env`, `*.env`, `*.key`, `*.pem`) are filtered out of every config
  mount — only their `*.example` skeletons are visible — and remote tokens,
  transcripts, and memory are not mounted at all. Set/remove tokens on your host
  (`cco remote set-token`).
- **Normal code sessions can't edit project config by accident.** In an ordinary
  `cco start <project>` session, a project's `project.yml` and secrets are
  protected (read-only inside the container — the default `cco_access=read-project`
  can read but not edit `.cco`). config-editor is
  the preset that intentionally lifts that protection (`cco_access=edit-global` by
  default, or `edit-all` with `--all`) so you can edit config. If you ever want to
  edit **just this project's** config inline in a normal session, opt in for that
  session with `cco start <project> --cco-access edit-project` (writes the project's
  `.cco` only, not `~/.cco`; the old `--enable-config-edit` flag still works as a
  deprecated alias), but config-editor is the cleaner path.
- **Remember to save.** After editing your personal store, run `cco config save`
  on your host so your changes are versioned.
