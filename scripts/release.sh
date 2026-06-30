#!/usr/bin/env bash
# scripts/release.sh — cut a cco release (maintainer-run, local). ADR-0037 D6/D7.
#
# Bumps package.json `version` (the single source of truth), runs the test suite
# + the npm-pack hygiene check locally as a fast pre-flight, commits, creates an
# annotated tag, and pushes. Pushing the tag triggers .github/workflows/release.yml
# which re-runs the suite + the read-only FRAMEWORK_ROOT gate + hygiene, then
# `npm publish --access public`. No npm token is needed on this machine — the
# token lives in CI (the NPM_TOKEN GitHub Actions secret).
#
# Usage:
#   scripts/release.sh <x.y.z> [--dry-run] [--allow-branch]
#
#   <x.y.z>          New semantic version (must be > the current package.json one)
#   --dry-run        Show every step without committing/tagging/pushing
#   --allow-branch   Skip the "must be on main" guard (use with care)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '\033[0;36m• %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m✓ %s\033[0m\n' "$*"; }
step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

VERSION=""; DRY_RUN=false; ALLOW_BRANCH=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)      DRY_RUN=true; shift ;;
        --allow-branch) ALLOW_BRANCH=true; shift ;;
        -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
        -*)             die "Unknown option: $1" ;;
        *)              [[ -z "$VERSION" ]] && VERSION="$1" || die "Unexpected argument: $1"; shift ;;
    esac
done

command -v jq  >/dev/null || die "jq is required."
command -v git >/dev/null || die "git is required."
[[ -n "$VERSION" ]] || die "Usage: scripts/release.sh <x.y.z> [--dry-run] [--allow-branch]"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version must be semantic x.y.z (got '$VERSION')."

run() { if $DRY_RUN; then printf '   [dry-run] %s\n' "$*"; else eval "$@"; fi; }

# ── Pre-flight checks ────────────────────────────────────────────────
step "Pre-flight"

local_branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$local_branch" != "main" ]] && ! $ALLOW_BRANCH; then
    die "Releases are cut from 'main' (on '$local_branch'). Merge develop→main first, or pass --allow-branch."
fi

[[ -z "$(git status --porcelain)" ]] || die "Working tree is dirty — commit or stash first."

CURRENT="$(jq -r '.version' package.json)"
[[ "$VERSION" != "$CURRENT" ]] || die "Version $VERSION is already the current package.json version."
# Ensure the new version sorts strictly after the current one.
greatest="$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
[[ "$greatest" == "$VERSION" ]] || die "Version $VERSION is not greater than current $CURRENT."

TAG="v$VERSION"
git rev-parse "$TAG" >/dev/null 2>&1 && die "Tag $TAG already exists."
ok "main / clean tree / $CURRENT → $VERSION / $TAG free"

# Reminder: changelog entries are added per-feature during development, not here.
if ! grep -q "Browse the bundled user docs offline" changelog.yml 2>/dev/null; then :; fi
info "Verify changelog.yml has entries for everything user-visible in this release."

# ── Local gate: suite + hygiene ──────────────────────────────────────
step "Test suite (includes the read-only FRAMEWORK_ROOT gate)"
run "bin/test"

step "npm pack hygiene"
"$REPO_ROOT/scripts/check-pack-hygiene.sh" || die "pack hygiene failed."

# ── Bump, commit, tag, push ──────────────────────────────────────────
step "Bump package.json → $VERSION"
if $DRY_RUN; then
    info "[dry-run] would set package.json .version = $VERSION"
else
    tmp="$(mktemp)"; jq --arg v "$VERSION" '.version = $v' package.json > "$tmp" && mv "$tmp" package.json
    ok "package.json version = $(jq -r .version package.json)"
fi

step "Commit + annotated tag + push"
run "git add package.json"
run "git commit -m 'chore(release): $TAG'"
run "git tag -a '$TAG' -m 'Release $TAG'"
run "git push --follow-tags"

echo ""
ok "Release $TAG prepared."
echo "   CI (.github/workflows/release.yml) now runs the suite + read-only gate +"
echo "   hygiene, then 'npm publish --access public'. Watch the Actions tab."
$DRY_RUN && info "(dry-run: nothing was changed or pushed)"
