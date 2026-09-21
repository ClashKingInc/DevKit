import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync,readFileSync,writeFileSync,rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { initWorkspace,loadWorkspace,encodeEnv } from '../src/workspace.mjs';
import { serviceDefinition } from '../src/services.mjs';
function fixture(t){const dir=mkdtempSync(join(tmpdir(),'clashking-cli-test-'));t.after(()=>rmSync(dir,{recursive:true,force:true}));return initWorkspace(dir);}
test('init is non-destructive and creates one secret source',t=>{const w=fixture(t),file=join(w.dir,'local.env'),before=readFileSync(file,'utf8');initWorkspace(w.root);assert.equal(readFileSync(file,'utf8'),before);assert.equal(w.env.DATA_ENCRYPTION_KEY.length,43);});
test('remote databases and production Discord apps are rejected',t=>{const w=fixture(t),file=join(w.dir,'local.env');writeFileSync(file,encodeEnv({...w.env,TIMESCALE_HOST:'prod.example.com'}));assert.throws(()=>loadWorkspace(w.root));writeFileSync(file,encodeEnv({...w.env,DISCORD_CLIENT_ID:'824653933347209227'}));assert.throws(()=>loadWorkspace(w.root));});
test('frontend definitions never inherit application secrets',t=>{const w=fixture(t);w.env.DISCORD_CLIENT_SECRET='secret';w.env.DISCORD_CLIENT_ID='123';const d=serviceDefinition(w,'dashboard');for(const key of ['DISCORD_CLIENT_SECRET','TIMESCALE_PASSWORD','API_BOT_TOKEN','JWT_ACCESS_SECRET'])assert.equal(d.env[key],undefined);assert.equal(d.env.VITE_CLASHKING_API_ORIGIN,w.env.CLASHKING_API_ORIGIN);});
test('only gateway is available from tracking',t=>{const w=fixture(t);w.env.DISCORD_BOT_TOKEN='test';const d=serviceDefinition(w,'gateway');assert.deepEqual(d.args,['run','.','--script','discord-gateway']);assert.equal(d.env.TIMESCALE_HOST,'127.0.0.1');assert.throws(()=>serviceDefinition(w,'scheduled'));assert.throws(()=>serviceDefinition(w,'war-archiver'));});
test('API receives local proxy and explicit stable key mapping',t=>{const w=fixture(t);w.env.DISCORD_CLIENT_ID='123';w.env.DISCORD_CLIENT_SECRET='test';const d=serviceDefinition(w,'api');assert.equal(d.env.CLASHKING_LOCAL_CLASH_PROXY_ORIGIN,'http://127.0.0.1:8011');assert.equal(d.env.CLASHKING_LOCAL_JWT_ACCESS_SECRET,w.env.JWT_ACCESS_SECRET);assert.equal(d.env.CLASHKING_LOCAL_ARCHIVE_BRIDGE,'0');});
test('env encoding refuses injected lines',()=>{assert.throws(()=>encodeEnv({TOKEN:'hello\nOTHER=bad'}));});
