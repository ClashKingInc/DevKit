// Inventory/copy public legacy Bunny assets to local staging only. This command
// has no upload, delete, R2, or CDN mutation path.
import {createRequire} from 'node:module'
import {createHash} from 'node:crypto'
import {readFileSync,writeFileSync,mkdirSync,existsSync} from 'node:fs'
import {resolve,dirname,sep} from 'node:path'

const args=process.argv.slice(2)
const option=name=>{const i=args.indexOf(name);return i<0?undefined:args[i+1]}
const limit=Number(option('--limit')??100)
if(!Number.isInteger(limit)||limit<1||limit>1000)throw Error('--limit must be1..1000')
const output=option('--output'),manifest=option('--manifest'),report=option('--report')
const root=output?resolve(output):undefined
let sources=[]
if(manifest){const input=JSON.parse(readFileSync(manifest,'utf8'));sources=Array.isArray(input)?input:input.items;}
else{
 const dsn=process.env.CLASHKING_LOCAL_DATABASE_URL
 if(!dsn||!['127.0.0.1','localhost','[::1]'].includes(new URL(dsn).hostname))throw Error('Provide --manifest or an explicit loopback database URL')
 if(!process.env.CLASHKING_API_REPO)throw Error('CLASHKING_API_REPO is required for local DB inventory')
 const{Client}=createRequire(resolve(process.env.CLASHKING_API_REPO,'package.json'))('pg')
 const client=new Client({connectionString:dsn});await client.connect()
 try{
  await client.query('BEGIN READ ONLY')
  await client.query("SET LOCAL statement_timeout='10s'")
  const rows=(await client.query(`SELECT channel_id,thread_id FROM tickets WHERE channel_id>$1 ORDER BY channel_id LIMIT $2`,[option('--after')??'',limit])).rows
  sources=rows.flatMap(row=>[row.channel_id,row.thread_id].filter(Boolean).map(id=>({sourceUrl:`https://cdn.clashk.ing/transcript-${id}.html`})))
  await client.query('ROLLBACK')
 }finally{await client.end()}
}
if(!Array.isArray(sources))throw Error('Manifest must contain an array of {sourceUrl}')
const queue=[...new Map(sources.map(item=>[item.sourceUrl,item])).values()].slice(0,limit)
const known=new Set(queue.map(item=>item.sourceUrl)),items=[]
for(let index=0;index<queue.length&&index<limit;index++){
 const sourceUrl=queue[index].sourceUrl
 try{
  const url=new URL(sourceUrl)
  if(url.origin!=='https://cdn.clashk.ing'||url.username||url.password||url.hash)throw Error('Only exact public legacy CDN URLs are allowed')
  const transcript=/^\/transcript-(\d{15,20})\.html$/.exec(url.pathname)
  const attachment=/^\/transcripts\/(\d{15,20})\/([^/]+)$/.exec(url.pathname)
  if(!transcript&&!attachment&&!/^\/[A-Za-z0-9_-]+\.png$/.test(url.pathname))throw Error('URL is outside documented legacy ticket/PNG paths')
  const objectKey=transcript?`legacy/tickets/transcripts/${transcript[1]}.html`:attachment?`legacy/tickets/attachments/${attachment[1]}/${encodeURIComponent(decodeURIComponent(attachment[2]))}`:`legacy/tickets/images/${createHash('sha256').update(sourceUrl).digest('hex')}.png`
  const path=root?resolve(root,objectKey):undefined
  if(path&&!path.startsWith(root+sep))throw Error('Unsafe output path')
  if(path&&existsSync(path)&&existsSync(path+'.source.json')){
   const previous=JSON.parse(readFileSync(path+'.source.json','utf8'))
   const bytes=readFileSync(path),sha256=createHash('sha256').update(bytes).digest('hex')
   if(previous.sourceUrl===sourceUrl&&previous.sha256===sha256){items.push({...previous,status:'already_staged'});continue}
   throw Error('Existing staged file does not match its source receipt; refusing overwrite')
  }
  const response=await fetch(url,{method:root?'GET':'HEAD',redirect:'error',signal:AbortSignal.timeout(15000)})
  if(!response.ok)throw Error(`source returned${response.status}`)
  if(!root){items.push({sourceUrl,objectKey,status:'available',contentLength:response.headers.get('content-length')});continue}
  const chunks=[];let size=0
  for await(const chunk of response.body){size+=chunk.length;if(size>20*1024*1024)throw Error('Asset exceeds20MiB staging limit');chunks.push(chunk)}
  const bytes=Buffer.concat(chunks),sha256=createHash('sha256').update(bytes).digest('hex')
  const metadata={sourceUrl,objectKey,sha256,bytes:size,contentType:response.headers.get('content-type')}
  mkdirSync(dirname(path),{recursive:true})
  if(existsSync(path)){
   if(createHash('sha256').update(readFileSync(path)).digest('hex')!==sha256)throw Error('Existing incomplete staged file differs from source; refusing overwrite')
  }else writeFileSync(path,bytes,{flag:'wx'})
  writeFileSync(path+'.source.json',JSON.stringify(metadata,null,2)+'\n',{flag:'wx'})
  items.push({...metadata,status:'staged'})
  if(transcript){for(const match of bytes.toString('utf8').matchAll(/https:\/\/cdn\.clashk\.ing\/transcripts\/[^\s"'<>]+/gu)){
   if(!known.has(match[0])&&queue.length<limit){known.add(match[0]);queue.push({sourceUrl:match[0]})}
  }}
 }catch(error){items.push({sourceUrl,status:'failed',error:error.message})}
}
const result={mode:root?'local_staging':'read_only_inventory',items,failed:items.filter(item=>item.status==='failed').length}
if(report)writeFileSync(resolve(report),JSON.stringify(result,null,2)+'\n')
console.log(JSON.stringify(result,null,2))
if(result.failed)process.exitCode=1
