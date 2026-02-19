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

# 3. Inizializza config utente e builda l'immagine Docker
cco init
```

## Uso

```bash
# Crea un progetto
cco project create my-app --repo ~/projects/my-app

# Configura il progetto
vim projects/my-app/project.yml         # repo, porte, auth
vim projects/my-app/.claude/CLAUDE.md   # istruzioni per Claude

# Avvia una sessione
cco start my-app

# Tip: alla prima sessione, usa /init per generare automaticamente
# un CLAUDE.md dettagliato basato sul codebase
```

Per sessioni temporanee senza creare un progetto:

```bash
cco new --repo ~/projects/experiment
cco new --repo ~/projects/api --repo ~/projects/frontend --port 3000:3000
```

## Comandi

| Comando | Descrizione |
|---------|-------------|
| `cco init` | Inizializza config utente dai defaults |
| `cco build` | Builda l'immagine Docker |
| `cco build --no-cache` | Rebuild completo (aggiorna Claude Code) |
| `cco start <progetto>` | Avvia sessione per un progetto configurato |
| `cco start <progetto> --dry-run` | Mostra il docker-compose generato senza avviare |
| `cco new --repo <path>` | Sessione temporanea con repo specifici |
| `cco project create <nome>` | Crea nuovo progetto da template |
| `cco project list` | Lista progetti disponibili |
| `cco stop [progetto]` | Ferma sessione/i in corso |

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
cco start my-app --teammate-mode auto    # iTerm2 nativo (richiede setup)
cco start my-app --teammate-mode tmux    # default, funziona ovunque

# Usa API key invece di OAuth
cco start my-app --api-key

# Porte e variabili extra
cco start my-app --port 9090:9090 --env DEBUG=true
```

## Documentazione

Per approfondimenti vedi [docs/](docs/):

- [PROJECT-SETUP.md](docs/PROJECT-SETUP.md) — Guida completa setup progetto, repos vs extra_mounts, scrivere CLAUDE.md
- [ARCHITECTURE.md](docs/ARCHITECTURE.md) — Architettura e decisioni di design
- [CLI.md](docs/CLI.md) — Dettaglio comandi e formato `project.yml`
- [DOCKER.md](docs/DOCKER.md) — Immagine Docker, compose, networking
- [CONTEXT.md](docs/CONTEXT.md) — Gerarchia contesto e settings
- [SUBAGENTS.md](docs/SUBAGENTS.md) — Subagenti e guida alla creazione
- [DISPLAY-MODES.md](docs/DISPLAY-MODES.md) — Modalità display: tmux vs iTerm2
