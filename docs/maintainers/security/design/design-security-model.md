# Security Review

This document is the authoritative security analysis of claude-orchestrator.
It is fact-based: every finding references specific files and line numbers.
It is intended to guide future hardening work, not to block shipping.

**Scope:** CLI (`bin/cco`, `lib/`), Docker entrypoint (`config/entrypoint.sh`),
Dockerfile, personal-store versioning (`lib/cmd-config.sh`), and sharing-repo
remotes (`lib/cmd-remote.sh` / `lib/remote.sh`).

**Threat model:** Single-developer or small-team tool, running on the developer's
own machine. The primary risks are accidental secret exposure (via git, logs, or
process inspection), not active adversarial attacks. Secrets stored on disk are
assumed to be as safe as the machine itself — the same baseline as `.env` files,
`~/.ssh/id_rsa`, `~/.aws/credentials`, and every other developer credential store.

**Date:** 2026-03-06
**Status:** Phase 1 and Phase 2 fixes implemented. Phase 3 deferred.

---

## Risk classification

| Level | Meaning |
|---|---|
| **HIGH** | Can directly expose a secret or enable privilege escalation in a common workflow |
| **MEDIUM** | Exposure requires a secondary failure (e.g., gitignore misconfiguration) or is limited to specific conditions |
| **LOW** | Theoretical, mitigated by other controls, or an accepted trade-off of the current design |

---

## Findings

> **Related access-control decisions.** The agent ↔ cco access & confidentiality model lives in
> its own ADR chain: [ADR-0042](../../configuration/agent-cco-access/decisions/0042-agent-cco-interaction-model.md)
> (three-level A/B/C) · [ADR-0043](../../cli/decisions/0043-unified-cli-environment-access-scope.md)
> (output-scoping; INV-D revised) · [ADR-0046](../../configuration/agent-cco-access/decisions/0046-unified-cco-access-model.md)
> (`(G,Pc,Po)` model) · [ADR-0047](../../configuration/agent-cco-access/decisions/0047-config-access-enforcement.md)
> (the privilege boundary — see **HIGH-6**). This doc's threat model (single-developer) is
> **extended** by that chain to the in-container **agent** as a semi-trusted actor.

### [HIGH-1] Token embedded in git clone URL visible in process list and git config

**File:** `lib/remote.sh:41`

```bash
_GIT_AUTH_URL="${url/https:\/\//https://x-access-token:${effective_token}@}"
```

The token is injected into the clone URL as `https://x-access-token:TOKEN@host/...`.
This URL is passed to `git clone` as a command-line argument.

**Exposure surfaces:**
- On Linux, `/proc/PID/cmdline` is readable by the process owner during the clone.
  Root can always read it. On macOS, `ps aux` shows full arguments.
- In `_clone_for_publish` (`remote.sh:104`), `git remote add origin "$_GIT_AUTH_URL"`
  writes the token-embedded URL into `.git/config` of a temp directory.

**What is safe:**
- All callers (`cmd-pack.sh:893`, `cmd-project.sh:981`) set
  `trap "_cleanup_clone '$tmpdir'" EXIT` immediately after the clone. The tmpdir
  is cleaned on normal exit, error (`set -e`), and signals (EXIT trap). The token
  in `.git/config` of the tmpdir is therefore ephemeral in all normal scenarios.
  It persists only if the process receives SIGKILL (un-trappable) or the system crashes.
- `_clone_config_repo` (`remote.sh:67-76`) cleans up on failure via inline
  `|| { rm -rf "$tmpdir"; die ...; }` and callers also set EXIT traps.
- The vault git remote (`cmd-remote.sh:122`) is added with the **clean** URL
  (`$url`), not the token-embedded URL. The token is NOT stored in the vault's
  `.git/config`.
- Git output is redirected to `/dev/null 2>&1`, so tokens do not appear in
  terminal output.

**Residual risk:** Process-list visibility during clone operations (seconds).
This is the same exposure as `git clone https://user:token@github.com/...`
used directly by a developer.

**Mitigation options (not implemented):**
- Use `GIT_ASKPASS` or a temporary credential helper script to avoid embedding
  the token in the URL entirely.

---

### [HIGH-2] Docker socket gives Claude full host Docker API access

**File:** `lib/cmd-start.sh:384-387`, `config/entrypoint.sh:6-20`

