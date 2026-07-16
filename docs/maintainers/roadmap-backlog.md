# Framework Improvements — Analysis & Decisions

> Backlog of framework improvements; see [roadmap.md](roadmap.md) for the live plan.
>
> Raised: 2026-03-14. Collected from field usage observations.
> These items will be revisited individually at design/analysis time before implementation.
>
> **Convention (2026-07-16) — re-verify the bound before designing an item.** A note records the
> symptom as *observed*, plus a suggested direction; neither is a finding. Before designing, re-derive
> the item's real boundary from the code: which call sites/artifacts are actually in scope, which are
> correct-by-design and must not be "fixed", and which **related** defects sit in the same
> neighbourhood — then design and fix them as one boundary-aware change. Rationale: this is how the
> 2026-07-16 triage found that `cco repo rename` needed no change at all (FI-21), that a second
> host-path defect sat inside the very function being fixed (§ e2e `project show`), and that
> FI-21/22/23 are three faces of one index model. A per-symptom fix would have missed all three.

---

## FI-1: Framework Context for the Coding Agent

**Status**: Implemented. Operational context added to `defaults/managed/CLAUDE.md` (Docker environment, workspace layout, agent teams, memory policy).

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

**Status**: Implemented (2026-03-19). Adaptive flow added to init-workspace: detects empty workspaces and guides user through 3 detail levels (idea → decisions → specs).

**Question**: When `/init-workspace` runs on an empty, unconfigured project, the agent doesn't know what to include. Should it ask the user clarification questions (project description, architecture, goals) before generating the CLAUDE.md? Or should init-workspace be suggested only after a first analysis phase?

**Context**: The current skill (`defaults/managed/.claude/skills/init-workspace/SKILL.md`) proceeds silently with automatic discovery. It is explicitly instructed to "proceed without confirmation" if the file is empty/missing. On an empty workspace (no repos, no manifests), it generates a nearly empty CLAUDE.md with placeholder sections.

**Analysis**:
- **Option A — Ask questions first**: Before writing, the skill asks "Describe what you want to build" and uses the answer to populate Overview and Architecture. More useful for greenfield projects.
- **Option B — Suggest init after first analysis**: The user first describes their goals (via `/analyze` or conversation), then invokes `/init-workspace` which already has context from the conversation. More aligned with the phased workflow.

**Decision**: Option B is more pragmatic and coherent with the structured workflow. The skill should add a check: if no repos are found and no `workspace.yml` descriptions exist, ask the user for a brief project description before generating.

**Effort**: Low (conditional logic addition to SKILL.md).

---

## FI-3: Default Ports and Chrome DevTools Port Management

**Status**: Implemented. Template default changed to `ports: []` with example comments. Chrome DevTools port management unchanged (already correct).

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

**Status**: Not implemented — planned as quick win (priority 2, effort medium-low). No `model:` field in `project.yml` or `--model` integration in entrypoint yet.

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

**Status**: Implemented (2026-03-19). Guides written (2026-03-16), defaults aligned with guides (2026-03-19). Scope revised: branch protection docs dropped (out of cco scope — user configures via GitHub if needed). Instead, defaults aligned to guide recommendations: CLAUDE.md rewritten, workflow.md expanded, diagrams.md→documentation.md, template cleaned up.

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

**Status**: Implemented. Deny rules added to `defaults/managed/managed-settings.json` preventing agent writes to `.claude/rules/*`, `.claude/agents/*`, `.claude/skills/*` at project level.

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

---

## FI-7: Publish-Install Sync and Resource Versioning

**Status**: Implemented (2026-03-17) — **but later superseded** by the decentralized-config
refactor. Projects no longer publish/install/update/internalize: a project rides its own
code-repo remote (ADR-0018 D2), and `cco project publish|install|update|internalize` were
removed (`bin/cco` now returns a removal notice). **Needs triage**: confirm which sub-decisions
survive under the new model (e.g. the 3-way merge path lives on in `cco update`; `cco project
internalize` / Case-C is reserved post-v1, ADR-0023 D4). The original FI-7 design doc
([link](../archive/sharing/publish-install-sync-design.md)) appears to have
been removed/archived in a docs reorg (dead link — needs triage alongside the doc review).

**Question**: After `cco project install`, the installed project has no connection to the source Config Repo. If the publisher pushes updates, how does the consumer know? Should there be a `cco project update` flow? What about versioning?

**Analysis & Design**: Full analysis and design completed 2026-03-17. Key decisions:

1. **Unified discovery** — `cco update` becomes the single "what's new?" command covering framework changes, remote publisher updates, and changelog. Actions are type-specific.

2. **Source-aware sync** — `cco update --sync` on installed projects skips opinionated files (managed by publisher chain: Framework → Publisher → Consumer). `--local` flag overrides this for inactive publishers.

3. **3-way merge for project updates** — `cco project update <name>` fetches remote, merges via `_collect_file_changes()` / `_interactive_sync()`. Consumer customizations preserved.

4. **Publish safety** — migration check (blocking), secret scan (blocking), framework alignment (warning), diff review, per-file confirmation, `.cco/publish-ignore`.

