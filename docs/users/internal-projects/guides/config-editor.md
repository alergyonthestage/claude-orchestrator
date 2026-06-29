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
```

`config-editor` is a built-in session — nothing to install or scaffold, and it
never appears in `cco list`. It always reflects your installed version of
claude-orchestrator.

If you run `cco start config-editor` from inside a configured repo, it picks up
that project automatically (the same as passing `--project`).

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

| Mode | Command | What's editable |
|------|---------|-----------------|
| **Global** | `cco start config-editor` | Your personal store: global config, packs, templates |
| **Project** | `cco start config-editor --project <name>` (or run from the repo) | The above **plus** that project's committed config |

The official documentation is also available to the session (read-only), so the
agent grounds its suggestions in the current docs rather than guesswork.

---

## 4. Saving and Activating Your Changes

The `cco` CLI runs on your **host**, not inside the session. So the agent edits
files, and you run the activating commands on your host terminal. The session will
tell you exactly which ones; typically:

```bash
# Version your personal store after edits
cco config save

# Sync across your machines (optional)
cco config push

# Validate a pack you just authored
cco pack validate <name>

# Launch a project you configured
cco start <name>
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
  through `cco …` commands, never hand-edited.
- **Normal code sessions can't edit project config by accident.** In an ordinary
  `cco start <project>` session, a project's `project.yml` and secrets are
  protected (read-only inside the container). config-editor is the session that
  intentionally lifts that protection so you can edit them. (If you ever want to
  edit project config inline in a normal session, you can opt in once with
  `cco start --enable-config-edit`, but config-editor is the cleaner path.)
- **Remember to save.** After editing your personal store, run `cco config save`
  on your host so your changes are versioned.