```yaml
- /var/run/docker.sock:/var/run/docker.sock
```

The host Docker socket is bind-mounted into the container when
`docker.mount_socket: true` is set in `project.yml`.
Any process inside the container — including Claude — can:
- Create new containers that mount the host filesystem (`/` -> `/mnt`).
- Read arbitrary files from the host (including `/etc/shadow`, SSH keys, etc.).
- Escalate to effective root on the host via standard Docker socket abuse.

**Context:** This is **intentional and documented**. The Docker socket enables
"Docker-from-Docker" so Claude can run `docker compose` for infrastructure.
It can be disabled per-session (`--no-docker`) or per-project
(`docker.mount_socket: false`).

**Mitigation (Sprint 6-Security):**
- **Default changed to `false`** — Docker socket is now opt-in, not opt-out. Projects that need Docker access must explicitly declare `docker.mount_socket: true`. Migration 006 adds explicit `true` to existing projects to preserve behavior.
- **Implemented: Docker socket proxy** — Go binary (`proxy/`) filtering Docker API calls by container name/label, mount restrictions, and security constraints. The proxy (`cco-docker-proxy`) runs between Claude and the real socket, enforcing `policy.json` rules generated from `project.yml`. See [docker-security design](design-socket-proxy.md).

**Proxy internal structure** (4 packages, stdlib-only, no external dependencies):

| Package | Files | LOC | Responsibility |
|---------|-------|-----|----------------|
| `internal/config` | `config.go` | 100 | Policy loading and validation from `policy.json` |
| `internal/cache` | `cache.go` | 206 | Container ID-to-name resolution with periodic refresh (RWMutex + atomic) |
| `internal/filter` | `containers.go`, `mounts.go`, `security.go`, `errors.go` | 482 | Modular filters: container name/label validation, mount path allow/deny, privilege escalation prevention |
| `internal/proxy` | `proxy.go`, `routes.go` | 900 | HTTP reverse proxy handler, route matching, request interception, response modification |

**Test coverage** (as of 2026-03-19 — all packages covered):

| Package | Test file(s) | Tests | Test LOC | Status |
|---------|-------------|-------|----------|--------|
| `config` | `config_test.go` | 12 | 269 | All policies + edge cases |
| `cache` | `cache_test.go` | 13 | 411 | Mock upstream socket, refresh logic, concurrent access |
| `filter` | `containers_test.go`, `mounts_test.go`, `security_test.go` | 44 | 1,127 | All filter policies, DfD path translation, caps normalization |
| `proxy` | `proxy_test.go`, `routes_test.go` | 23 | 758 | HTTP handler integration, route matching, label injection |

**Totals**: 92 test functions, 2,565 lines of test code covering 1,688 lines of production code. All four packages have test coverage (cache and proxy handler tests added in RF-4, resolving PROXY-1 and PROXY-2 from the [comprehensive review](../../reviews/18-03-2026-comprehensive-review.md)).

---

### [HIGH-3] `setup.sh` content passed as Docker build arg, visible in image history

**File:** `lib/cmd-build.sh:55-61`

```bash
setup_content=$(cat "$GLOBAL_DIR/setup.sh")
build_args+=(--build-arg "SETUP_SCRIPT_CONTENT=$setup_content")
```

Docker build args are stored in the image metadata and visible to anyone who
runs `docker history --no-trunc <image>`. If `setup.sh` contains API keys,
passwords, or other secrets, they are permanently embedded in the image layers.

**What is safe:** The default `setup.sh` template contains only a comment
placeholder. The risk is realized only if the user adds secrets to it.

**Mitigation options (not implemented):**
- Use `RUN --mount=type=secret` (BuildKit) instead of build args.
- Add a warning in `cmd_build` if `setup.sh` contains patterns that look like
  secrets (e.g., `KEY=`, `TOKEN=`, `PASSWORD=`).
- Document clearly that `setup.sh` must not contain secrets.

---

### [HIGH-4] Project setup.sh runs as root in the container

**File:** `config/entrypoint.sh:114-119`

```bash
PROJECT_SETUP="/workspace/setup.sh"
if [ -f "$PROJECT_SETUP" ]; then
    bash "$PROJECT_SETUP" 2>&1 >&2
fi
```

The entrypoint runs as root (needed for Docker socket GID manipulation at
lines 6-20 and group management). The `gosu claude` drop happens later (lines
141-149). This means `setup.sh` executes with **full root privileges** inside
the container.

