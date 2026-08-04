# Handoff verso cco — La memoria di ruolo dei subagent

> ℹ️ **Provenance.** Received 2026-08-04 from an external adopter line and persisted here
> **verbatim**, in the language it was written in: it is a point-in-time *input*, not a cco decision.
> It is the field measurement behind **FI-39(a)** in [improvements.md](../../improvements.md);
> §4 is the reason FI-39 is weighed together with cross-PC state sync, not before it.
>
> **Da**: la linea di lavoro sul pack `core-dev-framework` (repo del corso), agosto 2026.
> **A**: una sessione di **analisi** interna a cco.
> **Priorità dichiarata: bassa.** Nessuna correzione del pack dipende da questa voce — il
> pack ha già rimosso ciò che vi si appoggiava. È qui perché è **misurata** e perché,
> quando cco la affronterà, il vincolo di §3 non è ovvio e costa caro scoprirlo dopo.
> **Autoconsistente**: non linka documenti del repo di provenienza.

---

## 1. La misura

Eseguita in sessione con `findmnt` e prove di scrittura effettive, non per inferenza.

| Scope dichiarato in un agent | Destinazione | Dove vive davvero | Esito |
|---|---|---|---|
| `memory: project` | `/workspace/.claude/agent-memory/<nome>/` | mount **read-only** | **la scrittura fallisce** |
| `memory: local` | `/workspace/.claude/agent-memory-local/<nome>/` | stesso mount read-only | **la scrittura fallisce** |
| `memory: user` | `~/.claude/agent-memory/<nome>/` | **overlay del container** | scrive, **non persiste**: sparisce all'uscita |
| *auto memory del lead* | `~/.claude/projects/<progetto>/memory/` | **bind mount rw** verso lo STATE dell'host | scrive **ed è persistita** |

**Esito netto**: dei quattro scope, **uno solo funziona**, ed è quello del lead. Dopo
settimane di adozione reale, i sei agent di un pack avevano prodotto **zero byte** di memoria
persistita. Lo store di `memory: user` esiste ed è **vuoto** — non è che non venga creato: non
sopravvive.

---

## 2. Cosa ha fatto il pack, e perché non serve aspettare cco

Il pack aveva sei sezioni `## Memory`, una per agent, che istruivano il modello ad aggiornare
la propria memoria. **Sono state rimosse**: 37 righe ripetute sei volte che puntavano a uno
store inerte. Il campo `memory: user` nel frontmatter **è rimasto**, deliberatamente — è
inerte, non falso, e il giorno in cui cco lo rendesse usabile non andrebbe ri-aggiunto.

➡️ **La richiesta è quindi una feature, non uno sblocco.** Nessuno sta aspettando.

---

## 3. Il vincolo che non è ovvio, e che va deciso prima di progettare

La ragione per cui `memory: project` e `memory: local` falliscono è che cco monta
`<repo>/.claude` in **sola lettura**. Ma quella stessa proprietà del mount è, da un'altra
angolazione, una **garanzia di sicurezza reale**:

> Una sessione **non può manomettere i propri hook, agent, skill e settings**, perché il path
> che li contiene è read-only a livello di OS. È indipendente dal permission mode — vale anche
> sotto `bypassPermissions` — e non è aggirabile da un sotto-processo.

Questo è stato **verificato sul campo** in una prova dedicata (vedi l'handoff su
`settings.json` e hooks, dove è il reperto più importante).

⚠️ **Ne segue il vincolo di progetto**: la soluzione alla memoria di ruolo **non può essere
"rendere `.claude` scrivibile"**. Sarebbe uno scambio pessimo — si comprerebbe una feature a
bassa priorità pagando una garanzia di sicurezza che oggi cco offre gratis e che nessun altro
livello sa dare.

Le direzioni che rispettano il vincolo:

| # | Direzione | Nota |
|---|---|---|
| **1** | Un **mount separato e scrivibile** per la memoria degli agent, fuori da `.claude` — con lo stesso trattamento STATE che ha già la auto memory del lead | è la forma che riusa un meccanismo funzionante invece di inventarne uno |
| **2** | Rendere scrivibile **solo** il sotto-percorso `agent-memory*/` dentro un `.claude` altrimenti ro | più chirurgico, ma introduce un'eccezione dentro il confine che dà la garanzia — l'eccezione va poi difesa a ogni modifica futura |
| **3** | Non fare nulla e **dichiararlo**: `memory: project` / `local` non sono supportati sotto cco | onesto e a costo zero; oggi il campo fallisce in silenzio, che è la sola cosa da non lasciare com'è |

**Anche la direzione 3 chiude qualcosa**: il difetto peggiore oggi non è l'assenza della
feature, è che uno scope dichiarato in un frontmatter **fallisce senza dirlo**.

---

## 4. Da pesare contro una cosa sola

Se cco introdurrà la **sincronizzazione della memoria fra host dello stesso utente, o fra
membri di un team**, il quadro cambia: la memoria di ruolo diventerebbe un oggetto da
sincronizzare, con le sue domande su proprietà, conflitti e riservatezza (una memoria di ruolo
condivisa è molto meno personale di quella del lead). **Valutare le due cose insieme**, non in
sequenza: decidere la memoria di ruolo prima della sincronizzazione significa deciderla senza
il suo requisito più vincolante.

---

## 5. Perché la feature avrebbe valore, in una riga

Oggi tutte le memorie confluiscono in **un solo store**, quello del lead: le osservazioni di
ruoli diversi — chi analizza, chi implementa, chi rivede — si mescolano e nessuna può essere
consolidata o potata per il proprio ruolo. Separarle è ciò che rende la memoria di un ruolo
**consultabile** invece che semplicemente accumulata.
