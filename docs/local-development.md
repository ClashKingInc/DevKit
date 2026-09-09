# Local integration configuration

DevKit owns the local integration inventory and foreground orchestration, while
each application repository keeps its own start command. The runner manages only
its Valkey and child-process lifecycle. It does not create or stop PostgreSQL,
apply Goose migrations, wipe or reseed databases, deploy Workers, or send live
Discord or push traffic.

The checked-in configuration is [`../local/local-stack.example.json`](../local/local-stack.example.json).
It names the coordinated worktrees explicitly so an API checkout cannot resolve
a coincidental sibling directory. Update those paths when the coordinated
worktrees change. The retained database identity is fixed at
`127.0.0.1:54329/clashking_dev`; local mode rejects remote PostgreSQL, Valkey,
and S3-compatible object-storage endpoints.

Put shared local credentials in `local/.env`. The existing repository `.env`
ignore rule covers that basename at every depth. Every process should load this
single file rather than copying values between repositories. Keep these names in
it as applicable, without committing values:

```dotenv
TIMESCALE_USERNAME=
TIMESCALE_PASSWORD=
VALKEY_PASSWORD=
R2_ACCESS_KEY_ID=
R2_SECRET_ACCESS_KEY=
```

This file is for local infrastructure credentials only. The existing API
launcher keeps its stable local JWT, encryption, API-token, and webhook material
in the current Keychain-backed store; do not download, reset, or rotate it as
part of local orchestration. The user-approved production Discord client secret
and bot token are injected into process memory for the authorized run and must
not be written to `local/.env`. A future partner/test Discord application can
own separate development credentials when that setup is approved.

On macOS, the runner reads the existing Keychain item without creating or
replacing it and passes its API bot token to Tracking. A non-macOS partner must
inject the complete stable API keyset through the API launcher's
`CLASHKING_LOCAL_*` process environment: `DATA_ENCRYPTION_KEY`,
`JWT_ACCESS_SECRET`, `JWT_REFRESH_SECRET`, `API_BOT_TOKEN`, `AI_USAGE_SECRET`,
and `STRIPE_WEBHOOK_SECRET`, each prefixed with `CLASHKING_LOCAL_`. The runner
validates and forwards the complete set in memory, maps its API bot token to
Tracking, and rejects partial or invalid overrides without falling back or
rotating anything.

The local endpoint inventory is:

| Service | Loopback endpoint | Purpose |
| --- | --- | --- |
| PostgreSQL/Timescale | `127.0.0.1:54329`, database `clashking_dev` | Persistent retained development data |
| Valkey | `127.0.0.1:6379` | Shared cache and Streams transport |
| S3-to-R2 development bridge | `http://127.0.0.1:9000`, bucket `clashking-wars` | Shared API/Tracking archive objects owned by the API runtime |
| Clash API proxy or SSH forward | `http://127.0.0.1:8011` | Tracking's bounded live Clash reads; API uses its remote VPC binding |
| Effect Worker API | `http://127.0.0.1:8787` | Shared local API |
| Dashboard | `http://127.0.0.1:3002` | Guild dashboard |
| Admin | `http://127.0.0.1:3000` | Admin dashboard |
| Expo Metro | `http://127.0.0.1:7357` | Native bundle server managed through `tooling/dev-app` |

Tracking jobs that make Clash API reads use a private SSH forward. Establish it
outside the runner so the runner can adopt the listener without owning or
stopping it:

```bash
ssh -N \
  -L 127.0.0.1:8011:127.0.0.1:8011 \
  -o BatchMode=yes \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  root@152.53.82.182
```

The remote target is the proxy's stable loopback listener. Do not forward to a
Docker bridge address. The API does not use this tunnel; leaving
`CLASHKING_LOCAL_CLASH_PROXY_ORIGIN` unset keeps its real remote VPC binding.

Run the configuration and toolchain doctor from the DevKit root:

```bash
node scripts/local-stack.mjs doctor
```

It requires Node 26, npm 12, and Go 1.26.4. It also checks every explicit
repository path, reports each current Git revision and clean/dirty state, and
requires the shared secrets path to exist and remain ignored. It never reads the
secrets file. A failure is diagnostic and does not change local state.

Add read-only TCP probes for every configured service with:

```bash
node scripts/local-stack.mjs status
```

