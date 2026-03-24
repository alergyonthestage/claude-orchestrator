# Analysis: llms.txt Integration

> Date: 2026-03-24
> Status: Complete
> Next: [design.md](design.md)

---

## 1. Problem Statement

AI coding assistants produce better code when they have access to up-to-date
framework documentation. Training data is inherently stale — APIs change,
patterns evolve, new features appear. The `llms.txt` convention provides a
standardized way for frameworks to expose their documentation in LLM-friendly
format.

claude-orchestrator currently has no mechanism to:
- Install and manage external framework documentation
- Make it available to coding agents during sessions
- Keep it updated as frameworks release new versions
- Guide agents to consult official docs before writing framework-specific code

Users must manually copy documentation files or rely on MCP servers that add
network latency and context overhead.

---

## 2. The llms.txt Standard

### 2.1 Overview

llms.txt was proposed by Jeremy Howard (Answer.AI) in September 2024. It is a
community-driven convention (not ratified by IETF/W3C) that has achieved
significant adoption in the developer tooling ecosystem.

**Specification**: https://llmstxt.org/

**Format**: Markdown file at the root of a website (`/llms.txt`) with:
- H1 heading: project name (required)
- Blockquote: brief project summary (recommended)
- H2 sections: categorized lists of links in `- [name](url): description` format
- Optional section: secondary resources that can be omitted for smaller context windows

### 2.2 File Variants

The convention supports multiple size variants:

| File | Purpose | Typical size |
|------|---------|-------------|
| `/llms.txt` | Lightweight index with links and one-line descriptions | 50-200 lines |
| `/llms-full.txt` | Complete documentation inline, self-contained | 10K-50K lines |
| `/llms-medium.txt` | Abridged version, examples and non-essential content removed | 5K-20K lines |
| `/llms-small.txt` | Minimal version for small context windows | 2K-10K lines |

Sub-project variants are also common: `/docs/svelte/llms.txt`,
`/docs/kit/llms.txt`.

### 2.3 Adoption

**784+ websites** implement llms.txt as of early 2026. Notable adopters:

| Category | Examples |
|----------|---------|
| **Infrastructure** | Cloudflare, Vercel, Supabase, Shopify |
| **AI/ML** | Anthropic (docs.claude.com), Hugging Face, Pinecone, NVIDIA |
| **Frameworks** | Svelte/SvelteKit, LangChain, LangGraph |
| **UI Libraries** | shadcn/ui, shadcn-svelte, Chakra UI, Bits UI |
| **Payments** | Stripe |
| **Automation** | Zapier |
| **Dev Tools** | Cursor, ElevenLabs |

Directories tracking llms.txt adoption:
- https://llmstxt.site
- https://directory.llmstxt.cloud
- https://llmstxthub.com

### 2.4 How AI Tools Use llms.txt

| Tool | Integration |
|------|------------|
| **Cursor** | Native `@Docs` feature: user adds URL, content is indexed and available via `@docs <alias>` |
| **Windsurf** | `@` references in conversations and `.windsurfrules` files |
| **Claude Code** | No native integration. Manual fetch via WebFetch or community skills |
| **mcpdoc (LangChain)** | MCP server exposing llms.txt as tools (`list_doc_sources`, `fetch_docs`). Works with Cursor, Windsurf, Claude Desktop/Code |

### 2.5 Generation Tools

| Tool | Type |
|------|------|
| Firecrawl llmstxt-generator | SaaS + open source, scrapes sites |
| docusaurus-plugin-llms | Plugin for Docusaurus |
| vitepress-plugin-llms | Plugin for VitePress |
| Mintlify, GitBook, Fern | Native llms.txt generation |
| Yoast SEO, Rank Math | WordPress plugins |

---

## 3. Options Evaluated

### 3.1 MCP-Based Approach (mcpdoc)

Use LangChain's mcpdoc MCP server to serve llms.txt content at runtime.

**Pros**: Standard MCP integration, automatic updates from remote.
**Cons**: Network latency per query, tool definitions consume context, external
dependency at runtime, not aligned with cco philosophy (zero runtime dependencies).

**Decision**: Rejected as primary mechanism. Users can still add mcpdoc manually
via `mcp.json` if they prefer the MCP approach.

### 3.2 Framework-Specific MCP (e.g., Svelte MCP)

Some frameworks provide dedicated MCP servers (Svelte offers `@sveltejs/mcp`
with tools like `list-sections`, `get-documentation`, `svelte-autofixer`).

