# Display Modes: Agent Teams Visualization

> Version: 1.1.0
> Status: v1.1 — Updated with copy-paste guide
> Related: [architecture.md](../maintainer/architecture.md) | [subagents.md](./advanced/subagents.md)

---

## 1. Overview

When using agent teams, Claude Code can display teammates in three modes:

| Mode | Where Panes Live | Requirements | Best For |
|------|-------------------|--------------|----------|
| **tmux** | Inside the container's tmux session | tmux (pre-installed in image) | Reliability, any terminal |
| **iTerm2 (auto)** | Native iTerm2 panes on macOS | it2 CLI + Python API enabled | Polished UX, native feel |

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

### 2.4 Copy & Paste in tmux Mode

tmux intercepts all mouse events. This means copy-paste works differently from native terminal behavior. Below are the three supported methods, from initial setup to daily workflows.

> **Note**: Copy-paste is especially relevant during first-time authentication inside the container. If Claude Code prompts you to open a URL for OAuth login, you'll need to copy that URL from the tmux session. See [Authentication — In-container login](#in-container-login-without-credential-seeding) below for details.

#### One-time setup

Before using copy-paste, you need to configure the host terminal to receive clipboard data from the container. The setup depends on which terminal you use.

##### iTerm2 (macOS)

iTerm2 supports OSC 52 (the protocol used to transfer clipboard data from container to terminal), but it is **disabled by default**. To enable it:

1. Open **iTerm2 → Settings** (`Cmd+,`)
2. Go to **General → Selection**
3. Check **"Applications in terminal may access clipboard"**

Without this option, text selection in the container works visually but the text is not copied to the macOS clipboard. No iTerm2 restart needed — the change takes effect immediately.

##### Terminal.app (macOS)

Terminal.app **does not support OSC 52**. Auto-copy on mouse release does not work. The only available method is native bypass (Method C below): hold `fn` while dragging to use the terminal's native selection.

##### Alacritty, WezTerm, Kitty, Ghostty, Windows Terminal

OSC 52 works out of the box. No configuration needed.

##### GNOME Terminal, XFCE Terminal, and other VTE-based terminals

These terminals **do not support OSC 52** (rejected by VTE maintainers for security reasons). Use native bypass (Method C): hold `Shift` while dragging.

##### Compatibility summary

| Terminal | OSC 52 | Setup required |
|----------|--------|----------------|
| iTerm2 | Yes (opt-in) | Settings → General → Selection → "Applications in terminal may access clipboard" |
| Terminal.app | **No** | Use native bypass (`fn` + drag) |
| GNOME Terminal / VTE | **No** | Use native bypass (`Shift` + drag) |
| Alacritty | Yes | None |
| WezTerm | Yes | None |
| Kitty | Yes | None |
| Ghostty | Yes | None |
| Windows Terminal | Yes | None |

#### Method A: Mouse selection with auto-copy (recommended)

This is the fastest method for daily use. Text is copied automatically the moment you release the mouse.

1. **Click and drag** to select text — tmux enters copy-mode and highlights the selection
2. **Release the mouse** — text is automatically copied to the system clipboard via OSC 52
3. **Paste** with `Cmd+V` (macOS) or `Ctrl+Shift+V` (Linux) in any application

No right-click, no `y` key, no `Cmd+C` needed. Releasing the mouse is sufficient.

#### Method B: Manual copy-mode (for precise selection)

For precise selections or scrollback navigation:

1. `Ctrl+B` then `[` — enter copy-mode
2. Navigate with arrow keys or `h` `j` `k` `l` (vi-style)
3. `v` to start visual selection, or `Ctrl+V` for rectangle (column) selection
4. Move the cursor to extend the selection
5. `y` to copy to clipboard and exit copy-mode
6. `Cmd+V` (macOS) or `Ctrl+Shift+V` (Linux) to paste

This method is useful for selecting text outside the visible area (scrollback) or for precise column selection.

#### Method C: Bypass tmux — native terminal selection

Hold a modifier key while dragging to bypass tmux and use native terminal selection. This is the **only method** for terminals without OSC 52 support (Terminal.app, GNOME Terminal).

