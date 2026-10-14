// Read-only federation of published statistics. Arbitrary URLs are never fetched.
const source='https://dartsmw.netlify.app';
const tessamRpc='https://grjpabbgwxvkvgskyjit.supabase.co/rest/v1/rpc/mncs_public_statistics';
// Existing browser-safe publishable key. This is not a secret or service-role credential.
const tessamPublicKey='sb_publishable_FaSNXYGXEb3G0mxAJfTyMQ_ZkvY8ORd';
const cache=new Map();
export function tessamSummaries(data,now){
 if(data?.source!=='https://tessamims.netlify.app'||!Array.isArray(data.summaries)||data.summaries.length>200)throw Error('Invalid TESSAM feed.');
 return data.summaries.map(r=>{if(!/^[a-f0-9-]{36}$/i.test(r.competitionId)||!/^\d{4}$/.test(String(r.year))||typeof r.competitionName!=='string'||r.competitionName.length>200)throw Error('Invalid competition metadata.');for(const key of ['teams','athletes','fixtures','completedFixtures'])if(!Number.isSafeInteger(r[key])||r[key]<0||r[key]>10000000)throw Error('Invalid aggregate count.');if(r.completedFixtures>r.fixtures)throw Error('Invalid completion count.');return {associationId:'RESEARCH-28',year:String(r.year),sourceUrl:'https://tessamims.netlify.app',updatedAt:new Date(now).toISOString(),automatic:true,stale:false,payload:{competitionName:r.competitionName,competitionId:r.competitionId,teams:r.teams,athletes:r.athletes,fixtures:r.fixtures,completedFixtures:r.completedFixtures,missingResults:r.fixtures-r.completedFixtures,rankingRule:'Registrar-certified athletes and GS-approved team-sport results. Counts only; no student identities or provisional scores. Association totals do not certify MNCS affiliation.',leaders:[]}};});
}
async function tessam(fetcher,now){
 const previous=cache.get('tessam');try{let rows=previous&&now-previous.checked<60000?previous.rows:null;if(!rows){const r=await fetcher(tessamRpc,{method:'POST',headers:{apikey:tessamPublicKey,'Content-Type':'application/json'},body:'{}',redirect:'error',signal:AbortSignal.timeout(10000)});if(!r.ok)throw Error();rows=tessamSummaries(await r.json(),now);cache.set('tessam',{checked:now,rows});}return {summaries:rows,sources:[{associationId:'RESEARCH-28',status:'current',checkedAt:rows[0]?.updatedAt||new Date(now).toISOString()}]};}catch{return {summaries:previous&&now-previous.checked<86400000?previous.rows.map(r=>({...r,stale:true})):[],sources:[{associationId:'RESEARCH-28',status:'unavailable',message:'TESSAM feed is unavailable or invalid; any older summary is not current.'}]};}
}
export function summarise(region,bundle,competition){
 const year=String(bundle.season?.year||2026);
 if(year!==String(competition.period))throw Error('The association records belong to another season.');
 if(!bundle.results||typeof bundle.results!=='object'||!Array.isArray(bundle.fixtures)||!bundle.players||typeof bundle.players!=='object')throw Error('The association returned an incomplete stats feed.');
 const fixtures=bundle.fixtures.filter(f=>f.h!=='BYE'&&f.a!=='BYE'),ids=new Set(fixtures.map(f=>f.id));
 const completed=Object.entries(bundle.results).filter(([id,r])=>ids.has(id)&&r.h!==''&&r.a!==''&&r.h!=null&&r.a!=null&&Number.isInteger(Number(r.h))&&Number.isInteger(Number(r.a))&&Number(r.h)!==Number(r.a)).length;
 const roster=Object.values(bundle.players);if(roster.some(list=>!Array.isArray(list)))throw Error('The association roster is invalid.');
 return {associationId:competition.association_id,year,sourceUrl:source,payload:{competitionName:competition.published_payload?.name||competition.payload?.name||region.toUpperCase()+' League',region,teams:roster.length,athletes:roster.reduce((n,list)=>n+list.length,0),fixtures:fixtures.length,completedFixtures:completed,missingResults:Math.max(0,fixtures.length-completed),rankingRule:'Published regional league fixtures and registered athletes. Counts only; no private profiles or combined rankings.',leaders:[]}};
}
export async function collect(fetcher=fetch,env=process.env,now=Date.now()){
 const url=env.SUPABASE_URL?.trim().replace(/\/$/,''),key=env.SUPABASE_SECRET_KEY?.trim();
 if(!url||!key)throw Error('Automatic association statistics are not configured.');
 const headers={apikey:key,...(key.startsWith('sb_secret_')?{}:{Authorization:'Bearer '+key})};
 const read=async path=>{const r=await fetcher(url+'/rest/v1/'+path,{headers,signal:AbortSignal.timeout(10000)});if(!r.ok)throw Error('Association connections could not be checked.');return r.json();};
 const [connectors,competitions]=await Promise.all([read('association_connectors?select=id,association_id,site_url,enabled'),read('association_exchange?select=association_id,external_id,period,payload,published_payload,status&kind=eq.Competition&status=eq.Approved')]);
 const summaries=[],sources=[];let tessamAllowed=true;
 for(const connector of connectors){
  let origin;try{const u=new URL(connector.site_url);origin=u.origin;if(u.username||u.password)origin='';}catch{}
  if(origin==='https://tessamims.netlify.app'){if(connector.enabled===false)tessamAllowed=false;continue;}
  if(connector.enabled===false){sources.push({associationId:connector.association_id,status:'paused',message:'Association stats connection is paused.'});continue;}
  if(origin!==source){sources.push({associationId:connector.association_id,status:'unsupported',message:'This association needs a supported public stats feed.'});continue;}
  await Promise.all(['srdl','crdl','nrdl'].map(async region=>{
   const competition=competitions.find(c=>c.association_id===connector.association_id&&c.external_id==='comp-national-'+region+'-'+c.period);
   if(!competition){sources.push({associationId:connector.association_id,region,status:'awaiting-approval',message:'A council-approved competition is required.'});return;}
   const cacheKey=connector.id+':'+region+':'+competition.period,previous=cache.get(cacheKey);
   try{
    let row=previous&&now-previous.checked<60000?previous.row:null;
    if(!row){const response=await fetcher(source+'/.netlify/functions/results?region='+region,{redirect:'error',signal:AbortSignal.timeout(10000)});if(!response.ok)throw Error('The association stats feed is unavailable.');const text=await response.text();if(text.length>2000000)throw Error('The association feed is too large.');row=summarise(region,JSON.parse(text),competition);row.updatedAt=new Date(now).toISOString();cache.set(cacheKey,{checked:now,row});}
    summaries.push({...row,automatic:true,stale:false});sources.push({associationId:connector.association_id,region,status:'current',checkedAt:row.updatedAt});
   }catch{if(previous&&now-previous.checked<86400000)summaries.push({...previous.row,automatic:true,stale:true});sources.push({associationId:connector.association_id,region,status:'unavailable',message:'Source unavailable or invalid. Showing any last verified summary; do not treat it as current.'});}
  }));
 }
 const tertiary=tessamAllowed?await tessam(fetcher,now):{summaries:[],sources:[{associationId:'RESEARCH-28',status:'paused',message:'TESSAM stats connection is paused.'}]};return {summaries:[...summaries,...tertiary.summaries],sources:[...sources,...tertiary.sources],checkedAt:new Date(now).toISOString(),refreshSeconds:300};
}
export const handler=async event=>{const headers={'Content-Type':'application/json','Cache-Control':'no-store'};if(event.httpMethod!=='GET')return {statusCode:405,headers,body:JSON.stringify({error:'Use GET.'})};try{return {statusCode:200,headers,body:JSON.stringify(await collect())};}catch{return {statusCode:503,headers,body:JSON.stringify({error:'Automatic association stats are temporarily unavailable. Saved summaries remain available.'})};}};
