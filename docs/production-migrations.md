# Production Goose migrations

The workflow is manual, forward-only, and currently implements the exact 006 to
007 transition. It does not apply on merge or push. Production was reported by
the user to be at 006; the job independently checks that version before writing.
No production migration was performed while authoring this workflow.

## Required setup

At implementation time GitHub reported no DevKit environments and no repository
runners. An organization runner group may exist separately; this workflow
requires the following configuration before it is runnable:

1. Create the `production` environment with required reviewers, prevent self
   review, disable administrator bypass, and use custom deployment policies
   allowing only branch `main` (no tags). The workflow checks these settings via
   GitHub's API both before scheduling private work and again after approval.
   Do not weaken the gate if your GitHub plan lacks required reviewers.
2. Provision a dedicated ephemeral Linux x64 runner in the PostgreSQL private
   network, in runner group `production-migrations`, labelled
   `devkit-production-db`. Restrict the group to this repository's
   `.github/workflows/migrate-production.yml` on `refs/heads/main`; never let
   pull requests run on this group. Install bash, git, Python 3 and GitHub CLI;
   allow outbound GitHub/Go dependency access. The workflow pins Goose v3.26.0.
3. Store `PRODUCTION_DATABASE_URL` only as a production environment secret. Use
   the private database endpoint, a migration role with required DDL privileges,
   and TLS with certificate verification where supported (provision the CA on
   the runner). Do not expose port 5432 publicly for GitHub-hosted runners.
4. Store a read-only fine-grained `PRODUCTION_POLICY_TOKEN` repository secret
   scoped to DevKit with Environments read and Contents read. It is used only
   to inspect protection policy and the main ref; no DB credential is available
   to the hosted preflight job. Missing/inaccessible policy fails closed.

GitHub environments hold approval and secret-release policy; YAML alone cannot
create required reviewers. Runner group restrictions protect private-network
execution from other workflows. See GitHub's [deployment environment reference](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
and [deployment guidance](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/control-deployments).

## Run

Merge the corrective PR and require the schema-upgrade check. Confirm a usable
backup/recovery point and schedule the migration: rebuilding clan_leaderboards
and altering billing_subscriptions may hold locks. Stop other migration writers.
Dispatch **Apply production schema** from main with its full reviewed SHA and
confirmation `apply-006-to-007`. A different main SHA after approval requires a
new dispatch. The protected environment requires another reviewer to approve.

The job validates SQL, requires current Goose version 006, applies only up-to 7
in one transaction, then requires version 007. It bounds lock waits to 10 seconds
and statements to 20 minutes. GitHub concurrency prevents overlapping workflow
runs; it does not coordinate arbitrary manual migration sessions. No connection
string is passed in command arguments. Success logs the commit and version.

If application fails, Goose's transaction rolls back. If the job is interrupted
or loses connectivity, inspect Goose status through the private environment
before retrying: the commit may already have succeeded. A rerun at version 007
is rejected, not interpreted as permission to replay or downgrade. Down is
intentionally irreversible; use a reviewed forward fix or the recovery plan.
Never rewrite version history to make an old 007–028 fixture appear compatible.

For a future production upgrade, review and update the fixed expected/target
versions, dispatch confirmation, upgrade test, and runbook in a new PR. There is
no arbitrary SQL, migration command, branch, or database input in the workflow.

## Recurring materialized-view refresh ownership

The API Worker reads PostgreSQL directly and does not call Tracking or schedule
materialized-view refreshes. Its former five-minute cron and refresher are being
removed by the API task. The migration workflow is not a recurring refresh job.

Migration 007 performs one refresh of the rebuilt clan_leaderboards within its
transaction so the view is populated on commit. That does not keep the view
current afterward. Recurring refreshes belong to a separately operated job with
private database access. No such job is provisioned or verified by this PR;
assign its operator, view inventory and cadence before relying on fresh rankings.
Do not assume the former Worker schedule remains active or recreate it in the
Worker. Other materialized views need their own inventory and initialization
checks; the 007 refresh establishes readiness only for clan_leaderboards.
