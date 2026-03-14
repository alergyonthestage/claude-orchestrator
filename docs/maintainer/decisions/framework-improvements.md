# Framework Improvements — Analysis & Decisions

> Raised: 2026-03-14. Collected from field usage observations.
> These items will be revisited individually at design/analysis time before implementation.

---

## FI-1: Framework Context for the Coding Agent

**Question**: Should the coding agent inside the container know that it's running within claude-orchestrator? For example via managed CLAUDE.md or rules?

**Context**: Currently the managed `CLAUDE.md` (`defaults/managed/CLAUDE.md`) tells the agent *how to behave* (workspace layout, memory policy, agent teams) but does not explain what claude-orchestrator is or how the framework works.

**Analysis**:
- The agent does NOT need to know the framework internals (how `cco` works, config hierarchy, migrations) — it should use the workspace, not manage the framework.
- The agent SHOULD know key operational details: ports are mapped to host, `docker compose` creates sibling containers on `cc-<project>` network, `/etc/claude-code/` files are managed and non-modifiable, `/init-workspace` exists for project initialization, `cco` is a host-side CLI not available inside the container.
- The current managed CLAUDE.md already covers most of this. Missing: explicit mention that `cco` is host-only, Docker network naming convention.

**Decision**: Small additions to the existing managed CLAUDE.md. No separate knowledge pack or documentation needed — minimal operational context is sufficient.

**Effort**: Low (text additions to `defaults/managed/CLAUDE.md`).

---

## FI-2: `/init-workspace` on Empty Projects

**Question**: When `/init-workspace` runs on an empty, unconfigured project, the agent doesn't know what to include. Should it ask the user clarification questions (project description, architecture, goals) before generating the CLAUDE.md? Or should init-workspace be suggested only after a first analysis phase?

**Context**: The current skill (`defaults/managed/.claude/skills/init-workspace/SKILL.md`) proceeds silently with automatic discovery. It is explicitly instructed to "proceed without confirmation" if the file is empty/missing. On an empty workspace (no repos, no manifests), it generates a nearly empty CLAUDE.md with placeholder sections.

**Analysis**:
- **Option A — Ask questions first**: Before writing, the skill asks "Describe what you want to build" and uses the answer to populate Overview and Architecture. More useful for greenfield projects.
- **Option B — Suggest init after first analysis**: The user first describes their goals (via `/analyze` or conversation), then invokes `/init-workspace` which already has context from the conversation. More aligned with the phased workflow.

**Decision**: Option B is more pragmatic and coherent with the structured workflow. The skill should add a check: if no repos are found and no `workspace.yml` descriptions exist, ask the user for a brief project description before generating.

**Effort**: Low (conditional logic addition to SKILL.md).

---

## FI-3: Default Ports and Chrome DevTools Port Management

**Question**: The default `project.yml` template includes `ports: ["3000:3000", "8080:8080"]`. Is this correct? Should the default be empty? How should the Chrome DevTools port be managed — automatically by the framework or manually by the user? What about port conflicts?

**Context**:
- Template: `templates/project/base/project.yml` has ports 3000 and 8080 by default.
- Browser config: `enabled: false`, `cdp_port: 9222`, `mode: host`.
- `_resolve_browser_port()` in `lib/cmd-chrome.sh` already handles port conflict auto-resolution.

**Analysis**:
- **Default ports**: 3000/8080 are reasonable web dev defaults but violate "secure by default" — an empty `ports: []` with a comment explaining how to add them is cleaner. Unused ports don't cause conflicts but add noise.
- **Chrome DevTools port**: Already managed automatically by the framework. Chrome runs on the host (`mode: host`), not in the container. The CDP port (9222) is used directly on the host and does not appear in `docker.ports`. Port conflict resolution via `_resolve_browser_port()` handles edge cases.
- **User vs DevTools conflicts**: No architectural conflict — `docker.ports` maps container ports to host, while CDP is host-to-host. The only conflict would be if a user maps port 9222 inside the container AND uses Chrome DevTools — an edge case manageable via documentation.
- **Security**: All defaults are safe. Ports map to localhost only (Docker default). Browser is `enabled: false` by default. Docker socket proxy filters API calls.

**Decision**: Change template default to `ports: []` with a comment listing common examples. Chrome DevTools port management is already correct — no changes needed.

**Effort**: Low (template edit + one-line migration if needed for existing projects — actually no migration needed since ports are user-owned and additive).

---

## FI-4: Per-Project LLM Model Configuration

**Question**: Could it be useful to set a default LLM model globally and a different default per project, per agent, or per workflow phase?

**Context**:
- Currently no mechanism exists to configure the model from the framework. The model is decided by Claude Code at launch time.
- Subagents already support per-agent model via YAML frontmatter (`model: claude-3-5-haiku` in analyst, `model: claude-3-5-sonnet` in reviewer).
- `claude --model <name>` is the CLI flag.

**Analysis**:
- **Per project** (new): Add `model:` field in `project.yml`, passed to `claude` at launch via `--model` in the entrypoint. Most concrete use case: simple projects on haiku, complex projects on opus.
- **Per agent**: Already supported natively via agent frontmatter. No changes needed.
- **Per phase**: Not practical. Phases are conceptual (user workflow), not framework-managed entities. The user can change model manually during a session.
- **Global default**: Equivalent to setting `CLAUDE_MODEL` env var or a default in settings. Lower priority — the per-project level is more useful.

