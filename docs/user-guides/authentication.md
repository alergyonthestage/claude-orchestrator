# Autenticazione

> Guida alla configurazione dell'autenticazione per le sessioni Claude Code containerizzate.

---

## Panoramica

Le sessioni claude-orchestrator richiedono due tipi di autenticazione:

1. **Claude OAuth** — autenticazione verso l'API di Claude (obbligatoria)
2. **GitHub Token** — per `git push`, `gh` CLI e MCP GitHub (opzionale ma consigliato)

Entrambe sono gestite automaticamente dal framework. Nella maggior parte dei casi, basta configurare i token una volta e le sessioni successive funzionano senza intervento.

---

## Claude OAuth (metodo predefinito)

### Come funziona

Claude Code utilizza OAuth per autenticarsi con l'API di Claude. Su macOS, le credenziali sono salvate nel Keychain di sistema. Il flusso e il seguente:

1. **Al primo `cco start`**: il CLI legge le credenziali dal Keychain macOS e le copia in `global/claude-state/.credentials.json`
2. **Nelle sessioni successive**: il container usa le credenziali salvate. Se l'access token e scaduto, Claude lo rinnova automaticamente con il refresh token
3. **Se fai login sull'host** (es. dopo scadenza ~90 giorni): `cco start` rileva le nuove credenziali nel Keychain e aggiorna automaticamente il file

Le credenziali vengono salvate in due file (entrambi gitignored):

| File | Contenuto |
|------|-----------|
| `global/claude-state/claude.json` | Preferenze, stato onboarding, MCP |
| `global/claude-state/.credentials.json` | Token OAuth (access + refresh) |

Entrambi i file sono montati read-write nel container, cosi le credenziali rinnovate vengono salvate automaticamente.

### Prerequisito

Devi aver effettuato almeno un login con Claude Code sull'host:

```bash
# Sull'host (fuori dal container)
claude
# Segui il flusso OAuth nel browser
```

Dopo il primo login, `cco start` gestisce tutto automaticamente.

---

## API Key (alternativa)

Se preferisci usare una API key invece di OAuth (es. per ambienti CI, o se non hai accesso al Keychain), puoi configurarla cosi:

### Tramite secrets.env

```bash
# global/secrets.env
ANTHROPIC_API_KEY=sk-ant-api03-...
```

### Tramite flag --env

```bash
cco start my-project --env ANTHROPIC_API_KEY=sk-ant-api03-...
```

### Tramite project.yml

```yaml
auth:
  method: api_key
```

Quando `auth.method` e `api_key`, il CLI non tenta il seeding OAuth dal Keychain. La chiave deve essere disponibile come variabile d'ambiente (via `secrets.env` o `--env`).

---

## GitHub Token

Il `GITHUB_TOKEN` abilita tre funzionalita nel container:

- **`git push`** — via HTTPS tramite il credential helper di `gh`
- **`gh` CLI** — creazione PR, gestione issue, ecc.
- **MCP GitHub** — il server MCP per GitHub legge il token dall'ambiente

### Configurazione

**1. Crea un fine-grained PAT su GitHub:**

Vai su GitHub > Settings > Developer Settings > Fine-grained personal access tokens.

Permessi consigliati:
- Repository access: seleziona i repo specifici
- Permissions: Contents (read/write), Pull requests (read/write)

**2. Salva il token in secrets.env:**

```bash
echo "GITHUB_TOKEN=github_pat_..." >> ~/claude-orchestrator/global/secrets.env
```

**3. Avvia la sessione:**

```bash
cco start my-project
# [entrypoint] GitHub: authenticated gh CLI via GITHUB_TOKEN
# [entrypoint] GitHub: configured git credential helper
```

L'entrypoint del container configura automaticamente `gh auth login` e `gh auth setup-git` quando trova il `GITHUB_TOKEN` nell'ambiente.

### Token per progetto

Se vuoi usare token diversi per progetti diversi (es. PAT con scope diversi), crea un `secrets.env` per progetto:

