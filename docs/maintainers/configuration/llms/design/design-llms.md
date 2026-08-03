# Design: llms.txt Integration

> Status: **Implemented** — shipped design, re-verified against `lib/cmd-llms.sh` /
> `lib/llms.sh` on **2026-08-03** (G6 living-docs sweep). Written as a draft on 2026-03-24;
> where the shipped surface diverged from the draft (the `list` verb, `rename`, the
> retired `workspace.yml`, the mandatory llms `url`), this document now states the
> **shipped** behaviour.
> Date: 2026-03-24
> Analysis: [analysis.md](../analysis/analysis-001-llms.md)
> Related: [Packs design](../../../packs/design/design-packs.md) | [project-yaml.md](../../../../users/configuration/reference/project-yaml.md) | [ADR-0032](../../decentralized-config/decisions/0032-pack-llms-coordinate-coherence.md) (llms `url` invariant)

---

## 1. Overview

This feature adds first-class support for the llms.txt standard in
claude-orchestrator. It enables users to install, manage, and serve official
framework documentation to coding agents during sessions, ensuring they write
code against up-to-date APIs and patterns.

```mermaid
graph TB
    subgraph "CACHE (~/.cache/cco/)"
        LLMS["llms/<br/>svelte/<br/>shadcn-svelte/<br/>..."]
    end
    subgraph "project A"
        PY_A["project.yml<br/>llms: [svelte, shadcn-svelte]"]
    end
    subgraph "pack frontend-stack"
        PACK["pack.yml<br/>llms: [svelte, svelte-kit, shadcn-svelte]"]
    end
    subgraph "project B (uses frontend-stack)"
        PY_B["project.yml<br/>packs: [frontend-stack]"]
    end

    PY_A -->|references| LLMS
    PACK -->|references| LLMS
    PY_B -->|via pack| PACK
```

### Design Principles

1. **Zero runtime network dependency** — docs are pre-downloaded, served locally
2. **Shared storage** — one copy of each llms.txt serves all packs/projects
3. **Separate concept from knowledge** — different lifecycle, ownership, and semantics
4. **Convention-aligned** — respects the llms.txt spec (variants, naming, format)
5. **Minimal surface area** — simple CLI, simple YAML schema, reuse existing mount/injection infrastructure

---

## 2. Directory Structure

### 2.1 Storage Layout

```
~/.cache/cco/llms/
├── svelte/
│   ├── llms-full.txt           # Primary doc file (downloaded)
│   ├── llms.txt                # Index file (optional, if available)
│   └── .cco/
│       └── source              # Source metadata (URL, variant, date)
├── svelte-kit/
│   ├── llms-full.txt
│   └── .cco/
│       └── source
├── shadcn-svelte/
│   ├── llms.txt                # Index-only (no full variant available)
│   └── .cco/
│       └── source
└── claude-code/
    ├── llms.txt
    └── .cco/
        └── source
```

### 2.2 Source Metadata (`.cco/source`)

```yaml
url: "https://svelte.dev/docs/svelte/llms.txt"
variant: full                    # full | medium | small | index
downloaded: "2026-03-24T14:30:00Z"
resolved_url: "https://svelte.dev/docs/svelte/llms-full.txt"  # actual file fetched
etag: "abc123"                   # for change detection (if server provides)
```

### 2.3 Primary File Resolution

When the system needs to determine which file to serve for an llms entry, it
follows this priority order:

1. `llms-full.txt` (if exists)
2. `llms-medium.txt` (if exists)
3. `llms-small.txt` (if exists)
4. `llms.txt` (fallback — index or single-file)

This resolution is used by mount generation and context injection. The user can
override by specifying `variant:` in the YAML reference.

---

## 3. YAML Schema

### 3.1 Pack Reference (`pack.yml`)

