# Personalizzazione dell'ambiente

> Guida ai meccanismi di estensione per personalizzare l'ambiente di sviluppo nel container.

---

## Panoramica

claude-orchestrator offre quattro meccanismi complementari per personalizzare l'ambiente del container senza modificare il framework stesso:

| Meccanismo | Scope | Quando | Cosa |
|-----------|-------|--------|------|
| `global/setup.sh` | Tutti i progetti | `cco build` (build time) | Pacchetti di sistema, dipendenze pesanti |
| `projects/<name>/setup.sh` | Singolo progetto | `cco start` (runtime) | Setup leggero, dipendenze per progetto |
| `projects/<name>/mcp-packages.txt` | Singolo progetto | `cco start` (runtime) | Pacchetti npm per server MCP |
| `docker.image` in project.yml | Singolo progetto | `cco start` | Immagine Docker completamente custom |

---

## Script di setup globale

**File**: `global/setup.sh`

Lo script di setup globale viene eseguito durante `cco build` come step nel Dockerfile. Gira come root e puo installare pacchetti di sistema, configurare repository apt, aggiungere tool globali.

### Quando usarlo

- Installazione di pacchetti apt necessari in tutti i progetti
- Tool di sistema (Terraform, kubectl, Chromium, ecc.)
- Dipendenze pesanti che richiedono tempo di download

### Esempio

```bash
#!/bin/bash
# global/setup.sh

# Install Chromium for Playwright MCP
apt-get update && apt-get install -y chromium && rm -rf /var/lib/apt/lists/*

# Install Terraform
curl -fsSL https://releases.hashicorp.com/terraform/1.7.0/terraform_1.7.0_linux_amd64.zip \
    -o /tmp/terraform.zip && unzip /tmp/terraform.zip -d /usr/local/bin/ && rm /tmp/terraform.zip
```

### Note

- Lo script e incluso nel Docker image: le modifiche richiedono un `cco build` per avere effetto
- Gira come root — accesso completo al sistema
- Il file viene creato vuoto (con commenti) da `cco init`
- Le dipendenze installate qui sono disponibili in tutti i progetti

---

## Script di setup per progetto

**File**: `projects/<name>/setup.sh`

Viene eseguito dall'entrypoint ad ogni avvio del container (`cco start`), prima del lancio di Claude. Gira come root.

### Quando usarlo

- Dipendenze leggere specifiche di un progetto
- Setup che non giustifica un rebuild dell'immagine
- Installazione di pacchetti Python, Ruby gem o altri tool non-apt

### Esempio

```bash
#!/bin/bash
# projects/ml-project/setup.sh

# Install Python ML dependencies
pip3 install --quiet pandas numpy scikit-learn 2>/dev/null

# Create project-specific symlinks
ln -sf /workspace/shared-libs/bin/lint /usr/local/bin/project-lint
```

### Note

- Viene eseguito **ad ogni `cco start`** — deve essere idempotente
- Gira come root — puo installare pacchetti, ma aumenta il tempo di avvio
- Per dipendenze pesanti, preferisci `global/setup.sh` o un'immagine custom
- Se il file non esiste, viene semplicemente ignorato

---

## Pacchetti MCP per progetto

**File**: `projects/<name>/mcp-packages.txt`

Pacchetti npm installati globalmente all'avvio del container. Utile per server MCP specifici di un progetto.

### Quando usarlo

- Server MCP necessari solo per un progetto specifico
- Quando non vuoi includere il pacchetto nell'immagine base

### Esempio

```
# projects/devops-toolkit/mcp-packages.txt
@anthropic/mcp-server-playwright
@modelcontextprotocol/server-postgres
```

### Note

- Un pacchetto per riga; righe vuote e commenti (`#`) ignorati
- Installati ad ogni `cco start` (rallenta l'avvio se molti pacchetti)
- Per pacchetti usati in tutti i progetti, preferisci `global/mcp-packages.txt` (installati al build time con `cco build`)

### Confronto con mcp-packages.txt globale

| File | Installato quando | Disponibile in |
|------|-------------------|----------------|
| `global/mcp-packages.txt` | `cco build` (build time) | Tutti i progetti |
| `projects/<name>/mcp-packages.txt` | `cco start` (runtime) | Solo quel progetto |

---

## Immagine Docker custom

**Campo**: `docker.image` in `project.yml`

Permette a un progetto di usare un'immagine Docker completamente personalizzata al posto di `claude-orchestrator:latest`.

### Quando usarla

- Dipendenze molto pesanti che rallenterebbero troppo `setup.sh`
- Toolchain completamente diversa (es. progetto con stack Go + Kubernetes)
- Massimo controllo sull'ambiente, zero penalita all'avvio

### Configurazione

```yaml
# projects/devops-toolkit/project.yml
name: devops-toolkit

docker:
  image: claude-orchestrator-devops:latest
```

### Creare l'immagine custom

Parti dall'immagine base di claude-orchestrator per mantenere compatibilita con entrypoint, hook e configurazione:

```dockerfile
# projects/devops-toolkit/Dockerfile
FROM claude-orchestrator:latest

# Heavy project-specific dependencies
RUN apt-get update && apt-get install -y \
    chromium ansible terraform kubectl \
    && rm -rf /var/lib/apt/lists/*

# Additional MCP servers
RUN npm install -g @anthropic/mcp-server-playwright
```

Build:

```bash
docker build -t claude-orchestrator-devops:latest \
  -f projects/devops-toolkit/Dockerfile .
```

### Note

- Usa sempre `FROM claude-orchestrator:latest` come base per mantenere la compatibilita
- Dopo un `cco build` dell'immagine base, ricostruisci anche le immagini custom
- L'immagine custom riceve gli stessi mount e variabili d'ambiente dell'immagine base

---

## Matrice decisionale

Quale meccanismo usare in base alla necessita:

| Necessita | Meccanismo consigliato | Motivazione |
|-----------|----------------------|-------------|
| Pacchetto apt per tutti i progetti | `global/setup.sh` | Un solo rebuild, avvio rapido |
| Pacchetto apt per un progetto (leggero) | `projects/<name>/setup.sh` | Nessun rebuild necessario |
| Pacchetto apt per un progetto (pesante) | Immagine custom | Zero penalita all'avvio |
| Server MCP npm per tutti i progetti | `global/mcp-packages.txt` | Pre-installato al build |
| Server MCP npm per un progetto | `projects/<name>/mcp-packages.txt` | Runtime, nessun rebuild |
| Dipendenze pip/gem per un progetto | `projects/<name>/setup.sh` | Installazione runtime |
| Toolchain completamente diversa | `docker.image` in project.yml | Controllo totale |

### Regola generale

- **Build time** (setup globale, immagine custom): per dipendenze pesanti o usate spesso — un costo iniziale, avvio immediato
- **Runtime** (setup per progetto, mcp-packages per progetto): per dipendenze leggere o sperimentali — nessun rebuild, ma avvio piu lento

---

## Layout dei file

```
global/
  setup.sh                 # Script globale (build time)
  mcp-packages.txt         # Pacchetti MCP globali (build time)

projects/<name>/
  setup.sh                 # Script per progetto (runtime)
  mcp-packages.txt         # Pacchetti MCP per progetto (runtime)
  project.yml              # docker.image per immagine custom
```

Tutti questi file sono opzionali. Se non presenti, vengono semplicemente ignorati.
