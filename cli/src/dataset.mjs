import { createReadStream,createWriteStream,existsSync,renameSync } from 'node:fs';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { requireValues } from './workspace.mjs';
export function r2Config(env){
 requireValues(env,['DATASET_R2_BUCKET','R2_ENDPOINT']);
 if(!/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(env.DATASET_R2_BUCKET))throw Error('Invalid DATASET_R2_BUCKET');
 const u=new URL(env.R2_ENDPOINT);
 if(u.protocol!=='https:'||u.hostname.endsWith('.r2.cloudflarestorage.com')||u.username||u.password||u.search||u.hash)throw Error('R2_ENDPOINT must be the public HTTPS bucket URL, not the authenticated S3 endpoint');
 return {bucket:env.DATASET_R2_BUCKET,endpoint:u.href.replace(/\/+$/,'')+'/'};
}
export function validateManifest(m){
 if(!/^database\/[a-zA-Z0-9._-]+\.dump\.gpg$/.test(m.key??'')||!/^[a-f0-9]{64}$/.test(m.sha256??''))throw Error('Invalid starter backup manifest');
 return m;
}
export async function pullDataset(w){
 const config=r2Config(w.env);
 const get=async key=>{const r=await fetch(new URL(key,config.endpoint),{signal:AbortSignal.timeout(3600000)});if(!r.ok||!r.body)throw Error(`Public dataset download failed (${r.status})`);return r;};
 const response=await get('database/latest.json');
 const reader=response.body.getReader();let body='',length=0;
 while(true){const {done,value}=await reader.read();if(done)break;length+=value.length;if(length>65536){await reader.cancel();throw Error('Dataset manifest is too large');}body+=Buffer.from(value).toString('utf8');}
 const m=validateManifest(JSON.parse(body));
 const file=join(w.dir,'datasets',`${m.sha256}.dump.gpg`),partial=file+'.partial';
 if(!existsSync(file)){if(existsSync(partial))throw Error(`Incomplete download exists at ${partial}; inspect it before retrying`);const r=await get(m.key);await pipeline(Readable.fromWeb(r.body),createWriteStream(partial,{flags:'wx',mode:0o600}));}
 const hash=createHash('sha256');for await(const chunk of createReadStream(existsSync(file)?file:partial))hash.update(chunk);
 if(hash.digest('hex')!==m.sha256)throw Error('Dataset checksum does not match; refusing to import');
 if(!existsSync(file))renameSync(partial,file);
 return file;
}
