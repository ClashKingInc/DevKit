#!/usr/bin/env node

import { existsSync, readFileSync } from 'node:fs';
import { basename, isAbsolute, join, resolve } from 'node:path';
import { connect } from 'node:net';
import { spawn, spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const repositoryNames = ['devkit', 'api', 'tracking', 'dashboard', 'admin', 'app'];
const serviceNames = ['postgres', 'valkey', 'r2', 'proxy', 'api', 'tracking', 'dashboard', 'admin', 'expo'];
const stableApiSecretNames = [
  'DATA_ENCRYPTION_KEY', 'JWT_ACCESS_SECRET', 'JWT_REFRESH_SECRET', 'API_BOT_TOKEN', 'AI_USAGE_SECRET', 'STRIPE_WEBHOOK_SECRET',
];

function fail(message) {
  throw new Error(message);
}

function object(value, name) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) fail(`${name} must be an object`);
  return value;
}

function string(value, name) {
  if (typeof value !== 'string' || value.trim() === '') fail(`${name} must be a non-empty string`);
  return value.trim();
}

function port(value, name) {
  if (!Number.isInteger(value) || value < 1 || value > 65535) fail(`${name} must be an integer from 1 to 65535`);
  return value;
}

export function isLoopbackHost(host) {
  return ['127.0.0.1', 'localhost', '::1', '[::1]'].includes(host.toLowerCase());
}

function localOrigin(value, name) {
  const origin = string(value, name);
  let parsed;
  try {
    parsed = new URL(origin);
  } catch {
    fail(`${name} must be an absolute HTTP URL`);
  }
  if (!['http:', 'https:'].includes(parsed.protocol) || !isLoopbackHost(parsed.hostname)) {
    fail(`${name} must use a loopback HTTP origin in local mode`);
  }
  if (parsed.username || parsed.password || parsed.search || parsed.hash || parsed.pathname !== '/') {
    fail(`${name} must contain only scheme, loopback host, and port`);
  }
  if (!parsed.port) fail(`${name} must include an explicit port`);
  return { origin: parsed.origin, host: parsed.hostname, port: port(Number(parsed.port), `${name} port`) };
}

export function validateConfig(input) {
  const root = object(input, 'configuration');
  if (root.schemaVersion !== 1) fail('schemaVersion must be 1');
  if (root.mode !== 'local') fail('mode must be local');

  const toolchains = object(root.toolchains, 'toolchains');
  const normalizedToolchains = {
    node: string(toolchains.node, 'toolchains.node'),
    npm: string(toolchains.npm, 'toolchains.npm'),
    go: string(toolchains.go, 'toolchains.go'),
  };

  const repositories = object(root.repositories, 'repositories');
  const normalizedRepositories = {};
  for (const name of repositoryNames) {
    const path = string(repositories[name], `repositories.${name}`);
    if (!isAbsolute(path)) fail(`repositories.${name} must be an absolute path`);
    normalizedRepositories[name] = resolve(path);
  }

  const secretsEnv = string(root.secretsEnv, 'secretsEnv');
  if (!isAbsolute(secretsEnv)) fail('secretsEnv must be an absolute path');
  if (basename(secretsEnv) !== '.env') fail('secretsEnv must end in .env so the repository ignore rule applies');
  const archiveImportRoot = string(root.archiveImportRoot, 'archiveImportRoot');
  if (!isAbsolute(archiveImportRoot)) fail('archiveImportRoot must be an absolute path');

  const services = object(root.services, 'services');
  const apiProviders = object(root.apiProviders, 'apiProviders');
  if (apiProviders.clashProxy !== 'remote-vpc') fail('apiProviders.clashProxy must be remote-vpc');
  const postgres = object(services.postgres, 'services.postgres');
  const postgresHost = string(postgres.host, 'services.postgres.host');
  if (!isLoopbackHost(postgresHost)) fail('services.postgres.host must be loopback in local mode');
  const database = string(postgres.database, 'services.postgres.database');
  if (database !== 'clashking_dev') fail('services.postgres.database must be clashking_dev for the retained local database');

  const valkey = object(services.valkey, 'services.valkey');
  const valkeyHost = string(valkey.host, 'services.valkey.host');
  if (!isLoopbackHost(valkeyHost)) fail('services.valkey.host must be loopback in local mode');

  const r2 = object(services.r2, 'services.r2');
  const r2Endpoint = localOrigin(r2.endpoint, 'services.r2.endpoint');

  const origins = Object.fromEntries(
    ['proxy', 'api', 'tracking', 'dashboard', 'admin', 'expo'].map((name) => [name, localOrigin(services[name]?.origin, `services.${name}.origin`)]),
  );

  const normalizedServices = {
    postgres: { host: postgresHost, port: port(postgres.port, 'services.postgres.port'), database },
    valkey: { host: valkeyHost, port: port(valkey.port, 'services.valkey.port') },
    r2: { ...r2Endpoint, bucket: string(r2.bucket, 'services.r2.bucket') },
    ...origins,
  };
  const usedPorts = new Map();
  for (const name of serviceNames) {
    const service = normalizedServices[name];
    const key = `${service.host}:${service.port}`;
    if (usedPorts.has(key)) fail(`services.${name} conflicts with services.${usedPorts.get(key)} at ${key}`);
    usedPorts.set(key, name);
  }

  return {
    schemaVersion: 1,
    mode: 'local',
    toolchains: normalizedToolchains,
    repositories: normalizedRepositories,
    secretsEnv: resolve(secretsEnv),
    archiveImportRoot: resolve(archiveImportRoot),
    apiProviders: { clashProxy: 'remote-vpc' },
    services: normalizedServices,
  };
}

