#!/usr/bin/env node
// Copy completed Legend days from the production Timescale container into the
// explicitly named local disposable database. No writes occur without --apply.
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { pathToFileURL } from 'node:url';

const sourceHost = 'root@152.53.82.182';
const sourceContainer = 'timescale-qsj8dfwekv4uw7ri76r9bhcx-023002241562';
const sourceCommand = `docker exec -i ${sourceContainer} sh -c 'exec psql -X -q -A -t -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d clashking'`;
const targetEnvironment = {
  ...process.env,
  PGHOST: '127.0.0.1',
  PGPORT: '54330',
  PGDATABASE: 'clashking_dev',
  PGUSER: 'clashking_local',
  PGPASSWORD: 'clashking_local',
  PGSSLMODE: 'disable',
};
const battlesColumns = [
  'player_tag', 'opponent_tag', 'battle_time', 'direction', 'battle_mode',
  'player_town_hall', 'opponent_town_hall', 'stars', 'destruction_percentage',
  'duration_seconds', 'looted_resources', 'share_code',
];
const rankingsColumns = ['day', 'tag', 'global_rank', 'trophies'];

function parsedDay(day) {
  if (!/^\d{4}-\d{2}-\d{2}$/u.test(day)) throw Error(`Invalid UTC day: ${day}`);
  const parsed = new Date(`${day}T00:00:00Z`);
  if (!Number.isFinite(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== day) {
    throw Error(`Invalid UTC day: ${day}`);
  }
  return parsed;
}

export function parseImportOptions(argv, now = new Date()) {
  const flags = new Map();
  for (let index = 0; index < argv.length; index++) {
    const flag = argv[index];
    if (flag === '--apply') {
      if (flags.has(flag)) throw Error('Duplicate --apply');
      flags.set(flag, true);
    } else if (flag === '--from' || flag === '--through') {
      if (flags.has(flag) || !argv[index + 1]) throw Error(`Missing or duplicate ${flag}`);
      flags.set(flag, argv[++index]);
    } else {
      throw Error(`Unknown argument: ${flag}`);
    }
  }
  if (!flags.has('--from') || !flags.has('--through')) {
    throw Error('Usage: node scripts/import-legend-source-local.mjs --from YYYY-MM-DD --through YYYY-MM-DD [--apply]');
  }
  const from = parsedDay(flags.get('--from'));
  const through = parsedDay(flags.get('--through'));
  const days = Math.round((through.getTime() - from.getTime()) / 86_400_000) + 1;
  if (days < 1 || days > 7) throw Error('Import must cover 1–7 consecutive UTC days');
  const today = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  if (through >= today) throw Error('Only completed UTC days may be imported');
  if (from < new Date(today.getTime() - 30 * 86_400_000)) {
    throw Error('Import start must be within the last 30 UTC days');
  }
  const endExclusive = new Date(through.getTime() + 86_400_000).toISOString().slice(0, 10);
  return {
    from: flags.get('--from'),
    through: flags.get('--through'),
    days: Array.from({ length: days }, (_, index) =>
      new Date(from.getTime() + index * 86_400_000).toISOString().slice(0, 10)),
    start: `${flags.get('--from')}T05:10:00Z`,
    endExclusive: `${endExclusive}T05:10:00Z`,
    apply: flags.has('--apply'),
  };
}

function tableShape(table) {
  return `SELECT json_agg(json_build_array(a.attname,format_type(a.atttypid,a.atttypmod)) ORDER BY a.attnum)
    FROM pg_attribute a WHERE a.attrelid='public.${table}'::regclass
      AND a.attnum>0 AND NOT a.attisdropped`;
}

export function preflightSql(range) {
  return `SELECT json_build_object(
    'database',current_database(),'user',current_user,
    'battlesShape',(${tableShape('battles_ranked')}),
    'rankingsShape',(${tableShape('legend_rankings_history')}),
    'battleCount',(SELECT count(*) FROM public.battles_ranked
      WHERE battle_mode=2 AND direction=1
        AND battle_time>='${range.start}'::timestamptz
        AND battle_time<'${range.endExclusive}'::timestamptz),
    'battleDays',(SELECT COALESCE(json_object_agg(day,rows),'{}'::json)
      FROM (SELECT (battle_time AT TIME ZONE 'UTC' - interval '5 hours 10 minutes')::date AS day,
        count(*) AS rows FROM public.battles_ranked
        WHERE battle_mode=2 AND direction=1
          AND battle_time>='${range.start}'::timestamptz
          AND battle_time<'${range.endExclusive}'::timestamptz GROUP BY 1) by_day),
    'rankingCount',(SELECT count(*) FROM public.legend_rankings_history
      WHERE day>='${range.from}'::date AND day<='${range.through}'::date),
    'rankingDays',(SELECT COALESCE(json_object_agg(day,rows),'{}'::json)
      FROM (SELECT day,count(*) AS rows FROM public.legend_rankings_history
        WHERE day>='${range.from}'::date AND day<='${range.through}'::date GROUP BY day) by_day)
  )::text;`;
}

export function sourceCopySql(range, table) {
  if (table === 'battles_ranked') {
    return `COPY (SELECT ${battlesColumns.join(',')} FROM public.battles_ranked
      WHERE battle_mode=2 AND direction=1
        AND battle_time>='${range.start}'::timestamptz
        AND battle_time<'${range.endExclusive}'::timestamptz
      ) TO STDOUT WITH (FORMAT csv, NULL '\\N');`;
  }
  if (table === 'legend_rankings_history') {
    return `COPY (SELECT ${rankingsColumns.join(',')} FROM public.legend_rankings_history
      WHERE day>='${range.from}'::date AND day<='${range.through}'::date
      ) TO STDOUT WITH (FORMAT csv, NULL '\\N');`;
  }
  throw Error(`Unsupported source table: ${table}`);
}

function quotedCopyPath(path) {
  if (!/^\/[a-zA-Z0-9_./-]+$/u.test(path)) throw Error('Unsafe temporary COPY path');
  return `'${path}'`;
}

function sameDayCounts(left, right, days) {
  return Object.keys(left).length === Object.keys(right).length &&
    days.every(day => left[day] === right[day]);
}

function rowDigest(table, columns, where, orderBy) {
  return `(SELECT md5(COALESCE(string_agg(md5(row_to_json(row_data)::text),''
    ORDER BY ${orderBy}),'')) FROM
    (SELECT ${columns.join(',')} FROM ${table} ${where}) row_data)`;
}

export function mergeSql(range, battlesPath, rankingsPath, backupBattlesPath,
  backupRankingsPath, expected, localBefore) {
  const battleList = battlesColumns.join(',');
  const rankingList = rankingsColumns.join(',');
  const battleWhere = `WHERE battle_mode=2 AND direction=1
    AND battle_time>='${range.start}'::timestamptz
    AND battle_time<'${range.endExclusive}'::timestamptz`;
  const rankingWhere = `WHERE day>='${range.from}'::date AND day<='${range.through}'::date`;
  const battleOrder = 'row_data.player_tag,row_data.battle_time';
  const rankingOrder = 'row_data.day,row_data.tag';
  const sourceBattlesDigest = rowDigest('incoming_battles_ranked', battlesColumns, '', battleOrder);
  const targetBattlesDigest = rowDigest('public.battles_ranked', battlesColumns, battleWhere, battleOrder);
  const backupBattlesDigest = rowDigest('backup_battles_ranked', battlesColumns, '', battleOrder);
  const sourceRankingsDigest = rowDigest('incoming_legend_rankings', rankingsColumns, '', rankingOrder);
  const targetRankingsDigest = rowDigest('public.legend_rankings_history', rankingsColumns, rankingWhere, rankingOrder);
  const backupRankingsDigest = rowDigest('backup_legend_rankings', rankingsColumns, '', rankingOrder);
  return `BEGIN;
LOCK TABLE public.battles_ranked, public.legend_rankings_history IN SHARE ROW EXCLUSIVE MODE;
CREATE TEMP TABLE incoming_battles_ranked ON COMMIT DROP AS
  SELECT ${battleList} FROM public.battles_ranked WITH NO DATA;
CREATE TEMP TABLE incoming_legend_rankings ON COMMIT DROP AS
  SELECT ${rankingList} FROM public.legend_rankings_history WITH NO DATA;
CREATE TEMP TABLE backup_battles_ranked ON COMMIT DROP AS
  SELECT ${battleList} FROM public.battles_ranked WITH NO DATA;
CREATE TEMP TABLE backup_legend_rankings ON COMMIT DROP AS
  SELECT ${rankingList} FROM public.legend_rankings_history WITH NO DATA;
\\copy incoming_battles_ranked (${battleList}) FROM ${quotedCopyPath(battlesPath)} WITH (FORMAT csv, NULL '\\N')
\\copy incoming_legend_rankings (${rankingList}) FROM ${quotedCopyPath(rankingsPath)} WITH (FORMAT csv, NULL '\\N')
\\copy backup_battles_ranked (${battleList}) FROM ${quotedCopyPath(backupBattlesPath)} WITH (FORMAT csv, NULL '\\N')
\\copy backup_legend_rankings (${rankingList}) FROM ${quotedCopyPath(backupRankingsPath)} WITH (FORMAT csv, NULL '\\N')
DO $$ BEGIN
  IF (SELECT count(*) FROM incoming_battles_ranked) <> ${expected.battleCount}
    OR (SELECT count(*) FROM incoming_legend_rankings) <> ${expected.rankingCount}
  THEN RAISE EXCEPTION 'Source COPY row count changed or was truncated'; END IF;
  IF (SELECT count(*) FROM backup_battles_ranked) <> ${localBefore.battleCount}
    OR (SELECT count(*) FROM public.battles_ranked ${battleWhere}) <> ${localBefore.battleCount}
    OR (SELECT count(*) FROM backup_legend_rankings) <> ${localBefore.rankingCount}
    OR (SELECT count(*) FROM public.legend_rankings_history ${rankingWhere}) <> ${localBefore.rankingCount}
    OR ${backupBattlesDigest} <> ${targetBattlesDigest}
    OR ${backupRankingsDigest} <> ${targetRankingsDigest}
  THEN RAISE EXCEPTION 'Local rows changed after backup; no rows replaced'; END IF;
END $$;
DELETE FROM public.battles_ranked ${battleWhere};
DELETE FROM public.legend_rankings_history ${rankingWhere};
INSERT INTO public.battles_ranked (${battleList}) SELECT ${battleList} FROM incoming_battles_ranked;
INSERT INTO public.legend_rankings_history (${rankingList}) SELECT ${rankingList} FROM incoming_legend_rankings;
DO $$ BEGIN
  IF (SELECT count(*) FROM public.battles_ranked
    ${battleWhere}) <> ${expected.battleCount}
    OR (SELECT count(*) FROM public.legend_rankings_history
      ${rankingWhere}) <> ${expected.rankingCount}
    OR ${sourceBattlesDigest} <> ${targetBattlesDigest}
    OR ${sourceRankingsDigest} <> ${targetRankingsDigest}
  THEN RAISE EXCEPTION 'Post-replacement count or hash mismatch; transaction rolled back'; END IF;
END $$;
SELECT json_build_object('replacedBattles',${localBefore.battleCount},
  'importedBattles',${expected.battleCount},'battleDigest',${sourceBattlesDigest},
  'replacedRankings',${localBefore.rankingCount},
  'importedRankings',${expected.rankingCount},'rankingDigest',${sourceRankingsDigest})::text;
COMMIT;`;
}

async function run(command, args, input, environment) {
  const child = spawn(command, args, { env: environment, stdio: ['pipe', 'pipe', 'pipe'] });
  const stdout = [];
  const stderr = [];
  child.stdout.on('data', chunk => stdout.push(chunk));
  child.stderr.on('data', chunk => stderr.push(chunk));
  child.stdin.on('error', () => {}); // SSH may close early on connection failure.
  child.stdin.end(input);
  const code = await new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('close', resolve);
  });
  if (code !== 0) throw Error(`${command} exited ${code}: ${Buffer.concat(stderr).toString('utf8').trim()}`);
  return Buffer.concat(stdout).toString('utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
}

