# Roadmap

> Tracks planned features and known improvements for future iterations.

---

## Completed

### Automated Testing ✓

Pure bash test suite (`bin/test`) covering 126 test cases across 9 test files. Tests run without a Docker container using `--dry-run` and file-system assertions. Zero external dependencies.

**Coverage**: `cco init`, `cco project create`, `cco start --dry-run` (docker-compose generation), knowledge pack generation, workspace.yml generation, YAML parser edge cases, `cco stop`, `cco project list`.

### Knowledge Packs — Full Schema (knowledge + skills + agents + rules) ✓

Packs now support the full expanded schema: `knowledge:` section for document mounts, plus `skills:`, `agents:`, and `rules:` for project-level tooling. Skills/agents/rules are copied at `cco start` time (not mounted, to avoid Docker volume collisions with multi-pack setups).

Knowledge files are injected automatically via `session-context.sh` hook (no `@.claude/packs.md` in CLAUDE.md required).

### /init Skill ✓

Custom project initialization skill at `global/.claude/skills/init/SKILL.md`. Shadows the built-in `/init` command. Reads `workspace.yml`, explores repositories, generates a structured CLAUDE.md, and writes descriptions back to `workspace.yml`.

---

## Near-term

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
