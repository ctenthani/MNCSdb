(() => {
const cfg = window.MNCS_CONFIG || {};
const demo=Boolean(cfg.demo);
const live = Boolean(cfg.supabaseUrl && cfg.supabaseKey);
const db = live ? window.MNCS_DB||window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseKey) : null;
let user = null, profile = null, submissions = [], requirements = [], editingId = null, activePanel = 'overview';
const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const root = document.getElementById('portal-content');
const notice = document.getElementById('portal-notice');
const readablePayload=payload=>'<dl class="submission-fields">'+Object.entries(payload||{}).filter(([key,value])=>value!==''&&value!==null&&value!==undefined&&!['screeningOnly','categoryId','nomineeType'].includes(key)).map(([key,value])=>'<div><dt>'+esc(key.replace(/([A-Z])/g,' $1').replace(/^./,c=>c.toUpperCase()))+'</dt><dd>'+esc(typeof value==='object'?JSON.stringify(value):typeof value==='boolean'?(value?'Yes':'No'):value)+'</dd></div>').join('')+'</dl>';
const message = s => { notice.textContent = s; };
async function refresh() {
 if (db && user) {
  const p = await db.from('profiles').select('*').eq('id', user.id).maybeSingle();
  if(p.error) throw p.error;
  profile = p.data;
  if(!profile&&user.email_confirmed_at){const fan=await db.rpc('register_fan_profile');if(!fan.error){const reread=await db.from('profiles').select('*').eq('id',user.id).maybeSingle();profile=reread.data;}}
  if(!profile){submissions=[];requirements=[];renderPortal();message('Your sign-in succeeded, but no MNCS or association profile is assigned. Ask the MNCS administrator to complete account provisioning.');return;}
  const r = await db.from('submissions').select('*').order('created_at',{ascending:false});
  if(r.error) throw r.error;
  submissions = r.data;
  const requirementsResult=await db.from('reporting_requirements').select('*');
  if(requirementsResult.error) throw requirementsResult.error;
  requirements=requirementsResult.data;
 }
 renderPortal();
 if(state.currentView==='awards')await window.renderAwards?.();
}
function renderPortal() {
 const identity=document.getElementById('account-identity');
 if(identity){identity.hidden=!user;identity.innerHTML=user?`<span><strong>${esc(profile?.display_name||'Signed in')}</strong> · ${esc(user.email||profile?.email||'')} <span class="role-pill">${esc(profile?.role||'Voting account')}</span>${profile?.association_id?' · '+esc(getAssociation(profile.association_id).name):''}</span><button id="identity-workspace">My workspace</button>`:'';document.getElementById('identity-workspace')?.addEventListener('click',()=>switchView('portal'));}
 if(user&&profile&&['judge','auditor','fan'].includes(profile.role)){
  root.innerHTML=`<header class="workspace-hero"><div><h3>${profile.role==='judge'?'Your judging desk':profile.role==='auditor'?'Your audit desk':'Your fan account'}</h3><p>${esc(profile.display_name||user.email)} · ${esc(user.email)}</p></div><button id="logout">Sign out</button></header><section class="workspace-panel"><p>${profile.role==='fan'?'Choose a finalist in the separate fan poll. Your vote does not affect official awards.':'Open Awards to work on your assigned categories. Other association administration stays private.'}</p><button id="official-open-awards">Open awards</button></section>`;
  window.MNCS_ACCOUNTS?.mount(root,db,profile,refresh);
  document.getElementById('official-open-awards').onclick=()=>switchView('awards');document.getElementById('logout').onclick=async()=>{await db.auth.signOut();user=profile=null;renderPortal();};return;
 }

 if(user&&!profile){
  root.innerHTML='<h3>Account setup incomplete</h3><p>Your authentication account has no accessible role profile. No administrative permissions have been granted.</p><button id="profile-signout">Sign out</button>';
  document.getElementById('profile-signout').onclick=async()=>{if(db)await db.auth.signOut();user=profile=null;submissions=[];requirements=[];renderPortal();message('Signed out.');};return;
 }
 if (!user) {
  root.innerHTML = live ? `<h3>Association and MNCS sign-in</h3><form id="login"><label>Email<input name="email" type="email" required autocomplete="username"></label><label>Password<input name="password" type="password" required autocomplete="current-password"></label><button>Sign in</button></form><p>${demo?'DEMO ONLY: use admin@mncs.example, reviewer@mncs.example or association@mncs.example with password 1234. Data stays in this page session.':'Accounts are provisioned by the MNCS administrator.'}</p>${demo?'<div class="workspace-actions"><button type="button" data-demo-login="admin">Demo administrator</button><button type="button" data-demo-login="reviewer">Demo reviewer</button><button type="button" data-demo-login="association">Demo association</button></div>':''}` : `<h3>Workflow preview</h3><p>Supabase is not connected. This preview uses fictional records in memory; it does not authenticate users or save documents.</p><button id="demo-association">Preview association workspace</button> <button id="demo-reviewer">Preview MNCS review workspace</button>`;
  document.getElementById('login')?.addEventListener('submit',async e=>{e.preventDefault();const f=new FormData(e.target);try{const r=await db.auth.signInWithPassword({email:f.get('email'),password:f.get('password')});if(r.error)throw r.error;user=r.data.user;await refresh();if(profile)message('Signed in.');}catch(e){message(e.message);}});
  if(!demo)window.MNCS_ACCOUNTS?.mount(root,db,null,refresh);
  if(demo)root.querySelectorAll('[data-demo-login]').forEach(button=>button.onclick=async()=>{const result=await db.auth.signInWithPassword({email:button.dataset.demoLogin+'@mncs.example',password:'1234'});if(result.error){message(result.error.message);return;}user=result.data.user;await refresh();message('Demo session: no live records or passwords are changed.');});
  ['association','reviewer'].forEach(role=>document.getElementById('demo-'+role)?.addEventListener('click',()=>{user={id:'preview'};profile={role,association_id:state.associations[0]?.id};renderPortal();}));return;
 }
 const reviewer = ['reviewer','admin'].includes(profile.role);
 const mine = reviewer ? submissions : submissions.filter(s=>s.association_id===profile.association_id);
 root.innerHTML = `<header class="workspace-hero"><div><p class="workspace-eyebrow">MNCS REGISTRY · ${demo?'ISOLATED DEMO':live?'CONNECTED WORKSPACE':'WORKFLOW PREVIEW'}</p><h3>${reviewer?'MNCS administration':'Association workspace'}</h3><p>${esc(profile.display_name||user.email||'Welcome')+' · '+esc(user.email||'')} <span class="role-pill">${esc(profile.role==='admin'?'Administrator':profile.role==='reviewer'?'Reviewer':'Association representative')}</span></p>${profile.association_id?`<p>${esc(getAssociation(profile.association_id).name)}</p>`:''}</div><button id="logout">${live?'Sign out':'Exit preview'}</button></header><div class="portal-stats">${[['Awaiting review','Submitted'],['Corrections needed','Returned'],['Approved records','Approved'],['Drafts','Draft']].map(([label,status])=>`<div class="workspace-stat"><span>${label}</span><strong>${mine.filter(s=>s.status===status).length}</strong></div>`).join('')}</div><nav id="workspace-nav" class="workspace-nav" aria-label="Workspace sections"></nav><section id="workspace-overview" class="workspace-panel"><div class="panel-intro"><h3>Welcome to your workspace</h3><p>${reviewer?'Approve competitions, respond to council requests and oversee association activity.':'Manage your sport. Register people, organise competitions and record results. Send reports and requests to council when needed.'}</p></div><div class="workspace-actions"><button data-open-panel="submissions">${reviewer?'Review submissions':'Send a report or request'}</button><button data-open-panel="reporting">View reporting summary</button><button data-open-panel="sports">Manage sports records</button><button data-open-panel="rankings">View athlete rankings</button>${profile.role==='admin'?'<button data-open-panel="associations">Register an association</button><button data-open-panel="accounts">Create an account</button>':''}</div><div class="workspace-help"><h4>Your next steps</h4><p>${profile.role==='admin'?'Register associations, create accounts for their representatives, then set reporting requirements. Submitted records appear in the review queue.':reviewer?'Open submissions to review supporting documents and approve records or return them with a clear correction request.':'Players, teams, fixtures and results belong to your association: save them and continue. Council reviews competitions, reports, nominations and requests you send.'}</p></div></section><section id="workspace-submissions" class="workspace-panel">${reviewer?'':`<h3>Prepare a submission</h3><form id="submission-form"><label>Submission type<select name="kind"><option>Annual report</option><option>Funding request</option><option>Travel abroad</option><option>MRA clearance</option><option>Other request</option><option>Profile update</option><option>Constitution</option><option>AGM minutes</option><option>Strategic plan</option></select></label><label>Reporting period<input name="period" required maxlength="80" placeholder="e.g. 2026"></label><label>President<input name="president" maxlength="120"></label><label>General Secretary<input name="generalSecretary" maxlength="120"></label><label>Official email<input name="email" type="email"></label><label>Official phone<input name="phone" maxlength="40"></label><label>Leadership term start<input name="termStart" type="date"></label><label>Leadership term end<input name="termEnd" type="date"></label><label>Executive committee<textarea name="committee" maxlength="3000"></textarea></label><label>Affiliation details<textarea name="affiliation" maxlength="1000"></textarea></label><label>District coverage (comma separated)<input name="districts" maxlength="1000"></label><label>Last AGM<input name="lastAGM" type="date"></label><label>Supporting PDF (maximum 10 MB)<input name="document" type="file" accept="application/pdf"></label><button>Save draft</button></form>`}<h3>Submission history</h3><div id="submission-list">${mine.map(s=>`<article class="submission-card"><strong>${esc(s.kind)} · ${esc(s.period)}</strong><p>${esc(getAssociation(s.association_id).name)} · ${esc(s.status)}</p>${readablePayload(s.payload)}<p>${esc(s.review_comment||'No reviewer comment')}</p>${s.document_path?`<button data-doc="${esc(s.id)}">View supporting PDF</button>`:''}${!reviewer&&['Draft','Returned'].includes(s.status)?`<button data-edit="${esc(s.id)}">Edit draft / correction</button> <button data-submit="${esc(s.id)}">Submit for review</button>`:''}${reviewer&&s.status==='Submitted'?`<label>Reviewer comment<textarea id="comment-${esc(s.id)}" maxlength="3000"></textarea></label><button data-review="${esc(s.id)}" data-status="Approved">${s.kind==='Award nomination'?'Approve eligibility dossier':'Approve'}</button> <button data-review="${esc(s.id)}" data-status="Returned">Return for correction</button>`:''}<details><summary>Change history</summary><pre>${esc(JSON.stringify(s.history||[],null,2))}</pre></details></article>`).join('')||'<div class="workspace-empty"><strong>No submissions yet</strong><p>New submissions will appear here with their review status and supporting documents.</p></div>'}</div></section>`;
 renderReporting(reviewer);
 window.MNCS_ACCOUNTS?.mount(root,db,profile,refresh);
 window.MNCS_SPORTS?.mount(root,db,profile);
 setupWorkspaceNavigation();
 document.getElementById('logout').onclick=async()=>{if(db)await db.auth.signOut();user=profile=null;editingId=null;activePanel='overview';if(db){submissions=[];requirements=[];}renderPortal();};
 const submissionForm=document.getElementById('submission-form');
 if(submissionForm?.elements){
  const kindField=submissionForm.elements.kind;
  const original=submissionForm.innerHTML;
  const changeFields=()=>{
   const type=kindField.value;
   const request=['Funding request','Travel abroad','MRA clearance','Other request'].includes(type);
   const fields=type==='Profile update'?original.slice(original.indexOf('<label>President'),original.indexOf('<label>Supporting PDF')):request?`<label>Request title<input name="title" required maxlength="160"></label><label>Tell council what you need<textarea name="summary" required maxlength="12000"></textarea></label>${type==='Funding request'?'<label>Amount requested<input name="requestedAmount" type="number" min="0.01" step="0.01" required></label><label>Currency<select name="currency"><option>MWK</option><option>USD</option><option>EUR</option></select></label>':''}${type==='Travel abroad'?'<label>Destination country<input name="country" required maxlength="100"></label><label>Departure date<input name="departureDate" type="date" required></label><label>Return date<input name="returnDate" type="date" required></label>':''}`:'<label>Notes for council (optional)<textarea name="summary" maxlength="12000"></textarea></label>';
   submissionForm.querySelector('#council-specific-fields')?.remove();
   if(!submissionForm.querySelector('#council-base-pruned')){[...submissionForm.querySelectorAll('label')].filter(label=>label.querySelector('[name="president"],[name="generalSecretary"],[name="email"],[name="phone"],[name="termStart"],[name="termEnd"],[name="committee"],[name="affiliation"],[name="districts"],[name="lastAGM"]')).forEach(label=>label.remove());const marker=document.createElement('span');marker.id='council-base-pruned';submissionForm.appendChild(marker);}
   const box=document.createElement('div');box.id='council-specific-fields';box.innerHTML=fields;submissionForm.querySelector('[name="document"]').closest('label').before(box);
   submissionForm.querySelector('button').textContent='Save draft';
  };
  kindField.addEventListener('change',changeFields);changeFields();
  submissionForm.elements.period.value=new Date().getFullYear();
  submissionForm.addEventListener('submit', saveDraft);
 }else submissionForm?.addEventListener('submit',saveDraft);
 root.querySelectorAll('[data-edit]').forEach(b=>b.onclick=()=>{
  const record=submissions.find(s=>s.id===b.dataset.edit);editingId=record.id;
  const form=document.getElementById('submission-form');
  if(record.kind==='Award nomination'){
   document.getElementById('award-edit-fields')?.remove();
   const fields=document.createElement('div');fields.id='award-edit-fields';
   fields.innerHTML='<p>Correct this award dossier. Category and year remain unchanged.</p>'+['nomineeName','athleteId','dateOfBirth','description','motivation'].map(k=>`<label>${esc(k)}<textarea name="${k}" ${['athleteId','dateOfBirth'].includes(k)?'':'required'}>${esc(record.payload[k]||'')}</textarea></label>`).join('');
   form.prepend(fields);
  }
  form.elements.kind.value=record.kind;form.elements.kind.dispatchEvent(new Event('change'));form.elements.kind.disabled=true;
  form.elements.period.value=record.period;form.elements.period.readOnly=true;
  Object.entries(record.payload).forEach(([k,v])=>{if(form.elements[k])form.elements[k].value=v;});
  message('Editing '+record.kind+'. Existing PDF is retained unless you attach a replacement.');
  form.scrollIntoView?.({behavior:'smooth',block:'start'});
 });
 root.querySelectorAll('[data-submit]').forEach(b=>b.onclick=()=>transition(b.dataset.submit,'Submitted',''));
 root.querySelectorAll('[data-review]').forEach(b=>b.onclick=()=>transition(b.dataset.review,b.dataset.status,document.getElementById('comment-'+b.dataset.review).value));
 root.querySelectorAll('[data-doc]').forEach(b=>b.onclick=async()=>{try{const s=submissions.find(s=>s.id===b.dataset.doc);const r=await db.storage.from('association-documents').createSignedUrl(s.document_path,60);if(r.error)throw r.error;window.open(r.data.signedUrl,'_blank','noopener');}catch(e){message(e.message);}});
}
function setupWorkspaceNavigation(){
 const sections=[['overview','Home'],['submissions',profile.role==='association'?'Council requests & reports':'Council inbox'],['reporting','Reports'],['sports',profile.role==='association'?'Manage my sport':'Competitions & oversight'],['rankings','Rankings'],...(profile.role==='admin'?[['associations','Associations'],['accounts','Create accounts'],['directory','Account directory']]:[]),...(db?[['security','Security']]:[])];
 const available=sections.filter(([id])=>document.getElementById('workspace-'+id));
 const nav=document.getElementById('workspace-nav');
 nav.innerHTML=available.filter(([id])=>!['associations','directory'].includes(id)).map(([id,label])=>`<button type="button" data-panel="${id}" aria-controls="workspace-${id}">${label}</button>`).join('');
 const activate=id=>{
  activePanel=available.some(([key])=>key===id)?id:'overview';
  available.forEach(([key])=>{document.getElementById('workspace-'+key).hidden=key!==activePanel;});
  nav.querySelectorAll('[data-panel]').forEach(button=>{const selected=button.dataset.panel===activePanel;button.classList.toggle('selected',selected);button.setAttribute('aria-current',selected?'page':'false');});
 };
 nav.querySelectorAll('[data-panel]').forEach(button=>button.onclick=()=>activate(button.dataset.panel));
 root.querySelectorAll('[data-open-panel]').forEach(button=>button.onclick=()=>activate(button.dataset.openPanel));
 nav.insertAdjacentHTML?.('beforeend','<button type="button" id="workspace-awards-link">Awards</button>');
 document.getElementById('workspace-awards-link')?.addEventListener('click',()=>switchView('awards'));
 window.MNCS_OPEN_PANEL=activate;
 if(profile.role==='admin'){document.getElementById('workspace-security')?.insertAdjacentHTML('beforeend','<div class="workspace-actions"><button type="button" id="settings-associations">Manage associations</button><button type="button" id="settings-directory">Account directory</button></div>');document.getElementById('settings-associations')?.addEventListener('click',()=>activate('associations'));document.getElementById('settings-directory')?.addEventListener('click',()=>activate('directory'));}
 activate(activePanel);
}
async function saveDraft(e) {
 e.preventDefault();const button=e.target.querySelector('button');button.disabled=true;
 try {
 const f=new FormData(e.target), file=f.get('document'), payload={};
 const existing=submissions.find(s=>s.id===editingId);
 ['president','generalSecretary','email','phone','termStart','termEnd','committee','affiliation','districts','lastAGM','title','summary','requestedAmount','currency','country','departureDate','returnDate'].forEach(k=>{if(f.get(k)!==null&&f.get(k)!==undefined)payload[k]=String(f.get(k)||'').trim();});
 if(existing?.kind==='Award nomination'){
  Object.assign(payload,existing.payload);
  ['nomineeName','athleteId','dateOfBirth','description','motivation'].forEach(k=>payload[k]=String(f.get(k)||'').trim());
  if(!payload.nomineeName||!payload.description||!payload.motivation)throw Error('Complete the award nomination details.');
 }
 if(payload.termStart&&payload.termEnd&&payload.termEnd<payload.termStart)throw Error('Leadership term end must follow its start.');
 if(!['Profile update','Funding request','Travel abroad','MRA clearance','Other request'].includes(existing?.kind||f.get('kind'))&&!file.size&&!existing?.document_path)throw Error('Attach a supporting PDF for this document submission.');
 if(file.size&&(file.type!=='application/pdf'||file.size>10*1024*1024))throw Error('Use a PDF no larger than 10 MB.');
 const kind=existing?.kind||f.get('kind'),period=existing?.period||String(f.get('period')).trim();
 if(submissions.some(s=>s.id!==editingId&&s.association_id===profile.association_id&&!['Funding request','Travel abroad','MRA clearance','Other request'].includes(kind)&&s.kind===kind&&s.period===period&&['Draft','Submitted','Approved'].includes(s.status)))throw Error('A submission already exists for this type and period.');
 const row={id:crypto.randomUUID(),association_id:profile.association_id,created_by:user.id,kind,period,payload,status:'Draft',history:[],document_path:null};
 if(existing){
  let path=existing.document_path;
  if(db&&file.size){path=`${profile.association_id}/${existing.id}-${crypto.randomUUID()}.pdf`;const upload=await db.storage.from('association-documents').upload(path,file,{contentType:'application/pdf'});if(upload.error)throw upload.error;}
  if(db){const edit=await db.rpc('edit_submission',{submission_id:existing.id,new_payload:payload,new_document_path:path});if(edit.error)throw edit.error;editingId=null;await refresh();}
  else{existing.history.push({action:'Edited',previousPayload:existing.payload,at:new Date().toISOString()});existing.payload=payload;editingId=null;renderPortal();}
  message('Corrections saved. Submit the record when ready.');return;
 }
 if(db){if(file.size){row.document_path=`${profile.association_id}/${row.id}.pdf`;const u=await db.storage.from('association-documents').upload(row.document_path,file,{contentType:'application/pdf'});if(u.error)throw u.error;}const r=await db.from('submissions').insert(row);if(r.error)throw r.error;await refresh();}else{submissions.unshift(row);renderPortal();}
 message(live?'Draft saved.':'Preview draft created in memory. No file was uploaded.');
 }catch(e){message(e.message);}finally{button.disabled=false;}
}
async function transition(id,status,comment){try{if(status==='Returned'&&!comment.trim())throw Error('Explain the correction required.');if(db){const r=await db.rpc('transition_submission',{submission_id:id,next_status:status,comment});if(r.error)throw r.error;await refresh();await loadData();}else{const s=submissions.find(s=>s.id===id);s.status=status;s.review_comment=comment;s.history.push({status,comment,at:new Date().toISOString()});renderPortal();}message('Status updated.');}catch(e){message(e.message);}}
function renderReporting(reviewer){
 const container=document.createElement('section');container.id='workspace-reporting';container.className='workspace-panel';
 const assocs=reviewer?state.associations:state.associations.filter(a=>a.id===profile.association_id);
 const rows=window.MNCS_REPORTING.reportRows(assocs,requirements,submissions);
 container.innerHTML=`<h3>Reporting requirements and management summary</h3><p>Missing means no matching submission; overdue means the deadline passed without approval. These indicators do not determine affiliation or funding eligibility.</p>${reviewer?`<form id="requirement-form"><label>Required document<select name="kind"><option>Annual report</option><option>AGM minutes</option><option>Strategic plan</option><option>Constitution</option></select></label><label>Reporting period<input name="period" required maxlength="80"></label><label>Due date<input name="due" type="date" required></label><label>Association<select name="association"><option value="">All associations</option>${state.associations.map(a=>`<option value="${esc(a.id)}">${esc(a.name)}</option>`).join('')}</select></label><button>Add requirement</button></form>`:''}<button id="export-report">Download management CSV</button><div class="overflow-x-auto"><table><thead><tr><th>Association</th><th>Document</th><th>Period</th><th>Due</th><th>Status</th><th>Overdue</th></tr></thead><tbody>${rows.map(r=>`<tr><td>${esc(r.association)}</td><td>${esc(r.type)}</td><td>${esc(r.period)}</td><td>${esc(r.due)}</td><td>${esc(r.status)}</td><td>${r.overdue?'Yes':'No'}</td></tr>`).join('')||'<tr><td colspan="6">No reporting requirements configured.</td></tr>'}</tbody></table></div>`;
 root.appendChild(container);
 document.getElementById('export-report').onclick=()=>{const link=document.createElement('a');const url=URL.createObjectURL(new Blob([window.MNCS_REPORTING.csv(rows)],{type:'text/csv;charset=utf-8'}));link.href=url;link.download='MNCS-management-report.csv';link.click();URL.revokeObjectURL(url);};
 document.getElementById('requirement-form')?.addEventListener('submit',async e=>{e.preventDefault();try{const f=new FormData(e.target);const row={id:crypto.randomUUID(),kind:f.get('kind'),period:String(f.get('period')).trim(),due_date:f.get('due'),association_id:f.get('association')||null};if(requirements.some(r=>r.kind===row.kind&&r.period===row.period&&r.association_id===row.association_id))throw Error('This requirement already exists.');if(db){const result=await db.from('reporting_requirements').insert(row);if(result.error)throw result.error;await refresh();}else{requirements.push(row);renderPortal();}message('Requirement added.');}catch(e){message(e.message);}});
}
if(db)db.auth.getSession().then(async({data})=>{user=data.session?.user||null;try{await refresh();}catch(e){renderPortal();message(e.message);}});else renderPortal();
window.MNCS_DB=db;
window.MNCS_REFRESH_PORTAL=async()=>{if(db){const session=await db.auth.getSession();user=session.data.session?.user||null;}await refresh();};
})();
