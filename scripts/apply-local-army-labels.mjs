// Local-only bridge for the evolving, unpublished 022 extension. Existing saved
// identities/timestamps and the Goose ledger stay unchanged; production uses 022.
import {createRequire} from 'node:module'
import {readFileSync,writeFileSync,mkdtempSync} from 'node:fs'
import {execFileSync} from 'node:child_process'
import {tmpdir} from 'node:os'
import {resolve,join} from 'node:path'
const dsn=process.env.CLASHKING_LOCAL_DATABASE_URL
const url=new URL(dsn)
if(url.hostname!=='127.0.0.1'||url.port!=='54330'||url.pathname!=='/clashking_dev') throw Error('Only the local development database is allowed')
const {Client}=createRequire(resolve(process.env.CLASHKING_API_REPO,'package.json'))('pg')
const client=new Client({connectionString:dsn})
await client.connect()
try {
 await client.query('BEGIN')
 await client.query("SET LOCAL lock_timeout='5s'; SET LOCAL statement_timeout='30s'")
 const head=(await client.query('SELECT max(version_id)::int AS head FROM goose_db_version WHERE is_applied')).rows[0].head
 if(head!==22)throw Error('Expected local Goose head 22')
 await client.query('LOCK TABLE user_saved_armies IN ACCESS EXCLUSIVE MODE')
 const columns=(await client.query("SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='user_saved_armies' AND column_name IN ('name','notes')")).rows
 if(columns.length===2){await client.query('ROLLBACK');console.log(JSON.stringify({alreadyApplied:true,head}));process.exit(0)}
 if(columns.length)throw Error('Partial label schema found; inspect before changing anything')
 // Export before DDL. pg_dump takes its own lock, so release ours first, then
 // re-lock and recheck the columns in the actual change transaction.
 await client.query('ROLLBACK')
 const backup=join(mkdtempSync(join(tmpdir(),'ck-army-labels-backup-')),'user_saved_armies.sql')
 writeFileSync(backup,execFileSync('pg_dump',[dsn,'--table=public.user_saved_armies','--no-owner','--no-privileges'],{maxBuffer:32*1024*1024}),{mode:0o600})
 await client.query('BEGIN')
 await client.query("SET LOCAL lock_timeout='5s'; SET LOCAL statement_timeout='30s'; LOCK TABLE user_saved_armies IN ACCESS EXCLUSIVE MODE")
 const signature=async()=>(await client.query("SELECT count(*)::int AS count,md5(coalesce(string_agg(user_id||':'||share_code||':'||saved_at::text,'|' ORDER BY user_id,share_code),'')) AS digest FROM user_saved_armies")).rows[0]
 const before=await signature()
 const source=readFileSync(new URL('../database/timescale/022_release_extension.sql',import.meta.url),'utf8')
 const table=source.match(/CREATE TABLE public\.user_saved_armies \(([\s\S]*?)\n\);/)[1]
 const definitions=['name','notes'].map(name=>table.split('\n').find(line=>line.trim().startsWith(`${name} text CHECK`))?.trim().replace(/,$/,''))
 if(definitions.some(value=>!value))throw Error('Canonical 022 label definitions are missing')
 await client.query(`ALTER TABLE user_saved_armies ${definitions.map(value=>`ADD COLUMN ${value}`).join(', ')}`)
 await client.query("COMMENT ON COLUMN user_saved_armies.name IS 'Per-user display name, not part of the shared immutable army composition.'")
 const after=await signature()
 if(JSON.stringify(before)!==JSON.stringify(after))throw Error('Existing saved army data changed')
 await client.query('COMMIT')
 console.log(JSON.stringify({head,rowsPreserved:after.count,backup,added:['name','notes']}))
} catch(error){await client.query('ROLLBACK');throw error} finally {await client.end()}
