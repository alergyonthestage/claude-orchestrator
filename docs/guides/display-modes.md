# Display Modes: Agent Teams Visualization

> Version: 1.1.0
> Status: v1.1 — Updated with copy-paste guide
> Related: [architecture.md](../maintainer/architecture.md) | [subagents.md](./subagents.md)

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

### 2.4 Copy & Paste in tmux Mode

tmux intercepts tutti gli eventi mouse. Questo significa che copia/incolla funziona in modo diverso rispetto al terminale nativo. Di seguito i tre metodi supportati, dalla configurazione iniziale ai workflow quotidiani.

#### Setup iniziale (una tantum)

Prima di utilizzare il copia/incolla, è necessario configurare il terminale host per ricevere i dati dalla clipboard del container. La configurazione dipende dal terminale utilizzato.

##### iTerm2 (macOS)

iTerm2 supporta OSC 52 (il protocollo usato per trasferire la clipboard dal container al terminale), ma è **disabilitato di default**. Per abilitarlo:

1. Apri **iTerm2 → Settings** (`Cmd+,`)
2. Vai su **General → Selection**
3. Spunta **"Applications in terminal may access clipboard"**

Senza questa opzione, la selezione nel container funziona visivamente ma il testo non viene copiato nella clipboard di macOS. Non è necessario riavviare iTerm2 — la modifica è immediata.

##### Terminal.app (macOS)

Terminal.app **non supporta OSC 52**. La copia automatica al rilascio del mouse non funziona. L'unico metodo disponibile è il bypass nativo (Method C sotto): tieni premuto `fn` mentre trascini per selezionare con la selezione nativa del terminale.

##### Alacritty, WezTerm, Kitty, Ghostty, Windows Terminal

OSC 52 funziona out of the box. Nessuna configurazione necessaria.

##### GNOME Terminal, XFCE Terminal e altri terminali VTE

Questi terminali **non supportano OSC 52** (rifiutato dai maintainer di VTE per ragioni di sicurezza). Usa il bypass nativo (Method C): tieni premuto `Shift` mentre trascini.

##### Tabella riepilogativa

| Terminal | OSC 52 | Configurazione necessaria |
|----------|--------|--------------------------|
| iTerm2 | Sì (opt-in) | Settings → General → Selection → "Applications in terminal may access clipboard" |
| Terminal.app | **No** | Usare bypass nativo (`fn` + drag) |
| GNOME Terminal / VTE | **No** | Usare bypass nativo (`Shift` + drag) |
| Alacritty | Sì | Nessuna |
| WezTerm | Sì | Nessuna |
| Kitty | Sì | Nessuna |
| Ghostty | Sì | Nessuna |
| Windows Terminal | Sì | Nessuna |

#### Method A: Selezione con mouse e auto-copy (consigliato)

Questo è il metodo più rapido per il workflow quotidiano. Il testo viene copiato automaticamente nel momento in cui si rilascia il mouse.

1. **Clicca e trascina** per selezionare il testo — tmux entra in copy-mode e mostra la selezione evidenziata
2. **Rilascia il mouse** — il testo viene copiato automaticamente nella clipboard di macOS/sistema via OSC 52
3. **Incolla** con `Cmd+V` (macOS) o `Ctrl+Shift+V` (Linux) in qualsiasi applicazione

Non è necessario fare click destro, premere `y`, o usare `Cmd+C`. Il rilascio del mouse è sufficiente.

#### Method B: Copy-mode manuale (per selezione precisa)

Per selezioni più precise o navigazione nel buffer di scrollback:

1. `Ctrl+B` poi `[` — entra in copy-mode
2. Naviga con le frecce o con `h` `j` `k` `l` (vi-style)
3. `v` per iniziare la selezione visuale, oppure `Ctrl+V` per selezione rettangolare (colonna)
4. Muovi il cursore per estendere la selezione
5. `y` per copiare nella clipboard e uscire dal copy-mode
6. `Cmd+V` (macOS) o `Ctrl+Shift+V` (Linux) per incollare

Questo metodo è utile quando serve selezionare testo non visibile a schermo (scrollback) o selezionare con precisione colonne di testo.

#### Method C: Bypass tmux — selezione nativa del terminale

Tenendo premuto un tasto modificatore, il terminale ignora tmux e gestisce la selezione nativamente. Questo è l'**unico metodo** per terminali senza supporto OSC 52 (Terminal.app, GNOME Terminal).

| Terminal | Tasto modificatore | Platform |
|----------|-------------------|----------|
| iTerm2 | `Option` (⌥) | macOS |
| Terminal.app | `fn` | macOS |
| Alacritty, WezTerm, Kitty, Ghostty | `Shift` | Linux/macOS |
| Windows Terminal | `Shift` | Windows |
| GNOME Terminal, XFCE Terminal | `Shift` | Linux |

Workflow: **tieni premuto il modificatore**, trascina per selezionare, rilascia. Il testo è nella clipboard nativa del sistema. Incolla con `Cmd+V` o `Ctrl+Shift+V`.

**Limitazione**: la selezione nativa attraversa i bordi dei pane tmux — seleziona la griglia di caratteri raw, inclusi i bordi e la status bar. Per questo motivo, Method A è preferibile quando disponibile.

#### Incollare nel container

L'incolla funziona sempre allo stesso modo, indipendentemente dal metodo di copia usato:

| Azione | Come |
|--------|------|
| Incollare dalla clipboard di sistema | `Cmd+V` (macOS) / `Ctrl+Shift+V` (Linux) |
| Incollare dal buffer interno di tmux | `Ctrl+B` poi `]` |

Nota: il buffer di tmux e la clipboard di sistema sono indipendenti. `Cmd+V` incolla dalla clipboard di sistema (la più comune). `Ctrl+B` + `]` incolla dal buffer interno di tmux (utile solo se hai copiato con i comandi tmux senza OSC 52).

#### Troubleshooting

| Problema | Causa | Soluzione |
|----------|-------|-----------|
| Seleziono ma Cmd+V non incolla nulla | OSC 52 non abilitato nel terminale | Abilitare "Applications in terminal may access clipboard" in iTerm2, oppure usare bypass nativo |
| Click destro non copia | tmux intercetta il click destro come evento mouse | Non usare click destro. Rilasciare il mouse dopo la selezione è sufficiente |
| Cmd+C non copia | Cmd+C invia SIGINT (interrupt), non "copia" | Usare il rilascio del mouse (Method A) o il bypass nativo (Method C) |
| La selezione include bordi dei pane | Si sta usando il bypass nativo (Method C) | Usare Method A (selezione tmux) che è limitata al singolo pane |
| Il testo copiato contiene caratteri extra | Il terminale non gestisce correttamente il bracketed paste | Verificare che `TERM` sia impostato correttamente (`tmux-256color` nel container) |

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
