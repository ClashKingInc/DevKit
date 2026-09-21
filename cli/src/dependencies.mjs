import { execFileSync } from 'node:child_process';
import { databaseCommand } from './database.mjs';
export async function ensureDependencies(w){
 const docker=args=>execFileSync('docker',args,{encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();
 docker(['info','--format','{{.ServerVersion}}']);
 await databaseCommand(w,'db',['init']);
 const name='clashking-valkey';
 if(w.env.VALKEY_HOST!=='127.0.0.1'||w.env.VALKEY_PORT!=='6379'||w.env.VALKEY_PASSWORD)throw Error('Managed Valkey requires 127.0.0.1:6379 with no password');
 if(docker(['ps','-aq','--filter',`name=^/${name}$`])){
  const item=JSON.parse(docker(['inspect',name]))[0],ports=item.HostConfig.PortBindings?.['6379/tcp'];
  if(item.Config.Image!=='valkey/valkey:8-alpine'||ports?.length!==1||ports[0].HostIp!=='127.0.0.1'||ports[0].HostPort!=='6379')throw Error('Existing clashking-valkey is not the expected local cache');
  if(!item.State.Running)docker(['start',name]);
 }else docker(['run','-d','--name',name,'--restart','unless-stopped','-p','127.0.0.1:6379:6379','valkey/valkey:8-alpine']);
 for(let i=0;i<30;i++){try{if(docker(['exec',name,'valkey-cli','ping'])==='PONG')return;}catch{}await new Promise(r=>setTimeout(r,200));}
 throw Error('Local Valkey did not become ready');
}
