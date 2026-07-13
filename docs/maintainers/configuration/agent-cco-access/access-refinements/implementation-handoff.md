# WS-B implementation handoff — `claude_access` concordant model (ADR-0049)

> **▶ START A FRESH IMPLEMENTATION SESSION FROM THIS FILE.** Self-contained: it carries
> the decided model, every reference doc, the exact code anchors, the ordered task plan,
> the must-verify items, and the test/changelog/git rules. Analysis + Design are **DONE**;
> this session **implements** ADR-0049. Language: reply in Italian (user rule); code
> comments/docs in English.

**Branch**: `feat/config-access/claude-access-model` (already created, from the WS-A tip;
**NOT pushed** — push from the Mac at the end). The 4 design commits are already on it
(ADR-0049, WS-B analysis, design.md §4bis, ADR-0027/0048 annotations). Continue on this
branch.

**Self-development caveat** (project CLAUDE.md): edits to `lib/*.sh` are **NOT live** in the
running session — they take effect only after `cco build` + a fresh `cco start`. Implement +
unit-test with `./bin/test`; the live/e2e acceptance happens after a Mac-side `cco build`.

---

## 0. What to read first (canonical, in order)

1. **[ADR-0049](../decisions/0049-claude-access-concordant-model.md)** — THE decision. The
   axis triple, concordant defaults, presets, warn, functional floor, extra_mount, schema,
   coverage matrix. **Everything below implements this.**
2. **[design.md §4bis](../design.md)** — living target for the Axis-B model; also §7
   (init-workspace) and §8 (config-editor).
3. **[WS-B analysis](analysis/ws-b-claude-cco-coupling.md)** — the *why* (taxonomy,
   non-expressibility proof, code-grounded gaps, rejected paths). Read if a design choice
   seems arbitrary.
4. **[ADR-0046](../decisions/0046-unified-cco-access-model.md)** — the cco `(G,Pc,Po)` model
   whose resolver + grammar you **reuse** for Axis B. §2 (auto-promotion), §5 (scalar|map
   grammar), §7 (single-source resolver).
5. Context (frozen history, for reference): **[ADR-0027](../../decentralized-config/decisions/0027-config-editor-builtin-and-edit-protection.md)**
   (P17 — now reversed; the dropped `settings.local.json` overlay to re-introduce),
   **[ADR-0048](../decisions/0048-config-editor-min-privilege-refinement.md)** §4
   (config-editor claude-follows-G — now generalized), **[ADR-0047](../decisions/0047-config-access-enforcement.md)**
   (Axis-A privilege boundary — **untouched** by this work).

## 1. The model in one screen (implement exactly this)

`claude_access` (Axis B) → a **per-tree axis triple**, lattice **`{ro, rw}`** (no `none`):

| Axis | Tree | Container path | Mirrors cco | Default (unspecified) |
|---|---|---|---|---|
| `Cg` | B3 `~/.cco/.claude` | `/home/claude/.claude` (+ `/home/claude/.cco/.claude`) | `G` | `= G` |
| `Cp` | B2 `<repo>/.cco/claude` | `/workspace/.claude` | `Pc` | `= Pc` |
| `Co` | other projects' `.cco/claude` | (cross-project only) | `Po` | `= Po` |
| `Cr` | B1 `<repo>/.claude` | `/workspace/<repo>/.claude` | — | **`ro` always** |

- **Defaults derive from cco** when Axis B is unspecified: `Cg=G, Cp=Pc, Co=Po, Cr=ro`
  (cco `none` collapses to `ro` on this lattice — a non-writable tree is still readable).
- **Grammar = identical to cco** in all three sources (CLI `--claude-access`, `project.yml`
  `access.claude`, `~/.cco/access.yml` `claude`): **scalar preset** OR **granular map**.
  Presets (fixed triples): `none`=`(ro,ro,ro,ro)` · `repo`=`(rw,rw,ro,ro)` · `all`=all-rw.
  Map keys `{repo,current,global,others}`; omitted keys **derive from cco** (not the invariant
  floor — that's the one difference from cco's promotion).