const remoteArgs = ['-T', '-o', 'BatchMode=yes', sourceHost, sourceCommand];
const localArgs = ['-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1'];

async function copyToFile(command, args, environment, sql, destination) {
  const child = spawn(command, args, { env: environment, stdio: ['pipe', 'pipe', 'pipe'] });
  const stderr = [];
  child.stderr.on('data', chunk => stderr.push(chunk));
  child.stdin.on('error', () => {});
  child.stdin.end(sql);
  const completed = new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('close', resolve);
  });
  await pipeline(child.stdout, createWriteStream(destination, { mode: 0o600 }));
  const code = await completed;
  if (code !== 0) throw Error(`${command} COPY exited ${code}: ${Buffer.concat(stderr).toString('utf8').trim()}`);
}

async function fileSha256(path) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest('hex');
}

export async function main(argv = process.argv.slice(2)) {
  const range = parseImportOptions(argv);
  const [source] = await run('ssh', remoteArgs, preflightSql(range), process.env);
  const [target] = await run('psql', localArgs, preflightSql(range), targetEnvironment);
  if (source.database !== 'clashking' || target.database !== 'clashking_dev' ||
      target.user !== 'clashking_local' ||
      JSON.stringify(source.battlesShape) !== JSON.stringify(target.battlesShape) ||
      JSON.stringify(source.rankingsShape) !== JSON.stringify(target.rankingsShape) ||
      source.battlesShape.map(([name]) => name).join(',') !== battlesColumns.join(',') ||
      source.rankingsShape.map(([name]) => name).join(',') !== rankingsColumns.join(',')) {
    throw Error('Source/target database identity or table schema mismatch; no rows imported');
  }
  if (range.days.some(day => !(source.rankingDays?.[day] > 0)) || source.battleCount <= 0) {
    throw Error('Production source is missing a requested Legend day; no rows imported');
  }
  console.log(JSON.stringify({ mode: range.apply ? 'apply' : 'dry-run', range,
    source: { battleCount: source.battleCount, battleDays: source.battleDays,
      rankingCount: source.rankingCount, rankingDays: source.rankingDays },
    localBefore: { battleCount: target.battleCount, battleDays: target.battleDays,
      rankingCount: target.rankingCount, rankingDays: target.rankingDays } }));
  if (!range.apply) return;
  const temporary = await mkdtemp(join(tmpdir(), 'clashking-legend-source-'));
  const battlesPath = join(temporary, 'source-battles.csv');
  const rankingsPath = join(temporary, 'source-rankings.csv');
  const backupBattlesPath = join(temporary, 'backup-local-battles.csv');
  const backupRankingsPath = join(temporary, 'backup-local-rankings.csv');
  let transactionAttempted = false;
  let backupBattlesSha256;
  let backupRankingsSha256;
  try {
    await copyToFile('ssh', remoteArgs, process.env,
      sourceCopySql(range, 'battles_ranked'), battlesPath);
    await copyToFile('ssh', remoteArgs, process.env,
      sourceCopySql(range, 'legend_rankings_history'), rankingsPath);
    await copyToFile('psql', localArgs, targetEnvironment,
      sourceCopySql(range, 'battles_ranked'), backupBattlesPath);
    await copyToFile('psql', localArgs, targetEnvironment,
      sourceCopySql(range, 'legend_rankings_history'), backupRankingsPath);
    backupBattlesSha256 = await fileSha256(backupBattlesPath);
    backupRankingsSha256 = await fileSha256(backupRankingsPath);
    transactionAttempted = true;
    const output = await run('psql', localArgs,
      mergeSql(range, battlesPath, rankingsPath, backupBattlesPath,
        backupRankingsPath, source, target), targetEnvironment);
    for (const row of output) console.log(JSON.stringify(row));
    const [readBack] = await run('psql', localArgs, preflightSql(range), targetEnvironment);
    console.log(JSON.stringify({ localReadBack: {
      battleCount: readBack.battleCount, battleDays: readBack.battleDays,
      rankingCount: readBack.rankingCount, rankingDays: readBack.rankingDays,
    } }));
    if (readBack.battleCount !== source.battleCount ||
        readBack.rankingCount !== source.rankingCount ||
        !sameDayCounts(readBack.battleDays, source.battleDays, range.days) ||
        !sameDayCounts(readBack.rankingDays, source.rankingDays, range.days)) {
      throw Error('Post-commit per-day read-back differs from source; stop before closeout');
    }
  } finally {
    if (transactionAttempted) {
      await rm(battlesPath, { force: true });
      await rm(rankingsPath, { force: true });
      console.log(JSON.stringify({ localRecovery: {
        battlesPath: backupBattlesPath, battlesSha256: backupBattlesSha256,
        rankingsPath: backupRankingsPath, rankingsSha256: backupRankingsSha256,
      } }));
    } else {
      await rm(temporary, { recursive: true, force: true });
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
