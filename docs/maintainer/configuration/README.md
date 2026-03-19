# Configuration Documentation — Index

This directory contains analysis and design documents for cco's configuration,
update, and resource management systems. Each subdirectory covers a distinct
feature or architectural concern.

## Document Map

| Subdirectory | Scope | Key File |
|-------------|-------|----------|
| **resource-lifecycle/** | File policies (tracked/untracked/generated), resource update model, tutorial separation, FI-7 foundations, .cco/ directory structure | `analysis.md` — policies and lifecycle; `design.md` — .cco/ layout, path helpers, changelog dual-tracker |
| **update-system/** | Migration runner, discovery engine, opinionated file sync, change categories (additive/opinionated/breaking) | `design.md` — canonical for update mechanics; `base-tracking-fix-design.md` — base version tracking fix |
| **scope-hierarchy/** | Four-tier context hierarchy (managed/user/project/repo), override semantics | `design.md` — canonical for scope model |
| **sharing/** | Config Repos, manifest, publish/install commands, remotes, publish-install sync | `analysis.md` + `design.md` (base), `publish-install-sync-analysis.md` + `publish-install-sync-design.md` (FI-7) |
| **vault/** | Multi-PC sync, profiles, memory separation | `design.md` — canonical for vault mechanics |
| **packs/** | Pack format, pack.yml schema, knowledge management | `design.md` |
| **environment/** | Build-time and runtime extensibility (setup.sh, MCP, Docker) | `design.md` |
| **rules-and-guidelines/** | Rule content organization (which rules in which files) | `analysis.md`, `owner-preferences.md` |

## Concept Ownership

To avoid duplication, each concept has a single canonical source:

| Concept | Canonical Source |
|---------|-----------------|
| File policies (tracked, untracked, generated) | `resource-lifecycle/analysis.md` §3 |
| Four-tier scope hierarchy | `scope-hierarchy/design.md` §1-3 |
| Change categories (additive, opinionated, breaking) | `update-system/design.md` §3-4 |
| Discovery + sync mechanics | `update-system/design.md` §4-5 |
| Tutorial as internal resource | `resource-lifecycle/analysis.md` §4 |
| Config-editor template | `resource-lifecycle/analysis.md` §4.3 |
| Publish/install flow | `sharing/design.md` §15–§22 |
| Vault profiles and sync | `vault/design.md` |
| FI-7 foundations | `resource-lifecycle/analysis.md` §6 |
| .cco/ directory structure and path helpers | `resource-lifecycle/design.md` §2-4 |
| Changelog dual-tracker (last_seen + last_read) | `resource-lifecycle/design.md` §8 |
