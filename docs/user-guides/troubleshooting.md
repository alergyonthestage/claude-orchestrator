# Troubleshooting e FAQ

> Soluzioni ai problemi comuni, organizzate per categoria.

---

## Docker

### Docker daemon non in esecuzione

```
Error: Docker daemon is not running. Start Docker Desktop.
```

**Soluzione**: Avvia Docker Desktop (macOS/Windows) oppure il servizio Docker (`sudo systemctl start docker` su Linux). Verifica con:

```bash
docker info
```

### Build dell'immagine fallisce

**Sintomi**: `cco build` termina con errore.

**Soluzioni**:
- Verifica la connessione internet (il build scarica pacchetti npm e apt)
- Prova un rebuild completo senza cache:
  ```bash
  cco build --no-cache
  ```
- Se l'errore riguarda un pacchetto npm specifico, potrebbe essere un problema temporaneo del registry. Riprova dopo qualche minuto

### Conflitto di porte

```
Error: Port 3000 is already in use. Stop the conflicting service or use --port to remap.
```

**Soluzioni**:
- Identifica il processo che occupa la porta:
  ```bash
  lsof -i :3000
  ```
- Ferma il servizio in conflitto, oppure rimappa la porta:
  ```bash
  cco start my-project --port 3001:3000
  ```
- In alternativa, modifica `docker.ports` in `project.yml`

### Permessi Docker socket

**Sintomi**: comandi `docker` nel container falliscono con "permission denied".

**Soluzione**: l'entrypoint gestisce automaticamente il GID del socket Docker. Se il problema persiste:
- Verifica che il socket sia montato: controlla `docker.mount_socket` in `project.yml` (default: `true`)
- Su Linux, verifica che il tuo utente appartenga al gruppo `docker`:
  ```bash
  groups | grep docker
  ```

### Immagine Docker non trovata

```
Error: Docker image 'claude-orchestrator:latest' not found. Run 'cco build' first.
```

**Soluzione**: esegui `cco build` per costruire l'immagine. Se usi un'immagine custom (`docker.image` in `project.yml`), verifica che sia stata costruita.

---

## Autenticazione

### "Not logged in"

**Causa**: le credenziali OAuth non sono disponibili nel container.

**Soluzioni**:
1. Verifica di aver fatto login sull'host: esegui `claude` fuori dal container
2. Forza il re-seeding delle credenziali:
   ```bash
   rm global/claude-state/.credentials.json
   cco start my-project
   ```
3. Verifica il Keychain macOS:
   ```bash
   security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w | head -c 50
   ```

### Token scaduto

**Sintomi**: errori di autenticazione dopo un periodo di inattivita (~90 giorni).

**Soluzione**:
1. Login sull'host: esegui `claude` e autentica via browser
2. `cco start my-project` — il CLI rileva le nuove credenziali automaticamente

### Schermata di onboarding

**Sintomi**: appare la schermata "theme: dark" invece della sessione.

**Causa**: `hasCompletedOnboarding` e impostato a `false` in `claude.json`, tipicamente dopo un logout+login sull'host.

**Soluzione**: il CLI corregge automaticamente questo valore. Se il problema persiste:
```bash
jq '.hasCompletedOnboarding = true' global/claude-state/claude.json > /tmp/fix.json \
  && mv /tmp/fix.json global/claude-state/claude.json
```

### API key non riconosciuta

**Soluzioni**:
- Verifica `auth.method: api_key` in `project.yml`
- Verifica che `ANTHROPIC_API_KEY` sia in `global/secrets.env` o passato con `--env`
- Controlla il formato della chiave (deve iniziare con `sk-ant-api`)

### GitHub token non funziona

**Sintomi**: `git push` fallisce, `gh` non e autenticato.

**Soluzioni**:
- Verifica che `GITHUB_TOKEN` sia in `global/secrets.env` o `projects/<name>/secrets.env`
- Verifica i permessi del PAT: Contents (read/write) e Pull requests (read/write)
- Controlla i log dell'entrypoint per messaggi come:
  ```
  [entrypoint] GitHub: authenticated gh CLI via GITHUB_TOKEN
  ```

---

## tmux e copy-paste

### La clipboard non funziona

**Sintomi**: la selezione del testo funziona visivamente ma `Cmd+V` non incolla nulla.

**Causa**: il protocollo OSC 52 non e abilitato nel terminale.

**Soluzioni per terminale**:

| Terminale | Soluzione |
|-----------|----------|
| iTerm2 | Settings > General > Selection > abilita "Applications in terminal may access clipboard" |
| Terminal.app | OSC 52 non supportato: usa `fn` + drag per la selezione nativa |
| GNOME Terminal | OSC 52 non supportato: usa `Shift` + drag per la selezione nativa |
| Alacritty, WezTerm, Kitty, Ghostty | Funziona out of the box |

### Metodi alternativi di copia

Se la copia automatica non funziona, usa la selezione nativa bypassando tmux:

| Terminale | Tasto modificatore |
|-----------|-------------------|
| iTerm2 | `Option` (tenere premuto durante il drag) |
| Terminal.app | `fn` |
| Alacritty, WezTerm, Kitty | `Shift` |
| GNOME Terminal, XFCE | `Shift` |

**Limitazione**: la selezione nativa attraversa i bordi dei pane tmux, includendo bordi e barra di stato.

### Cmd+C non copia

`Cmd+C` invia SIGINT (interrupt), non copia. Per copiare:
- **Metodo consigliato**: seleziona col mouse e rilascia — la copia e automatica (se OSC 52 e abilitato)
- **Manuale**: `Ctrl+B` poi `[` per entrare in copy-mode, seleziona con `v`, copia con `y`
- **Bypass nativo**: tieni premuto il tasto modificatore del tuo terminale durante il drag

