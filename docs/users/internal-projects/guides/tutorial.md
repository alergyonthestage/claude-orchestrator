# Tutorial — Guided Onboarding

> An interactive, conversational walkthrough of claude-orchestrator. Launch it
> with one command and learn by doing.
>
> Related: [config-editor.md](./config-editor.md) | [project-setup.md](../../configuration/guides/project-setup.md) | [knowledge-packs.md](../../packs/guides/knowledge-packs.md)

---

## 1. Launch It

```bash
cco start tutorial
```

`tutorial` is a built-in session — there is nothing to install or scaffold, and
it never shows up in `cco list`. It always reflects your installed version of
claude-orchestrator, so the guidance is never stale.

To exit, end the session as you would any other (or run `cco stop tutorial` from
another terminal).

---

## 2. What It Does

The tutorial is a **teacher**, not an autonomous worker. It:

- Explains cco concepts, commands, and workflows in plain language.
- Reads the official documentation live, so answers stay accurate.
- Looks at your existing setup (your packs, templates, and global config) to give
  examples grounded in *your* configuration.
- Suggests the exact `cco` commands to run on your host terminal, and explains
  what each one does.

It is **read-only by design**. It will not create, modify, or delete your files.
When you want hands-on, agent-assisted editing of packs, templates, or project
config, use the [config-editor](./config-editor.md) session instead.

---

## 3. The Curriculum at a Glance

You can go through the modules in order (great for a first tour) or jump straight
to a topic. The tutorial adapts to what you ask for.

| Tier | Modules |
|------|---------|
| **Foundation** | What claude-orchestrator is · your first project · writing an effective CLAUDE.md |
| **Configuration** | Knowledge packs · framework docs with llms.txt · auth & secrets · environment (setup.sh, MCP, custom images) |
| **Collaboration** | Agent teams & subagents · sharing & distribution · browser automation |
| **Mastery** | Configuring rules & workflow · development-workflow practices · structured-development philosophy · pack design patterns · advanced topics |

You don't have to follow the tiers. Ask a direct question at any time
("how do knowledge packs work?", "how do I share a pack with my team?") and the
tutorial navigates to the right material.

---

## 4. How to Steer It

You can hint at where to start when you launch the guided flow:

| You say… | The tutorial… |
|----------|---------------|
| "I'm new to cco" | starts a guided tour from the basics |
| "help me set up my projects/packs" | jumps to the configuration topics |
| "I have a question about <topic>" | answers it directly, then offers related topics |

If you prefer keywords: pass `beginner`, `intermediate`, `advanced`, or a topic
when you invoke the guided flow, and it picks the matching starting point.

---

## 5. Working Alongside the Tutorial

The session runs in a container with **tmux**, so you can open a shell in the same
environment to look at files while you chat:

- Split a pane vertically: `Ctrl+B` then `%`
- Split horizontally: `Ctrl+B` then `"`
- Move between panes: `Ctrl+B` then the arrow keys

A few things to keep in mind:

- The `cco` CLI itself runs on your **host**, not inside the session. The tutorial
  shows you the commands to run there.
- Your personal config store is mounted **read-only** here — perfect for
  inspection, safe from accidental changes.

---

## 6. Resuming

Each topic is self-contained, so you can stop whenever you like and come back with
`cco start tutorial`. Pick up where you left off by naming the topic you want, or
ask for a quick recap and the next suggested step.

---

## 7. When to Use the Tutorial vs config-editor

| Use the **tutorial** when… | Use **config-editor** when… |
|----------------------------|-----------------------------|
| You want to learn or understand a concept | You want to actually create/edit config |
| You want explanations and examples | You want the agent to write files for you |
| You're exploring safely (read-only) | You're ready for read-write changes |

See [config-editor.md](./config-editor.md) for the hands-on editing session.
