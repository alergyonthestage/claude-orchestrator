# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in claude-orchestrator, please report it responsibly.

**Do NOT open a public GitHub issue for security vulnerabilities.**

Instead, use one of the following:

1. **GitHub Security Advisories** (preferred): Go to the [Security tab](../../security/advisories/new) of this repository and create a new advisory.
2. **Email**: Contact the maintainer directly at the email address listed in the GitHub profile.

You should receive an acknowledgment within 48 hours. We will work with you to understand the issue and coordinate a fix before any public disclosure.

## Security Model

claude-orchestrator runs Claude Code inside Docker containers with `--dangerously-skip-permissions`. This is safe because:

- **Docker IS the sandbox**: the container isolates Claude from the host filesystem and network (except explicitly mounted paths and mapped ports).
- **Docker socket proxy**: when the Docker socket is mounted (`mount_socket: true`), a Go-based proxy filters API calls by container name, labels, and mount paths. See `proxy/` for the implementation.
- **No host access**: Claude cannot access files outside the mounted repositories and configuration directories.

### Known Limitations

- **Network access**: containers currently have full internet access. Network hardening (restricted/none modes with domain filtering) is planned but not yet implemented. See the [roadmap](docs/maintainer/decisions/roadmap.md) for details.
- **Docker socket**: even with the proxy, mounting the Docker socket grants significant capabilities. Use `mount_socket: false` in `project.yml` if your workflow does not require Docker-from-Docker.
- **Mounted repositories**: Claude has read-write access to all mounted repos. This is by design — it needs to edit code.

For a detailed security analysis, see [docs/maintainer/architecture/security.md](docs/maintainer/architecture/security.md).

## Supported Versions

Only the latest release is supported with security updates. This project is in alpha — there are no LTS or backport guarantees.

| Version | Supported |
|---------|-----------|
| Latest (`main`) | Yes |
| Older tags | No |
