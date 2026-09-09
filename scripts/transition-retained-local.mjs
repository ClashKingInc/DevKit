import {createRequire} from 'node:module';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {resolve} from 'node:path';
import {rehearseRetainedTransfer} from './transfer-retained-local.mjs';

const original='clashking_dev';
const candidate='clashking_dev_candidate_007';
const retired='clashking_dev_retired_028';
const connection='postgres://clashking_local:clashking_local@127.0.0.1:54329/';

export function validateTransitionArguments(args) {
  if(args.length!==1 || args[0]!=='--approve-local-007-switch') throw Error('Requires --approve-local-007-switch; this changes only the retained loopback database');
}

export async function switchDatabaseNames(admin) {
  await admin.query(`ALTER DATABASE ${original} RENAME TO ${retired}`);
  try {
    await admin.query(`ALTER DATABASE ${candidate} RENAME TO ${original}`);
  } catch(error) {
    try {
      await admin.query(`ALTER DATABASE ${retired} RENAME TO ${original}`);
    } catch(recoveryError) {
      throw new AggregateError(
        [error,recoveryError],
        `Candidate rename failed and compensating recovery could not restore ${original}; source data remains in ${retired}`,
      );
    }
    throw error;
  }
}

export async function transitionRetainedLocal(env=process.env) {
  if(!env.CLASHKING_API_REPO) throw Error('CLASHKING_API_REPO is required');
  const require=createRequire(resolve(env.CLASHKING_API_REPO,'package.json'));
  const {Client}=require('pg');
  const admin=new Client({connectionString:connection+'postgres'});
  let created=false, frozen=false, switched=false;
  try {
    await admin.connect();
    const lock=await admin.query("SELECT pg_try_advisory_lock(hashtextextended('clashking-local-007-transition',0)) AS held");
    if(!lock.rows[0].held) throw Error('Another local transition is running');
    const databases=await admin.query('SELECT datname,datallowconn FROM pg_database WHERE datname=ANY($1)',[[original,candidate,retired]]);
    if(databases.rows.length!==1 || databases.rows[0].datname!==original || !databases.rows[0].datallowconn) throw Error('Expected only the enabled original local database; refusing to overwrite any candidate or retired copy');
    const active=await admin.query("SELECT count(*)::int AS count FROM pg_stat_activity WHERE datname=$1 AND backend_type='client backend'",[original]);
    if(active.rows[0].count!==0) throw Error('Stop local API/Tracking clients before switching the retained database');
    await admin.query(`CREATE DATABASE ${candidate} OWNER clashking_local TEMPLATE template0`);
    created=true;
    const migrationRoot=resolve(fileURLToPath(new URL('../database/timescale',import.meta.url)));
    const migrated=spawnSync('goose',['-env','/dev/null','-dir',migrationRoot,'postgres',connection+candidate,'up-to','6'],{encoding:'utf8',env:{...env,GOOSE_DBSTRING:'',GOOSE_DRIVER:'',ADMIN_OWNER_BOOTSTRAP_B64:''}});
    if(migrated.status!==0) throw Error(`Candidate Goose baseline failed: ${migrated.stderr?.slice(0,1500)}`);
    const report=await rehearseRetainedTransfer({...env,TEST_DATABASE_URL:connection+candidate,CLASHKING_RETAINED_CANDIDATE:'approved-local-007'}, {
      async onSourceConnected(pid,source,target) {
        // Preserve source bytes while blocking new application connections. Never
        // terminate someone else's session; abort if a writer raced our preflight.
        await source.query('SELECT _timescaledb_functions.stop_background_workers()');
        await target.query('SELECT _timescaledb_functions.stop_background_workers()');
        await admin.query(`ALTER DATABASE ${original} ALLOW_CONNECTIONS false`);
        frozen=true;
        const remaining=await admin.query('SELECT count(*)::int AS count FROM pg_stat_activity WHERE datname=$1 AND pid<>$2',[original,pid]);
        if(remaining.rows[0].count!==0) throw Error('Another client connected during transition; source was not changed');
      },
      async onValidated(target) {
        await target.query('SELECT _timescaledb_functions.stop_background_workers()');
      },
    });
    await switchDatabaseNames(admin);
    switched=true;
    const current=new Client({connectionString:connection+original});
    try {
      await current.connect();
      await current.query('SELECT _timescaledb_functions.start_background_workers()');
    } finally {await current.end();}
    return {event:'retained_local_007_switched',database:original,retiredDatabase:retired,retiredConnectionsEnabled:false,verifiedTables:report.verifiedAfterMigration.length,foreignKeys:report.foreignKeys,cleanup:'Retired database retained only until cross-process acceptance; remove it explicitly after acceptance.'};
  } finally {
    if(!switched) {
      if(frozen) {
        await admin.query(`ALTER DATABASE ${original} ALLOW_CONNECTIONS true`);
        const restored=new Client({connectionString:connection+original});
        try {await restored.connect();await restored.query('SELECT _timescaledb_functions.start_background_workers()');}
        finally {await restored.end();}
      }
      // This exact candidate was created in this invocation and never served
      // application traffic. The original is never dropped by this utility.
      if(created) await admin.query(`DROP DATABASE ${candidate}`);
    }
    await admin.end();
  }
}

if(process.argv[1]===fileURLToPath(import.meta.url)) {
  Promise.resolve().then(()=>validateTransitionArguments(process.argv.slice(2)))
    .then(()=>transitionRetainedLocal())
    .then(report=>console.log(JSON.stringify(report)))
    .catch(error=>{console.error(error.message);process.exitCode=1;});
}