```yaml
name: frontend-stack
description: "Stack-specific conventions for SvelteKit web applications"

knowledge:
  files:
    - path: frontend-coding-conventions.md
      description: "Read when writing frontend code"

# llms.txt references — each carries its own re-fetch coordinate
llms:
  - name: svelte
    url: https://svelte.dev/docs/svelte/llms.txt
  - name: svelte-kit
    url: https://svelte.dev/docs/kit/llms.txt
  - name: shadcn-svelte
    url: https://shadcn-svelte.com/llms.txt
    description: "Component index — read index, then WebFetch specific component pages"

rules:
  - frontend-rules.md
```

> ⚠ **The `url` is MANDATORY on every llms reference** — in `pack.yml` exactly as in
> `project.yml` (ADR-0017 D1, uniform coordinate schema ADR-0016 D2, enforced for packs by
> [ADR-0032 D1](../../decentralized-config/decisions/0032-pack-llms-coordinate-coherence.md)).
> The whole reachability model depends on it: llms content is the *sole* resource kind that
> is never vendored, precisely because it is always re-fetchable from its coordinate
> (ADR-0019 D6). A pack whose llms have no url is **not shareable for those llms** — which
> is the drift ADR-0032 was written to close.

**Short form**: `- svelte` — a bare name. Still **parsed** (back-compat: `yml_get_llms`
returns an empty url for it), but it is a **share-readiness gap, not a valid steady
state**: with no url anywhere, a teammate or a second machine has nothing to re-fetch
from. `_validate_llms_refs` (`lib/llms.sh:201`) reports it as
*"llms '<name>' has no url coordinate — required to share/re-fetch"* whenever the content
is not already present locally, and `cco pack validate` / `cco project validate` surface
that finding. Prefer the long form everywhere.

**Long form** (the intended shape):

```yaml
llms:
  - name: shadcn-svelte
    url: https://shadcn-svelte.com/llms.txt   # REQUIRED — the re-fetch coordinate
    description: "Component index — read index, then WebFetch component pages"
    variant: index                            # optional
```

### 3.2 Project Reference (`project.yml`)

```yaml
name: my-svelte-app
repos:
  - name: my-app
    url: git@github.com:org/my-app.git   # coordinate, never a host path (ADR-0014)

packs:
  - frontend-stack

# Project-level llms (in addition to pack llms)
llms:
  - name: drizzle-orm
    url: https://orm.drizzle.team/llms.txt
  - name: tailwind
    url: https://tailwindcss.com/llms.txt
    variant: medium
```

Same syntax as pack references — including the mandatory `url`. Project llms are merged
with pack llms (deduplicated by name; the project wins on a name clash, for variant and
description alike).

> The `repos:` entry above is a **coordinate**, not a path. A committed `project.yml`
> never carries a host path; the logical name → absolute path binding is machine-local,
> in the STATE index (ADR-0014 / ADR-0051).

### 3.3 Full Long-Form Schema

```yaml
llms:
  - name: svelte              # Required: matches the directory in <cache>/cco/llms/
    url: https://svelte.dev/docs/svelte/llms.txt   # Required (ADR-0017 D1): re-fetch coordinate
    description: "..."        # Optional: override for the session-context llms entry
                              #           (default: auto from the file's H1)
    variant: full             # Optional: force a variant (default: auto-resolve, §2.3)
```

`yml_get_llms` emits one `name\tdescription\tvariant\turl` tuple per entry; consumers
must read all four columns (`_peel_tab` preserves empty fields, so an absent description
cannot shift the url column).

---

## 4. CLI Commands

### 4.1 `cco llms install <url> [--name <name>] [--variant <v>] [--pack <pack>] [--project <project>]`

Downloads an llms.txt file and saves it to `~/.cache/cco/llms/<name>/`.

**Behavior**:

1. Parse URL to determine framework name (last path segment before `/llms.txt`,
   or `--name` override). Example: `https://svelte.dev/docs/svelte/llms.txt` →
   name `svelte`.

2. Detect available variants by probing sibling URLs:
   - Given `https://example.com/docs/llms.txt`, check for:
     - `https://example.com/docs/llms-full.txt`
     - `https://example.com/docs/llms-medium.txt`
     - `https://example.com/docs/llms-small.txt`
   - Given `https://example.com/llms-full.txt`, check for base `llms.txt`

