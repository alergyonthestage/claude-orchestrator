# Configuration Documentation — Index

This directory contains analysis and design documents for cco's configuration,
update, and resource management systems. Each subdirectory covers a distinct
feature or architectural concern.

## Document Map

| Subdirectory | Scope | Key File |
|-------------|-------|----------|
| **decentralized-config/** | The current config model: in-repo `<repo>/.cco/`, the `~/.cco` personal store, STATE/CACHE/DATA buckets, the machine-local index, sharing repos (structure-based discovery), multi-PC sync via `cco config`, per-user tags, and resource lifecycle. **Source of truth.** | `design.md` + supporting analyses |
| **update-system/** | Migration runner, discovery engine, opinionated file sync, change categories (additive/opinionated/breaking) | `design.md` — canonical for update mechanics; `base-tracking-fix-design.md` — base version tracking fix |
| **scope-hierarchy/** | Four-tier context hierarchy (managed/user/project/repo), override semantics | `design.md` — canonical for scope model |
| **packs/** | Pack format, pack.yml schema, knowledge management | `design.md` |
| **environment/** | Build-time and runtime extensibility (setup.sh, MCP, Docker) | `design.md` |
| **rules-and-guidelines/** | Rule content organization (which rules in which files) | `analysis.md`, `defaults-alignment-design.md` |
| **llms/** | LLMs.txt integration: storage, variant management, CLI commands | `analysis.md`, `design.md` |

> The former **sharing/**, **vault/**, and the `.cco/`-layout parts of **resource-lifecycle/** describe the removed central `user-config/` + vault model. Their successor is **decentralized-config/** (the surviving file-policy and changelog-dual-tracker concepts were re-homed into **update-system/**). The old subtrees are archived under `_archive/`.

## Concept Ownership

To avoid duplication, each concept has a single canonical source:

| Concept | Canonical Source |
|---------|-----------------|
| File policies (tracked, untracked, generated) | `update-system/` (re-homed from the former `resource-lifecycle/`) |
| Four-tier scope hierarchy | `scope-hierarchy/design.md` §1-3 |
| Change categories (additive, opinionated, breaking) | `update-system/design.md` §3-4 |
| Discovery + sync mechanics | `update-system/design.md` §4-5 |
| Tutorial as internal resource | `decentralized-config/` |
| Config-editor as a built-in session (`cco start config-editor`) | `decentralized-config/` |
| Sharing repos + publish/install flow (structure-based discovery, no manifest) | `decentralized-config/` |
| Multi-PC sync via `cco config` + per-user tags | `decentralized-config/` |
| In-repo `<repo>/.cco/` + `~/.cco` store layout, STATE/CACHE/DATA buckets, the machine-local index | `decentralized-config/` |
| Changelog dual-tracker (last_seen + last_read) | `update-system/` (re-homed from the former `resource-lifecycle/`) |
