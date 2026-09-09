import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { buildServicePlan, loadConfig, loadLocalEnvironment, readExistingLocalApiBotToken, redactText, resolveLocalApiBotToken, runDoctor, runStatus, startLocalStack, validateConfig } from './local-stack.mjs';

function fixture(root) {
  const repositories = Object.fromEntries(['devkit', 'api', 'tracking', 'dashboard', 'admin', 'app'].map((name) => {
    const path = join(root, name);
    mkdirSync(path, { recursive: true });
    return [name, path];
  }));
  const secretsEnv = join(root, 'devkit', 'local', '.env');
  mkdirSync(join(root, 'devkit', 'local'), { recursive: true });
  writeFileSync(secretsEnv, 'TEST_SECRET=never-print-this\n');
  return {
    schemaVersion: 1,
    mode: 'local',
    toolchains: { node: '26', npm: '12', go: '1.26.4' },
    repositories,
    secretsEnv,
    archiveImportRoot: join(root, 'api', '.local', 'imported-archives', 'packs'),
    apiProviders: { clashProxy: 'remote-vpc' },
    services: {
      postgres: { host: '127.0.0.1', port: 54329, database: 'clashking_dev' },
      valkey: { host: '127.0.0.1', port: 6379 },
      r2: { endpoint: 'http://127.0.0.1:9000', bucket: 'clashking-wars' },
      proxy: { origin: 'http://127.0.0.1:8011' },
      api: { origin: 'http://127.0.0.1:8787' },
      tracking: { origin: 'http://127.0.0.1:8091' },
      dashboard: { origin: 'http://127.0.0.1:3002' },
      admin: { origin: 'http://127.0.0.1:3000' },
      expo: { origin: 'http://127.0.0.1:7357' },
    },
  };
}

test('loads and normalizes the versioned local configuration', () => {
  const root = mkdtempSync(join(tmpdir(), 'ck-local-stack-'));
  const configPath = join(root, 'config.json');
  writeFileSync(configPath, JSON.stringify(fixture(root)));
  const config = loadConfig(configPath);
  assert.equal(config.services.postgres.database, 'clashking_dev');
  assert.equal(config.services.api.port, 8787);
  assert.equal(config.services.r2.host, '127.0.0.1');
  assert.equal(config.apiProviders.clashProxy, 'remote-vpc');
});

test('rejects remote SQL, Valkey, and R2 endpoints in local mode', () => {
  const root = mkdtempSync(join(tmpdir(), 'ck-local-stack-'));
  for (const mutate of [
    (value) => { value.services.postgres.host = 'db.example.com'; },
    (value) => { value.services.valkey.host = 'valkey.example.com'; },
    (value) => { value.services.r2.endpoint = 'https://r2.example.com:443'; },
  ]) {
    const config = fixture(root);
    mutate(config);
    assert.throws(() => validateConfig(config), /loopback/u);
  }
});

test('rejects the wrong retained database and port collisions', () => {
  const root = mkdtempSync(join(tmpdir(), 'ck-local-stack-'));
  const wrongDatabase = fixture(root);
  wrongDatabase.services.postgres.database = 'production';
  assert.throws(() => validateConfig(wrongDatabase), /clashking_dev/u);
  const collision = fixture(root);
  collision.services.admin.origin = collision.services.dashboard.origin;
  assert.throws(() => validateConfig(collision), /conflicts/u);
});

test('redacts credentials and common secret assignments', () => {
  const value = redactText('postgres://user:password@127.0.0.1/db Bearer abc.def token=visible password:visible');
  assert.equal(value.includes('password'), true);
  assert.equal(value.includes('abc.def'), false);
  assert.equal(value.includes('visible'), false);
  assert.equal(value.includes('user:password'), false);
});

test('doctor reports pinned tools plus git revision and dirty state without reading secrets', () => {
  const root = mkdtempSync(join(tmpdir(), 'ck-local-stack-'));
  const config = validateConfig(fixture(root));
  const calls = [];
  const spawnSync = (command, args, options) => {
    calls.push({ command, args, cwd: options.cwd });
    if (command === 'node') return { status: 0, stdout: 'v26.8.1\n', stderr: '' };
    if (command === 'npm') return { status: 0, stdout: '12.0.1\n', stderr: '' };
    if (command === 'go') return { status: 0, stdout: 'go version go1.26.4 darwin/arm64\n', stderr: '' };
    if (args.includes('check-ignore')) return { status: 0, stdout: '', stderr: '' };
    if (args.includes('rev-parse')) return { status: 0, stdout: 'abcdef0123456789\n', stderr: '' };
    return { status: 0, stdout: options.cwd.endsWith('/api') ? ' M owner-work.ts\n' : '', stderr: '' };
  };
  const checks = runDoctor(config, { spawnSync, existsSync: () => true });
  assert.equal(checks.every((check) => check.ok), true);
  assert.equal(checks.find((check) => check.name === 'repository:api').detail, 'abcdef012345 dirty');
  assert.equal(calls.some((call) => call.args.includes('check-ignore')), true);
  assert.equal(JSON.stringify(checks).includes('never-print-this'), false);
});

