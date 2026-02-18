# Quick Start

## Setup

```bash
# 1. Clona il repo
git clone <repo-url> ~/claude-orchestrator
cd ~/claude-orchestrator

# 2. Aggiungi il CLI al PATH
# bash:
echo 'export PATH="$PATH:$HOME/claude-orchestrator/bin"' >> ~/.bashrc
source ~/.bashrc

# zsh:
# echo 'export PATH="$PATH:$HOME/claude-orchestrator/bin"' >> ~/.zshrc
# source ~/.zshrc

# 3. Builda l'immagine Docker
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
```

Per sessioni temporanee senza creare un progetto:

```bash
cc new --repo ~/projects/experiment
cc new --repo ~/projects/api --repo ~/projects/frontend --port 3000:3000
```

## Comandi

| Comando | Descrizione |
|---------|-------------|
| `cc build` | Builda l'immagine Docker |
| `cc build --no-cache` | Rebuild completo (aggiorna Claude Code) |
| `cc start <progetto>` | Avvia sessione per un progetto configurato |
| `cc start <progetto> --dry-run` | Mostra il docker-compose generato senza avviare |
| `cc new --repo <path>` | Sessione temporanea con repo specifici |
| `cc project create <nome>` | Crea nuovo progetto da template |
| `cc project list` | Lista progetti disponibili |
| `cc stop [progetto]` | Ferma sessione/i in corso |

## Configurazione progetto

Ogni progetto vive in `projects/<nome>/` e contiene:

- **`project.yml`** — repo da montare, porte, variabili d'ambiente, metodo di autenticazione
- **`.claude/CLAUDE.md`** — istruzioni specifiche per Claude in questo progetto
- **`.claude/settings.json`** — override delle impostazioni globali (opzionale)
- **`.claude/agents/`** — subagenti specifici del progetto (opzionale)

Per il formato completo di `project.yml` vedi [docs/CLI.md](docs/CLI.md#4-project-configuration-format-projectyml).

## Opzioni aggiuntive

```bash
# Override modalità display agent teams
cc start my-app --teammate-mode auto    # iTerm2 nativo (richiede setup)
cc start my-app --teammate-mode tmux    # default, funziona ovunque

# Usa API key invece di OAuth
cc start my-app --api-key

# Porte e variabili extra
cc start my-app --port 9090:9090 --env DEBUG=true
```

## Documentazione

Per approfondimenti vedi [docs/](docs/):

- [ARCHITECTURE.md](docs/ARCHITECTURE.md) — Architettura e decisioni di design
- [CLI.md](docs/CLI.md) — Dettaglio comandi e formato `project.yml`
- [DOCKER.md](docs/DOCKER.md) — Immagine Docker, compose, networking
- [CONTEXT.md](docs/CONTEXT.md) — Gerarchia contesto e settings
- [SUBAGENTS.md](docs/SUBAGENTS.md) — Subagenti e guida alla creazione
- [DISPLAY-MODES.md](docs/DISPLAY-MODES.md) — Modalità display: tmux vs iTerm2
