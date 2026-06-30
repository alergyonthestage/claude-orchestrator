# Git Workflow — claude-orchestrator

This project uses a three-branch workflow. This rule takes precedence
over the global git-practices rule for branch strategy.

## Branch Strategy
- `main` — stable, release-ready. Updated via develop merges or hotfixes.
- `develop` — integration branch. Feature and fix branches merge here.
- `feat/<scope>/<description>` — feature branches, branch from develop.
- `fix/<scope>/<description>` — fix branches, branch from develop.
- `hotfix/<description>` — critical fixes, branch from **main**.

## Feature/Fix Workflow
1. Start: `git checkout develop && git pull && git checkout -b feat/...`
2. Develop on the feature branch with atomic commits
3. Merge into develop (fast-forward or merge commit)
4. Delete the feature branch after merge
5. Merge develop into main when ready to release/publish

## Hotfix Workflow
For critical bugs that must reach main without pulling in develop work:
1. Branch from main: `git checkout main && git checkout -b hotfix/...`
2. Fix and commit
3. Merge to main: `git checkout main && git merge hotfix/...`
4. Merge to develop: `git checkout develop && git merge hotfix/...`
5. Delete the hotfix branch
6. Push both branches

This ensures main gets only the fix, and develop stays in sync.

## Rules
- Never commit directly to main or develop
- Feature/fix branches → develop only (never directly to main)
- Hotfix branches → main first, then develop
- Keep develop in sync: push after each merge
- When develop and main diverge, merge main into develop to reconcile
