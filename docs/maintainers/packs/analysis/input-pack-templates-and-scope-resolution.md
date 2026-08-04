# Handoff verso cco — Il sistema di template dei pack, e la risoluzione degli scope

> ℹ️ **Provenance.** Received 2026-08-04 from an external adopter line and persisted here
> **verbatim**, in the language it was written in: it is a point-in-time *input*, not a cco decision.
> Feeds the shared resource-taxonomy analysis and Block C of the [roadmap](../../roadmap.md);
> tracked as **FI-47** (templates + parameters) and **FI-51** (scope resolution) in
> [improvements.md](../../improvements.md). Twin document:
> [input-pack-enforcement-transport.md](input-pack-enforcement-transport.md).
>
> **Da**: la linea di lavoro sul pack `core-dev-framework` (repo del corso), agosto 2026.
> **A**: una sessione di **analisi** interna a cco.
> **Cosa è**: la richiesta di tre integrazioni in cco, con il contesto e le misure che le
> hanno fatte emergere. **Non è un design**: è l'input da cui l'analisi cco può partire senza
> ri-scoprire nulla.
> **Autoconsistente di proposito**: non linka documenti del repo di provenienza. Tutto ciò che
> serve è qui.

---

## 0. Da dove nasce, in tre righe

Il pack `core-dev-framework` è stato adottato su progetti reali e ne sono emersi limiti
pratici. Analizzandoli è venuto fuori che **una parte dei limiti non è del pack: è di cco.**
Il pack può mitigarli, non risolverli, perché non possiede il punto di controllo. Questo
documento passa quella parte.

Le tre richieste, in ordine di valore:

1. **`*.template.md` nei pack**, istanziati **all'install** — con override successivo su uno
   scope di configurazione più specifico, tramite un comando dedicato.
2. **Parametri e prompt dentro il template**: ogni template dichiara i propri parametri e i
   prompt necessari a risolverli; all'install (e all'override) diventano domande interattive.
3. **Risoluzione degli scope di configurazione**: risolvere **al mount** dove possibile, e
   comunque marcare ogni file con il proprio scope, perché oggi file omonimi di scope diversi
   finiscono in contesto insieme e **indistinguibili**.

---

## 1. Il problema, misurato

### 1.1 File omonimi di scope diversi convivono in contesto, senza alcun modo di distinguerli

**Misurato in una sessione reale** (agosto 2026, progetto con un pack installato):

