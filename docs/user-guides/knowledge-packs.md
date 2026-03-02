# Knowledge Packs

> Guida pratica alla creazione, configurazione e gestione dei knowledge pack.

---

## Cosa sono i Knowledge Pack

I knowledge pack sono pacchetti riutilizzabili che raggruppano documentazione, convenzioni, skill, agent e rule. Possono essere condivisi tra piu progetti senza duplicare file. Un pack puo contenere, ad esempio, le convenzioni di codifica di un cliente, le linee guida di un team, o la documentazione di un dominio specifico.

I pack vivono in `global/packs/` e vengono attivati per progetto tramite `project.yml`.

---

## Creare un pack

### Comando rapido

```bash
cco pack create my-client-knowledge
```

Questo crea la struttura di directory completa in `global/packs/my-client-knowledge/` con un `pack.yml` di template.

### Struttura directory

```
global/packs/my-client-knowledge/
  pack.yml              # Definizione del pack (obbligatorio)
  knowledge/            # File di documentazione (opzionale)
    overview.md
    coding-conventions.md
  skills/               # Skill directories (opzionale)
    deploy/
      SKILL.md
  agents/               # Agent definitions (opzionale)
    specialist.md
  rules/                # Rule files (opzionale)
    api-conventions.md
```

### Formato pack.yml

Il file `pack.yml` dichiara il contenuto del pack. Tutte le sezioni sono opzionali: un pack puo contenere solo knowledge, solo skill, o qualsiasi combinazione.

```yaml
name: my-client-knowledge

# ── Knowledge files ─────────────────────────────────────────────────
knowledge:
  source: ~/documents/my-client-docs   # directory sull'host (montata read-only)
  files:
    - path: backend-coding-conventions.md
      description: "Read when writing backend code, APIs, or DB logic"
    - path: business-overview.md
      description: "Read for business context and product understanding"
    - testing-guidelines.md              # forma breve: senza descrizione

# ── Skills (nomi directory sotto skills/) ───────────────────────────
skills:
  - deploy

# ── Agents (nomi file sotto agents/) ───────────────────────────────
agents:
  - specialist.md

# ── Rules (nomi file sotto rules/) ─────────────────────────────────
rules:
  - api-conventions.md
```

---

## La sezione knowledge

La sezione `knowledge` e il cuore del pack: permette di iniettare documentazione nel contesto di Claude senza modificare alcun `CLAUDE.md`.

### source

Il campo `source` indica una directory sull'host che contiene i file di documentazione. Viene montata read-only nel container a `/workspace/.packs/<nome-pack>/`.

```yaml
knowledge:
  source: ~/documents/my-client-docs
```

Se `source` e omesso, il pack usa la propria directory `knowledge/` interna:

```yaml
# Senza source: i file vanno in global/packs/<name>/knowledge/
knowledge:
  files:
    - path: overview.md
      description: "Project overview and architecture"
```

### files

La lista `files` dichiara quali file rendere visibili a Claude e con quali istruzioni.

Ogni file puo avere due formati:

```yaml
files:
  # Formato esteso: con descrizione (consigliato)
  - path: backend-conventions.md
    description: "Read when writing backend code or API endpoints"

  # Formato breve: solo il nome del file
  - testing-guidelines.md
```

La descrizione e importante: viene inclusa nel contesto di Claude per aiutarlo a decidere **quando** leggere quel file. Una buona descrizione indica il contesto d'uso ("Read when...", "Reference for...", "Check before...").

---

## Risorse opzionali

Oltre alla knowledge, un pack puo includere skill, agent e rule che vengono copiati nella configurazione del progetto.

### Skills

Le skill sono directory contenenti un file `SKILL.md`. Vengono copiate in `/workspace/.claude/skills/` e sono disponibili come comandi slash (es. `/deploy`).

```yaml
skills:
  - deploy          # Riferimento a global/packs/<name>/skills/deploy/SKILL.md
```

### Agents

Gli agent sono file Markdown che definiscono subagent specializzati. Vengono copiati in `/workspace/.claude/agents/`.

```yaml
agents:
  - devops-specialist.md   # Riferimento a global/packs/<name>/agents/devops-specialist.md
```

### Rules

Le rule sono file Markdown con istruzioni aggiuntive. Vengono copiate in `/workspace/.claude/rules/`.

