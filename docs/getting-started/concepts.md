# Concetti chiave

> I concetti fondamentali di claude-orchestrator, spiegati in breve.

---

## Gerarchia di contesto

claude-orchestrator organizza la configurazione su quattro livelli, dal piu prioritario al meno:

| Livello | Path nel container | Cosa contiene | Modificabile? |
|---------|-------------------|---------------|---------------|
| **Managed** | `/etc/claude-code/` | Hook, variabili d'ambiente, deny rules | No (baked nell'immagine) |
| **User** | `~/.claude/` | Preferenze, agent, skill, regole | Si |
| **Project** | `/workspace/.claude/` | Istruzioni e config specifiche del progetto | Si |
| **Repo** | `/workspace/<repo>/.claude/` | Contesto della singola repository | Si (vive nella repo) |

I livelli superiori hanno la precedenza. Questo significa che gli hook managed sono sempre attivi e non possono essere disabilitati, mentre le impostazioni progetto sovrascrivono quelle globali. Ogni livello carica automaticamente i file `CLAUDE.md`, `settings.json`, `rules/*.md` e `agents/*.md` presenti nella sua directory.

Per la reference completa vedi [context-hierarchy.md](../reference/context-hierarchy.md).

---

## Knowledge pack

I knowledge pack sono raccolte riutilizzabili di documentazione (convenzioni, overview di business, linee guida) che possono essere attivate su piu progetti senza copiare file.

Un pack viene definito in `global/packs/<name>/pack.yml` con un riferimento a una directory di documenti sull'host. All'avvio della sessione, `cco start` monta la directory read-only e genera una lista dei file disponibili. Claude li legge on-demand quando sono rilevanti per il task corrente. I pack possono anche contribuire skill, agent e rule a livello progetto.

Attivazione in `project.yml`:

```yaml
packs:
  - my-client-knowledge
```

Per approfondire: [project-setup.md](../user-guides/project-setup.md) (sezione Configure a Pack).

---

## Agent team

Claude Code supporta agent team — piu istanze Claude che lavorano in parallelo su task diversi, coordinate da un lead.

claude-orchestrator supporta due modalita di visualizzazione:

- **tmux** (default) — ogni teammate appare come un pannello tmux all'interno del container. Funziona con qualsiasi terminale, nessuna configurazione host necessaria.
- **iTerm2** (`--teammate-mode auto`) — usa pannelli nativi iTerm2 su macOS. UX migliore ma richiede configurazione aggiuntiva (Python API abilitata, `it2` CLI sull'host).

La modalita si configura in `global/.claude/settings.json` (`"teammateMode": "tmux"`) oppure via flag CLI (`--teammate-mode`).

Per approfondire: [display-modes.md](../user-guides/display-modes.md).

---

## Isolamento Docker

Il container Docker e il meccanismo di isolamento di claude-orchestrator. Claude Code viene lanciato con `--dangerously-skip-permissions`, che normalmente disabilita tutte le conferme di sicurezza. All'interno del container questo e sicuro perche:

- Il filesystem e isolato — Claude puo modificare solo le repository montate e i file del container
- La rete e controllata — solo le porte esplicitamente mappate sono raggiungibili dall'host
- I feature branch git forniscono un ulteriore livello di protezione — ogni modifica e reversibile
- Il container e effimero (`--rm`) — tutto cio che non e montato viene perso al termine

L'unico punto di accesso privilegiato e il Docker socket montato dall'host, che permette a Claude di creare container fratelli (es. postgres, redis) sul daemon Docker dell'host.

Per approfondire: [architecture.md](../maintainer/architecture.md) (ADR-1: Docker as the Only Sandbox).

---

## Auto memory

Ogni progetto ha la propria directory di memoria isolata (`projects/<name>/claude-state/memory/`). Claude Code salva automaticamente note e insight durante le sessioni, e li ricarica nelle sessioni successive.

L'isolamento garantisce che le informazioni di un progetto non "trapelino" in un altro. La directory `claude-state/` contiene anche i session transcript, necessari per il comando `/resume` che permette di riprendere una sessione precedente anche dopo un rebuild dell'immagine Docker.

Per approfondire: [context-hierarchy.md](../reference/context-hierarchy.md) (sezione Auto Memory).

---

## Skill e agent

Le **skill** sono comandi invocabili dall'utente (es. `/analyze`, `/commit`, `/review`) che eseguono task specifici con istruzioni predefinite. Ogni skill e una directory con un file `SKILL.md` che ne definisce comportamento e tool disponibili.

Gli **agent** sono profili specializzati (es. analyst, reviewer) che Claude puo istanziare come subagent con modelli e permessi specifici. Vengono definiti come file `.md` nella directory `agents/`.

Entrambi esistono a tre livelli:

| Livello | Skill | Agent |
|---------|-------|-------|
| Managed | `/etc/claude-code/.claude/skills/` (es. `/init-workspace`) | Non usato |
| User | `~/.claude/skills/` (es. `/analyze`, `/design`, `/review`, `/commit`) | `~/.claude/agents/` |
| Project | `/workspace/.claude/skills/` | `/workspace/.claude/agents/` |

I knowledge pack possono aggiungere skill e agent a livello progetto.

Per approfondire: [context-hierarchy.md](../reference/context-hierarchy.md) (sezioni Skills e Subagents).

---

## Prossimi passi

- [Il tuo primo progetto](first-project.md) — tutorial guidato passo-passo
- [Project setup](../user-guides/project-setup.md) — guida avanzata alla configurazione
- [CLI reference](../reference/cli.md) — tutti i comandi disponibili