3. Download the selected variant (default: `full` if available, else the
   provided URL). Always download the index `llms.txt` too if available
   (lightweight, useful as catalog).

4. Save to `~/.cache/cco/llms/<name>/` with source metadata in `.cco/source`.

5. If `--pack <pack>` is specified, add the name to `pack.yml`'s `llms:` list.
   If `--project <project>` is specified, add to `project.yml`'s `llms:` list.

**Examples**:

```bash
cco llms install https://svelte.dev/docs/svelte/llms.txt
# → Downloads llms-full.txt (detected), saves to ~/.cache/cco/llms/svelte/

cco llms install https://shadcn-svelte.com/llms.txt --name shadcn-svelte
# → Downloads llms.txt (no full variant), saves to ~/.cache/cco/llms/shadcn-svelte/

cco llms install https://svelte.dev/docs/svelte/llms.txt --variant medium --pack frontend-stack
# → Downloads llms-medium.txt, adds "svelte" to frontend-stack pack.yml llms: list
```

**Output**:

```
Detecting variants for svelte...
  llms.txt        ✓ (index, 42 lines)
  llms-full.txt   ✓ (17140 lines)
  llms-medium.txt ✓ (8420 lines)
  llms-small.txt  ✓ (3210 lines)
Downloading llms-full.txt (default)...
Saved to ~/.cache/cco/llms/svelte/
  llms.txt      (index)
  llms-full.txt (primary — 17140 lines)
```

### 4.2 `cco list llms`

Lists all installed llms entries with metadata. **`cco llms list` was removed**
(ADR-0029 D1 → the unified index); it now answers with a migration hint on the host and
is refused with the same notice in-container. The renderer behind the kind view is still
`_llms_list`; `cco list` (unified) also surfaces llms rows, scoped to the session's read
scope (ADR-0043 — at `read-project` only the llms this project references are shown, with
a count-only stderr notice for the rest).

```
Name             Variant   Lines   Downloaded    Source URL
svelte           full      17140   2026-03-24    svelte.dev/docs/svelte/llms.txt
svelte-kit       full      16210   2026-03-24    svelte.dev/docs/kit/llms.txt
shadcn-svelte    index     117     2026-03-24    shadcn-svelte.com/llms.txt
claude-code      index     60      2026-03-20    code.claude.com/docs/en/llms.txt

Used by:
  svelte         → frontend-stack (pack), my-svelte-app (project)
  svelte-kit     → frontend-stack (pack)
  shadcn-svelte  → frontend-stack (pack)
  claude-code    → (unused)
```

### 4.3 `cco llms update [<name>] [--all]`

Re-downloads llms files from their source URLs.

**Behavior**:

1. Read `.cco/source` for URL and current variant.
2. Fetch remote file. If server provides ETag/Last-Modified, compare with stored
   value to detect changes.
3. If changed: download new version, update `.cco/source` timestamp.
4. If unchanged: report "already up to date".

```bash
cco llms update svelte          # Update one
cco llms update --all           # Update all installed
```

**Output**:

```
Checking svelte... updated (17140 → 17382 lines)
Checking svelte-kit... already up to date
Checking shadcn-svelte... updated (117 → 123 lines)
```

**Integration with `cco update`**: The main `cco update` command includes llms
freshness checks in its discovery output:

```
llms.txt updates available:
  svelte         last downloaded 45 days ago (check with: cco llms update svelte)
  shadcn-svelte  last downloaded 45 days ago
Run 'cco llms update --all' to refresh.
```

The threshold for staleness warnings is 30 days (configurable).

### 4.4 `cco llms remove <name>`

Removes an llms entry. Warns if referenced by any pack or project.

```bash
cco llms remove svelte
# Warning: 'svelte' is referenced by pack 'frontend-stack' and project 'my-svelte-app'.
# Remove anyway? [y/N]
```

### 4.5 `cco llms show <name>`

Shows detailed information about an installed llms entry.

```bash
cco llms show svelte
# Name:       svelte
# Source:     https://svelte.dev/docs/svelte/llms.txt
# Variant:    full (llms-full.txt)
# Lines:      17140
# Downloaded: 2026-03-24
# Files:
#   llms.txt      (42 lines, index)
#   llms-full.txt (17140 lines, primary)
# Used by:
#   pack frontend-stack
#   project my-svelte-app
```

