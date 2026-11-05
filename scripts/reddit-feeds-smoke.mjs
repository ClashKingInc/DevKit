// Exercise the real repair CLI with disposable SQL and a loopback Discord API.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
const exec=promisify(execFile),dsn=process.env.TEST_DATABASE_URL;
assert.equal(process.env.CLASHKING_DISPOSABLE_TIMESCALE,'1');
assert.match(dsn??'',/^postgres:\/\/clashking_test:clashking_test@127\.0\.0\.1:\d+\/clashking_test\?sslmode=disable$/u);
const sql=async q=>(await exec('psql',[dsn,'-X','-v','ON_ERROR_STOP=1','-At','-c',q])).stdout.trim();
const guild='999999999999996001',app='999999999999996002',parent='999999999999996003',thread='999999999999996004',role='999999999999996005',hookID='999999999999996006';
const hook={id:hookID,type:1,guild_id:guild,channel_id:parent,application_id:app};
let creates=0,available=true,hasHook=true;
const provider=createServer((req,res)=>{
 res.setHeader('content-type','application/json');
 const send=(v,status=200)=>{res.statusCode=status;res.end(JSON.stringify(v));};
 if(req.url==='/users/@me')return send({id:app});
 if(req.url===`/channels/${thread}`)return available?send({id:thread,type:11,guild_id:guild,parent_id:parent}):send({},404);
 if(req.url===`/channels/${parent}`)return send({id:parent,type:15,guild_id:guild});
 if(req.url===`/webhooks/${hookID}`)return send(hook);
 if(req.url===`/channels/${parent}/webhooks`){if(req.method==='POST'){creates++;hasHook=true;return send(hook);}return send(hasHook?[hook]:[]);}
 send({message:'unexpected request'},500);
});
await new Promise(r=>provider.listen(0,'127.0.0.1',r));
const temp=await mkdtemp(join(tmpdir(),'ck-reddit-repair-'));
try{
 const binary=join(temp,'repair'),source=join(temp,'source.json'),working=join(temp,'workspace','database');
 await mkdir(join(working,'timescale'),{recursive:true});
 await writeFile(join(temp,'workspace','.env'),'');await writeFile(join(working,'timescale','001_initial_stats.sql'),'');
 await writeFile(source,JSON.stringify([{server_id:guild,destination_id:thread,role_id:role,accounts:['Recruiter','r/legacy-value']} ]));
 await sql(`INSERT INTO servers(id,name) VALUES('${guild}','Reddit repair')`);
 await exec('go',['build','-o',binary,'migrations/reddit_feeds.go'],{cwd:resolve('database')});
 const env={...process.env,TIMESCALE_URL:dsn,BOT_TOKEN:'fixture',REDDIT_DISCORD_API_URL:`http://127.0.0.1:${provider.address().port}`,REDDIT_EXPECTED_APPLICATION_ID:app,REDDIT_FEEDS_SOURCE:source,REDDIT_FEEDS_APPLY:'0'};
 const run=extra=>exec(binary,[],{cwd:working,env:{...env,...extra}});
 assert.match((await run()).stdout,/apply=false scanned=1 total=1/u);assert.equal(creates,0);assert.equal(await sql(`SELECT count(*) FROM server_logs WHERE server_id='${guild}'`),'0');
 await run({REDDIT_FEEDS_APPLY:'1'});
 assert.equal(await sql(`SELECT webhook_id||':'||thread_id||':'||reddit_role_id||':'||reddit_accounts[1] FROM server_logs WHERE server_id='${guild}'`),`${hookID}:${thread}:${role}:Recruiter`);
 await run({REDDIT_FEEDS_APPLY:'1'});assert.equal(creates,0);
 assert.equal(await sql(`SELECT reddit_accounts[2] FROM server_logs WHERE server_id='${guild}'`),'r/legacy-value');
 await sql(`UPDATE server_logs SET reddit_accounts=ARRAY['Newer'] WHERE server_id='${guild}'`);
 assert.match((await run({REDDIT_FEEDS_APPLY:'1'})).stdout,/conflicts=1/u);assert.equal(await sql(`SELECT reddit_accounts[1] FROM server_logs WHERE server_id='${guild}'`),'Newer');
 await sql(`DELETE FROM server_logs WHERE server_id='${guild}'`);available=false;
 assert.match((await run({REDDIT_FEEDS_APPLY:'1'})).stdout,/unavailable=1/u);assert.equal(creates,0);
 available=true;hasHook=false;await run({REDDIT_FEEDS_APPLY:'1'});await run({REDDIT_FEEDS_APPLY:'1'});assert.equal(creates,1);
 await assert.rejects(run({REDDIT_EXPECTED_APPLICATION_ID:'999999999999996099'}));
 console.log('PASS actual Reddit repair: preview has no writes, forum/shared hook reuse, role/accounts preserved, newer SQL conflict retained, unavailable skipped, repeat creates none, app identity checked');
}finally{await new Promise(r=>provider.close(r));await rm(temp,{recursive:true,force:true});}
