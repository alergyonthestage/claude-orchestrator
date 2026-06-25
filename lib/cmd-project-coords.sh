#!/usr/bin/env bash
# cco project coords — cross-unit coordinate consistency (ADR-0016 D3, relocated
# to `cco project` by ADR-0023 D1). The STATE index is global-flat (one logical
# name → one path), so a name's `url` coordinate should be the SAME in every
# manifest that references it. This derives a name→url lookup on demand by
# scanning the indexed projects' project.yml — NO persisted artifact (F45) — and
# surfaces (or, with --sync, reconciles) divergence.
#
#   cco project coords                       # full derived name→url lookup
#   cco project coords --diff                # only the divergent names
#   cco project coords --sync --from <unit>  # adopt <unit>'s url for the
#                                            # divergent names across all units
#
# --diff is read-only. --sync NEVER auto-elects a winner — the user names the
# authoritative unit with --from (F48); it edits committed project.yml files, so
# it previews first and confirms (or -y).
#
# Provides: cmd_project_coords()
# Depends:  index.sh (_index_list_projects), cmd-resolve.sh
#           (_resolve_unit_dir_for_project), yaml.sh (*_coords parsers),
#           colors.sh.

# Emit "<name>\t<unit>\t<section>\t<url>\t<ymlpath>" for every url-bearing
# coordinate across all indexed projects. A url-less entry (authored pack,
# local-only repo/mount) carries no coordinate and is skipped — it cannot
# diverge. Peels tab fields by hand so empty middles survive.
_coords_scan() {
    local unit dir yml _ln rest name url
    while IFS='=' read -r unit _; do
        [[ -z "$unit" ]] && continue
        dir=$(_resolve_unit_dir_for_project "$unit" 2>/dev/null) || continue
        yml="$dir/.cco/project.yml"
        [[ -f "$yml" ]] || continue

        while IFS= read -r _ln; do
            [[ -z "$_ln" ]] && continue
            name="${_ln%%$'\t'*}"; rest="${_ln#*$'\t'}"
            url="${rest%%$'\t'*}"
            [[ -n "$name" && -n "$url" ]] && printf '%s\t%s\trepos\t%s\t%s\n' "$name" "$unit" "$url" "$yml"
        done < <(yml_get_repo_coords "$yml")

        while IFS= read -r _ln; do
            [[ -z "$_ln" ]] && continue
            name="${_ln%%$'\t'*}"; rest="${_ln#*$'\t'}"
            url="${rest%%$'\t'*}"
            [[ -n "$name" && -n "$url" ]] && printf '%s\t%s\textra_mounts\t%s\t%s\n' "$name" "$unit" "$url" "$yml"
        done < <(yml_get_mount_coords "$yml")

        while IFS= read -r _ln; do
            [[ -z "$_ln" ]] && continue
            name="${_ln%%$'\t'*}"; rest="${_ln#*$'\t'}"
            rest="${rest#*$'\t'}"; url="${rest#*$'\t'}"   # llms: name desc variant url
            [[ -n "$name" && -n "$url" ]] && printf '%s\t%s\tllms\t%s\t%s\n' "$name" "$unit" "$url" "$yml"
        done < <(yml_get_llms "$yml")

        while IFS= read -r _ln; do
            [[ -z "$_ln" ]] && continue
            name="${_ln%%$'\t'*}"; rest="${_ln#*$'\t'}"
            url="${rest%%$'\t'*}"
            [[ -n "$name" && -n "$url" ]] && printf '%s\t%s\tpacks\t%s\t%s\n' "$name" "$unit" "$url" "$yml"
        done < <(yml_get_pack_coords "$yml")
    done < <(_index_list_projects)
}

# Names that carry >1 distinct url across units (one per line).
_coords_divergent_names() {
    printf '%s\n' "$1" | awk -F'\t' '
        $1=="" { next }
        !seen[$1 SUBSEP $4]++ { cnt[$1]++ }
        END { for (n in cnt) if (cnt[n] > 1) print n }
    ' | sort
}

