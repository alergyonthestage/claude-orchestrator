# Documentazione

## Da dove parto?

| Profilo | Percorso |
|---|---|
| **Sono nuovo, da dove inizio?** | [getting-started/](getting-started/) — Overview → installazione → primo progetto → concetti |
| **Devo configurare un progetto** | [user-guides/](user-guides/) — Setup progetto, knowledge pack, autenticazione, agent team |
| **Ho un problema** | [user-guides/troubleshooting.md](user-guides/troubleshooting.md) |
| **Cerco un comando specifico** | [reference/cli.md](reference/cli.md) |
| **Voglio contribuire** | [maintainer/README.md](maintainer/README.md) |

---

## Getting Started

Percorso consigliato per chi inizia, da leggere in ordine.

| Documento | Contenuto |
|---|---|
| [overview.md](getting-started/overview.md) | Cos'è claude-orchestrator, a cosa serve, come si posiziona |
| [installation.md](getting-started/installation.md) | Requisiti, installazione, `cco init` |
| [first-project.md](getting-started/first-project.md) | Creare e avviare il primo progetto passo-passo |
| [concepts.md](getting-started/concepts.md) | Gerarchia contesto, knowledge pack, agent team, memoria |

## Guide utente

Guide operative per l'uso quotidiano.

| Documento | Contenuto |
|---|---|
| [project-setup.md](user-guides/project-setup.md) | Configurare un progetto: repo, mount, CLAUDE.md, project.yml |
| [knowledge-packs.md](user-guides/knowledge-packs.md) | Creare e attivare knowledge pack riutilizzabili |
| [agent-teams.md](user-guides/agent-teams.md) | Configurare agent team con tmux e iTerm2 |
| [authentication.md](user-guides/authentication.md) | OAuth, API key, GitHub token, gestione secrets |
| [troubleshooting.md](user-guides/troubleshooting.md) | Problemi comuni e soluzioni |
| [advanced/subagents.md](user-guides/advanced/subagents.md) | Subagent custom (analyst, reviewer) |
| [advanced/custom-environment.md](user-guides/advanced/custom-environment.md) | Setup script, pacchetti extra, immagini custom |

## Riferimento tecnico

Documentazione di riferimento per CLI, configurazione e architettura.

| Documento | Contenuto |
|---|---|
| [cli.md](reference/cli.md) | Tutti i comandi `cco`, opzioni e flag |
| [project-yaml.md](reference/project-yaml.md) | Formato completo di `project.yml` |
| [context-hierarchy.md](reference/context-hierarchy.md) | Gerarchia a quattro livelli, risoluzione settings, memoria |

## Maintainer

Architettura, specifiche e roadmap per chi contribuisce al progetto.

| Documento | Contenuto |
|---|---|
| [README.md](maintainer/README.md) | Guida per contributor, struttura del codice |
| [architecture.md](maintainer/architecture.md) | Decisioni architetturali (ADR) e design del sistema |
| [spec.md](maintainer/spec.md) | Specifica dei requisiti |
| [roadmap.md](maintainer/roadmap.md) | Funzionalità pianificate e miglioramenti futuri |

Design doc e analisi per area:

| Area | Documenti |
|---|---|
| Scope hierarchy | [analysis](maintainer/scope-hierarchy/analysis.md), [design](maintainer/scope-hierarchy/design.md) |
| Autenticazione | [analysis](maintainer/auth/analysis.md), [design](maintainer/auth/design.md) |
| Knowledge pack | [design](maintainer/packs/design.md) |
| Ambiente | [analysis](maintainer/environment/analysis.md), [design](maintainer/environment/design.md) |
| Docker | [design](maintainer/docker/design.md) |
| Agent team | [analysis](maintainer/agent-teams/analysis.md) |
| Worktree | [analysis](maintainer/future/worktree/analysis.md), [design](maintainer/future/worktree/design.md) |
| Browser MCP | [analysis](maintainer/future/browser-mcp/analysis.md) |
| Update system | [design](maintainer/future/update-system/design.md) |
| Review | [24-02-2026](maintainer/reviews/24-02-2026-architecture-review.md), [26-02-2026](maintainer/reviews/26-02-2026-progress-review.md), [sprint plan](maintainer/reviews/sprint-2-3-implementation-plan.md) |
