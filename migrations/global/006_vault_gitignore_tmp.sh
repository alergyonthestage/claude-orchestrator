#!/usr/bin/env bash
# Migration: Add projects/*/.tmp/ to vault .gitignore
#
# dry-run now writes generated files to <project>/.tmp/ instead of /tmp/.
# Existing vault .gitignore files need this entry to exclude dry-run artifacts.

MIGRATION_ID=6
MIGRATION_DESC="Add projects/*/.tmp/ to vault .gitignore (dry-run output dir)"

# $1 = target directory (global/.claude)
# Must be idempotent (safe to run multiple times)
# Return 0 on success, non-zero on failure
migrate() {
    local target_dir="$1"

    # Derive user-config dir: global/.claude → global → user-config
    local global_dir user_config_dir
    global_dir="$(dirname "$target_dir")"
    user_config_dir="$(dirname "$global_dir")"

    local gitignore="$user_config_dir/.gitignore"

    # No vault initialized: nothing to do
    if [[ ! -f "$gitignore" ]]; then
        return 0
    fi

    # Already has the entry: idempotent no-op
    if grep -qF 'projects/*/.tmp/' "$gitignore" 2>/dev/null; then
        return 0
    fi

    # Insert after projects/*/.managed/ (contextually appropriate)
    # Use awk for macOS/Linux compatibility (BSD sed -i and 'a' command differ)
    if grep -qF 'projects/*/.managed/' "$gitignore" 2>/dev/null; then
        awk '/projects\/\*\/\.managed\//{print; print "projects/*/.tmp/"; next}1' \
            "$gitignore" > "$gitignore.tmp" && mv "$gitignore.tmp" "$gitignore"
    else
        # Fallback: append to end
        echo "" >> "$gitignore"
        echo "# Dry-run output — generated, not user config" >> "$gitignore"
        echo "projects/*/.tmp/" >> "$gitignore"
    fi

    echo "[migration-006] Added projects/*/.tmp/ to vault .gitignore" >&2
    return 0
}