# Print the lookup. <records> <divergent-only:true|false>
_coords_print() {
    local recs="$1" divergent_only="$2"
    printf '%s\n' "$recs" | awk -F'\t' -v donly="$divergent_only" '
        $1=="" { next }
        !seen[$1 SUBSEP $4]++ { urls[$1] = urls[$1] (urls[$1] ? ", " : "") $4; cnt[$1]++ }
        END {
            any=0
            for (n in cnt) names[++k]=n
            for (i=1;i<=k;i++) for (j=i+1;j<=k;j++) if (names[j]<names[i]) { t=names[i]; names[i]=names[j]; names[j]=t }
            for (i=1;i<=k;i++) {
                n=names[i]
                if (cnt[n] > 1)      { print n ": " urls[n] "  <-- DIVERGENT"; any=1 }
                else if (donly!="true") print n ": " urls[n]
            }
            if (donly=="true" && any==0) print "# all referenced coordinates are consistent across units"
        }'
}

# Rewrite the `url:` of <name> within <section> of <file> to <url>, in place.
# Replaces an existing url sub-key, inserts one when absent, and expands a
# bare-string entry ("  - name") into the coordinate form. Atomic (mktemp+mv).
_coords_set_url() {
    local file="$1" section="$2" name="$3" url="$4" tmp
    tmp=$(mktemp) || return 1
    awk -v sec="$section" -v nm="$name" -v newurl="$url" '
        function flush() { if (in_target && !url_done) { print "    url: " newurl; url_done=1 } }
        /^[A-Za-z_][A-Za-z0-9_-]*:/ {                 # top-level section header
            flush()
            in_sec = ($0 ~ ("^" sec ":")); in_target=0
            print; next
        }
        in_sec && /^  - / {                           # entry header in the section
            flush()
            ename=$0
            if ($0 ~ /^  - name:/) sub(/^  - name:[ ]*/, "", ename)
            else                   sub(/^  -[ ]*/, "", ename)
            gsub(/["\047]/, "", ename); sub(/[ \t]*#.*$/, "", ename); gsub(/^[ \t]+|[ \t]+$/, "", ename)
            if (ename == nm) {
                in_target=1; url_done=0
                if ($0 ~ /^  - name:/) print
                else                   print "  - name: " nm   # expand bare string
                next
            }
            in_target=0; print; next
        }
        in_target && /^    url:/ { print "    url: " newurl; url_done=1; next }
        { print }
        END { flush() }
    ' "$file" > "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

cmd_project_coords() {
    local mode=table from="" force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --diff) [[ "$mode" == sync ]] || mode=diff; shift ;;
            --sync) mode=sync; shift ;;
            --from) from="${2:-}"; shift 2 || die "--from needs a unit name" ;;
            -y|--yes) force=true; shift ;;
            --help|-h)
                cat <<'EOF'
Usage: cco project coords [--diff] [--sync --from <unit>] [-y]

Check (and optionally reconcile) coordinate consistency across your projects.
The index is global-flat (one logical name → one path), so a name's url should
match in every manifest. The lookup is derived on demand — nothing is persisted.

Modes:
  (none)               Print the full derived name → url lookup
  --diff               Print only the names whose url diverges across units
  --sync --from <unit> Adopt <unit>'s url for each divergent name across all
                       units (edits committed project.yml — preview + confirm)

Options:
  --from <unit>        The authoritative project for --sync (never auto-elected)
  -y, --yes            Confirm --sync non-interactively
