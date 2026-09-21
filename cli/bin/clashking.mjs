#!/usr/bin/env node
import { spawn,spawnSync } from 'node:child_process';
import { existsSync,readFileSync } from 'node:fs';
import { join,resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { initWorkspace,loadWorkspace,inheritedEnvironment } from '../src/workspace.mjs';
import { serviceDefinition } from '../src/services.mjs';
import { control } from '../src/supervisor.mjs';
import { databaseCommand } from '../src/database.mjs';
import { ensureDependencies } from '../src/dependencies.mjs';
import { pullDataset } from '../src/dataset.mjs';

const [command,...args]=process.argv.slice(2);
process.umask(0o077);
const help=`clashking init <folder> [--repo name=/existing/checkout ...]
clashking doctor | status | logs <service>
clashking run <proxy|api|gateway|bot|dashboard|app|tunnel>
clashking up [service ...] | down [service ...]
clashking bot sync-commands
clashking repos clone
clashking app start|restart|reload|stop|status|logs|attach
clashking data pull [--replace]
All commands use .clashking/local.env. No production deployments or tracking collectors.`;
const execute=d=>new Promise((res,rej)=>{const child=spawn(d.command,d.args,{cwd:d.cwd,env:d.env,stdio:'inherit'});for(const signal of ['SIGINT','SIGTERM'])process.once(signal,()=>child.kill(signal));child.once('error',rej);child.once('exit',code=>code===0?res():rej(Error(`Command exited ${code}`)));});
async function main(){
 if(!command||['help','--help','-h'].includes(command)){console.log(help);return;}
 if(command==='init'){
  if(!args[0])throw Error('Provide a workspace folder');const repos={};for(let i=1;i<args.length;i+=2){if(args[i]!=='--repo'||!args[i+1]?.includes('='))throw Error('Use --repo name=/path');const at=args[i+1].indexOf('=');repos[args[i+1].slice(0,at)]=resolve(args[i+1].slice(at+1));}
  const w=initWorkspace(args[0],repos);console.log(`Workspace: ${w.root}\nEdit: ${join(w.dir,'local.env')}\nExisting files were preserved.`);return;
 }
 const w=loadWorkspace();
 if(command==='app'){
  const action=args[0]??'start';if(!['start','restart','reload','stop','status','logs','attach'].includes(action))throw Error('Unknown App command');
  const d=serviceDefinition(w,'app');d.args=[join(w.config.repositories.app,'tooling/dev-app'),action,...(action==='start'?[w.config.repositories.app]:[])];await execute(d);return;
 }
 if(command==='data'&&args[0]==='pull'){
  if(!args.includes('--replace'))throw Error('This replaces local data. Stop services, then run clashking data pull --replace');
  if(!w.env.DATASET_DECRYPTION_KEY)throw Error('Set DATASET_DECRYPTION_KEY in .clashking/local.env');
  for(const name of new Set(w.config.services))if((await control(w,name)).status==='running')throw Error('Run clashking down before replacing local data');
  const file=await pullDataset(w);await ensureDependencies(w);await databaseCommand(w,'data',['import',file,'--replace']);return;
 }
 if(command==='repos'&&args[0]==='clone'){
  const repos={devkit:'DevKit',api:'ClashKingAPI',bot:'ClashKingBot',dashboard:'ClashKingDashboard',app:'ClashKingApp',proxy:'ClashKingProxy',tracking:'ClashKingTracking'};
  for(const [name,remote]of Object.entries(repos)){
   const path=w.config.repositories[name];if(existsSync(path)){console.log(`Preserved existing ${name}: ${path}`);continue;}
   await execute({command:'git',args:['clone',`https://github.com/ClashKingInc/${remote}.git`,path],cwd:w.root,env:inheritedEnvironment()});
  }return;
 }
 if(command==='doctor'){
  let failed=false;for(const tool of ['node','git','docker','go','goose','gpg','cloudflared']){const r=spawnSync(tool,tool==='go'?['version']:tool==='docker'?['info','--format','{{.ServerVersion}}']:['--version'],{encoding:'utf8',env:inheritedEnvironment()});const okay=!r.error&&r.status===0;console.log(`${okay?'OK':'UNAVAILABLE'} ${tool}`);if(!okay)failed=true;}
  if(Number(process.versions.node.split('.')[0])<26)console.log('WARNING: CLI supports this Node version, but Dashboard declares Node >=26.1.0');
  for(const [name,path]of Object.entries(w.config.repositories)){const okay=existsSync(join(path,'.git'));console.log(`${okay?'OK':'MISSING'} ${name}: ${path}`);if(!okay)failed=true;}
  for(const key of ['DISCORD_CLIENT_ID','DISCORD_CLIENT_SECRET','DISCORD_BOT_TOKEN','DISCORD_PUBLIC_KEY','COC_KEYS']){console.log(`${w.env[key]?'SET':'MISSING'} ${key}`);if(!w.env[key])failed=true;}
  console.log(`Database: 127.0.0.1:${w.env.TIMESCALE_PORT}/${w.env.TIMESCALE_DATABASE}\nAPI: ${w.env.CLASHKING_API_ORIGIN}\nDashboard: ${w.env.CLASHKING_DASHBOARD_ORIGIN}`);
  console.log('App uses its repository process manager (bash/tmux; Windows requires WSL). No trackers are started.');if(failed)process.exitCode=1;return;
 }
 if(command==='run'){const d=serviceDefinition(w,args[0]);await execute(d);return;}
 if(command==='logs'){if(!/^[a-z]+$/.test(args[0]??''))throw Error('Provide a service name');const file=join(w.dir,'state',`${args[0]}.log`);console.log(existsSync(file)?readFileSync(file,'utf8').split('\n').slice(-100).join('\n'):'No managed log yet');return;}
 if(command==='status'||command==='down'){const names=new Set(args.length?args:[...w.config.services,'tunnel']);for(const name of names)console.log(JSON.stringify(await control(w,name,command==='down')));return;}
 if(command==='up'){
  const names=args.length?args:w.config.services;for(const name of names)serviceDefinition(w,name);
  await ensureDependencies(w);
  for(const name of names){if((await control(w,name)).status==='running'){console.log(`${name}: already running`);continue;}
   const child=spawn(process.execPath,[fileURLToPath(new URL('../src/supervisor.mjs',import.meta.url)),w.root,name],{stdio:'ignore',detached:true,env:inheritedEnvironment()});await new Promise((res,rej)=>{child.once('spawn',res);child.once('error',rej);});child.unref();
   let status;for(let attempt=0;attempt<30;attempt++){await new Promise(r=>setTimeout(r,100));status=await control(w,name);if(status.status==='running'||status.status==='failed')break;}console.log(JSON.stringify(status));if(status.status!=='running')throw Error(`${name} failed to start; inspect clashking logs ${name}`);
  }return;
 }
 if(command==='db'||command==='data'){await databaseCommand(w,command,args);return;}
 if(command==='bot'&&args[0]==='sync-commands'){
  if(!w.env.DISCORD_CLIENT_ID||!w.env.DISCORD_BOT_TOKEN)throw Error('Configure the development Discord application first');
  const r=w.config.repositories.bot;await execute({command:process.execPath,args:[join(r,'worker/node_modules/tsx/dist/cli.mjs'),join(r,'worker/scripts/register-commands.ts'),'dev'],cwd:join(r,'worker'),env:{...inheritedEnvironment(),DISCORD_APPLICATION_ID:w.env.DISCORD_CLIENT_ID,DISCORD_BOT_TOKEN:w.env.DISCORD_BOT_TOKEN}});return;
 }
 throw Error(`Unknown command.\n${help}`);
}
main().catch(e=>{console.error(`clashking: ${e.message}`);process.exitCode=1;});
