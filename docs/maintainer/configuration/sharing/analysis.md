# Analysis: Config Repo — Versioning & Sharing

> **Status**: Analysis — approved, proceeding to design
> **Date**: 2026-03-04
> **Scope**: Sprint 6 (Sharing & Import) + Sprint 10 (Config Vault)
> **Related**: [roadmap.md](../../decisions/roadmap.md) §Sprint 6, §Sprint 10

---

## Table of Contents

1. [Context and Motivation](#1-context-and-motivation)
2. [Problem Space](#2-problem-space)
3. [Current Limitations](#3-current-limitations)
4. [Options Evaluated](#4-options-evaluated)
5. [Key Decisions](#5-key-decisions)
6. [Access Control Model](#6-access-control-model)
7. [Constraints and Non-Goals](#7-constraints-and-non-goals)

---

## 1. Context and Motivation

Sprint 6 (Sharing & Import) and Sprint 10 (Config Vault) address two related but distinct needs:

- **Versioning**: personal backup and rollback of user configuration (global settings, projects, packs)
- **Sharing**: distributing packs, project templates, and rules between users or teams

These sprints were originally designed independently. After analysis, a unified "Config Repo" model was chosen that covers both needs with a single concept and minimal surface area.

**Current users**: the tool author + ~7 team members in a single organization. No public registry exists yet. The design must be simple enough to work today while being extensible toward a future ecosystem of publicly shared packs.

---

## 2. Problem Space

Two orthogonal axes define the requirements:

|                  | **Personal** | **Team / Public** |
|---|---|---|
| **Versioning**   | Rollback config changes, restore after machine loss | Track which pack version each project uses |
| **Sharing**      | Export a specific pack to share with a colleague | Distribute a curated set of packs across the organization |

Key constraint: sharing must be **granular** (share one pack, not everything) without causing **repo proliferation** (not one git repo per pack).

---

## 3. Current Limitations

| Limitation | Impact |
|---|---|
| `global/` and `projects/` are gitignored | No versioning or backup for user configuration |
| Packs are local only (`global/packs/`) | No mechanism to share a pack with another user |
| Packs are nested inside `global/` | Makes `global/` serve two different purposes: personal `.claude/` config AND reusable packs |
| No `templates/` concept | Project templates (shareable `project.yml` scaffolds) have no dedicated location |
| `global/`, `projects/` are separate top-level dirs | Two directories to manage, gitignore, or version — no single root for user data |

---

## 4. Options Evaluated

### Option A — Two separate systems (original plan)
- **Vault** (S10): a git repo wrapping `global/` + `projects/`
- **Share** (S6): `cco pack install <git-url>` with a `manifest.yml` manifest in each shared repo

**Rejected because**: vault and share repos have identical structure — two separate concepts for the same thing. If the user wants to share something from their vault, they need to configure two systems.

---

### Option B — Unified git model ("vault IS the share")
`global/` becomes a git repo. Versioning and sharing are the same concept: share by pushing (or making public) the repo or a branch.

**Rejected in pure form because**: within a single git repo, you cannot have some directories public and others private. Granular access control is impossible without multiple repos.

---

### Option C — Per-pack git repos
Each pack is an autonomous git repo cloned into `global/packs/<name>/`.

**Rejected because**: repo proliferation (10 packs = 10 repos to manage). No versioning for global `.claude/` settings. Vault would remain a separate system.

---

### Option D — Tarball / archive exchange
`cco pack export` → `.tar.gz`, `cco pack import` → extract.

**Rejected because**: no incremental updates, no history, no integrity guarantees without checksums. Manual file transfer does not scale even for a small team.

---

### Option E — External config directory (dotfiles style)
Dedicated config directory outside the tool repo, managed by CCO, versioned separately.

**Partial adoption**: the external directory concept (`~/.cco/`) is adopted, but as one of two supported modes rather than as a replacement. Users can choose between an in-repo `user-config/` and an external directory.

---

### Chosen: Config Repo model (B + E hybrid)

**Core insight**: the granular-without-proliferation requirement is solved by **git sparse-checkout**, not by per-resource repos.

```bash
# Install one pack from a repo that contains many
git clone --no-checkout --filter=blob:none <repo-url> /tmp/cco-tmp
git -C /tmp/cco-tmp sparse-checkout set packs/my-pack
git -C /tmp/cco-tmp checkout
```

This allows a single shared repo to contain multiple packs, while consumers install only the subset they need. Works with any git host (GitHub, GitLab, self-hosted Gitea).

---

## 5. Key Decisions

### KD-1: One concept — Config Repo

A Config Repo is a git repository that follows a standard directory convention. It can serve as:
1. **Personal vault**: private repo backing all user config
2. **Shared bundle**: public or team-private repo with selected resources
3. **Both**: the vault made public (or specific branches/remotes)

The user manages access at the git hosting level, not through CCO.

### KD-2: Packs elevated out of `global/`

Currently packs live at `global/packs/`. In the new model, `packs/` is a top-level directory of the Config Repo, at the same level as `global/` and `projects/`. This reflects the different nature of packs (reusable, shareable) vs global settings (personal).

### KD-3: Unified user data root — `user-config/`

Instead of separate top-level `global/` and `projects/` directories in the tool repo, a single `user-config/` directory holds all user-owned data. This directory:
- Is gitignored in the claude-orchestrator tool repo
- Can be initialized as a git repo independently (the vault)
- Has the same structure whether it lives inside the tool repo or at an external path (e.g. `~/.cco/`)

### KD-4: Access control delegated to git hosting

CCO does not implement resource-level access control. Visibility and authentication are properties of the git repo, not of individual resources within it. Consequence: resources with different visibility levels require different repos.

### KD-5: Pack source tracking

Each pack installed from a remote source stores a `.cco-source` metadata file recording the origin URL, path, and ref. This enables `cco pack update <name>` to pull the latest version from the original source without user intervention.

---

## 6. Access Control Model

### Visibility is per-repo, not per-resource

| Visibility | Mechanism | Example |
|---|---|---|
| Private (only you) | Private git repo | vault at `github.com/user/my-cco-config` (private) |
| Team-private | Private repo with org/team access | `github.com/company/team-config` (private, members only) |
| Public | Public git repo | `github.com/user/public-packs` (public) |

Within a single repo, all resources share the same access level. To share pack A publicly and keep pack B private, they must live in separate repos.

### Repo proliferation is bounded

The key observation: resources with the **same access level** coexist in the **same repo**. The number of repos is proportional to the number of distinct access tiers, not to the number of resources.

Typical user:
- 1 private vault (all personal config + private packs)
- 0–1 public repo (public packs, if any)
- 0–1 team repo (team-shared packs)

A team of 7 sharing a common pack set: 1 team repo. Not 7 × N repos.

### Authentication in CCO

CCO resolves credentials in this order:
1. SSH agent (SSH git URLs)
2. `GITHUB_TOKEN` environment variable (already used for `gh` CLI)
3. `--token <value>` flag on install commands
4. System git credential helper

No custom token storage is needed. Users configure credentials once at the system level.

### Future: selective publishing

A future `cco pack publish <name> --to <remote>` command could automate `git subtree push` to push a specific pack subdirectory to a separate remote (e.g. public). This avoids maintaining a separate repo manually. Deferred — not needed for Sprint 6.

---

## 7. Constraints and Non-Goals

**Constraints**:
- Must work without a registry or dedicated server
- Must not require per-user account management in CCO
- Installation must work with any git host (not GitHub-specific)
- Secrets (`secrets.env`, `.credentials.json`) must never appear in a shared or versioned repo

**Non-goals for Sprint 6 + 10**:
- Public registry / index of shared repos (future sprint)
- Selective per-directory publishing within a repo (`git subtree push`)
- Fine-grained token scoping per resource within a repo
- Dependency resolution between packs (Pack A requires Pack B)
- Semantic versioning / lockfile for pack dependencies