test('status probes every configured service and retains doctor failures', async () => {
  const root = mkdtempSync(join(tmpdir(), 'ck-local-stack-'));
  const config = validateConfig(fixture(root));
  const spawnSync = (command, args) => {
    if (command === 'node') return { status: 0, stdout: 'v24.0.0\n', stderr: '' };
    if (command === 'npm') return { status: 0, stdout: '12.0.1\n', stderr: '' };
    if (command === 'go') return { status: 0, stdout: 'go version go1.26.4 darwin/arm64\n', stderr: '' };
    if (args.includes('check-ignore')) return { status: 0, stdout: '', stderr: '' };
    if (args.includes('rev-parse')) return { status: 0, stdout: 'abcdef0123456789\n', stderr: '' };
    return { status: 0, stdout: '', stderr: '' };
  };
  const probes = [];
  const checks = await runStatus(config, {
    spawnSync,
    existsSync: () => true,
    probeTcp: async (host, servicePort) => {
      probes.push(`${host}:${servicePort}`);
      return { ok: servicePort !== 9000, detail: servicePort === 9000 ? 'ECONNREFUSED' : 'listening' };
    },
  });
  assert.equal(probes.length, 9);
  assert.equal(checks.find((check) => check.name === 'toolchain:node').ok, false);
  assert.equal(checks.find((check) => check.name === 'service:r2').ok, false);
});

