# CLI Environment-Awareness

> Version: 1.4.0
> Status: Current — principle established with ADR-0042 (agent ↔ cco access); **output-scoping
> layer added with [ADR-0043](../decisions/0043-unified-cli-environment-access-scope.md)**;
> **full CLI-surface review complete (2026-07-02, §6)**; **central-gate property made explicit
> + [CLI-surface matrix](../reference/cli-surface-matrix.md) added (2026-07-07, §4)**;
> **base model → `(G,Pc,Po)` triple ([ADR-0046](../../configuration/agent-cco-access/decisions/0046-unified-cco-access-model.md))
> + enforcement via a privilege boundary, output-scoping demoted to defense-in-depth
> ([ADR-0047](../../configuration/agent-cco-access/decisions/0047-config-access-enforcement.md)) — design-intent, not yet implemented (2026-07-08)**
> Related: [ADR-0036](../../configuration/decentralized-config/decisions/0036-session-config-capability-model.md) (capability model — D4 wrapped-cco, D8 caller-context) · [ADR-0042](../../configuration/agent-cco-access/decisions/0042-agent-cco-interaction-model.md) (three-level interaction model) · [ADR-0043](../decisions/0043-unified-cli-environment-access-scope.md) (unified env & access-scope resolution) · [ADR-0046](../../configuration/agent-cco-access/decisions/0046-unified-cco-access-model.md) (`(G,Pc,Po)` model) · [ADR-0047](../../configuration/agent-cco-access/decisions/0047-config-access-enforcement.md) (enforcement — privilege boundary) · [agent ↔ cco access design](../../configuration/agent-cco-access/design.md) · user CLI reference [`cli.md`](../../../users/reference/cli.md)

---

## 1. Why this document exists

The `cco` CLI used to run in exactly one place: the user's **host**. Two decisions changed
that:

- **ADR-0036 D4** introduced a **wrapped `cco`** that runs *inside a session container*
  (container-operator mode), behind a default-deny whitelist shim, driven by the agent.
- **ADR-0042** made that wrapped `cco` a **primary channel** (Level B of the three-level
  model) and set the normal-session default to `cco_access=read-project` — so a wrapped
  `cco` is present in **almost every session**, not an edge case.

**Consequence — the entire CLI surface is now dual-context.** The *same* `cco` binary is
invoked both by a human on the host and by an agent inside a container. A verb that was
historically "host-only / user-facing" is now reachable by an agent. Environment-awareness
can no longer be an afterthought bolted onto a few commands — it is a **property of the
whole surface**.

## 2. The principle (normative)

> **Every `cco` command MUST determine the environment it runs in and behave correctly for
> that environment.** Host execution and container-operator execution are both first-class;
> neither may be assumed. When in doubt, a command defaults to the *safe* behavior for the
> container context (refuse + redirect to the host).

This is default-deny: a command reaches its real work in a container session **only** when it
has been explicitly classified as safe for that context (read within scope, or a path-free
write at an edit level). Everything else is refused with a "run it on your host" hint.

## 3. Detection signals (grounded)

All three live in `lib/paths.sh` / `bin/cco` and are the canonical way to reason about
context — do not re-derive it ad hoc:

| Signal | Location | Meaning |
|---|---|---|
| `_cco_caller_context` | `lib/paths.sh` | `host` \| `container-agent` — the D8 caller-context signal (`/.dockerenv` / `CCO_IN_CONTAINER`). |
| `_cco_container_operator` | `lib/paths.sh` | True **only** under the deliberate wrapped-cco mode: `CCO_CONTAINER_OPERATOR=1` **and** all three bucket overrides (`CCO_DATA_HOME`/`CCO_STATE_HOME`/`CCO_CACHE_HOME`) are absolute mount paths. Never inferrable from a plain agent env. |
| `CCO_CCO_ACCESS` | env (set by `cco start`) | The resolved access scope in-container (`read-project` … `edit-all`) — drives read-scope + write gating (ADR-0042). |
| `PROJECT_NAME` | env (set by `cco start`) | The current session's project — the "current project" signal that makes `project`-scoped output filtering possible in-container (ADR-0043). Empty on the host. |

## 4. Enforcement layers

**Permissions are enforced by a single central gate, upstream of every command.** In
container-operator mode `bin/cco` routes **all** verbs through one chokepoint —
`_cco_operator_shim` — **before** the real dispatcher runs any command body (grounded:
`bin/cco`, `if _cco_container_operator; then _cco_operator_shim …`). This is a deliberate
design choice: *unified preventive protection* rather than per-command permission checks.

