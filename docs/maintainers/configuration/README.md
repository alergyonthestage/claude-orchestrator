# Configuration — Domain Index

This domain covers cco's configuration model, distribution, and resource
management. Each subdomain owns a distinct concern and follows the doc-type leaf
convention (`analysis/` and `decisions/` are append-only history; `design/` is
living). See the [maintainer index](../README.md) for the convention.

## Subdomains

| Subdomain | Scope | Links |
|-----------|-------|-------|
| **decentralized-config/** | **Source of truth.** The deferred config + sharing design: in-repo `<repo>/.cco/`, the `~/.cco` personal store, the STATE/CACHE/DATA buckets, the machine-local index, sharing repos (structure-based discovery), multi-PC sync via `cco config`, per-user tags, and the resource lifecycle. Carries its own ADR stream (0001–0027). | [design.md](decentralized-config/design.md) · [guiding-principles.md](decentralized-config/guiding-principles.md) · [decisions/](decentralized-config/decisions/) |
| **scope-hierarchy/** | The four-tier context hierarchy (managed → user → project → repo) and its override semantics. | [design](scope-hierarchy/design/design-scope-hierarchy.md) · [analysis](scope-hierarchy/analysis/analysis-001-scope-hierarchy.md) |
| **rules-and-guidelines/** | How rule content is organized — which rules live in which files, and aligning the shipped defaults. | [analysis](rules-and-guidelines/analysis/analysis-001-rules-and-guidelines.md) · [design](rules-and-guidelines/design/design-defaults-alignment.md) |
| **llms/** | llms.txt framework-documentation integration: storage, variant management, and the `cco llms` CLI surface. | [analysis](llms/analysis/analysis-001-llms.md) · [design](llms/design/design-llms.md) |
| **file-destinations/** | Where each managed file is written (config vs STATE/CACHE/DATA) and why. | [design](file-destinations/design/design-file-destinations.md) |

## Notes

- The **update system** (migrations, discovery, file policies, the additive/
  opinionated/breaking taxonomy) and **knowledge packs** are sibling maintainer
  domains, not subdomains here — see [update-system/](../update-system/) and
  [packs/](../packs/).
- The former **sharing/**, **vault/**, and `resource-lifecycle/` designs
  described the removed central `user-config/` + vault model. They are
  superseded by **decentralized-config/** and archived under
  [docs/archive/](../../archive/).
