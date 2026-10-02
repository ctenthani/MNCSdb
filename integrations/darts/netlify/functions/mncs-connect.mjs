import {leagueSummary} from '../../lib/mncs-adapter.mjs';
// Install alongside the existing results function; that function remains unchanged.
const SITE='https://dartsmw.netlify.app',GATEWAY='https://mncsdb.netlify.app/.netlify/functions/association-gateway';
export const handler=async event=>{
 const headers={'Content-Type':'application/json','Cache-Control':'no-store'};const reply=(status,data)=>({statusCode:status,headers,body:JSON.stringify(data)});
 if(event.httpMethod!=='POST')return reply(405,{error:'Use POST.'});
 if(event.headers?.origin!==SITE)return reply(403,{error:'Use the Darts Malawi site.'});
 if(event.isBase64Encoded||Buffer.byteLength(event.body||'')>64000)return reply(413,{error:'Message too large.'});
 let body;try{body=JSON.parse(event.body||'');}catch{return reply(400,{error:'Invalid JSON.'});}
 if(!['srdl','crdl','nrdl'].includes(body.region)||typeof body.password!=='string'||!body.password||!['receipts','send','preview'].includes(body.action))return reply(400,{error:'Sign in as the committee and select a regional league.'});
 const connectorId=process.env.MNCS_CONNECTOR_ID,token=process.env.MNCS_CONNECTOR_TOKEN;
 if(!connectorId||!token)return reply(503,{error:'Ask the site owner to configure the MNCS connector.'});
 const call=async(url,payload)=>{const r=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload),signal:AbortSignal.timeout(15000)});const d=await r.json();if(!r.ok)throw Object.assign(Error(d.error||'The service rejected this exchange.'),{status:r.status});return d;};
 try{
 // Recheck the existing server authority; a client-side isAdmin flag is insufficient.
 const auth=await call(SITE+'/.netlify/functions/results',{action:'login',region:body.region,password:body.password});
 if(auth.role!=='admin'&&auth.siteAdmin!==true)return reply(403,{error:'A verified site administrator is required for national submissions.'});
 if(auth.region&&auth.region!==body.region&&!auth.siteAdmin&&auth.role!=='admin')return reply(403,{error:'League authority mismatch.'});
 const receipts=async()=> (await call(GATEWAY,{action:'receipts',connectorId,token})).data;
 if(body.action==='receipts')return reply(200,{data:await receipts()});
 let message=body.message;
 if(!message||typeof message!=='object')return reply(400,{error:'Choose a competition, report or nomination.'});
 if(message.kind==='Performance summary'){
  if(String(message.period)!=='2026')return reply(400,{error:'This pilot reads the current 2026 league. Connect a season-specific source before sharing another year.'});
  const r=await fetch(SITE+'/.netlify/functions/results?region='+body.region,{signal:AbortSignal.timeout(15000)});if(!r.ok)throw Error('Published league data is unavailable; nothing was shared.');
  const data=await r.json();if(!data.results||typeof data.results!=='object')throw Error('Published results are unavailable.');
  message={...message,payload:{...leagueSummary(data,Number(body.fixtureCount)||0,body.shareNames===true),competitionExternalId:message.payload?.competitionExternalId}};
 }
 if(body.action==='preview')return reply(200,{data:message.payload});
 const prior=(await receipts()).find(r=>r.externalId===message.externalId&&r.kind===message.kind);message={...message,revision:(prior?.revision||0)+1};
 const response=await call(GATEWAY,{action:'send',connectorId,token,message});return reply(200,response);
 }catch(error){return reply([400,401,403,409].includes(error.status)?error.status:502,{error:error.message||'Exchange failed. Try again.'});}
};
