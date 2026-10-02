(() => {
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const notice=text=>document.getElementById('portal-notice').textContent=text;
const passwordMinimum=window.MNCS_CONFIG?.demo?4:12;
const accountFields=`<label>Full name<input name="display_name" required maxlength="120" autocomplete="name"></label><label>Email<input name="email" type="email" required maxlength="254" autocomplete="off"></label><label>Password<input name="password" type="password" required minlength="${passwordMinimum}" maxlength="128" autocomplete="new-password"></label><label>Confirm password<input name="confirm" type="password" required minlength="${passwordMinimum}" maxlength="128" autocomplete="new-password"></label>`;
async function call(db,body){
 if(db.demoAction)return db.demoAction(body);
 const {data}=await db.auth.getSession();
 const headers={'Content-Type':'application/json'};
 if(data.session)headers.Authorization=`Bearer ${data.session.access_token}`;
 const response=await fetch('/.netlify/functions/accounts',{method:'POST',headers,body:JSON.stringify(body)});
 if(response.status===404)throw Error('The account service is not deployed. Deploy this project with Netlify functions enabled; uploading only the static site is insufficient.');
 let result;try{result=await response.json();}catch{throw Error('Account service is unavailable. Deploy the Netlify function and configure its server settings.');}
 if(!response.ok)throw Error(result.message||'Account request failed.');return result;
}
async function registerAssociation(db,body){
 const id=String(body.id||'').trim(),name=String(body.name||'').trim(),shortName=String(body.shortName||'').trim(),sport=String(body.sport||'').trim();
 if(!/^[A-Za-z0-9_-]{1,80}$/.test(id)||!name||name.length>160||!shortName||shortName.length>40||!sport||sport.length>100)throw Error('Complete all association fields. Use letters, numbers, hyphens or underscores for the ID.');
 const {error}=await db.from('registry').insert({collection:'associations',id,payload:{id,name,shortName,sport,status:'Under Review',verificationStatus:'Awaiting verification',strategicPlan:false}});
 if(error){
  if(error.code==='23505')throw Error('That association ID is already registered. Use the existing association or choose another ID.');
  if(error.code==='42501')throw Error('Registration is not permitted. Confirm your account has the MNCS administrator role and run the latest supabase/INSTALL_ALL.sql.');
  if(['42P01','PGRST205'].includes(error.code))throw Error('The registry table is unavailable. Run supabase/INSTALL_ALL.sql in the connected project.');
  throw Error('Association registration failed. Check your connection and try again. If it continues, report error '+(error.code||'unknown')+' to the site owner.');
 }
 return {message:'Association registered. You can now create accounts for its representatives.'};
}
function mount(root,db,profile,onRefresh){
 if(!db)return;
 const section=document.createElement('section');section.id='account-management';
 if(!profile){
  section.innerHTML=`<details><summary class="font-semibold cursor-pointer">Set up the initial MNCS administrator</summary><p>Use this once, with the setup code provided by the site owner. Once an administrator exists, initial setup is locked.</p><form id="bootstrap-form">${accountFields}<label>One-time setup code<input name="setup_code" type="password" required minlength="32" autocomplete="off"></label><button>Create initial MNCS administrator</button></form></details>`;
 }else if(profile.role==='admin'){
  section.innerHTML=`<section id="workspace-accounts" class="workspace-panel"><div class="panel-intro"><h3>Account management</h3><p>Create accounts for MNCS staff and association representatives. Each person receives their own login.</p></div><div id="account-service-health" class="service-health" role="status">Checking account service…</div><form id="create-account-form">${accountFields}<label>Role<select name="role"><option value="association">Association administrator</option><option value="reviewer">MNCS reviewer</option><option value="admin">MNCS administrator</option><option value="judge">Awards judge</option><option value="auditor">Independent awards auditor</option></select></label><label>Association (required for association accounts)<select name="association_id"><option value="">Select an association</option>${state.associations.map(a=>`<option value="${esc(a.id)}">${esc(a.name)}</option>`).join('')}</select></label><button type="button" id="generate-account-password">Generate and fill password</button><button>Create account</button></form><p id="generated-password" role="status"></p></section><section id="workspace-associations" class="workspace-panel"><div class="panel-intro"><h3>Register an association</h3><p>Add an association before creating accounts for its representatives. Use a stable, unique ID such as BUM.</p></div><form id="create-association-form"><label>Unique ID<input name="id" required pattern="[A-Za-z0-9_-]{1,80}" maxlength="80" placeholder="e.g. BUM"></label><label>Association name<input name="name" required maxlength="160"></label><label>Abbreviation<input name="shortName" required maxlength="40"></label><label>Sport<input name="sport" required maxlength="100"></label><button>Register association</button></form><div id="association-directory"><h3>Registered associations</h3><div class="overflow-x-auto"><table><thead><tr><th>ID</th><th>Association</th><th>Sport</th><th>Verification</th><th>Action</th></tr></thead><tbody>${state.associations.map(a=>`<tr><td>${esc(a.id)}</td><td>${esc(a.name)}</td><td>${esc(a.sport)}</td><td>${esc(a.verificationStatus||'Awaiting verification')}</td><td><button type="button" data-edit-association="${esc(a.id)}">Edit</button></td></tr>`).join('')||'<tr><td colspan="5">No associations registered yet.</td></tr>'}</tbody></table></div></div></section><section id="workspace-directory" class="workspace-panel"><h3>Account directory</h3><div id="account-directory">Loading accounts…</div></section>`;
 }else section.innerHTML='';
 if(profile)section.innerHTML+=`<section id="workspace-security" class="workspace-panel"><h3>Account security</h3><p>Choose a password of at least ${passwordMinimum} characters.${db.demo?' Demo only: 1234 is accepted; no live credentials are changed.':''}</p><details open><summary>Change my password</summary><form id="change-password-form"><label>New password<input name="password" type="password" required minlength="${passwordMinimum}" maxlength="128" autocomplete="new-password"></label><label>Confirm password<input name="confirm" type="password" required minlength="${passwordMinimum}" maxlength="128" autocomplete="new-password"></label><button>Update my password</button></form></details></section>`;
 if(profile?.role==='admin')section.querySelector('#workspace-security').insertAdjacentHTML('beforeend',`<h3>Reset a managed user's password</h3><p>Select any MNCS or association account. Reset one account at a time and share the new password privately.</p><form id="reset-password-form"><label>User<select name="user_id" required id="reset-user-select"><option value="">Loading accounts…</option></select></label><label>New password<input name="password" type="password" required minlength="${passwordMinimum}" maxlength="128" autocomplete="new-password"></label><label>Confirm password<input name="confirm" type="password" required minlength="${passwordMinimum}" maxlength="128" autocomplete="new-password"></label><button>Reset selected password</button></form>`);
 root.appendChild(section);
 if(profile?.role==='admin'){
  const health=document.getElementById('account-service-health');
  if(db.demo)health.textContent='Isolated demo: accounts are simulated in this page session.';
  else fetch('/.netlify/functions/accounts').then(async response=>{const status=await response.json();health.dataset.state=status.ready?'ready':'error';health.textContent=status.ready?'Server settings are present. Account creation still requires valid Supabase credentials.':'Setup required: '+(status.missing||[]).join(', ')+'. Set these variables in Netlify Functions and redeploy.';}).catch(()=>{health.dataset.state='error';health.textContent='The account service could not be checked. Confirm the Netlify function is deployed.';});
  const form=document.getElementById('create-account-form');const association=form.elements.association_id;
  const roleChanged=()=>{association.disabled=form.elements.role.value!=='association';association.required=!association.disabled;};form.elements.role.addEventListener('change',roleChanged);roleChanged();
 }

 document.getElementById('generate-account-password')?.addEventListener('click',()=>{
  const alphabet='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#';const values=crypto.getRandomValues(new Uint32Array(16));const password='Aa7!'+Array.from(values,v=>alphabet[v%alphabet.length]).join('');
  const form=document.getElementById('create-account-form');form.elements.password.value=password;form.elements.confirm.value=password;document.getElementById('generated-password').textContent='Generated password: '+password+' — copy and share privately.';
 });
 section.querySelectorAll('[data-edit-association]').forEach(button=>button.onclick=()=>{
  const association=state.associations.find(a=>a.id===button.dataset.editAssociation);const form=document.getElementById('create-association-form');form.dataset.editId=association.id;
  ['id','name','shortName','sport'].forEach(key=>form.elements[key].value=association[key]||'');form.elements.id.readOnly=true;form.querySelector('button').textContent='Save association changes';form.scrollIntoView?.({behavior:'smooth'});
 });

 section.querySelectorAll('form').forEach(form=>{const feedback=document.createElement('p');feedback.className='form-feedback';feedback.setAttribute('role','status');feedback.setAttribute('aria-live','polite');form.appendChild(feedback);});
 const bind=(id,action)=>document.getElementById(id)?.addEventListener('submit',async event=>{
  event.preventDefault();const button=event.target.querySelector('button:not([type="button"])');const feedback=event.target.querySelector('.form-feedback');button.disabled=true;feedback.textContent='Saving…';feedback.dataset.state='pending';
  try{const f=new FormData(event.target);const body=Object.fromEntries(f.entries());
   if('password' in body&&body.password!==body.confirm)throw Error('Passwords must match.');
   delete body.confirm;
   if(action==='create-account'&&body.role==='association'&&!body.association_id)throw Error('Select an association.');
   if(action==='change-password'){
    const updated=await db.auth.updateUser({password:body.password});if(updated.error)throw updated.error;
    event.target.reset();feedback.textContent='Password updated.';feedback.dataset.state='success';notice('Password updated.');return;
   }
   let result;
   if(action==='create-association'&&event.target.dataset.editId){const changed=await db.rpc('edit_association_basics',{association_key:event.target.dataset.editId,association_name:body.name,abbreviation:body.shortName,sport_name:body.sport});if(changed.error)throw changed.error;result={message:'Association details updated.'};}
   else result=action==='create-association'?await registerAssociation(db,body):await call(db,{...body,action});event.target.reset();feedback.textContent=result.message;feedback.dataset.state='success';
   if(profile){await loadData();await onRefresh();}
   document.getElementById('generated-password')?.replaceChildren();notice(result.message);
  }catch(error){feedback.textContent=error.message;feedback.dataset.state='error';notice(error.message);}finally{button.disabled=false;}
 });
 bind('reset-password-form','reset-password');bind('bootstrap-form','bootstrap');bind('create-account-form','create-account');bind('create-association-form','create-association');bind('change-password-form','change-password');
 if(profile?.role==='admin')db.from('profiles').select('id,email,display_name,role,association_id').then(({data,error})=>{
  const target=document.getElementById('account-directory');if(!target)return;
  const select=document.getElementById('reset-user-select');if(select)select.innerHTML=error?'<option value="">Account directory unavailable</option>':'<option value="">Select a user</option>'+data.map(p=>`<option value="${esc(p.id)}">${esc(p.display_name||p.email||p.id)} · ${esc(p.role)}</option>`).join('');
  target.innerHTML=error?'Account directory unavailable. Check the v0.4 database migration.':`<div class="overflow-x-auto"><table><thead><tr><th>Name</th><th>Email</th><th>Role</th><th>Association</th></tr></thead><tbody>${data.map(p=>`<tr><td>${esc(p.display_name||'Not recorded')}</td><td>${esc(p.email||'Not recorded')}</td><td>${esc(p.role)}</td><td>${esc(p.association_id||'MNCS')}</td></tr>`).join('')}</tbody></table></div>`;
 });
}
window.MNCS_ACCOUNTS={mount,registerAssociation};
})();