### 4.6 `cco llms rename <old> <new>`

Renames an installed entry: the CACHE directory `<llms>/<old>/` → `<llms>/<new>/`, and
every `llms:` reference to it in the packs and projects that name it. **Only llms has
`rename`** among the resource families' download-shaped verbs — entries are auto-named
from their URL, so a bad auto-name is a real and llms-specific need (`cmd_llms`,
`lib/cmd-llms.sh:21-22`).

> **The llms verb set is smaller than pack's / template's.** Shipped: `install`, `show`,
> `update`, `rename`, `remove` (+ the removed `list` alias). There is deliberately **no**
> `llms create` (an entry is a download, not something you author), **no** `import` /
> `export` / `publish` / `internalize` (the coordinate is shared inside `project.yml` /
> `pack.yml`, and the content is re-fetchable — §12), and **no** `llms validate` (llms
> references are validated as part of `cco pack validate` / `cco project validate`, via
> `_validate_llms_refs` in `lib/llms.sh`). The operator shim classifies
> `pack|template|llms` as one family, so those absent verbs pass its gate and then die at
> the dispatcher with `Unknown llms command` — see the
> [CLI surface matrix](../../../cli/reference/cli-surface-matrix.md) §2.2/§2.3.

---

## 5. Mount Strategy

### 5.1 Mount Generation

At `cco start`, llms directories are mounted read-only, similar to pack
knowledge:

```yaml
# In generated docker-compose.yml
volumes:
  # Pack knowledge (existing)
  - /path/to/packs/frontend-stack/knowledge:/workspace/.claude/packs/frontend-stack:ro
  # LLMs docs (NEW)
  - /path/to/llms/svelte:/workspace/.claude/llms/svelte:ro
  - /path/to/llms/svelte-kit:/workspace/.claude/llms/svelte-kit:ro
  - /path/to/llms/shadcn-svelte:/workspace/.claude/llms/shadcn-svelte:ro
```

**Mount path**: `/workspace/.claude/llms/<name>/` — parallel to
`/workspace/.claude/packs/<name>/` for knowledge.

**Deduplication**: If both a pack and a project reference the same llms name,
only one mount is generated (same source directory).

### 5.2 Resolution Logic

```
_resolve_llms_mounts():
  1. Collect llms names from project.yml (direct)
  2. Collect llms names from each active pack's pack.yml
  3. Deduplicate (project overrides take precedence for variant)
  4. For each unique name:
     a. Resolve primary file (variant priority: full > medium > small > index)
     b. Verify directory exists in ~/.cache/cco/llms/<name>/
     c. Generate mount line
```

Implementation lives in a new `lib/llms.sh` module, called from
`_start_generate_compose()` alongside `_generate_pack_mounts()`.

---

## 6. Context Injection

### 6.1 The llms section of the session context

> **The `workspace.yml` file is retired (ADR-0042).** The agent-facing session-info
> surface is no longer a generated file in the `.claude` overlay: it is computed
> host-side by `lib/session-context.sh` and passed to the container as the base64
> **`CCO_SESSION_CONTEXT`** env var, which the SessionStart hook decodes and appends
> verbatim. `cco start` actively deletes any stale `workspace.yml`/`packs.md` a
> pre-ADR-0042 session left behind. The *content* below is unchanged in substance — the
> block still carries the same llms entries — only its carrier changed.

`_build_session_context` renders an **Official Framework Documentation (llms.txt)**
section from `_llms_render_entries "$project_yml" "$pack_names" "$project_dir"`, which
merges the project's and its packs' `llms:` references (project wins on a name clash)
and resolves each to its primary file under the mount:

```
Official Framework Documentation (llms.txt). Consult these BEFORE
writing code that uses these frameworks:
- /workspace/.claude/llms/svelte/llms-full.txt — Official Svelte 5 documentation
- /workspace/.claude/llms/svelte-kit/llms-full.txt — Official SvelteKit documentation
- /workspace/.claude/llms/shadcn-svelte/llms.txt — component index (WebFetch for details)
```

