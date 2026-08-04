# ADR 0045 — Host-maintained session running registry (in-container running-awareness)

**Status**: Accepted (2026-07-07) — direction ratified by the maintainer during the
pre-revalidation design pass; **build scheduled pre-review** (before the e2e access v2).
Backlog item **DI1** (`../../configuration/agent-cco-access/e2e-review/pre-revalidation-backlog.md`).

**Deciders**: maintainer (chose the registry model over an unfiltered docker path, and the
cco_access-gated visibility); implementer (code-grounding + reconciliation design).

**Related**: [ADR-0043](../../cli/decisions/0043-unified-cli-environment-access-scope.md)
(access-scope output layer — the visibility gate reused here) · socket-proxy design
([`../../security/design/design-socket-proxy.md`](../../security/design/design-socket-proxy.md))
· docker design ([`../design/design-docker.md`](../design/design-docker.md)) · the R1
`cco.project` label (agent↔cco e2e fix).

> **Forward annotation (implementation, 2026-07-10 — refined by
> [ADR-0047](../../configuration/agent-cco-access/decisions/0047-config-access-enforcement.md)).**
> This ADR predates the ADR-0047 privilege boundary. Its §2 "bind-mounted **read-only**
> into sessions" assumed the pre-0047 model where confidentiality rode on
> `access-scope.sh` output-gating. But the marker **filenames are project names** — the
> S1-class confidential data ADR-0047 closed: a claude-readable `:ro` mount would let `ls`
> enumerate every project, re-opening the leak. **Reconciliation as built:** the `running/`
> dir mounts `:ro` **under the cco-svc privileged root**
> (`/var/lib/cco-internal/state/cco/running`), NOT at a claude-readable path. In-container it
> is read **only inside the already-elevated `cco __store list/show`** (cco-svc can traverse
> the boundary), with cross-project visibility still gated by `_env_in_scope` row-scoping —
> so the intent of §2 (access-gated visibility) is preserved while the confidentiality is
> enforced by the boundary, not by output-scoping alone. The claude user cannot traverse the
> 0700 root, so no raw enumeration. No rebuild: the mountpoint auto-creates under the root.
> ⚠ **Qualified 2026-07-21 (e2e v3 cycle-1.1 / S1).** "The mountpoint auto-creates under the
> root" holds here **because `running/` is a DIRECTORY bind** — the runtime's auto-created
> ancestor is then replaced by the mount itself. The sibling STATE members that crossed as
> **file** binds hit the opposite outcome: their parent stayed a runtime-created `root:root`
> dir that `cco-svc` cannot create in, which was v3's blocking root R1
> (`design-docker.md` §1.2.2.1). This registry is behaviourally unaffected, and the shape that
> saved it is now an invariant rather than an accident: **INV-STATE** pins the allow-list
> `{shared, running}`, and `entrypoint.sh` owns `state/cco` to `cco-svc` at every start. Do not
> convert `running/` to per-marker file binds.
> Also: the marker lifecycle does **not** depend on `cco stop` (B-DF3) — the blocking `cco
> start` owns it (mark pre-run, unmark post-run), and host-side reconciliation is the primary
> reaper. See `feat/config-access/e2e-review` commits `95eb8b5`/`f08bbf2`.

## Context

`cco list project` / `cco project show` report a project's **running status** via
`_cco_session_running` (`lib/utils.sh`), which runs `docker ps --filter
label=cco.project=<name>`. **Host-side this is correct** (the daemon sees every sibling
container). **In-container it is not**, for two independent reasons:

1. **The socket may be absent.** A project with `mount_socket: false` (e.g. the tutorial,
   config-editor) has no docker socket in-session — the query returns nothing.