EOF
                return 0 ;;
            -*) die "Unknown option: $1" ;;
            *)  die "Unexpected argument: $1" ;;
        esac
    done

    local recs; recs=$(_coords_scan)
    if [[ -z "$recs" ]]; then
        info "No coordinates found — no projects reference a url-bearing repo/mount/llms/pack."
        return 0
    fi

    if [[ "$mode" != sync ]]; then
        _coords_print "$recs" "$([[ "$mode" == diff ]] && echo true || echo false)"
        return 0
    fi

    # ---- --sync ----
    [[ -n "$from" ]] || die "--sync requires --from <unit> (cco never auto-elects an authoritative coordinate; ADR-0016 F48)."
    local from_dir; from_dir=$(_resolve_unit_dir_for_project "$from" 2>/dev/null) \
        || die "--from unit '$from' not found (unknown, or its repo is unresolved here — run 'cco resolve $from')."

    local -a names=()
    local n
    while IFS= read -r n; do [[ -n "$n" ]] && names+=("$n"); done < <(_coords_divergent_names "$recs")
    if [[ ${#names[@]} -eq 0 ]]; then
        ok "Coordinates are already consistent across units — nothing to sync."
        return 0
    fi

    # Plan: for each divergent name, adopt <from>'s url everywhere it differs.
    local -a plan=()    # "<file>\t<section>\t<name>\t<oldurl>\t<newurl>\t<unit>"
    local rec rn ru rs rurl ryml from_url
    for n in "${names[@]}"; do
        from_url=$(printf '%s\n' "$recs" | awk -F'\t' -v n="$n" -v u="$from" '$1==n && $2==u {print $4; exit}')
        if [[ -z "$from_url" ]]; then
            warn "skip '$n' — '$from' has no coordinate for it"
            continue
        fi
        while IFS= read -r rec; do
            [[ -z "$rec" ]] && continue
            rn="${rec%%$'\t'*}"; rest="${rec#*$'\t'}"
            ru="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
            rs="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
            rurl="${rest%%$'\t'*}"; ryml="${rest#*$'\t'}"
            [[ "$ru" == "$from" ]] && continue            # don't rewrite the source
            [[ "$rurl" == "$from_url" ]] && continue      # already agrees
            plan+=("$ryml"$'\t'"$rs"$'\t'"$rn"$'\t'"$rurl"$'\t'"$from_url"$'\t'"$ru")
        done < <(printf '%s\n' "$recs" | awk -F'\t' -v n="$n" '$1==n')
    done

    if [[ ${#plan[@]} -eq 0 ]]; then
        ok "Every divergent name already matches '$from' elsewhere — nothing to sync."
        return 0
    fi

    info "Planned coordinate sync (authoritative unit: $from):"
    local p pyml psec pname pold pnew punit
    for p in "${plan[@]}"; do
        pyml="${p%%$'\t'*}"; rest="${p#*$'\t'}"
        psec="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
        pname="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
        pold="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
        pnew="${rest%%$'\t'*}"; punit="${rest#*$'\t'}"
        info "  [$punit] $psec.$pname: $pold -> $pnew"
    done

    if [[ "$force" != true ]]; then
        if [[ ! -t 0 ]]; then
            warn "Non-interactive — re-run with -y to apply, or use --diff to inspect."
            return 0
        fi
        printf 'Apply %d coordinate edit(s) to committed project.yml file(s)? [y/N] ' "${#plan[@]}" >&2
        local ans; read -r ans
        case "$ans" in [yY]|[yY][eE][sS]) ;; *) info "Aborted — nothing changed."; return 0 ;; esac
    fi

    local applied=0
    for p in "${plan[@]}"; do
        pyml="${p%%$'\t'*}"; rest="${p#*$'\t'}"
        psec="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
        pname="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
        rest="${rest#*$'\t'}"          # drop oldurl
        pnew="${rest%%$'\t'*}"         # newurl
        if _coords_set_url "$pyml" "$psec" "$pname" "$pnew"; then
            applied=$(( applied + 1 ))
        else
            warn "failed to edit $pyml ($psec.$pname)"
        fi
    done
    ok "Synced $applied coordinate(s) to '$from'. Commit the updated project.yml file(s) to share."
}
