import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync, openSync, closeSync, existsSync, readFileSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { loadWorkspace } from './workspace.mjs';
import { serviceDefinition } from './services.mjs';

export async function control(workspace,name,stop=false){
 if(!/^[a-z]+$/.test(name))throw Error('Invalid service');
 const file=join(workspace.dir,'state',`${name}.json`);if(!existsSync(file))return {service:name,status:'stopped'};
 const state=JSON.parse(readFileSync(file,'utf8'));
 try{const r=await fetch(`http://127.0.0.1:${state.controlPort}/${stop?'stop':'status'}`,{method:stop?'POST':'GET',headers:{Authorization:`Bearer ${state.token}`},signal:AbortSignal.timeout(2000)});if(!r.ok)throw Error('Control request rejected');const body=await r.json();if(body.service!==name||body.workspace!==workspace.root)throw Error('Supervisor ownership mismatch');return body;}
 catch{return {service:name,status:'stale',message:'No authenticated supervisor; no process was killed'};}
}
export async function supervise(root,name){
 const w=loadWorkspace(root),d=serviceDefinition(w,name);if(d.externalManager)throw Error('Use clashking run app; the App repository owns its existing process manager');
 const existing=await control(w,name);if(existing.status==='running')throw Error(`${name} is already running`);
 const token=randomBytes(32).toString('hex'),file=join(w.dir,'state',`${name}.json`),log=join(w.dir,'state',`${name}.log`);
 mkdirSync(join(w.dir,'state'),{recursive:true,mode:0o700});const fd=openSync(log,'a',0o600);
 const child=spawn(d.command,d.args,{cwd:d.cwd,env:d.env,stdio:['ignore',fd,fd],detached:process.platform!=='win32',windowsHide:true});closeSync(fd);
 let status='running',exitCode=null,stopping=false;
 const stop=()=>{if(stopping)return;stopping=true;if(status==='running'){
   if(process.platform==='win32')spawn('taskkill',['/pid',String(child.pid),'/T','/F'],{stdio:'ignore'});
   else try{process.kill(-child.pid,'SIGTERM');}catch{}
  }else server.close(()=>process.exit(0));};
 const server=createServer((req,res)=>{if(req.headers.authorization!==`Bearer ${token}`){res.writeHead(403);return res.end();}res.setHeader('Content-Type','application/json');res.end(JSON.stringify({service:name,workspace:w.root,status,pid:child.pid,exitCode,log}));if(req.method==='POST'&&req.url==='/stop')stop();});
 child.on('error',()=>{status='failed';exitCode=1;});child.on('exit',code=>{status=code===0?'stopped':'failed';exitCode=code;if(stopping)server.close(()=>process.exit(code??0));});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 writeFileSync(file,JSON.stringify({service:name,workspace:w.root,controlPort:server.address().port,token}),{mode:0o600});
 process.on('SIGINT',stop);process.on('SIGTERM',stop);
 process.on('exit',()=>{try{if(JSON.parse(readFileSync(file,'utf8')).token===token)unlinkSync(file);}catch{}});
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)supervise(process.argv[2],process.argv[3]).catch(e=>{console.error(e.message);process.exitCode=1;});