export function loadConfig(configPath) {
  const absolutePath = resolve(configPath);
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(absolutePath, 'utf8'));
  } catch (error) {
    if (error?.code === 'ENOENT') fail(`configuration file does not exist: ${absolutePath}`);
    fail(`configuration file is not valid JSON: ${absolutePath}`);
  }
  return validateConfig(parsed);
}

export function redactText(value) {
  return String(value)
    .replace(/([a-z][a-z0-9+.-]*:\/\/)[^/@\s]+:[^/@\s]+@/giu, '$1[REDACTED]@')
    .replace(/\b(Bearer\s+)[A-Za-z0-9._~+/=-]+/giu, '$1[REDACTED]')
    .replace(/\b((?:password|secret|token|dsn|access[_-]?key)(?:\s*[=:]\s*))["']?[^\s,"']+/giu, '$1[REDACTED]');
}

function execute(command, args, cwd, runner) {
  const result = runner(command, args, { cwd, encoding: 'utf8', timeout: 3_000 });
  return {
    ok: result.status === 0,
    stdout: redactText(result.stdout ?? '').trim(),
    stderr: redactText(result.stderr ?? '').trim(),
  };
}

function versionCheck(name, expected, actual) {
  const normalized = actual.replace(/^go version go|^[vV]/u, '').split(/\s/u)[0];
  const ok = expected.includes('.') ? normalized === expected : normalized.split('.')[0] === expected;
  return { name: `toolchain:${name}`, ok, detail: ok ? normalized : `expected ${expected}, found ${normalized || 'unavailable'}` };
}

export function runDoctor(config, dependencies = {}) {
  const runner = dependencies.spawnSync ?? spawnSync;
  const pathExists = dependencies.existsSync ?? existsSync;
  const checks = [];

  const versions = [
    ['node', config.toolchains.node, 'node', ['--version']],
    ['npm', config.toolchains.npm, 'npm', ['--version']],
    ['go', config.toolchains.go, 'go', ['version']],
  ];
  for (const [name, expected, command, args] of versions) {
    const result = execute(command, args, undefined, runner);
    checks.push(result.ok ? versionCheck(name, expected, result.stdout) : { name: `toolchain:${name}`, ok: false, detail: result.stderr || 'unavailable' });
  }

  for (const [name, path] of Object.entries(config.repositories)) {
    if (!pathExists(path)) {
      checks.push({ name: `repository:${name}`, ok: false, detail: `missing ${path}` });
      continue;
    }
    const revision = execute('git', ['rev-parse', 'HEAD'], path, runner);
    const status = execute('git', ['status', '--porcelain'], path, runner);
    checks.push({
      name: `repository:${name}`,
      ok: revision.ok && status.ok,
      detail: revision.ok && status.ok ? `${revision.stdout.slice(0, 12)} ${status.stdout ? 'dirty' : 'clean'}` : revision.stderr || status.stderr || 'git inspection failed',
    });
  }

  const secretExists = pathExists(config.secretsEnv);
  const ignored = execute('git', ['-C', config.repositories.devkit, 'check-ignore', '--no-index', '--quiet', config.secretsEnv], undefined, runner);
  checks.push({
    name: 'secrets-env',
    ok: secretExists && ignored.ok,
    detail: `${secretExists ? 'present' : 'missing'}; ${ignored.ok ? 'ignored' : 'not ignored'}; ${config.secretsEnv}`,
  });
  return checks;
}

function probeTcp(host, servicePort, timeoutMs = 500) {
  return new Promise((resolveProbe) => {
    const socket = connect({ host, port: servicePort });
    const finish = (ok, detail) => {
      socket.destroy();
      resolveProbe({ ok, detail });
    };
    socket.setTimeout(timeoutMs, () => finish(false, 'timeout'));
    socket.once('connect', () => finish(true, 'listening'));
    socket.once('error', (error) => finish(false, error.code ?? 'unreachable'));
  });
}

export async function runStatus(config, dependencies = {}) {
  const probe = dependencies.probeTcp ?? probeTcp;
  const doctor = runDoctor(config, dependencies);
  const services = await Promise.all(serviceNames.map(async (name) => {
    const service = config.services[name];
    const result = await probe(service.host, service.port);
    return { name: `service:${name}`, ok: result.ok, detail: `${service.host}:${service.port} ${result.detail}` };
  }));
  return [...doctor, ...services];
}

export function loadLocalEnvironment(path, dependencies = {}) {
  const read = dependencies.readFileSync ?? readFileSync;
  const values = {};
  for (const [index, source] of read(path, 'utf8').split(/\r?\n/u).entries()) {
    const line = source.trim();
    if (!line || line.startsWith('#')) continue;
    const match = /^(?:export\s+)?([A-Z][A-Z0-9_]*)=(.*)$/u.exec(line);
    if (!match) fail(`${path}:${index + 1} is not a KEY=value assignment`);
    let value = match[2].trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
    values[match[1]] = value;
  }
  return values;
}

export function readExistingLocalApiBotToken(dependencies = {}) {
  if ((dependencies.platform ?? process.platform) !== 'darwin') fail('persistent local API secrets require macOS Keychain');
  const sync = dependencies.spawnSync ?? spawnSync;
  const result = sync('/usr/bin/security', [
    'find-generic-password', '-s', 'ing.clashking.effect-rewrite.local-api', '-a', 'local-signing-and-encryption-v1', '-w',
  ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  if (result.status !== 0) fail('cannot read the existing local API Keychain item; unlock or allow access, and do not rotate it');
  let secrets;
  try { secrets = JSON.parse(String(result.stdout).trim()); } catch { fail('the existing local API Keychain item is invalid; refusing to replace it'); }
  if (typeof secrets?.API_BOT_TOKEN !== 'string' || !/^[A-Za-z0-9_-]{43}$/u.test(secrets.API_BOT_TOKEN)) {
    fail('the existing local API Keychain item has no valid API_BOT_TOKEN; refusing to replace it');
  }
  return secrets.API_BOT_TOKEN;
}

export function resolveLocalApiBotToken(environment, dependencies = {}) {
  const explicit = Object.fromEntries(stableApiSecretNames.map((name) => [name, environment[`CLASHKING_LOCAL_${name}`]]));
  const supplied = stableApiSecretNames.filter((name) => typeof explicit[name] === 'string' && explicit[name].length > 0);
  if (supplied.length > 0) {
    if (supplied.length !== stableApiSecretNames.length) fail('explicit stable API secrets must provide the complete CLASHKING_LOCAL_* keyset');
    for (const name of stableApiSecretNames) {
      if (!/^[A-Za-z0-9_-]{43}$/u.test(explicit[name])) fail(`CLASHKING_LOCAL_${name} must be a 43-character base64url value`);
    }
    return explicit.API_BOT_TOKEN;
  }
  return readExistingLocalApiBotToken(dependencies);
}

function requiredSecret(values, name) {
  const value = values[name];
  if (typeof value !== 'string' || value.length === 0) fail(`${name} is required in the ignored local secrets file`);
  return value;
}

function without(environment, names) {
  const result = { ...environment };
  for (const name of names) delete result[name];
  return result;
}

export function buildServicePlan(config, localSecrets, options = {}, baseEnvironment = process.env) {
  const common = without(baseEnvironment, [
    'DATABASE_URL', 'TEST_DATABASE_URL', 'CLASHKING_DISPOSABLE_TIMESCALE', 'CLASHKING_LOCAL_CLASH_PROXY_ORIGIN',
    'TIMESCALE_URL', 'VALKEY_ADDR', 'VALKEY_URL', 'REDIS_URL', 'PROXY_URL',
    'R2_ENDPOINT', 'R2_ENDPOINT_URL', 'R2_ACCOUNT_ID', 'R2_WARS_BUCKET',
    'CLASHKING_API_URL', 'CLASHKING_API_TOKEN',
    'DISCORD_BOT_TOKEN', 'BOT_TOKEN', 'MOBILE_PUSH_FCM_SERVICE_ACCOUNT_JSON', 'MOBILE_PUSH_FCM_PROJECT_ID',
    'CLASHKING_LOCAL_FCM_API_ORIGIN', 'CLASHKING_LOCAL_DISCORD_API_URL', 'SENTRY_DSN',
    'CLASHKING_LOCAL_DISCORD_CLIENT_ID', 'CLASHKING_LOCAL_DISCORD_CLIENT_SECRET', 'CLASHKING_LOCAL_DISCORD_BOT_TOKEN',
    ...stableApiSecretNames.map((name) => `CLASHKING_LOCAL_${name}`),
  ]);
  const r2AccessKey = requiredSecret(localSecrets, 'R2_ACCESS_KEY_ID');
  const r2SecretKey = requiredSecret(localSecrets, 'R2_SECRET_ACCESS_KEY');
  const valkeyPassword = requiredSecret(localSecrets, 'VALKEY_PASSWORD');
  const timescaleUsername = requiredSecret(localSecrets, 'TIMESCALE_USERNAME');
  const timescalePassword = requiredSecret(localSecrets, 'TIMESCALE_PASSWORD');
  const apiEnvironment = {
    ...common,
    CLASHKING_LOCAL_SCHEMA_ROOT: config.repositories.devkit,
    CLASHKING_LOCAL_INFRA_ENV: config.secretsEnv,
    CLASHKING_LOCAL_API_PORT: String(config.services.api.port),
    CLASHKING_LOCAL_LAN_IP: options.lanIp ?? '127.0.0.1',
    CLASHKING_LOCAL_TRACKING_ORIGIN: config.services.tracking.origin,
    CLASHKING_LOCAL_ARCHIVE_IMPORT_ROOT: config.archiveImportRoot,
    CLASHKING_LOCAL_ADMIN_IDENTITY: options.admin ? '1' : '0',
    ...Object.fromEntries([
      'CLASHKING_LOCAL_DISCORD_CLIENT_ID', 'CLASHKING_LOCAL_DISCORD_CLIENT_SECRET', 'CLASHKING_LOCAL_DISCORD_BOT_TOKEN',
    ].filter((name) => typeof baseEnvironment[name] === 'string' && baseEnvironment[name].length > 0).map((name) => [name, baseEnvironment[name]])),
    ...Object.fromEntries(stableApiSecretNames.map((name) => `CLASHKING_LOCAL_${name}`)
      .filter((name) => typeof baseEnvironment[name] === 'string' && baseEnvironment[name].length > 0).map((name) => [name, baseEnvironment[name]])),
    R2_ACCESS_KEY_ID: r2AccessKey,
    R2_SECRET_ACCESS_KEY: r2SecretKey,
  };
  const trackingEnvironment = {
    ...common,
    TIMESCALE_HOST: config.services.postgres.host,
    TIMESCALE_PORT: String(config.services.postgres.port),
    TIMESCALE_DATABASE: config.services.postgres.database,
    TIMESCALE_USERNAME: timescaleUsername,
    TIMESCALE_PASSWORD: timescalePassword,
    TIMESCALE_SSLMODE: 'disable',
    VALKEY_HOST: config.services.valkey.host,
    VALKEY_PORT: String(config.services.valkey.port),
    VALKEY_PASSWORD: valkeyPassword,
    CLASHKING_PROXY_INTERNAL_ORIGIN: config.services.proxy.origin,
    CLASHKING_API_ORIGIN: config.services.api.origin,
    TRACKING_INTERNAL_HTTP_ADDR: `${config.services.tracking.host}:${config.services.tracking.port}`,
    API_BOT_TOKEN: requiredSecret(options, 'apiBotToken'),
    WAR_ARCHIVE_S3_ENDPOINT: config.services.r2.origin,
    WAR_ARCHIVE_ORIGIN: `${config.services.r2.origin}/${config.services.r2.bucket}`,
    WAR_ARCHIVE_BUCKET: config.services.r2.bucket,
    R2_ACCESS_KEY_ID: r2AccessKey,
    R2_SECRET_ACCESS_KEY: r2SecretKey,
    DISCORD_BOT_TOKEN: '',
    BOT_TOKEN: '',
    DISCORD_MESSAGE_CREATE_ENABLED: 'false',
    MOBILE_PUSH_FCM_SERVICE_ACCOUNT_JSON: '',
    MOBILE_PUSH_FCM_PROJECT_ID: '',
    SENTRY_DSN: '',
  };
  const services = [
    { name: 'api', command: process.execPath, args: ['scripts/local-api-database.mjs', 'run'], cwd: config.repositories.api, env: apiEnvironment },
    ...['internal-api', 'war-archiver'].map((script) => ({
      name: `tracking:${script}`, command: 'go', args: ['run', '.', '--script', script], cwd: config.repositories.tracking, env: trackingEnvironment,
    })),
  ];
  if (options.dashboard) {
    const discordClientId = baseEnvironment.CLASHKING_LOCAL_DISCORD_CLIENT_ID || baseEnvironment.VITE_DISCORD_CLIENT_ID;
    if (!/^\d+$/u.test(discordClientId ?? '')) fail('Set CLASHKING_LOCAL_DISCORD_CLIENT_ID (or VITE_DISCORD_CLIENT_ID) before starting the Dashboard');
    services.push({ name: 'dashboard', command: 'npm', args: ['run', 'dev'], cwd: config.repositories.dashboard, env: { ...common, VITE_DISCORD_CLIENT_ID: discordClientId, VITE_CLASHKING_API_ORIGIN: config.services.api.origin } });
  }
  if (options.admin) services.push({ name: 'admin', command: 'npm', args: ['run', 'dev', '--', '--host', '127.0.0.1', '--port', String(config.services.admin.port)], cwd: config.repositories.admin, env: { ...common, VITE_CLASHKING_API_ORIGIN: 'http://127.0.0.1:8786' } });
  const expoApiOrigin = options.lanIp ? `http://${options.lanIp}:${config.services.api.port}` : config.services.api.origin;
  if (options.expo) services.push({
    name: 'expo', command: 'npm', args: ['run', 'start', '--', '--host', options.lanIp ? 'lan' : 'localhost', '--port', String(config.services.expo.port)], cwd: join(config.repositories.app, 'expo'),
    env: {
      ...common,
      BROWSER: 'none',
      EXPO_PUBLIC_CK_API_ENV: 'local',
      EXPO_PUBLIC_CK_API_BASE_URL: expoApiOrigin,
      EXPO_PUBLIC_CK_API_V2_BASE_URL: `${expoApiOrigin}/v2`,
      EXPO_PUBLIC_CK_PROXY_BASE_URL: `${expoApiOrigin}/proxy/v1`,
      EXPO_PUBLIC_CK_PUSH_API_V2_BASE_URL: `${expoApiOrigin}/v2`,
    },
  });
  return { services, valkeyEnvironment: { ...common, ...localSecrets, HOST_BIND_IP: '127.0.0.1', VALKEY_PORT: String(config.services.valkey.port) } };
}

function childExit(child) {
  return new Promise((resolveExit) => {
    child.once('exit', (code, signal) => resolveExit({ code, signal }));
    child.once('error', (error) => resolveExit({ error }));
  });
}

async function waitFor(check, description, timeoutMs = 60_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await check()) return;
    await new Promise((resolveWait) => setTimeout(resolveWait, 250));
  }
  fail(`timed out waiting for ${description}`);
}

export async function startLocalStack(config, options = {}, dependencies = {}) {
  const probe = dependencies.probeTcp ?? probeTcp;
  const spawnProcess = dependencies.spawn ?? spawn;
  const sync = dependencies.spawnSync ?? spawnSync;
  const fetchHealth = dependencies.fetch ?? fetch;
  const output = dependencies.output ?? ((message) => process.stdout.write(`${redactText(message)}\n`));
  const killOwned = dependencies.killOwned ?? ((child, signal) => process.platform === 'win32' ? child.kill(signal) : process.kill(-child.pid, signal));
  const stabilityMs = dependencies.stabilityMs ?? 500;
  const environment = dependencies.environment ?? process.env;
  const localSecrets = loadLocalEnvironment(config.secretsEnv, dependencies);
  const apiBotToken = dependencies.apiBotToken ?? resolveLocalApiBotToken(environment, dependencies);
  const plan = buildServicePlan(config, localSecrets, { ...options, apiBotToken }, environment);
  const owned = [];
  let valkeyOwned = false;
  let stopping = false;
  let stopPromise;
  const composeFile = join(config.repositories.devkit, 'database/docker-compose.valkey.yml');
  const composeArgs = ['compose', '--env-file', config.secretsEnv, '-f', composeFile];

  const stop = () => {
    if (stopPromise) return stopPromise;
    stopping = true;
    stopPromise = (async () => {
      for (const item of [...owned].reverse()) {
        try { killOwned(item.child, 'SIGTERM'); } catch { /* a failed spawn is already stopped */ }
        await new Promise((resolveWait) => {
          const timer = setTimeout(() => { try { killOwned(item.child, 'SIGKILL'); } catch {} resolveWait(); }, 10_000);
          item.exit.finally(() => { clearTimeout(timer); resolveWait(); });
        });
      }
      if (valkeyOwned) sync('docker', [...composeArgs, 'stop', 'valkey'], { cwd: config.repositories.devkit, env: plan.valkeyEnvironment, stdio: 'inherit' });
    })();
    return stopPromise;
  };

  const launch = (definition) => {
    const child = spawnProcess(definition.command, definition.args, { cwd: definition.cwd, env: definition.env, stdio: 'inherit', detached: process.platform !== 'win32' });
    const exit = childExit(child);
    const item = { name: definition.name, child, exit };
    owned.push(item);
    exit.then((result) => {
      if (!stopping) {
        output(`${definition.name} exited unexpectedly (${result.error?.message ?? result.code ?? result.signal})`);
        void stop();
      }
    });
    output(`started ${definition.name} pid=${child.pid}`);
    return item;
  };

  try {
    if (!(await probe(config.services.postgres.host, config.services.postgres.port)).ok) fail('retained PostgreSQL is not listening; start it separately and do not migrate through this runner');
    output('adopted postgres read-only');
    if ((await probe(config.services.proxy.host, config.services.proxy.port)).ok) output('adopted Clash proxy tunnel read-only');
    else output('Clash proxy tunnel is unavailable; core internal-api and war-archiver domains can still start');
    if ((await probe(config.services.valkey.host, config.services.valkey.port)).ok) output('adopted valkey read-only');
    else {
      const context = sync('docker', ['context', 'inspect', '--format', '{{.Endpoints.docker.Host}}'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
      if (context.status !== 0 || !String(context.stdout).trim().startsWith('unix://')) fail('Valkey startup requires a local Unix-socket Docker context');
      const result = sync('docker', [...composeArgs, 'up', '-d', 'valkey'], { cwd: config.repositories.devkit, env: plan.valkeyEnvironment, stdio: 'inherit' });
      if (result.status !== 0) fail('persistent Valkey failed to start');
      valkeyOwned = true;
      await waitFor(async () => (await probe(config.services.valkey.host, config.services.valkey.port)).ok, 'Valkey');
      output('started persistent valkey');
    }

    const apiOpen = (await probe(config.services.api.host, config.services.api.port)).ok;
    const r2Open = (await probe(config.services.r2.host, config.services.r2.port)).ok;
    if (apiOpen !== r2Open) fail('API and R2 bridge have a partial unowned startup; refusing to replace or kill either listener');
    if (apiOpen) {
      let healthy = false;
      try { healthy = (await fetchHealth(`${config.services.api.origin}/v2/health`)).ok; } catch { healthy = false; }
      if (!healthy) fail('adopted API listener did not pass /v2/health; refusing to start Tracking');
      output('adopted api and r2 read-only');
    }
    else {
      launch(plan.services.find((service) => service.name === 'api'));
      await waitFor(async () => {
        if (!(await probe(config.services.r2.host, config.services.r2.port)).ok) return false;
        try { return (await fetchHealth(`${config.services.api.origin}/v2/health`)).ok; } catch { return false; }
      }, 'API health and R2 bridge');
    }

    const trackingDefinitions = plan.services.filter((service) => service.name.startsWith('tracking:'));
    const trackingOpen = (await probe(config.services.tracking.host, config.services.tracking.port)).ok;
    const trackingReady = async () => {
      try {
        const response = await fetchHealth(`${config.services.tracking.origin}/internal/verified-players/refresh`, {
          method: 'POST', headers: { Authorization: `Bearer ${apiBotToken}`, 'Content-Type': 'application/json' }, body: '{"player_tags":[]}',
        });
        return response.ok;
      } catch { return false; }
    };
    if (trackingOpen) {
      await waitFor(trackingReady, 'authenticated adopted Tracking internal API');
      output('adopted tracking domains read-only; skipping war-archiver to avoid a duplicate singleton');
    } else {
      launch(trackingDefinitions.find((service) => service.name === 'tracking:internal-api'));
      await waitFor(trackingReady, 'authenticated Tracking internal API');
      const archiver = launch(trackingDefinitions.find((service) => service.name === 'tracking:war-archiver'));
      const earlyExit = await Promise.race([archiver.exit, new Promise((resolveWait) => setTimeout(() => resolveWait(null), stabilityMs))]);
      if (earlyExit !== null) fail(`tracking:war-archiver exited before readiness (${earlyExit.error?.message ?? earlyExit.code ?? earlyExit.signal})`);
    }
    for (const definition of plan.services.filter((service) => ['dashboard', 'admin', 'expo'].includes(service.name))) {
      const service = config.services[definition.name];
      if ((await probe(service.host, service.port)).ok) output(`adopted ${definition.name} read-only`);
      else {
        launch(definition);
        await waitFor(async () => (await probe(service.host, service.port)).ok, definition.name);
      }
    }
    output('local stack ready; press Ctrl-C to stop owned processes');
    return { owned, stop, valkeyOwned };
  } catch (error) {
    await stop();
    throw error;
  }
}

function printChecks(checks, json) {
  if (json) {
    process.stdout.write(`${redactText(JSON.stringify({ ok: checks.every((check) => check.ok), checks }, null, 2))}\n`);
    return;
  }
  for (const check of checks) process.stdout.write(`${check.ok ? 'ok' : 'fail'}  ${check.name}  ${redactText(check.detail)}\n`);
}

function parseArguments(argv) {
  const command = argv[0] ?? 'doctor';
  if (!['doctor', 'status', 'start'].includes(command)) fail('usage: local-stack.mjs <doctor|status|start> [--config path] [--json] [--with-frontends] [--with-expo] [--lan-ip IPv4]');
  let configPath = new URL('../local/local-stack.example.json', import.meta.url).pathname;
  let json = false;
  const options = { dashboard: false, admin: false, expo: false };
  for (let index = 1; index < argv.length; index += 1) {
    if (argv[index] === '--json') json = true;
    else if (argv[index] === '--with-frontends') options.dashboard = options.admin = true;
    else if (argv[index] === '--with-expo') options.expo = true;
    else if (argv[index] === '--lan-ip' && argv[index + 1]) {
      const value = argv[++index];
      if (!/^\d{1,3}(?:\.\d{1,3}){3}$/u.test(value) || value.split('.').some((part) => Number(part) > 255)) fail('--lan-ip must be an explicit IPv4 address');
      options.lanIp = value;
    }
    else if (argv[index] === '--config' && argv[index + 1]) configPath = argv[++index];
    else fail('usage: local-stack.mjs <doctor|status|start> [--config path] [--json] [--with-frontends] [--with-expo] [--lan-ip IPv4]');
  }
  return { command, configPath, json, options };
}

export async function main(argv = process.argv.slice(2)) {
  try {
    const { command, configPath, json, options } = parseArguments(argv);
    const config = loadConfig(configPath);
    if (command === 'start') {
      if (json) fail('--json is not supported with start');
      const checks = runDoctor(config);
      printChecks(checks, false);
      if (!checks.every((check) => check.ok)) fail('doctor checks must pass before starting the local stack');
      const runtime = await startLocalStack(config, options);
      const shutdown = () => void runtime.stop();
      process.once('SIGINT', shutdown);
      process.once('SIGTERM', shutdown);
      await Promise.all(runtime.owned.map((item) => item.exit));
      await runtime.stop();
      return 0;
    }
    const checks = command === 'status' ? await runStatus(config) : runDoctor(config);
    printChecks(checks, json);
    return checks.every((check) => check.ok) ? 0 : 1;
  } catch (error) {
    process.stderr.write(`local-stack: ${redactText(error instanceof Error ? error.message : error)}\n`);
    return 2;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  process.exitCode = await main();
}
