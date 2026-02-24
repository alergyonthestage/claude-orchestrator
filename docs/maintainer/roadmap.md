# Roadmap

> Tracks planned features, improvements, and known issues for future iterations.
> Last updated: 2026-02-24 (post architecture review).

---

## Completed

### Automated Testing ✓

Pure bash test suite (`bin/test`) covering 126 test cases across 9 test files. Tests run without a Docker container using `--dry-run` and file-system assertions. Zero external dependencies.

**Coverage**: `cco init`, `cco project create`, `cco start --dry-run` (docker-compose generation), knowledge pack generation, workspace.yml generation, YAML parser edge cases, `cco stop`, `cco project list`.

### Knowledge Packs — Full Schema (knowledge + skills + agents + rules) ✓

Packs now support the full expanded schema: `knowledge:` section for document mounts, plus `skills:`, `agents:`, and `rules:` for project-level tooling. Skills/agents/rules are copied at `cco start` time (not mounted, to avoid Docker volume collisions with multi-pack setups).

Knowledge files are injected automatically via `session-context.sh` hook (no `@.claude/packs.md` in CLAUDE.md required).

### /init Skill ✓

Custom project initialization skill at `global/.claude/skills/init/SKILL.md`. Shadows the built-in `/init` command. Reads `workspace.yml`, explores repositories, generates a structured CLAUDE.md, and writes descriptions back to `workspace.yml`.

---

## Current Sprint — CLI Robustness & Review Fixes

Bug fix e miglioramenti di robustezza emersi dall'architecture review del 24-02-2026.

### Fix test packs.md header mismatch (bug)

Test `test_packs_md_has_auto_generated_header` fallisce: asserisce `"Read them proactively"` ma il codice genera `"Read the relevant files BEFORE starting..."`. Aggiornare il test.

**Source**: architecture review §7, test run confermato.

### Aggiungere `alwaysThinkingEnabled: true` a settings.json

La doc (`context.md` §4.1) lo elenca come raccomandato, ma `defaults/global/.claude/settings.json` non lo include. Discrepanza doc/implementazione.

**Source**: architecture review §2 gap 1.

### Semplificare SessionStart hook matcher

Le due entry `"startup"` e `"clear"` puntano allo stesso script. Unificare in un singolo catch-all senza matcher, come raccomandato dalla doc ufficiale Claude Code.

**Source**: architecture review §2 gap 2.

### Lock per sessioni concorrenti

`cco start project-a` quando `project-a` è già running produce un errore Docker generico. Aggiungere un check esplicito con `docker ps` e un messaggio chiaro.

**Source**: architecture review §3 problema 5.

### Validazione formato `secrets.env`

`load_global_secrets()` non valida il formato `KEY=VALUE`. Righe malformate vengono passate come `-e garbage` a Docker, causando errori confusi. Aggiungere validazione con skip + warning.

**Source**: architecture review §3 problema 4.

### Pinning versione Claude Code nel Dockerfile

`@latest` nel Dockerfile rende le build non riproducibili. Aggiungere `ARG CLAUDE_CODE_VERSION=latest` per permettere il pinning opzionale via `cco build --build-arg CLAUDE_CODE_VERSION=1.0.x`.

**Source**: architecture review §4 miglioramento 1.

---

## Near-term

### Pack cleanup — manifest file copiati

Skills, agents e rules copiati dai pack in `projects/<n>/.claude/` non vengono rimossi se il pack cambia. Aggiungere un manifest (`.pack-manifest`) e pulire i file stale prima di ogni copia.

**Source**: architecture review §7 miglioramento 1.

### Warning conflitti nome tra pack

Se `pack-a` e `pack-b` definiscono entrambi `agents/reviewer.md`, il secondo sovrascrive il primo silenziosamente. Emettere un warning in `cco start`.

**Source**: architecture review §7 miglioramento 2.

### ADR-9 — Knowledge Packs

Documentare le trade-off del design dei pack in un ADR dedicato in `architecture.md`: scelta di copiare vs montare, staleness dei file copiati, injection via hook, composizione.

**Source**: architecture review §1 miglioramento.

### Pack inheritance / composition

Allow packs to extend other packs:
```yaml
extends: base-client
files:
  - additional-doc.md
```

### `cco pack create <name>` command

Scaffold a new pack definition interactively, similar to `cco project create`.

---

## Medium-term

### `cco update` — merge intelligente config

Metodo per aggiornare `projects/` e `global/` quando l'orchestratore aggiunge skill, template o modifica strutture, senza perdere customizzazioni utente (merge intelligente defaults → user config).

**Source**: TODO.

### Docker socket toggle per progetto

Opzione in `project.yml` per abilitare/disabilitare il mount del Docker socket. Mitigazione del rischio root-access-via-socket per progetti che non necessitano di sibling containers.

**Source**: TODO.

### Fix tmux copy-paste

Risolvere problemi di selezione e copia/incolla in tmux per token di autenticazione e prompt/risposte. La selezione non funziona correttamente con la configurazione attuale.

**Source**: TODO.

### Browser Automation MCP in Docker

Enable Claude to navigate and analyze web pages from within a container session using a headless browser MCP server.

**Approach**:
- Install Chromium in the `Dockerfile` (`apt-get install -y chromium`)
- Add a Playwright or Puppeteer MCP server to `global/mcp.json`
- Browser runs headless inside the container — no display or VNC required
- Claude can navigate URLs, take screenshots, extract page content

**Why useful**: analyze live UIs, verify deployed endpoints, scrape structured data from web pages — all without leaving the coding session.

**Complexity**: Medium. Requires Dockerfile change (image size increase ~400 MB) and MCP server package. Make opt-in via `cco build --with-browser` flag and a separate image tag.

### `cco project edit <name>` command

Open project.yml in `$EDITOR` and regenerate docker-compose.yml after save.

### Session resume

`cco resume <project>` — reattach to a running tmux session inside a running container.

---

## Long-term / Exploratory

### Remote sessions

Mount repos from remote hosts via SSHFS or similar, enabling orchestrator sessions on remote development machines.

### Multi-project sessions

A single Claude session with repos from multiple projects, for cross-project refactoring or analysis tasks.

### Web UI

Optional lightweight web dashboard for listing projects, starting/stopping sessions, viewing logs, and editing project configurations.

---

## Declined / Won't Do

### PreToolUse safety hook

Proposta dalla review (§2 gap 3): hook per bloccare `rm -rf /`, `git push --force`, accesso fuori `/workspace`.

**Decisione**: Non implementare. Docker è il sandbox (ADR-1). Il container opera con mount point limitati. Eventuali comandi specifici da bloccare possono essere aggiunti puntualmente in futuro se emerge un bisogno concreto.
