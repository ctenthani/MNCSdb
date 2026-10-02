// Isolated, in-memory simulator. No Supabase or account-service calls.
(() => {
const tables={registry:[],profiles:[],submissions:[],reporting_requirements:[],award_cycles:[]};
const users=[['admin','admin@mncs.example','admin',null],['reviewer','reviewer@mncs.example','reviewer',null],['association','association@mncs.example','association','DEMO-ASSOC']].map(([id,email,role,association_id])=>({id,email,password:'1234',role,association_id,display_name:'Demo '+role}));
tables.profiles=users.map(({password,...p})=>p);
tables.registry=[{collection:'associations',id:'DEMO-ASSOC',payload:{id:'DEMO-ASSOC',name:'Demonstration Sports Association',shortName:'DEMO',sport:'Demonstration',status:'Under Review'}}];
let session=null;const files=new Map();
const ready=fetch('data/researched-associations.json').then(r=>r.json()).then(records=>tables.registry.push(...records.map(payload=>({collection:'associations',id:payload.id,payload}))));
const current=()=>tables.profiles.find(p=>p.id===session?.user.id);
const error=message=>({data:null,error:{message}});
const ok=data=>({data,error:null});
function accessible(table,row){const p=current();if(table==='registry'||table==='award_cycles')return true;if(!p)return false;if(table==='profiles')return p.role==='admin'||p.id===row.id;return ['admin','reviewer'].includes(p.role)||row.association_id===p.association_id;}
function query(table){let filters=[],operation='select',values=null,single=false;
 const q={select(){return q;},eq(key,value){filters.push(r=>r[key]===value);return q;},contains(key,value){filters.push(r=>Object.entries(value).every(([k,v])=>r[key]?.[k]===v));return q;},order(){return q;},maybeSingle(){single=true;return q;},insert(data){operation='insert';values=data;return q;},upsert(data){operation='upsert';values=data;return q;},then(resolve,reject){return execute().then(resolve,reject);}};
 async function execute(){await ready;if(!tables[table])return error('Unknown demo table');
  if(operation==='select'){const data=tables[table].filter(r=>accessible(table,r)&&filters.every(f=>f(r)));return ok(single?data[0]||null:data);}
  const p=current();if(!p)return error('Sign in to the demo.');
  if(['registry','award_cycles'].includes(table)&&p.role!=='admin')return error('Administrator required');
  if(table==='reporting_requirements'&&!['admin','reviewer'].includes(p.role))return error('Reviewer required');
  if(table==='submissions'&&(p.role!=='association'||values.association_id!==p.association_id))return error('Own association only');
  if(table==='profiles')return error('Use demo account management');
  for(const row of Array.isArray(values)?values:[values]){
   const key=table==='award_cycles'?'year':'id',existing=tables[table].find(r=>r[key]===row[key]&&(table!=='registry'||r.collection===row.collection));
   if(existing&&operation==='insert')return {data:null,error:{code:'23505',message:'Duplicate record'}};
   if(existing)Object.assign(existing,row);else tables[table].push({...row,created_at:new Date().toISOString()});
  }return ok(null);
 }return q;
}
const db={demo:true,from:query,auth:{async getSession(){await ready;return ok({session});},async signInWithPassword({email,password}){const u=users.find(u=>u.email===email&&u.password===password);if(!u)return error('Invalid demo credentials');session={user:{id:u.id,email:u.email},access_token:'demo-only'};return ok({user:session.user,session});},async signOut(){session=null;return ok(null);},async updateUser({password}){users.find(u=>u.id===session.user.id).password=password;return ok(null);}},storage:{from:()=>({async upload(path,file){files.set(path,file);return ok(null);},async createSignedUrl(path){if(!files.has(path))return error('Demo PDF is available only in the current page session.');return ok({signedUrl:URL.createObjectURL(files.get(path))});}})},async rpc(action,args){await ready;const p=current();if(!p)return error('Sign in');
 if(action==='edit_association_basics'){if(p.role!=='admin')return error('Administrator required');const row=tables.registry.find(r=>r.id===args.association_key);if(!row)return error('Association not found');Object.assign(row.payload,{name:args.association_name,shortName:args.abbreviation,sport:args.sport_name});return ok(null);}
 const s=tables.submissions.find(s=>s.id===args.submission_id);if(!s)return error('Submission not found');
 if(action==='edit_submission'){if(p.role!=='association'||s.association_id!==p.association_id||!['Draft','Returned'].includes(s.status))return error('Cannot edit');s.history.push({action:'Edited',previousPayload:s.payload});s.payload=args.new_payload;s.document_path=args.new_document_path;return ok(null);}
 if(action==='transition_submission'){
  const next=args.next_status;
  if(next==='Submitted'){
   if(p.role!=='association'||s.association_id!==p.association_id||!['Draft','Returned'].includes(s.status))return error('Cannot submit');
   if(s.kind==='Award nomination'&&s.payload.categoryId.startsWith('junior-')){const cycle=tables.award_cycles.find(c=>c.year===Number(s.period));const eligibility=window.MNCS_AWARD_SCORING.juniorEligibility(s.payload.dateOfBirth,cycle?.age_reference_date);if(!eligibility.eligible)return error('Set the junior age reference date and use an eligible under-20 nominee.');}
  }else if(!['Approved','Returned'].includes(next)||!['admin','reviewer'].includes(p.role)||s.status!=='Submitted')return error('Cannot review');
  if(next==='Returned'&&!args.comment.trim())return error('Correction comment required');s.status=next;s.review_comment=args.comment;s.history.push({status:next,comment:args.comment,at:new Date().toISOString()});if(next==='Approved'&&s.kind==='Profile update'){const row=tables.registry.find(r=>r.collection==='associations'&&r.id===s.association_id);if(row){for(const key of ['president','generalSecretary','termStart','termEnd','committee','affiliation','districts','lastAGM'])if(s.payload[key])row.payload[key]=s.payload[key];row.payload.verificationStatus='Approved';}}return ok(null);
 }return error('Unsupported demo operation');
},async demoAction(body){if(current()?.role!=='admin')throw Error('Demo administrator required');
 if(body.action==='reset-password'){const u=users.find(u=>u.id===body.user_id);if(!u)throw Error('User not found');u.password=body.password;return {message:'Demo password reset.'};}
 if(body.action==='create-account'){if(!['admin','reviewer','association'].includes(body.role))throw Error('Invalid demo role');if(users.some(u=>u.email===body.email))throw Error('Demo email already exists');if(body.role==='association'&&!tables.registry.some(r=>r.id===body.association_id))throw Error('Select an association');const u={...body,id:crypto.randomUUID(),association_id:body.role==='association'?body.association_id:null};users.push(u);const {password,...profile}=u;tables.profiles.push(profile);return {message:'Demo account created in memory.'};}
 throw Error('Unsupported demo account action');
}};
window.MNCS_CONFIG={demo:true,supabaseUrl:'demo-only',supabaseKey:'demo-only'};
window.supabase={createClient:()=>db};
window.MNCS_DEMO={db,tables,users,ready};
})();