### Sessione tmux nidificata

Se usi gia tmux sull'host, il container crea una sessione nidificata. Il prefisso del container e `Ctrl+B` (default). Per raggiungere il tmux interno, premi `Ctrl+B` due volte, oppure rimappa il prefisso di uno dei due.

**Alternativa**: usa la modalita iTerm2 (`--teammate-mode auto`) per evitare il nesting.

---

## Knowledge Packs

### File di knowledge non nel contesto

**Sintomi**: Claude non sembra conoscere il contenuto dei file di knowledge.

**Soluzioni**:
1. Verifica che il pack sia elencato in `packs:` nel `project.yml`
2. Controlla l'output di `cco start` per il messaggio "Generated .claude/packs.md"
3. Verifica che `pack.yml` abbia la sezione `knowledge.files:` compilata
4. Controlla il contenuto di `projects/<name>/.claude/packs.md` — deve elencare i file

### Conflitti tra pack

**Sintomi**: warning durante `cco start` su nomi duplicati.

**Causa**: due pack definiscono lo stesso agent, rule o skill.

**Soluzione**: l'ultimo pack nella lista `packs:` di `project.yml` vince. Rinomina il file in conflitto in uno dei pack, oppure riordina la lista per dare precedenza al pack corretto.

### Errori di validazione

```bash
# Verifica la struttura del pack
cco pack validate my-pack
```

Problemi comuni:
- `pack.yml` mancante o con sintassi errata
- File dichiarati in `knowledge.files` che non esistono nella directory source
- Nomi di skill/agent/rule che non corrispondono ai file nella directory

---

## MCP

### Server MCP non caricati

**Sintomi**: i tool MCP non sono disponibili nella sessione.

**Soluzioni**:
1. Verifica che `mcp.json` sia valido JSON:
   ```bash
   jq . projects/my-project/mcp.json
   ```
2. Verifica che le variabili d'ambiente referenziate (`${VAR}`) siano disponibili nel container tramite `secrets.env` o `--env`
3. Se una variabile `${VAR}` non e risolta, Claude Code ignora l'intero file `mcp.json`
4. Per server globali, verifica `global/.claude/mcp.json`
5. Controlla i log dell'entrypoint per errori di merge

### Variabili d'ambiente non risolte

**Causa**: `${GITHUB_TOKEN}` in `mcp.json` non viene espanso perche la variabile non e nell'ambiente del container.

**Soluzione**: aggiungi la variabile a `global/secrets.env`:
```bash
echo "GITHUB_TOKEN=ghp_..." >> global/secrets.env
```

Oppure passala con `--env`:
```bash
cco start my-project --env GITHUB_TOKEN=ghp_...
```

### Pacchetti MCP lenti al primo avvio

**Causa**: `npx -y` scarica il pacchetto ad ogni avvio se non pre-installato.

**Soluzione**: pre-installa i pacchetti nell'immagine Docker:
```bash
# Via mcp-packages.txt (persistente)
echo "@modelcontextprotocol/server-github" >> global/mcp-packages.txt
cco build

# Via flag CLI (una tantum)
cco build --mcp-packages "@modelcontextprotocol/server-github"
```

Per pacchetti specifici di un progetto, usa `projects/<name>/mcp-packages.txt`.

---

## Generale

### Sessione gia in esecuzione

```
Error: Project 'my-project' already has a running session (container cc-my-project). Run 'cco stop my-project' first.
```

**Soluzione**:
```bash
# Ferma la sessione esistente
cco stop my-project

# Oppure ferma tutte le sessioni
cco stop
```

### Repository non visibile nel container

**Sintomi**: la directory `/workspace/<repo>/` non esiste nel container.

**Soluzioni**:
1. Verifica che il percorso in `project.yml` esista sull'host:
   ```bash
   ls -la ~/projects/my-repo
   ```
2. Verifica la configurazione in `project.yml`:
   ```yaml
   repos:
     - path: ~/projects/my-repo    # deve esistere sull'host
       name: my-repo               # nome in /workspace/
   ```
3. Usa `cco start my-project --dry-run` per vedere i volumi generati nel `docker-compose.yml`

### Progetto non trovato

```
Error: Project 'foo' not found. Run 'cco project list' to see available projects.
```

**Soluzioni**:
- Verifica il nome con `cco project list`
- Verifica che `projects/<name>/project.yml` esista
- Se il progetto non esiste ancora, crealo:
  ```bash
  cco project create my-project --repo ~/projects/my-repo
  ```

### Contesto troppo grande

**Sintomi**: Claude segnala che il contesto e vicino al limite, o le risposte diventano imprecise.

**Soluzioni**:
- Riduci il numero di file nei knowledge pack (usa descrizioni precise per limitare i file letti)
- Usa `/compact` periodicamente durante sessioni lunghe
- Verifica che i file di knowledge non siano eccessivamente grandi (preferisci file sotto le 500 righe)
- Controlla la barra di stato per la percentuale di contesto utilizzata

### secrets.env con formato errato

```
Warning: secrets.env:3: skipping malformed line (expected KEY=VALUE)
```

**Causa**: una riga non rispetta il formato `KEY=VALUE`.

**Soluzione**: verifica il file. Le chiavi devono iniziare con una lettera o underscore, seguite da `=` senza spazi attorno:
```bash
# Corretto
GITHUB_TOKEN=ghp_...
MY_VAR=hello world

# Errato
3BAD_KEY=value       # non inizia con lettera/underscore
export KEY=value     # 'export' non supportato
KEY = value          # spazi attorno a =
```