- **Why central, not per-command.** A permission check re-implemented in each command
  drifts, is easy to forget on a new verb, and leaves the surface only as safe as its
  weakest command. One default-deny gate means a verb is **unreachable in-container until
  explicitly classified** — a *forgotten* verb fails safe (refused), not open. Permissions
  are therefore verified **before** execution, in one auditable place (the shim's
  classification table + the `lib/access-scope.sh` level→scope maps it consults, INV-E).
- **Division of labour — permissions vs command guards.** The gate owns *whether a verb may
  run here* (host-only vs read-scope vs write-scope). A command's own guards exist **only**
  for execution differences **intrinsic to that command** that a generic gate cannot
  express — output scoping (what a permitted read verb *shows*, §4b), secret masking,
  host-path hygiene, and sub-flag distinctions the coarse verb+subcommand gate cannot see
  (e.g. `remote add --token` refusing only the token half). These are *not* permission
  re-checks; the permission decision has already been made upstream.
- **Residual to watch.** The gate protects against a *forgotten* verb (default-deny) but not
  a *mis-classified* one (a write verb wrongly tagged read, or a wrong target scope) — such
  a verb would pass. The classification is centralized (good) but hand-maintained; the
  [CLI-surface matrix](../reference/cli-surface-matrix.md) makes it auditable, and
  `tests/test_operator_shim.sh` pins it.

Environment-correct behavior is then layered — a command must respect **all** layers that
apply to it, not rely on one alone:

```mermaid
flowchart TD
  IN["cco &lt;verb&gt; invoked"] --> D{"_cco_container_operator?"}
  D -- "no (host)" --> HOST["Normal host dispatch<br/>(first-run bootstrap, full surface)"]
  D -- "yes (container)" --> SHIM["_cco_operator_shim<br/>(default-deny whitelist)"]
  SHIM -- "host-only verb" --> REDIR["die: 'run it on your host' hint"]
  SHIM -- "read verb" --> SCOPE{"read scope ≥ required?"}
  SHIM -- "write verb" --> EDIT{"cco_access ∈ edit-*?"}
  SCOPE -- no --> REDIR2["die: needs read-global/all"]
  SCOPE -- yes --> BODY
  EDIT -- no --> REDIR3["die: needs an edit level"]
  EDIT -- yes --> BODY["command body"]
  BODY --> SELF["per-command self-checks:<br/>resolver guard · secret masking ·<br/>path_map gating · scope-aware help"]
```

1. **Central shim — `_cco_operator_shim` (`bin/cco`).** The first gate in container-operator
   mode. Default-deny: host-only verbs die with a hint; read verbs are gated by read scope
   (`template`/`remote list` need `read-global`, etc.); write verbs need an edit level. This
   is where a verb's *context classification* lives.
2. **Resolver guard — `_cco_resolver_guard` (`lib/paths.sh`).** Refuses host-path resolution
   inside a container (anti-in-container guard, ADR-0007), except the sanctioned operator
   mode with mounted buckets. Any command that resolves host paths is thereby host-only.
3. **Per-command self-checks.** Where a command does context-sensitive work it must self-check:
   - **Secret masking** — real secret files never reach the container (masked at mount).
   - **Host-path hygiene** — never print host paths beyond the gated `path_map`
     (`show_host_paths`); resolution stays host-side (ADR-0007 / INV-4).
   - **Host-path *consumption*** — a host path that legitimately reaches a container verb
     must be **translated onto its mount before it is used**, never tested or read as-is. See
     §4c: this is the layer B-DF1 fell through.
   - **Scope-aware help** — `usage()` / `--help` reflect the wrapped scope in operator mode:
     host-only verbs flagged `(host only — run on your host)`, verbs above the current level
     marked unavailable (ADR-0042 §4.3).

## 4c. Host paths a verb *consumes* — translate onto the mount (B-DF1)

§4b covers what a verb **shows**. This covers what a verb **acts on**. The two host-path rules
are easy to conflate and are different obligations:

| | Question | Rule |
|---|---|---|
| **Hygiene** (INV-4) | may I *print* this host path? | Only where `show_host_paths` permits. |
| **Consumption** (this §) | may I *test/read* this host path here? | Not in-container — translate to the mount first. |

> **A third, orthogonal host-path axis lives elsewhere — do not fold it in here.** This document
> owns *does this path exist in **this environment***. Since ADR-0051, a repo/extra_mount path also
> has a *which **project** does this label belong to* question (the same name may be a different
> resource per project). That axis — cwd default, explicit `--project`/`--all-projects`, declare
> the scope or return every match — is tracked as **FI-21** and, if ratified, belongs in the naming
> design tree. Two different questions that merely share the word "path": a verb can be perfectly
> environment-aware and still act on the wrong project.

The framework's internal maps are **host-side by construction**: the STATE index stores host
absolute paths, because it is the machine-local map the host resolver writes. Those paths are
**meaningless inside a session** — `cco start` bind-mounts each member at the flat WORKDIR path
`<workdir>/<name>`. So in a container:

> **A host path from the index must never be passed to `-d` / `-f` / a read.** It cannot exist,
> so the test does not report "missing" — it reports **nothing at all**, uniformly and silently.
> Translate it to the mount (`_cco_member_probe_path`, `lib/paths.sh`) and probe that.

**Why this needs its own rule rather than "it's obvious".** The failure is silent and
*plausible*: the code looks right, runs without error, and returns a well-formed answer that is
simply always wrong in one context. It has now produced two distinct defects from one root:

- **F1** (2026-07-02 surface review) — `config validate` flagged **every** index entry an orphan
  in-container and printed the user's host paths doing it. Resolved by reclassifying the verb
  **host-only**: its whole job is sanitising machine-local host state, which is only coherent
  host-side.
- **B-DF1** (found 2026-07-09, fixed 2026-07-16) — `cco project show` badged every mounted repo
  `[missing] [code-only]` + "N reference(s) unresolved". Host-only was **not** available as an
  answer here: R4 deliberately makes `project show` in-container introspection. The answer had
  to be translation.

That contrast is the substance of the rule: **when a verb consumes host paths, "make it
host-only" and "translate onto the mount" are both valid — pick by whether the verb's *purpose*
is in-container.** Sanitising machine-local host state is not; introspecting the session is.
A verb that is legitimately reachable in-container must translate, and translating is a
per-command self-check the central gate (§4) cannot make for it: the gate decides *whether* the
verb runs, never what a path *means* once it does.

**Where the translation belongs.** In the caller that still holds the resource **name** — the
name is what indexes the mount. Do not push it down into shared classifiers that take a ready
path (`_project_member_status`), and do not "fix" the index-reading primitives: their other
callers are host-only verbs (`join`/`forget`/`rename`) that must keep receiving the **real host
path** to act on. Translate at the edge, per context; leave the map alone.

## 4b. Output scoping — what a *permitted* read verb shows (ADR-0043)

Verb gating (§4) decides **whether** a verb runs in-container. It does **not** decide **what a
permitted read verb shows**. A verb that is allowed at `read-project` must still scope its
**output** to the current project — otherwise it leaks the full resource set, or (worse) shows
an empty result for an unmounted resource that the agent then mistakes for "does not exist".

This is a second, orthogonal dimension enforced by a single shared layer
(`lib/access-scope.sh`) so every command implements only its own differentiation logic:

- **Scope taxonomy (reuses §4's shim classes).** Two scope classes — the same ones the shim
  uses for verb gating — now applied to read **output**:

  | Kind | Scope class | Visible at `read-project` | Visible at `read-global` / `read-all` |
  |---|---|---|---|
  | project · pack · llms | **project** | current project (`PROJECT_NAME`) + its referenced resources | all |
  | template · remote | **global** | none (needs `read-global+`) | all |

  `global`-class kinds mirror the shim's existing gates (`template …`, `remote list` need
  `read-global+`). One taxonomy for both verb gating and output scoping — no parallel model.
  Rationale + the full module API in
  [ADR-0043](../decisions/0043-unified-cli-environment-access-scope.md).
- **Invariants.** Host-open (scoping engages only under `_cco_container_operator`); hidden ≠
  absent (a filtered command emits one standardized *count-only* notice on **stderr** telling
  the agent how to widen — a `read-global` session or the host); the STATE index stays the
  complete internal map. **Output-scoping is defense-in-depth, not the confidentiality control**
  ([ADR-0047](../../configuration/agent-cco-access/decisions/0047-config-access-enforcement.md),
  revising ADR-0043 INV-D): because the agent and the wrapped `cco` share a UID, a presentation
  filter alone cannot stop a raw `cat` of the internal store — confidentiality is enforced by a
  **privilege boundary** (a `cco-svc`-owned mode-0700 real-FS parent the `claude` user cannot
  traverse + a setuid helper enforcing `(G,Pc,Po)`). This layer scopes *output* on top of that
  boundary. (Design-intent; not yet implemented.)
