# Maintainer Documentation

Internal technical documentation for people developing or maintaining
claude-orchestrator: architecture, decision records, design docs, analyses,
reviews, and the roadmap.

> Building or contributing? Start with [foundation/design/architecture.md](foundation/design/architecture.md)
> and the [roadmap](roadmap.md).

## Domains

Each domain owns a slice of the system. Domains contain doc-type leaf
directories (see the convention below).

| Domain | Scope | Index / entry point |
|--------|-------|---------------------|
| **foundation** | Core system design: the project-wide **governing law** ([guiding-principles.md](foundation/design/guiding-principles.md), P1–P18), the four-tier context hierarchy, Docker-as-sandbox, workspace layout, plus the foundational ADRs (0001–0015) and the requirements spec. | [design/guiding-principles.md](foundation/design/guiding-principles.md) · [design/architecture.md](foundation/design/architecture.md) · [analysis/spec.md](foundation/analysis/spec.md) · [adr/](foundation/adr/) |
| **configuration** | The config lifecycle and distribution: scope hierarchy, rules & guidelines, llms.txt integration, file destinations, and the decentralized in-repo config model. | [configuration/README.md](configuration/README.md) |
| **packs** | Knowledge pack format, `pack.yml` schema, and zero-duplication resource delivery. | [packs/design/](packs/design/) |
| **update-system** | Migration runner, discovery engine, opinionated-file sync, and the additive/opinionated/breaking change taxonomy. | [update-system/design/](update-system/design/) · [update-system/analysis/](update-system/analysis/) |
| **environment** | Build-time and runtime container extensibility (setup scripts, packages, custom images, Docker). | [environment/design/](environment/design/) · [environment/analysis/](environment/analysis/) |
| **integration** | Infrastructure and external services: authentication, browser MCP, agent teams, git-worktree isolation, and the managed-integrations protocol. | [integration/auth/](integration/auth/) · [integration/browser-mcp/](integration/browser-mcp/) · [integration/agent-teams/](integration/agent-teams/) · [integration/worktree/](integration/worktree/) · [integration/guides/managed-integrations.md](integration/guides/managed-integrations.md) |
| **security** | Threat model, the security design, and the Docker socket proxy design. | [security/design/](security/design/) · [security/analysis/](security/analysis/) |
| **internal-projects** | The framework-internal sessions shipped with cco: the tutorial and the config-editor. | [internal-projects/tutorial/](internal-projects/tutorial/) · [internal-projects/config-editor/](internal-projects/config-editor/) |
| **cli** | The `cco` CLI as a **dual-context surface** (host **and** in-container agent): the environment-awareness principle, verb gating vs output scoping, and the unified env & access-scope layer. Cross-cutting — every verb inherits it. | [cli/design/design-cli-environment-awareness.md](cli/design/design-cli-environment-awareness.md) · [cli/decisions/](cli/decisions/) |
| **naming** | Resource naming & rename: where each resource's name/ID is stored, the identity re-key model (generalizing `cco project rename`), and mono- vs multi-repo naming. | [naming/analysis/resource-name-storage-map.md](naming/analysis/resource-name-storage-map.md) |
| **engineering** | How we build cco: coding conventions, testing, and review playbooks. | [engineering/guides/coding-conventions.md](engineering/guides/coding-conventions.md) · [engineering/guides/testing.md](engineering/guides/testing.md) · [engineering/guides/review-playbooks.md](engineering/guides/review-playbooks.md) |
| **reviews** | Cross-cutting historical architecture and progress reviews. | [reviews/](reviews/) |

## Doc-type leaf convention

Within each domain, documents live in leaf directories named by type. The type
determines the document's lifecycle (see the project rule
[`.claude/rules/documentation-lifecycle.md`](../../.claude/rules/documentation-lifecycle.md)):

| Leaf | Lifecycle |
|------|-----------|
| `analysis/`, `adr/` (also `decisions/`) | **Append-only history.** Decision and investigation records. Never rewritten in place — when superseded, the original is kept and forward-annotated with a pointer to the refining record. They preserve *why*. |
| `design/`, `guides/` | **Living docs.** Always rewritten to reflect the current/target truth; their history lives in git. They describe *how the system is / will be*. |

## Decision records (ADRs)

There are two ADR streams:

- **foundation/adr/** — the foundational architecture decisions, numbered
  **0001–0015** (Docker-as-sandbox, context hierarchy, auth, packs, worktree,
  managed integrations, …).
- **configuration/decentralized-config/decisions/** — the **deferred config +
  sharing design**, which is the **source of truth** for the in-repo config
  model. It carries its own ADR stream, **0001–0041** (the substantive
  config+sharing decisions run 0005–0041), plus its `design.md` and supporting
  analyses. See
  [configuration/README.md](configuration/README.md). Its
  [`guiding-principles.md`](foundation/design/guiding-principles.md) was promoted
  to **foundation** as project-wide **governing law** (P1–P18).
- **Later cross-cutting decisions continue the same sequence in their own domain
  `decisions/`**: the session capability model
  ([0036](configuration/decentralized-config/decisions/0036-session-config-capability-model.md)),
  the agent ↔ cco interaction model
  ([0042](configuration/agent-cco-access/decisions/0042-agent-cco-interaction-model.md)), and the
  unified CLI environment & access-scope layer
  ([0043](cli/decisions/0043-unified-cli-environment-access-scope.md)) — the last two govern how
  the **whole CLI** behaves in-container, so they live in the **cli** domain's normative design
  ([cli/design/design-cli-environment-awareness.md](cli/design/design-cli-environment-awareness.md)).

## Roadmap

- [roadmap.md](roadmap.md) — the single source of truth for planned work,
  priorities, and feature status.
- [roadmap-backlog.md](roadmap-backlog.md) — backlog of deferred and candidate
  items.
