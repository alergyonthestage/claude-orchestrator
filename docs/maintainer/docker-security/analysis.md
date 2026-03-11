# Analysis: Docker Socket Restriction & Network Hardening

> **Status**: Analysis — Sprint 6-Security
> **Date**: 2026-03-11
> **Scope**: Architecture — Docker socket filtering, mount restrictions, network isolation
> **Related**: [design.md](./design.md) | [security.md](../security.md) (HIGH-2) | [architecture.md](../architecture.md) (ADR-4) | [roadmap.md](../roadmap.md) (Sprint 6-Security)

---

## Table of Contents

1. [Context and Motivation](#1-context-and-motivation)
2. [Current State](#2-current-state)
3. [Threat Model](#3-threat-model)
4. [Docker Socket Restriction](#4-docker-socket-restriction)
5. [Mount Restriction for Sibling Containers](#5-mount-restriction-for-sibling-containers)
6. [Network & Internet Access Controls](#6-network--internet-access-controls)
7. [Security Enforcement on Created Containers](#7-security-enforcement-on-created-containers)
8. [project.yml Schema — Full Proposal](#8-projectyml-schema--full-proposal)
9. [Recommendation](#9-recommendation)
10. [Open Questions](#10-open-questions)

---

## 1. Context and Motivation

claude-orchestrator gives Claude Code full access to the host Docker daemon via a mounted socket (`/var/run/docker.sock`). This is the **largest attack surface** (HIGH-2 in security.md): Claude can create, inspect, modify, and destroy **any** container on the host — not just the ones belonging to the current project.

Additionally, the main container has **unrestricted internet access** and can create sibling containers with **arbitrary volume mounts**, potentially exposing host paths that were not intended for the project.

Sprint 6-Security addresses these gaps with three capabilities:

1. **Docker Socket Restriction** — filter which containers Claude can access and what operations are allowed
2. **Mount Restriction** — control which host paths can be mounted into sibling containers
3. **Network Hardening** — control internet access for the main container and sibling containers

---

## 2. Current State

### 2.1 Docker Socket Access

- Socket mounted read-write at `/var/run/docker.sock` (when `docker.mount_socket: true`)
- Default is `true` — **opposite of secure-by-default** (documented in roadmap as bugfix #C)
- GID synchronization in entrypoint ensures the `claude` user can access the socket
- No filtering: all Docker API calls pass through unmodified

### 2.2 Container Creation

- Claude can run `docker compose up`, `docker run`, etc. to create sibling containers
- Created containers join the project network (`cc-<project>`) by default, but Claude can specify any network
- No restrictions on container names, labels, capabilities, or volume mounts
- No restrictions on `--privileged` mode

### 2.3 Network Access

- Main container: full internet access via bridge network
- Sibling containers: full internet access (default bridge behavior)
- No egress filtering, no proxy, no domain allowlist
- Claude Code tools (WebFetch, WebSearch) are unrestricted

### 2.4 mount_socket Default Bug

`lib/cmd-start.sh:111` defaults `mount_socket` to `"true"`:
```bash
mount_socket=$(_parse_bool "$(yml_get "$project_yml" "docker.mount_socket")" "true")
```

This violates the secure-by-default principle (ADR-13). Projects that need Docker access should explicitly declare it.

---

## 3. Threat Model

**Context**: single-developer or small-team tool on the developer's machine. Threats are primarily **accidental scope expansion** and **autonomous agent misbehavior**, not adversarial attacks.

### 3.1 Threats Addressed

| Threat | Risk | Current | After |
|--------|------|---------|-------|
| Claude accesses/destroys containers from other projects | HIGH | Possible | Blocked by name/label filter |
| Claude mounts sensitive host paths (SSH keys, AWS creds) into sibling containers | HIGH | Possible | Blocked by mount policy |
| Claude creates privileged containers (container escape) | HIGH | Possible | Blocked by security policy |
| Claude exfiltrates data via unrestricted internet | MEDIUM | Possible | Configurable (full/restricted/none) |
| Claude creates containers on unrelated networks | MEDIUM | Possible | Blocked by network policy |
| Claude exhausts host resources via unlimited containers | LOW | Possible | Configurable resource limits |

### 3.2 Threats NOT Addressed (Out of Scope)

- Malicious Docker images (supply chain attacks) — out of scope for socket filtering
- Host kernel exploits via container — requires Docker daemon hardening
- Data exfiltration via DNS tunneling — requires specialized DNS filtering

---

## 4. Docker Socket Restriction

### 4.1 Approach: Custom HTTP Proxy

The Docker daemon communicates via HTTP over Unix socket. A proxy process intercepts API calls, inspects the request (method, path, body), and allows or denies based on policy.

**Architecture**:
```
Claude → /var/run/docker-proxy.sock → [Proxy] → /var/run/docker.sock (host)
```

**Why a custom proxy (not docker-socket-proxy)**:
- `docker-socket-proxy` (Tecnativa) filters by API endpoint type only (e.g., allow/deny all container operations)
- We need **per-container filtering** by name and label — requires body inspection on create, path inspection on other operations
- Custom proxy can enforce mount restrictions and security policies on `POST /containers/create`

### 4.2 Technology: Go Binary

**Decision**: Go binary, compiled and added to the Docker image.

| Criterion | Go | Node.js |
|-----------|-----|---------|
| Performance | Excellent — native binary, minimal overhead | Good — but V8 startup, GC pauses |
| Memory | ~5-10 MB RSS | ~30-50 MB (V8 heap) |
| Docker SDK | Official `docker/docker` client libraries | `dockerode` (community) |
| Unix socket | Native `net.Listener` | Possible but less ergonomic |
| JSON parsing | `encoding/json` (fast, typed) | Native (fast) |
| Binary distribution | Single static binary, no dependencies | Requires Node.js runtime (already present) |
| Build complexity | Requires Go toolchain in CI or pre-compiled binary | No build step |

Go is preferred for a long-running proxy that handles every Docker API call. The single binary simplifies the Docker image (no runtime dependency). Cross-compilation (`GOOS=linux GOARCH=amd64`) produces a static binary.

**Fallback**: If Go introduces too much build complexity, Node.js is viable since it's already in the container.

### 4.3 Docker API Endpoints to Filter

Based on typical Claude usage patterns (compose up/down, exec, logs, build):

| Endpoint | Method | Action | Filter Strategy |
|----------|--------|--------|-----------------|
| `POST /containers/create` | POST | Create container | Inspect body: name, labels, mounts, capabilities, privileged |
| `POST /containers/{id}/start` | POST | Start container | Resolve ID → name/label check |
| `POST /containers/{id}/stop` | POST | Stop container | Resolve ID → name/label check |
| `DELETE /containers/{id}` | DELETE | Remove container | Resolve ID → name/label check |
| `POST /containers/{id}/exec` | POST | Exec into container | Resolve ID → name/label check |
| `GET /containers/{id}/logs` | GET | Read logs | Resolve ID → name/label check |
| `GET /containers/{id}/json` | GET | Inspect container | Resolve ID → name/label check |
| `GET /containers/json` | GET | List containers | Filter response to allowed containers only |
| `POST /images/create` | POST | Pull image | Allow (needed for compose) |
| `POST /build` | POST | Build image | Allow (needed for compose) |
| `GET /images/json` | GET | List images | Allow |
| `POST /networks/create` | POST | Create network | Enforce name prefix |
| `POST /networks/{id}/connect` | POST | Join network | Enforce allowed networks only |
| `GET /networks` | GET | List networks | Filter to project networks |
| `POST /volumes/create` | POST | Create volume | Allow (named volumes) |
| `GET /events` | GET | Docker events stream | Filter to allowed containers |
| `GET /_ping` | GET | Health check | Always allow |
| `GET /version` | GET | Version info | Always allow |
| `GET /info` | GET | System info | Allow or deny (configurable) |

### 4.4 Container Identification

Containers are identified by **name prefix** and/or **label**:

- **Name prefix**: `cc-{project}-*` — all containers created by the project must have this prefix
- **Label**: `cco.project={project}` — injected automatically on container creation

The proxy resolves container IDs to names/labels via a local cache (populated from `GET /containers/json`) to avoid an extra API call per request.

### 4.5 Policy Configuration

```yaml
docker:
  containers:
    policy: project_only | allowlist | denylist | unrestricted
    allow:              # only with policy: allowlist
      - "cc-myapp-*"
      - "redis-dev"
    deny:               # only with policy: denylist
      - "cc-production-*"
    create: true        # can create new containers (default: true)
    name_prefix: "cc-{project}-"  # enforced on create (default: cc-{name}-)
    required_labels:    # injected on create
      cco.project: "{project}"
```

**Policy semantics**:

| Policy | Create | Access existing | List visibility |
|--------|--------|----------------|-----------------|
| `project_only` | Yes (with prefix/label) | Only `cc-{project}-*` or `cco.project={project}` | Filtered |
| `allowlist` | Yes (if name matches allow) | Only matching allow patterns | Filtered |
| `denylist` | Yes (if name not in deny) | All except deny patterns | Filtered |
| `unrestricted` | Yes | All | Unfiltered |

---

## 5. Mount Restriction for Sibling Containers

### 5.1 Problem

When Claude creates containers via `docker run -v /host/path:/container/path`, it can mount **any** host path — including SSH keys, cloud credentials, other project directories, and the Docker socket itself (recursive escape).

### 5.2 Policy Configuration

```yaml
docker:
  mounts:
    policy: none | project_only | allowlist | any
    allow:                    # only with policy: allowlist
      - "/home/user/data"
      - "/tmp/builds"
    deny:                     # override on allow/project_only/any
      - "/var/run/docker.sock"
      - "*.pem"
      - "*.key"
    force_readonly: false     # force all mounts to be read-only
```

**Policy semantics**:

| Policy | Allowed mounts |
|--------|---------------|
| `none` | No host mounts allowed (only named Docker volumes) |
| `project_only` | Only paths already in `repos[].path` and `extra_mounts[].source` |
| `allowlist` | Only paths matching `allow` patterns |
| `any` | Any path (current behavior) |

**Implicit deny list** (always enforced, non-overridable):

| Path | Reason |
|------|--------|
| `/var/run/docker.sock` | Prevents recursive socket escape |
| `~/.ssh/` | SSH private keys |
| `~/.aws/` | AWS credentials |
| `~/.config/gcloud/` | GCP credentials |
| `~/.azure/` | Azure credentials |
| `/etc/shadow` | System passwords |
| `/etc/sudoers` | Privilege escalation |

### 5.3 Proxy Enforcement

The proxy inspects `POST /containers/create` body, specifically:
- `HostConfig.Binds` — bind mount strings (`host:container[:ro]`)
- `HostConfig.Mounts` — mount objects (type, source, target)
- `Volumes` — volume declarations

For each mount, the proxy:
1. Checks the path against the implicit deny list → reject if matched
2. Checks the path against the explicit `deny` list → reject if matched
3. Checks the path against the policy (none/project_only/allowlist/any) → reject if not allowed
4. If `force_readonly` is true → inject `:ro` option

---

## 6. Network & Internet Access Controls

### 6.1 Options Evaluated

Four approaches were evaluated for network restriction:

#### Option A: Squid Egress Proxy (Sidecar)

A Squid proxy sidecar with domain allowlist. Supports HTTPS filtering via SNI peek (no MITM/certificate injection needed).

| Criterion | Assessment |
|-----------|-----------|
| Effectiveness | High for HTTP/S traffic. Does NOT block raw TCP or direct IP connections |
| Granularity | Domain-level. Supports wildcard (`*.npmjs.org`) |
| Workflow impact | Low if allowlist is complete. `npm install`, `git clone`, `pip install` work via proxy |
| Complexity | Medium-high (Dockerfile for sidecar, dual network, proxy config) |
| Sibling containers | Only if on same network AND configured with `HTTP_PROXY` |
| Bypass | Direct IP connections, raw TCP sockets |

#### Option B: Docker Network `internal: true` + Proxy

Combination: project network set to `internal: true` (no internet access), with a proxy sidecar on both an internal and external network.

| Criterion | Assessment |
|-----------|-----------|
| Effectiveness | **Maximum**. Blocks ALL traffic (TCP, UDP, DNS) unless routed through proxy |
| Granularity | Domain-level via proxy; IP-level via network isolation |
| Workflow impact | None if allowlist complete. Requires accurate domain list |
| Complexity | High (dual network setup, DNS forwarding, proxy config) |
| Sibling containers | **Yes** — if created on the internal network, they have no direct internet |
| Bypass | Very difficult. Would require proxy exploitation |

#### Option C: Claude Code Deny Rules

Block `WebFetch`, `WebSearch`, `Bash(curl *)`, `Bash(wget *)` in managed-settings.json.

| Criterion | Assessment |
|-----------|-----------|
| Effectiveness | **Low-Medium**. Only blocks Claude's direct tools, not subprocess network access |
| Granularity | Tool-level. Cannot filter npm/git/pip/node/python network access |
| Workflow impact | Low (Claude uses WebFetch/WebSearch rarely for coding) |
| Complexity | **Minimal** — single JSON change |
| Sibling containers | **No** — deny rules only apply to Claude Code process |
| Bypass | Easy — Claude can write a script that fetches URLs and execute it |

#### Option D: DNS-Based Filtering

Custom DNS server (CoreDNS/dnsmasq) that resolves only allowed domains.

| Criterion | Assessment |
|-----------|-----------|
| Effectiveness | Medium. Blocks DNS resolution but not direct IP connections |
| Granularity | Domain-level |
| Workflow impact | Requires comprehensive allowlist including CDN domains |
| Complexity | Medium (CoreDNS sidecar, DNS config) |
| Sibling containers | Only if using same DNS server |
| Bypass | Direct IP connections bypass DNS entirely |

### 6.2 Comparison Matrix

| Criterion | A: Proxy | B: Internal+Proxy | C: Deny Rules | D: DNS |
|-----------|----------|-------------------|----------------|--------|
| Blocks HTTP/S | Yes | Yes | Partial | Yes (via DNS) |
| Blocks raw TCP | No | **Yes** | No | No |
| Blocks npm/git/pip | Yes (via proxy) | **Yes** | No | Partial |
| Blocks direct IP | No | **Yes** | No | No |
| Sibling containers | Partial | **Yes** | No | Partial |
| Complexity | Medium-high | **High** | **Minimal** | Medium |
| Bypass difficulty | Medium | **Very hard** | Easy | Medium |

### 6.3 Recommended Approach: Layered Defense

**Layer 1 — Claude Code Deny Rules (immediate, zero cost)**:
Add to managed-settings.json when `network.internet` is not `full`. Blocks the most common vector (Claude directly fetching URLs). Not sufficient alone but eliminates the easy path.

**Layer 2 — Docker Network `internal: true` + Squid Proxy Sidecar (robust)**:
The only approach that provides true network isolation. Combined architecture:

```
External network (bridge, default)
  │
  [Squid Proxy container] ── domain allowlist (SNI-based HTTPS filtering)
  │
Internal network (internal: true, cc-<project>)
  │
  [Claude container] + [Sibling containers]
```

- Main container and sibling containers on `internal: true` network → no direct internet
- Squid sidecar on both networks → acts as sole gateway
- `HTTP_PROXY` / `HTTPS_PROXY` env vars point to Squid
- Squid filters by domain (SNI peek for HTTPS, no MITM)

This combination blocks ALL unauthorized traffic, including raw TCP, direct IP, and subprocess network access.

### 6.4 Policy Configuration

```yaml
network:
  internet: full | restricted | none
  allowed_domains:          # only with internet: restricted
    - "api.anthropic.com"
    - "*.npmjs.org"
    - "registry.npmjs.org"
    - "*.github.com"
    - "github.com"
    - "*.githubusercontent.com"
    - "pypi.org"
    - "*.pypi.org"
    - "*.docker.io"
    - "docker.io"
    - "*.docker.com"
    - "*.googleapis.com"
  blocked_domains:          # only with internet: full
    - "*.internal.corp"
  created_containers:
    internet: same | full | restricted | none
    allowed_domains: []     # override (if different from main)
```

**Policy semantics**:

| Policy | Main container | Sibling containers |
|--------|---------------|-------------------|
| `full` | Unrestricted (current behavior) | Same as `created_containers.internet` |
| `restricted` | Via Squid proxy with domain allowlist | Same or override |
| `none` | No internet (internal network, no proxy) | Same or override |

**Default domain allowlist** (for `restricted` mode, covers common dev workflows):

| Category | Domains |
|----------|---------|
| Anthropic API | `api.anthropic.com`, `claude.ai` |
| npm | `registry.npmjs.org`, `*.npmjs.org` |
| GitHub | `github.com`, `*.github.com`, `*.githubusercontent.com` |
| PyPI | `pypi.org`, `*.pypi.org`, `files.pythonhosted.org` |
| Docker Hub | `*.docker.io`, `*.docker.com` |
| Google (APIs, fonts) | `*.googleapis.com`, `*.gstatic.com` |

---

## 7. Security Enforcement on Created Containers

### 7.1 Problem

Even with container access restrictions, Claude can create containers with dangerous capabilities: `--privileged`, `CAP_SYS_ADMIN`, root user, etc.

### 7.2 Policy Configuration

```yaml
docker:
  security:
    no_privileged: true       # block --privileged (default: true)
    no_sensitive_mounts: true # block /proc, /sys bind mounts (default: true)
    force_non_root: false     # force USER != root in created containers (default: false)
    drop_capabilities:        # caps to drop from created containers
      - SYS_ADMIN
      - NET_RAW
      - NET_ADMIN
      - SYS_PTRACE
    resources:
      memory: "4g"            # max memory per created container
      cpus: "4"               # max CPUs per created container
      max_containers: 10      # max simultaneous containers
```

### 7.3 Proxy Enforcement

On `POST /containers/create`, the proxy inspects and modifies:

| Field | Check |
|-------|-------|
| `HostConfig.Privileged` | Block if `true` and `no_privileged: true` |
| `HostConfig.Binds` containing `/proc` or `/sys` | Block if `no_sensitive_mounts: true` |
| `User` field | Force non-root if `force_non_root: true` |
| `HostConfig.CapAdd` | Remove any in `drop_capabilities` list |
| `HostConfig.Memory` | Cap to configured limit |
| `HostConfig.NanoCpus` | Cap to configured limit |

Container count is tracked in-memory by the proxy. When `max_containers` is reached, new `POST /containers/create` requests are rejected.

---

## 8. project.yml Schema — Full Proposal

Complete schema for the `docker:` and `network:` sections:

```yaml
docker:
  # ── Existing fields ──────────────────────────────────────────────
  image: claude-orchestrator:latest
  mount_socket: false           # CHANGED: default false (bugfix #C)
  network: cc-myproject
  ports:
    - "3000:3000"
    - "8080:8080"
  env:
    NODE_ENV: development

  # ── NEW: Container access policy ─────────────────────────────────
  containers:
    policy: project_only        # project_only | allowlist | denylist | unrestricted
    allow: []                   # glob patterns (only with policy: allowlist)
    deny: []                    # glob patterns (only with policy: denylist)
    create: true                # can create new containers
    name_prefix: "cc-{name}-"  # enforced prefix on create ({name} = project name)
    required_labels:            # injected on create
      cco.project: "{name}"

  # ── NEW: Mount restrictions ──────────────────────────────────────
  mounts:
    policy: project_only        # none | project_only | allowlist | any
    allow: []                   # host paths (only with policy: allowlist)
    deny: []                    # host paths (always checked, even with policy: any)
    force_readonly: false       # force :ro on all mounts

  # ── NEW: Security constraints ────────────────────────────────────
  security:
    no_privileged: true
    no_sensitive_mounts: true
    force_non_root: false
    drop_capabilities:
      - SYS_ADMIN
      - NET_ADMIN
    resources:
      memory: "4g"
      cpus: "4"
      max_containers: 10

# ── NEW: Network policy ─────────────────────────────────────────────
network:
  internet: full                # full | restricted | none
  allowed_domains: []           # with internet: restricted
  blocked_domains: []           # with internet: full
  created_containers:
    internet: same              # same | full | restricted | none
    allowed_domains: []         # override if different
```

**Defaults summary** (when fields are omitted — secure by default):

| Field | Default | Rationale |
|-------|---------|-----------|
| `docker.mount_socket` | `false` | Opt-in Docker access |
| `docker.containers.policy` | `project_only` | Isolate between projects |
| `docker.containers.create` | `true` | Needed for infra dev |
| `docker.containers.name_prefix` | `cc-{name}-` | Identification and filtering |
| `docker.mounts.policy` | `project_only` | Only project repo paths |
| `docker.mounts.force_readonly` | `false` | Dev needs writable mounts |
| `docker.security.no_privileged` | `true` | Prevent container escape |
| `docker.security.no_sensitive_mounts` | `true` | Prevent kernel access |
| `docker.security.force_non_root` | `false` | Many images need root |
| `docker.security.resources.memory` | `"4g"` | Reasonable dev default |
| `docker.security.resources.cpus` | `"4"` | Reasonable dev default |
| `docker.security.resources.max_containers` | `10` | Prevent resource exhaustion |
| `network.internet` | `full` | Don't break existing workflows |
| `network.created_containers.internet` | `same` | Inherit from main |

---

## 9. Recommendation

### Implementation Order

1. **Phase A: `mount_socket` default fix** (bugfix, immediate)
   - Change default from `"true"` to `"false"` in `cmd-start.sh`
   - Add migration for existing projects
   - Update docs and project-yaml.md

2. **Phase B: Docker Socket Proxy** (core feature)
   - Build Go proxy binary
   - Integrate into Dockerfile and entrypoint
   - Implement container filtering (name/label)
   - Implement mount restrictions
   - Implement security constraints (privileged, capabilities, resources)
   - Parse `docker.containers`, `docker.mounts`, `docker.security` from project.yml
   - Generate proxy config and pass to entrypoint
   - Tests

3. **Phase C: Network Hardening** (requires Phase B)
   - Build Squid sidecar Docker image (or use official squid image with config)
   - Implement `internal: true` network generation
   - Implement `HTTP_PROXY`/`HTTPS_PROXY` injection
   - Parse `network` section from project.yml
   - Generate Squid allowlist from `network.allowed_domains`
   - Inject deny rules in managed-settings.json for `restricted`/`none` modes
   - Tests

### Technology Stack

- **Docker Socket Proxy**: Go binary (compiled in multi-stage Dockerfile)
- **Network Proxy**: Squid (official Docker image, SNI-based HTTPS filtering)
- **Configuration**: project.yml parsing via existing `lib/yaml.sh`
- **Policy file**: JSON config generated by `cmd-start.sh`, read by Go proxy at startup

---

## 10. Open Questions

1. **Proxy logging**: should the proxy log denied requests? If so, where? (stdout → visible in container logs, or file in `/tmp/`)
2. **Compose interception**: `docker compose up` sends multiple API calls. Should the proxy understand compose semantics (service names → container names)?
3. **Image pull restriction**: should we allow pulling only specific images, or any image?
4. **Hot reload**: should policy changes require container restart, or can the proxy reload config via signal?
5. **Squid image size**: official Squid image is ~150MB. Consider alpine-based build or tinyproxy as lighter alternative.
6. **Default allowlist completeness**: the domain allowlist for `restricted` mode needs validation against real-world workflows (npm with scoped packages, GitHub API, pip with custom indexes).
