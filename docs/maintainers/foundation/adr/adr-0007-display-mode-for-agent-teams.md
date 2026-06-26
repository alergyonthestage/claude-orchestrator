# ADR-0007: Display Mode for Agent Teams

> **Status**: accepted

## Context

Agent teams need to display multiple concurrent panes. Different developers use
different terminals, so the display mechanism must work broadly while still
allowing a more polished native experience where available.

## Decision

Support both tmux and iTerm2 modes. User chooses via global settings or CLI flag.

**tmux mode** (recommended default):
- tmux is installed in the Docker image
- Agent teams create split panes inside the container's tmux session
- Works in ANY terminal emulator
- No host-side configuration needed

**iTerm2 mode**:
- Requires `it2` CLI installed on host
- Requires Python API enabled in iTerm2 settings
- Provides native iTerm2 panes (not inside tmux)
- More polished UX but more setup

**Configuration**:
```json
// ~/.cco/global/.claude/settings.json
{
  "teammateMode": "tmux"   // or "auto" for iTerm2 detection
}
```

**CLI override**:
```bash
cco start my-project --teammate-mode tmux
cco start my-project --teammate-mode auto  # iTerm2 if available
```