5. **Project internalize** — `cco project internalize <name>` disconnects from remote permanently.

6. **Version metadata** — optional `version:` field in `.cco/source` for human-readable labels; `commit:` field for precise comparison via `git ls-remote`.

**Docs**: [analysis](../archive/sharing/publish-install-sync-analysis.md) | [design](../archive/sharing/publish-install-sync-design.md) | [user guide](../users/configuration/guides/configuration-management.md)

**Effort**: Medium-High (6 implementation phases defined in design doc).

## FI-8: PromptSubmit Hook + Documentation-First Rule

**Status**: Implemented. See [defaults-alignment-design.md](configuration/rules-and-guidelines/design/design-defaults-alignment.md) §2.2, §2.3.

**Problem**: Rules loaded at session start lose effective weight as conversation grows or after compaction. The agent frequently forgets key behavioral rules — particularly git practices and commit discipline.

**Solution**:

1. **UserPromptSubmit hook** (`config/hooks/prompt-submit.sh`) — managed hook injecting a concise per-prompt reminder. Follows the Content Principle: reminds the agent to check its configured rules rather than hardcoding specific rule content. Works regardless of how the user has customized their rules.

2. **Documentation-first rule** (`defaults/managed/.claude/rules/documentation-first.md`) — managed rule requiring the agent to check existing docs, design documents, ADRs, and prior analysis before starting new work. Prevents proposing solutions that contradict or duplicate existing design decisions.

3. **Defaults review** (8c-8e) — global rules, global CLAUDE.md, and managed CLAUDE.md reviewed against user guides. No changes needed — FI-5 alignment was already complete.

**Design principle**: The hook and rule are managed (framework behavior), not opinionated defaults. They govern *how to use existing artifacts*, not *which artifacts to create*. The hook references user-configured rules rather than encoding specific conventions.

**Effort**: Low.

---

## FI-9: Migration UX gaps surfaced by the v0.4.0 release

**Status**: Open (raised 2026-06-30 during the npm-packaging analysis). To be addressed in the
`cco update` responsibility refactor — see
[`engineering/opinionated-extraction-and-update-refactor-handoff.md`](engineering/opinionated-extraction-and-update-refactor-handoff.md) §6.

**Context**: Running cco after the v0.4.0 decentralized-config migration exposed three UX gaps in the
migration / update flow.

**Items**:
1. **No rebuild reminder after migration.** When `cco <cmd>` triggers the preventive vault backup and
   advises `cco update` + `cco init --migrate`, nothing tells the user that a **fresh `cco build`
   (`--no-cache`?) is required before `cco start`** — a new release needs a new image, but this is
   surfaced nowhere. Add the hint; evaluate whether the migration should auto-trigger the rebuild.
2. **`cco update` as first command — backup symmetry.** Clarify whether `cco update` run as the very
   first command performs the **preventive backup of the old centralized vault** like every other cco
   command (it should, symmetrically), or intentionally skips it.
3. **Re-build coupling.** Decide whether the decentralized-config migration **triggers the rebuild**
   itself, or stays separate with an explicit user hint.

**Analysis**: All three point toward the future **`cco update` orchestrator** (detect install method →
run engine update + migrations, one command). Keep them together with that refactor.

**Effort**: Low–Medium (hints now; full orchestration with the update refactor).

## FI-10: Is managed `permissions.deny` enforced under `--dangerously-skip-permissions`?

**Status**: Open (raised 2026-06-30 during the `settings.json` decomposition for npm packaging —
ADR-0037 D10). Security investigation; does **not** block packaging.

**Context**: cco always launches `claude --dangerously-skip-permissions` (`config/entrypoint.sh:261,267`),
which bypasses the permission-prompt gate. The framework relies on managed `permissions.deny`
(`defaults/managed/managed-settings.json` — `Read(~/.ssh/*)`, `Read(~/.claude.json)`) as a security
backstop. Official Claude Code docs list `allowManagedPermissionRulesOnly` and
`permissions.disableBypassPermissionsMode` as the controls that make *only* managed rules apply and
disable bypass mode — and **cco sets neither**.

**Question**: Under bypassPermissions, are managed `deny` rules still enforced, or are they decorative?
- If enforced → no action; document the guarantee.
- If not → either add `allowManagedPermissionRulesOnly` / `disableBypassPermissionsMode` (but that would
  re-enable prompting, conflicting with the zero-friction model), **or** accept that **Docker-is-the-sandbox**
  is the real boundary and downgrade the `deny` to informational (the container already isolates host
  secrets; `~/.ssh` is not mounted).

**Verify**: read the official permissions/bypass docs precisely, then test in a live container
(attempt a denied `Read` under skip-permissions).

**Effort**: Low (investigation + doc/test); fix scope depends on the finding.

## FI-11: Top-level `cco --version` / `-v` (and `--help` / `-h`)