```yaml
rules:
  - api-conventions.md     # Riferimento a global/packs/<name>/rules/api-conventions.md
```

---

## Attivare un pack in un progetto

Per attivare un pack, aggiungi il suo nome alla lista `packs:` nel file `project.yml` del progetto:

```yaml
# projects/my-saas/project.yml
name: my-saas

repos:
  - path: ~/projects/backend-api
    name: backend-api

packs:
  - my-client-knowledge
  - team-conventions
```

I pack vengono processati ad ogni `cco start`: le risorse sono copiate e la knowledge e montata automaticamente.

### Precedenza in caso di conflitti

Se due pack definiscono lo stesso agent, rule o skill, l'ultimo pack nella lista `packs:` vince. Un warning viene emesso a terminale per segnalare il conflitto.

---

## Gestione dei pack

### Elencare i pack disponibili

```bash
cco pack list
```

Output:
```
NAME              KNOWLEDGE  SKILLS  AGENTS  RULES
my-client             3         1       1       1
team-conventions      2         0       0       2
```

### Vedere i dettagli di un pack

```bash
cco pack show my-client-knowledge
```

Mostra il contenuto completo del pack: file di knowledge con descrizioni, skill, agent, rule e i progetti che lo utilizzano.

### Validare un pack

```bash
# Validare un pack specifico
cco pack validate my-client-knowledge

# Validare tutti i pack
cco pack validate
```

Verifica la struttura del pack: presenza di `pack.yml`, esistenza dei file dichiarati, formato corretto.

### Rimuovere un pack

```bash
# Con conferma (se usato da progetti attivi)
cco pack remove my-client-knowledge

# Forzare la rimozione
cco pack remove my-client-knowledge --force
```

Se il pack e utilizzato da uno o piu progetti, viene richiesta conferma prima della rimozione.

---

## Come funziona l'iniezione

L'iniezione dei knowledge pack e completamente automatica e non richiede alcuna modifica ai file `CLAUDE.md`.

Il processo avviene in due fasi:

**1. Al momento di `cco start`:**
- La directory `knowledge.source` viene montata in read-only a `/workspace/.packs/<nome>/`
- Viene generato il file `.claude/packs.md` con la lista dei file e le relative descrizioni
- Skill, agent e rule vengono copiati nella directory `.claude/` del progetto
- Un file `.pack-manifest` traccia i file copiati per la pulizia al prossimo avvio

**2. All'avvio della sessione Claude:**
- L'hook `session-context.sh` (SessionStart) inietta il contenuto di `packs.md` in `additionalContext`
- Claude riceve automaticamente la lista dei file di knowledge disponibili con le descrizioni
- I file vengono letti on-demand da Claude quando rilevanti per il task corrente

Esempio di `packs.md` generato:

```
The following knowledge files provide project-specific conventions and context.
Read the relevant files BEFORE starting any implementation, review, or design task.

- /workspace/.packs/my-client/backend-coding-conventions.md — Read when writing backend code
- /workspace/.packs/my-client/business-overview.md — Read for business context
- /workspace/.packs/my-client/testing-guidelines.md
```

---

## Best practice

### Naming

- Usa nomi lowercase con trattini: `my-client-docs`, `team-backend-conventions`
- Scegli nomi descrittivi che indichino il dominio: `frontend-design-system`, `devops-runbooks`

### Descrizioni dei file

- Scrivi descrizioni orientate all'azione: "Read when writing...", "Check before deploying...", "Reference for..."
- Evita descrizioni generiche come "Documentation" o "Guidelines"
- La descrizione aiuta Claude a decidere quando leggere il file, quindi sii specifico

### Organizzazione dei file di knowledge

- Mantieni i file focalizzati su un singolo argomento
- Preferisci piu file piccoli a un unico file grande (riduce il consumo di contesto)
- Se un file supera le 500 righe, considera di suddividerlo
- Usa nomi di file descrittivi: `backend-coding-conventions.md` invece di `conventions.md`

### Separazione delle responsabilita

- Usa la sezione `knowledge` per documentazione e contesto (read-only, non processata)
- Usa `skills` per azioni invocabili dall'utente (es. deploy, review)
- Usa `rules` per istruzioni comportamentali sempre attive
- Usa `agents` per subagent specializzati con ruoli definiti
