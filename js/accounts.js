(() => {
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const notice=text=>document.getElementById('portal-notice').textContent=text;
const accountFields=`<label>Full name<input name="display_name" required maxlength="120" autocomplete="name"></label><label>Email<input name="email" type="email" required maxlength="254" autocomplete="off"></label><label>Password<input name="password" type="password" required minlength="12" maxlength="128" autocomplete="new-password"></label><label>Confirm password<input name="confirm" type="password" required minlength="12" maxlength="128" autocomplete="new-password"></label>`;
async function call(db,body){
 const {data}=await db.auth.getSession();
 const headers={'Content-Type':'application/json'};
 if(data.session)headers.Authorization=`Bearer ${data.session.access_token}`;
 const response=await fetch('/.netlify/functions/accounts',{method:'POST',headers,body:JSON.stringify(body)});
 let result;try{result=await response.json();}catch{throw Error('Account service is unavailable. Deploy the Netlify function and configure its server settings.');}
 if(!response.ok)throw Error(result.message||'Account request failed.');return result;
}
function mount(root,db,profile,onRefresh){
 if(!db)return;
 const section=document.createElement('section');section.id='account-management';
 if(!profile){
  section.innerHTML=`<details><summary class="font-semibold cursor-pointer">Set up the initial MNCS administrator</summary><p>Use this once, with the setup code provided by the site owner. Once an administrator exists, initial setup is locked.</p><form id="bootstrap-form">${accountFields}<label>One-time setup code<input name="setup_code" type="password" required minlength="32" autocomplete="off"></label><button>Create initial MNCS administrator</button></form></details>`;
 }else if(profile.role==='admin'){
  section.innerHTML=`<h3>Account management</h3><p>Create accounts for MNCS staff and association representatives. Each person receives their own login.</p><form id="create-account-form">${accountFields}<label>Role<select name="role"><option value="association">Association administrator</option><option value="reviewer">MNCS reviewer</option><option value="admin">MNCS administrator</option></select></label><label>Association (required for association accounts)<select name="association_id"><option value="">Select an association</option>${state.associations.map(a=>`<option value="${esc(a.id)}">${esc(a.name)}</option>`).join('')}</select></label><button>Create account</button></form><h3>Register an association</h3><form id="create-association-form"><label>Unique ID<input name="id" required pattern="[A-Za-z0-9_-]{1,80}" maxlength="80" placeholder="e.g. BUM"></label><label>Association name<input name="name" required maxlength="160"></label><label>Abbreviation<input name="shortName" required maxlength="40"></label><label>Sport<input name="sport" required maxlength="100"></label><button>Register association</button></form><h3>Account directory</h3><div id="account-directory">Loading accounts…</div>`;
 }else section.innerHTML='';
 if(profile)section.innerHTML+=`<details><summary>Change my password</summary><form id="change-password-form"><label>New password<input name="password" type="password" required minlength="12" maxlength="128" autocomplete="new-password"></label><label>Confirm password<input name="confirm" type="password" required minlength="12" maxlength="128" autocomplete="new-password"></label><button>Update my password</button></form></details>`;
 root.appendChild(section);
 const bind=(id,action)=>document.getElementById(id)?.addEventListener('submit',async event=>{
  event.preventDefault();const button=event.target.querySelector('button');button.disabled=true;
  try{const f=new FormData(event.target);const body=Object.fromEntries(f.entries());
   if('password' in body&&body.password!==body.confirm)throw Error('Passwords must match.');
   delete body.confirm;
   if(action==='create-account'&&body.role==='association'&&!body.association_id)throw Error('Select an association.');
   if(action==='change-password'){
    const updated=await db.auth.updateUser({password:body.password});if(updated.error)throw updated.error;
    event.target.reset();notice('Password updated.');return;
   }
   const result=await call(db,{...body,action});event.target.reset();
   if(profile){await loadData();await onRefresh();}
   notice(result.message);
  }catch(error){notice(error.message);}finally{button.disabled=false;}
 });
 bind('bootstrap-form','bootstrap');bind('create-account-form','create-account');bind('create-association-form','create-association');bind('change-password-form','change-password');
 if(profile?.role==='admin')db.from('profiles').select('id,email,display_name,role,association_id').then(({data,error})=>{
  const target=document.getElementById('account-directory');if(!target)return;
  target.innerHTML=error?'Account directory unavailable. Check the v0.4 database migration.':`<div class="overflow-x-auto"><table><thead><tr><th>Name</th><th>Email</th><th>Role</th><th>Association</th></tr></thead><tbody>${data.map(p=>`<tr><td>${esc(p.display_name||'Not recorded')}</td><td>${esc(p.email||'Not recorded')}</td><td>${esc(p.role)}</td><td>${esc(p.association_id||'MNCS')}</td></tr>`).join('')}</tbody></table></div>`;
 });
}
window.MNCS_ACCOUNTS={mount};
})();
