# ADR-0004: Docker-from-Docker via Socket Mount

> **Status**: accepted

## Context

Claude needs to run `docker compose up` for microservices and run dev servers with
accessible ports.

## Decision

Mount the host's Docker socket into the Claude container. This is
"Docker-from-Docker" (DfD), NOT Docker-in-Docker (DinD).

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock
```

### How it works

1. Docker CLI inside the Claude container sends commands to the HOST Docker daemon
2. `docker compose up` creates **sibling containers** on the host (not nested)
3. Sibling containers share the host's Docker network
4. Port mappings on sibling containers are accessible from macOS via `localhost:<port>`

### For dev servers inside the Claude container (e.g., `npm run dev`)

- Use docker-compose port mapping: `ports: ["3000:3000"]`
- The dev server binds to `0.0.0.0:3000` inside the container
- Docker Desktop for Mac routes `localhost:3000` on macOS to the container

### For sibling containers (postgres, redis, etc.)

- Created via `docker compose up` from within Claude container
- Use a shared Docker network so Claude container can reach them
- Port mappings make them accessible from macOS too

## Rationale

- DfD is simpler and more performant than DinD
- No `--privileged` flag needed (just socket access)
- Single Docker daemon = no image duplication, shared cache
- Standard pattern used by CI/CD tools (Jenkins, GitLab Runner)

## Risks

- Docker socket = root-equivalent access to host Docker daemon
- Acceptable for single-developer workstation
- Claude container could theoretically manipulate other containers on the host
- Mitigated by: developer oversight, feature branches, session isolation

## Consequences

- Docker CLI and docker-compose must be installed in the image
- Container user needs permission to access the socket (group `docker` or socket
  permissions)
- Shared Docker networks need consistent naming to avoid conflicts between projects
