# Update System — Changelog & Migrations

When making changes to claude-orchestrator, always consider the impact on existing user installations.

## Additive Changes → `changelog.yml`

When you add a **new user-visible feature or optional config field**:
1. Add a code-level default so existing installations work without changes
2. Update `templates/project/base/` for new projects
3. **Append an entry to `changelog.yml`** (repo root) with the next sequential `id`:
   ```yaml
   - id: <next_id>
     date: "YYYY-MM-DD"
     type: additive
     title: "Short description"
     description: "Details about the new feature and how to use it"
   ```
4. Users are notified via `cco update` (summary) or `cco update --news` (details)

Examples of additive changes: new CLI subcommands, new optional `project.yml` fields, new vault capabilities.

## Breaking Changes → Migrations

When you make a **structural or schema-breaking change** (renames, moves, format changes):
1. Create a migration script in `migrations/{scope}/NNN_description.sh`
   - Scopes: `global`, `project`, `pack`, `template`
   - IDs must be sequential — check `migrations/{scope}/` for the current max
2. The migration must define `MIGRATION_ID=N`, `MIGRATION_DESC="..."`, and a `migrate()` function
3. Every migration **must be idempotent** (safe to run multiple times)
4. Update base template AND non-base native templates
5. If the migration moves an opinionated file, also update `.cco-base/` in the migration
6. Test with `cco update --project <name>` and verify idempotency

## Opinionated Changes → `defaults/global/`

Improvements to framework rules, agents, or skills: update `defaults/global/`. Users discover via `cco update --diff` and apply via `cco update --apply`.

## Reminder

Before completing any implementation task, ask yourself:
- Did I add a new user-visible feature? → Update `changelog.yml`
- Did I rename/move/restructure config files? → Create a migration
- Did I improve a default rule/agent/skill? → Update `defaults/global/`
