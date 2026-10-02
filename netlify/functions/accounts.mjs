import { timingSafeEqual, randomUUID } from 'node:crypto';
export function equalSecret(a,b){const x=Buffer.from(a||''),y=Buffer.from(b||'');return x.length===y.length&&x.length>=32&&timingSafeEqual(x,y);}
export function validateAccount(body){
 if(!body || typeof body!=='object')throw Error('Invalid request.');
 const email=String(body.email||'').trim().toLowerCase();
 const password=typeof body.password==='string'?body.password:'';
 const display_name=String(body.display_name||'').trim();
 if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)||email.length>254)throw Error('Enter a valid email.');
 if(password.length<12||password.length>128)throw Error('Use a password between 12 and 128 characters.');
 if(!display_name||display_name.length>120)throw Error('Enter a name of up to 120 characters.');
 const role=body.action==='bootstrap'?'admin':body.role;
 if(!['admin','reviewer','association','judge','auditor'].includes(role))throw Error('Invalid account role.');
 const association_id=role==='association'?String(body.association_id||''):null;
 if(role==='association'&&!/^[A-Za-z0-9_-]{1,80}$/.test(association_id))throw Error('Select a registered association.');
 return {email,password,display_name,role,association_id};
}
export function canonicalOrigin(value){
 try{const url=new URL(String(value||'').trim());return ['https:','http:'].includes(url.protocol)&&!url.username&&!url.password&&url.pathname==='/'&&!url.search&&!url.hash?url.origin:null;}catch{return null;}
}
export function originAllowed(origin,env=process.env){
 const requested=canonicalOrigin(origin);if(!requested)return false;
 // Exact trusted origins only: never derive authority from Host headers.
 const configured=String(env.SITE_ORIGIN||'').split(',');
 const trusted=[...configured,env.URL].map(canonicalOrigin).filter(Boolean);
 return trusted.includes(requested);
}
export const handler=async(event)=>{
 const headers={'Content-Type':'application/json','Cache-Control':'no-store'};
 const result=(code,message,extra={})=>({statusCode:code,headers,body:JSON.stringify({message,...extra})});
 if(event.httpMethod==='GET'){const missing=['SUPABASE_URL','SUPABASE_SECRET_KEY'].filter(name=>!process.env[name]?.trim());if(![process.env.SITE_ORIGIN,process.env.URL].some(canonicalOrigin))missing.push('SITE_ORIGIN');return result(missing.length?503:200,missing.length?'Account service setup incomplete.':'Account service settings present.',{ready:missing.length===0,missing});}
 if(event.httpMethod!=='POST')return result(405,'Use GET for status or POST for account operations.');
 const requestHeaders=Object.fromEntries(Object.entries(event.headers||{}).map(([key,value])=>[key.toLowerCase(),value]));
 if(!originAllowed(requestHeaders.origin))return result(403,'Request origin is not authorised. Set Netlify SITE_ORIGIN to the exact site URL (https://mncsdb.netlify.app), enable its Functions scope, and redeploy.');
 const base=process.env.SUPABASE_URL?.trim().replace(/\/$/,''),secret=process.env.SUPABASE_SECRET_KEY?.trim();
 if(!base||!secret)return result(503,'Account service needs '+[!base?'SUPABASE_URL':null,!secret?'SUPABASE_SECRET_KEY':null].filter(Boolean).join(' and ')+'. Add the missing private settings in Netlify Functions and redeploy.');
 if((event.body||'').length>16000)return result(413,'Request too large.');
 let body;try{body=JSON.parse(event.body);}catch{return result(400,'Invalid request.');}
 const api=async(path,method='GET',data)=>{
  const response=await fetch(base+path,{method,headers:{apikey:secret,...(secret.startsWith('sb_secret_')?{}:{Authorization:`Bearer ${secret}`}),'Content-Type':'application/json'},body:data===undefined?undefined:JSON.stringify(data),signal:AbortSignal.timeout(15000)});
  const text=await response.text();let value;try{value=text?JSON.parse(text):null;}catch{value=null;}
  if(!response.ok){
   const error=new Error('Account operation failed.');
   error.status=response.status;error.code=value?.code;error.path=path;
   throw error;
  }
  return value;
 };
 let claim=null,createdId=null,completed=false;
 try{
  if(body.action==='bootstrap'){
   const account=validateAccount(body);
   if(!equalSecret(body.setup_code,process.env.MNCS_SETUP_CODE))return result(403,'Initial setup code is invalid or disabled.');
   claim=randomUUID();
   if(!await api('/rest/v1/rpc/claim_initial_admin','POST',{operation_id:claim}))return result(409,'Initial MNCS setup is already completed or in progress.');
   const auth=await api('/auth/v1/admin/users','POST',{email:account.email,password:account.password,email_confirm:true});
   createdId=auth.id;
   if(!createdId)throw Error('Account creation did not return a user ID.');
   await api('/rest/v1/rpc/complete_initial_admin','POST',{operation_id:claim,user_id:createdId,user_email:account.email,user_name:account.display_name});
   completed=true;return result(201,'Initial MNCS administrator created. Sign in with your chosen email and password.');
  }
  // Validate the session with Auth, then check its immutable server-side profile.
  const token=(requestHeaders.authorization||'').replace(/^Bearer /i,'');
  if(!token)return result(401,'Sign in as an MNCS administrator.');
  const authResponse=await fetch(base+'/auth/v1/user',{headers:{apikey:secret,Authorization:`Bearer ${token}`},signal:AbortSignal.timeout(15000)});
  if(!authResponse.ok)return result(401,'Your session expired. Sign in again.');
  const caller=await authResponse.json();
  const profiles=await api('/rest/v1/profiles?id=eq.'+encodeURIComponent(caller.id)+'&select=role');
  if(profiles?.[0]?.role!=='admin')return result(403,'Only MNCS administrators can manage accounts.');
  if(body.action==='reset-password'){
   const targetId=String(body.user_id||'');
   if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(targetId))return result(400,'Select an existing user.');
   if(typeof body.password!=='string'||body.password.length<12||body.password.length>128)return result(400,'Use a password between 12 and 128 characters.');
   const target=await api('/rest/v1/profiles?id=eq.'+encodeURIComponent(targetId)+'&select=id');
   if(!target.length)return result(404,'That user has no managed MNCS profile.');
   await api('/auth/v1/admin/users/'+encodeURIComponent(targetId),'PUT',{password:body.password});
   return result(200,'Password reset. Give the new password privately to this user. Existing sessions may remain valid until their tokens expire.');
  }
  if(body.action==='create-association'){
   const id=String(body.id||'').trim(),name=String(body.name||'').trim(),sport=String(body.sport||'').trim(),shortName=String(body.shortName||'').trim();
   if(!/^[A-Za-z0-9_-]{1,80}$/.test(id)||!name||name.length>160||!sport||sport.length>100||!shortName||shortName.length>40)return result(400,'Enter valid association details and a unique ID using letters, numbers, underscores or hyphens.');
   await api('/rest/v1/registry','POST',{collection:'associations',id,payload:{id,name,sport,shortName,status:'Under Review',verificationStatus:'Awaiting verification',strategicPlan:false}});
   return result(201,'Association registered. You can now create its accounts.');
  }
  if(body.action!=='create-account')return result(400,'Unknown account action.');
  const account=validateAccount(body);
  if(account.association_id){const rows=await api('/rest/v1/registry?collection=eq.associations&id=eq.'+encodeURIComponent(account.association_id)+'&select=id');if(!rows.length)return result(400,'Register the association first.');}
  const auth=await api('/auth/v1/admin/users','POST',{email:account.email,password:account.password,email_confirm:true});createdId=auth.id;
  if(!createdId)throw Error('Account creation did not return a user ID.');
  await api('/rest/v1/profiles','POST',{id:createdId,role:account.role,association_id:account.association_id,email:account.email,display_name:account.display_name});
  completed=true;return result(201,'Account created. The user can now sign in.');
 }catch(error){
  // Compensate only the newly created user; never delete an existing account.
  if(createdId&&!completed){try{await api('/auth/v1/admin/users/'+encodeURIComponent(createdId),'DELETE');}catch{return result(503,'Account provisioning was interrupted. An administrator must inspect Auth and profiles before retrying.');}}
  if(claim&&!completed){try{await api('/rest/v1/rpc/release_initial_admin','POST',{operation_id:claim});}catch{return result(503,'Initial setup was interrupted. An administrator must inspect the setup claim before retrying.');}}
  if(body.action==='create-association'){
   if(error.code==='23505')return result(409,'That association ID is already registered. Choose another ID or use the existing association.');
   if(error.status===401||error.status===403)return result(503,'Association service cannot access the database. The site owner must check the Netlify SUPABASE_SECRET_KEY and redeploy.');
   if(error.code==='42P01'||error.code==='PGRST205')return result(503,'The registry table is unavailable. Run supabase/INSTALL_ALL.sql in the connected Supabase project.');
   return result(503,'Association registration could not be completed. Check the Netlify function settings and logs, then retry.');
  }
  if(error.status===401||error.status===403)return result(503,'Account service credentials are not authorised. Check the private SUPABASE_SECRET_KEY in Netlify Functions and redeploy.');
  if(error.path?.startsWith('/auth/v1/admin/users')&&[400,422].includes(error.status))return result(400,'Supabase rejected the account change. Check whether the email already exists and whether the password meets your project password policy.');
  return result(400,error.message?.startsWith('Enter')||error.message?.startsWith('Use')||error.message?.startsWith('Select')||error.message?.startsWith('Invalid')?error.message:'Account operation failed. Check configuration and whether this email already exists.');
 }
};
