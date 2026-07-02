# Docker & Networking

> How your repos and extra mounts are mounted into the session, how ports and
> networking work, how to reach the host, and how to run sibling containers
> (Docker-from-Docker).
>
> Related: [project.yml reference](../../configuration/reference/project-yaml.md) |
> [Socket security](../../security/guides/socket-security.md)

---

## 1. Overview

`cco start` reads your project's `project.yml`, generates a `docker-compose.yml`,
and launches one container (`cc-<project>`) with `working_dir: /workspace`. Your
repos and any extra mounts appear as subdirectories of `/workspace/`, ports you
declare are published to the host, and the container joins a per-project network.

```mermaid
flowchart LR
  subgraph host["Host"]
    R1["repo: backend-api"]
    R2["repo: frontend-app"]
    M1["extra mount: api-specs"]
    P["ports 3000, 4000 ..."]
  end
  subgraph c["Container cc-myproject (/workspace)"]
    W1["/workspace/backend-api (rw)"]
    W2["/workspace/frontend-app (rw)"]
    W3["/workspace/docs/api-specs (ro)"]
  end
  R1 --> W1
  R2 --> W2
  M1 --> W3
  P -. "host:container" .-> c
  c --- NET["network: cc-myproject (bridge)"]
```

---

## 2. How repos are mounted

Every entry under `repos:` is mounted **read-write** at `/workspace/<name>`, so
Claude can edit your code and changes persist on the host.

```yaml
repos:
  - name: backend-api          # → /workspace/backend-api  (read-write)
  - name: frontend-app         # → /workspace/frontend-app (read-write)
```

The logical `name` is also the directory name in `/workspace/`. The absolute
host path is resolved per machine from the local index (set it with
`cco resolve`), never written into `project.yml`.

