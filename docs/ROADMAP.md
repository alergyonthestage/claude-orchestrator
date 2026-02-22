# Roadmap

> Tracks planned features and known improvements for future iterations.

---

## Near-term

### Knowledge Packs — Agents & Skills support

Currently packs support only knowledge document imports via `@path`. Future extension:
- `agents/*.md` in a pack definition → added as project-level subagents
- `skills/*.md` in a pack definition → added as project-level skills
- Pack `settings.json` partial → merged into project settings

### Pack inheritance / composition

Allow packs to extend other packs:
```yaml
extends: base-client
files:
  - additional-doc.md
```

### `cco pack create <name>` command

Scaffold a new pack definition interactively, similar to `cco project create`.

---

## Medium-term

### Browser Automation MCP in Docker

Enable Claude to navigate and analyze web pages from within a container session using a headless browser MCP server.

**Approach**:
- Install Chromium in the `Dockerfile` (`apt-get install -y chromium`)
- Add a Playwright or Puppeteer MCP server to `global/mcp.json`
- Browser runs headless inside the container — no display or VNC required
- Claude can navigate URLs, take screenshots, extract page content

**Why useful**: analyze live UIs, verify deployed endpoints, scrape structured data from web pages — all without leaving the coding session.

**Complexity**: Medium. Requires Dockerfile change (image size increase ~400 MB) and MCP server package. Make opt-in via `cco build --with-browser` flag and a separate image tag.

### `cco project edit <name>` command

Open project.yml in `$EDITOR` and regenerate docker-compose.yml after save.

### Session resume

`cco resume <project>` — reattach to a running tmux session inside a running container.

---

## Long-term / Exploratory

### Remote sessions

Mount repos from remote hosts via SSHFS or similar, enabling orchestrator sessions on remote development machines.

### Multi-project sessions

A single Claude session with repos from multiple projects, for cross-project refactoring or analysis tasks.

### Web UI

Optional lightweight web dashboard for listing projects, starting/stopping sessions, viewing logs, and editing project configurations.
