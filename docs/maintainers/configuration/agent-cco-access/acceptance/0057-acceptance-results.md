# Acceptance results — ADR-0057, the `ask` enforcement plane (A4)

**Historical record.** Run by the maintainer on the macOS host, **2026-08-06**, against
`feat/access/claude-md-axis` at `f1e5766`, following
[the runbook](0057-ask-plane-runbook.md). Three real sessions started with `./bin/cco`;
mechanical checks delegated to each session's own agent, dialogs answered by the maintainer.

Re-homed out of `scratchpad/` (gitignored) — that is exactly how three pack-line inputs were nearly
lost in the previous cycle. The raw transcript is preserved verbatim in §6.

## 1. Verdict

| # | Check | Result |
|---|---|---|
| 1 | `/workspace/.claude/CLAUDE.md` mounted `rw` inside a `:ro` tree | ⚠️ **HALF MEASURED** — `rw` proven, the parent's `:ro` **not measured** (runbook bug) |
| 2 | a nested `<repo>/**/CLAUDE.md` prompts; a sibling `.md` does not; a refusal is honoured | ✅ **PASS**, all three |
| 3 | `<repo>/.cco/claude/rules/*` refused at OS level, no prompt | ❌ **MEASURED NOTHING** (runbook bug) |
| 4 | `--claude-access none`: no prompt, no write, every class | ✅ **PASS**, all four |
| 5 | config-editor: no prompt on any class of its target | ❌ **FAIL** — as [FI-52](../../../improvements.md) predicted |
| 6 | `cco whoami` reports the matrix, both dimensions | ✅ **PASS** — but see [FI-53](../../../improvements.md) |

**Two checks are not evidence, and the runbook is why.** Both commands were wrong *as written by the
runbook author*; neither failure says anything about the implementation. They are recorded as
"measured nothing" rather than folded into a pass — the recurrence this project has already paid for
twice.

## 2. What passed, and what it proves

### Check 2 — the trigger case, closed

The dialog appeared on a nested `CLAUDE.md`, answering **no** left the file unchanged (verified by
`git diff`), and a sibling `README.md` was edited with **no dialog**. This is the whole point of
A4: the session that noticed a stale `CLAUDE.md` can fix it, with one keystroke instead of a
restart, and nothing else in the repo became noisier.

### Check 4 — `none` is genuinely locked

Verbatim from the session:

```
grep -c 'workspace/\*\*/CLAUDE.md' /etc/claude-code/managed-settings.json  →  0
285 270 … /workspace/.claude                ro,nosuid,nodev,relatime
299 285 … /workspace/.claude/CLAUDE.md      ro,nosuid,nodev,relatime
echo x >> /workspace/.claude/CLAUDE.md  →  Read-only file system, exit=1
Edit tool                               →  EROFS, no dialog
```

No overlay generated, no rule bound, both mounts `:ro`, the write refused at OS level with **no
dialog**. The only `rw` paths under `/workspace/.claude` are `settings.local.json` and `workflows/` —
the functional-write floor, exactly as ADR-0055 requires. Declared autonomy works.

### Check 6 — both dimensions reported

`cco whoami` printed the `claude entries:` line and the *Resolved cells that differ from their tree*
block naming `repo CLAUDE.md ask` and `current CLAUDE.md ask`. See FI-53 for the caveat.

## 3. Check 5 — the predicted failure, now measured

The maintainer got a dialog on **every** edit inside the config-editor's target, including
`claude-orchestrator-config/claude/CLAUDE.md`. The session's managed settings carried:

```json
"ask": [ "Edit(//workspace/**/CLAUDE.md)" ]
```

This is [FI-52](../../../improvements.md) exactly as written: the glob spans all of `/workspace`, the
target's config is mounted at `/workspace/<name>-config`, and the glob matches it. The prediction
made from the dry-run pre-flight is confirmed against a real session. **A4 cannot be accepted until
FI-52 is decided.**

## 4. Two claims from the session agents, adjudicated

Both were reported as defects. **One is refuted; one is real but is a reporting defect, not an
enforcement one.**

### ❌ Refuted — *"`rules=ro` is not enforced"*