- **Warn (P2) iff** resolved `Cp`/`Cg`/`Co` is *more permissive* than the cco-concordant
  default (i.e. rw where cco is not). `Cr` never warns; tighter-than-cco never warns. Session
  still starts (never a refusal).
- **Functional-write floor**: keep rw regardless of axes — global `~/.claude/settings.json`
  (already), and a **rw child overlay** for `settings.local.json` at B2 (`/workspace/.claude/
  settings.local.json`) and B1 (`<repo>/.claude/settings.local.json`). Everything else
  (`CLAUDE.md`/`rules`/`agents`/`skills`, project/repo `settings.json`) follows the axes.

**Do NOT**: clamp/bound one knob by the other (rejected — it's defaults + warn, not
enforcement clamp); add a `/init` carve-out; touch ADR-0047's Axis-A boundary; do the
init-workspace re-analysis (separate — just leave the design's re-analysis flag).

## 2. Code anchors (verified this session, `lib/`)

**Resolver — `lib/cmd-start.sh` `_start_resolve_access` (`:217-354`)**
- `_ACCESS_CLAUDE_VALUES="none repo all"` (`:175`) — redefine as preset sugar; the enum
  validator (`:333-334`) must accept preset **or** map.
- claude resolution today: `_access_pick` scalar only (`:332`). Replace with a triple
  resolver (reuse `_cco_promote_triple`/`_cco_resolve_access` pattern from `access-scope.sh`).
- **Remove** the config-editor bespoke `d_claude follows G` (`:329-331`) — the general
  cco-derived default subsumes it (ADR-0049 §8).
- cco map read (project.yml) is the template to mirror for claude: `_mg/_mc/_mo` at `:296-300`.
- Global `access.yml` read (`:274-278`) is **scalar-only** for both `claude` and `cco` →
  extend to the granular map (ADR-0049 §9).

**cco resolver to reuse — `lib/access-scope.sh`**
- `_cco_axis_rank` (`:81`), `_cco_promote_triple` (`:158`), `_cco_resolve_access`,
  `_cco_triple_label`, `_cco_triple_preset` (`:105`). Build the Axis-B analogues (or
  parameterize): Axis B is simpler (2-value lattice, no INV-2/3/4 floors — only the
  cco-derived default fill + `Cr=ro`).

**Mount-gen — `lib/cmd-start.sh` `_start_generate_compose`**
- `_b2_mode` / `_b3_auth_mode` / `_b1_ro` (`:1205-1210`) → derive per-axis from
  `(Cr,Cp,Cg,Co)` instead of the coarse `claude_access` case.
- B3 mounts `:1240-1245` (settings.json always-rw `:1241`); B3-inside-store re-overlay
  `:1314-1316`. B2 mount `:1251`. B1 `:ro` overlay `:1400-1406`. A1 `<repo>/.cco :ro` overlay
  `:1415-1421`. Extra_mounts `:1456-1467`.
- **Add**: `settings.local.json` rw child overlays (B2/B1); recursive `.claude`/`.cco`
  detection (bounded `find`) for repos **and** extra_mounts; extra_mount nested-config
  strict-`ro` default + `config_access_policy` (`ro`|`project`|`write`).

**Schema / paths**
- `templates/project/base/project.yml` — `access:` block (`:4-22`, currently documents
  `claude: none|repo|all` scalar). Add the `access.claude` **map** form + document it (mirror
  the existing `access.cco` map note). Add `extra_mounts[].config_access_policy`.
- `_cco_access_file` (`lib/paths.sh:103`, `~/.cco/access.yml`), `_cco_languages_file` (`:85`).
  **Scaffold `~/.cco/access.yml` commented at `cco init`** (net-new — no current scaffold
  found; find the store-setup in `lib/cmd-init.sh`). Document the granular escape.

**Tests** — `tests/test_access_resolution.sh` (690 lines), `tests/test_config_editor.sh`
(371). Run all with `./bin/test`.

## 3. Ordered task plan (commit atomically per unit; keep suite green)

Recommended decomposition (the user offered to review between sub-steps — **pause after each
numbered group** if the user wants checkpoints; otherwise proceed):

1. **Axis-B resolver + grammar** — the triple type, preset sugar, granular map parse,
   cco-derived default fill, `Cr=ro`; wire into `_start_resolve_access`; remove config-editor
   `d_claude` branch. Unit-test the resolution matrix (ADR-0049 coverage table) +
   preset/map/partial + the warn predicate.
2. **Schema parse** — `project.yml access.claude` map; `~/.cco/access.yml` granular (claude
   **and** cco); `access.yml` commented scaffold at init; template docs.
3. **Mount-gen per-axis** — `_b1/_b2/_b3` from `(Cr,Cp,Cg,Co)`; `settings.local.json` rw
   overlays (B2/B1); config-editor still resolves correctly (regression: `test_config_editor`).
4. **extra_mount + recursive detection** — strict-`ro` nested-config default;
   `config_access_policy` (`ro`|`project`|`write`); recursive `.claude`/`.cco` overlay for
   repos + extra_mounts. Tests for each policy value + a nested fixture.
5. **Warn + docs sweep** — the discordance warning (P2); `cco whoami` reflects the Axis-B
   triple; **changelog** entry (behaviour change: `.claude` authoring default → read-only,
   "requires `cco build`"); user `cli.md` + CLI-surface matrix rows; verify no migration
   needed (additive schema — confirm `project.yml` schema_version unchanged).

## 4. Must-verify (against real Claude Code behaviour, task 3)

- Confirm the **functional-write floor** set: does Claude Code (under
  `--dangerously-skip-permissions`, in-container) write anything under project/repo `.claude`
  besides `settings.local.json`? (e.g. `.claude/worktrees/` for background sessions — likely
  inert in cco; check `code-claude` llms.) Carve only what breaks functioning; keep
  preference/authoring governed. See ADR-0049 §5.
- Confirm removing config-editor's `d_claude` branch leaves `test_config_editor` green (the
  general derivation must reproduce project→`Cp=rw,Cg=ro`, edit-global→`Cg=rw`, edit-all→`Co=rw`).