**Status**: ✅ Done (2026-06-30). Implemented exactly as scoped below: `--version`/`-v`
prints `package.json` `version` (`_cco_print_version` in `bin/cco`), `--help`/`-h` aliases
`usage()`, both handled before the dispatch and the J0 bootstrap (no side effects).
Tests in `tests/test_version.sh`; changelog #27. Ships in the next release (`0.5.2`).

**Context**: now that `cco` ships as an npm CLI, users expect `cco --version` to print the version
and `cco --help`/`-h` to show usage — both are near-universal CLI conventions. The dispatcher
(`bin/cco`) currently has **neither**: bare `cco` and `cco help` print usage (`usage()`, dispatch
line ~282), and `cco <command> --help`/`-h` work per-subcommand, but a top-level `--version`/`-v` or
`--help`/`-h` falls through to the `*)` arm → `die "Unknown command: …"` (line ~283). Surfaced when
`cco --version` errored during the post-release smoke test (the version had to be read from
`npm ls -g` instead).

**Proposed scope**:
- `cco --version` / `-v` → print the version. Source of truth = `package.json` `version` (read with
  the already-required `jq` from the resolved package root). Keeps the single source of truth
  (ADR-0037 D7) — no hardcoded string to drift.
- `cco --help` / `-h` (top-level, no subcommand) → call `usage()` (alias of `cco help`).
- Handle these **before** the command dispatch so they work with no other args.

**Type & tracking**: additive user-visible feature → `changelog.yml` entry; add a small dispatch test
(`cco --version` matches `package.json`, `cco --help` prints usage). No migration, no template change.

**Effort**: Low.

## FI-12: Retire `cco stop` — stop belongs to session exit

**Status**: 📝 Note — to analyze (surfaced 2026-07-14 during the resource-naming work).

**Context**: `cco stop [project]` is effectively unused. A session already terminates the
normal way: the user runs `/exit` in Claude and, once the last tmux pane exits, the `cco`
process (the `docker compose run --rm` foreground) ends and the container is removed. Nobody
runs `cco stop`. Worse, its detection is unreliable: with a session actually running, an
external `cco stop <project>` reports `No running session for '<project>'` and the project
keeps running — the lookup does not find the live session (likely because identity is the
compose `cco.project` label on a `run --rm`-discarded container, not a container name — see
the session-identity note in the access-model work).

**Direction to evaluate**: remove `cco stop` and assign stop responsibility entirely to the
`/exit` + tmux-exit path (which is already what happens). Before removing, verify no
teardown step (network `cc-<project>`, generated compose/overlay cleanup, running-registry
marker per ADR-0045) depends on `cco stop` being called — if so, re-home that teardown onto
the entrypoint/exit path or the `cco start` reconcile backstop. If a detection fix is cheaper
than removal, at minimum make the running-session lookup label-based so it stops matching by
container name.

**Type & tracking**: verb removal → breaking CLI surface change (deprecation + changelog);
possibly a migration only if teardown responsibilities move. **Effort**: Low–Med.

## FI-13: `cco deinit` — explicit, symmetric de-initialization

**Status**: 📝 Note — to analyze (surfaced 2026-07-14).

**Context**: there is no verb that is the clean inverse of `cco init` with an explicit
"de-initialize this project" intent. `cco forget` already performs the underlying action
(remove internal references to a project; `--purge` also removes `<repo>/.cco`), but its
intent/scope differs: `forget` is **not cwd-based** (takes a project name), and without
`--purge` it leaves `<repo>/.cco` in place. So the operation exists but the UX/verb for
"undo my init here" is missing — asymmetric with `init`.

**Direction to evaluate**: a `cco deinit` (cwd-based) that resolves the current repo's
project and wraps `forget --purge` (with the standard preview + confirm), giving init a clear
symmetric counterpart. Decide whether `deinit` should be a thin alias/wrapper or whether
`forget` itself grows a cwd-first form; keep one canonical implementation. Relates to the
resource-naming/lifecycle consistency theme.

**Type & tracking**: additive verb (or `forget` cwd-first form) → changelog; no schema
change. **Effort**: Low.

## FI-14: Unified credential/secret vault for agent access

**Status**: 📝 Note — major future feature, to analyze (surfaced 2026-07-14).

**Context**: today secrets reach a session only via the per-repo `secrets.env` (host-edited,
masked from every config mount) and `GITHUB_TOKEN`/`gh` for git+GitHub. There is no unified,
explicit management of credentials, keys, or passwords that agents (or cco-integrated tools)
may need — e.g. gh tokens, repo-access keys, or logins for portals/sites an agent drives in a
browser.

**Direction to evaluate**: a dedicated, access-controlled vault that unifies management of
secrets of various kinds for agent/tool use, integrated with the existing access model
(`cco_access`/`claude_access`, the setuid privilege boundary of ADR-0047, and the secret-file
masking already in place). Most important near-term use: repo + `gh` access. Design guidance
to capture: recommend **dedicated per-agent accounts** for external platforms so audit trails
stay faithful and permissions stay granular per access/operation. Cross-reference the archived
`docs/archive/vault/` design material (the old centralized-vault direction) for prior art —
this is a different, agent-credential-oriented scope, not that vault.

