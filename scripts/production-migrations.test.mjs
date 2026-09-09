import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import test from 'node:test';

const script = resolve('scripts/apply-production-migrations.sh');
const sha = 'a'.repeat(40);
function run(overrides = {}) {
 const dir = mkdtempSync(join(tmpdir(), 'devkit-production-test-'));
 const log = join(dir, 'calls');
 const mock = `#!${process.execPath}
const fs=require('node:fs'),path=require('node:path');const tool=path.basename(process.argv[1]),args=process.argv.slice(2);
if(tool==='git') { console.log('${sha}');process.exit(0); }
fs.appendFileSync(process.env.LOG, JSON.stringify({args,dsn:process.env.GOOSE_DBSTRING})+'\\n');
if(args[0]==='-version') console.log('goose version: v3.26.0');
else if(args.includes('version')) console.error('goose: version '+(fs.existsSync(process.env.LOG+'.applied')?'7':(process.env.BEFORE_VERSION||'6')));
else if(args.includes('up-to')) { if(process.env.FAIL_UP)process.exit(1);fs.writeFileSync(process.env.LOG+'.applied','yes'); }
`;
 for(const tool of ['git','goose'])writeFileSync(join(dir,tool),mock,{mode:0o755});
 const result=spawnSync('bash',[script],{encoding:'utf8',env:{...process.env,PATH:`${dir}:${process.env.PATH}`,LOG:log,GITHUB_ACTIONS:'true',GITHUB_REPOSITORY:'ClashKingInc/DevKit',GITHUB_REF:'refs/heads/main',GITHUB_EVENT_NAME:'workflow_dispatch',EXPECTED_SHA:sha,CONFIRMATION:'apply-006-to-007',PRODUCTION_DATABASE_URL:'private-test-secret',GOOSE_DBSTRING:'wrong-inherited-secret',...overrides}});
 let calls=[];try{calls=readFileSync(log,'utf8').trim().split('\n').map(JSON.parse)}catch{}
 rmSync(dir,{recursive:true,force:true});return {...result,calls};
}
test('applies exact target using environment credential, never command arguments',()=>{
 const r=run();assert.equal(r.status,0,r.stderr);
 const up=r.calls.find(c=>c.args.includes('up-to'));assert.deepEqual(up.args.slice(-2),['up-to','7']);assert.equal(up.dsn,'private-test-secret');
 assert.ok(r.calls.every(c=>!c.args.join(' ').includes('secret')));assert.ok(!r.stdout.includes('secret'));
});
test('refuses wrong baseline, replay, ref, event, repository, commit and confirmation',()=>{
 for(const overrides of [{BEFORE_VERSION:'0'},{BEFORE_VERSION:'7'},{BEFORE_VERSION:'28'},{GITHUB_REF:'refs/heads/test'},{GITHUB_EVENT_NAME:'pull_request'},{GITHUB_REPOSITORY:'elsewhere/repo'},{EXPECTED_SHA:'b'.repeat(40)},{CONFIRMATION:'yes'}]){
 const r=run(overrides);assert.notEqual(r.status,0);assert.ok(!r.calls.some(c=>c.args.includes('up-to')));
 }
});
test('migration failure cannot report success',()=>{
 const r=run({FAIL_UP:'1'});assert.notEqual(r.status,0);assert.ok(!r.stdout.includes('Applied Goose'));
});