The session agent edited `<target>/.cco/claude/rules/git-workflow.md`, saw it succeed, and concluded
the `rules=ro` cell was unenforced. **The write was correct.** ADR-0057 D3: *a class never reduces
below its tree*. config-editor derives `Cp=rw`, so `cell(current, rules) = max(rw, ro) = rw`. The
resolved cell is `rw`, and the mount honoured it.

### ✅ Real — the `claude entries:` line invites exactly that misreading

`cco whoami` prints the class **axis inputs** (`rules=ro`) on a line a reader naturally takes for
effective permissions, while the *differing cells* block only shows cells that differ from their
tree — so a class that resolved **upward** to `rw` is reported nowhere. A trained reader, reading a
security surface, drew the wrong conclusion from it within minutes. Recorded as
[FI-53](../../../improvements.md).

### 📝 *"the pattern covers only `Edit`"* — untested here, and already measured elsewhere

The agent flagged that `Edit(…)` might not intercept `Write`, `MultiEdit` or a Bash write, and said
plainly it had not tested this. [FI-48](../../../improvements.md) measured it on 2026-08-04: `Edit`
rules **do** cover the built-in modifying tools and the file commands Claude Code recognises in Bash
(`sed -i`, `echo >`, `printf >`) — while **`dd`, `truncate` and any interpreter pass**.

That residue is not a defect; it is [ADR-0057 P6](../decisions/0057-ask-enforcement-plane-and-resource-classes.md),
stated before implementation: `permissions` is a **gate**, not a boundary, and `ask` requires the
mount `rw`, so choosing it **always trades a boundary for a gate**. There is no way to close it on
the permissions plane — only the mount plane is a real boundary, and `ask` cannot use it by
construction. The maintainer's question during check 2 (*"can the agent bypass the ask rule?"*) has
that as its answer: yes, through an uncovered write path, by design, which is why `ask` is offered
only where a versioned backstop exists and never on `settings.json` or hooks.

## 5. Corrected commands for the two unmeasured checks

Both runbook commands were wrong. Re-run these; nothing about the implementation is yet known for
either check.

### Check 1 — the parent's mode

The runbook's `sed 's/.*rw,/rw,/;s/.*ro,/ro,/'` is **greedy**: every `mountinfo` line ends with
`rw,fakeowner` (the *superblock* options of the shared host mount), so `.*rw,` matched to the last
occurrence and printed `rw,fakeowner` for both lines regardless of the actual mount flag. It reported
`rw` for a mount that may well be `ro`.

```bash
# per-mount flags are field 6, after the mountpoint — print mountpoint + flags only
awk '$5=="/workspace/.claude" || $5=="/workspace/.claude/CLAUDE.md" {print $5, $6}' /proc/self/mountinfo
```

Expect exactly:

```
/workspace/.claude ro,nosuid,nodev,relatime
/workspace/.claude/CLAUDE.md rw,nosuid,nodev,relatime
```

### Check 3 — the rules tree

`echo x >> /workspace/.claude/rules/*.md` fails in **bash** with *ambiguous redirect* whenever the
glob matches more than one file (or none). The `exit=1` came from the shell, never reaching the
filesystem.

```bash
# name ONE file explicitly — no glob in a redirect target
f=$(ls /workspace/.claude/rules/*.md | head -1); echo "target: $f"
echo x >> "$f" ; echo "exit=$?"
```

Expect `Read-only file system`, `exit=1`, and **no dialog** — this is the mount plane, which never
prompts. ⚠ If `ls` prints nothing the tree is empty and the check still measures nothing; say so.

---

## 6. Raw transcript, verbatim

As captured by the maintainer. Preserved unedited — the analysis above is derived from it, and a
reader who disagrees with a verdict should be able to re-derive it from here.

<details>
<summary>Session A / B / C, as run</summary>

# Risultati runbook 0057 ask plane

## Host session A