Use `--json` for machine-readable output or `--config /absolute/path/config.json`
for another coordinated checkout set. Output redacts URL credentials, bearer
tokens, and common secret assignments. `status` proves that a port accepts a TCP
connection; it does not claim that schema, credentials, archive contents, or
application behavior are ready.

Start the persistent core stack in the foreground with one command:

```bash
node scripts/local-stack.mjs start
```

PostgreSQL must already be listening with the retained `clashking_dev` database;
the runner never creates, migrates, copies, resets, or stops it. The runner starts
the persistent Compose Valkey service when needed, then starts the API and waits
for both `/v2/health` and the R2 bridge before starting Tracking's `internal-api`
and `war-archiver` domains. Ctrl-C stops owned children in reverse order and
stops Valkey only when this invocation started it; persistent volumes remain.
An already-listening service is reported as adopted and is never killed. The
same doctor checks shown above must pass before `start` changes any state.

Add both web frontends with `--with-frontends`. For Dashboard login, supply `CLASHKING_LOCAL_DISCORD_CLIENT_ID`
(the same public application ID as the API), or `VITE_DISCORD_CLIENT_ID` when
adopting an already-running API. The runner maps only the public ID into Vite,
never the Discord secret or bot token, and rejects a missing ID before startup.
Local Admin uses a loopback-only adapter on `127.0.0.1:8786`, enabled by
`--with-frontends` (`CLASHKING_LOCAL_ADMIN_IDENTITY=1` for a separately started
API). It signs a short-lived `local-developer` identity with an ephemeral key;
the API still runs its ordinary Access signature, issuer and audience checks.
Only AJAX requests from the local Admin's port 3000 are admitted. No production
Access token or authentication bypass is added to the deployed Worker. If the
runner adopts an existing API, restart that API with this flag before using
Admin. The adapter grants owner access to local data; never expose it via a tunnel.
Add Expo Metro with
`--with-expo`. These remain explicit because the core API and Tracking workflow
does not require a browser, simulator, or Metro process. Loopback is suitable
for an iOS Simulator. For a physical phone, also pass an explicit reachable
address such as `--lan-ip 192.168.1.20`; that value configures the API's public
origin and Expo's API URLs, with no saved or guessed Mac address. When the
existing `tooling/dev-app` Metro listener already owns port 7357, the runner
adopts it and never launches or stops a duplicate.

The start command reads only the ignored `local/.env`, then uses these
repository-owned entrypoints and environment mappings:

Before spawning long-running processes, it removes inherited database, Valkey,
Redis, proxy, R2, and API URL aliases that could point at another environment.
Tracking receives freshly constructed loopback Timescale, Valkey, proxy, API,
and archive coordinates, so a parent shell's production variables cannot take
precedence over the local configuration.

Tracking itself loads a repository `.env`, so disabled provider credentials are
passed as explicit empty values rather than merely removed. Both Discord bot
token aliases, both FCM variables, and the Sentry DSN therefore remain disabled
even when the Tracking checkout contains production-oriented defaults. The
default runner never starts the Discord gateway, Discord delivery, or mobile
push domains.

- DevKit Compose owns persistent PostgreSQL and Valkey. It must use
  `HOST_BIND_IP=127.0.0.1`, `TIMESCALE_PORT=54329`,
  `TIMESCALE_DATABASE=clashking_dev`, and `VALKEY_PORT=6379`, without running
  Goose automatically.
- The current API `node scripts/local-api-database.mjs run` command ensures the
  retained container is running and refuses to start unless the database exists;
  it no longer applies Goose automatically. After the coordinator separately
  establishes schema readiness, the shared runner can invoke it with
  `CLASHKING_LOCAL_API_PORT=8787`, its existing Keychain-backed local secret
  injection plus the user-authorized in-memory Discord credential, and
  `CLASHKING_LOCAL_SCHEMA_ROOT=/Users/matthewanderson/.codex/worktrees/1cec/clashking_schemas`
  plus the configured absolute archive import root, explicitly instead of using
  either API script fallback. Leave
  `CLASHKING_LOCAL_CLASH_PROXY_ORIGIN` unset so the API uses the verified remote
  `CLASH_PROXY` VPC binding represented by `apiProviders.clashProxy`.
