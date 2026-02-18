# Quick Start

**claude-orchestrator** gestisce sessioni Claude Code isolate in container Docker, con repo montati, contesto precaricato e agent teams pronti all'uso — tutto con un singolo comando.

## Setup

```bash
# 1. Aggiungi il CLI al PATH
echo 'export PATH="$PATH:$HOME/claude-orchestrator/bin"' >> ~/.zshrc
source ~/.zshrc

# 2. Builda l'immagine Docker
cc build
```

## Uso

```bash
# Crea un progetto
cc project create my-app --repo ~/projects/my-app

# Configura il progetto
vim projects/my-app/project.yml         # repo, porte, auth
vim projects/my-app/.claude/CLAUDE.md   # istruzioni per Claude

# Avvia una sessione
cc start my-app

# Oppure: sessione temporanea senza progetto
cc new --repo ~/projects/experiment
```

## Comandi

| Comando | Descrizione |
|---------|-------------|
| `cc build` | Builda l'immagine Docker |
| `cc start <progetto>` | Avvia sessione per un progetto configurato |
| `cc new --repo <path>` | Sessione temporanea con repo specifici |
| `cc project create <nome>` | Crea nuovo progetto da template |
| `cc project list` | Lista progetti disponibili |
| `cc stop [progetto]` | Ferma sessione/i in corso |

## Come funziona

```
Host                              Container Docker
──────────────────────────────────────────────────────
global/.claude/        ──mount──► ~/.claude/           (config globale)
projects/my-app/.claude/ ──mount──► /workspace/.claude/  (contesto progetto)
~/projects/my-app/     ──mount──► /workspace/my-app/    (repo, read-write)
Docker socket          ──mount──► Docker socket          (docker-from-docker)

                                  $ claude --dangerously-skip-permissions
```

## Requisiti

- macOS o Linux
- Docker Desktop (macOS) o Docker Engine (Linux)
- Bash 4+
- Account Claude Code (Pro/Team/Enterprise o API key)

## Documentazione

Per approfondimenti vedi la cartella [docs/](docs/):

- [SPEC.md](docs/SPEC.md) — Requisiti
- [ARCHITECTURE.md](docs/ARCHITECTURE.md) — Architettura e decisioni di design
- [CLI.md](docs/CLI.md) — Dettaglio comandi e formato `project.yml`
- [DOCKER.md](docs/DOCKER.md) — Immagine Docker, compose, networking
- [CONTEXT.md](docs/CONTEXT.md) — Gerarchia contesto e settings
- [SUBAGENTS.md](docs/SUBAGENTS.md) — Subagenti e guida alla creazione
- [DISPLAY-MODES.md](docs/DISPLAY-MODES.md) — Modalità display: tmux vs iTerm2