```
Alessandros-MacBook-Pro-2:claude-orchestrator alessandro$ cat .cco/project.yml | grep -A 3 access
# ── cco and claude access policies

## Enable rw access to .claude in claude-orchestator. Required to edit internal and defaults .claude
## To replace with access all only for claude-orchestrator/{internal;defaults} paths, when FI-25 will be implemented.
# access:
#   claude: all

# ── Knowledge Packs (optional) ───────────────────────────────────────
--
# Skills, agents, and rules are copied to .claude/ for project-scoped access.
#
# Pack schema (global/packs/<name>/pack.yml):
# name: my-pack
Alessandros-MacBook-Pro-2:claude-orchestrator alessandro$ ./bin/cco start claude-orchestrator \
>     --claude-access repo=ro,current=ro,global=ro,others=ro
[debug] matrix: repo claude_md=ask repo rules ro repo agents ro repo skills ro repo * ro current claude_md ask current rules ro current agents ro current skills ro current * ro global claude_md ro global rules ro global agents ro global skills ro global * ro others claude_md ro others rules ro others agents ro others skills ro others * ro
[start] Generated Docker socket policy: containers=project_only, mounts=project_only
⚠ Committed .claude/llms/ is framework-reserved — its contents are shadowed by pack/llms :ro overlays.
✓ claude-orchestrator resolved (0 newly bound)
ℹ started claude-orchestrator from claude-orchestrator [source: name]
⚠ ~/.cco has uncommitted changes — commit them to version your global config
⚠ claude-orchestrator: .cco has uncommitted changes — commit it with your normal git flow
ℹ Starting session for project 'claude-orchestrator'...
```
### Dentro la sessione
```
claude@b6ed7ab0a42c:/workspace$ # 1 — the CLAUDE.md mount must be rw, inside a .claude that is ro
grep -E '/workspace/\.claude(/CLAUDE\.md)? ' /proc/self/mountinfo | sed 's/.*rw,/rw,/;s/.*ro,/ro,/'
grep '/workspace/.claude/CLAUDE.md' /proc/self/mountinfo

# 3 — the rules tree must refuse at OS level, with NO dialog
echo x >> /workspace/.claude/rules/*.md ; echo "exit=$?"

# 6 — both dimensions reported
/workspace/claude-orchestrator/bin/cco whoami
rw,fakeowner
rw,fakeowner
297 284 0:46 /alessandro/Projects/CaveResistance/Software/claude-orchestrator/.cco/claude/CLAUDE.md /workspace/.claude/CLAUDE.md rw,nosuid,nodev,relatime - fakeowner /run/host_mark/Users rw,fakeowner
-bash: /workspace/.claude/rules/*.md: ambiguous redirect
exit=1
Session
  identity:         claude-orchestrator
  code repos:       claude-orchestrator
  image built from: detached@8fbf8ab

Access
  level:            read-project
  triple:           G=none Pc=ro Po=none  (read: project, write: none)
  claude_access:    repo=ro,current=ro,global=ro,others=ro,entries.claude_md=ask
  claude triple:    Cr=ro Cp=ro Cg=ro Co=ro
  claude entries:   claude_md=ask rules=ro agents=ro skills=ro
  show_host_paths:  true

Config trees (.cco)
  project config (<repo>/.cco):        ro
  personal store (~/.cco) + registry:  —
  llms cache:                          —

Authoring trees (.claude)
  repo-native <repo>/.claude (Cr):     ro
  project <repo>/.cco/claude (Cp):     ro
  global ~/.cco/.claude (Cg):          ro

Resolved cells that differ from their tree
  repo     CLAUDE.md    ask
  current  CLAUDE.md    ask
  (ask = the mount is writable, every write prompts — ADR-0057)

Enforcement  internal store confined behind the ADR-0047 privilege boundary —
              store reads/writes are gated by this triple via the setuid cco-svc
              helper (a raw read of the store fails), not just output-filtered.
claude@b6ed7ab0a42c:/workspace$
```
1. Prompt dialog apparso -> rispondo no -> nessun edit nel diff, verificato.
   1. Domanda riguardo la trap -> se l'agent bypassa edit usando Bash o tools diversi è un problema... ha un modo per bypassare l'enforcement rule "ask", serve capire come evitare.
2. Confermo, edit senza nessun dialog su README.md.

