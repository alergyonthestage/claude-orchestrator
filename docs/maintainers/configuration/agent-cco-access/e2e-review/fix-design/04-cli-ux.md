# 04 — Operator-Shim UX & Packaging (R9 + R10)

> The shim's refusal/help layer and one packaging gap. Mostly implementation
> polish, plus two ratified conventions (help filtering D7, exit codes D8) and one
> micro-design (`--help` for host-only verbs).

## R9 — Model the refusal-case taxonomy

**Cause.** A single default-deny `*)` (`bin/cco:298`) conflates five distinct
verb-states into one "not available in a container session. Run it on the host"
message. `$host_hint` (`:222`) is correct only for *actual* host-only verbs.

**The five cases** (currently all fall through to one branch):

| Case | Example | Correct response |
|---|---|---|
| Unknown verb | `cco whoami`, `cco bogus` | "unknown cco command — see `cco help`" (exit `1`) — never "run on host" |
| Host-only verb | `cco start`, `cco resolve` | "host-only — run on your host" (exit `2`) |
| Removed alias (ADR-0029) | `cco project list`, `cco pack list` | "was removed — use `cco list <kind>`" (exit `2`) |
| Bare namespace | `cco project`, `cco pack` | print scope-aware sub-usage (exit `2`) — **not** a host redirect |
| Informational `--help` | `cco start --help`, `cco pack --help` | show usage, host-only flagged; never refuse |

**Design.**
- **Enumerate the known-verb set** in the shim so *unknown* is distinguishable from *host-only*. Unknown → "unknown cco command" (exit `1`). This removes the "run `cco whoami` on the host" misfire (NEW-1) and is what makes the F4 verb (`02`) resolvable rather than default-denied.
- **Bare-namespace** (`cco project|pack|llms|template` with no sub): print the scope-aware sub-usage (the reachable subcommands at this level), not a refusal. Fixes the `'cco project '` trailing-space cosmetic bug too (the message must use `${sub:+ $sub}`, not `$cmd` alone).
- **Removed aliases**: wire `cco project list` into the same ADR-0029 redirect the other namespaces get (`cmd-project` host dispatch `:390`) — the shim currently lets `pack list` *execute* and default-denies `project list`; both should redirect to `cco list <kind>` (exit `2`). Single wiring point with R3's dispatcher (`01-scope-model.md §7`).
- **Header recomputation** (S6-04): the operator-mode usage header (`bin/cco:168`) is static text with only the level substituted. Recompute the caveats from the resolved level so `edit-all` doesn't recite "write verbs need an edit level; template/remote need read-global" when nothing is gated. Derive from `01`'s `read_scope`/`write_scope`.

**F5 confirmed resolved** — `cco start --help` no longer prints empty; it refuses
consistently. Only the `--help`-refusal residue (below) remains.

### D7 — In-container help filtering (ratified)
- **Host** `cco help`/`cco --help`: unchanged, complete, no host-only notes.
- **In-container, default**: filtered to verbs runnable at the current `cco_access` (host-only and above-`read_scope`/`write_scope` verbs omitted). A one-line warn: `"N host-only verbs hidden — run 'cco --help --host' to list them."`
- **In-container `cco --help --host`**: full list, host-only verbs flagged `(host only — run on your host)`.
- **`<cmd> --help`** (any verb, incl. host-only): always shows usage — for a host-only verb, the host usage flagged `(host only — run on your host)`. `--help` is informational, never an operation (ADR-0042 §4 "shown but flagged"). Fixes S3-6/S7-04.
- Rationale: reduces the agent↔cco context in-container; feeds the maintainer CLI reference (overview §6).

### D8 — Exit-code convention (ratified)
Audit every shim/CLI refusal/error/degrade path to:
- `0` — success or graceful degrade (scope-filtered, "not here at this scope").
- `2` — refused by policy (needs wider `cco_access`, host-only, removed alias, bare namespace).
- `1` — actual error (unknown verb, missing file, parse error).

Fixes S8-7 (`cco docs` 1 vs `cco docs concepts` 0; `start --help` 1 vs `new --help`
0; `cco list pack` error exit 0; `_env_require_visible` refusals exit 0 → these
become exit `2` where they are policy refusals, `0` only for true graceful
degrade). Documented in the maintainer CLI reference.

```mermaid
flowchart TD
  I["cco &lt;cmd&gt; (in-container)"] --> K{known verb?}
  K -- no --> UNK["unknown command · exit 1"]
  K -- yes --> H{host-only?}
  H -- yes, --help --> FH["show host usage, flagged"]
  H -- "yes, invoke" --> HO["host-only refusal · exit 2"]
  H -- no --> RA{removed alias?}
  RA -- yes --> RED["redirect to 'cco list &lt;kind&gt;' · exit 2"]
  RA -- no --> BN{bare namespace?}
  BN -- yes --> SU["scope-aware sub-usage · exit 2"]
  BN -- no --> SCOPE["scope/write gate (01) → run or refuse (exit 2)"]
```

## R10 — Bake `docs/` into the image

**Cause.** `Dockerfile:140-143` bakes `bin/lib/templates` but **not** `docs/`;
`cmd-docs.sh:12` hardcodes `$REPO_ROOT/docs/users` → `/opt/cco/docs/users`, absent
in the image → `cco docs` fails in **every** session (🔴 for the tutorial, whose
"learn by doing" relies on it). Pure packaging gap.

**Design.** `COPY docs/users /opt/cco/docs/users` in the Dockerfile (the npm
package already ships only `docs/users`, ADR-0037 D3 — the user-facing subset,
which is exactly what agents should see). No `cmd-docs.sh` change needed; the
hardcoded path then resolves. The review's `/cco-docs` bind-mount is a separate
concern (human reading of design specs), not a substitute — `cco docs` must work
in every session, mount or not.

**Edge case.** Confirm `docs/users` is the correct in-image root and that no
`cco docs <topic>` path escapes it. Exit codes for `cco docs` failures align to D8.

## Consolidated fix loci
| Root | Primary loci |
|---|---|
| R9 | `bin/cco:166-182,298` (known-verb set, 5-case dispatch, header recompute, help filtering) · `cmd-*.sh` (exit-code audit) |
| R10 | `Dockerfile` (`COPY docs/users`) |
