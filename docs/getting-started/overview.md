# Cos'e claude-orchestrator

> Sessioni Claude Code isolate in Docker, pronte all'uso con un singolo comando.

---

## Cos'e

claude-orchestrator e un tool che gestisce sessioni Claude Code all'interno di container Docker. Ogni sessione viene configurata automaticamente con:

- Le repository del progetto montate in lettura-scrittura
- Il contesto completo (istruzioni, regole, agent, skill)
- Agent team pronti per il lavoro collaborativo
- Memoria isolata per progetto

Un singolo comando (`cco start my-app`) lancia tutto.

---

## Perche usarlo

| Problema | Soluzione |
|----------|-----------|
| Gestire piu progetti con configurazioni diverse | Ogni progetto ha il proprio `project.yml` con repo, porte, variabili d'ambiente |
| Contesto perso tra le sessioni | Gerarchia a quattro livelli: managed, globale, progetto, repository |
| Agent team complessi da configurare | Configurazione automatica con tmux (o iTerm2) |
| Workflow non strutturato | Fasi predefinite (Analysis, Design, Implementation, Documentation) con transizioni manuali |
| Memoria condivisa tra progetti | Ogni progetto ha la propria directory `claude-state/` isolata |
| Rischio di danni al filesystem host | Docker fornisce isolamento completo: `--dangerously-skip-permissions` e sicuro nel container |

---

## Come funziona

Il flusso di avvio e semplice:

1. **`cco start my-app`** — il CLI legge `project.yml`
2. **Genera `docker-compose.yml`** — volume mount per repo, porte, variabili d'ambiente
3. **Lancia il container Docker** — immagine con Claude Code, tmux, Docker CLI, git
4. **Entrypoint** — sistema i permessi, configura MCP, avvia tmux
5. **Claude Code** — si avvia con tutto il contesto gia caricato

```mermaid
graph LR
    subgraph Host
        CLI["cco CLI"]
        PROJ["project.yml"]
        GLOBAL["global/.claude/"]
        REPOS["~/projects/repos/"]
    end

    subgraph Container Docker
        EP["entrypoint.sh"]
        TMUX["tmux"]
        CLAUDE["Claude Code"]
    end

    CLI -->|"legge config"| PROJ
    CLI -->|"genera docker-compose.yml"| Container Docker
    GLOBAL -->|"mount ~/.claude/"| EP
    PROJ -->|"mount /workspace/.claude/"| EP
    REPOS -->|"mount /workspace/repos/"| Container Docker
    EP --> TMUX --> CLAUDE
```

All'interno del container, Claude Code ha accesso a:

- **Tutte le repository** del progetto in `/workspace/`
- **Docker socket** dell'host per lanciare container fratelli (postgres, redis, ecc.)
- **Porte esposte** verso `localhost` sulla macchina host
- **Git e GitHub CLI** per commit, push e pull request

---

## Prossimo passo

Vai alla [guida di installazione](installation.md) per configurare claude-orchestrator sulla tua macchina.