2. **The proxy scopes visibility by design.** When the socket *is* mounted, the
   cco-docker-proxy filters the daemon API to the **session's own** container
   (name/label constrained — the security boundary that stops an agent enumerating or
   touching *other* projects' containers). So `docker ps` in-container sees only the
   current project.

Net effect: from inside a session, every project **other than the current one** is
reported `stopped` even when it is running in another host terminal (observed with a
`config-editor` session not seeing a running project). This is a **false negative**, not a
logic bug — the information is simply not reachable through the (correctly) restricted
in-container docker channel.

**Key framing.** The docker proxy is the **wrong layer** to govern the *CLI's*
project-visibility. A session's knowledge of *which other projects exist / run* is already
a **`cco_access`** concern (the ADR-0043 scope taxonomy: `read-project` → current only;
`read-global`/`read-all` → others). The proxy exists for **agent container-security**
(manipulating containers), not for CLI status introspection. These must not be conflated.

## Decision

Introduce a **host-maintained "running sessions" registry in STATE**, read (not written)
by in-container sessions, with cross-project visibility **gated by the existing
access-scope layer** — not by the docker channel.

### 1. The registry (STATE artifact)

- A directory under STATE — `<state>/cco/running/` — holding one **marker per running
  session**, keyed by the `cco.project` **label** (the R1 session identity) — e.g.
  `<state>/cco/running/<project>` containing the container id(s) + start metadata.
- **Writers are host-side, on lifecycle transitions:**
  - `cco start` creates the marker after the container is up.
  - `cco stop` removes it.
- **Liveness reconciliation (host-side).** On any host read (`cco list`, `cco project
  show`, `cco start`, `cco stop`) the registry is reconciled against `docker ps` (full
  host visibility): markers with no live container (crash, `docker kill`, host reboot) are
  pruned. The registry is a **cache of docker truth**, never the source of truth
  host-side — docker remains authoritative on the host (no behaviour change to host UX).

### 2. In-container consumption

- The registry **directory** is bind-mounted **read-only** into sessions. Being a live
  dir bind-mount, host `cco start`/`stop` events on other projects appear **near-live**
  in-session (no snapshot staleness between mount and read).
- In-container, `_cco_session_running` (and the `cco list` / `project show` status column)
  reads the **registry**, not the scoped docker daemon.
- **Visibility is gated by `lib/access-scope.sh`** (the same layer that scopes all read
  output, ADR-0043): at `read-project` a session sees the running status of the **current
  project only**; at `read-global`/`read-all` it sees other projects too (the `project`
  kind is `read-all` for *other* projects — identical taxonomy, one model). Anything hidden
  → the standard count-only stderr notice (INV-B). No new visibility model.
- In-container reconciliation is **not** possible (no full docker) — a session reads the
  host-maintained view as-is. Residual staleness (a crash between host reconciliations)
  is bounded and self-heals on the next host command.

### 3. Interim fallback (B4)

Until the registry ships, and afterwards for any session where the registry is
absent/unmounted, in-container status **degrades to `unknown`** — never a false `stopped`
(pre-revalidation fix B4). B4 and this registry are complementary: B4 removes the lie, the
registry supplies the truth.

## Alternatives considered

- **A dedicated unfiltered docker path for the CLI (bypass the proxy filter for cco's own
  status query).** Rejected on security: it reintroduces the exact unfiltered-daemon
  surface the proxy exists to remove, and cco-in-container is **agent-invokable** — the
  channel's mere existence is attack surface, regardless of intent. The registry achieves
  the goal without touching the proxy.
- **Keep docker-only + accept `unknown` in-container (B4 alone).** Rejected as the *end*
  state: it leaves every non-current project permanently `unknown` in-session, a poor
  experience for a legitimate, access-governed query. Kept only as the interim/fallback.
- **Registry as the host source of truth too.** Rejected: introduces a staleness class on
  the host where docker already answers perfectly. The registry is host-side a *reconciled
  cache*; its only unique value is being **readable where docker is not** (in-container).

## Consequences

- **Positive**: in-container running-awareness becomes correct and **cross-project where
  cco_access allows it**, through one visibility model (the access-scope layer), with the
  docker proxy and its security boundary **untouched**. Host UX unchanged (docker stays
  authoritative). Reuses the R1 label + the ADR-0043 layer — no parallel machinery.
- **Negative / trade-offs**: a new STATE artifact + lifecycle write points (`cco
  start`/`stop`) + a reconciliation path + one more ro mount. Bounded staleness after an
  unclean exit until the next host reconciliation (self-healing, acceptable for a status
  display). Marker writes must be robust to concurrent starts/stops (per-project file,
  atomic create/remove).
- **Scope**: this ADR covers *running-state awareness* only. It does **not** widen what an
  agent may *do* to other containers (the proxy boundary is unchanged) — it only surfaces
  *status*, gated by cco_access.
- **Implementation** (pre-review phase): add `<state>/cco/running/` writers to
  `cco start`/`stop`, a host-side reconciler, the ro mount in `_start_generate_compose`,
  and route in-container `_cco_session_running` through the registry + `_env_in_scope`.
  Update the CLI-surface matrix B4/DI1 rows and `design-docker.md` (mount inventory).
  Changelog on landing.
