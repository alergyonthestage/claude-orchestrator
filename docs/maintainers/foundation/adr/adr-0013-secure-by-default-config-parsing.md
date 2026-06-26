# ADR-0013: Secure-by-Default Config Parsing

> **Status**: accepted
> **Date**: 2026-03-09

## Context

The YAML parser (`lib/yaml.sh`) is extremely permissive. It accepts any input and
defers validation to Docker or Claude Code at runtime. A security audit revealed
that malformed configuration — trailing spaces, boolean variants (`yes`, `True`),
missing fields, wrong indentation — can silently change security-relevant behavior.
Specifically, `extra_mounts[].readonly: "true   "` (with trailing spaces) was
mounted read-write because the parser compared with `==` instead of normalizing.
This is a class of bugs where **config parsing errors silently weaken security**.

## Decision

Adopt the principle of **secure-by-default config parsing**:

1. **Restrictive defaults**: When a security-relevant field is omitted, the default
   MUST be the most restrictive value. Specifically:
   - `extra_mounts[].readonly` → default `true` (read-only) when field is omitted
   - `docker.mount_socket` → default `false` (opt-in; changed in Sprint 6-Security Phase A)
   - `browser.enabled` → remains `false` (disabled)
   - `github.enabled` → remains `false` (disabled)

2. **Robust boolean parsing**: All boolean fields MUST be parsed through a shared
   helper that:
   - Trims leading/trailing whitespace
   - Normalizes to lowercase
   - Accepts YAML boolean variants: `true/false`, `yes/no`, `on/off`, `1/0`
   - Rejects unrecognized values with a warning and defaults to the safe value

3. **Fail-safe on parse error**: If a value cannot be parsed or is malformed, the
   parser MUST:
   - Emit a warning visible to the user
   - Fall back to the most restrictive/safe default
   - Never silently accept an invalid value

4. **Validate before apply**: All parsed values MUST be validated in `cmd_start()`
   before generating `docker-compose.yml`. Validation includes:
   - `name`: matches `^[a-zA-Z0-9][a-zA-Z0-9_-]*$`, max 63 chars
   - `repos[]`: every `path:` has a corresponding `name:`
   - `docker.ports[]`: matches `^[0-9]+:[0-9]+(/tcp|/udp)?$`
   - `docker.env`: every line has `KEY: value` format
   - `browser.cdp_port`: numeric, range 1-65535
   - `browser.mcp_args`: values escaped before JSON injection
   - `auth.method`: enum `oauth` | `api_key`

5. **Whitespace handling**: All parsed values MUST have leading and trailing
   whitespace trimmed. The AWK parser already strips some whitespace, but the
   trimming MUST be applied consistently to all fields, including list items and
   nested values.

## Rationale

- Trailing spaces in `readonly: true   ` caused a real-world security bug where an
  extra mount was writable when it should have been read-only
- Silent data loss in repos/extra_mounts state machines caused missing mounts with
  no user feedback
- The YAML parser has no external dependency (no yq) — validation must be done in
  bash/awk, making explicit checks essential
- "Never crash" is still a goal, but "never silently weaken security" takes
  priority over "never emit an error"

## Breaking changes

- `extra_mounts[].readonly` default changes from `false` to `true`. Users with
  existing writable extra mounts must add `readonly: false` explicitly. This is a
  security improvement — the new default matches the primary use case (reference
  material, specs, docs).

## Consequences

- A `_parse_bool()` helper function is added to `lib/yaml.sh`
- `cmd_start()` gains a validation pass before compose generation
- Invalid config now produces user-visible warnings instead of silent acceptance
- All boolean fields use the same normalization path