## 5. After implementation (from the Mac)

1. `cco build` + fresh `cco start` → live dogfood (normal session default `.claude` read-only;
   `--claude-access repo` re-opens B1/B2; explicit discordance warns; extra_mount policies).
2. **e2e v2 acceptance** against the final design (the whole access model is now settled).
3. **Push all branches from the Mac** (NOT pushed): `feat/config-access/e2e-review`,
   `feat/config-access/config-editor-access` (WS-A), `feat/config-access/claude-access-model`
   (WS-B). Then merge → `develop` per the project git-workflow (feature → develop; never
   direct to main/develop mid-work).

## 6. Rules recap (project + global)

- **Git**: three-branch workflow (`main`/`develop`/`feat/*`); feature → develop only; atomic
  commits leaving the suite green; commit trailer `Co-Authored-By: Claude <noreply@anthropic.com>`.
- **Docs**: living design rewritten in place (no "SUPERSEDED" banners); ADRs are immutable
  history (forward-annotate). Mermaid required in written `.md` (not terminal replies).
- **Update system**: additive change → `changelog.yml` + base template; schema-breaking →
  migration (this is additive — no migration expected, but verify).
- **Workflow**: this is the Implementation phase; if the design needs to change mid-build,
  **pause and discuss** — don't drift from ADR-0049.

## 7. Memory pointer

Workstream state: memory `access-refinements.md` (WS-B section = DESIGN DONE; this file is
the impl entry). Parent context: `roadmap-next.md`, `hardening-v2-impl.md`.
