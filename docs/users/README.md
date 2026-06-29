# User Documentation

Welcome! This is everything you need to run claude-orchestrator (`cco`) and make
it your own. Guides are grouped by domain; references give you the precise
details when you need them.

## Start here — recommended reading order

If you're new, read these four in order. They take you from "what is this?" to a
running session, and they're enough to be productive.

| # | Read | Why |
|---|------|-----|
| 1 | [foundation/guides/overview.md](foundation/guides/overview.md) | What cco is, who it's for, and how it works at a glance. |
| 2 | [foundation/guides/installation.md](foundation/guides/installation.md) | Prerequisites, `cco init`, and getting the Docker image built. |
| 3 | [foundation/guides/first-project.md](foundation/guides/first-project.md) | Create and start your first project, step by step. |
| 4 | [foundation/guides/concepts.md](foundation/guides/concepts.md) | The mental model: context hierarchy, packs, agent teams, memory. |

> The fastest hands-on path is the built-in interactive tutorial: run
> `cco start tutorial`. See [internal-projects/guides/tutorial.md](internal-projects/guides/tutorial.md).

After that, dip into the domains below as your needs grow — you don't have to
read them in order.

## Domains

| Domain | What's there | Key guides & reference |
|--------|--------------|------------------------|
| **Foundation** | Orientation, install, your first project, the day-to-day development workflow, and the principles behind structured agentic development. | [overview](foundation/guides/overview.md) · [installation](foundation/guides/installation.md) · [first-project](foundation/guides/first-project.md) · [concepts](foundation/guides/concepts.md) · [development-workflow](foundation/guides/development-workflow.md) · [structured-agentic-development](foundation/guides/structured-agentic-development.md) · ref: [context-hierarchy](foundation/reference/context-hierarchy.md) |
| **Configuration** | How to configure a project, organize rules across scopes, and version/share your config across machines and teammates. | [configuration-management](configuration/guides/configuration-management.md) · [project-setup](configuration/guides/project-setup.md) · [configuring-rules](configuration/guides/configuring-rules.md) · ref: [project-yaml](configuration/reference/project-yaml.md) |
| **Packs** | Reusable knowledge packs — bundle docs, rules, agents, and skills once and activate them per project. | [knowledge-packs](packs/guides/knowledge-packs.md) |
| **Integration** | Authentication, browser automation, and multi-agent work (agent teams and subagents). | [authentication](integration/guides/authentication.md) · [browser-automation](integration/guides/browser-automation.md) · [agent-teams](integration/guides/agent-teams.md) · [subagents](integration/guides/subagents.md) |
| **Environment** | Customize the container: setup scripts, extra packages, custom images, Docker, and networking. | [custom-environment](environment/guides/custom-environment.md) · [docker-and-networking](environment/guides/docker-and-networking.md) |
| **Security** | Understand and control the Docker socket exposure. | [socket-security](security/guides/socket-security.md) |
| **Internal projects** | The built-in sessions that ship with cco: the interactive tutorial and the config-editor. | [tutorial](internal-projects/guides/tutorial.md) · [config-editor](internal-projects/guides/config-editor.md) |
| **Reference** | The complete CLI: every `cco` command, option, and flow. | [cli](reference/cli.md) |

## When something breaks

[troubleshooting.md](troubleshooting.md) — common issues and fixes by category
(Docker, auth, tmux, MCP, packs).

---

Maintaining or contributing to cco itself? See the
[maintainer documentation](../maintainers/README.md).