A declared llms entry that resolves to nothing on this machine is **not silently
dropped**: `_declared_unresolved_llms` lists it as `- llms: <name> — unresolved`, so the
agent sees a named gap rather than a short list it would read as complete.

**Description resolution**: if the YAML reference provides a `description:`, use it.
Otherwise auto-generate from the llms.txt H1 heading + line count + type hint (index vs
full).

### 6.2 Injection Flow

`config/hooks/session-context.sh` decodes `CCO_SESSION_CONTEXT` and injects it into
`additionalContext` — it does not read or parse any file. Teammates get the parallel,
deliberately leaner `CCO_SUBAGENT_CONTEXT` (knowledge + llms **paths only**, no
descriptions) through `config/hooks/subagent-context.sh`.

```mermaid
sequenceDiagram
    participant CLI as cco start
    participant Docker as Container
    participant Hook as session-context.sh
    participant Claude as Claude Code

    CLI->>CLI: Read project.yml + pack.yml llms: sections
    CLI->>CLI: Resolve llms mounts (deduplicate)
    CLI->>CLI: Add llms mounts to docker-compose.yml
    CLI->>CLI: Build the context block, base64 -> CCO_SESSION_CONTEXT
    CLI->>Docker: docker compose run (llms mounted :ro, env set)
    Docker->>Claude: Start session
    Claude->>Hook: SessionStart trigger
    Hook->>Hook: Decode CCO_SESSION_CONTEXT (no file read)
    Hook-->>Claude: additionalContext with knowledge + llms list
    Claude->>Claude: Framework docs available for selective reading
```

---

## 7. Managed Rule

### 7.1 Rule File

New managed rule at `defaults/managed/.claude/rules/use-official-docs.md`:

```markdown
# Use Official Framework Documentation

When official framework documentation (llms.txt) is listed in the session
context:

1. **Consult before writing**: Read the relevant llms.txt documentation BEFORE
   writing code that uses that framework. Do not rely solely on training data —
   APIs change between versions.

2. **Read selectively**: Large documentation files (10K+ lines) should be read
   with offset/limit targeting the relevant section. Do not read the entire file.

3. **Index files**: When a documentation file is an index (contains URLs to
   component/API pages), read the index first to locate the relevant page, then
   use WebFetch to retrieve the specific page content.

4. **Priority**: Official documentation takes precedence over training data when
   there is a conflict in API signatures, component props, or usage patterns.
```

This rule is **managed** (baked into the Docker image at `/etc/claude-code/`),
not opinionated. It defines framework behavior: if llms docs are installed, the
agent must use them. It is only actionable when llms files are actually present
in the session context.

### 7.2 Conditional Activation

The rule is always loaded (managed level), but its instructions are naturally
conditional: "When official framework documentation is listed in the session
context." If no llms files are installed, the rule has no effect.

---

## 8. YAML Parser Extensions

### 8.1 New Functions in `lib/yaml.sh`

```bash
# Parse llms list from project.yml or pack.yml
# Outputs one entry per line as: "<name>\t<description>\t<variant>"
# Short form "- svelte" outputs: "svelte\t\t"
# Long form outputs all fields.
yml_get_llms()

# Parse llms names only (for deduplication/validation)
# Outputs one name per line.
yml_get_llms_names()
```

### 8.2 Updated Validation

`_validate_single_pack()` in `lib/packs.sh` gains llms validation:
- Each referenced llms name must exist in `~/.cache/cco/llms/<name>/`
- At least one doc file must be present (llms-full.txt or llms.txt)

New `_validate_project_llms()` for project.yml validation (same checks).

The top-level key regex in pack validation gains `llms`:
```bash
grep -qE '^(name|knowledge|llms|skills|agents|rules):' "$pack_yml"
```

---

## 9. CLI Module

### 9.1 New `lib/cmd-llms.sh`

Following the existing pattern (`lib/cmd-pack.sh`), a new module handles all
`cco llms` subcommands:

```bash
# lib/cmd-llms.sh — LLMs.txt management: install, show, update, rename, remove
#
# Provides: cmd_llms()
# Dependencies: colors.sh, utils.sh, paths.sh
# Globals: LLMS_DIR (CACHE: ~/.cache/cco/llms)

cmd_llms() {
    local subcmd="${1:-}"
    # A bare invocation (or --help/-h) prints the sub-usage and returns 0.
    shift
    case "$subcmd" in
        install) _llms_install "$@" ;;
        list)    die "'cco llms list' was removed — use 'cco list llms' (ADR-0029)." ;;
        show)    _llms_show "$@" ;;
        update)  _llms_update "$@" ;;
        rename)  _llms_rename "$@" ;;
        remove)  _llms_remove "$@" ;;
        *)       die "Unknown llms command: $subcmd. Run 'cco llms --help'." ;;
    esac
}
```

Note the `*)` arm **dies** rather than printing usage: an unknown subcommand is an error
(exit 1), which is what makes a mis-documented verb such as `llms create` fail loudly
instead of silently showing help.

### 9.2 URL Parsing and Variant Detection

```bash
_llms_detect_variants() {
    local base_url="$1"
    # Given https://example.com/docs/llms.txt or https://example.com/docs/llms-full.txt
    # Derive the base path and probe for all variants.
    # Uses HEAD requests (curl -I) to minimize bandwidth.
    # Returns available variants as space-separated list.
}

_llms_resolve_name() {
    local url="$1"
    # Extract framework name from URL path.
    # https://svelte.dev/docs/svelte/llms.txt → svelte
    # https://shadcn-svelte.com/llms.txt → shadcn-svelte
    # Heuristic: use the path segment before /llms*.txt, or the domain name.
}
```

### 9.3 Download Implementation

Downloads use `curl` (available in the Docker image and on host). The install
command runs on the host (part of `cco` CLI), not inside the container.

---

## 10. Integration with `cco update`

### 10.1 Staleness Check

`cco update` includes an llms freshness check in its discovery phase:

```bash
_update_check_llms_freshness() {
    local threshold_days=30
    for dir in "$LLMS_DIR"/*/; do
        [[ ! -d "$dir" ]] && continue
        local source_file="$dir/.cco/source"
        [[ ! -f "$source_file" ]] && continue
        local downloaded
        downloaded=$(yml_get "$source_file" "downloaded")
        # Compare with current date, warn if older than threshold
    done
}
```

This is informational only — `cco update` does not auto-download. It suggests
`cco llms update --all`.

### 10.2 No Migration Required

llms.txt is a purely additive feature:
- New `llms:` key in pack.yml/project.yml — ignored by existing parsers
- New `~/.cache/cco/llms/` directory — does not affect existing installations
- New managed rule — added on next `cco build`
- Existing packs and projects continue to work unchanged

A `changelog.yml` entry is required to notify users of the new feature.

---

## 11. Implementation Plan

All five phases are **shipped**; the file map below is kept as the implementation
index, corrected to where each piece landed (verified 2026-08-03).

### Phase 1: Core Infrastructure

1. **`lib/llms.sh`** — shared helpers: path resolution (`_llms_resolve_primary_file`),
   collection (`_collect_llms_names`), context rendering (`_llms_render_entries`),
   validation (`_validate_llms_refs`), freshness (`_update_check_llms_freshness`)
2. **`lib/yaml.sh`** — `yml_get_llms()`, `yml_get_llms_names()` parsers
3. **`lib/cmd-start.sh`** — llms mount generation
4. **`lib/packs.sh`** — extend `_validate_single_pack()` for llms references,
   update top-level key regex

### Phase 2: CLI Commands

5. **`lib/cmd-llms.sh`** — `install`, `show`, `update`, `rename`, `remove`
6. **`bin/cco`** — register `llms` in the dispatcher (and in `_cco_operator_shim`)

### Phase 3: Agent Guidance

7. **`defaults/managed/.claude/rules/use-official-docs.md`** — managed rule
8. **`lib/session-context.sh`** — emit the llms section into the `CCO_SESSION_CONTEXT`
   block (§6; not a `workspace.yml` file — ADR-0042)

