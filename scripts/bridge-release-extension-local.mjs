// Explicit local-only adoption of the consolidated unpublished migration.
// Refuses removal of a nonempty obsolete manual-reminder queue.
import {createRequire} from 'node:module'
import {readFileSync,writeFileSync} from 'node:fs'
import {createHash,randomUUID} from 'node:crypto'
import {fileURLToPath} from 'node:url'
import {resolve} from 'node:path'
import {tmpdir} from 'node:os'

const root=fileURLToPath(new URL('../',import.meta.url))
const args=process.argv.slice(2)
const apply=args.includes('--apply-local')
const expected=args.find(arg=>arg.startsWith('--expect-schema-sha256='))?.split('=')[1]
const dsn=process.env.CLASHKING_LOCAL_DATABASE_URL
if(!dsn) throw Error('CLASHKING_LOCAL_DATABASE_URL is required')
const url=new URL(dsn)
if(!['127.0.0.1','localhost','[::1]'].includes(url.hostname)||!['postgres:','postgresql:'].includes(url.protocol)) throw Error('Only a loopback database is permitted')
if(apply&&!/^[a-f0-9]{64}$/.test(expected??'')) throw Error('Inspect first, then provide --expect-schema-sha256 from that report')
if(!process.env.CLASHKING_API_REPO) throw Error('CLASHKING_API_REPO is required to locate the existing PostgreSQL driver')
const {Client}=createRequire(resolve(process.env.CLASHKING_API_REPO,'package.json'))('pg')
const archive=resolve(root,'database/migration_history/unpublished-022-060')
const manifest=JSON.parse(readFileSync(resolve(archive,'manifest.json'),'utf8'))
for(const entry of manifest.files.filter(entry=>entry.version<=21)){
 const actual=createHash('sha256').update(readFileSync(resolve(root,'database/timescale',entry.file))).digest('hex')
 if(actual!==entry.sha256) throw Error('Published migration checksum mismatch: '+entry.file)
}
const consolidated=createHash('sha256').update(readFileSync(resolve(root,'database/timescale',manifest.consolidatedFile))).digest('hex')
if(consolidated!==manifest.consolidatedSha256) throw Error('Consolidated migration checksum mismatch')
const client=new Client({connectionString:dsn})
try{
 await client.connect()
 await client.query(apply?'BEGIN':'BEGIN READ ONLY')
 await client.query("SET LOCAL statement_timeout='30s'")
 await client.query("SET LOCAL lock_timeout='5s'")
 if(apply) await client.query('LOCK TABLE public.goose_db_version IN EXCLUSIVE MODE')
 const ledger=(await client.query('SELECT id,version_id::text,is_applied,tstamp FROM public.goose_db_version ORDER BY id')).rows
 const latest=new Map(ledger.map(row=>[Number(row.version_id),row.is_applied]))
 const versions=[...latest].filter(([version,active])=>version>0&&active).map(([version])=>version).sort((a,b)=>a-b)
 const expectedVersions=Array.from({length:60},(_,i)=>i+1)
 if(JSON.stringify(versions)!==JSON.stringify(expectedVersions)) throw Error('Bridge requires exactly the fully applied original migrations1..60; partial, changed, or already consolidated ledgers are refused')
 const schema=(await client.query(`SELECT jsonb_agg(row_to_json(c) ORDER BY c.table_name,c.ordinal_position) AS shape
 FROM (SELECT table_name,column_name,ordinal_position,data_type,udt_name,is_nullable,column_default
 FROM information_schema.columns WHERE table_schema='public' AND table_name<>'goose_db_version') c`)).rows[0].shape
 const schemaSha256=createHash('sha256').update(JSON.stringify(schema)).digest('hex')
 if(schemaSha256!==manifest.originalSchemaSha256) throw Error('Local schema does not match a clean application of original migrations1..60')
 if(expected&&expected!==schemaSha256) throw Error('Local schema changed since inspection; checksum mismatch')
 const additions=(await client.query(`SELECT table_name,column_name FROM information_schema.columns WHERE table_schema='public'
 AND ((table_name='basic_player' AND column_name='last_active') OR (table_name='autoboards' AND column_name='row_limit'))`)).rows
 if(additions.length) throw Error('New extension columns already exist under an original ledger; inspect the mismatch explicitly')
 let backup
 if(apply){
  backup=resolve(tmpdir(),'clashking-pre-extension-ledger-'+randomUUID()+'.json')
  const retiredReminders=(await client.query("SELECT * FROM public.reminders WHERE type=4 OR lower(type_name)='inactivity'")).rows
  writeFileSync(backup,JSON.stringify({database:url.pathname,ledger,schemaSha256,manifest,retiredReminders},null,2)+'\n',{flag:'wx',mode:0o600})
  await client.query('ALTER TABLE public.basic_player ADD COLUMN last_active timestamptz')
  await client.query('ALTER TABLE public.autoboards ADD COLUMN row_limit integer NOT NULL DEFAULT 10 CHECK (row_limit BETWEEN 1 AND 50)')
  await client.query('LOCK TABLE public.manual_reminder_requests IN ACCESS EXCLUSIVE MODE')
  const requests=(await client.query('SELECT count(*)::int AS count FROM public.manual_reminder_requests')).rows[0].count
  if(requests!==0) throw Error('Obsolete manual reminder queue is nonempty; explicit inspection is required before removal')
  await client.query('DROP TABLE public.manual_reminder_requests')
  await client.query("DELETE FROM public.reminders WHERE type=4 OR lower(type_name)='inactivity'")
  await client.query("ALTER TABLE public.reminders ADD CONSTRAINT reminders_no_inactivity_check CHECK(type<>4 AND lower(COALESCE(type_name,''))<>'inactivity')")
  await client.query('DELETE FROM public.goose_db_version WHERE version_id>=22')
  await client.query('INSERT INTO public.goose_db_version(version_id,is_applied) VALUES(22,true)')
  await client.query('COMMIT')
 }else await client.query('ROLLBACK')
 console.log(JSON.stringify({applied:apply,originalHead:60,replacementHead:22,verifiedMigrationFiles:manifest.files.length,schemaSha256,...backup?{ledgerBackup:backup}:{}},null,2))
}catch(error){await client.query('ROLLBACK').catch(()=>{});throw error}
finally{await client.end()}
