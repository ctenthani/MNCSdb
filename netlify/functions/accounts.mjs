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
 if(!['admin','reviewer','association'].includes(role))throw Error('Invalid account role.');
 const association_id=role==='association'?String(body.association_id||''):null;
 if(role==='association'&&!/^[A-Za-z0-9_-]{1,80}$/.test(association_id))throw Error('Select a registered association.');
 return {email,password,display_name,role,association_id};
}
export const handler=async(event)=>{
 const headers={'Content-Type':'application/json','Cache-Control':'no-store'};
 const result=(code,message,extra={})=>({statusCode:code,headers,body:JSON.stringify({message,...extra})});
 if(event.httpMethod!=='POST')return result(405,'Use POST.');
 const allowedOrigin=process.env.SITE_ORIGIN;
 const origin=event.headers.origin;
 if(!allowedOrigin||origin!==allowedOrigin)return result(403,'Request origin is not authorised.');
 const base=process.env.SUPABASE_URL,secret=process.env.SUPABASE_SECRET_KEY;
 if(!base||!secret)return result(503,'Account service needs server configuration.');
 if((event.body||'').length>16000)return result(413,'Request too large.');
 let body;try{body=JSON.parse(event.body);}catch{return result(400,'Invalid request.');}
 const api=async(path,method='GET',data)=>{
  const response=await fetch(base+path,{method,headers:{apikey:secret,Authorization:`Bearer ${secret}`,'Content-Type':'application/json'},body:data===undefined?undefined:JSON.stringify(data),signal:AbortSignal.timeout(15000)});
  const text=await response.text();let value;try{value=text?JSON.parse(text):null;}catch{value=null;}
  if(!response.ok)throw Error('Account operation failed. Check server configuration or whether that email is already registered.');
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
  const token=(event.headers.authorization||'').replace(/^Bearer /i,'');
  if(!token)return result(401,'Sign in as an MNCS administrator.');
  const authResponse=await fetch(base+'/auth/v1/user',{headers:{apikey:secret,Authorization:`Bearer ${token}`},signal:AbortSignal.timeout(15000)});
  if(!authResponse.ok)return result(401,'Your session expired. Sign in again.');
  const caller=await authResponse.json();
  const profiles=await api('/rest/v1/profiles?id=eq.'+encodeURIComponent(caller.id)+'&select=role');
  if(profiles?.[0]?.role!=='admin')return result(403,'Only MNCS administrators can manage accounts.');
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
  return result(400,error.message?.startsWith('Enter')||error.message?.startsWith('Use')||error.message?.startsWith('Select')||error.message?.startsWith('Invalid')?error.message:'Account operation failed. Check configuration and whether this email already exists.');
 }
};
