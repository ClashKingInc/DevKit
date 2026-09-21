import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync,mkdirSync,writeFileSync,readFileSync,rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { initWorkspace,encodeEnv } from '../src/workspace.mjs';
import { control } from '../src/supervisor.mjs';
test('supervisor authenticates control and stops only its own child',async t=>{
 const root=mkdtempSync(join(tmpdir(),'clashking-supervisor-test-')),api=join(root,'api');mkdirSync(join(api,'scripts'),{recursive:true});
 writeFileSync(join(api,'scripts/start-local-rewrite-api.mjs'),'setInterval(()=>{},1000);');
 const w=initWorkspace(root,{api});writeFileSync(join(w.dir,'local.env'),encodeEnv({...w.env,DISCORD_CLIENT_ID:'123',DISCORD_CLIENT_SECRET:'test'}));
 const child=spawn(process.execPath,[fileURLToPath(new URL('../src/supervisor.mjs',import.meta.url)),root,'api'],{stdio:'ignore'});
 const exit=new Promise(resolve=>child.once('exit',resolve));
 t.after(async()=>{child.kill('SIGTERM');await exit;rmSync(root,{recursive:true,force:true});});
 let status;for(let i=0;i<50;i++){await new Promise(r=>setTimeout(r,50));status=await control(w,'api');if(status.status==='running')break;}
 assert.equal(status.status,'running');
 const s=JSON.parse(readFileSync(join(w.dir,'state/api.json'),'utf8'));
 assert.equal((await fetch(`http://127.0.0.1:${s.controlPort}/stop`,{method:'POST'})).status,403);
 assert.equal((await control(w,'api')).status,'running');
 await control(w,'api',true);await exit;
 assert.notEqual((await control(w,'api')).status,'running');
});