- Tracking receives the same Timescale and Valkey coordinates,
  `CLASHKING_PROXY_INTERNAL_ORIGIN=http://127.0.0.1:8011`,
  `WAR_ARCHIVE_S3_ENDPOINT=http://127.0.0.1:9000`, and
  `WAR_ARCHIVE_BUCKET=clashking-wars`. The integration test below proves its
  archive writer and the API range-read shape against the same R2 object. Its
  unsigned cache-prime request is pointed at the authenticated loopback bridge,
  where the expected 403 remains a best-effort warning and cannot reach the
  production archive origin.
- Dashboard receives `NEXT_PUBLIC_CLASHKING_API_ORIGIN=http://127.0.0.1:8787`;
  Admin receives `VITE_CLASHKING_API_ORIGIN=http://127.0.0.1:8787`; Expo runs
  from its `expo` workspace with `EXPO_PUBLIC_CK_API_ENV=local` and its API,
  API-v2, proxy, and push base URLs derived from the same loopback API origin.

The API's current local runner separates migration from startup, uses Admin port
3000 for CORS, acquires the remote `CLASH_PROXY` VPC binding, and wires the local
archive bridge below to its in-process Miniflare R2 bucket. The shared runner
starts Tracking only after both the API health endpoint and archive bridge are
ready, then stops Tracking before the bridge and API runtime.

## Local archive bridge boundary

[`../scripts/local-archive-bridge.mjs`](../scripts/local-archive-bridge.mjs)
provides the narrow S3 protocol adapter for the archive alignment above. The API
runtime supplies its existing Miniflare `WAR_ARCHIVE` bucket to
`createLocalArchiveBridge`; the adapter does not create another bucket, object
store, or disk copy. Wiring and startup remain with the API owner.

The adapter binds only `127.0.0.1:9000`, serves only
`clashking-wars/packs/<numeric>.pack`, and implements signed `PutObject`,
`GetObject`, and `HeadObject`, including single byte ranges. It rejects browser
origins, remote peers, other buckets and keys, arbitrary query parameters,
unsigned uploads, delete, list, and multipart operations. Uploads and full reads
are capped at 256 MiB. Its SigV4 verifier checks the configured access key,
signature, signed headers, service scope, payload hash, and a five-minute clock
window; AWS streaming uploads additionally require and verify the SDK checksum.

This remains a loopback development adapter over plain HTTP. SigV4 authenticates
the request, but the SDK's `STREAMING-UNSIGNED-PAYLOAD-TRAILER` mode relies on an
unkeyed checksum for body integrity, and a local process that observes a valid
request could replay it inside the five-minute window. Use a dedicated local
credential, keep the port off LAN/public interfaces, and never reuse production
R2 credentials. The bridge emits no request, authorization, or object logs.

The API wiring order is deliberate: await Miniflare readiness, seed any approved
retained archive objects, obtain `runtime.getR2Bucket('WAR_ARCHIVE')`, then start
the bridge with the shared local R2 access key and secret. Shutdown closes the
bridge first so it cannot accept a write while Miniflare is disposing, then
disposes Miniflare and its remote platform proxy. A bridge bind/authentication
failure must fail API startup and dispose both runtimes rather than starting a
partially connected stack.

Tracking's separate cache-prime request is an unsigned ordinary HTTP range GET,
while this S3 adapter requires SigV4 for every method. The runner deliberately
points `WAR_ARCHIVE_ORIGIN` at the loopback bridge, so that request produces a
best-effort 403 after each successful upload and cannot contact production. The
bridge keeps its authenticated boundary and never adds an anonymous exception.

The bridge has a reproducible cross-repository protocol test:

```bash
node --test scripts/local-archive-bridge.integration.test.mjs
```

It loads the explicit API and Tracking paths from the versioned local
configuration, creates one ephemeral Miniflare `WAR_ARCHIVE` bucket, injects that
bucket into the bridge, and runs a Go `s3.PutObject` client from Tracking's pinned
module. The test then performs the same `{ offset, length }` R2 read used by the
API archive loader and asserts the exact bytes. Credentials and object contents
are test-only, the listener is closed in `finally`, and the temporary Go build
cache is removed. This proves SDK encoding, SigV4 validation, streaming checksum
handling, shared-bucket writes, and API-style range access without starting the
application or touching retained SQL.

No command in this phase performs the retained-data transition. The coordinator
must approve the temporary destination, mapping validation, switch, and eventual
cleanup separately.