**Decision**: Implement per-project `model:` in `project.yml` only. Global default is a simple env var. Per-agent is already covered. Per-phase is not worth the complexity.

**Effort**: Medium (project.yml schema, entrypoint integration, documentation).

---

## FI-5: Human Workflow Guide and Review Best Practices

**Question**: Should the documentation or tutorial include guidance on which tasks remain human responsibilities, the recommended development flow, common problems and workarounds?

**Original observations from field usage**:
> - Verificare sempre in dettaglio tutti gli artifact intermedi tra fasi. Il riferimento sono i documenti di analisi e design creati.
> - Dopo ogni ciclo di implementazione far fare una o più review automatiche (da uno o più agents) a Claude per:
>   - Review allineamento dell'implementazione al design e caccia di bug critici
>   - Review della docs: nessuna docs stale, tutti i riferimenti e concetti sono aggiornati al nuovo design
>   - Review dei test. Verifica che i test hanno coverage sufficiente e sono completi
> - Da eseguire sempre prima di considerare una feature chiusa e completa. Spesso la seconda review trova errori di implementazione o fix necessari che durante l'implementazione sono sfuggiti al modello.
> - Ovviamente l'umano deve sempre controllare e dirigere le scelte principali e la qualità del codice, di sicurezza, di conformità e scelte architetturali.
> - Possono essere spesso utili anche delle review e analisi di refactor possibili o ottimizzazioni dell'architettura.
> - Template project può consigliare all'utente di seguire queste fasi e direttive.
> - **Human in the loop + review automatiche migliorano drasticamente la qualità dei risultati ed evitano l'accumularsi di bug ed errori.** Ogni ciclo di sviluppo deve essere concluso con testing automatizzato + test e verifica umana.
>
> Git flow recommendations:
> - Definire un flusso git preciso e convenzioni di nomenclatura branch e direzione dei commit.
> - Includere nelle rules commit automatici dall'agent.
> - I punti di review non sono i commit, ma i merge da branch feature o fix al branch develop o main. Questo sembra essere il compromesso migliore.
> - Configurare ruleset git per PR obbligatorie per forzare la review umana e impedire merge automatici del modello — non solo tramite rules ma meccanicamente (GitHub branch protection).

**Context**: `docs/user-guides/structured-agentic-development.md` already covers team discipline, two-layer review (agent + human), and workflow phases with approval gates. Default rules in `defaults/global/.claude/rules/` cover git practices and workflow phases. The `/review` skill and `reviewer` agent exist.

**Analysis**: The conceptual framework exists, but a **practical operational guide** is missing. What's needed:
1. **`docs/user-guides/development-workflow.md`** — step-by-step guide with:
   - Checklist per phase (what to do, what to verify)
   - Recommended review pattern: implementation → design alignment review → docs review → test review
   - Common problems and workarounds (e.g., "model forgets constraints during long implementation")
   - Precise git flow: branch naming, when to commit, when to merge, mandatory PR rules
2. **Template integration** — the base project template could reference these best practices in the generated CLAUDE.md or suggest them post-`cco project create`.
3. **GitHub branch protection** — document how to configure rulesets to mechanically enforce human review on merges to develop/main, not just via soft rules.

**Decision**: Create the practical guide. The core message: human-in-the-loop + automated multi-pass reviews drastically improve output quality and prevent bug accumulation.

**Effort**: Medium (documentation writing, template updates).

---

## FI-6: Read-Only Mounts for User-Owned `.claude/` Config

**Question**: Currently `.claude/` rules, agents, and other user-defined files can be modified by the agent inside the container. Should these be mounted read-only to prevent unintended modifications?

**Original observation**: The agent was observed modifying user-defined rules and config files during a session. The only project that should legitimately modify these is the tutorial project (which explicitly mounts `user-config` in rw).

**Context — current mount modes**:
| Resource | Mount mode | Reason |
|---|---|---|
| Global settings, CLAUDE.md, rules, agents, skills | `:ro` | User-owned, never modified |
| Project `.claude/` | `:rw` | `/init-workspace` writes CLAUDE.md and workspace.yml |
| Pack resources (knowledge, rules, agents, skills) | `:ro` | Read-only by design (ADR-14) |
| Managed files (`/etc/claude-code/`) | Baked in image, root-owned 644 | Non-modifiable |
| `project.yml` | `:ro` | Config, not modified at runtime |

**Analysis**: The only issue is project `.claude/` being `:rw`. This is needed because `/init-workspace` writes to `.claude/CLAUDE.md` and `.claude/workspace.yml`. But it also allows the agent to modify `.claude/rules/`, `.claude/agents/`, `.claude/skills/`.

**Solutions evaluated**:
1. **Granular mounts**: Mount each subdirectory separately (CLAUDE.md `:rw`, rules/ `:ro`, etc.). More complex compose generation, harder to maintain.
2. **Deny rules in managed-settings.json**: Add deny patterns for write access to `.claude/rules/*`, `.claude/agents/*`, `.claude/skills/*` at project level. Simpler, no mount changes needed. `/init-workspace` only writes CLAUDE.md and workspace.yml, which remain writable.
3. **Soft rule only** (current): `memory-policy.md` says "Do NOT modify user-owned config files without explicit user approval" — but this is not enforced technically.

**Decision**: Option 2 (deny rules in managed-settings.json) is the most elegant. Technical enforcement without mount complexity. Tutorial project can override if needed via its own settings.

**Effort**: Low (deny rule additions to `managed-settings.json`).