test('loads only explicit local assignments and builds a fail-closed service plan', () => {
  const root = mkdtempSync(join(tmpdir(), 'ck-local-stack-'));
  const config = validateConfig(fixture(root));
  const secrets = loadLocalEnvironment(config.secretsEnv, { readFileSync: () => [
    'TIMESCALE_USERNAME=clashking_local', 'TIMESCALE_PASSWORD=local-db', 'VALKEY_PASSWORD=local-cache',
    'R2_ACCESS_KEY_ID=local-r2', 'R2_SECRET_ACCESS_KEY=local-r2-secret',
  ].join('\n') });
  const plan = buildServicePlan(config, secrets, { dashboard: true, admin: true, expo: true, apiBotToken: 'a'.repeat(43) }, {
    DISCORD_BOT_TOKEN: 'must-be-cleared', MOBILE_PUSH_FCM_PROJECT_ID: 'must-be-cleared', SENTRY_DSN: 'must-be-cleared',
    DATABASE_URL: 'postgres://production.invalid/live', TIMESCALE_URL: 'postgres://production.invalid/live',
    VALKEY_ADDR: 'production.invalid:6379', VALKEY_URL: 'redis://production.invalid:6379', REDIS_URL: 'redis://production.invalid:6379',
    PROXY_URL: 'https://production.invalid', R2_ENDPOINT: 'https://production.invalid', R2_ENDPOINT_URL: 'https://production.invalid',
    R2_ACCOUNT_ID: 'production-account', R2_WARS_BUCKET: 'production-bucket', CLASHKING_API_URL: 'https://production.invalid',
    CLASHKING_API_TOKEN: 'production-token',
    CLASHKING_LOCAL_DISCORD_CLIENT_ID: '123', CLASHKING_LOCAL_DISCORD_CLIENT_SECRET: 'oauth-secret', CLASHKING_LOCAL_DISCORD_BOT_TOKEN: 'bot-secret',
    CLASHKING_LOCAL_JWT_ACCESS_SECRET: 'stable-api-only',
  });
  const api = plan.services.find((service) => service.name === 'api');
  const dashboard = plan.services.find((service) => service.name === 'dashboard');
  assert.equal(dashboard.env.VITE_DISCORD_CLIENT_ID, '123');
  assert.equal(dashboard.env.CLASHKING_LOCAL_DISCORD_CLIENT_SECRET, undefined);
  assert.equal(dashboard.env.CLASHKING_LOCAL_DISCORD_BOT_TOKEN, undefined);
  assert.throws(() => buildServicePlan(config, secrets, { dashboard: true, apiBotToken: 'a'.repeat(43) }, {}), /DISCORD_CLIENT_ID/);
  assert.equal(buildServicePlan(config, secrets, { dashboard: true, apiBotToken: 'a'.repeat(43) }, { VITE_DISCORD_CLIENT_ID: '456' }).services.find(service => service.name === 'dashboard').env.VITE_DISCORD_CLIENT_ID, '456');
  const tracking = plan.services.find((service) => service.name === 'tracking:internal-api');
  assert.equal(api.env.CLASHKING_LOCAL_LAN_IP, '127.0.0.1');
  assert.equal(api.env.CLASHKING_LOCAL_ADMIN_IDENTITY, '1');
  assert.equal(plan.services.find(service => service.name === 'admin').env.VITE_CLASHKING_API_ORIGIN, 'http://127.0.0.1:8786');
  assert.equal(api.env.CLASHKING_LOCAL_INFRA_ENV, config.secretsEnv);
  assert.equal(api.env.CLASHKING_LOCAL_CLASH_PROXY_ORIGIN, undefined);
  assert.equal(api.env.CLASHKING_LOCAL_DISCORD_CLIENT_SECRET, 'oauth-secret');
  assert.equal(api.env.CLASHKING_LOCAL_JWT_ACCESS_SECRET, 'stable-api-only');
  assert.equal(tracking.env.DISCORD_BOT_TOKEN, '');
  assert.equal(tracking.env.BOT_TOKEN, '');
  assert.equal(tracking.env.CLASHKING_LOCAL_DISCORD_BOT_TOKEN, undefined);
  assert.equal(tracking.env.CLASHKING_LOCAL_JWT_ACCESS_SECRET, undefined);
  assert.equal(tracking.env.MOBILE_PUSH_FCM_PROJECT_ID, '');
  assert.equal(tracking.env.MOBILE_PUSH_FCM_SERVICE_ACCOUNT_JSON, '');
  assert.equal(tracking.env.SENTRY_DSN, '');
  assert.equal(tracking.env.DISCORD_MESSAGE_CREATE_ENABLED, 'false');
  assert.equal(tracking.env.API_BOT_TOKEN, 'a'.repeat(43));
  for (const name of ['DATABASE_URL', 'TIMESCALE_URL', 'VALKEY_ADDR', 'VALKEY_URL', 'REDIS_URL', 'PROXY_URL', 'R2_ENDPOINT', 'R2_ENDPOINT_URL', 'R2_ACCOUNT_ID', 'R2_WARS_BUCKET', 'CLASHKING_API_URL', 'CLASHKING_API_TOKEN']) {
    assert.equal(tracking.env[name], undefined, `${name} must not reach Tracking`);
  }
  assert.equal(tracking.env.TIMESCALE_HOST, '127.0.0.1');
  assert.equal(tracking.env.VALKEY_HOST, '127.0.0.1');
  assert.equal(tracking.env.CLASHKING_PROXY_INTERNAL_ORIGIN, 'http://127.0.0.1:8011');
  assert.equal(tracking.env.WAR_ARCHIVE_S3_ENDPOINT, 'http://127.0.0.1:9000');
  assert.equal(tracking.env.WAR_ARCHIVE_ORIGIN, 'http://127.0.0.1:9000/clashking-wars');
  assert.deepEqual(plan.services.map((service) => service.name), ['api', 'tracking:internal-api', 'tracking:war-archiver', 'dashboard', 'admin', 'expo']);
  const expo = plan.services.find((service) => service.name === 'expo');
  assert.equal(expo.cwd, join(config.repositories.app, 'expo'));
  assert.equal(expo.env.EXPO_PUBLIC_CK_API_V2_BASE_URL, 'http://127.0.0.1:8787/v2');
});

test('reads the existing Keychain API token without creating or replacing the item', () => {
  const calls = [];
  const token = readExistingLocalApiBotToken({
    platform: 'darwin',
    spawnSync: (command, args) => {
      calls.push([command, ...args]);
      return { status: 0, stdout: JSON.stringify({ API_BOT_TOKEN: 'z'.repeat(43) }) };
    },
  });
  assert.equal(token, 'z'.repeat(43));
  assert.equal(calls[0].includes('find-generic-password'), true);
  assert.equal(calls[0].includes('add-generic-password'), false);
});

