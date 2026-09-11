import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const script = join(dirname(fileURLToPath(import.meta.url)), 'with-test-timescale.sh');
const container = 'a'.repeat(64);

function runFixture(overrides = {}, child = 'exit 0', options = []) {
  const directory = mkdtempSync(join(tmpdir(), 'clashking-fixture-test-'));
  const log = join(directory, 'calls.jsonl');
  const mock = `#!${process.execPath}
const fs = require('node:fs');
const path = require('node:path');
const tool = path.basename(process.argv[1]);
const args = process.argv.slice(2);
const migrationDirectory = tool === 'goose' ? args[args.indexOf('-dir') + 1] : undefined;
const migrations = migrationDirectory ? fs.readdirSync(migrationDirectory).sort() : undefined;
fs.appendFileSync(process.env.FIXTURE_LOG, JSON.stringify({tool, args, migrations, inheritedDsn: process.env.GOOSE_DBSTRING}) + '\\n');
if (tool === 'docker') {
  if (args[0] === 'context') console.log(process.env.FIXTURE_ENDPOINT || 'unix:///tmp/test-docker.sock');
  if (args[0] === 'run') console.log('${container}');
  if (args[0] === 'inspect') {
    const calls = fs.readFileSync(process.env.FIXTURE_LOG, 'utf8').trim().split('\\n').map(JSON.parse);
    const run = calls.find(call => call.tool === 'docker' && call.args[0] === 'run');
    const label = run?.args.find(value => value.startsWith('io.clashking.fixture.run='));
    console.log(process.env.FIXTURE_INSPECT_RUN_ID || label?.split('=')[1] || '');
  }
  if (args[0] === 'port') console.log(process.env.FIXTURE_PORT || '127.0.0.1:54329');
} else if (tool === 'goose' && args.includes('up')) {
  process.exit(Number(process.env.FIXTURE_MIGRATION_EXIT || 0));
}
`;
  for (const name of ['docker', 'goose']) writeFileSync(join(directory, name), mock, { mode: 0o755 });
  const environment = { ...process.env, PATH: `${directory}:${process.env.PATH}`, FIXTURE_LOG: log,
    GOOSE_DBSTRING: 'production-must-never-be-used', TEST_DATABASE_URL: 'production-must-never-be-used', ...overrides };
  delete environment.DOCKER_HOST;
  delete environment.DOCKER_CONTEXT;
  Object.assign(environment, overrides);
  const profile = options.length ? options : ['--profile', 'retained-api'];
  const result = spawnSync('bash', [script, ...profile, '--', 'bash', '-c', child], { env: environment, encoding: 'utf8', timeout: 10_000 });
  let calls = [];
  try { calls = readFileSync(log, 'utf8').trim().split('\n').map(JSON.parse); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  rmSync(directory, { recursive: true, force: true });
  return { ...result, calls };
}

test('uses only retained authoritative migrations and its own disposable container', () => {
  const result = runFixture({}, 'test "$CLASHKING_DISPOSABLE_TIMESCALE" = 1 && test "$CLASHKING_TIMESCALE_PROFILE" = retained-api && test "$TEST_ADMIN_EMAIL" = owner@example.test && test "$TEST_DATABASE_URL" = "$TEST_TIMESCALE_DSN" && test -z "${ADMIN_OWNER_BOOTSTRAP_B64:-}"');
  assert.equal(result.status, 0, result.stderr);
  const run = result.calls.find(call => call.tool === 'docker' && call.args[0] === 'run');
  assert.ok(run.args.includes('127.0.0.1::5432'));
  assert.ok(run.args.includes('type=tmpfs,destination=/var/lib/postgresql'));
  const labels = run.args.filter((value, index) => run.args[index - 1] === '--label');
  const fixtureLabel = labels.find(value => value.startsWith('io.clashking.fixture=timescale-'));
  const runLabel = labels.find(value => value.startsWith('io.clashking.fixture.run='));
  assert.ok(fixtureLabel);
  assert.equal(fixtureLabel.slice('io.clashking.fixture=timescale-'.length), runLabel.slice('io.clashking.fixture.run='.length));
  assert.ok(labels.includes('io.clashking.fixture.owner=with-test-timescale'));
  const ready = result.calls.find(call => call.tool === 'docker' && call.args[0] === 'exec');
  assert.deepEqual(ready.args.slice(2, 5), ['pg_isready', '-h', '127.0.0.1']);
  const migrations = result.calls.filter(call => call.tool === 'goose');
  assert.equal(migrations.length, 3);
  for (const call of migrations) {
    assert.equal(call.inheritedDsn, undefined);
    assert.deepEqual(call.args.slice(0, 2), ['-env', '/dev/null']);
    assert.match(call.args[3], /clashking-retained-migrations\./);
    assert.deepEqual(call.migrations, [
      '001_initial_stats.sql', '002_initial_settings.sql', '003_tracking_observability.sql',
      '004_developer_link_grants.sql', '005_remove_legacy_admin_auth.sql', '006_simplify_developer_applications.sql',
      '007_worker_api.sql', '008_ranked_battle_history.sql',
      '009_league_army_analytics.sql', '010_cwl_season_statistics.sql',
      '011_active_verified_players.sql',
      '012_legend_only_army_compositions.sql',
      '013_battle_player_time_identity.sql',
      '014_ranked_defense_loot_nullable.sql',
      '015_army_code_family_compatibility.sql',
      '016_remove_cwl_season_statistics.sql',
      '017_final_operational_contract.sql',
      '018_personal_base_library.sql',
    ]);
  }
  assert.equal(migrations[1].args.at(-1), 'up');
  assert.ok(migrations[1].args.includes('postgres://clashking_test:clashking_test@127.0.0.1:54329/clashking_test?sslmode=disable'));
  assert.deepEqual(result.calls.at(-1).args, ['rm', '--force', '--volumes', container]);
});

test('supports a migration-013 compatibility baseline', () => {
  const result = runFixture({}, 'test "\$CLASHKING_TIMESCALE_PROFILE" = baseline-013', ['--profile', 'baseline-013']);
  assert.equal(result.status, 0, result.stderr);
  const migration = result.calls.find(call => call.tool === 'goose' && call.args.includes('up'));
  assert.equal(migration.migrations.at(-1), '013_battle_player_time_identity.sql');
  assert.equal(migration.migrations.length, 13);
});

test('preserves a failing child exit code and still cleans up', () => {
  const result = runFixture({}, 'exit 42');
  assert.equal(result.status, 42);
  assert.equal(result.calls.at(-1).args[0], 'rm');
});

test('refuses cleanup when the exact container no longer has this run label', () => {
  const result = runFixture({ FIXTURE_INSPECT_RUN_ID: 'another-run' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /cleanup refused/);
  assert.ok(!result.calls.some(call => call.tool === 'docker' && call.args[0] === 'rm'));
});

test('supports an opt-in disk-backed PostgreSQL data directory for large fixtures', () => {
  const result = runFixture({ CLASHKING_FIXTURE_TIMESCALE_STORAGE: 'disk' });
  assert.equal(result.status, 0, result.stderr);
  const run = result.calls.find(call => call.tool === 'docker' && call.args[0] === 'run');
  const mount = run.args[run.args.indexOf('--mount') + 1];
  assert.match(mount, /^type=bind,source=.*\/clashking-timescale-data\.[^,]+,destination=\/var\/lib\/postgresql$/);
  assert.ok(!run.args.some(value => value.includes('type=tmpfs')));
});

test('rejects conflicting or unknown fixture storage settings before touching Docker', () => {
  const conflicting = runFixture({
    CLASHKING_FIXTURE_TIMESCALE_STORAGE: 'disk',
    CLASHKING_FIXTURE_TIMESCALE_TMPFS_SIZE: '1024',
  });
  assert.equal(conflicting.status, 2);
  assert.deepEqual(conflicting.calls, []);

  const unknown = runFixture({ CLASHKING_FIXTURE_TIMESCALE_STORAGE: 'remote' });
  assert.equal(unknown.status, 2);
  assert.deepEqual(unknown.calls, []);
});

test('cleans up on SIGTERM and preserves the signal exit status', () => {
  const result = runFixture({}, 'kill -TERM "$PPID"; exit 0');
  assert.equal(result.status, 143, result.stderr);
  assert.equal(result.calls.at(-1).args[0], 'rm');
});

test('cleans up a migration failure without running the child', () => {
  const result = runFixture({ FIXTURE_MIGRATION_EXIT: '17' }, 'echo CHILD-RAN');
  assert.equal(result.status, 17);
  assert.ok(!result.stdout.includes('CHILD-RAN'));
  assert.equal(result.calls.at(-1).args[0], 'rm');
});

test('rejects remote Docker contexts before creating a container', () => {
  const result = runFixture({ FIXTURE_ENDPOINT: 'ssh://production.example.test' });
  assert.equal(result.status, 1);
  assert.ok(!result.calls.some(call => call.args[0] === 'run'));
});

test('rejects non-loopback port publication and cleans up', () => {
  const result = runFixture({ FIXTURE_PORT: '0.0.0.0:54329' });
  assert.equal(result.status, 1);
  assert.ok(!result.calls.some(call => call.tool === 'goose'));
  assert.equal(result.calls.at(-1).args[0], 'rm');
});

test('rejects an explicit remote Docker host without touching Docker', () => {
  const result = runFixture({ DOCKER_HOST: 'tcp://production.example.test:2375' });
  assert.equal(result.status, 1);
  assert.deepEqual(result.calls, []);
});

test('pins the same Timescale image as the authoritative Compose configuration', () => {
  const root = dirname(dirname(script));
  const compose = readFileSync(join(root, 'database/docker-compose.timescale.yml'), 'utf8');
  const image = compose.match(/image: (timescale\/timescaledb:[^\s]+)/)[1];
  assert.ok(readFileSync(join(root, 'scripts/retained-api-profile.sh'), 'utf8').includes(`fixture_image='${image}'`));
  assert.ok(readFileSync(script, 'utf8').includes('source "$fixture_root/scripts/retained-api-profile.sh"'));
});

test('rejects old migration ceilings and unapproved profiles before touching Docker', () => {
  for (const options of [['--through', '27'], ['--profile', 'bot'], ['--profile', 'all']]) {
    const result = runFixture({}, 'exit 0', options);
    assert.equal(result.status, 2);
    assert.deepEqual(result.calls, []);
  }
});