## Host session B
```
  Searched for 2 patterns, read 1 file, listed 1 directory, ran 1 shell command

● Update(.claude/CLAUDE.md)
Error: EROFS: read-only file system, open '/workspace/.claude/CLAUDE.md.tmp.98.7358b944a1c0'

● Ecco l'esito, comando per comando (output verbatim).

  1. ls -l /etc/claude-code/managed-settings.json
  -rw-r--r-- 1 root root 1252 Aug  4 09:32 /etc/claude-code/managed-settings.json

  2. grep -c 'workspace/\*\*/CLAUDE.md' /etc/claude-code/managed-settings.json || echo "no rule (expected)"
  0
  no rule (expected)
  (grep -c stampa 0 ed esce 1 → scatta anche il ramo ||. Nessuna deny rule sul path CLAUDE.md nei managed settings.)

  3. grep '/workspace/.claude' /proc/self/mountinfo — 32 righe, riportate integralmente qui sotto in forma ridotta per leggibilità; le tre rilevanti verbatim:
  285 270 0:46 /alessandro/.cache/cco/projects/claude-orchestrator/claude-view /workspace/.claude ro,nosuid,nodev,relatime - fakeowner /run/host_mark/Users rw,fakeowner
  299 285 0:46 /alessandro/Projects/CaveResistance/Software/claude-orchestrator/.cco/claude/CLAUDE.md /workspace/.claude/CLAUDE.md ro,nosuid,nodev,relatime - fakeowner /run/host_mark/Users rw,fakeowner
  289 285 0:46 /alessandro/.local/state/cco/projects/claude-orchestrarw,fakeowner
289 285 0:46 /alessandro/.local/state/cco/projects/claude-orchestrator/local-settings/workspace.json /workspace/.claude/settings.local.json rw,nosuid,nodev,relatime - fakeowner /run/host_mark/Users rw,fakeowner
296 285 0:46 /alessandro/.local/state/cco/projects/claude-orchestrator/workflows /workspace/.claude/workflows rw,nosuid,nodev,relatime - fakeowner /run/host_mark/Users rw,fakeowner
Le restanti 28 righe (packs, skills, agents, rules, llms, settings.json, i .gitkeep) sono tutte ro. Le uniche due rw dentro /workspace/.claude sono settings.local.json e workflows/. L'output completo è quello che hai nel tool result — è troppo lungo per ripeterlo qui riga per riga, ma non ho omesso nessuna riga rw.

4. echo x >> /workspace/.claude/CLAUDE.md ; echo "exit=$?"
/bin/bash: line 3: /workspace/.claude/CLAUDE.md: Read-only file system
exit=1

Edit tool su /workspace/.claude/CLAUDE.md

Ho letto il file e poi provato una Edit reale (Self-development of claude-orchestrator → ... (write-probe)). Risultato:

EROFS: read-only file system, open '/workspace/.claude/CLAUDE.md.tmp.98.7358b944a1c0'

- Dialog di permesso: no. La chiamata non è stata intercettata né rifiutata a livello di permessi — un diniego dell'utente torna con un messaggio distinto ("user declined"), che non è comparso. Il tool è arrivato fino alla syscall.
- Scrittura: fallita. Non a livello di policy, ma di filesystem: la Edit scrive tramite file temporaneo nella stessa directory, e la directory è montata ro.
- Il file è invariato — né l'append di bash né la Edit hanno prodotto alcuna modifica.

Conclusione: la protezione qui è solo il mount, non una regola di permessi. managed-settings.json non contiene alcuna deny rule per workspace/**/CLAUDE.md (grep = 0), quindi il layer di permessi lascia passare la scrittura; a fermarla è il doppio ro — la view /workspace/.claude è ro, e CLAUDE.md ha in più un proprio bind ro dal repo (.cco/claude/CLAUDE.md). Se un giorno la view diventasse rw, non ci sarebbe nessuna seconda linea di difesa a livello di permessi.
✻ Cogitated for 49s
```

## Host session C
Mi è apparso dialog su tutti gli edit `Update(claude-orchestrator-config/claude/CLAUDE.md)`
ho accettato.