**Type & tracking**: large, multi-ADR feature; security-sensitive → requires its own analysis
+ design tree before any code. **Effort**: High.

## FI-15: Resource locking for concurrent sessions sharing a repo

**Status**: 📝 Note — to analyze (surfaced 2026-07-14). **Related**: Sprint 10 — Git worktree
isolation (#6) in `roadmap.md`.

**Context**: two different projects that reference the **same** repo (the supported
one-repo-multiple-projects model) can both be launched with `cco start` — the operation is
permitted with no guard. Their agents then potentially write the same files in the same host
repo/mount, risking concurrent-edit conflicts and corruption, with nothing protecting them.
The planned worktree isolation (Sprint 10) is the mechanism that would let multiple sessions
safely share a repo (each on its own `cco/<project>` worktree/branch), but until it lands the
shared-repo case is unprotected.

**Direction to evaluate**: a resource-locking mechanism over the host directories/repos/mounts
a started project holds — e.g. an advisory lock (tied to the ADR-0045 running-registry) that,
on `cco start`, detects another live session already holding an overlapping repo/mount and
either refuses, warns, or requires worktree isolation. Frame worktrees (Sprint 10) as the
**enabler** for safe concurrent sharing and the lock as the **guard** for the un-isolated case.
Needs proper analysis, evaluation, and design — captured here as a note to keep in mind.

**Type & tracking**: safety/correctness feature; couples with Sprint 10 → design together.
**Effort**: Med–High.

## FI-16: Fail-loud state guards for mixed cco versions

**Status**: 📝 Note — to analyze (surfaced 2026-07-15 while fixing the ADR-0049 §5 start bug).

**Context**: two cco installs on one machine share a single config store, and a newer one can
leave state an older one silently misreads. Observed: `./bin/cco` (dev, ADR-0051) upgraded the
machine-local index to `version: 2` on its first write; the npm-released `0.5.2` — which predates
per-project scoping and looks for the flat `paths:` section — then found no bindings and prompted
to re-clone a repo that was present all along. The index migration itself is sound (`lib/index.sh`
reads v1 as global-flat and upgrades on the first host write); the defect is that the **downgrade
degrades illegibly**, into a misleading prompt rather than a clear refusal.

The maintainer's framing (2026-07-15): the breaking changes were deliberate and correct (pre-1.0,
~2 users, unified config + access model wanted fast) — the lesson is not "break less" but
**fail loud at the boundaries where one version reads another's state**. Fixing the `0.5.2` symptom
is not worth it: that code is published and the edge case dies at release. Fix the root.

