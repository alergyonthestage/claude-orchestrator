# Project: claude-orchestrator

## Overview
Self-development of claude-orchestrator

## Note: Self-Development

Stai sviluppando l'orchestratore dall'interno di una sua sessione.
Le modifiche a entrypoint.sh, hooks/*, e Dockerfile NON sono attive
in questa sessione. Per testarle, esci e fai `cco build && cco start`.

> **N.B.**
`cco build` dentro il container è possibile ma ricostruisce l'immagine sotto i piedi.
Claude ha accesso al Docker socket, quindi potrebbe eseguire `docker build -t claude-orchestrator:latest`. dall'interno del container. Questo ricostruirebbe l'immagine che il container stesso sta usando. Non crasha nulla (il container corrente usa l'immagine vecchia, le immagini Docker sono immutabili una volta lanciate), ma è confuso. La prossima cco start userebbe la nuova immagine. Anche qui, nessun problema reale — solo consapevolezza necessaria.

## Repositories

<!-- List your mounted repositories and their purpose -->

## Project-Specific Instructions

<!-- Add project-specific instructions, conventions, and context here -->

## Architecture

<!-- Describe the overall architecture, how repos relate to each other -->

## Infrastructure

<!-- If this project uses docker compose for infrastructure:
- Network name: cc-claude-orchestrator
- Set `networks.default.external = true` and `networks.default.name = cc-claude-orchestrator`
  in infrastructure docker-compose files so containers join the project network.
-->

## Key Commands

<!-- Common commands for this project:
- Build: ...
- Test: ...
- Run dev: ...
- Deploy: ...
-->
