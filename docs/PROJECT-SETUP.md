# Guida Setup Progetto

> Related: [CLI.md](./CLI.md) | [CONTEXT.md](./CONTEXT.md) | [ARCHITECTURE.md](./ARCHITECTURE.md)

---

## 1. Creare un progetto

```bash
cco project create my-app \
  --repo ~/projects/backend-api \
  --repo ~/projects/frontend-app \
  --description "My SaaS application"
```

Questo genera la struttura in `projects/my-app/`:

```
projects/my-app/
├── project.yml              # Configurazione principale
├── .claude/
│   ├── CLAUDE.md            # Istruzioni per Claude (progetto)
│   ├── settings.json        # Override settings (opzionale)
│   ├── agents/              # Subagenti custom (opzionale)
│   └── rules/               # Regole custom (opzionale)
├── memory/                  # Auto memory (persistente tra sessioni)
└── docker-compose.yml       # Generato automaticamente da `cco start`
```

Se passi `--repo`, il CLI auto-rileva informazioni base dai repository (package.json, pyproject.toml, go.mod, ecc.) e popola CLAUDE.md con i dettagli.

---

## 2. Configurare project.yml

### Repos vs Extra Mounts

| Campo | Scopo | Montato in | Uso tipico |
|-------|-------|------------|------------|
| `repos` | Repository di lavoro attivi | `/workspace/<name>/` | Codice che Claude modifica |
| `extra_mounts` | Materiale di riferimento | Path custom | Docs, API specs, dataset (spesso `readonly: true`) |

**repos** — I repository su cui Claude lavora attivamente. Vengono montati come subdirectory di `/workspace/` e Claude vi ha accesso in lettura/scrittura. I file `.claude/CLAUDE.md` dentro i repo vengono caricati automaticamente quando Claude legge file in quella directory.

**extra_mounts** — Materiale aggiuntivo che serve come riferimento. Montato in un path arbitrario nel container, tipicamente in read-only. Utile per documentazione API, specifiche, dataset di test.

```yaml
repos:
  - path: ~/projects/backend-api
    name: backend-api
  - path: ~/projects/frontend-app
    name: frontend-app

extra_mounts:
  - source: ~/documents/api-specs
    target: /workspace/docs/api-specs
    readonly: true
```

### Porte e variabili d'ambiente

```yaml
docker:
  ports:
    - "3000:3000"       # Frontend dev server
    - "4000:4000"       # Backend API
    - "5432:5432"       # PostgreSQL (sibling container)
  env:
    NODE_ENV: development
    DATABASE_URL: "postgresql://postgres:postgres@postgres:5432/myapp"
```

Le porte rendono i servizi accessibili da `localhost` su macOS. Le variabili d'ambiente sono disponibili dentro il container.

### Autenticazione

```yaml
auth:
  method: oauth         # Default: usa il token dal macOS Keychain
  # method: api_key     # Alternativa: usa ANTHROPIC_API_KEY env var
```

---

## 3. Scrivere un buon CLAUDE.md

Il file `projects/<nome>/.claude/CLAUDE.md` è il punto centrale per dare contesto a Claude sul progetto. Un buon CLAUDE.md fa la differenza tra sessioni produttive e sessioni in cui Claude chiede continuamente chiarimenti.

### Approccio consigliato: usa /init

Al primo avvio del progetto, chiedi a Claude di analizzare il codebase:

```
> Usa /init per analizzare i repository e generare un CLAUDE.md dettagliato
```

Il comando `/init` di Claude Code analizza i file, rileva struttura, framework, comandi di build/test, e genera automaticamente contenuto rilevante. Puoi poi raffinarlo manualmente.

### Cosa includere

- **Overview**: Cosa fa il progetto, come si relazionano i repository tra loro
- **Architettura**: Tecnologie, pattern, componenti principali
- **Comandi**: Build, test, dev server, deploy — per ogni repository
- **Convenzioni**: Stile di codice, naming, pattern da seguire
- **Infrastruttura**: Se usi Docker Compose per servizi (postgres, redis...), specifica la rete del progetto

### Esempio

```markdown
# Project: my-saas

## Overview
Piattaforma SaaS con backend Node.js e frontend React.

## Repositories
- `/workspace/backend-api/` — API REST + GraphQL (Node.js, Express, Prisma)
- `/workspace/frontend-app/` — SPA React con Vite + TailwindCSS

## Architecture
Il backend espone API REST su :4000 e GraphQL su :4000/graphql.
Il frontend comunica via fetch con il backend.
Database PostgreSQL raggiungibile come `postgres:5432` nella rete Docker.

## Commands
### backend-api
- Dev: `npm run dev` (porta 4000)
- Test: `npm test` / `npm run test:watch`
- Lint: `npm run lint`

### frontend-app
- Dev: `npm run dev` (porta 3000)
- Build: `npm run build`
- Test: `npm run test`

## Infrastructure
Network Docker: `cc-my-saas`
Per i docker-compose dell'infrastruttura, usa:
\`\`\`yaml
networks:
  default:
    external: true
    name: cc-my-saas
\`\`\`
```

---

## 4. Gerarchia dei contesti

Claude Code carica le istruzioni in ordine di precedenza:

```
1. ~/.claude/CLAUDE.md                      ← Globale (sempre caricato)
2. /workspace/.claude/CLAUDE.md             ← Progetto (sempre caricato)
3. /workspace/<repo>/.claude/CLAUDE.md      ← Repository (on-demand)
```

I settings di progetto (livello 2) sovrascrivono quelli globali (livello 1). Le istruzioni di repository (livello 3) si aggiungono quando Claude legge file in quella directory.

Per approfondimenti sulla gerarchia vedi [CONTEXT.md](./CONTEXT.md).

---

## 5. Usare directory esterne per i progetti

Se vuoi tenere i progetti in una directory diversa (es. su un altro disco o per separarli tra macchine):

```bash
export CCO_PROJECTS_DIR=~/my-custom-projects
cco project create my-app --repo ~/projects/backend
cco start my-app
```

Analogamente per la configurazione globale:

```bash
export CCO_GLOBAL_DIR=~/my-claude-config
```

Questo permette di clonare il repo `claude-orchestrator` su più macchine mantenendo i progetti e le configurazioni separate.

---

## 6. Checklist post-creazione

Dopo `cco project create`:

- [ ] Verifica `project.yml`: repos, porte, variabili d'ambiente
- [ ] Personalizza `.claude/CLAUDE.md` (o usa `/init` alla prima sessione)
- [ ] Aggiungi settings custom in `.claude/settings.json` se necessario
- [ ] Primo avvio: `cco start <nome>` — verifica che tutto funzioni
- [ ] Opzionale: aggiungi subagenti custom in `.claude/agents/`
