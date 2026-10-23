import { join } from 'node:path';
import { mkdirSync, readFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { inheritedEnvironment,secretNames,requireValues,encodeEnv,writePrivate,clashProxyOrigin } from './workspace.mjs';

export function serviceDefinition(workspace,name){
 const {config:c,env:e,dir}=workspace,r=c.repositories,p=c.ports;
 const base=inheritedEnvironment();
 const select=keys=>Object.fromEntries(keys.map(k=>[k,e[k]??'']));
 const node=(script,args=[],cwd=r.devkit,env={})=>({command:process.execPath,args:[script,...args],cwd,env:{...base,...env}});
 if(name==='proxy'){requireValues(e,['COC_KEYS']);return {command:'go',args:['run','.'],cwd:r.proxy,env:{...base,COC_KEYS:e.COC_KEYS,HOST:'127.0.0.1',PORT:String(p.proxy),DEV_COC_URL:''}};}
 if(name==='api'){
  requireValues(e,[...secretNames,'DISCORD_CLIENT_ID','DISCORD_CLIENT_SECRET']);
  return node(join(r.api,'scripts/start-local-rewrite-api.mjs'),[],r.api,{
   CLASHKING_LOCAL_ADMIN_IDENTITY:c.localAdmin===true?'1':'0',
   CLASHKING_LOCAL_DISCORD_PUBLIC_KEY:e.DISCORD_PUBLIC_KEY,
   CLASHKING_LOCAL_FCM_CREDENTIALS_FILE:c.localPushCredentialsFile??'',
   // Seed unpublished JSONs into local R2 instead of the public cache. No asset host
   // or production bucket write is needed; restart API after regenerating files.
   CLASHKING_LOCAL_STATIC_ASSETS_ROOT:c.localStaticAssetsRoot??'',
   CLASHKING_PERSISTENT_LOCAL_API:'1',CLASHKING_LOCAL_DATABASE_URL:`postgres://clashking_local:clashking_local@127.0.0.1:${e.TIMESCALE_PORT}/clashking_dev?sslmode=disable`,CLASHKING_LOCAL_API_PORT:String(p.api),CLASHKING_LOCAL_LAN_IP:'127.0.0.1',CLASHKING_LOCAL_PUBLIC_ORIGIN:e.CLASHKING_API_ORIGIN,CLASHKING_LOCAL_DASHBOARD_ORIGIN:e.CLASHKING_DASHBOARD_ORIGIN,CLASHKING_LOCAL_CUSTOM_ORIGINS:'1',CLASHKING_LOCAL_DISCORD_CLIENT_ID:e.DISCORD_CLIENT_ID,CLASHKING_LOCAL_DISCORD_CLIENT_SECRET:e.DISCORD_CLIENT_SECRET,CLASHKING_LOCAL_DISCORD_BOT_TOKEN:e.DISCORD_BOT_TOKEN,CLASHKING_LOCAL_CLASH_PROXY_ORIGIN:clashProxyOrigin(workspace),CLASHKING_LOCAL_ARCHIVE_BRIDGE:'0',CLASHKING_LOCAL_SCHEMA_ROOT:r.devkit,CLASHKING_LOCAL_STORAGE_ROOT:join(dir,'state','api'),CLASHKING_LOCAL_PRODUCTION_READS:'1',...Object.fromEntries(secretNames.map(k=>[`CLASHKING_LOCAL_${k}`,e[k]]))});
 }
 if(name==='gateway'){
  requireValues(e,['DISCORD_BOT_TOKEN']);
  return {command:'go',args:['run','.','--script','discord-gateway'],cwd:r.tracking,env:{...base,...select(['TIMESCALE_HOST','TIMESCALE_PORT','TIMESCALE_DATABASE','TIMESCALE_USERNAME','TIMESCALE_PASSWORD','TIMESCALE_SSLMODE','VALKEY_HOST','VALKEY_PORT','VALKEY_PASSWORD','DISCORD_BOT_TOKEN','DISCORD_GUILD_ALLOWLIST']),SCRIPT_NAME:'discord-gateway',BOT_TOKEN:'',TIMESCALE_URL:'',VALKEY_URL:'',DISCORD_MESSAGE_CREATE_ENABLED:'false'}};
 }
 if(name==='bot'){
  requireValues(e,['DISCORD_CLIENT_ID','DISCORD_BOT_TOKEN','DISCORD_PUBLIC_KEY','API_BOT_TOKEN']);
  const envPath=join(dir,'state','bot.env');mkdirSync(join(dir,'state'),{recursive:true,mode:0o700});
  writePrivate(envPath,encodeEnv({DISCORD_APPLICATION_ID:e.DISCORD_CLIENT_ID,DISCORD_BOT_TOKEN:e.DISCORD_BOT_TOKEN,DISCORD_PUBLIC_KEY:e.DISCORD_PUBLIC_KEY,CLASHKING_API_TOKEN:e.API_BOT_TOKEN,CLASHKING_API_BASE_URL:`http://127.0.0.1:${p.api}`,APP_ENV:'dev',LOCAL_TEST_USER_ID:'',...(e.CLASHOFSTATS_USER_AGENT?{CLASHOFSTATS_USER_AGENT:e.CLASHOFSTATS_USER_AGENT}:{})}));
  return node(join(r.bot,'worker/node_modules/wrangler/bin/wrangler.js'),['dev','--local','--config','wrangler.local.jsonc','--env-file',envPath,'--port',String(p.bot),'--persist-to',join(dir,'state','bot')],join(r.bot,'worker'));
 }
 if(name==='dashboard')return node(join(r.dashboard,'node_modules/vite/bin/vite.js'),['--host','127.0.0.1','--port',String(p.dashboard)],r.dashboard,{VITE_CLASHKING_API_ORIGIN:e.CLASHKING_API_ORIGIN,VITE_CLASHKING_AI_ORIGIN:e.CLASHKING_AI_ORIGIN??(new URL(e.CLASHKING_DASHBOARD_ORIGIN).hostname==='localhost'?`http://localhost:${p.assistant??8789}`:'https://local-ai.clashk.ing'),VITE_DISCORD_CLIENT_ID:e.DISCORD_CLIENT_ID,CLASHKING_LOCAL_DASHBOARD_HOST:new URL(e.CLASHKING_DASHBOARD_ORIGIN).hostname});
 if(name==='assistant'){
  requireValues(e,['AI_USAGE_SECRET']);
  const secrets=parseEnv(readFileSync(join(r.dashboard,'.dev.vars'),'utf8'));
  requireValues(secrets,['OPENAI_API_KEY']);
  const envPath=join(dir,'state','assistant.env');mkdirSync(join(dir,'state'),{recursive:true,mode:0o700});
  writePrivate(envPath,encodeEnv({OPENAI_API_KEY:secrets.OPENAI_API_KEY,AI_USAGE_SECRET:e.AI_USAGE_SECRET}));
  return node(join(r.dashboard,'scripts/start-local-roster-assistant.mjs'),[],r.dashboard,{
   CLASHKING_API_ORIGIN:`http://127.0.0.1:${p.api}`,CLASHKING_ASSISTANT_PORT:String(p.assistant??8789),CLASHKING_ASSISTANT_ENV_FILE:envPath});
 }
 if(name==='app')return {command:'bash',args:[join(r.app,'tooling/dev-app'),'start',r.app],cwd:r.app,env:{...base,DEV_APP_API_ORIGIN:e.CLASHKING_API_ORIGIN,DEV_APP_DISCORD_CLIENT_ID:e.DISCORD_CLIENT_ID,DEV_APP_HOST:'lan'},externalManager:true};
 if(name==='tunnel'){
  if(!c.tunnelConfig)throw Error('Set tunnelConfig in .clashking/workspace.json; see CONTRIBUTING.md');
  return {command:'cloudflared',args:['tunnel','--config',c.tunnelConfig,'run'],cwd:workspace.root,env:base};
 }
 throw Error(`Unknown service ${name}; only proxy, api, gateway, bot, dashboard, assistant, app, tunnel are allowed`);
}
