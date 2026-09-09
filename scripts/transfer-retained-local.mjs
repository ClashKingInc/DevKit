import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {resolve} from 'node:path';
import {spawnSync} from 'node:child_process';

export const quoteIdentifier = value => '"'+value.replaceAll('"','""')+'"';

export function transferProjection(table,columns) {
  return {
    source: columns.map(column=>`${quoteIdentifier(column)}::text AS ${quoteIdentifier(column)}`).join(','),
    incoming: columns.map(column=>`${quoteIdentifier(column)} text`).join(','),
    decoded: columns.map(column=>{
      const type=table.types[column];
      if(!type) throw Error(`Missing catalog type for ${column}`);
      return `incoming.${quoteIdentifier(column)}::${type}`;
    }),
  };
}

export function validateTransferTargets(sourceValue,targetValue,env) {
  const source=new URL(sourceValue), target=new URL(targetValue);
  if(source.protocol!=='postgres:' || source.hostname!=='127.0.0.1' || source.port!=='54329' || source.pathname!=='/clashking_dev' || source.username!=='clashking_local' || source.password!=='clashking_local') throw Error('Source must be the retained loopback development database');
  const disposable=env.CLASHKING_DISPOSABLE_TIMESCALE==='1' && target.protocol==='postgres:' && target.hostname==='127.0.0.1' && target.port && target.port!==source.port && target.pathname==='/clashking_test' && target.username==='clashking_test' && target.password==='clashking_test';
  const candidate=env.CLASHKING_RETAINED_CANDIDATE==='approved-local-007' && target.protocol==='postgres:' && target.hostname===source.hostname && target.port===source.port && target.username===source.username && target.password===source.password && target.pathname==='/clashking_dev_candidate_007';
  if(!disposable && !candidate) throw Error('Destination must be the schema-owned disposable fixture or explicitly approved local candidate');
  return {source,target};
}

const relation = table => `${quoteIdentifier(table.schema)}.${quoteIdentifier(table.name)}`;

async function tables(client) {
  const {rows}=await client.query(`SELECT n.nspname AS schema,c.relname AS name,
    array_agg(a.attname::text ORDER BY a.attnum) AS columns,
    json_object_agg(a.attname,format_type(a.atttypid,a.atttypmod)) AS types,
    COALESCE((SELECT array_agg(pa.attname::text ORDER BY keys.position) FROM pg_index i
      CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY keys(number,position)
      JOIN pg_attribute pa ON pa.attrelid=c.oid AND pa.attnum=keys.number WHERE i.indrelid=c.oid AND i.indisprimary),'{}') AS pk
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped AND a.attgenerated=''
    WHERE n.nspname IN ('public','discord_cache') AND c.relkind IN ('r','p') AND c.relname<>'goose_db_version'
    GROUP BY c.oid,n.nspname,c.relname ORDER BY n.nspname,c.relname`);
  return new Map(rows.map(row=>[`${row.schema}.${row.name}`,row]));
}

async function digest(client,table,columns) {
  const projection=columns.map(column=>table.schema==='public' && table.name==='ticket_panels' && column==='components'
    ? `COALESCE((SELECT jsonb_agg(component.value-'id' ORDER BY component.ordinality) FROM jsonb_array_elements(components) WITH ORDINALITY component(value,ordinality)),'[]'::jsonb) AS components`
    : quoteIdentifier(column)).join(',');
  const {rows}=await client.query(`SELECT count(*)::text AS count,md5(COALESCE(string_agg(hash,'' ORDER BY hash),'')) AS digest FROM
    (SELECT md5(row_to_json(value)::text) AS hash FROM (SELECT ${projection} FROM ${relation(table)}) value) hashed`);
  return rows[0];
}

