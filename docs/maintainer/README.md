# Guida per Contributor

Questa sezione contiene la documentazione tecnica interna di claude-orchestrator, destinata a chi sviluppa o mantiene il progetto. Qui trovi design doc, analisi tecniche, review architetturali e specifiche di implementazione.

---

## Mappa delle Aree Funzionali

Ogni area del progetto ha uno o entrambi i tipi di documento:

- **Design doc** — descrive come un componente è (o sarà) costruito: architettura, decisioni, flussi, interfacce
- **Analysis doc** — investigazione tecnica: opzioni valutate, vincoli, raccomandazioni

| Area | Design | Analysis |
|------|--------|----------|
| Scope & Context Hierarchy | [scope-hierarchy/design.md](scope-hierarchy/design.md) | [scope-hierarchy/analysis.md](scope-hierarchy/analysis.md) |
| Authentication & Secrets | [auth/design.md](auth/design.md) | [auth/analysis.md](auth/analysis.md) |
| Environment Extensibility | [environment/design.md](environment/design.md) | [environment/analysis.md](environment/analysis.md) |
| Docker Infrastructure | [docker/design.md](docker/design.md) | — |
| Agent Teams | — | [agent-teams/analysis.md](agent-teams/analysis.md) |
| Knowledge Packs | [packs/design.md](packs/design.md) | — |
| Git Worktree Isolation | [future/worktree/design.md](future/worktree/design.md) | [future/worktree/analysis.md](future/worktree/analysis.md) |
| Browser MCP | — | [future/browser-mcp/analysis.md](future/browser-mcp/analysis.md) |
| Update System | [future/update-system/design.md](future/update-system/design.md) | — |

---

## Documenti Fondamentali

Questi tre documenti costituiscono il nucleo della documentazione di progetto:

- [architecture.md](architecture.md) — ADR (Architecture Decision Records), diagrammi di sistema, flussi dati e considerazioni di sicurezza
- [spec.md](spec.md) — specifica dei requisiti funzionali e non funzionali
- [roadmap.md](roadmap.md) — piano di sviluppo, priorità e stato di avanzamento delle feature

---

## Review

La directory [reviews/](reviews/) contiene le review architetturali e di avanzamento condotte durante lo sviluppo. Ogni review documenta lo stato del progetto a una certa data, le decisioni prese e i prossimi passi concordati.

---

## Organizzazione della Documentazione

La documentazione maintainer segue due convenzioni:

1. **Design doc** (`<area>/design.md`) — descrivono come qualcosa è costruito o sarà costruito. Contengono: overview, architettura, flussi, decisioni implementative, interfacce, edge case. Sono il riferimento primario per chi implementa.

2. **Analysis doc** (`<area>/analysis.md`) — documentano indagini tecniche. Contengono: problema analizzato, opzioni considerate con pro/contro, vincoli identificati, raccomandazione finale. Sono il riferimento per capire *perché* una certa direzione è stata scelta.

Le aree in `future/` riguardano feature non ancora implementate. I design doc in questa directory sono proposte approvate ma non ancora realizzate.
