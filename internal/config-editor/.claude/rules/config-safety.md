# Config Editor Safety Rules

## Before Modifying Files
- Check if the file exists before writing — show the diff if overwriting.
- For `project.yml` edits, validate YAML structure after changes; keep it
  machine-agnostic (logical names + coordinates, never real host paths).
- For `pack.yml` edits, remind the user to run `cco pack validate` on host.

## Protected Content
- **Never** write real secret values into a committed file. `secrets.env` is
  gitignored and host-edited; only `*.example` skeletons are committed.
- **Never** delete projects or packs without explicit confirmation.
- cco-internal data (the index, `tags.yml`, remotes, caches, transcripts) is
  managed only via `cco …` and is **not** mounted here — do not try to edit it.

## Versioning & Sharing Awareness
- After significant edits to `~/.cco` (mounted at `/workspace/cco-config`),
  remind the user: `cco config save` on host (and `cco config push` to sync).
- To review pending changes: `git -C ~/.cco status` / `git -C ~/.cco diff`.
- If the user mentions sharing/publishing, reference the **sharing repo** flow
  (`cco pack publish` / `cco pack install`) — there is no `manifest.yml`.

## cco Commands
- cco CLI commands CANNOT run inside this container — they are host-only.
- When an action requires cco, show the exact command for the user's host
  terminal and explain what it does.