### Phase 4: Update Integration

9. **`lib/llms.sh`** — `_update_check_llms_freshness`, called from the `cco update`
   discovery phase (the check lives with the other llms helpers, not in `cmd-update.sh`)
10. **`changelog.yml`** — additive change entry

### Phase 5: Documentation & Templates

11. **User guide** — ⚠ *no dedicated llms user guide was ever written*. The user-facing
    coverage is distributed across `docs/users/configuration/reference/project-yaml.md`
    (§ LLMs.txt schema), `docs/users/reference/cli.md` (the `cco llms` verbs) and
    `docs/users/packs/guides/knowledge-packs.md` (pack-provided llms). The planned
    `llms-txt.md` does not exist — raised at the G6 sweep, 2026-08-03; whether to write
    one is a maintainer call, not a doc-sweep fix.
12. **`docs/users/reference/cli.md`** — CLI reference ✅
13. **`docs/users/configuration/reference/project-yaml.md`** — schema ✅
14. **`templates/project/base/project.yml`** — commented `llms:` section ✅

---

## 12. Interaction with Other Features

### Pack Inheritance (#9)

When implemented, llms references would be inherited naturally: a child pack
that `extends: base-web` would inherit the parent's `llms:` list. The child
can add or override entries.

### RAG (Sprint 12)

The RAG system could index llms.txt files for semantic search, reducing the
need for full-file reads. The llms directory structure is already RAG-friendly
(one directory per framework, clear file naming).

### Sharing

An llms entry is referenced by **coordinate** — a logical `name` → `url` (plus
optional `variant`/`ref`) — embedded per-unit in `project.yml` / `pack.yml`
([ADR-0014](../../decentralized-config/decisions/0014-llms-and-referenced-resource-coordinates.md),
[ADR-0016](../../decentralized-config/decisions/0016-consolidated-resource-taxonomy.md)).
The coordinate is the machine-agnostic, team-shareable part; the downloaded
llms.txt content lives in **CACHE** (`~/.cache/cco/llms/<name>/`) and is
re-fetchable from the coordinate's `url` at any time. Only the coordinate is
shared — never the cached content, which is a machine-local, regenerable copy
that each machine and teammate rebuilds on demand.

Because the reference rides the unit's manifest, team-sharing of llms references
follows the same two paths as every other resource
([ADR-0018](../../decentralized-config/decisions/0018-sharing-model-unification.md)):

- **Project-referenced llms** ride the project's own **code-repo remote**: the
  `llms:` coordinates are committed in `<repo>/.cco/project.yml`, so anyone who
  clones the repo resolves them and re-fetches the content into their own CACHE.
  (Projects do not publish/install.)
- **Pack-referenced llms** ride the **sharing repo** via `cco pack publish` /
  `cco pack install`: the `llms:` coordinates travel inside `pack.yml`, and the
  consumer re-fetches content on resolve. Sharing-repo discovery is
  **structure-based** (a `packs/` + `templates/` layout) — there is **no
  `manifest.yml`**.

---

## 13. Open Questions

### Resolved

| Question | Decision |
|----------|----------|
| Separate concept from knowledge? | Yes — different lifecycle, ownership, semantics |
| Where to store files? | `~/.cache/cco/llms/<name>/` (shared) |
| Default variant? | `full` (self-contained, no runtime network) |
| Referenced from packs or projects? | Both |
| Dedicated CLI or extend pack CLI? | Dedicated `cco llms` subcommand |
| MCP vs local files? | Local files (zero runtime dependency) |
| Managed vs opinionated rule? | Managed (framework behavior) |

### Deferred

| Question | Notes |
|----------|-------|
| Auto-discovery of llms.txt for project dependencies? | Future enhancement — parse `package.json` deps, check if llms.txt exists for each. |
| Should `cco llms install` support bulk install from a list file? | Evaluate after initial usage patterns emerge. |
| Should the staleness threshold (30 days) be configurable? | Start with hardcoded, make configurable if users request it. |
