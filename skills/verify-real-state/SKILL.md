---
name: verify-real-state
description: Ground technical work in the current implementation, repository, remote, generated artifacts, and deployed state. Use before planning, explaining, diagnosing, or changing a codebase when the answer depends on actual files, branches, contracts, configuration, sibling repositories, or live behavior.
---

# Verify Real State

Establish the real working surface before drawing conclusions or making changes.

## Workflow

1. Identify the requested phase: explain, plan, diagnose, implement, publish, or operate.
2. Inspect the current checkout before editing:
   - repository root, branch, worktrees, remotes, and recent commits
   - staged, unstaged, ignored, and untracked files
   - relevant README files, environment examples, tests, and generators
3. Locate the authoritative source before duplicating a contract, schema, model, asset, or generated file.
4. Inspect direct consumers when a change crosses repository or package boundaries.
5. Distinguish local evidence from remote or deployed evidence. If the user says the problem is remote, switch to the remote system instead of continuing local-only analysis.
6. Verify temporally unstable facts through the appropriate live source.
7. State conclusions with concrete paths, commands, versions, endpoints, SHAs, and exact error text.

## Evidence rules

- Prefer current code and live state over remembered conventions.
- Treat names supplied by the user as leads until the exact repository, route, field, or process is verified.
- Do not invent missing schemas, compatibility needs, callers, deployment behavior, or test results.
- Mark inference as inference and identify the evidence supporting it.
- If evidence conflicts, lead with the conflict and resolve it before acting.

## Phase boundary

Stay read-only when the user asks for a plan, diagnosis, review, or recommendation. Implement only when the request authorizes implementation. Publishing, deployment, data mutation, and external messaging require their own explicit scope.

## Handoff

Lead with the current result. Include the exact artifacts inspected or changed, validation performed, unresolved uncertainty, and the next decision the user must make.
