---
name: setup-pack
description: >
  Assisted knowledge pack creation wizard. Helps the user design and create
  a knowledge pack with proper structure, following best practices for
  composability and documentation.
argument-hint: "[pack name or domain description]"
---

# Setup Pack Wizard

Guide the user through creating a well-structured knowledge pack.

## Step 1: Understand the Domain

Ask the user about:
- **Domain**: What area does this pack cover? (client, org, technology, etc.)
- **Projects**: Which projects will use this pack?
- **Content**: What kind of knowledge? (coding conventions, business context,
  architecture docs, testing guidelines, etc.)
- **Team**: Will this pack be shared with others? (affects structure and docs)

## Step 2: Design Pack Structure

Based on the domain, suggest:
- **Pack name**: Lowercase, hyphens, descriptive (e.g., `acme-backend`, `my-org-core`)
- **Knowledge files**: Suggest files based on the domain, with descriptions
- **Rules**: Are there non-negotiable conventions to enforce? (always-loaded, keep short)
- **Skills/Agents**: Are there domain-specific workflows or specialist agents needed?
- **LLMs.txt**: Does the domain use frameworks with llms.txt support? (e.g., Svelte,
  Tailwind, Drizzle). If so, suggest `cco llms install <url>` and adding `llms:` to
  the pack. This keeps agents current with official API docs.

Apply pack design best practices:
- **Composability**: One pack per concern, no cross-pack dependencies
- **Rules vs Knowledge**: Rules (~30 lines, always loaded) for constraints;
  knowledge (200-500 lines, on-demand) for detailed reference
- **Descriptions**: Action-oriented ("Read when writing backend code...")
- **Start minimal**: Include only what's needed now, expand incrementally
- Read `cco-docs/user-guides/knowledge-packs.md` for reference

If the user has multiple domains, suggest multiple packs with clear boundaries.
Explain the "extract at 2+ consumers" principle — don't create a shared pack
for a single project.

Present the proposed structure and get approval.

## Step 3: Create the Pack (on the host)

The tutorial is read-only, so it cannot create the pack here. Packs live in the
personal store at `~/.cco/packs/<name>/`. Guide the user to either:
- run `cco pack create <name>` on the host, or
- open `cco start config-editor` for hands-on assistance (it has rw access to
  `~/.cco/packs/`).

Either way, the structure is:
1. `~/.cco/packs/<name>/` with `knowledge/`, `rules/`, `agents/`, `skills/`
2. `pack.yml` with the agreed structure and file descriptions
3. placeholder knowledge files with section templates; rule files if agreed

## Step 4: Post-Creation Guidance

After creation:
- Show how to activate the pack: add to `packs:` in project.yml (by name, with
  an optional `url` coordinate if shared).
- Show `cco pack validate <name>` to verify structure.
- Explain the knowledge file descriptions and how Claude uses them.
- If the pack should be shared, mention the **sharing repo** flow and
  `cco pack publish <name> [remote]` (no central manifest).
- Suggest writing knowledge file content (the actual conventions, guidelines).
- Reference: `cco-docs/user-guides/knowledge-packs.md`.
- Remind the user to run `cco config save` on host to version the new pack.

## Important

- Always explain pack design principles (composability, no cross-deps, etc.)
- Show how descriptions guide Claude's on-demand loading
- Reference the official docs for each concept
- Validate pack name format
- If the user's needs are simple, don't over-engineer — a pack with 2-3
  knowledge files is perfectly valid