**Pros**: Richer features (autofixer, playground links).
**Cons**: Each framework requires its own MCP server, network dependency, context
overhead, feature overlap with what Claude already does with full docs available.

**Decision**: Rejected. The value is marginal over having the full documentation
available locally. Users can add framework MCPs manually if desired.

### 3.3 Knowledge Files in Packs (No New Mechanism)

Store llms.txt files as regular knowledge files in pack `knowledge/` directories.

**Pros**: Zero changes to the system, works today.
**Cons**: No update mechanism (files become stale), no variant support, no source
tracking, semantically incorrect (knowledge = user-written conventions, llms =
external framework docs), llms files duplicated across packs sharing the same
technology.

**Decision**: Rejected. llms.txt files have fundamentally different lifecycle
and semantics than knowledge files.

### 3.4 Dedicated llms.txt Subsystem (Selected)

New `user-config/llms/` directory for shared llms.txt files, referenced from
packs and projects via a dedicated `llms:` section. CLI commands for install,
update, and management.

**Pros**: Clean separation of concerns, shared across packs/projects, updatable,
variant support, source tracking.
**Cons**: New concept and CLI surface area.

**Decision**: Selected. The additional complexity is justified by the distinct
lifecycle, the sharing requirement, and the update mechanism.

---

## 4. Key Design Decisions

### 4.1 Separate Concept from Knowledge

**Decision**: llms.txt is a separate resource type, not a subtype of knowledge.

**Rationale**:
- **Lifecycle**: knowledge is static (user-written), llms is updatable (fetched from URL)
- **Ownership**: knowledge is authored by the user, llms is authored by framework maintainers
- **Sharing**: knowledge is typically pack-specific, llms is shared across packs/projects
- **Size**: knowledge files are small (always relevant), llms files are large (read selectively)
- **Update**: knowledge has no remote source, llms tracks URL + variant + freshness

Both share the mount/injection mechanism (read-only Docker mounts, listed in
context), but they are distinct resource types.

### 4.2 Shared Storage in `user-config/llms/`

**Decision**: llms.txt files live in `user-config/llms/<name>/`, shared across
all packs and projects.

**Rationale**: A Svelte project and a SvelteKit project both need the same Svelte
docs. Duplicating 17K-line files across packs is wasteful. The shared directory
mirrors how `user-config/packs/` already works — defined once, referenced by name.

### 4.3 Full Variant as Default

**Decision**: When installing, download `llms-full.txt` if available, falling
back to `llms.txt`.

**Rationale**: The full variant is self-contained (no network dependency at
runtime), which aligns with cco's philosophy. The index variant requires WebFetch
to be useful — acceptable as fallback but not preferred.

### 4.4 Referenced from Packs AND Projects

**Decision**: Both `pack.yml` and `project.yml` can declare which llms files
they need via an `llms:` section.

**Rationale**: Technology choice is project-specific. A pack groups conventions
for a technology stack (and naturally includes its llms references). A project
might need additional llms not covered by its packs, or might not use packs at
all.

Resolution order: project `llms:` + all pack `llms:` (deduplicated).

### 4.5 Managed Rule for Agent Guidance

**Decision**: Add a managed rule that instructs the agent to consult installed
llms.txt documentation before writing framework-specific code.

**Rationale**: The documentation must not only be available — the agent must be
reminded to use it. A managed rule (not opinionated) ensures consistent behavior
across all projects where llms files are present.

### 4.6 `cco llms` as Dedicated CLI Subcommand

**Decision**: New `cco llms` subcommand family (install, list, update, remove).

**Rationale**: llms files have a distinct lifecycle (install from URL, update
from remote, manage variants) that doesn't fit naturally into `cco pack` or
`cco project` commands.

---

## 5. Scope and Boundaries

### In Scope
- `user-config/llms/` directory structure with source tracking
- `llms:` section in `pack.yml` and `project.yml`
- `cco llms install|list|update|remove` CLI commands
- Mount generation and context injection at `cco start`
- Managed rule for agent guidance
- Variant support (full, medium, small, index)

### Out of Scope
- Automatic discovery of llms.txt for installed frameworks (could be future enhancement)
- RAG indexing of llms.txt content (Sprint 12 concern)
- MCP integration for llms.txt serving (users can add mcpdoc manually)
- Knowledge section for projects (natural extension, but separate feature — can be
  bundled if effort is minimal)

### Dependencies
- No blocking dependencies on other features
- Clean interaction with #9 Pack Inheritance (llms refs inherited naturally)
- Sprint 12 RAG could index llms files in the future