> Each repo's own `.cco/` config directory is overlaid **read-only** inside the
> container, even though the repo itself is writable. This protects your
> structural config (`project.yml`, `secrets.env`) from accidental edits during a
> normal session (`cco_access=read-project` — read-only for `.cco`). Use `cco start
> config-editor` (or, per session, `cco start <project> --cco-access edit-project`) when
> you actually want to change it.
> See [Session access](../../reference/cli.md#session-access-capability-model).

---

## 3. Extra mounts (`extra_mounts`)

Use `extra_mounts` for reference material that is not a project repo — shared
specs, datasets, design assets. They are **read-only by default** (a secure
default: extra mounts are reference material, writes require an explicit opt-in).

```yaml
extra_mounts:
  - name: api-specs              # logical name, path resolved from the index
    target: /workspace/docs/api-specs   # optional; defaults to /workspace/<name>
    readonly: true               # default — omit it to keep read-only

  - name: scratch-data
    target: /workspace/scratch
    readonly: false              # explicit opt-in to make it writable
```

| Field | Default | Meaning |
|---|---|---|
| `name` | — (required) | Logical mount name; absolute host path resolved from the index. |
| `target` | `/workspace/<name>` | Container path. |
| `readonly` | `true` | Read-only unless you set `false`. |

**One-off mounts without editing `project.yml`** — use `--mount` on `cco start`
(repeatable). These are read-only by default; add `:rw` to make one writable.
The target defaults to `/workspace/<basename>`.

```bash
cco start myproject --mount ~/datasets/sample            # → /workspace/sample (ro)
cco start myproject --mount ~/notes:/workspace/notes:rw  # writable, explicit target
```

---

## 4. Ports and port mapping

Containers do not expose ports automatically. Declare each one as
`"host:container"` under `docker.ports`:

```yaml
docker:
  ports:
    - "3000:3000"     # frontend dev server
    - "4000:4000"     # backend API
    - "5432:5432"     # PostgreSQL
```

Now a server bound to `0.0.0.0:3000` inside the container is reachable at
`http://localhost:3000` on your host. The format is validated as
`host:container` (an optional `/tcp` or `/udp` suffix is allowed).

**Add ports for one session** without editing `project.yml` with `--port`
(repeatable):

```bash
cco start myproject --port 8080:8080 --port 9229:9229
```

> Bind your dev servers to `0.0.0.0` (not `127.0.0.1`) inside the container,
> otherwise the published port will not forward from the host.

---

## 5. The per-project network `cc-<project>`

Each project gets its own bridge network named `cc-<project>` (override with
`docker.network`). The session container joins it, and any sibling containers you
start (see §6) should join the same network so they can reach each other by
service/container name.

```yaml
docker:
  network: cc-my-saas    # optional; defaults to cc-<project-name>
```

Containers on the same `cc-<project>` network resolve each other by name. For
example, with a `postgres` sibling on the network, a connection string of
`postgresql://postgres:postgres@postgres:5432/app` works from the session
container — `postgres` resolves to the sibling.

---

## 6. Running sibling containers (Docker-from-Docker)

When `docker.mount_socket: true`, the host's Docker socket is available in the
session, so Claude can run `docker` / `docker compose`. These create **sibling
containers on the host daemon** — not nested containers. Put them on the
project network so they can talk to the session and to each other.

```yaml
docker:
  mount_socket: true     # default is false — opt in deliberately
  network: cc-myproject
```

Then, inside the session:

```bash
# Start a database sibling on the project network
docker run -d --name postgres --network cc-myproject \
  -e POSTGRES_PASSWORD=postgres postgres:16

# Or with compose — attach services to the same external network
docker compose up -d
```

Because siblings run on the host daemon, ports they publish appear on the **host**
(not via the session container's mappings). Container-to-container traffic stays
on `cc-myproject` and needs no port mapping.

> Mounting the Docker socket grants broad access to the host Docker daemon. cco
> filters it through a socket proxy (container name/label and mount-path rules),
> but you should still enable it only when your workflow needs it. See the
> [socket security guide](../../security/guides/socket-security.md) before turning
> it on.

---

## 7. Reaching the host from the container

| Platform | How |
|---|---|
| **macOS (Docker Desktop)** | `host.docker.internal` resolves to the host automatically — e.g. `http://host.docker.internal:5432`. |
| **Linux** | `host.docker.internal` is not automatic. cco injects the `host.docker.internal:host-gateway` mapping when browser host mode is enabled; otherwise reach host services through a published port or a sibling on the project network. |

> **Never use `network_mode: host` on macOS.** Docker Desktop runs a Linux VM, so
> `host` networking refers to the VM, not your Mac. Always use explicit port
> mappings (§4). cco does not generate `network_mode: host`.

---

## 8. Inspecting the generated compose

To see exactly what cco will mount, map, and network — without launching —
use a dry run:

```bash
cco start myproject --dry-run          # prints a summary
cco start myproject --dry-run --dump   # also writes the generated files to .tmp/
```

The summary lists the image, network, ports, repos, and packs; `--dump`
persists the full `docker-compose.yml` for inspection.

---

## 9. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Can't reach a dev server on `localhost:PORT` from the host | Port not declared in `docker.ports` (or via `--port`); or the server is bound to `127.0.0.1` instead of `0.0.0.0` inside the container. |
| Sibling containers can't see each other | They are not on the same `cc-<project>` network. Add `--network cc-<project>` (or the same `external` network in compose). |
| `host.docker.internal` not resolving on Linux | Not auto-injected outside browser host mode; publish the host service on a port or use a sibling on the project network instead. |
| `docker: command not found` / permission denied in session | `docker.mount_socket` is `false` (the default). Set it `true` (and review socket security) to enable Docker-from-Docker. |
| "Project already has a running session" on start | A `cc-<project>` container is still up. Run `cco stop <project>` first. |
| Edits to `project.yml` / `secrets.env` rejected inside the session | The committed `<repo>/.cco/` is mounted read-only by default (`cco_access=read-project`). Use `cco start config-editor`, or opt in per session with `cco start <project> --cco-access edit-project`. Note: real `secrets.env` values are filtered out of every session — only `*.example` is visible; edit real secrets on the host. |
