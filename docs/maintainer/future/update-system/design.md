# Update System Design

> Status: design completato, implementazione completata.

## Problema

Oggi non esiste nessun meccanismo di update. Le uniche opzioni sono:

| Scenario | Meccanismo | Problema |
|----------|-----------|----------|
| Nuovi defaults globali | `cco init --force` | **Distruttivo** — cancella `global/` e ricopia tutto |
| Nuova struttura template progetto | Nessuno | L'utente deve applicare manualmente |
| Migrazione legacy | `_migrate_to_managed()` | One-shot con marker file, non estensibile |
| Pack aggiornati | `cco start` (manifest) | Funziona ma solo per risorse pack→project |

### Cosa distrugge `init --force`

`rm -rf "$GLOBAL_DIR"` cancella:
- `global/packs/` — pack utente, irrecuperabili
- `global/claude-state/` — session transcripts, credentials, memory
- `global/.claude/mcp.json` — configurazione MCP custom
- Tutte le customizzazioni utente (agents, rules, skills modificati)

### Requisito principale

Aggiornare progetti e scope global **senza cancellare e rifare**, preservando:
- History e chat sessions (`claude-state/`)
- CLAUDE.md utente (global e progetto)
- `mcp.json`, `secrets.env`, `project.yml`
- Pack utente (`global/packs/`)

## Classificazione dei file per ownership

### Global (`defaults/global/` → `global/`)

| File | Owner | Update sicuro? | Strategia |
|------|-------|----------------|-----------|
| `.claude/settings.json` | Framework | Sì | Sovrascrivere sempre |
| `.claude/rules/language.md` | Framework | Sì (con attenzione) | Rigenerare da scelte salvate |
| `.claude/rules/*.md` (altri) | Framework | Cauto | Checksum: sovrascrivere se invariato |
| `.claude/agents/*.md` | Framework | Cauto | Checksum: sovrascrivere se invariato |
| `.claude/skills/*/SKILL.md` | Framework | Cauto | Checksum: sovrascrivere se invariato |
| `.claude/CLAUDE.md` | Framework | Cauto | Checksum: sovrascrivere se invariato |
| `.claude/mcp.json` | **Utente** | Mai | Non toccare |
| `setup.sh` | **Utente** | Mai | Non toccare |

### Project (`defaults/_template/` → `projects/<name>/`)

| File | Owner | Update sicuro? | Strategia |
|------|-------|----------------|-----------|
| `.claude/settings.json` | Framework | Sì | Sovrascrivere |
| `.gitkeep` files | Framework | Sì | Ignorare |
| `project.yml` | **Utente** | Mai | Non toccare |
| `.claude/CLAUDE.md` | **Utente** | Mai | Non toccare |
| `.claude/rules/language.md` | **Utente** | Mai | Non toccare |
| `setup.sh` | **Utente** | Cauto | Copiare solo se mancante |
| `mcp-packages.txt` | **Utente** | Cauto | Copiare solo se mancante |
| `secrets.env` | **Utente** | Cauto | Copiare solo se mancante |

## Architettura: Ibrido checksum + migrazioni

### Perché ibrido

| Criterio | Solo Checksum | Solo Migrazioni | **Ibrido** |
|----------|--------------|-----------------|------------|
| Update contenuto file | Automatico | Una funzione per file | Automatico |
| Rileva edit utente | Sì | Deve reimplementare | Sì |
| Cambi strutturali | No | Sì | Sì |
| Rename/rimozione file | No | Sì | Sì |
| Schema changes | No | Sì | Sì |
| Manutenzione | Minima | Alta | Media |

### Moduli e file

Tre nuovi file seguendo i pattern esistenti del progetto:

| File | Ruolo | Pattern di riferimento |
|------|-------|----------------------|
| `lib/update.sh` | Engine: checksum, manifest I/O, diff, migration runner | Come `packs.sh` (logica riutilizzabile separata dal comando) |
| `lib/cmd-update.sh` | Comando: option parsing, orchestrazione, interazione utente | Come `cmd-init.sh`, `cmd-project.sh` |
| `migrations/{global,project}/*.sh` | Script di migrazione individuali | Nuovo pattern, documentato sotto |

