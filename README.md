# claude-orchestrator

> Orchestrate Claude Code sessions in Docker.

Sessioni Claude Code isolate, preconfigurate e pronte all'uso — un comando per partire.

## Perché claude-orchestrator?

- **Isolamento completo** — Ogni progetto gira in un container Docker dedicato. Niente conflitti, niente leak di contesto tra progetti. `--dangerously-skip-permissions` è sicuro perché Docker è la sandbox.
- **Contesto automatico** — Repo montati, knowledge pack attivati, CLAUDE.md generato. Claude parte già sapendo tutto del progetto, senza setup manuale.
- **Agent team integrati** — Sessioni tmux con lead + teammate, pronti a collaborare. Un agent coordina, gli altri eseguono.
- **Knowledge pack riutilizzabili** — Convenzioni, linee guida, documentazione di dominio: definiti una volta, attivati per progetto. La source of truth resta nel tuo repo.
- **Memoria isolata** — Ogni progetto ha la propria directory di memoria. Insight e cronologia non si mescolano tra sessioni diverse.

## Come funziona

```mermaid
graph LR
    subgraph Host
        CLI["cco CLI"]
        CFG["Configurazione<br/>(global + progetto)"]
        REPOS["I tuoi repo"]
    end

    subgraph Container Docker
        CC["Claude Code<br/>con contesto completo"]
        TMUX["tmux<br/>(agent team)"]
        DOCK["Docker CLI<br/>(infrastruttura)"]
    end

    CLI -->|genera & avvia| Container Docker
    CFG -->|mount| CC
    REPOS -->|mount read-write| Container Docker
    CC --- TMUX
    CC --- DOCK
```

```
Setup: git clone → cco init → cco project create → cco start
```

## Quick Start

```bash
# 1. Clona il repository
git clone https://github.com/user/claude-orchestrator.git
cd claude-orchestrator

# 2. Inizializza (copia defaults, build immagine Docker)
bin/cco init

# 3. Crea un progetto
bin/cco project create my-app

# 4. Avvia la sessione
bin/cco start my-app
```

## Funzionalità principali

| Funzionalità | Descrizione |
|---|---|
| **CLI monolitico** | Un singolo script Bash (`bin/cco`) — nessuna dipendenza oltre Bash 4+, Docker e strumenti Unix standard |
| **Gerarchia a quattro livelli** | Managed → Global → Project → Repo, mappata nativamente sulla risoluzione settings di Claude Code |
| **Docker-from-Docker** | Il socket Docker è montato nel container. Claude può lanciare `docker compose` per creare container fratelli (database, servizi) |
| **Knowledge pack** | Documenti riutilizzabili (convenzioni, overview, linee guida) definiti in `global/packs/` e attivati per progetto in `project.yml` |
| **Agent team** | Sessioni tmux con lead + teammate. Supporto iTerm2 opzionale su macOS |
| **Autenticazione flessibile** | OAuth (credentials da macOS Keychain), API key via env var, GitHub token per `gh` CLI |
| **Ambiente estendibile** | Setup script, pacchetti extra e immagini custom configurabili per progetto |

## Documentazione

| Percorso | Contenuto |
|---|---|
| **Nuovo utente** | [getting-started/](docs/getting-started/) — Overview, installazione, primo progetto, concetti |
| **Guide utente** | [user-guides/](docs/user-guides/) — Setup progetto, knowledge pack, autenticazione, agent team, troubleshooting |
| **Riferimento tecnico** | [reference/](docs/reference/) — CLI, project.yml, gerarchia contesto |
| **Contribuire** | [maintainer/](docs/maintainer/) — Architettura, spec, roadmap, design doc |

Indice completo: [docs/README.md](docs/README.md)

## Requisiti

- **OS**: macOS o Linux
- **Docker**: Docker Desktop (macOS) o Docker Engine (Linux)
- **Bash**: 4+ (macOS: il CLI è compatibile con `/bin/bash` 3.2)
- **Claude Code**: account Pro, Team, Enterprise o API key
