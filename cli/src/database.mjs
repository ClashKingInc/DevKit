import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, chmodSync, renameSync, writeFileSync,createReadStream,unlinkSync } from 'node:fs';
import { dirname,join,resolve } from 'node:path';
import { randomBytes, createHash } from 'node:crypto';
import { Transform, Writable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { inheritedEnvironment } from './workspace.mjs';

function finished(c){return new Promise((res,rej)=>{c.once('error',rej);c.once('close',code=>code===0?res():rej(Error(`Subprocess exited ${code}`)));});}
async function run(command,args,env=inheritedEnvironment()){const c=spawn(command,args,{env,stdio:'inherit'});await finished(c);}
async function capture(command,args){const c=spawn(command,args,{env:inheritedEnvironment(),stdio:['ignore','pipe','inherit']});let output='';c.stdout.on('data',b=>output+=b);await finished(c);return output.trim();}
export async function databaseCommand(w,command,args){
 const action=args[0],c=w.config.database,repo=w.config.repositories;
 const sql=statement=>run('docker',['exec',c.container,'psql','-X','-v','ON_ERROR_STOP=1','-U','clashking_local','-d',c.name,'-c',statement]);
 if(command==='db'&&['init','migrate'].includes(action)){
  await run(process.execPath,[join(repo.api,'scripts/local-api-database.mjs'),'migrate'],{...inheritedEnvironment(),CLASHKING_LOCAL_DB_CONTAINER:c.container,...(c.volume?{CLASHKING_LOCAL_DB_VOLUME:c.volume}:{}),CLASHKING_LOCAL_DB_PORT:String(c.port),CLASHKING_LOCAL_SCHEMA_ROOT:repo.devkit});
  await sql("SELECT alter_job(job_id,scheduled=>false) FROM timescaledb_information.jobs WHERE proc_name <> 'policy_telemetry'");return;
 }
 if(command==='db'&&action==='refresh-views'){
  for(const view of ['clan_leaderboards','townhall_counts','war_league_counts','api_global_counts','api_league_tier_counts','player_townhall_leaderboards','player_league_leaderboards'])await sql(`REFRESH MATERIALIZED VIEW ${view}`);
  await sql("CALL refresh_continuous_aggregate('townhall_stats_daily',NULL::timestamptz,NULL::timestamptz)");return;
 }
 const isBackup=command==='db'&&action==='backup',isImport=command==='data'&&action==='import';
 if(!isBackup&&!isImport)throw Error('Expected db init|migrate|refresh-views|backup, or data import');
 const file=args[1]&&!args[1].startsWith('--')?resolve(args[1]):null,keyArgument=args.indexOf('--key');
 if(keyArgument>=0&&(!args[keyArgument+1]||args[keyArgument+1].startsWith('--')))throw Error('--key requires a key file path');
 let key=keyArgument>=0?resolve(args[keyArgument+1]):w.env.DATASET_KEY_FILE;
 if(keyArgument<0&&w.env.DATASET_DECRYPTION_KEY){
  if(/[\r\n]/.test(w.env.DATASET_DECRYPTION_KEY))throw Error('Dataset key must be a single line');
  key=join(w.dir,'state','dataset.key');writeFileSync(key,w.env.DATASET_DECRYPTION_KEY+'\n',{mode:0o600});chmodSync(key,0o600);
 }
 if(!file||!key)throw Error('Provide an archive path and --key /path/to/key-file (or DATASET_KEY_FILE)');
 const gpgHome=join(w.dir,'state','gpg');mkdirSync(gpgHome,{recursive:true,mode:0o700});
 const gpgArgs=['--homedir',gpgHome,'--batch','--pinentry-mode','loopback','--no-symkey-cache','--passphrase-file',key];
 if(isBackup){
  if(existsSync(file)||existsSync(file+'.partial'))throw Error('Output exists; refusing to overwrite it');
  mkdirSync(dirname(file),{recursive:true,mode:0o700});
  if(!existsSync(key)){mkdirSync(dirname(key),{recursive:true,mode:0o700});writeFileSync(key,randomBytes(32).toString('hex')+'\n',{flag:'wx',mode:0o600});}
  const dump=spawn('docker',['exec',c.container,'pg_dump','-U','clashking_local','-d',c.name,'--format=custom','--compress=zstd:3','--no-owner','--no-acl'],{stdio:['ignore','pipe','inherit'],env:inheritedEnvironment()});
  const encrypt=spawn('gpg',[...gpgArgs,'--symmetric','--cipher-algo','AES256','--compress-algo','none','--output',file+'.partial'],{stdio:['pipe','ignore','inherit'],env:inheritedEnvironment()});
  const hash=createHash('sha256'),tap=new Transform({transform(chunk,encoding,callback){hash.update(chunk);callback(null,chunk);}});
  try{await Promise.all([finished(dump),finished(encrypt),pipeline(dump.stdout,tap,encrypt.stdin)]);}catch(e){dump.kill();encrypt.kill();throw e;}
  const verify=createHash('sha256'),decrypt=spawn('gpg',[...gpgArgs,'--decrypt',file+'.partial'],{stdio:['ignore','pipe','inherit'],env:inheritedEnvironment()});
  await Promise.all([finished(decrypt),pipeline(decrypt.stdout,new Writable({write(chunk,encoding,callback){verify.update(chunk);callback();}}))]);
  if(hash.digest('hex')!==verify.digest('hex'))throw Error('Backup decryption verification failed');
  chmodSync(file+'.partial',0o600);renameSync(file+'.partial',file);console.log(`Encrypted compressed backup: ${file}\nKeep the separate key safe: ${key}`);return;
 }
 if(!existsSync(file)||!existsSync(key))throw Error('Archive or key file does not exist');
 // Never write decrypted SQL directly into the active database. Authentication
 // is checked to EOF before pg_restore is allowed to consume the local file.
 const suffix=Date.now().toString(),target=`clashking_import_${suffix}`,previous=`clashking_before_${suffix}`;
 const admin=q=>capture('docker',['exec',c.container,'psql','-XAt','-v','ON_ERROR_STOP=1','-U','clashking_local','-d','postgres','-c',q]);
 const active=await admin("SELECT count(*) FROM pg_database WHERE datname='clashking_dev'");
 if(active!=='0'&&!args.includes('--replace'))throw Error('clashking_dev already exists. Back it up, stop local services, then pass --replace to replace it.');
 const temp=join(w.dir,'state',`restore-${suffix}.dump`);
 await run('gpg',[...gpgArgs,'--output',temp,'--decrypt',file]);chmodSync(temp,0o600);
 await run('docker',['exec',c.container,'createdb','-U','clashking_local',target]);
 const targetSQL=q=>run('docker',['exec',c.container,'psql','-X','-v','ON_ERROR_STOP=1','-U','clashking_local','-d',target,'-c',q]);
 try{
  await targetSQL('CREATE EXTENSION IF NOT EXISTS timescaledb; SELECT timescaledb_pre_restore();');
  const restore=spawn('docker',['exec','-i',c.container,'pg_restore','-U','clashking_local','-d',target,'--exit-on-error','--no-owner','--no-acl'],{env:inheritedEnvironment(),stdio:['pipe','inherit','inherit']});
  await Promise.all([finished(restore),pipeline(createReadStream(temp),restore.stdin)]);
  await targetSQL("SELECT timescaledb_post_restore(); SELECT alter_job(job_id,scheduled=>false) FROM timescaledb_information.jobs WHERE proc_name <> 'policy_telemetry'; SELECT max(version_id) FROM goose_db_version WHERE is_applied;");
  const users=await admin("SELECT count(*) FROM pg_stat_activity WHERE datname='clashking_dev' AND backend_type='client backend'");
  if(users!=='0')throw Error(`Stop local clients before activation. Verified import retained as ${target}.`);
  if(active!=='0'){
   await admin('ALTER DATABASE clashking_dev ALLOW_CONNECTIONS false');
   await admin("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='clashking_dev'");
   await admin(`ALTER DATABASE clashking_dev RENAME TO ${previous}`);
  }
  try{
   await admin(`ALTER DATABASE ${target} ALLOW_CONNECTIONS false`);
   await admin(`SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${target}'`);
   await admin(`ALTER DATABASE ${target} RENAME TO clashking_dev`);
   await admin('ALTER DATABASE clashking_dev ALLOW_CONNECTIONS true');
  }catch(e){
   const promoted=await admin(`SELECT count(*) FROM pg_database WHERE datname='${target}'`);
   if(promoted==='0'){
    await admin('ALTER DATABASE clashking_dev ALLOW_CONNECTIONS false');
    await admin("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='clashking_dev'");
    await admin(`ALTER DATABASE clashking_dev RENAME TO ${target}`);
   }
   if(active!=='0'){await admin(`ALTER DATABASE ${previous} RENAME TO clashking_dev`);await admin('ALTER DATABASE clashking_dev ALLOW_CONNECTIONS true');}
   throw e;
  }
  console.log(`Imported and activated clashking_dev.${active!=='0'?` Previous database retained as ${previous}; remove it explicitly after checking your data.`:''}`);
  unlinkSync(temp);
 }catch(e){throw Error(`${e.message}\nImport artifacts retained for inspection; decrypted file: ${temp}`);}
}