Il migration runner vive in `update.sh` (non file separato) perché è strettamente accoppiato all'engine (entrambi leggono/scrivono `.cco-meta`) e non è riusato altrove.

### Relazione init / update

Sono comandi separati con semantiche diverse:

| Aspetto | `cco init` | `cco update` |
|---------|-----------|-------------|
| Scopo | Setup iniziale / factory reset | Merge incrementale |
| `--force` | `rm -rf global/` → ricopia tutto da defaults | Sovrascrive solo file framework-managed, preserva file utente |
| Distruttività | Alta — cancella mcp.json, claude-state/, packs | Bassa — non tocca mai file user-owned |
| Crea `.cco-meta` | Sì, al primo init | Sì, se mancante (retrocompat) |
| Esegue migrazioni | Sì (schema_version = latest, nessuna migrazione pending) | Sì (tutte quelle pending) |

**Modifiche a `cmd-init.sh`:**
- Dopo il `cp -r` dei defaults, chiama `_generate_cco_meta()` per creare `.cco-meta` con hash di tutti i file copiati e `schema_version` = latest
- Le scelte lingua vengono salvate nella sezione `languages:` di `.cco-meta`
- `_migrate_to_managed()` rimossa dalla chiamata diretta — sostituita dal sistema migrazioni

**Hint su `cco start`:**
- `cmd-start.sh` controlla se `.cco-meta` esiste nel global scope
- Se `schema_version < latest`, stampa: `ℹ Updates available. Run 'cco update' to apply.`
- Non esegue update automaticamente

### Algoritmo di update (dettaglio)

Auto-discovery dei file managed. Scansiona `defaults/` escludendo i file user-owned:

```bash
GLOBAL_USER_FILES=("mcp.json" "setup.sh")        # Mai toccare
GLOBAL_SPECIAL_FILES=("rules/language.md")         # Rigenerare da scelte salvate
# Tutto il resto da defaults → framework-managed
```

Per ogni file managed (non user-owned, non special):

```
installed_hash = hash(installed_file)   # o "" se non esiste
manifest_hash  = hash from .cco-meta   # o "" se nuovo file
default_hash   = hash(default_file)     # dalla directory defaults/

if installed_hash == "" and default_hash != "":
    → NEW: copia da defaults
elif manifest_hash == default_hash:
    → NO_UPDATE: default non è cambiato dall'ultima versione
elif installed_hash == manifest_hash:
    → SAFE_UPDATE: utente non ha modificato, framework ha aggiornato → sovrascrivere
elif installed_hash != manifest_hash and default_hash != manifest_hash:
    → CONFLICT: sia utente che framework hanno modificato → risolvi
elif installed_hash != manifest_hash and default_hash == manifest_hash:
    → USER_MODIFIED: utente ha modificato, framework non ha aggiornato → skip
```

Per `language.md`: viene rigenerato dal template con le scelte lingua salvate in `.cco-meta`, poi trattato come file managed separato (hash aggiornato nel manifest).

