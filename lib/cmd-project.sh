#!/usr/bin/env bash
# lib/cmd-project.sh — STUB (split into separate files)
#
# This file has been split into:
#   (cmd-project-create.sh removed in P3-3b — replaced by `cco init`, ADR-0026;
#    _resolve_template_vars() relocated to cmd-template.sh)
#   (cmd-project-{install,publish,update}.sh removed in P4-4 — projects are not
#    published/installed/updated from a sharing repo; they ride the code-repo
#    remote, ADR-0018 D2. The current project-internalize semantic is retired
#    with them, ADR-0023 D4c. Sharing a project = cmd-project-export-import.sh.)
#   (cmd-project-delete.sh + cmd-project-pack-ops.sh removed in P4-5 — the tier-2
#    legacy verbs project delete/resolve/validate<name>/add-pack/remove-pack are
#    retired with no alias, AD12. Deregistration returns via `cco forget` and
#    share-readiness validation via `cco project validate` in a later release;
#    pack coordinates are embedded with `cco project add pack`, ADR-0023 D3.)
#   cmd-project-query.sh         — cmd_project_list(), cmd_project_show()
#   cmd-project-add.sh           — cmd_project_add()
#   cmd-project-export-import.sh — cmd_project_export(), cmd_project_import()
#
# All files are sourced by bin/cco. This stub is kept for reference only.
