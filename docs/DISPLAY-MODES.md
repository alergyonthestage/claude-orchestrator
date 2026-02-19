# Display Modes: Agent Teams Visualization

> Version: 1.0.0
> Status: Draft — Pending Review
> Related: [ARCHITECTURE.md](./ARCHITECTURE.md) | [SUBAGENTS.md](./SUBAGENTS.md)

---

## 1. Overview

When using agent teams, Claude Code can display teammates in three modes:

| Mode | Where Panes Live | Requirements | Best For |
|------|-------------------|--------------|----------|
| **tmux** | Inside the container's tmux session | tmux (pre-installed in image) | Reliability, any terminal |
| **iTerm2 (auto)** | Native iTerm2 panes on macOS | it2 CLI + Python API enabled | Polished UX, native feel |
| **in-process** | All in one terminal (Shift+Up/Down to navigate) | Nothing | Simplicity, fallback |

---

## 2. Option A: tmux Mode (Recommended Default)

### 2.1 How It Works

- tmux is pre-installed in the Docker image
- The entrypoint starts a tmux session, then launches Claude Code inside it
- When agent teams create teammates, each gets its own tmux pane
- You see all panes in your terminal via tmux's built-in pane management

### 2.2 Setup

**No host-side setup required.** tmux runs entirely inside the container.

**Configuration** (`global/.claude/settings.json`):
```json
{
  "teammateMode": "tmux"
}
```

Or per-session:
```bash
cco start my-project --teammate-mode tmux
```

### 2.3 Usage

| Action | Key |
|--------|-----|
| Navigate between panes | `Alt + Arrow keys` |
| Resize pane | `Ctrl+B` then `Alt + Arrow` |
| Scroll pane history | `Ctrl+B` then `[` (enter copy mode), then scroll |
| Exit copy/scroll mode | `q` |
| Zoom a pane (fullscreen toggle) | `Ctrl+B` then `z` |

### 2.4 Pros and Cons

**Pros**:
- Works in any terminal (iTerm2, Terminal.app, VS Code, etc.)
- No host configuration needed
- Reliable — tmux is mature and well-tested
- Persists pane layout even if terminal reconnects

**Cons**:
- No native clipboard integration with macOS (copy requires tmux copy mode)
- Visual appearance depends on terminal's tmux rendering
- Nested tmux sessions (if you already use tmux) need prefix remapping

### 2.5 Nested tmux Note

If you already run tmux on the host, the container's tmux creates a nested session. To avoid prefix key conflicts:

The container's tmux.conf uses `Ctrl+B` (default). If your host tmux also uses `Ctrl+B`, you'll need to press it twice to reach the inner session, or remap one of them.

**Alternative**: Use iTerm2 mode instead to avoid nesting entirely.

---

## 3. Option B: iTerm2 Native Mode

### 3.1 How It Works

- Claude Code detects iTerm2 and uses its native pane API
- Agent team panes appear as iTerm2 split panes — no tmux involved
- Each pane is a real iTerm2 pane with native scrollback, search, and clipboard

### 3.2 Setup

#### Step 1: Install the `it2` CLI

The `it2` CLI is required for Claude Code to control iTerm2 panes.

```bash
# Install via Homebrew
brew install mkusaka/it2/it2

# Verify installation
it2 --version
```

If Homebrew doesn't have it, install from source:
```bash
# Check https://github.com/mkusaka/it2 for latest instructions
go install github.com/mkusaka/it2@latest
```

#### Step 2: Enable Python API in iTerm2

1. Open iTerm2
2. Go to **iTerm2 → Settings** (or `Cmd+,`)
3. Navigate to **General → Magic**
4. Check **"Enable Python API"**
5. Restart iTerm2

#### Step 3: Configure the Orchestrator

Set `teammateMode` to `"auto"` — this makes Claude Code detect iTerm2 automatically:

```json
{
  "teammateMode": "auto"
}
```

Or per-session:
```bash
cco start my-project --teammate-mode auto
```

### 3.3 Usage

With iTerm2 mode active:
- Agent team panes appear as native iTerm2 splits
- Click a pane to interact with that teammate
- Standard iTerm2 shortcuts work (Cmd+D for split, Cmd+Shift+D for horizontal split, etc.)
- Native clipboard integration — select text to copy, Cmd+V to paste

### 3.4 Pros and Cons

**Pros**:
- Native macOS experience — clipboard, scrollback, search all work
- Beautiful pane rendering with iTerm2's features
- No nested tmux complexity
- Cmd+Click on file paths opens them in your editor

**Cons**:
- macOS + iTerm2 only
- Requires `it2` CLI and Python API setup
- Slightly more fragile than tmux (depends on iTerm2 API stability)
- Panes are lost if iTerm2 crashes or the tab is closed

### 3.5 Troubleshooting

| Problem | Solution |
|---------|----------|
| Panes don't appear | Verify `it2` is installed: `which it2` |
| "Python API not enabled" | iTerm2 → Settings → General → Magic → Enable Python API |
| Mode falls back to in-process | Check that iTerm2 is the active terminal (not VS Code terminal, Terminal.app, etc.) |
| Panes appear but are empty | Restart Claude Code; the teammate may have crashed |

---

## 4. Option C: In-Process Mode (Fallback)

### 4.1 How It Works

All teammates run within the same terminal. You navigate between them using keyboard shortcuts.

### 4.2 Setup

```json
{
  "teammateMode": "in-process"
}
```

### 4.3 Usage

| Action | Key |
|--------|-----|
| Cycle through teammates | `Shift+Up` / `Shift+Down` |
| Enter a teammate's session | `Enter` (when selected) |
| Interrupt teammate | `Escape` |
| Toggle task list | `Ctrl+T` |
| Message a teammate | Select with Shift+Up/Down, then type |

### 4.4 When to Use

- When tmux and iTerm2 modes don't work
- When you prefer a simple single-terminal experience
- When running in terminals that don't support tmux well

---

## 5. Recommendation Matrix

| Scenario | Recommended Mode |
|----------|-----------------|
| Daily development in iTerm2 | `auto` (iTerm2 native) if setup done, else `tmux` |
| Using VS Code terminal | `tmux` or `in-process` |
| Already using tmux on host | `auto` (iTerm2) or `in-process` |
| First time / unsure | `tmux` (works everywhere, no setup) |
| Need clipboard integration | `auto` (iTerm2) |
| Want maximum reliability | `tmux` |

---

## 6. Switching Modes

You can switch modes at any time:

1. **Per-session** — use the CLI flag:
   ```bash
   cco start my-project --teammate-mode auto
   ```

2. **Per-project** — add to project settings:
   ```json
   // projects/<n>/.claude/settings.json
   { "teammateMode": "auto" }
   ```

3. **Globally** — change global settings:
   ```json
   // global/.claude/settings.json
   { "teammateMode": "tmux" }
   ```

Precedence: CLI flag > project settings > global settings.