async function copyRows(source,target,table,columns,{updateColumns=[]}={}) {
  const projection=columns.map(quoteIdentifier).join(',');
  const wire=transferProjection(table,columns);
  const count=await target.query(`SELECT count(*)::text AS count FROM ${relation(table)}`);
  const seeded=count.rows[0].count!=='0';
  if(updateColumns.length===0 && seeded && !table.pk.length) throw Error(`Cannot reconcile seeded fixture table without primary key ${relation(table)}`);
  await source.query(`DECLARE transfer_rows NO SCROLL CURSOR FOR SELECT row_to_json(value)::text AS document FROM (SELECT ${wire.source} FROM ${relation(table)}) value`);
  let transferred=0;
  try {
    for (;;) {
      const {rows}=await source.query('FETCH FORWARD 500 FROM transfer_rows');
      if(rows.length===0) break;
      // Keep PostgreSQL's JSON text intact: parsing bigint IDs in JavaScript
      // would silently round values larger than Number.MAX_SAFE_INTEGER.
      // Each non-SQL-null value travels as PostgreSQL text. In particular,
      // jsonb 'null' travels as the string "null", not JSON null: populating a
      // composite record directly would otherwise turn it into SQL NULL.
      const payload='['+rows.map(row=>row.document).join(',')+']';
      if(updateColumns.length) {
        if(!table.pk.length) throw Error(`No stable identity for extra columns in ${relation(table)}`);
        await target.query(`UPDATE ${relation(table)} AS existing SET ${updateColumns.map(column=>`${quoteIdentifier(column)}=${wire.decoded[columns.indexOf(column)]}`).join(',')}
          FROM jsonb_to_recordset($1::jsonb) AS incoming(${wire.incoming})
          WHERE ${table.pk.map(column=>`existing.${quoteIdentifier(column)}=${wire.decoded[columns.indexOf(column)]}`).join(' AND ')}`,[payload]);
      } else {
        const changes=columns.filter(column=>!table.pk.includes(column));
        const conflict=seeded ? ` ON CONFLICT (${table.pk.map(quoteIdentifier).join(',')}) DO ${changes.length ? 'UPDATE SET '+changes.map(column=>`${quoteIdentifier(column)}=EXCLUDED.${quoteIdentifier(column)}`).join(',') : 'NOTHING'}` : '';
        await target.query(`INSERT INTO ${relation(table)} (${projection}) OVERRIDING SYSTEM VALUE SELECT ${wire.decoded.join(',')} FROM jsonb_to_recordset($1::jsonb) AS incoming(${wire.incoming})${conflict}`,[payload]);
      }
      transferred+=rows.length;
    }
  } finally { await source.query('CLOSE transfer_rows'); }
  const before=await digest(source,table,columns), after=await digest(target,table,columns);
  if(before.count!==after.count || before.digest!==after.digest) throw Error(`Data comparison failed for ${relation(table)}`);
  return transferred;
}

async function validateForeignKeys(client) {
  const {rows}=await client.query(`SELECT c.conname, c.conrelid::regclass::text AS child,c.confrelid::regclass::text AS parent,c.confmatchtype,
    array_agg(a.attname::text ORDER BY keys.position) AS child_columns,array_agg(b.attname::text ORDER BY keys.position) AS parent_columns
    FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace n ON n.oid=t.relnamespace
    CROSS JOIN LATERAL unnest(c.conkey,c.confkey) WITH ORDINALITY keys(child_number,parent_number,position)
    JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=keys.child_number
    JOIN pg_attribute b ON b.attrelid=c.confrelid AND b.attnum=keys.parent_number
    WHERE c.contype='f' AND n.nspname IN ('public','discord_cache') GROUP BY c.oid`);
  for(const row of rows) {
    if(row.confmatchtype!=='s') throw Error(`Unsupported foreign-key match mode: ${row.conname}`);
    const joined=row.child_columns.map((column,index)=>`child.${quoteIdentifier(column)}=parent.${quoteIdentifier(row.parent_columns[index])}`).join(' AND ');
    const nonnull=row.child_columns.map(column=>`child.${quoteIdentifier(column)} IS NOT NULL`).join(' AND ');
    const check=await client.query(`SELECT EXISTS(SELECT 1 FROM ${row.child} child WHERE ${nonnull} AND NOT EXISTS(SELECT 1 FROM ${row.parent} parent WHERE ${joined})) AS invalid`);
    if(check.rows[0].invalid) throw Error(`Retained rows violate ${row.conname}`);
  }
  return rows.length;
}

async function resetOwnedSequences(client,catalog) {
  for(const table of catalog.values()) for(const column of table.columns) {
    const {rows}=await client.query('SELECT pg_get_serial_sequence($1,$2) AS sequence',[relation(table),column]);
    if(rows[0].sequence) await client.query(`SELECT setval($1::regclass,GREATEST(COALESCE(max(${quoteIdentifier(column)}),1),1),count(*)>0) FROM ${relation(table)}`,[rows[0].sequence]);
  }
}

