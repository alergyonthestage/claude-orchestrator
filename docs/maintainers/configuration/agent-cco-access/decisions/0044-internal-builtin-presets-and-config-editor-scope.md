# ADR 0044 — Internal built-in session presets & config-editor scope default

**Status**: Accepted (2026-07-07) — ratified by the maintainer in a design session
refining the shipped access model before the e2e re-validation. **Refines
[ADR-0042](0042-agent-cco-interaction-model.md) §8** (config-editor UX) and its preset
decisions (§Decision, D6/§9): the config-editor *default scope* is flipped from
`edit-all`-broad to minimum-privilege, and the tutorial preset is set to `read-all`.
ADR-0042 stays Accepted/frozen; its §8 is forward-annotated to point here.

**Deciders**: maintainer (set the two-regime framing, the read-only-vs-write
discriminator, the config-editor default flip, tutorial=read-all); implementer
(code-grounding + consequences).

**Design**: [`../design.md`](../design.md) §8 (living doc — rewritten to this truth).

## Context

ADR-0042 §8 made `cco start config-editor` default to a **broad `edit-all`** surface
(every resolvable project's `<repo>/.cco` + the personal store), with `--project`
narrowing. Two things pushed a reconsideration:

1. **Least-privilege inconsistency.** `edit-all` is the *widest and most dangerous*
   scope (write across **every** project's committed config). Making it the silent
   default for a bare `config-editor` contradicts the principle applied everywhere else
   in the model — normal sessions default to `read-project`, not `read-all`; the e2e fix
   (ADR-0043) made the whole read side minimum-by-default. A write-capable session
   defaulting to the maximal blast radius is the one place that broke the rule.
2. **The internal built-ins are already "special".** tutorial and config-editor are
   framework-defined **named** sessions, not cwd-referencing `cco start <project>`. They
   already carry preset knobs that deviate from the standard model, and config-editor
   already has a structural exception (its *started project* is always `config-editor`,
   while the projects it may **edit** are a separate set carried by `CCO_CONFIG_TARGETS`,
   ADR-0042 D9 — so *started-project ≠ scoped-config-project*). This "special session"
   nature was implicit; it deserves to be a stated principle so each deviation is
   **motivated**, not accidental.

## Decision

### 1. Two regimes — standard projects vs internal built-ins

- **Standard projects** follow the **uniform scope model** (ADR-0036/0042/0043):
  default **minimum privilege** (`claude=repo`, `cco=read-project`, `show_host_paths=on`);
  flags widen (`--cco-access read-global|read-all|edit-*`) or narrow (`none`). The
  *started* project and the *cwd* project coincide.
- **Internal built-ins** (tutorial, config-editor) are **special sessions that define
  their own explicit preset rules and exceptions**, each **motivated** by the session's
  purpose. They MAY deviate from the standard model; the deviation and its rationale are
  documented at the preset. The governing discriminator is **read-only vs write**:
  - a **read-only** built-in may safely default to a **broad read** scope (full context,
    no mutation risk);
  - a **write-capable** built-in MUST default to **minimum privilege** and require an
    explicit flag to widen.

### 2. tutorial — `read-all` hardcoded (read-only teacher)

The tutorial defaults to **`claude=none`, `cco=read-all`, `show_host_paths=on`**
(previously `cco=read-project`). Rationale for the deliberate deviation from the
standard `read-project` default:

- **Read-only** — no write verb is reachable, so there is **no accidental-modification
  risk** from the broad scope.
- **Pedagogically complete** — the tutorial's job is to reveal the user's whole cco
  world (their projects, packs, templates, llms, remotes) and teach the CLI hands-on. At
  `read-project` the tutorial project (empty `repos`, no packs/llms) shows **essentially
  nothing** and emits "hidden by scope" notices — the *least* useful default. `read-all`
  gives full context immediately.
- **Low sensitivity + defense-in-depth** — cco config content is not particularly
  sensitive, it is the user's own single-tenant machine, and exfiltration paths are
  already constrained by the docker-socket proxy + limited network. The `read-all`
  information-disclosure concern (which motivates minimum-default for *automated work
  sessions*) does not apply to a human-driven, read-only learning session on one's own
  machine.
- `--cco-access` remains available to *narrow* for demonstration, but is **discouraged**
  for the tutorial (documented as such). (Whether to hard-disable the flag for the
  tutorial preset is left to implementation — default is: available but discouraged.)

### 3. config-editor — minimum-privilege default, explicit widening (write-capable)

Because config-editor **writes** config, it takes the opposite default from the
tutorial. `cco start config-editor` no longer defaults to `edit-all`:

| Invocation | Editable config surface (mounted rw) | Resolved `cco_access` |
|---|---|---|
| `cco start config-editor` **in a project cwd** | `~/.cco` + **the cwd project's** `<repo>/.cco` | edit-project |
| `cco start config-editor` **outside any project** | `~/.cco` **only** (no project trees) | edit-global |
| `cco start config-editor --project <name>` (repeatable) | `~/.cco` + that project's `<repo>/.cco` **+ its repos** (repo-aware authoring, ADR-0042 §8) | edit-project (targeted) |
| `cco start config-editor --repo <name>` | above + one resolvable repo | (as above) |
| `cco start config-editor --all` **or** `--cco-access edit-all` | `~/.cco` + **every** resolvable project's `<repo>/.cco` (no repos) | edit-all |

> **Forward annotation (ADR-0046 ladder, implemented 2026-07-11).** The **"Resolved `cco_access`"**
> column above says `edit-project` for the in-project / `--project` rows. When ADR-0046 redefined
> the preset ladder, `edit-project` became `(none, rw, none)` — `G = none`, so it can **no longer
> write `~/.cco`**. But the "Editable config surface" those rows intend (`~/.cco` **+** the project's
> `.cco`) is exactly `edit-global` `(rw, rw, none)` under the new ladder. So the shipped preset
> resolves project mode to **`edit-global`**, not `edit-project` (the config-editor targets are the
> `current`/`Pc` axis via `_env_is_current_project`; other projects stay `Po = none`). `edit-all`
> and the outside-a-project `edit-global` rows are unchanged. An explicit `--cco-access edit-project`
> still works (writes only the project, guarded to require a target). See `lib/cmd-start.sh`
> `_start_resolve_access` and the CLI-surface matrix preset table.
>
> **Why not keep `edit-project` for project mode?** (Reconsidered + rejected 2026-07-11, maintainer
> confirmed edit-global.) The tempting reading — "`edit-project` mounts the project-referenced
> globals rw, and `config save` is allowed for those" — is **not expressible in this model**.
> ADR-0046 §7 makes global **write authority uniform on `G`**: writing *any* `~/.cco` resource
> (referenced pack included) or `config save` requires `G = rw`. The "referenced globals ride with
> `Pc`" rule is **read-visibility only** (they mount `ro` under `G = none` — `cmd-start.sh:1212-1230`).
> A per-referenced-resource *write* flavour is exactly ADR-0046's **rejected Model α** (the 4-value
> `G`). So `edit-project` config-editor would edit *only* the project's `<repo>/.cco`, with `~/.cco`
> read-only and `config save`/pack-authoring **refused** — which breaks config-editor's core purpose
> (authoring packs/templates/global config). `edit-global` is therefore the least privilege that
> keeps the tool functional; the meaningful min-privilege boundary (`Po = none`, don't touch *other*
> projects) is already enforced.

- **Outside-a-project default is global-only (option b), not edit-all-with-prompt.** cco
  widens access via **explicit flags**, never an interactive "are you sure" prompt
  (consistent with the rest of the CLI; prompts break automation).
- **`--all` is now an explicit widener**, not the old broad default. It (or the
  equivalent `--cco-access edit-all`) is the *only* way to reach the every-project
  surface.
- **The started ≠ cwd exception is explicit.** For config-editor the *started project*
  is always `config-editor`; "edit-project scope" means **the cwd project's `.cco`**,
  which is a different project. For a standard session these coincide; for config-editor
  they do not. This asymmetry is a documented property of the built-in, surfaced to the
  agent via `CCO_CONFIG_TARGETS` (D9) — the agent introspects the *target*, not
  `PROJECT_NAME`.

## Alternatives considered

- **Keep config-editor `edit-all`-broad by default (ADR-0042 §8 as-is).** Rejected: the
  widest write scope as a silent default violates least-privilege, the one place the
  model broke its own rule. Its convenience (edit any project without a flag) is
  preserved behind the explicit `--all`.
- **Outside-a-project → edit-all + interactive confirmation (option a).** Rejected: cco
  has no other interactive access prompt; it widens via explicit flags. A prompt also
  breaks non-interactive/scripted starts.
- **tutorial → `read-global`.** Considered (full store, hides other projects — the
  read analog of "broadest is explicit"). Rejected in favour of `read-all` because the
  tutorial is read-only and single-tenant: the only thing `read-all` reveals beyond
  `read-global` is the user's *own* projects, which is precisely the useful onboarding
  context, at no write risk. The "broadest-is-explicit" rule is a *write*-side and
  *automated-session* guard; it is deliberately not imposed on the read-only teacher.
- **tutorial → keep `read-project` / `none`.** Rejected: `read-project` shows the empty
  tutorial project (least useful); `none` breaks `cco docs` (refused at `none`, R6) and
  the hands-on "run cco commands" teaching.

## Consequences

- **Positive**: least-privilege is now consistent across *every* default (standard +
  write-capable built-in); the widest scopes (edit-all, all-projects) are always an
  explicit opt-in; the tutorial finally shows a complete, notice-free teaching surface;
  the "internal built-ins define their own motivated preset rules" principle makes future
  built-ins/exceptions principled rather than ad hoc; the started ≠ cwd asymmetry is
  documented, not a trap.
- **Negative / trade-offs**: config-editor users who relied on the bare command editing
  any project must now pass `--all` (a behaviour change — documented; changelog on
  implementation). The tutorial preset deviates from the uniform model — acceptable and
  explicitly motivated (read-only teacher).
- **Implementation** (later phase, not in this ADR): change the tutorial preset to
  `read-all` and the config-editor preset/target resolution
  (`_start_resolve_access`, `_start_collect_config_editor_targets` in `lib/cmd-start.sh`)
  to the cwd-based minimum-privilege default with `--all` as the explicit broad widener;
  update `CLAUDE.md` + user docs at the phase that makes it true (shipped-behaviour docs
  — documentation-lifecycle rule); changelog entry ("requires `cco build`").
- **Supersession**: refines ADR-0042 §8 D2 + the tutorial preset in ADR-0042 §Decision;
  ADR-0042 is forward-annotated. Feeds the CLI-surface matrix (config-editor + tutorial
  rows) and the e2e handoff v2 acceptance criteria.