test('uses an explicit process-only API token on non-macOS hosts', () => {
  const environment = Object.fromEntries([
    'DATA_ENCRYPTION_KEY', 'JWT_ACCESS_SECRET', 'JWT_REFRESH_SECRET', 'API_BOT_TOKEN', 'AI_USAGE_SECRET', 'STRIPE_WEBHOOK_SECRET',
  ].map((name) => [`CLASHKING_LOCAL_${name}`, name === 'API_BOT_TOKEN' ? 'x'.repeat(43) : 'y'.repeat(43)]));
  assert.equal(resolveLocalApiBotToken(environment, {
    platform: 'linux', spawnSync: () => { throw new Error('Keychain must not be read'); },
  }), 'x'.repeat(43));
  assert.throws(() => resolveLocalApiBotToken({ CLASHKING_LOCAL_API_BOT_TOKEN: 'x'.repeat(43) }, { platform: 'linux' }), /complete/u);
  assert.throws(() => resolveLocalApiBotToken({}, { platform: 'linux' }), /macOS Keychain/u);
});

test('starts in dependency order and stops only owned children in reverse order', async () => {
  const root = mkdtempSync(join(tmpdir(), 'ck-local-stack-'));
  const config = validateConfig(fixture(root));
  let valkeyOpen = false;
  let apiOpen = false;
  const events = [];
  const fetches = [];
  let nextPid = 100;
  const runtime = await startLocalStack(config, {}, {
    apiBotToken: 'a'.repeat(43),
    stabilityMs: 0,
    environment: {},
    readFileSync: () => [
      'TIMESCALE_USERNAME=clashking_local', 'TIMESCALE_PASSWORD=local-db', 'VALKEY_PASSWORD=local-cache',
      'R2_ACCESS_KEY_ID=local-r2', 'R2_SECRET_ACCESS_KEY=local-r2-secret',
    ].join('\n'),
    output: (message) => events.push(message),
    killOwned: (child, signal) => {
      events.push(`kill:${child.localName}:${signal}`);
      queueMicrotask(() => child.emit('exit', 0, signal));
    },
    spawnSync: (command, args) => {
      assert.equal(command, 'docker');
      if (args.includes('inspect')) return { status: 0, stdout: 'unix:///var/run/docker.sock\n' };
      if (args.includes('up')) valkeyOpen = true;
      return { status: 0 };
    },
    spawn: (command, args) => {
      const child = new EventEmitter();
      child.pid = nextPid++;
      child.localName = args.at(-1) === 'run' ? 'api' : args.at(-1);
      events.push(`spawn:${child.localName}`);
      if (args.at(-1) === 'run') apiOpen = true;
      return child;
    },
    probeTcp: async (_host, servicePort) => ({
      ok: servicePort === 54329 || (servicePort === 6379 && valkeyOpen) || ([8787, 9000].includes(servicePort) && apiOpen), detail: 'test',
    }),
    fetch: async (url, init) => { fetches.push({ url, init }); return { ok: apiOpen }; },
  });
  assert.deepEqual(events.filter((event) => event.startsWith('spawn:')), ['spawn:api', 'spawn:internal-api', 'spawn:war-archiver']);
  assert.equal(events.includes('Clash proxy tunnel is unavailable; core internal-api and war-archiver domains can still start'), true);
  const trackingReady = fetches.find((call) => call.url.includes('/internal/verified-players/refresh'));
  assert.equal(trackingReady.init.headers.Authorization, `Bearer ${'a'.repeat(43)}`);
  assert.equal(trackingReady.init.body, '{"player_tags":[]}');
  await runtime.stop();
  assert.deepEqual(events.filter((event) => event.startsWith('kill:')), [
    'kill:war-archiver:SIGTERM', 'kill:internal-api:SIGTERM', 'kill:api:SIGTERM',
  ]);
  assert.equal(events.some((event) => event.includes('docker') && event.includes('kill')), false);
});

test('adopts existing listeners and never spawns or stops them', async () => {
  const root = mkdtempSync(join(tmpdir(), 'ck-local-stack-'));
  const config = validateConfig(fixture(root));
  const spawned = [];
  const runtime = await startLocalStack(config, {}, {
    apiBotToken: 'a'.repeat(43), environment: {},
    readFileSync: () => 'TIMESCALE_USERNAME=u\nTIMESCALE_PASSWORD=p\nVALKEY_PASSWORD=v\nR2_ACCESS_KEY_ID=a\nR2_SECRET_ACCESS_KEY=s\n',
    output: () => undefined,
    killOwned: (child, signal) => { queueMicrotask(() => child.emit('exit', 0, signal)); },
    spawnSync: () => { throw new Error('must not manage adopted Valkey'); },
    spawn: (_command, args) => {
      spawned.push(args.at(-1));
      const child = new EventEmitter(); child.pid = 200 + spawned.length;
      return child;
    },
    probeTcp: async (_host, servicePort) => ({ ok: [54329, 6379, 8011, 8787, 9000, 8091].includes(servicePort), detail: 'test' }),
    fetch: async () => ({ ok: true }),
  });
  assert.deepEqual(spawned, []);
  await runtime.stop();
});