Per file in manifest ma non più in defaults: segnalati come "removed from defaults", non cancellati (l'utente potrebbe averli personalizzati).

### Strategia dry-run

Approccio a due fasi (come `cmd-start.sh --dry-run`):

```
Phase 1: COLLECT (always runs, read-only)
  - Scan files, compute hashes, detect changes
  - Count pending migrations

Phase 2: APPLY (skipped if --dry-run)
  - Execute file updates
  - Run migrations
  - Update .cco-meta
```

Per `--dry-run`:
- File changes: mostra lista di file da aggiornare/aggiungere/rimuovere con status
- Migrazioni: mostra "N migrations pending" con descrizioni
- Termina con `ℹ Dry run complete. No changes made.`

## Il file `.cco-meta`

Uno per ogni scope updatable. Formato YAML-like (parsato con AWK).

### `global/.claude/.cco-meta`

```yaml
# Auto-generated by cco — do not edit
schema_version: 1
created_at: 2026-01-15T10:00:00Z
updated_at: 2026-02-27T14:30:00Z

languages:
  communication: Italian
  documentation: Italian
  code_comments: English

manifest:
  CLAUDE.md: <sha256>
  settings.json: <sha256>
  rules/diagrams.md: <sha256>
  rules/git-practices.md: <sha256>
  rules/language.md: <sha256-post-substitution>
  rules/workflow.md: <sha256>
  agents/analyst.md: <sha256>
  agents/reviewer.md: <sha256>
  skills/analyze/SKILL.md: <sha256>
  skills/commit/SKILL.md: <sha256>
  skills/design/SKILL.md: <sha256>
  skills/review/SKILL.md: <sha256>
```

### Parsing e scrittura

**Lettura**: AWK-based, funzioni dedicate per le tre sezioni (header, languages, manifest).

**Scrittura**: Generazione completa da scratch con `printf` (come docker-compose.yml in cmd-start.sh). No editing in-place — riscrittura totale ad ogni update.

```bash
_generate_cco_meta() {
    local meta_file="$1" schema="$2" created="$3"
    local comm_lang="$4" docs_lang="$5" code_lang="$6"
    # Manifest entries from stdin as "path\thash" lines

    {
        printf '# Auto-generated by cco — do not edit\n'
        printf 'schema_version: %d\n' "$schema"
        printf 'created_at: %s\n' "$created"
        printf 'updated_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '\nlanguages:\n'
        printf '  communication: %s\n' "$comm_lang"
        printf '  documentation: %s\n' "$docs_lang"
        printf '  code_comments: %s\n' "$code_lang"
        printf '\nmanifest:\n'
        while IFS=$'\t' read -r path hash; do
            [[ -z "$path" ]] && continue
            printf '  %s: %s\n' "$path" "$hash"
        done
    } > "$meta_file"
}
```

## Migrazioni

Funzioni bash in `migrations/`, eseguite in ordine per `schema_version`.

```
migrations/
├── global/
│   └── 001_managed_scope.sh
└── project/
    └── 001_memory_to_claude_state.sh
```

### Convenzioni

**Naming**: `NNN_descriptive_name.sh` (3 cifre zero-padded)

**Struttura file**:
```bash
#!/usr/bin/env bash
# Migration: <descrizione breve>

MIGRATION_ID=1
MIGRATION_DESC="Managed scope migration"

# $1 = target directory (global_dir/.claude o project_dir)
# Must be idempotent (safe to run multiple times)
# Return 0 on success, non-zero on failure
migrate() {
    local target_dir="$1"
    # ... migration logic ...
}
```

**Regole:**
- Ogni file definisce `MIGRATION_ID` (intero), `MIGRATION_DESC` (stringa), `migrate()` (funzione)
- `migrate()` riceve la directory target come primo argomento
- Deve essere **idempotente** — safe to run multiple times
- Usa `info()`, `warn()`, `ok()` per output (disponibili perché `colors.sh` è già caricato)
- Return 0 = success, non-zero = failure
- Nessun `down()/rollback` — non serve per CLI tool
- Nessun accesso a variabili globali (`GLOBAL_DIR`, etc.) diretto — riceve tutto via argomento (eccezione: `DEFAULTS_DIR` per accesso ai file template)

**Schema version**: Calcolata dinamicamente dal `MIGRATION_ID` più alto trovato nella directory `migrations/{scope}/`. Non serve mantenerla come costante.

### Migration runner

`_run_migrations()` in `lib/update.sh`:
1. Legge `schema_version` da `.cco-meta`
2. Scansiona `migrations/{scope}/*.sh` ordinandoli per nome (ordine naturale via NNN prefix)
3. Per ogni file con `MIGRATION_ID > schema_version`: source il file, chiama `migrate()`
4. Dopo ogni migrazione riuscita, aggiorna `schema_version` in `.cco-meta`
5. Se una migrazione fallisce: stop, report errore, non aggiorna `schema_version`

### Porting migrazioni legacy

| Legacy | Nuovo | Scope | ID |
|--------|-------|-------|----|
| `_migrate_to_managed()` in `secrets.sh` | `migrations/global/001_managed_scope.sh` | global | 1 |
| `migrate_memory_to_claude_state()` in `secrets.sh` | `migrations/project/001_memory_to_claude_state.sh` | project | 1 |

Le funzioni originali sono marcate come deprecated in `secrets.sh` ma mantenute per retrocompatibilità con installazioni che non hanno ancora eseguito `cco update`.

## Comando `cco update`

```
cco update                    # Update global defaults
cco update --project <name>   # Un progetto specifico
cco update --all              # Global + tutti i progetti
cco update --dry-run          # Mostra cosa cambierebbe
cco update --force            # Sovrascrive anche file modificati
cco update --keep             # Mantiene sempre versione utente
cco update --backup           # Backup .bak + sovrascrive (no prompt)
```

Default: `--interactive` (mostra diff, utente sceglie per ogni conflitto).

### Opzioni conflitto interattivo

- **Keep (K)**: mantiene file utente, aggiorna hash nel manifest
- **Update (U)**: sovrascrive con nuovo default
- **Backup (B)**: backup `.bak` + sovrascrive
- **Skip (S)**: non tocca nulla, non aggiorna hash (ri-segnalato al prossimo update)

### Retrocompatibilità (senza `.cco-meta`)

Primo run: `schema_version: 0`, esegue tutte le migrazioni, genera manifest con hash attuali (senza sovrascrivere), informa utente. Dal secondo update il sistema funziona normalmente.

### Gestione `language.md`

Le scelte lingua sono salvate in `.cco-meta` → `languages:`. All'update, il template viene rigenerato con le scelte salvate. Se `.cco-meta` mancante, i valori vengono estratti dal file corrente tramite pattern matching.

## Impatto su comandi esistenti

### `cmd-init.sh`
- Dopo `cp -r` dei defaults, genera `.cco-meta` con hash di tutti i file copiati
- Salva le scelte lingua nella sezione `languages:`
- `schema_version` = latest (nessuna migrazione pending su fresh install)
- Su installazioni pre-esistenti (senza `.cco-meta`), esegue le migrazioni pending

### `cmd-start.sh`
- Controlla se `.cco-meta` esiste nel global scope
- Se `schema_version < latest`, stampa hint: `ℹ Updates available. Run 'cco update' to apply.`
- Non esegue update automaticamente
- Mantiene la chiamata diretta a `migrate_memory_to_claude_state()` per retrocompatibilità

### `secrets.sh`
- `_migrate_to_managed()` e `migrate_memory_to_claude_state()` marcate come deprecated
- Mantenute per retrocompatibilità
- Le funzioni `load_secrets_file()` e `load_global_secrets()` invariate

## Test plan

### Nuovi helper in `tests/helpers.sh`
- `create_cco_meta()` — crea un `.cco-meta` con contenuto specificato
- `modify_managed_file()` — modifica un file managed per simulare edit utente
- `assert_output_not_contains()` — asserts CCO_OUTPUT doesn't contain pattern

### Scenari di test (`tests/test_update.sh`)

1. `test_update_first_run_no_meta` — genera `.cco-meta`, esegue migrazioni
2. `test_update_no_changes` — tutto aggiornato, nulla da fare
3. `test_update_framework_changed` — default modificato, file utente invariato → aggiorna
4. `test_update_user_modified` — file utente modificato → preserva
5. `test_update_force_overwrites` — `--force` sovrascrive anche file modificati
6. `test_update_keep_preserves` — `--keep` mantiene versione utente
7. `test_update_backup_creates_bak` — `--backup` crea .bak + sovrascrive
8. `test_update_new_file_added` — nuovo file in defaults → copiato
9. `test_update_dry_run` — nessun cambiamento, output informativo
10. `test_update_migrations_run_in_order` — migrazioni eseguite in ordine
11. `test_update_migration_failure_stops` — fallimento blocca esecuzione
12. `test_update_init_creates_cco_meta` — init genera .cco-meta corretto
13. `test_update_language_preserved` — language.md rigenerato con scelte salvate
14. `test_update_help` — --help mostra usage text