**What is safe:** The script is mounted `:ro` from the user's own project
directory (`cmd-start.sh:335`), so it cannot be modified at runtime. The user
controls its content. Inside the container, root has limited value — Docker
socket access (if enabled) already grants effective host root regardless.

**Residual risk:** If a shared project template includes a malicious `setup.sh`,
it runs as root in every team member's container. This is relevant for the
Config Repo sharing use case.

**Mitigation options (not implemented):**
- Execute `setup.sh` as the `claude` user via `gosu claude bash "$PROJECT_SETUP"`.
  Commands that need root (e.g., `apt-get install`) can use `sudo` explicitly.

---

### [MEDIUM-1] OAuth credentials written to tmpfile without guaranteed cleanup

**File:** `lib/cmd-start.sh:215-226`

```bash
tmp_keychain=$(mktemp) || true
if [[ -n "$tmp_keychain" ]]; then
    echo "$keychain_json" > "$tmp_keychain"
    ...
    rm -f "$tmp_keychain"
fi
```

The full OAuth credentials JSON (including access and refresh tokens) is written
to a temp file. It is removed with `rm -f` after use.

**Exposure paths:**
- If the process is interrupted (Ctrl-C, SIGKILL, system crash) between write
  and `rm -f`, the credentials file persists in `$TMPDIR` indefinitely.
- On macOS, `$TMPDIR` is per-user (`/var/folders/.../T/`) and not world-readable.
  The file itself inherits umask permissions (typically `600` on macOS).
- This code only executes on macOS (`uname == Darwin` check at line 211), where
  the same credentials are already in the Keychain — the tmpfile exposure is
  therefore redundant (an attacker with access to `$TMPDIR` also has Keychain
  access via the same user).

**Mitigation options (not implemented):**
- Use `trap 'rm -f "$tmp_keychain"' EXIT INT TERM` immediately after `mktemp`.
- Or compare Keychain JSON in-memory using a pipe to `jq` instead of a tmpfile.

---

### [MEDIUM-2] `chmod 600` failure is silently ignored

**Files:** `lib/cmd-remote.sh:116`, `lib/cmd-remote.sh:196`

```bash
chmod 600 "$rf" 2>/dev/null || true
```

If `chmod` fails (filesystem without Unix permissions, or an ownership issue),
`.cco/remotes` containing tokens remains world-readable with no warning.

The credentials file at `cmd-start.sh:223` uses `chmod 600` without `|| true`,
so a failure there would propagate correctly.

**Mitigation options (not implemented):**
- Remove `|| true`, let failures surface.
- Or: verify permissions after `chmod` and warn if broader than expected.

---

### [MEDIUM-3] Personal-store secret scan — single canonical pattern set

**File:** `lib/cmd-config.sh` (the `cco config save` scan), `lib/secrets.sh`

`cco config save` versions the personal `~/.cco` store. Before committing it
runs a two-pass secret scan via `_secret_match_filename` + `_secret_match_content`
(`lib/secrets.sh`) — the **same** `_SECRET_FILENAME_PATTERNS` used by
`cco pack publish` and `cco project export`. This closes the historical gap (a
separate, shorter vault-only pattern list that could drift from the canonical
set): adding a pattern to `_SECRET_FILENAME_PATTERNS` now hardens every gate at
once (see Coding Conventions §"Secret-like files").

Defense-in-depth still holds: a double-barrier allowlist staging
(`cco config save` never `git add -A`; only the explicit synced set) is the
primary barrier and the content scan is the secondary one. Auth tokens for
sharing-repo remotes never ride a synced file — they live in the machine-local
STATE `remotes-token` store (0600), not the DATA `remotes` registry.

**Residual:** the scan is best-effort, not a guarantee — a novel secret format
not matched by `_SECRET_FILENAME_PATTERNS`/`_secret_match_content` can still be
committed if the user explicitly stages it. Mitigation: extend the canonical
pattern set as new credential shapes appear.

---

### [MEDIUM-4] `$*` unquoted in tmux command string — argument handling issue

**File:** `config/entrypoint.sh:143`

```bash
gosu claude tmux new-session -s claude "claude --dangerously-skip-permissions $*"
```

`$*` is expanded inside a double-quoted string that tmux passes to `sh -c`.
Arguments with spaces, semicolons, or other shell metacharacters would be
misinterpreted. The non-tmux path (line 149) correctly uses `"$@"`.

