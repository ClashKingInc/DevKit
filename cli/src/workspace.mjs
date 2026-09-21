import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve, join, dirname } from 'node:path';
import { randomBytes } from 'node:crypto';
import { parseEnv } from 'node:util';

export const repositoryNames = {devkit:'clashking_schemas',api:'clashking_api',bot:'clashking_bot',dashboard:'ClashKingDashboard',app:'ClashKingApp',proxy:'ClashKingProxy',tracking:'clashking_tracking'};
export const secretNames=['DATA_ENCRYPTION_KEY','JWT_ACCESS_SECRET','JWT_REFRESH_SECRET','API_BOT_TOKEN','AI_USAGE_SECRET','STRIPE_WEBHOOK_SECRET'];
export function findWorkspace(start=process.cwd()) {
 if(process.env.CLASHKING_WORKSPACE)return resolve(process.env.CLASHKING_WORKSPACE);
 for(let dir=resolve(start);;dir=dirname(dir)){if(existsSync(join(dir,'.clashking','workspace.json')))return dir;if(dirname(dir)===dir)throw Error('No workspace found. Run clashking init <folder> or set CLASHKING_WORKSPACE.');}
}
export function writePrivate(path,contents,exclusive=false){writeFileSync(path,contents,{mode:0o600,...(exclusive?{flag:'wx'}:{})});}
export function encodeEnv(values){return Object.entries(values).map(([k,v])=>{if(!/^[A-Z][A-Z0-9_]*$/.test(k)||/[\r\n"]/.test(String(v)))throw Error(`Unsupported env value for ${k}`);return `${k}="${String(v)}"`;}).join('\n')+'\n';}
export function initWorkspace(root,repositories={}) {
 root=resolve(root);const dir=join(root,'.clashking');mkdirSync(dir,{recursive:true,mode:0o700});
 for(const name of ['state','datasets','backups'])mkdirSync(join(dir,name),{recursive:true,mode:0o700});
 const configPath=join(dir,'workspace.json'),envPath=join(dir,'local.env');
 if(!existsSync(configPath))writePrivate(configPath,JSON.stringify({version:1,repositories:Object.fromEntries(Object.entries(repositoryNames).map(([key,name])=>[key,resolve(repositories[key]??join(root,name))])),database:{container:'clashking-timescale',port:54330,name:'clashking_dev'},ports:{api:8787,bot:8788,dashboard:3002,app:7357,proxy:8011},services:['proxy','api','gateway','bot','dashboard','tunnel'],tunnelConfig:''},null,2),true);
 if(!existsSync(envPath)){
  const env={TIMESCALE_HOST:'127.0.0.1',TIMESCALE_PORT:'54330',TIMESCALE_DATABASE:'clashking_dev',TIMESCALE_USERNAME:'clashking_local',TIMESCALE_PASSWORD:'clashking_local',TIMESCALE_SSLMODE:'disable',VALKEY_HOST:'127.0.0.1',VALKEY_PORT:'6379',VALKEY_PASSWORD:'',DISCORD_CLIENT_ID:'',DISCORD_CLIENT_SECRET:'',DISCORD_BOT_TOKEN:'',DISCORD_PUBLIC_KEY:'',DISCORD_GUILD_ALLOWLIST:'',COC_KEYS:'',CLASHKING_API_ORIGIN:'http://127.0.0.1:8787',CLASHKING_DASHBOARD_ORIGIN:'http://localhost:3002',DATASET_KEY_FILE:''};
  env.DATASET_DECRYPTION_KEY='';env.DATASET_R2_BUCKET='clashking-bucket';env.R2_ENDPOINT='';
  for(const name of secretNames)env[name]=randomBytes(32).toString('base64url');
  writePrivate(envPath,'# Local-only source of truth. Never commit or share this file.\n'+encodeEnv(env),true);
 }
 if(!existsSync(join(root,'.gitignore')))writeFileSync(join(root,'.gitignore'),'.clashking/\n');
 return loadWorkspace(root);
}
export function loadWorkspace(root=findWorkspace()){
 root=resolve(root);const dir=join(root,'.clashking'),config=JSON.parse(readFileSync(join(dir,'workspace.json'),'utf8')),env=parseEnv(readFileSync(join(dir,'local.env'),'utf8'));
 if(config.version!==1)throw Error('Unsupported workspace version');
 if(env.TIMESCALE_HOST!=='127.0.0.1'||env.TIMESCALE_DATABASE!=='clashking_dev'||env.TIMESCALE_USERNAME!=='clashking_local'||env.TIMESCALE_PASSWORD!=='clashking_local')throw Error('Only the loopback clashking_dev database with local development credentials is supported');
 if(String(config.database.port)!==env.TIMESCALE_PORT||config.database.name!==env.TIMESCALE_DATABASE||!(config.database.container==='clashking-timescale'||/^clashking-rewrite-api-[a-z0-9-]+$/.test(config.database.container)))throw Error('Database config does not match local.env');
 for(const name of ['CLASHKING_API_ORIGIN','CLASHKING_DASHBOARD_ORIGIN']){
  const url=new URL(env[name]);if(url.origin!==env[name]||url.username||url.password||!['http:','https:'].includes(url.protocol)||['api.clashk.ing','v2-api.clashk.ing','dash.clashk.ing','staging-api.clashk.ing'].includes(url.hostname))throw Error(`${name} must be a local development origin, never production/staging`);
 }
 if(env.DISCORD_CLIENT_ID==='824653933347209227')throw Error('Production Discord application is forbidden in this workspace');
 return {root,dir,config,env};
}
export function inheritedEnvironment(){const keep=['PATH','Path','HOME','USERPROFILE','SYSTEMROOT','SystemRoot','WINDIR','COMSPEC','ComSpec','PATHEXT','TEMP','TMP','TMPDIR','SHELL','LANG','TERM','SSH_AUTH_SOCK'];return Object.fromEntries(keep.filter(k=>process.env[k]!==undefined).map(k=>[k,process.env[k]]));}
export function requireValues(env,names){for(const name of names)if(!env[name])throw Error(`Set ${name} in .clashking/local.env`);}
