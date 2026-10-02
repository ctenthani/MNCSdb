// Authenticated association exchange. Tokens are body-only and are never logged.
export const handler=async event=>{
 const headers={'Content-Type':'application/json','Cache-Control':'no-store'};
 const reply=(status,data)=>({statusCode:status,headers,body:JSON.stringify(data)});
 if(event.httpMethod!=='POST')return reply(405,{error:'Use POST.'});
 if(event.isBase64Encoded||Buffer.byteLength(event.body||'')>70000)return reply(413,{error:'Message too large.'});
 let body;try{body=JSON.parse(event.body||'');}catch{return reply(400,{error:'Invalid JSON.'});}
 if(!/^[a-f0-9-]{36}$/i.test(body.connectorId||'')||!/^[a-f0-9]{64}$/i.test(body.token||'')||!['send','receipts'].includes(body.action))return reply(400,{error:'Invalid integration request.'});
 const url=process.env.SUPABASE_URL?.trim().replace(/\/$/,''),key=process.env.SUPABASE_SECRET_KEY?.trim();
 if(!url||!key)return reply(503,{error:'The MNCS integration service is not configured.'});
 try{
 const name=body.action==='send'?'receive_association_message':'integration_receipts';
 const args={connector:body.connectorId,secret:body.token};if(body.action==='send')args.message=body.message;
 const r=await fetch(url+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:key,...(key.startsWith('sb_secret_')?{}:{Authorization:'Bearer '+key}),'Content-Type':'application/json'},body:JSON.stringify(args),signal:AbortSignal.timeout(15000)});
 const data=await r.json();
 if(!r.ok){const message=String(data.message||'The integration could not be completed.');return reply(/credentials invalid/.test(message)?401:/Revision conflict|with council/.test(message)?409:400,{error:message});}
 return reply(200,{data});
 }catch{return reply(502,{error:'MNCS could not complete this exchange. Retry the same message safely.'});}
};
