# Access-model refinements — handoff (post hardening-v2)

> **Status (2026-07-11): PROPOSED decisions, NOT yet implemented.** Emerged from the maintainer
> dialogue during hardening-v2 Phase VI (the config-editor `edit-global` fix `67ad13f` + the DOC5
> cutover). Two refinement workstreams, sequenced. **The next session's FIRST task is to VALIDATE
> correctness + coherence of these decisions against the current model (ADR-0036/0044/0046) — only
> then implement.** If validation surfaces a contradiction, revise the decision, don't force the code.
>
> **Scope note:** the shipped hardening-v2 code (branch `feat/config-access/e2e-review`, NOT pushed)
> stays as-is; config-editor currently resolves project mode to `edit-global` (`67ad13f`). These
> refinements *revise* that — but only after validation, in the dedicated sessions below. Nothing
> here is a released model, so there is no back-compat burden.
>
> **Sequencing (maintainer decision 2026-07-11): these refinements land BEFORE e2e v2.** The
> hardening-v2 image is already rebuilt (`cco build` done, this session restarted on it — the
> boundary/preset fixes are live). e2e v2 acceptance is **deferred to run against the FINAL,
> approved+implemented design** — i.e. after WS-A (and WS-B where it touches the model). So the
> order is: **WS-A validate → implement → (WS-B) → then e2e v2** (+ push both branches from the Mac).

**Related decisions**: [ADR-0036](../decisions/) (three-knob model `claude_access`/`cco_access`/
`show_host_paths`), [ADR-0044](../decisions/0044-internal-builtin-presets-and-config-editor-scope.md)
(config-editor min-privilege + tutorial read-all), [ADR-0046](../decisions/0046-unified-cco-access-model.md)
(the `(G,Pc,Po)` triple + invariants). **These refinements will be extracted into a new ADR (or an
amendment) + the living design docs once validated.**

---

## 0. Verified facts (established this session, code-grounded)

1. **Tutorial `read-all` is overridable downward.** `read-all` is the *preset default*; the user
   may narrow it with an explicit `--cco-access` (precedence CLI > preset; **no clamp** —
   `cmd-start.sh:247-262`; ADR-0044 §2 chose "available but discouraged", not hard-disable).
   **No change wanted** — confirmed correct as-is.
2. **config-editor project mode currently resolves to `edit-global` `(rw,rw,none)`** (`67ad13f`),
   and `~/.cco` (`cco-config`) is mounted `rw` unconditionally by its generated project.yml
   (`cmd-start.sh:132-134`). An explicit `--cco-access edit-project` yields `(none,rw,none)` — the
   footgun this refinement closes.
