---
name: preserve-git-work
description: Preserve existing user changes and exact Git state while switching branches, moving worktrees, staging, committing, pushing, opening or removing pull requests, or cleaning up branches. Use whenever a task touches a dirty repository or specifies local-only, no-push, branch, PR, commit, reset, or restoration requirements.
---

# Preserve Git Work

Make the requested Git transition without losing, publishing, or absorbing unrelated work.

## Inspect before mutation

Run and interpret:

- `git status -sb`
- `git diff --name-status`
- `git diff --cached --name-status`
- `git ls-files --others --exclude-standard`
- `git worktree list` when branches may be checked out elsewhere
- `git remote -v` before any remote operation

Inspect overlapping files individually. Treat every pre-existing change as user-owned.

## Preserve scope

- Stage explicit paths in a mixed worktree.
- Keep generated, ignored, and untracked artifacts separate from intended source changes.
- Never discard or rewrite user work to make a branch operation easier.
- Use a reversible safety mechanism before moving a dirty checkout. Verify restoration file by file before removing the backup.
- When paths move, remap preserved edits to the new paths and confirm content equivalence.

## Respect publication boundaries

Translate the user's words literally:

- `commit locally` does not authorize push.
- `push this branch` does not authorize merging.
- `make a PR` does not authorize making it ready or merging unless specified.
- `review before push` means leave the work only in the requested local state.
- `delete the branch locally and remotely` means verify both refs are gone and handle any associated PR explicitly.

If the user changes the desired handoff after publication, unwind the remote PR or branch, preserve local work, and verify the exact final state.

## Destructive operations

Use destructive commands only when clearly requested. Prefer non-destructive, inspectable transitions. Never use a hard reset or blanket cleanup as a shortcut around a mixed worktree.

## Final verification

Report:

- current local branch or detached state
- local HEAD and divergence from the remote
- remaining staged, unstaged, and untracked files
- remote branch and PR state
- whether anything was pushed, merged, deleted, or left local
