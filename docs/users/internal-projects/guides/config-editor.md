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
model, resolved to the **least privilege its mode needs** (ADR-0044 → ADR-0048).
The mode decides which trees are writable; `claude_access` is not set separately —
it **derives** from the resolved config access (ADR-0049), so `.claude` authoring
follows the same shape. A whitelisted `cco` runs inside the session (see §4). You
can narrow a session with an explicit `--cco-access` (e.g. `--cco-access
read-global` for a look-only pass); the store stays at least *readable* either way,
so a narrower value is clamped up with a notice.

Scope is **minimum-privilege by mode** — note which side is read-only in each:

- **Bare, outside any project** (`cco start config-editor`) → `~/.cco` **read-write**,
  and nothing else (`(G,Pc,Po) = (rw,none,none)`). No project trees, no code repos.
- **Inside a project** — a cwd hosting a configured repo, or `--project <name>`
  (**repeatable**) → that project's `<repo>/.cco/` **and its code repos** read-write,
  while `~/.cco` is mounted **read-only** (`(ro,rw,none)`): you edit the project and
  *reference* the store. `--repo <name>` adds a single resolvable repo to the mount
  set. To **also** write the store in this mode, add `--cco-access edit-global`.
- **Every project at once** — the **explicit widener** `--all` (or `--cco-access
  edit-all`) → `~/.cco` plus **every** resolvable project's committed `<repo>/.cco/`
  read-write (no code repos; unresolvable projects are announced, not silently
  skipped), at `edit-all`. `--all` cannot be combined with `--project`/`--repo`.

To exit, end the session as usual (or `cco stop config-editor` from another
terminal).

---

## 2. What You Can Safely Do

Unlike the tutorial, config-editor has **read-write** access to the config its mode
targets (§1) — your personal store in global mode, the project's committed config in
project mode — so the agent can create and edit files for you:

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

| Mode | Command | Writable | Readable only | `(G,Pc,Po)` |
|------|---------|----------|---------------|-------------|
| **Global** (bare, outside a project) | `cco start config-editor` | `~/.cco` — global config, packs, templates | — | `(rw,none,none)` |
| **Focused** (inside a project) | `cco start config-editor --project <name>` (repeatable; or run from the repo) | that project's committed `<repo>/.cco` **plus its code repos** | `~/.cco` | `(ro,rw,none)` |
| **Broad** (explicit widener) | `cco start config-editor --all` | `~/.cco` + **every** resolvable project's `<repo>/.cco` (no code repos) | — | `edit-all` |
| **Add a repo** | `… --repo <name>` | Adds one resolvable code repo to the mount set | | |
| **Focused + store** | `… --project <name> --cco-access edit-global` | both the project **and** `~/.cco` | — | `(rw,rw,none)` |

The official documentation is also available to the session (read-only), so the
agent grounds its suggestions in the current docs rather than guesswork.

---

## 4. Saving and Activating Your Changes

A **whitelisted `cco`** runs inside the config-editor session (wrapped-`cco`),
operating on your real, mounted config buckets. So many commands the agent needs
now run in-session — you don't have to shuttle everything to your host terminal.

**Reads — run in every mode:**

```bash
cco list                    # discover projects/packs/templates/llms
cco pack validate <name>    # validate a pack you just authored
cco … show                  # inspect any resource
cco whoami                  # what THIS session may read and write — check it first
```

**Writes — gated by the axis the target lives on**, so which of these run depends on
the mode you launched (§3). Anything that writes the personal store needs `G=rw`
(global mode, `--all`, or `--cco-access edit-global`); in **focused** project mode
`~/.cco` is read-only and they are refused with a *"needs G=rw"* hint:

```bash
cco pack create <name>      # author packs/templates/llms — needs G=rw
cco remote add <name> <url> # register a sharing-repo remote (URL only) — needs G=rw
cco config save             # version your personal store ~/.cco — needs G=rw
cco tag add <name> <tag>    # per-user tags — by TARGET: this project needs Pc=rw,
                            #   a pack/template needs G=rw
cco repo rename <old> <new> # re-label a repo in this project — needs Pc=rw
```

A project's own committed config is edited by **writing the mounted files directly**
(that is what `Pc=rw` buys); only the two `rename` verbs above go through `cco`,
because a rename must also re-key the machine-local index.

Read output is **scoped to the session's level** (ADR-0043): a narrower session
(e.g. `--cco-access read-global`) prints a count-only "hidden by access scope" notice
on stderr for anything outside it — a hidden resource is not a missing one.

**Host-only** — the agent will show you the exact command for your host terminal
(using the host path map, since `show_host_paths` is on):

```bash
cco start <name>            # session/image lifecycle (start/stop/build/new)
cco resolve / sync / init / join / forget / update / clean  # path-resolving lifecycle
cco config validate         # sanitises machine-local state — only coherent host-side
cco config push / pull      # network + credentials — sync ~/.cco across machines
cco remote set-token / remove-token / remove / rename   # all cascade into the
                            #   0600 token store, which never reaches a container
cco project rename          # re-keys machine-local state
```

For project config, the committed `<repo>/.cco/` is versioned with the repo's
normal git — review and commit it like any other change in that repo.

---

## 5. How It Differs from the Tutorial

| | **tutorial** | **config-editor** |
|--|--------------|-------------------|
| Goal | Learn and understand | Create and edit |
| Your config store | Read-only (safe to inspect) | Read-write in global/`--all` mode; read-only in focused project mode (§1) |
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
  the preset that intentionally lifts that protection, for the trees its mode
  targets (§1) — never wider. If you ever want to
  edit **just this project's** config inline in a normal session, opt in for that
  session with `cco start <project> --cco-access edit-project` (writes the project's
  `.cco` only, not `~/.cco`; the old `--enable-config-edit` flag still works as a
  deprecated alias), but config-editor is the cleaner path.
- **Remember to save.** After editing your personal store, run `cco config save`
  on your host so your changes are versioned.