| Terminal | Modifier key | Platform |
|----------|-------------|----------|
| iTerm2 | `Option` (⌥) | macOS |
| Terminal.app | `fn` | macOS |
| Alacritty, WezTerm, Kitty, Ghostty | `Shift` | Linux/macOS |
| Windows Terminal | `Shift` | Windows |
| GNOME Terminal, XFCE Terminal | `Shift` | Linux |

Workflow: **hold the modifier**, drag to select, release. The text is in the native system clipboard. Paste with `Cmd+V` or `Ctrl+Shift+V`.

**Limitation**: native selection crosses tmux pane boundaries — it selects the raw character grid including borders and status bar. For this reason, Method A is preferred when available.

#### Pasting into the container

Paste works the same way regardless of which copy method was used:

| Action | How |
|--------|-----|
| Paste from system clipboard | `Cmd+V` (macOS) / `Ctrl+Shift+V` (Linux) |
| Paste from tmux internal buffer | `Ctrl+B` then `]` |

The tmux buffer and system clipboard are independent. `Cmd+V` pastes from the system clipboard (most common). `Ctrl+B` + `]` pastes from the tmux internal buffer (only useful if you copied via tmux commands without OSC 52).

#### In-container login without credential seeding

When OAuth credentials are not seeded from the host (e.g., first-time setup, or on Linux where Keychain seeding is not available), Claude Code prompts for authentication directly inside the container. The prompt displays a URL that you need to open in a browser.

To copy the authentication URL from the tmux session:

1. **Click and drag** over the URL to select it
2. **Release the mouse** — the URL is copied to your clipboard
3. Open a browser and **paste** (`Cmd+V`) to complete the OAuth flow

If auto-copy does not work (e.g., OSC 52 not configured yet), use native bypass: hold `Option` (iTerm2), `fn` (Terminal.app), or `Shift` (Linux) while dragging to select the URL, then `Cmd+C` / `Ctrl+C` to copy.

#### Troubleshooting

| Problem | Cause | Solution |
|---------|-------|----------|
| Selection works but Cmd+V pastes nothing | OSC 52 not enabled in terminal | Enable "Applications in terminal may access clipboard" in iTerm2, or use native bypass |
| Right-click does not copy | tmux intercepts right-click as a mouse event | Don't right-click. Releasing the mouse after selection is sufficient |
| Cmd+C does not copy | Cmd+C sends SIGINT (interrupt), not "copy" | Use mouse release (Method A) or native bypass (Method C) |
| Selection includes pane borders | Using native bypass (Method C) | Use Method A (tmux selection) which is limited to a single pane |
| Copied text contains extra characters | Terminal does not handle bracketed paste correctly | Verify `TERM` is set correctly (`tmux-256color` inside the container) |

### 2.5 Pros and Cons

**Pros**:
- Works in any terminal (iTerm2, Terminal.app, VS Code, etc.)
- No host configuration needed
- Reliable — tmux is mature and well-tested
- Persists pane layout even if terminal reconnects
- Clipboard integration via OSC 52 for most terminals

**Cons**:
- Terminal.app and GNOME Terminal lack OSC 52 (must use native selection)
- iTerm2 requires one-time opt-in for clipboard access
- Visual appearance depends on terminal's tmux rendering
- Nested tmux sessions (if you already use tmux) need prefix remapping

### 2.6 Nested tmux Note

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
| Mode falls back to tmux | Check that iTerm2 is the active terminal (not VS Code terminal, Terminal.app, etc.) |
| Panes appear but are empty | Restart Claude Code; the teammate may have crashed |

---

## 4. Recommendation Matrix

| Scenario | Recommended Mode |
|----------|-----------------|
| Daily development in iTerm2 | `auto` (iTerm2 native) if setup done, else `tmux` |
| Using VS Code terminal | `tmux` |
| Already using tmux on host | `auto` (iTerm2) or `tmux` |
| First time / unsure | `tmux` (works everywhere, no setup) |
| Need clipboard integration | `auto` (iTerm2) or `tmux` (with OSC 52-compatible terminal) |
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