**Second sighting (2026-07-16)** — the same incident recurred on the host and widened the symptom
set, confirming the note is worth acting on. Running the **npm-released `cco`** against a
dev-written store: `cco path list` reported *"the path index is empty"* (v1 reader, flat `paths:`,
against a v2 `project_paths:` index), and `cco resolve` then offered to re-clone a repo that was
present all along. Worse than the misread: `cco resolve` / `cco path set` are **index writers** — an
old binary that misreads v2 as "empty" can write **v1-format records back into a v2 file**, mixing
formats in place (the corruption feared in [FI-22](#fi-22-internal-state-validation-doctor-and-repair)).
The maintainer's framing stands: fix the root, not the published `0.5.2` symptom.

**Direction to evaluate** (a **global, schema-driven gate** — explicitly NOT a per-command guard;
the stated requirement is that no command can be "forgotten"):
- **The choke point already exists.** `_cco_first_run "$cmd"` (`bin/cco:521`) runs **before every
  dispatch**, host-side only, idempotent — the natural home for one gate covering the whole surface.
- **The max supported version is already derivable.** `_latest_schema_version <scope>`
  (`lib/update-meta.sh`) computes the max by scanning the binary's **own `migrations/<scope>/`**.
  A gate written as `on-disk > latest → die` therefore **self-maintains**: adding a migration bumps
  the bound automatically, with no constant to remember to update. (Verify at design: `migrations/`
  covers `global`/`project`; the **index** version is a separate hardcoded `2` in
  `_index_ensure_file` — it needs its own declared bound, and it is the artifact that actually broke.)
- **The gap is one-directional.** Only `current < latest` exists today (`lib/cmd-start.sh:858`,
  "Updates available. Run 'cco update'"). The reverse — disk **newer** than the binary — has no
  check anywhere, so the old binary proceeds silently. That asymmetry is the whole defect.
- **Which artifacts need a bound**: today only `.cco/meta` (`schema_version`) and the index
  (`version:`) carry one at all. Tags/remotes/running-registry/source records are **unversioned**
  (see FI-22) — decide at design whether the gate needs them stamped, or whether refusing on the
  two versioned artifacts is sufficient to stop the session before anything else is written.
- **CLI↔image version handshake** at `cco start` — the host cco and the image's `/opt/cco` can
  diverge (exactly the 2026-07-15 case: npm cco + dev-built image), today with no signal.
- **Dev-side mitigation** (no code, available today): keep the npm cco off `PATH` while developing
  (`npm link`/alias) so the mixed-version state cannot arise in the first place.
- Note `_cco_in_container` has a related gap: the `CCO_IN_CONTAINER` override honours `==1` but
  never `==0`, so there is no escape hatch to force host semantics.

**Re-verify the bound before design** (per the 2026-07-16 triage convention): confirm the write-side
inventory — *every* index/store writer reachable from an old binary, not just `resolve`/`path set` —
and check whether the gate belongs **before** `_cco_first_run`'s own bootstrap/self-heal steps
(`_cco_flatten_global_claude` etc. already mutate state at that point, so a gate placed after them
would fire too late). Decide read-only verbs' fate too: a hard `die` on `cco list` may be worse than
a warn, but a `die` on any writer is the point of the exercise.

**Type & tracking**: additive guards → changelog; no schema change. **Effort**: Low.
**Priority**: high among the FI notes — it is the root cause that makes FI-22's corruption class
possible, and it is cheap. Not gating the access/CLI e2e review (that runs a single binary — the one
baked into the image — so the mixed-version scenario cannot arise there).

## FI-17: config-editor should mount the target project's repos read-only

**Status**: 📝 Note — to analyze (raised by the maintainer 2026-07-15).

**Context**: `cco start config-editor` mounts config only. But editing a project's rules/config
well needs the project's **context**: its repos and extra_mounts, read-only. The precedent is the
personal store — `~/.cco` is mounted `ro` precisely so decisions are informed rather than blind;
the same argument applies to the repos the rules govern. Today the config-editor edits rules for
code it cannot see.

**Direction to evaluate**: in config-editor **project mode** (cwd-in-project or `--project <name>`),
mount the target's repos/extra_mounts `:ro` by default. Touches ADR-0044 §3 (min-privilege by mode)
and the ADR-0048 WS-A refinement — the `--repo <name>` flag already adds one repo, so decide whether
this becomes the default or stays opt-in, and whether extra_mounts follow. Weigh against the
min-privilege default the preset is built on.

**Type & tracking**: default-behaviour change in a built-in preset → changelog; ADR-0044 annotation.
**Effort**: Low–Med.

## FI-18: Decouple CLAUDE.md from rules/agents/skills in claude_access

**Status**: 📝 Note — to analyze (raised by the maintainer 2026-07-15; explicitly post-e2e).

**Context**: Axis B (`claude_access`, ADR-0049) governs each `.claude` **tree** as a unit: CLAUDE.md,
`rules/`, `agents/`, and `skills/` share one `ro`/`rw` decision per tree. A finer split may be
wanted: let a session author **CLAUDE.md** (project narrative/context, routinely updated as work
progresses) while `rules/`, `agents/`, and `skills/` stay read-only (governance the agent should not
rewrite for itself). Today the two intents can only be had together.

**Direction to evaluate**: whether the axis granularity should grow a per-resource dimension, or
whether a `settings.local.json`-style **functional-write floor** (ADR-0049 §5) is the better shape —
i.e. a narrow always-writable carve-out rather than a new axis. Consider the cost: Axis B is already
a 4-tuple `(Cr,Cp,Cg,Co)`, and multiplying it by resource class risks an unusable surface. Weigh
against P2 discordance and the concordant-default model before committing.

**Type & tracking**: access-model extension → ADR + changelog. **Effort**: Med.

## FI-19: Host-only suite tests should skip, not fail, under the privilege boundary

**Status**: 📝 Note — to analyze (surfaced 2026-07-15 while fixing the ADR-0049 §5 start bug).

**Context**: the suite reports a permanent **7 failures when run inside a cco session** — 6 in
`tests/test_access_scope.sh` (`test_as_*`) and `test_paths_symlink_safe_tool_root`. They are **not a
code defect**: the ADR-0047 privilege boundary is live in-session (`cco-svc-helper` setuid 4750,
`~/.cache/cco` unreadable to the agent), and the 6 `test_as_*` tests explicitly set
`CCO_CONTAINER_OPERATOR=1`, so `cco list` re-enters via the setuid helper — which by design ignores
env (`CCO_STATE_HOME` & co.) and reads the real internal store. The tests' redirected fixture store is
therefore invisible and the real environment shows up instead. `test_paths` fails on `mkdir ~/.cache/cco`
→ Permission denied, same boundary. Ironically these tests accidentally prove the boundary cannot be
bypassed by environment. On the host they are expected to pass (1308/0 — worth confirming once).

**Why it matters**: a standing 7-failure baseline trains everyone to read failures as noise. That is
the same habit that let the ADR-0049 §5 start bug ship green.

**Direction to evaluate**: detect the boundary (`-u /usr/local/bin/cco-svc-helper`, or `~/.cache/cco`
unreadable) and **skip with a reason** instead of failing. The harness has no `skip_test()` helper
today — add one, keeping the suite hermetic (it mocks docker throughout; no daemon dependency).
Refuted while diagnosing, do not retry: a `CCO_IN_CONTAINER=0` escape hatch, and unsetting the
inherited session env — neither fixes any of the 7.

**Type & tracking**: test-harness change only; no user-facing surface. **Effort**: Low.

## FI-20: git operations vs the `:ro` `.cco` overlay — partial checkout footgun

**Status**: 📝 Note — to analyze (hit live 2026-07-15 while merging the start-bug fix in-session).

**Context**: the Axis-A1 edit-protection overlay mounts `<repo>/.cco` `:ro` at `read-project`. Git
is not exempt: **any branch operation whose diff touches `.cco` fails**, because git must write the
worktree file and hits `EROFS`. This is **correct by design** — if git could write `.cco`, an agent
could bypass the structural-config boundary by committing and checking out — but it has consequences
nobody has written down:

- A branch carrying a committed `.cco` change (e.g. a migration's own output, as migration 015
  produced here) **cannot be merged or checked out from a normal session**.
- Worse, git applies checkouts **partially**: `git checkout develop` switched branches and updated
  every other file, failing only on `.cco/.gitignore`. The result was a worktree silently sitting on
  the wrong branch **without the fix that had just been made** — a subsequent `cco start` would have
  reintroduced the very bug being fixed. The `Aborting` message came from the follow-on merge, not
  the checkout, so the failure read as "nothing happened" when in fact the tree had moved.
- Recovery is non-obvious: `git checkout <branch>` refuses (local changes), `git stash`/`git checkout
  -- <path>` also need to write `.cco`. What works: `git add .cco/<file>` to align the index with the
  (already-correct) worktree content, so the next checkout needs no write.

**Direction to evaluate**: decide the intended contract and make it legible rather than emergent.
Options, not exclusive — (a) detect the condition at `cco start`/in the shim and **warn** that git
branch ops touching `.cco` will fail at this access level; (b) document the pattern (commit `.cco`
changes host-side, or use `--cco-access edit-project`) in the access docs; (c) consider whether the
overlay should be relaxed for git's own writes — **probably not**, it would reopen the bypass. Note
the interaction is generic: it applies to `secrets.env` and any other `:ro`-masked path too.

**Type & tracking**: UX/safety of the access model; docs + possibly a start-time warning. No schema
change. **Effort**: Low.

## FI-21: Explicit project scope on the host-path surface (post-ADR-0051 completeness)

**Status**: 📝 Note — to analyze (surfaced 2026-07-16, maintainer host session, while renaming a repo;
scope refined by the maintainer the same day — see the principle below).

**Context**: ADR-0051 made repo/extra_mount names **per-project labels for a path** — the same name
may legitimately name *different resources* in different projects. The index primitives and the
rename verbs implement that model correctly, but **the CLI surface around them was never audited for
the ambiguity the model introduces**. The maintainer's question — *"if I rename a `<repo-name>` that
differs across projects, which one moves? if `cco path set` gets a name that exists in several
projects, which path changes?"* — gets three different answers today, and the surface as a whole was
never given a deliberate scope UX:

- **`cco repo|extra-mount rename` — semantics correct; scope UX incomplete.** `lib/cmd-repo.sh` is
  deliberately project-scoped and path-anchored, and the *default* (cwd project) is right: another
  project's same-named-but-different-path binding **is a different resource**, so cross-project
  fan-out must never be the default (D1). It also names the project it acted on. **But "the default
  is correct" is not "the verb is complete"**: there is no way to target another project without
  `cd`-ing into it (`--project <name>`), and no way to re-label a path **everywhere it is
  referenced** (`--all-projects`). Note the latter is *not* in tension with D1 — re-labelling one
  PATH across the projects that reference it is path-anchored by definition, which is exactly what
  D1 makes identity. (An earlier triage pass recorded this as "correct, no action, question closed";
  that was **wrong** — it answered the semantics question and mistook it for the UX one.)
- **`cco path set <name> <path>` — same shape.** Binds in the project hosting the **cwd**; outside any
  project it writes the `unscoped:` bucket. The default is sound and the choice is deterministic
  **and printed** (`path set: [<proj>] <name> -> <abs>`), and the verb is the documented low-level
  escape hatch — but again there is no `--project` to aim it elsewhere.
- **Silent first-match resolution — the outright defect.** `_index_get_path_any <name>` returns the
  **first** binding across all projects with no disambiguation and no notice. `lib/index.sh:533`
  documents 3 such call sites; there are **5**: `cco sync --from` (`cmd-sync.sh:178`), `cco sync
  <target>` (`cmd-sync.sh:200`), `resolve --scan` pass 2 (`cmd-resolve.sh:566`), `cco start --from`
  (`cmd-start.sh:720`), config-editor `--repo` (`cmd-start.sh:613`). With homonyms (`backend`, `web`,
  `assets`) these act on **whichever project is indexed first** — a wrong-target write for `sync`.
  The doc under-counts its own ambiguity sites, which is itself a signal the surface was not swept.

**Proposed guiding principle (maintainer, 2026-07-16 — to ratify at design, NOT yet normative)**.
It governs **read and write alike**, and its point is *deliberate, complete* scope UX rather than
scope-by-accident:

> Every `cco` command that handles the host path of a **per-project-scoped resource** (repo,
> extra_mount) MUST make its project scope **explicit and complete**:
> 1. **Default to the cwd project** — the established cco convention, and the right default.
> 2. **Never be limited to it.** Where another scope is meaningful, offer it explicitly:
>    `--project <name>` to aim at another project, `--all-projects` where acting on every binding of
>    a path is coherent. cwd is a *convenience default*, never a ceiling (the same resolution D-CE1
>    reached for config-editor).
> 3. **Declare the scope, or show everything.** A per-project-scoped output must *say* it is scoped
>    (as `cco path list` does with its `[project]` prefix). A lookup that is generic must return
>    **all** matching bindings — **never the first occurrence while silently hiding the others**.
>    "Scoped" and "generic" are both fine; *undeclared* is not.
> 4. **Filter, don't force.** Give the user a scope filter (e.g. `cco path list --project <name>`)
>    rather than making them read a mixed view — the current list is legible only because it is short.
>
> Rationale: the same UX applies whether the command reads or writes, so the user learns **one** rule
> for the whole surface. Point 3 is the one that turns a UX preference into a correctness rule — it is
> what makes `_index_get_path_any`'s silent first-match a bug rather than a shortcut.

**Suggested direction (verify at design)**: extend the **existing** ADR-0051 D4 machinery
(`_index_bindings_for_name`, `_resolve_reuse_menu`, `_resolve_disambiguate`, + the git-origin/url
divergence signal) from the add-time surface to the read/edit/consume surface, rather than inventing a
second mechanism. Interactive prompts need a non-interactive twin (`sync`/`start` must stay
scriptable, and cco's own convention is "widen via explicit flags, not prompts" — D-CE1), which is why
the flags in point 2 and the prompt are the *same* decision seen from two contexts. Naming to settle
at design: `--all-projects` vs a `--project` that repeats; and whether path listing becomes a `cco
list` kind (`cco list path --project …`, the maintainer's phrasing) or stays `cco path list
--project …`.

**Re-verify the bound before design**: re-derive the call-site list from the code (do not trust the 5
above, nor the stale `index.sh:533` header — that under-count *is* the failure mode). Then classify
every site on **two** axes, not one: (a) *genuinely cross-project* (config-editor `--repo` is
intentionally so) vs *ambiguous by omission*; and (b) **read vs write** — a wrong-target *read*
degrades, a wrong-target *write* (`sync`) corrupts, so they may deserve different answers (prompt /
flag / fail-loud refusal). Sweep the **whole** kind, not just the verbs named here: any verb taking a
repo/extra_mount name is in scope. Check `_index_get_path`'s `unscoped:` fallback in the same pass —
see [FI-23](#fi-23-extra_mount-legacy-bindings-land-in-the-unscoped-bucket-adr-0051-migration-residue),
which is the same model leaking from the other end, and would otherwise re-introduce a cross-project
default underneath any flag added here.

**Type & tracking**: UX + correctness on the naming surface → changelog; no schema change expected
(flags + lookups only). If ratified, the principle belongs in a **living design doc**, not only in
this note — the natural home is the naming design tree, cross-referenced from
[design-cli-environment-awareness](cli/design/design-cli-environment-awareness.md) (which owns the
*other* host-path axis: host-vs-container, §4c). Keep the two axes distinct — *which project does this
path belong to* and *does this path exist in this environment* are different questions that happen to
share the word "path". **Effort**: Med.
**Not gating the access/CLI e2e review** — the e2e handoff §9 explicitly defers "broader naming
semantics (per-project scoping ADR-0051, disambiguation prompts)" to a separate naming track. This
note **is** that track.

## FI-22: Internal-state validation, doctor and repair

**Status**: 📝 Note — to analyze (surfaced 2026-07-16, maintainer question following the FI-16 incident).

**Context**: if an internal file is written by a wrong/older cco or hand-edited, records can end up
malformed or **mixed-format** (e.g. an un-scoped v1 repo path inside a v2 per-project index). The
question was whether cco has validation / warning / doctor / sanitisation for this, or whether it is
left to "conventions" that each writer must follow. Conventions are the wrong answer for exactly the
FI-16 reason: they are what gets forgotten.

**What already exists** (so this is an *extension*, not a new subsystem):
- **`cco config validate [--fix]`** (`lib/cmd-config.sh:300`) already has the right shape:
  orphan-sanitisation, **detect-only by default**, `--fix` preview-first + confirmed, never
  automatic. Its prune aggressiveness is already calibrated by bucket sync-class (ADR-0021 Dec.5):
  STATE/CACHE are machine-local + rebuildable via `cco resolve --scan`; **DATA is synced, so a wrong
  prune propagates across machines** and needs a second explicit confirmation. That reasoning is the
  hard part and it is already settled — reuse it, do not re-litigate it.
- Self-heal precedents: the ADR-0045 running-registry reconcile backstop (silent prune of stale
  markers at `cco start`) and the transparent index v1→v2 migration (ADR-0051 D6).
- Per-resource validators exist for **user-facing** config: `cco project|pack|template validate`.

**The actual gap**: the **internal** artifacts have no integrity story. Readers are uniformly
*lenient* — `lib/index.sh` (awk section extraction, `_peel_tab`), `lib/tags.sh` (`_tags_get` bracket
regex), `lib/cmd-remote.sh` (`IFS='=' read`) all **skip or silently misparse** a malformed record
rather than flag it, so corruption reads as "empty" (precisely the FI-16 symptom). And only
`.cco/meta` + the index carry a version at all: **tags, remotes, tokens, running markers and source
records are unversioned**, so nothing can even detect that they were written by another generation.

**Direction to evaluate**:
- **Fix the source first.** Much of this class is closed upstream by the [FI-16](#fi-16-fail-loud-state-guards-for-mixed-cco-versions)
  gate — refusing the old binary prevents the corruption instead of detecting it afterwards.
  Sequence FI-16 **before** this note and re-scope what is left.
- **Extend `cco config validate`** with structural/format checks (does each record parse? is any
  record in a foreign format? is the file's version within the supported bound?) rather than adding a
  `cco doctor` verb — a second entry point for the same job would split the surface. Whether a
  `doctor` **alias** is warranted is a naming question, decidable later.
- **Decide the read-time contract**: strict-fail vs warn-once vs lenient-skip on a malformed record.
  Today's silent-skip is the reason a corrupt index looks empty; at minimum a malformed record should
  be *visible*. Note `cco path list` already flags malformed (non-absolute) entries — a local
  precedent to generalise from.

**Re-verify the bound before design**: inventory each internal artifact as **regenerable**
(index → `resolve --scan`; llms → re-download) vs **irreplaceable** (tags, tokens) — repair strategy
follows from that split, and the ADR-0021 sync-class reasoning already encodes half of it. Confirm
what FI-16 leaves unfixed before sizing.

**Type & tracking**: extends an existing verb → changelog; possibly version stamps on unversioned
artifacts (schema-touching → migration). **Effort**: Med (Low if FI-16 lands first).
**Not gating** the e2e review.

## FI-23: extra_mount legacy bindings land in the `unscoped:` bucket (ADR-0051 migration residue)

**Status**: 📝 Note — to analyze (found 2026-07-16 by code inspection while triaging FI-21; **live on
the maintainer's machine**).

**Context**: the v1→v2 index migration (`lib/index.sh:97`) re-homes a flat `paths:` name under every
project that lists it **in the `projects:` membership**. But membership is written by
`_index_set_project_repos`, fed from `yml_get_repo_coords` (`cmd-resolve.sh:330`/`537`, `cmd-init.sh`,
`cmd-join.sh`) — i.e. **repos only, never extra_mounts**. So every legacy extra_mount matches no
membership and is migrated into the `unscoped:` bucket, where `_index_get_path` (`lib/index.sh:523`)
consults it as a **fallback for any project**.

**Why it matters**: that fallback is a de-facto **global default layer for extra_mounts** — the exact
construct **ADR-0051 D2 explicitly rejected** ("no global-default layer … a global default is
meaningless for generic labels"). And it lands precisely on the generic names the ADR was written for:
the maintainer's live index shows `assets`, `mock`, `reference`, `project-docs`,
`cave-api-framework` sitting unscoped. Observable symptom: the messy mixed `cco path list` view
(prefixed `[project] name` rows *and* bare rows) that prompted the maintainer's "path list is a bit
of a mess" remark — the format is not the cause, the residue is.

**Severity is low, and why**: it is self-healing in practice — `cco resolve` re-binds each mount
per-project (the maintainer's `cave-flow`/`cave-eda-framework` are correctly scoped under two
projects), and a project's own binding **wins** over the unscoped fallback. The residue is a stale
record, not a wrong resolution. But it is a **completeness gap in a just-shipped migration**, and it
keeps a rejected mechanism reachable.

**Direction to evaluate**: decide whether the fallback is (a) an intentional escape hatch for the
project-less `cco path set` pin — which is how `index.sh:512-517` describes it, and that use is
legitimate — or (b) an unintended global default once *migrated* mounts land there. If the split is
real, the fix is in the **migration**, not the fallback: re-home a legacy extra_mount under the
projects whose `project.yml` actually references it (the coordinate reader for mounts already exists
alongside `yml_get_repo_coords`), leaving `unscoped:` for genuine project-less pins only. Pair with a
prune path for residue already on disk (`cco config validate --fix` is the natural home — FI-22).

**Re-verify the bound before design**: confirm whether membership *should* include extra_mounts at all
(it is named `_index_set_project_repos` and `cco join` reasons about repos — widening it may have
callers' semantics attached), and check whether `_index_get_path_any` (FI-21) plus this fallback
overlap into the same cross-project resolution question. FI-21, FI-22 and this note all touch the
index model — **scope them together before designing any one of them**.

**Type & tracking**: migration completeness → likely a follow-up migration + changelog.
**Effort**: Low–Med. **Not gating** the e2e review (self-healing; project bindings win).