3. **`edit-project` mounts project-referenced globals READ-ONLY** (ADR-0046 §7: referenced packs
   ride with `Pc` for *read visibility only*; any global *write* needs `G=rw`; code
   `cmd-start.sh:1212-1230` mounts them `ro` under `G=none`). There is **no partial-write on the
   referenced subset** (that is the rejected Model α). This is why `edit-project` config-editor is
   read-limited (can't discover unreferenced globals to reference) — see WS-A.
4. **`claude_access` (Axis B) governs three `.claude` trees; `cco_access` (Axis A) governs the
   `.cco` config** — physically nested, decoupled by child-mount-wins (`cmd-start.sh:1123-1246`):

   | Tree | Container path | Governed by | Modes |
   |---|---|---|---|
   | **B1** repo-native `<repo>/.claude` | `/workspace/<repo>/.claude` | `claude_access` | none→ro, repo/all→rw |
   | **B2** project claude `<repo>/.cco/claude/` | `/workspace/.claude` | `claude_access` | none→ro, repo/all→rw |
   | **B3** global claude `~/.cco/.claude` | `/home/claude/.cco/.claude` | `claude_access` | none/repo→ro, **all→rw** |
   | **A1** project structural `<repo>/.cco` (project.yml, secrets, packs wiring) | overlay | `cco_access` **Pc** | Pc=rw→rw |
   | **A2** global store `~/.cco` (packs/templates/llms) | `/home/claude/.cco` | `cco_access` **G** | G=rw→rw |
   | `settings.json` (B3) | — | — | **always rw** (runtime prefs) |

   B2 and B3 live *inside* the `.cco` trees but are governed by `claude_access`, not `cco_access`
   → the source of the C2 incongruence (WS-B).

---

## WS-A — config-editor default access + read floor (validate → implement)

### A.1 The decided model (PROPOSED)

config-editor serves **three real, recurring intents**, all of which must be launchable
**without typing an explicit granular triple**:

```mermaid
flowchart TD
  START["cco start config-editor"] --> Q{cwd is a project<br/>OR --project given?}
  Q -- "no (bare)" --> G["GLOBAL mode<br/>(rw, none, none)<br/>edit only ~/.cco"]
  Q -- "yes" --> P["PROJECT mode — DEFAULT<br/>(ro, rw, none)<br/>edit the project, READ global"]
  P -- "--cco-access edit-global" --> PG["(rw, rw, none)<br/>edit project + global"]
  START -- "--all / --cco-access edit-all" --> ALL["(rw, rw, rw)<br/>edit every project + global"]
```

| Launch | Resolved `(G,Pc,Po)` | Intent | Preset? |
|---|---|---|---|
| `config-editor`, cwd-in-project or `--project <n>` | **`(ro, rw, none)`** *(DEFAULT, min-priv)* | edit **only** the project; **see** the whole global store (to reference) | none (asymmetric) — reached as the default |
| `config-editor --cco-access edit-global`, in a project | `(rw, rw, none)` | edit project **+** global store | `edit-global` sugar |
| `config-editor`, bare (no project resolved) | **`(rw, none, none)`** | edit **only** the global store | none (see A.2) |
| `config-editor --all` / `--cco-access edit-all` | `(rw, rw, rw)` | edit every project + global | `edit-all` sugar |

**Invariant (config-editor-specific): `G ≥ ro` always.** config-editor is an *authoring* tool — it
must always *see* the global store to reference/author against it (analogous to tutorial=read-all).
So `G=none` is never allowed for config-editor: an explicit `--cco-access edit-project` (or any
lower-G granular) is **clamped to `G=ro`** → `(ro,rw,none)`. Rationale mirrors ADR-0044 §2's
read-all reasoning + closes both C1-blindness and the C2 asymmetry at the config-editor level.

**Why `(ro,rw,none)` default over the shipped `edit-global` `(rw,rw,none)`:** "I opened config-editor
on project X" most often means *edit X*, reading the global only to reference it — least privilege.
Writing the global store is a *distinct* intent, reached with the known `edit-global` sugar. This
gives a clean, symmetric-sugar-friendly ladder without forcing explicit triples.

### A.2 Correctness / coherence items to VALIDATE FIRST

- **[A-V1] `(rw,none,none)` violates INV-2 as currently coded.** `_cco_promote_triple`
  (`access-scope.sh:132-143`) **dies** if `Pc < ro` while cco is enabled (*"INV-2 project floor"*).
  INV-2 (ADR-0046 §2) assumes a current project **always exists** — false in config-editor global
  mode (and arguably `cco new` / any no-project session). **Decision needed:** refine INV-2 to
  **"IF a current project is in scope, `Pc ≥ ro`"** (a conditional floor + a "no-current-project"
  session state where `Pc=none` is legitimate), **or** keep `Pc` inert at `ro`/`rw` for global mode
  (i.e. accept `(rw,ro,none)` / today's `(rw,rw,none)` as "Pc moot"). Recommended: the conditional
  floor — it makes `(rw,none,none)` the honest triple the maintainer wants and generalises to every
  project-less session. Verify it does not break the resolver, the mount-gen, or output-scoping
  (what does `_env_in_scope project <current>` do when there is no current project?).
- **[A-V2] Revises `67ad13f` + contradicts ADR-0044 §3.** ADR-0044 §3 states project-mode editable
  surface = "`~/.cco` + cwd project" (⇒ `~/.cco` writable). The new default `(ro,rw,none)` makes
  `~/.cco` **read-only** in project mode. Re-annotate ADR-0044 §3 (immutable history) and reconcile
  the forward-annotation added by `67ad13f`/`4335b2f`.
- **[A-V3] config-editor `claude_access=all` interaction.** config-editor sets `claude=all`
  unconditionally (`cmd-start.sh:226`) → B3 (`~/.cco/.claude`) `rw` even when the new default has
  `G=ro`. That reintroduces the global-authoring asymmetry (global `.claude` writable, global `.cco`
  read-only) at the config-editor level. **This couples WS-A to WS-B** — resolve together, or make
  config-editor's `claude_access` follow `G` (B3 rw only when `G=rw`).
- **[A-V4] Global mode "no project resolved".** Confirm the resolver's mode detection
  (`_resolve_config_editor_mode`) cleanly distinguishes "bare, no project" (→ global) from
  "cwd-in-project" (→ project) for the `(rw,none,none)` vs `(ro,rw,none)` split; and that `--all`
  still wins.

### A.3 Implementation sketch (AFTER validation)

- `_start_resolve_access` config-editor branch: `project → (ro,rw,none)`; `global → (rw,none,none)`;
  `all → edit-all`; clamp `G` to `≥ ro` for any explicit override.
- Enforce the `G ≥ ro` invariant for the config-editor preset (clamp, with a one-line notice).
- Revisit the config-editor `cco-config` mount so its rw/ro follows the resolved `G` (today
  unconditional rw, `cmd-start.sh:132-134`).
- Resolve [A-V1] (INV-2) and [A-V3] (claude=all) as decided.
- Tests: `test_access_resolution` (the new triples + clamp), `test_config_editor` (the three launch
  modes + edit-global override + explicit-edit-project→clamp), invariant tests for the conditional floor.
- **DOC5 follow-up cutover** (the shipped docs describe `edit-global` project mode today): update
  `cli.md`, repo `CLAUDE.md`, config-editor guide, CLI-surface matrix; re-annotate ADR-0044 §3.

---

## WS-B — `claude_access` × `cco_access` coupling (dedicated analysis session)

### B.1 The incongruence taxonomy (established)

| # | Combination | Effect | Verdict |
|---|---|---|---|
| **C1** | normal session: `claude=repo` + `cco=read-project` | writes `<repo>/.cco/claude/` (CLAUDE.md/rules) but **not** project.yml/secrets | **FEATURE** (P17: /init authoring open; structural protected) — coherent but non-obvious |
| **C2** | config-editor `claude=all` + `G=none/ro` | writes `~/.cco/.claude` (global rules) but **not** `~/.cco/packs` (global packs) | **FOOTGUN** — asymmetric global authoring; `claude=all` is unconditional in config-editor, decoupled from `G` |
| **C3** | `cco=edit-*` + `claude=none` | rewires packs/project.yml but not rules/agents | rare/coherent |

### B.2 Proposed direction (to analyse in depth)

**Targeted coupling, not blanket:** `cco_access` **bounds** `claude_access` for the `.claude` trees
that live **inside** `.cco` config (B2 `<repo>/.cco/claude/`, B3 `~/.cco/.claude`); only **B1**
(`<repo>/.claude`, the repo's own native tree, *not* framework config) stays fully decoupled.

- **Global (B3 vs G):** `cco_access` wins — if `cco_access` denies the global store (`G=none`) but
  `claude_access=all` would write `~/.cco/.claude` → **error** (or clamp B3 to ro + warn). Closes C2.
- **Project (B2 vs Pc):** decide between:
  - **(b-i) keep decoupled** — B2 rw under `claude=repo` even if `Pc=ro` (preserves C1/P17), or
  - **(b-ii) bound it too** — `<repo>/.cco/claude/` follows `Pc`; only `<repo>/.claude` (B1) stays
    decoupled. Cleaner mental model ("everything under `.cco` obeys `cco_access`; the repo's own
    `.claude` obeys `claude_access`") but **changes the C1/P17 default** for standard projects.
- **Warn** on explicit conflicting flags regardless (`--claude-access all --cco-access read-project`).

### B.3 Open questions for the dedicated session

- Is `claude_access` **always** bounded by `cco_access` (leaving only B1 decoupled)? Or keep
  project-level decoupling (b-i)? Weigh C1/P17 value vs the "everything-in-.cco obeys cco_access"
  simplicity. **Applies to ALL projects, standard + internal.**
- Should `claude_access` even remain a **separate knob**, or fold into `cco_access`? (Maintainer
  raised elimination; preliminary view: **keep it** — B1 the repo-native `.claude` is not a `.cco`
  tree and has no `(G,Pc,Po)` mapping; folding loses that dimension. Re-examine with the coupling
  decision.)
- Does the config-editor `claude=all` default (A-V3) survive, or become `claude=repo` + a G-coupled
  B3?

---

## Session plan

```mermaid
flowchart LR
  V["Session A.0 — VALIDATE<br/>correctness + coherence of A.1/B.2<br/>vs ADR-0036/0044/0046"] --> A["Session A — config-editor access<br/>impl (ro,rw,none) default + G≥ro invariant<br/>+ INV-2 refinement + DOC5 follow-up"]
  A --> B["Session B — claude×cco coupling<br/>dedicated analysis → decision → impl"]
  B --> ADR["Extract validated decisions →<br/>new ADR + living design docs"]
  ADR --> E2E["e2e v2 acceptance (final design)<br/>+ push both branches from the Mac"]
```

1. **Validate** (first thing): walk A.1 + B.2 against the resolver, invariants, mount-gen, and
   output-scoping. Confirm the decisions resolve the problems AND are compatible with the current
   design — or specify the **design evolution** each requires (esp. INV-2 [A-V1]).
2. **Session A** (config-editor): implement WS-A once validated; tests; DOC5 follow-up; ADR-0044
   re-annotation.
3. **Session B** (separate): the claude×cco coupling analysis + resolution.
4. **Extract**: fold the validated, motivated decisions into a **new ADR** (refining 0036/0044/0046)
   and the **living design docs** (`design.md`, user guides).

## Decisions to confirm (carried from the maintainer dialogue, 2026-07-11)

- [x] Tutorial read-all overridable — **keep as-is** (verified).
- [ ] config-editor default `(ro,rw,none)` (project) / `(rw,none,none)` (global) / `edit-global`
  override / `edit-all` via `--all` — **confirmed by maintainer, pending [A-V1..A-V4] validation.**
- [ ] `G ≥ ro` invariant for config-editor (never blind) — **confirmed, pending validation.**
- [ ] INV-2 refined to a **conditional** project floor (Pc≥ro *iff* a current project is in scope) —
  **needs validation** (enables the honest `(rw,none,none)`).
- [ ] claude×cco: **cco bounds claude for in-`.cco` trees (B2/B3); B1 decoupled**; error/warn on
  conflict — **direction confirmed, dedicated Session B analysis needed** (esp. project-level b-i vs b-ii).