**Practical risk:** The entrypoint's arguments come from `docker compose run ...
claude`, which passes no extra arguments in normal operation. The risk is
realized only if the user manually passes arguments with special characters.

**What is safe:** The non-tmux path (line 149) uses `exec gosu claude claude
--dangerously-skip-permissions "$@"` which handles arguments correctly.

**Mitigation options (not implemented):**
- Build a properly escaped argument string for tmux. For example:
  `printf '%q ' "$@"` to generate a shell-safe argument string.

---

### [MEDIUM-5] `eval` in secrets loader

**File:** `lib/secrets.sh:31`

```bash
eval "${_target}+=(-e $(printf '%q' "$line"))"
```

`printf '%q'` correctly escapes the value from `secrets.env`. The `$_target`
variable (the array name) is also evaluated, but is always a literal name
(`run_env`) passed by internal callers — no user input reaches it.

**Why this eval exists:** Bash 3.2 has no `nameref` (`declare -n`), which was
added in Bash 4.3. The `eval` + `printf '%q'` pattern is the standard
bash-3.2-compatible approach for dynamic array appending.

**Residual risk:** If a future refactor routes user input to `_target`, the eval
becomes exploitable. Purely theoretical today.

---

### [LOW-1] Secrets in `secrets.env` appear as process arguments to `docker compose run`

**File:** `lib/cmd-start.sh:522`

```bash
docker compose -f "$compose_file" run --rm --service-ports "${run_env[@]}" claude
```

Secrets are passed as `-e KEY=VALUE` arguments to the Docker CLI, visible in
`ps` output during the `docker compose run` process lifetime.

**Context:** This is the standard Docker pattern. The same exposure exists with
`docker run -e`, `heroku config:set`, any CLI that passes env vars. Docker
passes env vars to the container process through its API; they are not
re-exposed in the container's own `ps` output.

**Mitigation options (not implemented):**
- Use `--env-file` with a temporary file instead of individual `-e` flags.

---

### [LOW-2] `mcp-packages.txt` installs npm packages without integrity verification

**File:** `config/entrypoint.sh:128-130`

Package names from `mcp-packages.txt` are installed with `npm install -g`
without version pinning or lockfile. This is the same risk as any `npm install`
in any project. The file is user-controlled.

---

### [LOW-3] `--dangerously-skip-permissions` is always active

**File:** `config/entrypoint.sh:143,149`

Claude Code runs without permission prompts. This is **by design** — Docker IS
the sandbox. The `claude` user is non-root; `:ro` mounts are enforced. The repos
are mounted read-write intentionally.

---

### [LOW-4] `cco config push` does not inject a stored token

**File:** `lib/cmd-config.sh` (`_config_push`)

`cco config push` versions the personal `~/.cco` store to its own git remote and
calls `git push` without injecting any token — for a private remote the user
configures git credentials separately (SSH key, credential helper, etc.). This is
a **functional gap**, not a security issue (and is intentional: keeping the
`~/.cco` remote out of the token store means no personal-store secret is implied
by config). Sharing-repo remotes are different: `lib/remote.sh` *does* inject the
STATE `remotes-token` when cloning/fetching a token-protected sharing repo.

---

## Secret storage strategy: current design vs alternatives

The current approach stores sharing-repo auth tokens in plaintext in the
machine-local STATE store `<state>/cco/remotes-token` with `chmod 600` (the DATA
`remotes` registry holds only the de-tokenized url, so no secret rides a synced
file). This is consistent with how virtually all developer tools handle
credentials:

| Tool | Storage | Permissions |
|---|---|---|
| npm | `~/.npmrc` | plaintext, `600` |
| AWS CLI | `~/.aws/credentials` | plaintext, `600` |
| Docker | `~/.docker/config.json` | plaintext, `600` |
| `.env` files | project root | plaintext, gitignored |
| git netrc | `~/.netrc` | plaintext, `600` |
| SSH private keys | `~/.ssh/id_rsa` | plaintext, `600` |

The macOS Keychain provides better security (encrypted, requires user
authentication), but introduces complexity, macOS lock-in, and CI/headless
incompatibility.

**Conclusion:** The current plaintext + `chmod 600` + gitignore strategy is the
correct baseline. The Keychain integration already used for OAuth tokens is
appropriate for that specific credential (always macOS, always interactive).
Extending it to arbitrary remote tokens would reduce portability without
meaningful security improvement for the target threat model.

---

### [HIGH-5] Config parsing silently permissive — security-relevant fields accept invalid values

**File:** `lib/yaml.sh` (lines 137-176), `lib/cmd-start.sh` (lines 98-138)

**Date added:** 2026-03-09

The YAML parser and its consumers accept any value for security-relevant fields
without validation. Malformed values (trailing spaces, YAML boolean variants,
missing fields) silently produce permissive behavior instead of failing safely.

**Affected fields and their failure modes:**

| Field | Invalid Input | Silent Result |
|-------|--------------|---------------|
| `extra_mounts[].readonly` | `"true   "` (trailing spaces) | Mounted read-write |
| `extra_mounts[].readonly` | `yes`, `True`, `YES` | Mounted read-write |
| `extra_mounts[].readonly` | field omitted | Mounted read-write (default was `false`) |
| `browser.enabled` | `yes`, `True`, `1` | Browser disabled (safe by accident) |
| `docker.mount_socket` | `yes`, `True`, `1` | Socket mounted (permissive by accident) |
| `browser.mcp_args` | value containing `"` | JSON injection in MCP config |
| `repos[]` | `path:` without `name:` | Repository silently dropped |
| `docker.ports[]` | `"3000"` (no colon) | Docker fails at runtime |

