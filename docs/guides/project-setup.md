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

### Repos vs Extra Mounts vs Packs

| Campo | Scopo | Montato in | Caricato in contesto | Uso tipico |
|-------|-------|------------|----------------------|------------|
| `repos` | Repository di lavoro attivi | `/workspace/<name>/` | On-demand (quando Claude legge file) | Codice che Claude modifica |
| `extra_mounts` | Materiale di riferimento puntuale | Path custom | No (Claude lo legge su richiesta) | Librerie condivise, API specs, dataset |
| `packs` | Knowledge trasversale riusabile | `/workspace/.packs/<name>/` | Sì (via `@.claude/packs.md`) | Convenzioni, business overview, guidelines |

**repos** — I repository su cui Claude lavora attivamente. Vengono montati come subdirectory di `/workspace/` e Claude vi ha accesso in lettura/scrittura. I file `.claude/CLAUDE.md` dentro i repo vengono caricati automaticamente quando Claude legge file in quella directory.

**extra_mounts** — Materiale aggiuntivo che serve come riferimento. Montato in un path arbitrario nel container, tipicamente in read-only. Utile per librerie condivise (es. framework interni), API specs, o qualsiasi file di riferimento che Claude potrebbe voler leggere ma non modificare.

**packs** — Gruppi di documenti di knowledge (convenzioni, business overview, linee guida) definiti una volta in `global/packs/` e riusabili in più progetti senza copiare nulla. La source directory del pack viene montata read-only e i file vengono iniettati automaticamente nel contesto di Claude via `@import`. Ideali per documentazione trasversale che si applica a tutti i progetti di un cliente o dominio.

```yaml
repos:
  - path: ~/projects/backend-api
    name: backend-api
  - path: ~/projects/frontend-app
    name: frontend-app

extra_mounts:
  - source: ~/projects/shared-framework
    target: /workspace/shared-framework
    readonly: true

packs:
  - my-client-knowledge   # → global/packs/my-client-knowledge/pack.yml
```

### Configurare un pack

Crea `global/packs/<nome>/pack.yml`:

```yaml
name: my-client-knowledge
source: ~/documents/my-client    # directory con i file di knowledge
target: /workspace/.packs/my-client

files:
  - backend-coding-conventions.md
  - business-overview.md
  - testing-guidelines.md
```

Poi aggiungi **una volta** al `projects/<n>/.claude/CLAUDE.md` del progetto:

```markdown
@.claude/packs.md
```

Ogni `cco start` rigenera automaticamente `.claude/packs.md` con le `@import` directives per i file del pack. I file originali restano nel tuo repo di knowledge — zero duplicazione.

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
1. ~/.claude/CLAUDE.md                          ← Globale (sempre caricato)
   └── ~/.claude/rules/*.md

2. /workspace/.claude/CLAUDE.md                 ← Progetto (sempre caricato)
   ├── /workspace/.claude/rules/*.md
   └── @.claude/packs.md                        ← Knowledge packs (se configurati)
         └── @/workspace/.packs/<name>/*.md

3. /workspace/<repo>/.claude/CLAUDE.md          ← Repository (on-demand)
```

I settings di progetto (livello 2) sovrascrivono quelli globali (livello 1). Le istruzioni di repository (livello 3) si aggiungono quando Claude legge file in quella directory.

I **knowledge packs** si innestano nel livello progetto tramite `@.claude/packs.md` (auto-generato da `cco start`): Claude riceve in contesto i file della knowledge senza che tu debba copiarli nel progetto.

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

## 6. Versionamento configurazione utente

Poiché `global/` e `projects/` sono gitignored nel repo dell'orchestrator, puoi versionarli separatamente.

### Pattern "config repo"

Se lavori su più macchine, tieni la tua configurazione utente in un repo separato:

```bash
# Sulla macchina principale, inizializza un repo per la config
cd ~/claude-orchestrator
git init global/
cd global/
git add -A && git commit -m "Initial global config"
git remote add origin <your-config-repo-url>
git push -u origin main
```

Su un'altra macchina:

```bash
# Clona l'orchestrator
git clone <orchestrator-url> ~/claude-orchestrator
cd ~/claude-orchestrator
cco init  # crea global/ dai defaults

# Oppure: sostituisci global/ con il tuo repo config
rm -rf global/
git clone <your-config-repo-url> global/
```

### Gestire aggiornamenti dei defaults

Quando il tool viene aggiornato (`git pull`), i defaults in `defaults/` potrebbero cambiare. Per vedere le differenze rispetto alla tua configurazione attuale:

```bash
# Confronta la tua config con i nuovi defaults
diff -r defaults/global/.claude/ global/.claude/

# Per resettare ai nuovi defaults (sovrascrive le personalizzazioni):
cco init --force
```

### Esempio pratico

```bash
# Setup iniziale
git clone <orchestrator-url> ~/claude-orchestrator
cd ~/claude-orchestrator
cco init                                    # Copia defaults → global/, builda immagine

# Personalizza
vim global/.claude/CLAUDE.md                # Le tue istruzioni globali
vim global/.claude/rules/my-rules.md        # Le tue regole custom

# Crea progetti
cco project create my-app --repo ~/code/my-app
vim projects/my-app/.claude/CLAUDE.md       # Istruzioni per questo progetto

# Aggiorna il tool (senza conflitti!)
git pull                                    # Aggiorna solo defaults/, bin/, docs/
```

---

## 7. Checklist post-creazione

Dopo `cco project create`:

- [ ] Verifica `project.yml`: repos, porte, variabili d'ambiente
- [ ] Personalizza `.claude/CLAUDE.md` (o usa `/init` alla prima sessione)
- [ ] Aggiungi settings custom in `.claude/settings.json` se necessario
- [ ] Configura `packs:` in `project.yml` se hai knowledge trasversale da condividere
- [ ] Se usi packs: aggiungi `@.claude/packs.md` al `CLAUDE.md` del progetto (una volta sola)
- [ ] Primo avvio: `cco start <nome>` — verifica che tutto funzioni
- [ ] Opzionale: aggiungi subagenti custom in `.claude/agents/`
