---
name: finish-requested-workflow
description: Carry an authorized task through the user's exact terminal condition instead of stopping at an intermediate artifact. Use when the request says finish, continue, monitor, do not stop, run it, install it, publish it, apply it, repair coverage, or otherwise names an observable end state.
---

# Finish Requested Workflow

Treat the user's terminal condition as the definition of done.

## Define done

Extract the observable endpoint before starting. Examples include:

- process running and monitored
- migration applied and status verified
- generated artifact refreshed and inspected
- branch pushed and PR opened
- app installed on the requested device
- remote data coverage reaches the requested range
- queue or alert count reaches zero

Do not substitute a plan, partial implementation, local test, or progress report for that endpoint.

## Execute persistently

1. Complete each safe in-scope step.
2. Observe the result before choosing the next step.
3. Monitor asynchronous work until success, failure, or a real external blocker.
4. Fix in-scope errors encountered on the path when the user authorized implementation or repair.
5. Keep progress updates concise and current.

## Hold scope steady

Persistence does not broaden authority. Do not deploy, publish, message, delete, contact people, or change production merely because the user said to continue. Respect explicit exclusions and stop expanding systems the user has said are already sufficient.

## Blockers

Exhaust safe diagnostics and alternatives before declaring a blocker. Report the exact missing authority, credential, decision, or external state. Preserve all completed work in the requested state.

## Final handoff

Lead with the observable outcome. Include exact URLs, paths, SHAs, tags, counts, dates, validation, and remaining review items. Do not claim completion while a required check, push, install, migration, or live verification is still pending.