- **Layer API.** `_env_in_scope <kind> <name> [owner]` (0/1), `_env_note_hidden <kind>`,
  `_env_flush_hidden_notice` (stderr), `_env_require_visible <kind> <name>` (graceful "not
  available at this scope" for `show`/detail verbs). Commands call these; they never re-derive
  context.
- **Awareness pairing.** Level A + the managed rule state that `read-project` gives a
  *project-scoped* view of `~/.cco` — a subset, not the whole store — so a hidden resource is
  never read as a missing one.

## 5. Checklist — adding or changing a `cco` verb

Any new or changed verb MUST answer, and wire, the following:

1. **Classify the verb for the container context**: host-only (spawns containers, resolves
   host paths, touches **credentials** or the personal-store git remote) · read (which scope:
   project / global / all) · write (which scope).
   > **Network carve-out (ADR-0036 D4).** "Touches the network" is *not* on its own a
   > host-only trigger. Sharing-repo fetches — `pack|template|llms install|update|import` —
   > are **write** verbs, allowed at an edit level (they clone public sharing repos into the
   > mounted store); only credential/remote-git ops stay host-only (`config push|pull`,
   > `remote set-token|remove-token`). Token-authed fetches simply degrade in-container (the
   > token bucket is never mounted), they are not refused by the shim.
2. **Wire it into `_cco_operator_shim`** with that classification (default-deny — an
   unclassified verb is refused in-container).
3. If it **resolves host paths** → it is host-only; rely on the resolver guard and add the
   host-only branch + hint.
3b. If it **consumes a host path** it did not resolve — anything read out of the STATE index
   (`_index_get_path`, `_effective_repo_mounts`, …) — decide **explicitly** which of the two
   answers applies (§4c), and write the choice down:
   - the verb's purpose is host-side machine-local state → **host-only** (precedent: `config
     validate`, F1);
   - the verb is legitimately in-container → **translate onto the mount** before any `-d`/`-f`/
     read (`_cco_member_probe_path`), in the caller that still holds the resource name
     (precedent: `project show`, B-DF1).
   > **Smell test.** Ask: *"in a session, does this path exist?"* If a `[[ -d "$p" ]]` on an
   > index path can reach a container, it is already wrong — it does not fail loudly, it just
   > answers "no" forever. Grep the verb for existence tests on anything index-derived.
4. If it **emits paths or reads config** → mask secrets, respect `show_host_paths` and the
   resolved read scope. Note this is a **separate** obligation from 3b — what you may *print*
   (hygiene, INV-4) is not what you may *test* (consumption). B-DF1 shipped with both wrong in
   the same function, each masking the other.
5. If it **lists or shows resources** → scope its **output** via the shared layer (§4b):
   `_env_in_scope` while iterating, `_env_note_hidden` on skip, `_env_flush_hidden_notice` at
   the end; `show`/detail verbs call `_env_require_visible` first. Never re-derive context.
6. If it **prints help** → keep it scope-aware in operator mode.
7. **Tests**: extend `tests/test_operator_shim.sh` (classification/scope) and the verb's own
   suite; add scoped-output assertions (§4b). Assert both host and container-operator behavior.

## 6. Full CLI-surface review — done (2026-07-02)

The principle above is applied incrementally as verbs are touched. The **output-scoping layer
(§4b) for the READ surface was pulled into workstream B2** (ADR-0043, step 4.5) because B2's
`read-project` mount narrowing made it necessary then.

**The dedicated review of the ENTIRE verb surface is complete** — every `cco` command was
audited against §2–§5, including the write and host-only verbs B2 did not touch. See the
findings report:
[reviews/2026-07-02-cli-surface-awareness-review.md](../reviews/2026-07-02-cli-surface-awareness-review.md).

Outcome — five findings, all resolved: `config validate` reclassified **host-only** (it read
the host-path STATE index and leaked host paths + reported wholesale false orphans
in-container); `remote add --token` now **refuses the token half** in a container (the STATE
token store is never mounted, so it wrote an ephemeral secret + a false "[token saved]");
`config save` gives a **clear "needs edit-global" message** on the read-only `~/.cco` mount at
edit-project; `llms remove` prints a **repo-relative** path; and the `usage()` host-only
annotation is documented as deliberately top-level (no drift). The network-write cluster,
host-only refusals, and the B2 read surface were confirmed correct.

**Amendment (2026-07-16) — the sweep missed the host-path *consumption* case.** The review found
F1 (`config validate`) and resolved it by reclassifying the verb host-only. It did not ask the
follow-on question — *which other verbs consume index host paths, and which of them cannot be
made host-only?* — so **B-DF1** (`cco project show` badging every mounted repo `[missing]`)
survived the audit and was found three days later by dogfood. The two are the same defect wearing
different clothes; only the remedy differs (§4c).

The gap was in the **checklist, not the sweep**: §5 covered host paths a verb *resolves* (→
host-only) and host paths a verb *prints* (→ hygiene), but never host paths a verb *consumes*,
so there was no question whose answer would have caught it. §4c + §5.3b now close it.

Take the audit's conclusion accordingly: the surface was swept against §2–§5 **as they read on
2026-07-02**. Re-verify verbs that read the STATE index against §4c specifically — the class is
demonstrated to survive a general review, because each instance looks locally correct.

Treat this document as the reference for any CLI change: new commands inherit the method (the §5
checklist) from day one — and when a checklist item is found missing, the fix is the item, not
just the bug.
