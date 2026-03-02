# Troubleshooting and FAQ

> Solutions to common problems, organized by category.

---

## Docker

### Docker daemon is not running

```
Error: Docker daemon is not running. Start Docker Desktop.
```

**Solution**: Start Docker Desktop (macOS/Windows) or the Docker service (`sudo systemctl start docker` on Linux). Verify with:

```bash
docker info
```

### Image build fails

**Symptoms**: `cco build` terminates with an error.

**Solutions**:
- Check your internet connection (the build downloads npm and apt packages)
- Try a full rebuild without cache:
  ```bash
  cco build --no-cache
  ```
- If the error is about a specific npm package, it could be a temporary registry issue. Try again after a few minutes.

### Port conflict

```
Error: Port 3000 is already in use. Stop the conflicting service or use --port to remap.
```

**Solutions**:
- Identify the process using the port:
  ```bash
  lsof -i :3000
  ```
- Stop the conflicting service, or remap the port:
  ```bash
  cco start my-project --port 3001:3000
  ```
- Alternatively, modify `docker.ports` in `project.yml`

### Docker socket permissions

**Symptoms**: `docker` commands in the container fail with "permission denied".

**Solution**: the entrypoint automatically handles the Docker socket GID. If the problem persists:
- Verify that the socket is mounted: check `docker.mount_socket` in `project.yml` (default: `true`)
- On Linux, verify that your user belongs to the `docker` group:
  ```bash
  groups | grep docker
  ```

### Docker image not found

```
Error: Docker image 'claude-orchestrator:latest' not found. Run 'cco build' first.
```

**Solution**: run `cco build` to build the image. If you're using a custom image (`docker.image` in `project.yml`), verify that it has been built.

---

## Authentication

### "Not logged in"

**Cause**: OAuth credentials are not available in the container.

**Solutions**:
1. Verify that you've logged in on the host: run `claude` outside the container
2. Force credential re-seeding:
   ```bash
   rm global/claude-state/.credentials.json
   cco start my-project
   ```
3. Check the macOS Keychain:
   ```bash
   security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w | head -c 50
   ```

### Expired token

**Symptoms**: authentication errors after a period of inactivity (~90 days).

**Solution**:
1. Log in on the host: run `claude` and authenticate via browser
2. `cco start my-project` — the CLI automatically detects the new credentials

### Onboarding screen

**Symptoms**: the "theme: dark" screen appears instead of the session.

**Cause**: `hasCompletedOnboarding` is set to `false` in `claude.json`, typically after logout+login on the host.

**Solution**: the CLI automatically fixes this value. If the problem persists:
```bash
jq '.hasCompletedOnboarding = true' global/claude-state/claude.json > /tmp/fix.json \
  && mv /tmp/fix.json global/claude-state/claude.json
```

### API key not recognized

**Solutions**:
- Check `auth.method: api_key` in `project.yml`
- Verify that `ANTHROPIC_API_KEY` is in `global/secrets.env` or passed with `--env`
- Check the key format (must start with `sk-ant-api`)

### GitHub token doesn't work

**Symptoms**: `git push` fails, `gh` is not authenticated.

**Solutions**:
- Verify that `GITHUB_TOKEN` is in `global/secrets.env` or `projects/<name>/secrets.env`
- Check PAT permissions: Contents (read/write) and Pull requests (read/write)
- Check the entrypoint logs for messages like:
  ```
  [entrypoint] GitHub: authenticated gh CLI via GITHUB_TOKEN
  ```

---

## tmux and copy-paste

### Clipboard doesn't work

**Symptoms**: text selection works visually but `Cmd+V` doesn't paste anything.

**Cause**: the OSC 52 protocol is not enabled in your terminal.

**Solutions per terminal**:

| Terminal | Solution |
|-----------|----------|
| iTerm2 | Settings > General > Selection > enable "Applications in terminal may access clipboard" |
| Terminal.app | OSC 52 not supported: use `fn` + drag for native selection |
| GNOME Terminal | OSC 52 not supported: use `Shift` + drag for native selection |
| Alacritty, WezTerm, Kitty, Ghostty | Works out of the box |

### Alternative copy methods

If automatic copy doesn't work, use native selection to bypass tmux:

| Terminal | Modifier key |
|-----------|-------------------|
| iTerm2 | `Option` (hold during drag) |
| Terminal.app | `fn` |
| Alacritty, WezTerm, Kitty | `Shift` |
| GNOME Terminal, XFCE | `Shift` |

**Limitation**: native selection crosses tmux pane borders, including borders and status line.

### Cmd+C doesn't copy

`Cmd+C` sends SIGINT (interrupt), not copy. To copy:
- **Recommended method**: select with mouse and release — copy is automatic (if OSC 52 is enabled)
- **Manual**: `Ctrl+B` then `[` to enter copy-mode, select with `v`, copy with `y`
- **Native bypass**: hold your terminal's modifier key during drag

