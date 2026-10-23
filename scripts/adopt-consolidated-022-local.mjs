// Adopt the final unpublished 022 only after a fresh Goose 001..022 database
// proves full public-schema equivalence. No application rows are rewritten.
import {createRequire} from 'node:module'
import {readFileSync, writeFileSync} from 'node:fs'
import {createHash, randomUUID} from 'node:crypto'
import {execFileSync} from 'node:child_process'
import {resolve} from 'node:path'
import {tmpdir} from 'node:os'
import {fileURLToPath} from 'node:url'

const root=fileURLToPath(new URL('../',import.meta.url))
const args=process.argv.slice(2)
const apply=args.includes('--apply-local')
const expected=args.find(arg=>arg.startsWith('--expect-schema-sha256='))?.split('=')[1]
const local=process.env.CLASHKING_LOCAL_DATABASE_URL
const reference=process.env.CLASHKING_REFERENCE_DATABASE_URL
for(const dsn of [local,reference]) {
 if(!dsn) throw Error('Local and freshly Goose-migrated reference database URLs are required')
 const url=new URL(dsn)
 if(!['127.0.0.1','localhost','[::1]'].includes(url.hostname)||!['postgres:','postgresql:'].includes(url.protocol)) throw Error('Only loopback PostgreSQL databases are allowed')
}
if(new URL(local).pathname===new URL(reference).pathname) throw Error('Reference must be a separate disposable database')
if(!process.env.CLASHKING_API_REPO) throw Error('CLASHKING_API_REPO is required for the existing PostgreSQL driver')
if(apply&&!/^[a-f0-9]{64}$/.test(expected??'')) throw Error('Inspect first and supply --expect-schema-sha256')
const {Client}=createRequire(resolve(process.env.CLASHKING_API_REPO,'package.json'))('pg')
const manifest=JSON.parse(readFileSync(resolve(root,'database/migration_history/unpublished-022-060/manifest.json'),'utf8'))
const sha=text=>createHash('sha256').update(text).digest('hex')
for(const entry of manifest.files.filter(entry=>entry.version<=21)) {
 if(sha(readFileSync(resolve(root,'database/timescale',entry.file)))!==entry.sha256) throw Error('Published migration changed: '+entry.file)
}
if(sha(readFileSync(resolve(root,'database/timescale',manifest.consolidatedFile)))!==manifest.consolidatedSha256) throw Error('Consolidated migration checksum mismatch')
const clients=[new Client({connectionString:local}),new Client({connectionString:reference})]
function sections(dsn,snapshot) {
 const dump=execFileSync('pg_dump',[dsn,'--schema-only','--schema=public','--exclude-table=public.goose_db_version','--no-owner','--no-privileges','--snapshot='+snapshot],{encoding:'utf8',maxBuffer:20*1024*1024})
 // pg_dump emits dependency order and random restriction tokens. Preserve every
 // SQL byte inside each named object, but sort objects independently of OIDs.
 return dump.replace(/^\\(?:un)?restrict.*$/gm,'').split(/(?=^--\n-- Name: )/m).map(s=>s.trim()).sort()
}
async function ledger(client,head) {
 const rows=(await client.query('SELECT id,version_id::text,is_applied,tstamp FROM public.goose_db_version ORDER BY id')).rows
 if(rows.length!==head+1||rows.some((row,i)=>Number(row.version_id)!==i||!row.is_applied)) throw Error('Expected exact, unreverted ledger 0..'+head)
 return rows
}
async function timescaleShape(client) {
 return (await client.query(`SELECT jsonb_build_object(
  'hypertables',(SELECT jsonb_agg(to_jsonb(h) ORDER BY hypertable_name)
    FROM (SELECT hypertable_schema,hypertable_name,num_dimensions,compression_enabled
      FROM timescaledb_information.hypertables WHERE hypertable_schema='public') h),
  'dimensions',(SELECT jsonb_agg(to_jsonb(d) ORDER BY hypertable_name,dimension_number)
    FROM (SELECT hypertable_schema,hypertable_name,dimension_number,column_name,column_type,
      dimension_type,time_interval,integer_interval,num_partitions
      FROM timescaledb_information.dimensions WHERE hypertable_schema='public') d),
  'policies',(SELECT jsonb_agg(to_jsonb(p) ORDER BY hypertable_name,proc_schema,proc_name)
    FROM (SELECT hypertable_schema,hypertable_name,proc_schema,proc_name,schedule_interval,
      max_runtime,max_retries,retry_period,config-'hypertable_id'-'mat_hypertable_id' AS config
      FROM timescaledb_information.jobs WHERE hypertable_schema='public') p)
 ) AS shape`)).rows[0].shape
}
try {
 for(const c of clients) { await c.connect(); await c.query('BEGIN ISOLATION LEVEL REPEATABLE READ'); await c.query("SET LOCAL statement_timeout='30s'; SET LOCAL lock_timeout='5s'") }
 if(apply) await clients[0].query('LOCK TABLE public.goose_db_version IN EXCLUSIVE MODE')
 const beforeLedger=await ledger(clients[0],23)
 await ledger(clients[1],22)
 const timescale=await timescaleShape(clients[0])
 if(JSON.stringify(timescale)!==JSON.stringify(await timescaleShape(clients[1]))) throw Error('Timescale dimensions, compression flags or policy settings differ')
 const snapshots=[]
 for(const c of clients) snapshots.push((await c.query('SELECT pg_export_snapshot() AS snapshot')).rows[0].snapshot)
 const before=sections(local,snapshots[0]),fresh=sections(reference,snapshots[1])
 const schemaSha256=sha(JSON.stringify(fresh))
 if(expected&&expected!==schemaSha256) throw Error('Reference schema changed after inspection')
 const onlyLocal=before.filter(x=>!fresh.includes(x)),onlyFresh=fresh.filter(x=>!before.includes(x))
 const grantHeader='--\n-- Name: dashboard_role_grants; Type: TABLE;'
 const indexHeader='--\n-- Name: role_refresh_jobs_completed; Type: INDEX;'
 const allowedLocal=onlyLocal.filter(x=>x.startsWith(grantHeader))
 const allowedFresh=onlyFresh.filter(x=>x.startsWith(grantHeader)||x.startsWith(indexHeader))
 if(onlyLocal.length!==allowedLocal.length||onlyFresh.length!==allowedFresh.length) throw Error('Unexpected public schema drift; adoption refused')
 if(allowedLocal.length) {
  const target=fresh.find(x=>x.startsWith(grantHeader))
  if(allowedLocal.length!==1||allowedLocal[0].replace("'settings'::text, 'family_settings'::text,","'settings'::text,")!==target) throw Error('Unexpected role-grant constraint drift')
 }
 if(onlyFresh.some(x=>x.startsWith(grantHeader))&&!allowedLocal.length) throw Error('Missing role-grants table')
 const obsolete=(await clients[0].query("SELECT count(*)::int AS n FROM public.dashboard_role_grants WHERE section='family_settings'")).rows[0].n
 if(obsolete) throw Error('Obsolete family_settings grants require explicit data migration')
 const counts=async()=> (await clients[0].query('SELECT (SELECT count(*) FROM public.reminders)::text AS reminders,(SELECT count(*) FROM public.dashboard_role_grants)::text AS grants,(SELECT count(*) FROM public.role_refresh_jobs)::text AS role_jobs')).rows[0]
 const beforeCounts=await counts()
 let backup
 if(apply) {
  backup=resolve(tmpdir(),'clashking-pre-final022-ledger-'+randomUUID()+'.json')
  writeFileSync(backup,JSON.stringify({database:new URL(local).pathname,beforeLedger,beforeCounts,beforeSchema:before,referenceSchema:fresh,timescale,schemaSha256,manifest},null,2)+'\n',{flag:'wx',mode:0o600})
  if(allowedLocal.length) {
   await clients[0].query('ALTER TABLE public.dashboard_role_grants DROP CONSTRAINT dashboard_role_grants_section_check')
   await clients[0].query("ALTER TABLE public.dashboard_role_grants ADD CONSTRAINT dashboard_role_grants_section_check CHECK(section IN ('settings','logs','clans','rosters','links','moderation','roles','reminders','autoboards','giveaways','panels','tickets','embeds','wars','leaderboards'))")
  }
  if(onlyFresh.some(x=>x.startsWith(indexHeader))) await clients[0].query('CREATE INDEX role_refresh_jobs_completed ON public.role_refresh_jobs (completed_at) WHERE completed_at IS NOT NULL')
  // pg_dump on another connection cannot see uncommitted DDL. Compare after
  // applying those exact reference statements through this transaction instead.
  const constraint=(await clients[0].query("SELECT pg_get_constraintdef(oid) AS definition FROM pg_constraint WHERE conrelid='public.dashboard_role_grants'::regclass AND conname='dashboard_role_grants_section_check'")).rows[0].definition
  const refConstraint=(await clients[1].query("SELECT pg_get_constraintdef(oid) AS definition FROM pg_constraint WHERE conrelid='public.dashboard_role_grants'::regclass AND conname='dashboard_role_grants_section_check'")).rows[0].definition
  const index=(await clients[0].query("SELECT pg_get_indexdef('public.role_refresh_jobs_completed'::regclass) AS definition")).rows[0].definition
  const refIndex=(await clients[1].query("SELECT pg_get_indexdef('public.role_refresh_jobs_completed'::regclass) AS definition")).rows[0].definition
  if(constraint!==refConstraint||index!==refIndex) throw Error('Reconciled schema definitions do not match reference')
  if(JSON.stringify(await counts())!==JSON.stringify(beforeCounts)) throw Error('Application row counts changed')
  const removed=await clients[0].query('DELETE FROM public.goose_db_version WHERE version_id=23 AND is_applied RETURNING id')
  if(removed.rowCount!==1) throw Error('Expected exactly one version23 ledger row')
  await ledger(clients[0],22)
  await clients[0].query('COMMIT')
 } else await clients[0].query('ROLLBACK')
 await clients[1].query('ROLLBACK')
 console.log(JSON.stringify({applied:apply,previousHead:23,replacementHead:22,schemaSha256,comparedPublicObjects:fresh.length-1,reconciledObjects:onlyFresh.map(x=>x.split('\n')[1]),applicationCounts:beforeCounts,...backup?{ledgerBackup:backup}:{}},null,2))
} catch(error) { for(const c of clients) await c.query('ROLLBACK').catch(()=>{}); throw error }
finally { for(const c of clients) await c.end() }