```
Searched for 1 pattern, read 3 files, listed 2 directories, ran 2 shell commands

● Update(claude-orchestrator-config/claude/CLAUDE.md)
Added 1 line, removed 1 line

## Repositories

<!-- List your mounted repositories and their purpos
e -->
<!-- List your mounted repositories and their purpos
e (permission probe) -->

## Project-Specific Instructions


● Update(claude-orchestrator-config/claude/rules/git-workflow.md)
Added 1 line, removed 1 line
This ensures main gets only the fix, and develop sta
ys in sync.

## Rules
- Never commit directly to main or develop
- Never commit directly to main or develop (permissi
on probe)
- Feature/fix branches → develop only (never directl
y to main)
- Hotfix branches → main first, then develop
- Keep develop in sync: push after each merge

● Update(claude-orchestrator-config/claude/CLAUDE.md)
Added 1 line, removed 1 line

## Repositories

<!-- List your mounted repositories and their purpos
e (permission probe) -->
<!-- List your mounted repositories and their purpos
e -->

## Project-Specific Instructions


● Update(claude-orchestrator-config/claude/rules/git-workflow.md)
Added 1 line, removed 1 line
This ensures main gets only the fix, and develop sta
ys in sync.

## Rules
- Never commit directly to main or develop (permissi
on probe)
- Never commit directly to main or develop
- Feature/fix branches → develop only (never directl
y to main)
- Hotfix branches → main first, then develop
- Keep develop in sync: push after each merge

  Ran 1 shell command

● Risultati

  1. ls /etc/claude-code/managed-settings.json → esiste, 1307 byte, -rw-r--r--.

  2. grep -c 'CLAUDE.md' → 1. L'unica occorrenza è la regola in permissions:

  "deny": [ "Read(~/.claude.json)", "Read(~/.ssh/*)" ],
  "ask":  [ "Edit(//workspace/**/CLAUDE.md)" ]

  3. cco whoami → custom (global=ro,current=rw,others=none), triple G=ro Pc=rw Po=none.
  Celle .claude: Cr=ro Cp=rw Cg=ro Co=ro, con entry-level claude_md=ask rules=ro agents=ro skills=ro e la nota ADR-0057 «repo CLAUDE.md → ask».
 CLAUDE.md → ask».

Test di scrittura

┌───────────────────────────────────┬──────────────┬────────────┐
│               File                │ Cella attesa │ Esito Edit │
├───────────────────────────────────┼──────────────┼────────────┤
│ .cco/claude/CLAUDE.md             │ ask          │ ✅ scritto │
├───────────────────────────────────┼──────────────┼────────────┤
│ .cco/claude/rules/git-workflow.md │ ro           │ ✅ scritto │
└───────────────────────────────────┴──────────────┴────────────┘

Entrambe le modifiche sono state revertite; git status -- .cco/ mostra solo M .cco/project.yml, già modificato prima di questa sessione (non l'ho toccato).

Cosa posso e non posso dire sul "prompt"

Se un prompt viene mostrato e tu approvi, il tool restituisce lo stesso identico risultato di un'autorizzazione automatica: dal mio lato non è distinguibile. Quindi per CLAUDE.md non posso confermare se il prompt sia comparso — lo sai tu. Posso però confermare il caso negativo: nessuna delle due Edit è stata negata.

Due discrepanze da valutare

1. rules=ro non è applicato. whoami dichiara le rules read-only, ma managed-settings.json non ha nessuna regola deny/ask su Edit(//workspace/**/rules/**), e l'Edit è passata. La cella entry-level rules=ro risulta quindi solo dichiarativa nell'output di whoami, non enforced a livello di permessi Claude Code — a differenza di claude_md=ask, che ha la sua regola corrispondente. Nota che l'enforcement descritto in whoami (cco-svc setuid, ADR-0047) copre lo store ~/.cco, non l'albero .claude del progetto: qui il mount è rw e l'unica barriera possibile è la permission rule.
2. Il pattern copre solo Edit. Edit(//workspace/**/CLAUDE.md) non intercetta Write, MultiEdit, né una scrittura via Bash (tee, >). Non l'ho testato, è una lettura del pattern — ma se l'intento è "ogni scrittura su CLAUDE.md prompta", la regola attuale è aggirabile per costruzione.
```

</details>