**Real-world impact:** A user configured `readonly: true` with trailing whitespace
in `project.yml`. The parser compared `"true   " == "true"` → false, and the
mount was silently created as read-write. Claude could write to a directory the
user intended to be read-only.

**Root cause:** The parser prioritizes "never crash" over "never silently weaken
security". No validation layer exists between parsing and docker-compose generation.

**Mitigation:** Implemented via ADR-13 (Secure-by-Default Config Parsing):
- All boolean fields parsed through `_parse_bool()` with trim + normalize + enum
- `extra_mounts[].readonly` default changed to `true` (read-only)
- Validation pass in `cmd_start()` before compose generation
- Invalid values produce warnings and fall back to restrictive defaults

**Status:** Fix in progress (ADR-13 implementation)

---

### [HIGH-6] In-container agent reads the whole internal store — cross-project info leak (S1/S1b)

**File:** `~/.local/state/cco/index` (STATE), `~/.local/share/cco/` (DATA: tags, de-tokenized
remotes, per-resource `source` provenance); mounted by `lib/cmd-start.sh:1088-1094`.

**Issue.** In a wrapped-`cco` session the agent and the wrapped `cco` run as the **same UID
`claude`** with `--dangerously-skip-permissions` and no filesystem confinement. The whole STATE
index and DATA bucket mount into the container (`:ro` at read levels) **outside** the
`read-project` narrowing branch (which scopes only CONFIG). `lib/access-scope.sh` filters command
**output**, not the raw files. So even at the default `read-project`, the agent runs
`cat ~/.local/state/cco/index` and enumerates **every other project's name, host path,
membership, tags, and remote URLs** — and host paths leak even at `show_host_paths=off` (S1b).
*Verified live.*

**Impact.** Confidentiality / project-isolation breach across all projects registered on the
machine. Integrity is unaffected (write-gating is enforced physically by `:ro`/`:rw` mount flags,
a VFS property `fakeowner` does not weaken).

**Root cause.** No privilege boundary between the agent's shell and the internal store — any file
`cco` can read, the agent can `cat`. Claude Code's own controls cannot fix this (permission
`deny`/sandbox `denyRead` act uniformly on the shell and would block `cco` too; bypass mode is on
by design). `chown`/`chmod` on the mounted registries do not confine either — macOS Docker Desktop
`fakeowner` ignores DAC on bind-mount content.

**Mitigation (decided, PLANNED — [ADR-0047](../../configuration/agent-cco-access/decisions/0047-config-access-enforcement.md), D2).**
Confine **only** the internal store behind a **privilege boundary**: a dedicated **`cco-svc`**-owned
**mode-0700** parent on the **real** container FS (`/var/lib/cco-internal`) the `claude` user
cannot traverse (real-FS parent traversal confines even a `fakeowner` child); `$HOME` XDG cco
paths symlink into it; a **setuid `cco-svc` helper** crosses it and enforces the `(G,Pc,Po)` gate
(ADR-0046 §7) from a trusted, root-owned session descriptor (never `argv`/env). Config-content
trees stay mounted (native reads). Mirrors the `cco-docker-proxy` privilege precedent. Output-
scoping (`access-scope.sh`) remains as **defense-in-depth**, not the confidentiality control.