| File | Scope global (`~/.claude/rules/`) | Scope project (`/workspace/.claude/rules/`) |
|---|---|---|
| `documentation.md` | ✅ (dell'utente) | ✅ (del pack) |
| `git-practices.md` | ✅ (dell'utente) | ✅ (del pack) |
| `workflow.md` | ✅ (dell'utente) | ✅ (del pack) |
| `language.md` | ✅ | — |
| `testing.md` | — | ✅ |

**Tre collisioni di nome su quattro file.** Entrambe le versioni sono caricate in contesto:
le rule in markdown **non hanno una semantica di merge** — non c'è un `settings.json` che le
fonda, sono testo concatenato.

**La precedenza esiste solo come frase** nel `CLAUDE.md` managed: *«Project-level rules (in
`/workspace/.claude/rules/`) take precedence over global rules for that project»*. È una
regola rivolta al modello, non un meccanismo.

> **Perché conta più di quanto sembri.** Nella stessa sessione questo ha prodotto un errore
> reale: si stava attribuendo un comportamento osservato alle regole del pack, quando la
> regola in vigore poteva essere quella globale dell'utente — due file omonimi, entrambi in
> contesto, nessun modo di dire quale avesse governato. L'ambiguità non è teorica: ha già
> falsato un'analisi.

### 1.2 Ogni template istanziato a mano è una regola «fermati e fai un passo in più»

Questa è la ragione di progetto, non solo di comodità. Sull'adozione reale del pack è stata
misurata una separazione fra due classi di regola:

- una regola che prescrive la **forma** di un artefatto che l'agente sta già producendo →
  **seguita in modo affidabile** (7 casi su 7 misurati);
- una regola che impone di **fermarsi e fare un passo in più prima di procedere** → è la
  classe che **può** fallire, e quando fallisce fallisce male (un caso all'83 % di violazione,
  un altro con 3 violazioni in una sola sessione).

**«Dopo aver installato il pack, copia questi template e compilali» appartiene alla seconda
classe.** Un'istanziazione all'install la sposta nella prima: diventa qualcosa che il sistema
**produce**, non qualcosa che l'utente deve ricordarsi di fare. È lo stesso criterio applicato
all'installazione invece che al workflow.

### 1.3 Gli oggetti da istanziare sono già quattro, e uno non nasce dal pack

| Oggetto | Cosa parametrizza | Scope tipico | Origine |
|---|---|---|---|
| `project-profile` | quali **decisioni** richiedono un umano (autonomia) · branch strategy · politica sul remoto (push/pull) · PR richieste o no | quello del pack, con override più specifici | dalla linea pack |
| `maintenance-policy` | politica di manutenzione del progetto | project | **già nel pack**, oggi «copia e adatta a mano» |
| `settings.json` | `permissions` + hook `PreToolUse` per i ruoli read-only | project | dalla linea pack (opt-in) |
| **`language`** | lingua di **codice**, **documentazione**, **comunicazione** | global, con override project | **preesistente in cco**, oggi gestita in modo poco riusabile |

> **L'ultimo è l'indizio decisivo: `language` non nasce dal pack.** Era già una regola di cco,
> e la convergenza l'ha fatta emergere come **istanza dello stesso problema**. Quando quattro
> oggetti di origine diversa chiedono lo stesso meccanismo, il meccanismo manca al livello che
> li contiene — cioè a cco, non al pack.

Un quinto candidato già nominato: **PR required**, per gli adottanti che usano ruleset con pull
request obbligatoria.

---

## 2. Richiesta 1 — `*.template.md` nei pack, istanziati all'install

**Cosa**: un pack può contenere file `*.template.md`. `cco` li istanzia **al momento
dell'installazione del pack**, scrivendo il risultato nella configurazione dell'utente — non
dentro il pack.

**Vincoli che l'analisi non dovrebbe riscoprire:**

- **L'istanza non vive dentro il pack.** Il pack è montato read-only in sessione, e una
  re-installazione lo sovrascriverebbe: le risposte dell'utente andrebbero perse. L'istanza
  appartiene all'albero di configurazione, il template al pack.
- **Lo scope di istanziazione è quello in cui il pack è attivo.** Se il pack è installato come
  configurazione globale, l'istanza nasce global; se è installato per un progetto, nasce
  project.
- **Override su scope più specifico, con un comando dedicato post-install.** Esempio d'uso
  reale: pack installato come configurazione globale, un singolo progetto vuole una politica
  diversa → si ri-istanzia il template nello scope project di quel progetto.
- **Anche il repo-native è una casa valida** (`<repo>/.claude/`), con una particolarità: è
  caricato **on-demand**, quando l'agente legge file in quella directory. Il che coincide con
  l'ambito in cui l'override vale — ma introduce due problemi (§4.2) da tenere presenti.
- **Un template istanziato è un file dell'utente.** Un aggiornamento del pack non deve
  sovrascriverlo silenziosamente; al più segnalare che il template a monte è cambiato.

---

## 3. Richiesta 2 — parametri e prompt dichiarati dentro il template

**Cosa**: ogni template dichiara i **parametri** che contiene e, per ciascuno, **come
chiederlo**. All'install (e a ogni ri-istanziazione per override) cco esegue quei prompt in
modo interattivo e produce il file risolto.

Esempi concreti, dai quattro oggetti reali:

| Template | Parametri | Forma del prompt |
|---|---|---|
| `language.template.md` | lingua del **codice** · della **documentazione** · della **comunicazione** | scelta singola, con default |
| `project-profile.template.md` | **preset di autonomia** (`assistito` \| `delegato`) · deviazioni per singola cella · **branch strategy** (solo `main` \| `main`+`develop`) · **politica sul remoto** (l'agente pusha? fa pull?) · **PR richieste** | preset a scelta singola; le deviazioni sono opzionali e possono restare vuote |
| `maintenance-policy.template.md` | i parametri della politica di manutenzione | — |
| `settings.template.json` | i path scrivibili per i ruoli read-only | — |

**Requisiti che l'esperienza d'uso ha già chiarito:**

- **Ogni parametro ha un default**, e il default deve coincidere col **comportamento attuale**
  — così un adottante che preme invio su tutto non cambia nulla e nulla si rompe. Per il
  `project-profile` i default sono: autonomia `assistito` · branch strategy solo `main` ·
  l'agente non pusha · PR non assunte.
- **I prompt devono poter essere saltati** in esecuzione non interattiva, cadendo sui default.
- **Deve essere possibile ri-eseguire i prompt** su un'istanza esistente, per cambiare una
  risposta senza riscrivere il file a mano.
- **Alcuni parametri non sono parametri.** Nel `project-profile` tre celle non sono
  abbassabili per ragioni **strutturali, non prudenziali** (vedi §5): il template deve poterle
  marcare come non parametriche, e spiegarne la ragione accanto, così chi legge vede il perché
  e non un divieto.
- **Un template dovrebbe poter dichiarare il proprio scope di istanziazione preferito** —
  `language` è naturalmente global, `settings.json` è naturalmente project.

---

## 4. Richiesta 3 — risoluzione e marcatura degli scope di configurazione

### 4.1 Le tre direzioni, dalla più forte alla più debole

| # | Direzione | Forza | Costo / rischio |
|---|---|---|---|
| **1** | **Risolvere al mount.** cco **già** materializza il set di rule — quelle di un pack compaiono in `/workspace/.claude/rules/` senza essere nella sorgente project dell'utente. Possiede quindi già il punto di controllo: sulla **collisione di nome** potrebbe montare solo la versione più specifica | **alta** — è enforcement vero: l'agente non vedrebbe **mai** due regole in conflitto | Le rule non sono chiave-valore: due file omonimi **potrebbero** essere entrambi voluti. Va limitato alla collisione di **nome**, che è il caso rilevabile — ed è quello reale (3 su 4 nella misura) |
| **2** | **Montare tutto, ma generare un'intestazione di precedenza** nel preambolo di sessione — come cco già fa per l'elenco della knowledge | media | Resta prosa, ma **generata dal framework**: non può divergere dallo stato reale, a differenza di una frase scritta a mano in una managed rule |
| **3** | **Frontmatter `scope:`** su ogni file di config (`global` \| `project` \| `repo` \| `managed`) | bassa | È una mitigazione **dichiarativa**: rende l'ambiguità **leggibile**, non la elimina. È tutto ciò che un pack può fare da solo |

**La 3 serve comunque**, anche se si fa la 1: se due file coesistono legittimamente, chi legge
deve poter dire da dove viene ciascuno. Le tre direzioni non sono alternative esclusive.

### 4.2 Il caso repo-native, e la clausola che lo rende sicuro

Il repo-native è caricato quando l'agente legge file in quella directory. Sembra
perfettamente allineato all'intenzione — la politica c'è quando serve e non c'è quando non
serve — ma il meccanismo è più debole dell'intenzione in due modi:

1. **L'innesco è «legge un file in quella directory», non «la sessione riguarda quel repo».**
   Una decisione può cadere prima della prima lettura: a inizio sessione, in fase di piano, nel
   decidere se aprire un gate. Una politica che arriva *dopo* non ha governato quella decisione.
2. **Un progetto cco può montare più repo.** Due repo con override proprio, entrambi letti →
   due politiche pari in contesto, nessun criterio fra loro.

**La mitigazione trovata dal lato pack**, che cco può assorbire e fare meglio:

> Il file di scope **project elenca quali repo portano un override**. Il contenuto resta nel
> repo; ciò che diventa sempre-in-contesto è la sua **esistenza**.

È lo stesso pattern che cco usa già per la knowledge: l'elenco con le descrizioni iniettato a
inizio sessione, i file letti su richiesta. Se cco genera quell'elenco automaticamente
(sa quali repo sono montati e quali portano un `.claude/`), la clausola smette di essere una
regola per l'utente e diventa **una riga generata** — cioè passa dalla classe di regola che
fallisce a quella che funziona.

---

## 5. Contesto utile: cosa contiene il `project-profile`, e perché è il template più difficile

Serve all'analisi cco per dimensionare i prompt: è il template con la struttura più ricca.

**È un vettore sopra una matrice, non una manopola.** La matrice è **fase × livello di scope**:

- righe (fase): Criteri/Analisi · Design · Plan-priorità · Plan-ordine tecnico · Impl+Test ·
  Merge · Regola d'oro · review di refactoring;
- colonne (livello di scope): Task · Feature · Modulo/App;
- ogni cella dichiara **chi decide** e, quando non è l'umano, **chi lo sostituisce**:
  `U` umano · `O` oracolo deterministico · `A` autonomo.

I due preset sono **abbreviazioni di un vettore**: `assistito` = `U` ovunque non sia già
`A`/`O`; `delegato` = `O` dove la matrice lo ammette **e la precondizione è soddisfatta**. Chi
vuole granularità fine sovrascrive **la singola cella** — i preset servono perché il caso
comune non richieda di compilare tutte le celle.

**Tre celle non sono abbassabili, per ragioni strutturali:**

- **i criteri** — un verificatore agentico fa *verifica* (conformità ai criteri ricevuti), non
  *validazione* (validità di quei criteri). Se l'errore è nei criteri, ogni controllo a valle
  lo ratifica con crescente sicurezza: il segnale che manca **non è nell'input**, per
  costruzione;
- **la regola d'oro** (mai decidere al posto dell'umano una decisione mai presa) — è per
  definizione il caso «i criteri non esistono»;
- **la review di refactoring** — non perché tocca il codice, ma perché **cambia il design**,
  cioè cambia i criteri contro cui tutto il resto sarà verificato.

**Ogni cella abbassata porta con sé una precondizione.** Se non è soddisfatta, abbassare non è
delegare: è rimuovere una verifica. Il template deve poter chiedere/registrare la precondizione
insieme alla deviazione.

---

## 6. Due limiti da dichiarare, non da risolvere

**Il ciclo di fase resta manuale sotto cco.** `/clear` e l'avvio della skill successiva sono
azioni umane: l'harness non abilita un agente a farli da sé (fuori dai loop a obiettivo, che
sono un'altra cosa). Il profilo di autonomia toglie i gate di **decisione**, non il passo
**meccanico**. Va scritto: un preset chiamato `delegato` che non lo dichiara promette
un'automazione che l'harness non dà.

**Un pack è un artefatto cco, e va bene così.** La linea di lavoro sul pack ha deciso di **non**
duplicare il modello di scope di cco dentro il pack per anticipare un altro harness: il pack
dichiara il **metodo** in termini neutri e il **meccanismo** in termini cco, esplicitamente. Se
servirà altrove, si ri-adatta. La conseguenza per cco è positiva: **cco può assumere di essere
il proprietario del meccanismo** senza doverlo negoziare col formato pack.

---

## 7. Osservazioni di metodo, dalla sessione che ha prodotto questa richiesta

Non sono requisiti; sono cose che è costato scoprire.

- **Il problema §1.1 è emerso *misurando*, non ragionando.** Tre collisioni di nome erano in
  contesto mentre si discuteva se potessero esistere. Vale la pena, nell'analisi cco, fare la
  stessa misura su qualche configurazione reale prima di dimensionare la soluzione.
- **Una fonte documentale non è un esito verificato.** Nella stessa linea di lavoro, tre
  affermazioni del pack su meccanismi di enforcement si sono rivelate false perché dedotte
  dalla documentazione senza mai eseguirle. Per le direzioni di §4.1 — in particolare la 1 —
  la prova su una configurazione reale è una **precondizione**, non un follow-up.
- **Attenzione a due sensi della parola «scope»**: il **livello di scope** ricorsivo (task ·
  feature · modulo · app) e lo **scope di configurazione** (global · project · repo-native ·
  managed). Nella stessa frase sembrano la stessa cosa e non lo sono. Conviene fissare i due
  termini all'inizio dell'analisi.
- **Il caso d'uso arriva prima della feature.** `maintenance-policy` era già un template a
  copia manuale nel pack, `language` era già una regola di cco: il meccanismo mancava da prima
  che qualcuno lo chiedesse. Probabilmente ci sono altri candidati già in giro nella
  configurazione di cco — vale la pena censirli in analisi.
