# Installazione e Quick Start

> Da zero a sessione funzionante in 5 minuti.

---

## Prerequisiti

| Requisito | Note |
|-----------|------|
| **macOS o Linux** | Windows non supportato (WSL2 non testato) |
| **Docker Desktop** (macOS) o **Docker Engine** (Linux) | Deve essere in esecuzione |
| **Bash 4+** | macOS include bash 3.2 (`/bin/bash`) — sufficiente per il CLI |
| **jq** | `brew install jq` (macOS) / `apt install jq` (Linux) |
| **Account Claude Code** | Pro, Team, Enterprise, oppure API key |

---

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

# 3. Inizializza configurazione utente e build dell'immagine Docker
cco init
```

`cco init` esegue tre operazioni:
1. Copia i default utente in `global/.claude/` (agent, skill, regole, settings)
2. Crea la directory `projects/`
3. Avvia `cco build` per costruire l'immagine Docker

---

## Uso rapido

```bash
# Crea un progetto
cco project create my-app --repo ~/projects/my-app

# Configura il progetto
vim projects/my-app/project.yml         # repos, ports, auth
vim projects/my-app/.claude/CLAUDE.md   # istruzioni per Claude

# Avvia una sessione
cco start my-app

# Tip: alla prima sessione, usa /init-workspace per generare
# automaticamente un CLAUDE.md dettagliato basato sul codebase
```

Per sessioni temporanee senza creare un progetto:

```bash
cco new --repo ~/projects/experiment
cco new --repo ~/projects/api --repo ~/projects/frontend --port 3000:3000
```

---

## Comandi principali

| Comando | Descrizione |
|---------|-------------|
| `cco init` | Inizializza configurazione utente e build immagine |
| `cco build` | Build dell'immagine Docker |
| `cco build --no-cache` | Rebuild completo (aggiorna Claude Code) |
| `cco build --claude-version x.y.z` | Fissa Claude Code a una versione specifica |
| `cco start <project>` | Avvia sessione per un progetto configurato |
| `cco start <project> --dry-run` | Mostra il docker-compose generato senza eseguire |
| `cco new --repo <path>` | Sessione temporanea con repository specifiche |
| `cco project create <name>` | Crea un nuovo progetto da template |
| `cco project list` | Lista progetti disponibili |
| `cco stop [project]` | Ferma sessione/i in esecuzione |

---

## Configurazione progetto

Ogni progetto vive in `projects/<name>/` e contiene:

- **`project.yml`** — repository da montare, porte, variabili d'ambiente, metodo di autenticazione
- **`.claude/CLAUDE.md`** — istruzioni specifiche per Claude
- **`.claude/settings.json`** — override delle impostazioni globali (opzionale)
- **`.claude/agents/`** — subagent specifici del progetto (opzionale)

Per il formato completo di `project.yml` vedi [cli.md](../reference/cli.md).

---

## Knowledge pack

I pack permettono di condividere documentazione cross-progetto (convenzioni, overview di business, linee guida) e opzionalmente skill/agent/rule senza copiare file.

```bash
# 1. Definisci un pack in global/packs/<name>/pack.yml
cat > global/packs/my-client/pack.yml << 'EOF'
name: my-client

knowledge:
  source: ~/documents/my-client-knowledge   # directory con i documenti
  files:
    - path: backend-conventions.md
      description: "Read when writing backend code or APIs"
    - path: business-overview.md
      description: "Read for business context and domain terminology"
    - testing-guidelines.md
EOF

# 2. Attiva il pack in project.yml
# packs:
#   - my-client

# 3. Avvia — i pack vengono iniettati automaticamente
cco start my-app
```

`cco start` monta la directory sorgente in sola lettura, genera `packs.md` con la lista dei file, e l'hook `session-context.sh` la inietta in `additionalContext` all'avvio. I file originali restano nella tua directory — zero duplicazione.

---

## Opzioni aggiuntive

```bash
# Override modalita agent team
cco start my-app --teammate-mode auto    # iTerm2 nativo (richiede setup)
cco start my-app --teammate-mode tmux    # default, funziona ovunque

# Usa API key invece di OAuth
cco start my-app --api-key

# Porte e variabili d'ambiente aggiuntive
cco start my-app --port 9090:9090 --env DEBUG=true
```

---

## Troubleshooting primo avvio

### Docker non in esecuzione

```
Error: Docker daemon is not running. Start Docker Desktop.
```

Avvia Docker Desktop (macOS) o il servizio Docker (`sudo systemctl start docker` su Linux), poi riprova.

### Build dell'immagine fallisce

```bash
# Riprova con una build pulita
cco build --no-cache
```

Se il problema persiste, verifica la connessione internet (l'immagine scarica `node:22-bookworm` e i pacchetti npm) e che Docker abbia sufficiente spazio disco.

### Conflitto di porte

```
Error: Port 3000 is already in use.
```

Un altro servizio sta usando la porta. Fermalo, oppure usa una porta diversa:

```bash
cco start my-app --port 3001:3000
```

### Immagine Docker non trovata

```
Error: Docker image 'claude-orchestrator:latest' not found. Run 'cco build' first.
```

Esegui `cco build` per costruire l'immagine. Se hai gia eseguito `cco init`, la build dovrebbe essere stata avviata automaticamente.

---

## Prossimi passi

- [Il tuo primo progetto](first-project.md) — tutorial guidato passo-passo
- [Concetti chiave](concepts.md) — gerarchia di contesto, knowledge pack, agent team
- [Overview](overview.md) — cos'e e come funziona claude-orchestrator
