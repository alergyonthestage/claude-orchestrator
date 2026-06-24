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
#   cmd-project-delete.sh        — cmd_project_delete()
#   cmd-project-query.sh         — cmd_project_list(), cmd_project_show(), cmd_project_validate()
#   cmd-project-pack-ops.sh      — cmd_project_add_pack(), cmd_project_remove_pack(), _project_has_pack(), _project_yml_add_pack(), _project_yml_remove_pack()
#   cmd-project-add.sh           — cmd_project_add()
#   cmd-project-export-import.sh — cmd_project_export(), cmd_project_import()
#
# All files are sourced by bin/cco. This stub is kept for reference only.