### Nested tmux session

If you already use tmux on the host, the container creates a nested session. The container's prefix is `Ctrl+B` (default). To reach the inner tmux, press `Ctrl+B` twice, or remap the prefix of one of the two.

**Alternative**: use iTerm2 mode (`--teammate-mode auto`) to avoid nesting.

---

## Knowledge Packs

### Knowledge files not in context

**Symptoms**: Claude doesn't seem to know the contents of knowledge files.

**Solutions**:
1. Verify that the pack is listed in `packs:` in `project.yml`
2. Check the output of `cco start` for the message "Generated .claude/packs.md"
3. Verify that `pack.yml` has the `knowledge.files:` section populated
4. Check the contents of `projects/<name>/.claude/packs.md` — it must list the files

### Pack conflicts

**Symptoms**: warning during `cco start` about duplicate names.

**Cause**: two packs define the same agent, rule, or skill.

**Solution**: the last pack in `project.yml`'s `packs:` list wins. Rename the conflicting file in one of the packs, or reorder the list to give precedence to the correct pack.

### Validation errors

```bash
# Check pack structure
cco pack validate my-pack
```

Common problems:
- `pack.yml` missing or with syntax error
- Files declared in `knowledge.files` that don't exist in the source directory
- Skill/agent/rule names that don't match files in the directory

---

## MCP

### MCP servers not loaded

**Symptoms**: MCP tools are not available in the session.

**Solutions**:
1. Verify that `mcp.json` is valid JSON:
   ```bash
   jq . projects/my-project/mcp.json
   ```
2. Verify that referenced environment variables (`${VAR}`) are available in the container via `secrets.env` or `--env`
3. If a `${VAR}` variable is not resolved, Claude Code ignores the entire `mcp.json` file
4. For global servers, check `global/.claude/mcp.json`
5. Check the entrypoint logs for merge errors

### Unresolved environment variables

**Cause**: `${GITHUB_TOKEN}` in `mcp.json` is not expanded because the variable is not in the container's environment.

**Solution**: add the variable to `global/secrets.env`:
```bash
echo "GITHUB_TOKEN=ghp_..." >> global/secrets.env
```

Or pass it with `--env`:
```bash
cco start my-project --env GITHUB_TOKEN=ghp_...
```

### MCP packages slow on first startup

**Cause**: `npx -y` downloads the package on each startup if not pre-installed.

**Solution**: pre-install packages in the Docker image:
```bash
# Via mcp-packages.txt (persistent)
echo "@modelcontextprotocol/server-github" >> global/mcp-packages.txt
cco build

# Via CLI flag (one-time)
cco build --mcp-packages "@modelcontextprotocol/server-github"
```

For project-specific packages, use `projects/<name>/mcp-packages.txt`.

---

## General

### Session already running

```
Error: Project 'my-project' already has a running session (container cc-my-project). Run 'cco stop my-project' first.
```

**Solution**:
```bash
# Stop the existing session
cco stop my-project

# Or stop all sessions
cco stop
```

### Repository not visible in container

**Symptoms**: the `/workspace/<repo>/` directory doesn't exist in the container.

**Solutions**:
1. Verify that the path in `project.yml` exists on the host:
   ```bash
   ls -la ~/projects/my-repo
   ```
2. Check the configuration in `project.yml`:
   ```yaml
   repos:
     - path: ~/projects/my-repo    # must exist on host
       name: my-repo               # name in /workspace/
   ```
3. Use `cco start my-project --dry-run` to see the generated volumes in `docker-compose.yml`

### Project not found

```
Error: Project 'foo' not found. Run 'cco project list' to see available projects.
```

**Solutions**:
- Check the name with `cco project list`
- Verify that `projects/<name>/project.yml` exists
- If the project doesn't exist yet, create it:
  ```bash
  cco project create my-project --repo ~/projects/my-repo
  ```

### Context too large

**Symptoms**: Claude reports that context is near the limit, or responses become imprecise.

**Solutions**:
- Reduce the number of files in knowledge packs (use precise descriptions to limit file reading)
- Use `/compact` periodically during long sessions
- Verify that knowledge files are not excessively large (prefer files under 500 lines)
- Check the status bar for the percentage of context used

### secrets.env with incorrect format

```
Warning: secrets.env:3: skipping malformed line (expected KEY=VALUE)
```

**Cause**: a line doesn't respect the `KEY=VALUE` format.

**Solution**: check the file. Keys must start with a letter or underscore, followed by `=` with no spaces around it:
```bash
# Correct
GITHUB_TOKEN=ghp_...
MY_VAR=hello world

# Wrong
3BAD_KEY=value       # doesn't start with letter/underscore
export KEY=value     # 'export' not supported
KEY = value          # spaces around =
```
