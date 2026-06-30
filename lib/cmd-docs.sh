#!/usr/bin/env bash
# lib/cmd-docs.sh — `cco docs`: browse the bundled user documentation offline.
#
# The npm package ships docs/users only (ADR-0037 D3/D9). This surfaces that tree
# on the host, always matched to the INSTALLED cco version — read-only, offline, no
# dependency beyond a pager (falls back to cat / non-TTY). The public GitHub Pages
# site renders the SAME tree (latest-on-main); local vs web is intentional.
#
# Provides: cmd_docs()
# Globals: REPO_ROOT

_docs_root() { printf '%s\n' "$REPO_ROOT/docs/users"; }

# Page a file: pager when interactive and available, else plain cat (CI / pipes).
_docs_page() {
    local f="$1"
    if [[ -t 1 ]] && command -v "${PAGER:-less}" >/dev/null 2>&1; then
        "${PAGER:-less}" "$f"
    else
        cat "$f"
    fi
}

# List available topics (relative paths, README excluded).
_docs_list() {
    local root="$1" f rel
    info "cco user documentation ($root):"
    echo ""
    while IFS= read -r f; do
        rel="${f#"$root"/}"
        printf '  %s\n' "${rel%.md}"
    done < <(find "$root" -type f -name '*.md' ! -name 'README.md' | sort)
    echo ""
    echo "Open one with:  cco docs <topic>     (e.g. cco docs reference/cli)"
}

cmd_docs() {
    case "${1:-}" in
        -h|--help)
            cat <<'EOF'
Usage: cco docs [<topic>]

Browse the bundled cco user documentation offline (read-only).

  cco docs                 List available documentation topics
  cco docs <topic>         Open a topic (matches a path or name under docs/users)

Examples:
  cco docs                 # list all topics
  cco docs cli             # -> reference/cli
  cco docs project-setup   # -> configuration/guides/project-setup

The same docs are published at the project's GitHub Pages site (latest); this
command always shows the version installed on this machine.
EOF
            return 0
            ;;
    esac

    local root; root="$(_docs_root)"
    [[ -d "$root" ]] || die "Bundled docs not found at $root (reinstall cco, or run from the framework root)."

    # No topic → list available topics.
    if [[ -z "${1:-}" ]]; then
        _docs_list "$root"
        return 0
    fi

    local topic="${1%.md}"
    # Resolve, most-specific first: (1) exact relative path, (2) basename,
    # (3) path substring. Exact wins outright.
    local -a matches=()
    local f rel base
    while IFS= read -r f; do
        rel="${f#"$root"/}"; rel="${rel%.md}"
        base="$(basename "$rel")"
        if [[ "$rel" == "$topic" ]]; then matches=("$f"); break; fi
        if [[ "$base" == "$topic" || "$rel" == *"$topic"* ]]; then matches+=("$f"); fi
    done < <(find "$root" -type f -name '*.md' | sort)

    if [[ ${#matches[@]} -eq 0 ]]; then
        error "No doc matches '$topic'."
        echo "Run 'cco docs' to list available topics." >&2
        return 1
    fi
    if [[ ${#matches[@]} -gt 1 ]]; then
        info "Multiple docs match '$topic':"
        local m
        for m in "${matches[@]}"; do rel="${m#"$root"/}"; printf '  %s\n' "${rel%.md}"; done
        echo ""
        echo "Refine with a more specific path, e.g. cco docs ${matches[0]#"$root"/}"
        return 1
    fi
    _docs_page "${matches[0]}"
}
