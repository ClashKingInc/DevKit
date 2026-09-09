import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const script = join(dirname(fileURLToPath(import.meta.url)), 'with-test-integration.sh');
const valkeyContainer = 'b'.repeat(64);
const timescaleContainer = 'a'.repeat(64);

function runFixture(overrides = {}, child = 'exit 0', options = ['--profile', 'retained-api']) {
  const directory = mkdtempSync(join(tmpdir(), 'clashking-integration-fixture-test-'));
  const log = join(directory, 'calls.jsonl');
  const mock = `#!${process.execPath}
const fs = require('node:fs');
const path = require('node:path');
const tool = path.basename(process.argv[1]);
const args = process.argv.slice(2);
fs.appendFileSync(process.env.FIXTURE_LOG, JSON.stringify({tool, args}) + '\\n');
if (tool === 'docker') {
  if (args[0] === 'context') console.log(process.env.FIXTURE_ENDPOINT || 'unix:///tmp/test-docker.sock');
  if (args[0] === 'run') console.log(args.includes('valkey/valkey:8') ? '${valkeyContainer}' : '${timescaleContainer}');
  if (args[0] === 'inspect') {
    const calls = fs.readFileSync(process.env.FIXTURE_LOG, 'utf8').trim().split('\\n').map(JSON.parse);
    const requested = args.at(-1);
    const run = calls.find(call => call.tool === 'docker' && call.args[0] === 'run' && (requested === '${valkeyContainer}' ? call.args.includes('valkey/valkey:8') : !call.args.includes('valkey/valkey:8')));
    const label = run?.args.find(value => value.startsWith('io.clashking.fixture.run='));
    console.log(process.env.FIXTURE_INSPECT_RUN_ID || label?.split('=')[1] || '');
  }
  if (args[0] === 'exec' && args.includes('valkey-cli')) console.log('PONG');
  if (args[0] === 'port') console.log(args[1] === '${valkeyContainer}' ? (process.env.FIXTURE_VALKEY_PORT || '127.0.0.1:63891') : '127.0.0.1:54329');
} else if (tool === 'goose') {
  process.exit(0);
}
`;
  for (const name of ['docker', 'goose']) writeFileSync(join(directory, name), mock, { mode: 0o755 });
  const environment = {
    ...process.env,
    PATH: `${directory}:${process.env.PATH}`,
    FIXTURE_LOG: log,
    VALKEY_HOST: 'production.example.test',
    VALKEY_PORT: '6379',
    VALKEY_PASSWORD: 'must-not-survive',
    ...overrides,
  };
  delete environment.DOCKER_HOST;
  delete environment.DOCKER_CONTEXT;
  Object.assign(environment, overrides);
  const result = spawnSync('bash', [script, ...options, '--', 'bash', '-c', child], {
    env: environment,
    encoding: 'utf8',
    timeout: 10_000,
  });
  let calls = [];
  try { calls = readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  rmSync(directory, { recursive: true, force: true });
  return { ...result, calls };
}

test('provides disposable Timescale and Valkey coordinates to the child', () => {
  const child = 'test "$CLASHKING_DISPOSABLE_TIMESCALE" = 1 && test "$CLASHKING_DISPOSABLE_VALKEY" = 1 && test "$VALKEY_HOST" = 127.0.0.1 && test "$VALKEY_PORT" = 63891 && test "$TEST_VALKEY_ADDR" = 127.0.0.1:63891 && test "$TEST_VALKEY_URL" = redis://127.0.0.1:63891 && test -z "${VALKEY_PASSWORD:-}"';
  const result = runFixture({}, child);
  assert.equal(result.status, 0, result.stderr);
  const runs = result.calls.filter((call) => call.tool === 'docker' && call.args[0] === 'run');
  assert.equal(runs.length, 2);
  assert.ok(runs[0].args.includes('valkey/valkey:8'));
  assert.ok(runs[0].args.includes('type=tmpfs,destination=/data'));
  assert.ok(runs[0].args.includes('127.0.0.1::6379'));
  const runIds = runs.map(run => run.args.find(value => value.startsWith('io.clashking.fixture.run='))?.split('=')[1]);
  assert.ok(runIds[0]);
  assert.deepEqual(runIds, [runIds[0], runIds[0]]);
  assert.ok(runs[0].args.includes(`io.clashking.fixture=valkey-${runIds[0]}`));
  assert.ok(runs[1].args.includes(`io.clashking.fixture=timescale-${runIds[0]}`));
  const removals = result.calls.filter((call) => call.tool === 'docker' && call.args[0] === 'rm');
  assert.deepEqual(removals.map((call) => call.args.at(-1)), [timescaleContainer, valkeyContainer]);
});

test('preserves a failing child status and cleans up both fixtures', () => {
  const result = runFixture({}, 'exit 37');
  assert.equal(result.status, 37, result.stderr);
  const removals = result.calls.filter((call) => call.tool === 'docker' && call.args[0] === 'rm');
  assert.deepEqual(removals.map((call) => call.args.at(-1)), [timescaleContainer, valkeyContainer]);
});

test('refuses cleanup when a fixture container has another run label', () => {
  const result = runFixture({ FIXTURE_INSPECT_RUN_ID: 'another-run' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /cleanup refused/);
  assert.ok(!result.calls.some(call => call.tool === 'docker' && call.args[0] === 'rm'));
});

test('rejects a remote Docker context before creating either fixture', () => {
  const result = runFixture({ FIXTURE_ENDPOINT: 'ssh://production.example.test' });
  assert.equal(result.status, 1);
  assert.ok(!result.calls.some((call) => call.args[0] === 'run'));
});

test('rejects a non-loopback Valkey publication and removes only Valkey', () => {
  const result = runFixture({ FIXTURE_VALKEY_PORT: '0.0.0.0:63891' });
  assert.equal(result.status, 1);
  assert.ok(!result.calls.some((call) => call.tool === 'goose'));
  const removals = result.calls.filter((call) => call.tool === 'docker' && call.args[0] === 'rm');
  assert.deepEqual(removals.map((call) => call.args.at(-1)), [valkeyContainer]);
});

test('rejects old ceilings and unknown profiles before touching Docker', () => {
  for (const options of [['--through', '27'], ['--profile', 'bot'], ['--profile', 'all']]) {
    const result = runFixture({}, 'exit 0', options);
    assert.equal(result.status, 2);
    assert.deepEqual(result.calls, []);
  }
});
