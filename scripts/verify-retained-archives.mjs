import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {resolve} from 'node:path';
import {pathToFileURL,fileURLToPath} from 'node:url';

export async function verifyRetainedArchives(env=process.env) {
  if(!env.CLASHKING_API_REPO || !env.CLASHKING_LOCAL_ARCHIVE_IMPORT_ROOT || !env.CLASHKING_LOCAL_ARCHIVE_OFFSETS) throw Error('Explicit API, existing pack directory, and original offset manifest paths are required');
  const api=resolve(env.CLASHKING_API_REPO),packs=resolve(env.CLASHKING_LOCAL_ARCHIVE_IMPORT_ROOT);
  const offsets=JSON.parse(readFileSync(env.CLASHKING_LOCAL_ARCHIVE_OFFSETS,'utf8'));
  const require=createRequire(resolve(api,'package.json'));
  const {Client}=require('pg');
  const {createArchiveDecoder}=await import(pathToFileURL(resolve(api,'workers/api/src/war-archive-codec.ts')));
  const decode=createArchiveDecoder(new WebAssembly.Module(readFileSync(resolve(api,'node_modules/@bokuweb/zstd-wasm/dist/esm/zstd.wasm'))),readFileSync(resolve(api,'workers/api/assets/war-json.zdict')));
  const client=new Client({connectionString:'postgres://clashking_local:clashking_local@127.0.0.1:54329/clashking_dev'});
  await client.connect();
  try {
    await client.query('BEGIN READ ONLY');
    const {rows}=await client.query('SELECT war_id::text,clan_tag,opponent_tag,end_time,archive_pack_id::text,archive_offset::text,archive_compressed_bytes FROM wars WHERE archive_pack_id IS NOT NULL ORDER BY archive_pack_id,archive_offset');
    if(rows.length!==Object.keys(offsets).length) throw Error('Retained SQL archive coverage differs from the imported offset manifest');
    let currentPack=null,bytes=null,packCount=0,totalBytes=0;
    for(const row of rows) {
      const expected=offsets[row.war_id];
      const offset=Number(row.archive_offset),length=row.archive_compressed_bytes;
      if(!expected || String(expected.packId)!==row.archive_pack_id || expected.offset!==offset || expected.length!==length) throw Error(`Local archive locator mismatch: ${row.war_id}`);
      if(!/^\d+$/.test(row.archive_pack_id) || !Number.isSafeInteger(offset) || offset<0 || !Number.isSafeInteger(length) || length<=0) throw Error('Invalid local archive locator');
      if(currentPack!==row.archive_pack_id) {
        currentPack=row.archive_pack_id;
        bytes=readFileSync(resolve(packs,`${currentPack.padStart(6,'0')}.pack`));
        packCount++;totalBytes+=bytes.length;
      }
      if(offset+length>bytes.length) throw Error(`Local archive range exceeds object: ${row.war_id}`);
      const war=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(decode(bytes.subarray(offset,offset+length))));
      if(war.clan?.tag!==row.clan_tag || war.opponent?.tag!==row.opponent_tag || new Date(war.endTime).getTime()!==row.end_time.getTime()) throw Error(`Decoded archive identity mismatch: ${row.war_id}`);
    }
    await client.query('COMMIT');
    return {event:'retained_archives_verified',wars:rows.length,packs:packCount,bytes:totalBytes,networkDownloads:0};
  } finally {await client.end();}
}

if(process.argv[1]===fileURLToPath(import.meta.url)) verifyRetainedArchives().then(value=>console.log(JSON.stringify(value))).catch(error=>{console.error(error.message);process.exitCode=1;});
