#!/usr/bin/env bash
# lib/cmd-project-pack-ops.sh — Add/remove packs from projects
#
# Provides: cmd_project_add_pack(), cmd_project_remove_pack(),
#           _project_has_pack(), _project_yml_add_pack(), _project_yml_remove_pack()
# Dependencies: colors.sh, utils.sh, yaml.sh
# Globals: PROJECTS_DIR, PACKS_DIR

cmd_project_add_pack() {
    local project="" pack=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco project add-pack <project> <pack>

Add a knowledge pack to a project's packs list in project.yml.
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$project" ]]; then
                    project="$1"
                elif [[ -z "$pack" ]]; then
                    pack="$1"
                else
                    die "Unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    [[ -z "$project" || -z "$pack" ]] && die "Usage: cco project add-pack <project> <pack>"

    local project_dir="$PROJECTS_DIR/$project"
    local project_yml="$project_dir/project.yml"
    [[ ! -f "$project_yml" ]] && die "Project '$project' not found at $project_dir/"

    # Validate pack exists
    [[ ! -d "$PACKS_DIR/$pack" ]] && die "Pack '$pack' not found in packs/."

    # Check if already present
    if _project_has_pack "$project_yml" "$pack"; then
        warn "Pack '$pack' is already in project '$project'"
        return 0
    fi

    # Add pack to project.yml
    _project_yml_add_pack "$project_yml" "$pack"
    ok "Added pack '$pack' to project '$project'"
}

cmd_project_remove_pack() {
    local project="" pack=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: cco project remove-pack <project> <pack>

Remove a knowledge pack from a project's packs list in project.yml.
EOF
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$project" ]]; then
                    project="$1"
                elif [[ -z "$pack" ]]; then
                    pack="$1"
                else
                    die "Unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    [[ -z "$project" || -z "$pack" ]] && die "Usage: cco project remove-pack <project> <pack>"

    local project_dir="$PROJECTS_DIR/$project"
    local project_yml="$project_dir/project.yml"
    [[ ! -f "$project_yml" ]] && die "Project '$project' not found at $project_dir/"

    # Check if pack is in project
    if ! _project_has_pack "$project_yml" "$pack"; then
        warn "Pack '$pack' is not in project '$project'"
        return 0
    fi

    # Remove pack from project.yml
    _project_yml_remove_pack "$project_yml" "$pack"
    ok "Removed pack '$pack' from project '$project'"
}

# Check if a pack is listed in project.yml's packs section.
_project_has_pack() {
    local file="$1" pack="$2"
    # Match "  - pack-name" under the packs: section
    awk -v pack="$pack" '
        BEGIN { found=0 }
        /^packs:/ { in_packs=1; next }
        in_packs && /^[^ #]/ { exit }
        in_packs && /^  - / {
            sub(/^  - */, "")
            gsub(/[\"'\''[:space:]]/, "")
            if ($0 == pack) { found=1; exit }
        }
        END { exit !found }
    ' "$file"
}

# Add a pack entry to project.yml's packs section.
_project_yml_add_pack() {
    local file="$1" pack="$2"

    if grep -q '^packs: *\[\]' "$file" 2>/dev/null; then
        # Replace empty array with list
        awk -v pack="$pack" '
            /^packs: *\[\]/ { print "packs:"; print "  - " pack; next }
            { print }
        ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    elif grep -q '^packs:' "$file" 2>/dev/null; then
        # Append after last pack entry (or after packs: line if section is empty)
        awk -v pack="$pack" '
            /^packs:/ { in_packs=1; print; next }
            in_packs && /^  - / { last_pack=NR; print; next }
            in_packs && /^[^ #]/ {
                # End of packs section — insert before this line
                if (!inserted) { print "  - " pack; inserted=1 }
                in_packs=0; print; next
            }
            { print }
            END { if (in_packs && !inserted) print "  - " pack }
        ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    elif grep -q '^# packs:' "$file" 2>/dev/null; then
        # Commented-out packs section — replace with active one
        awk -v pack="$pack" '
            /^# packs:/ { print "packs:"; print "  - " pack; next }
            { print }
        ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    else
        # No packs section — append one
        printf '\npacks:\n  - %s\n' "$pack" >> "$file"
    fi
}

# Remove a pack entry from project.yml's packs section.
_project_yml_remove_pack() {
    local file="$1" pack="$2"

    awk -v pack="$pack" '
        /^packs:/ { in_packs=1; print; next }
        in_packs && /^[^ #]/ { in_packs=0; print; next }
        in_packs && /^  - / {
            line=$0
            sub(/^  - */, "", line)
            gsub(/[\"'\''[:space:]]/, "", line)
            if (line == pack) next  # skip this entry
        }
        { print }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"

    # If packs section is now empty, replace with packs: []
    if ! awk '/^packs:/ { in_packs=1; next } in_packs && /^  - / { found=1; exit } in_packs && /^[^ #]/ { exit } END { exit !found }' "$file" 2>/dev/null; then
        _sed_i_raw "$file" 's/^packs:$/packs: []/'
    fi
}