**Status:** Design accepted 2026-07-08 (D2); implementation deferred to the access-model impl
phase (after D3). Present in all shipped wrapped-`cco` sessions until then.

---

## Recommended fix priority

Ordered by a combination of effort required and risk addressed.

### Immediate — trivial fixes (DONE)

| # | Finding | What was done | Status |
|---|---|---|---|
| 1 | **[MEDIUM-3]** Secret scan pattern drift | Resolved by the decentralized-config refactor: `cco config save` scans via the canonical `_SECRET_FILENAME_PATTERNS` (`lib/secrets.sh`), so there is no separate vault-only list to drift | DONE |
| 2 | **[MEDIUM-2]** Silent chmod failure | Replaced `\|\| true` with `warn` on failure | DONE |

### Short-term — low effort, meaningful hardening (DONE)

| # | Finding | What was done | Status |
|---|---|---|---|
| 3 | **[MEDIUM-1]** Tmpfile cleanup | Eliminated tmpfile — pipe keychain JSON through jq in-memory | DONE |
| 4 | **[HIGH-3]** setup.sh secrets | Added pre-build grep for KEY=/TOKEN=/PASSWORD=/SECRET= patterns | DONE |
| 5 | **[HIGH-4]** setup.sh runs as root | Changed to `gosu claude bash "$PROJECT_SETUP"` | DONE |
| 6 | **[HIGH-2]** Docker socket docs | Added Security section to README with disable instructions | DONE |
| 7 | **[MEDIUM-4]** tmux `$*` quoting | Used `printf '%q'` to build shell-safe argument string | DONE |

### Short-term — config parsing hardening (IN PROGRESS)

| # | Finding | What to do | Status |
|---|---|---|---|
| 8 | **[HIGH-5]** Config parsing permissive | Implement ADR-13: `_parse_bool()`, validation pass, secure defaults | IN PROGRESS |

### Medium-term — higher effort, lower incremental value

| # | Finding | What to do | Effort |
|---|---|---|---|
| 9 | **[LOW-1]** Secrets in process args | Use `--env-file` with a tmpfile instead of `-e` flags | Medium |
| 10 | **[HIGH-1]** Token in clone URL | Replace with `GIT_ASKPASS` credential helper | High |

### Design-stage — access-model enforcement (PLANNED)

| # | Finding | What to do | Status |
|---|---|---|---|
| 11 | **[HIGH-6]** Agent reads whole internal store (S1/S1b) | Implement the [ADR-0047](../../configuration/agent-cco-access/decisions/0047-config-access-enforcement.md) privilege boundary: `cco-svc` setuid helper + `/var/lib/cco-internal` mode-0700 parent + trusted session descriptor, enforcing `(G,Pc,Po)` | Design accepted (2026-07-08); impl after D3 |

### Accepted risks — no fix needed

| Finding | Rationale |
|---|---|
| **[LOW-2]** npm packages | User-controlled config; same as any npm install |
| **[LOW-3]** skip-permissions | By design; Docker is the sandbox (host protection). Note: *intra-container* agent access to the internal store is a separate confidentiality gap — see **HIGH-6** / ADR-0047, not covered by "Docker is the sandbox" |
| **[LOW-4]** Vault push auth gap | Functional gap, not security; user configures git creds separately |
| **[MEDIUM-5]** eval in secrets.sh | Correctly escaped; `_target` is internal-only |

---

## OS compatibility

**Supported:**
- macOS 12+ (Monterey and later) — full support including Keychain integration
- Linux (any distribution with Docker Engine) — full support, no Keychain features

**Unsupported (no planned support):**
- Windows native — requires PowerShell rewrite; not in scope
- Windows WSL2 — works as a Linux environment; no changes needed, not officially tested

The CLI targets `bash 3.2+` for macOS compatibility. All `sed -i` calls use the
`sed -i '' ... || sed -i ...` pattern to handle macOS vs GNU differences.
The `stat -c '%g'` call in `entrypoint.sh` uses GNU stat syntax, which is
correct because it runs inside the Debian container, not on the host.