```bash
# projects/my-project/secrets.env
GITHUB_TOKEN=github_pat_project_specific...
```

I secret per-progetto sovrascrivono quelli globali per le chiavi con lo stesso nome.

---

## Gestione dei secret

I secret sono gestiti tramite file `.env` a due livelli, entrambi gitignored:

### Livello globale

```bash
# global/secrets.env — disponibile in tutti i progetti
GITHUB_TOKEN=ghp_...
LINEAR_API_KEY=lin_api_...
SLACK_BOT_TOKEN=xoxb_...
```

### Livello progetto

```bash
# projects/my-project/secrets.env — solo per questo progetto
GITHUB_TOKEN=github_pat_project_specific...   # sovrascrive il globale
STRIPE_KEY=sk_test_...                        # solo per questo progetto
```

### Flag --env

Per variabili temporanee o di sessione:

```bash
cco start my-project --env DEBUG=true --env API_URL=http://localhost:8080
```

### Come vengono iniettati

I secret sono passati come flag `-e` a `docker compose run` al momento dell'avvio. Non vengono mai scritti in `docker-compose.yml` o altri file generati.

Ordine di precedenza (l'ultimo vince):
1. `global/secrets.env`
2. `projects/<name>/secrets.env`
3. `--env` da CLI

### Formato

```bash
# Formato: KEY=VALUE (uno per riga)
# Le righe vuote e i commenti (#) sono ignorati
GITHUB_TOKEN=ghp_...
# Questa e una variabile con spazi nel valore
MY_VAR=hello world
```

Righe malformate vengono ignorate con un warning:
```
Warning: secrets.env:3: skipping malformed line (expected KEY=VALUE)
```

---

## Prima autenticazione (senza Keychain)

Se non hai credenziali nel Keychain macOS (es. prima installazione, oppure su Linux), Claude Code richiede l'autenticazione direttamente nel container:

1. Avvia la sessione: `cco start my-project`
2. Claude Code mostra un URL per il login OAuth
3. Copia l'URL dal terminale (vedi la sezione copy-paste nella [guida Agent Teams](agent-teams.md))
4. Apri l'URL nel browser e completa l'autenticazione
5. Le credenziali vengono salvate in `global/claude-state/.credentials.json`
6. Le sessioni successive usano le credenziali salvate automaticamente

---

## Troubleshooting

### "Not logged in" dopo `cco start`

1. **Verifica il Keychain** (macOS):
   ```bash
   security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w \
     | python3 -c "import sys,json; print('OK' if json.load(sys.stdin).get('claudeAiOauth',{}).get('accessToken') else 'NO TOKEN')"
   ```

2. **Verifica il file credentials**:
   ```bash
   jq '.claudeAiOauth | keys' global/claude-state/.credentials.json
   ```

3. **Verifica i permessi**:
   ```bash
   ls -la global/claude-state/.credentials.json
   # Deve essere 600 (-rw-------)
   ```

4. **Forza il re-seeding**:
   ```bash
   rm global/claude-state/.credentials.json
   cco start my-project
   ```

### Schermata di onboarding ("theme: dark")

Succede quando `claude.json` ha `hasCompletedOnboarding: false`, tipicamente dopo un logout+login sull'host. Il CLI forza automaticamente questo valore a `true` prima di avviare il container. Se il problema persiste:

```bash
jq '.hasCompletedOnboarding = true' global/claude-state/claude.json > /tmp/fix.json \
  && mv /tmp/fix.json global/claude-state/claude.json
```

### Token scaduto (dopo ~90 giorni)

1. Fai login sull'host: esegui `claude` e autentica via browser
2. Avvia la sessione: `cco start my-project` — il CLI rileva le nuove credenziali nel Keychain e aggiorna automaticamente

### API key non funziona

- Verifica che `auth.method: api_key` sia impostato in `project.yml`
- Verifica che `ANTHROPIC_API_KEY` sia presente in `secrets.env` o passato con `--env`
- Controlla che la chiave inizi con `sk-ant-api`