export async function rehearseRetainedTransfer(env=process.env,{onSourceConnected,onValidated}={}) {
  const {source:sourceURL,target:targetURL}=validateTransferTargets(env.CLASHKING_SOURCE_DATABASE_URL??'postgres://clashking_local:clashking_local@127.0.0.1:54329/clashking_dev',env.TEST_DATABASE_URL,env);
  if(!env.CLASHKING_API_REPO) throw Error('CLASHKING_API_REPO is required to use its pinned pg dependency');
  const require=createRequire(resolve(env.CLASHKING_API_REPO,'package.json'));
  const {Client}=require('pg');
  const source=new Client({connectionString:sourceURL.href}),target=new Client({connectionString:targetURL.href});
  const report={baseline:[],restored:[],verifiedAfterMigration:[],intentionallyRemoved:[],foreignKeys:0};
  try {
    await source.connect();await target.connect();
    if(onSourceConnected) await onSourceConnected(source.processID,source,target);
    await source.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
    const history=await source.query('SELECT version_id::text FROM goose_db_version WHERE is_applied ORDER BY goose_db_version.version_id');
    if(history.rows.map(row=>row.version_id).join(',')!=='0,1,2,3,4,5,6,7,8,9,10,12,13,20,22,23,27,28') throw Error('Retained migration history differs from the reviewed source');
    const version=await target.query('SELECT max(version_id)::text AS version FROM goose_db_version WHERE is_applied');
    if(version.rows[0].version!=='6') throw Error('Start destination through --profile baseline-006');
    const old=await tables(source),baseline=await tables(target);
    await target.query('BEGIN');
    // Only the disposable target relaxes trigger order while loading the
    // snapshot. Every FK is explicitly checked before committing this phase.
    await target.query("SET LOCAL session_replication_role='replica'");
    for(const [name,table] of baseline) {
      const previous=old.get(name);
      if(!previous) continue;
      const columns=table.columns.filter(column=>previous.columns.includes(column));
      const count=await copyRows(source,target,table,columns);
      report.baseline.push({table:name,count});
    }
    report.foreignKeys=await validateForeignKeys(target);
    await resetOwnedSequences(target,baseline);
    await target.query('COMMIT');
    const root=resolve(fileURLToPath(new URL('..',import.meta.url)));
    const migrated=spawnSync('goose',['-env','/dev/null','-dir',resolve(root,'database/timescale'),'postgres',targetURL.href,'up-to','7'],{encoding:'utf8',env:{...env,GOOSE_DBSTRING:'',GOOSE_DRIVER:'',ADMIN_OWNER_BOOTSTRAP_B64:''}});
    if(migrated.status!==0) throw Error(`Goose 006 to 007 failed: ${migrated.stderr?.slice(0,1500)}`);
    const canonical=await tables(target);
    await target.query('BEGIN');
    await target.query("SET LOCAL session_replication_role='replica'");
    for(const [name,previous] of old) {
      const table=canonical.get(name);
      if(!table) {report.intentionallyRemoved.push(name);continue;}
      const columns=table.columns.filter(column=>previous.columns.includes(column));
      if(!baseline.has(name)) {
        report.restored.push({table:name,count:await copyRows(source,target,table,columns)});
      } else {
        const extra=columns.filter(column=>!baseline.get(name).columns.includes(column));
        if(extra.length) {
          const selected=[...table.pk,...extra];
          report.restored.push({table:name,columns:extra,count:await copyRows(source,target,table,selected,{updateColumns:extra})});
        }
      }
    }
    report.foreignKeys=await validateForeignKeys(target);
    await resetOwnedSequences(target,canonical);
    // A successful import before migration is insufficient: prove every retained
    // field still agrees after Goose and restoration. Ticket components gain UUID
    // ids by design; their payload comparison excludes only that generated field.
    const allowedRemoved=new Set(['discord_cache.delivery_receipts','public.discord_managed_resources','public.player_link_mutation_locks','public.roster_ai_budget_locks','public.subject_mutation_locks']);
    for(const name of report.intentionallyRemoved) if(!allowedRemoved.has(name)) throw Error(`Unexpected removed retained table: ${name}`);
    for(const [name,previous] of old) {
      const table=canonical.get(name);
      if(!table) continue;
      const columns=table.columns.filter(column=>previous.columns.includes(column));
      const before=await digest(source,table,columns),after=await digest(target,table,columns);
      if(before.count!==after.count || before.digest!==after.digest) throw Error(`Post-migration data comparison failed for ${relation(table)}`);
      report.verifiedAfterMigration.push({table:name,count:Number(after.count)});
    }
    const ticketIdentities=await target.query(`SELECT
      NOT EXISTS(SELECT 1 FROM public.ticket_panel legacy LEFT JOIN public.ticket_panels current ON current.id=legacy.id WHERE current.id IS NULL) AS panels,
      NOT EXISTS(SELECT 1 FROM public.ticket_panel_buttons legacy JOIN public.ticket_panels current ON current.id=legacy.panel_id
        CROSS JOIN LATERAL jsonb_array_elements(current.components) component
        WHERE current.archived_at IS NULL AND component->>'custom_id'=legacy.custom_id AND component->>'id' IS DISTINCT FROM legacy.id::text) AS buttons`);
    if(!ticketIdentities.rows[0].panels || !ticketIdentities.rows[0].buttons) throw Error('Migrated ticket identities differ from retained identities');
    await target.query('COMMIT');
    await source.query('COMMIT');
    if(onValidated) await onValidated(target);
    return report;
  } finally {
    await source.query('ROLLBACK').catch(()=>{});await target.query('ROLLBACK').catch(()=>{});
    await source.end().catch(()=>{});await target.end().catch(()=>{});
  }
}

if(process.argv[1]===fileURLToPath(import.meta.url)) {
  rehearseRetainedTransfer().then(report=>console.log(JSON.stringify({event:'retained_transfer_rehearsal_verified',...report}))).catch(error=>{console.error(error.message);process.exitCode=1;});
}
