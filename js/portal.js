(() => {
const cfg = window.MNCS_CONFIG || {};
const live = Boolean(cfg.supabaseUrl && cfg.supabaseKey);
const db = live ? window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseKey) : null;
let user = null, profile = null, submissions = [], requirements = [], editingId = null;
const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const root = document.getElementById('portal-content');
const notice = document.getElementById('portal-notice');
const message = s => { notice.textContent = s; };
async function refresh() {
 if (db && user) {
  const p = await db.from('profiles').select('*').eq('id', user.id).single();
  if(p.error) throw p.error;
  profile = p.data;
  const r = await db.from('submissions').select('*').order('created_at',{ascending:false});
  if(r.error) throw r.error;
  submissions = r.data;
  const requirementsResult=await db.from('reporting_requirements').select('*');
  if(requirementsResult.error) throw requirementsResult.error;
  requirements=requirementsResult.data;
 }
 renderPortal();
}
function renderPortal() {
 if (!user) {
  root.innerHTML = live ? `<h3>Association and MNCS sign-in</h3><form id="login"><label>Email<input name="email" type="email" required autocomplete="username"></label><label>Password<input name="password" type="password" required autocomplete="current-password"></label><button>Sign in</button></form><p>Accounts are provisioned by the MNCS administrator.</p>` : `<h3>Workflow preview</h3><p>Supabase is not connected. This preview uses fictional records in memory; it does not authenticate users or save documents.</p><button id="demo-association">Preview association workspace</button> <button id="demo-reviewer">Preview MNCS review workspace</button>`;
  document.getElementById('login')?.addEventListener('submit',async e=>{e.preventDefault();const f=new FormData(e.target);try{const r=await db.auth.signInWithPassword({email:f.get('email'),password:f.get('password')});if(r.error)throw r.error;user=r.data.user;await refresh();message('Signed in.');}catch(e){message(e.message);}});
  ['association','reviewer'].forEach(role=>document.getElementById('demo-'+role)?.addEventListener('click',()=>{user={id:'preview'};profile={role,association_id:state.associations[0]?.id};renderPortal();}));return;
 }
 const reviewer = ['reviewer','admin'].includes(profile.role);
 const mine = reviewer ? submissions : submissions.filter(s=>s.association_id===profile.association_id);
 root.innerHTML = `<div class="portal-heading"><h3>${reviewer?'MNCS review workspace':'Association workspace'}</h3><button id="logout">${live?'Sign out':'Exit preview'}</button></div><p>${live?'Connected':'Preview only'} · ${esc(profile.role)} ${profile.association_id?'· '+esc(getAssociation(profile.association_id).name):''}</p><div class="portal-stats"><span>Submitted: ${mine.filter(s=>s.status==='Submitted').length}</span><span>Returned: ${mine.filter(s=>s.status==='Returned').length}</span><span>Approved: ${mine.filter(s=>s.status==='Approved').length}</span></div>${reviewer?'':`<h3>Prepare a submission</h3><form id="submission-form"><label>Submission type<select name="kind"><option>Profile update</option><option>Constitution</option><option>AGM minutes</option><option>Strategic plan</option><option>Annual report</option></select></label><label>Reporting period<input name="period" required maxlength="80" placeholder="e.g. 2026"></label><label>President<input name="president" maxlength="120"></label><label>General Secretary<input name="generalSecretary" maxlength="120"></label><label>Official email<input name="email" type="email"></label><label>Official phone<input name="phone" maxlength="40"></label><label>Leadership term start<input name="termStart" type="date"></label><label>Leadership term end<input name="termEnd" type="date"></label><label>Executive committee<textarea name="committee" maxlength="3000"></textarea></label><label>Affiliation details<textarea name="affiliation" maxlength="1000"></textarea></label><label>District coverage (comma separated)<input name="districts" maxlength="1000"></label><label>Last AGM<input name="lastAGM" type="date"></label><label>Supporting PDF (maximum 10 MB)<input name="document" type="file" accept="application/pdf"></label><button>Save draft</button></form>`}<h3>Submission history</h3><div id="submission-list">${mine.map(s=>`<article class="submission-card"><strong>${esc(s.kind)} · ${esc(s.period)}</strong><p>${esc(getAssociation(s.association_id).name)} · ${esc(s.status)}</p><pre>${esc(JSON.stringify(s.payload,null,2))}</pre><p>${esc(s.review_comment||'No reviewer comment')}</p>${s.document_path?`<button data-doc="${esc(s.id)}">View supporting PDF</button>`:''}${!reviewer&&['Draft','Returned'].includes(s.status)?`<button data-edit="${esc(s.id)}">Edit draft / correction</button> <button data-submit="${esc(s.id)}">Submit for review</button>`:''}${reviewer&&s.status==='Submitted'?`<label>Reviewer comment<textarea id="comment-${esc(s.id)}" maxlength="3000"></textarea></label><button data-review="${esc(s.id)}" data-status="Approved">Approve</button> <button data-review="${esc(s.id)}" data-status="Returned">Return for correction</button>`:''}<details><summary>Change history</summary><pre>${esc(JSON.stringify(s.history||[],null,2))}</pre></details></article>`).join('')||'<p>No submissions yet.</p>'}</div>`;
 renderReporting(reviewer);
 document.getElementById('logout').onclick=async()=>{if(db)await db.auth.signOut();user=profile=null;editingId=null;if(db){submissions=[];requirements=[];}renderPortal();};
 document.getElementById('submission-form')?.addEventListener('submit', saveDraft);
 root.querySelectorAll('[data-edit]').forEach(b=>b.onclick=()=>{
  const record=submissions.find(s=>s.id===b.dataset.edit);editingId=record.id;
  const form=document.getElementById('submission-form');
  form.elements.kind.value=record.kind;form.elements.kind.disabled=true;
  form.elements.period.value=record.period;form.elements.period.readOnly=true;
  Object.entries(record.payload).forEach(([k,v])=>{if(form.elements[k])form.elements[k].value=v;});
  message('Editing '+record.kind+'. Existing PDF is retained unless you attach a replacement.');
  form.scrollIntoView?.({behavior:'smooth',block:'start'});
 });
 root.querySelectorAll('[data-submit]').forEach(b=>b.onclick=()=>transition(b.dataset.submit,'Submitted',''));
 root.querySelectorAll('[data-review]').forEach(b=>b.onclick=()=>transition(b.dataset.review,b.dataset.status,document.getElementById('comment-'+b.dataset.review).value));
 root.querySelectorAll('[data-doc]').forEach(b=>b.onclick=async()=>{try{const s=submissions.find(s=>s.id===b.dataset.doc);const r=await db.storage.from('association-documents').createSignedUrl(s.document_path,60);if(r.error)throw r.error;window.open(r.data.signedUrl,'_blank','noopener');}catch(e){message(e.message);}});
}
async function saveDraft(e) {
 e.preventDefault();const button=e.target.querySelector('button');button.disabled=true;
 try {
 const f=new FormData(e.target), file=f.get('document'), payload={};
 const existing=submissions.find(s=>s.id===editingId);
 ['president','generalSecretary','email','phone','termStart','termEnd','committee','affiliation','districts','lastAGM'].forEach(k=>payload[k]=String(f.get(k)||'').trim());
 if(payload.termStart&&payload.termEnd&&payload.termEnd<payload.termStart)throw Error('Leadership term end must follow its start.');
 if((existing?.kind||f.get('kind'))!=='Profile update'&&!file.size&&!existing?.document_path)throw Error('Attach a supporting PDF for this document submission.');
 if(file.size&&(file.type!=='application/pdf'||file.size>10*1024*1024))throw Error('Use a PDF no larger than 10 MB.');
 const kind=existing?.kind||f.get('kind'),period=existing?.period||String(f.get('period')).trim();
 if(submissions.some(s=>s.id!==editingId&&s.association_id===profile.association_id&&s.kind===kind&&s.period===period&&['Draft','Submitted','Approved'].includes(s.status)))throw Error('A submission already exists for this type and period.');
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
 const container=document.createElement('section');container.id='reporting-panel';
 const assocs=reviewer?state.associations:state.associations.filter(a=>a.id===profile.association_id);
 const rows=window.MNCS_REPORTING.reportRows(assocs,requirements,submissions);
 container.innerHTML=`<h3>Reporting requirements and management summary</h3><p>Missing means no matching submission; overdue means the deadline passed without approval. These indicators do not determine affiliation or funding eligibility.</p>${reviewer?`<form id="requirement-form"><label>Required document<select name="kind"><option>Annual report</option><option>AGM minutes</option><option>Strategic plan</option><option>Constitution</option></select></label><label>Reporting period<input name="period" required maxlength="80"></label><label>Due date<input name="due" type="date" required></label><label>Association<select name="association"><option value="">All associations</option>${state.associations.map(a=>`<option value="${esc(a.id)}">${esc(a.name)}</option>`).join('')}</select></label><button>Add requirement</button></form>`:''}<button id="export-report">Download management CSV</button><div class="overflow-x-auto"><table><thead><tr><th>Association</th><th>Document</th><th>Period</th><th>Due</th><th>Status</th><th>Overdue</th></tr></thead><tbody>${rows.map(r=>`<tr><td>${esc(r.association)}</td><td>${esc(r.type)}</td><td>${esc(r.period)}</td><td>${esc(r.due)}</td><td>${esc(r.status)}</td><td>${r.overdue?'Yes':'No'}</td></tr>`).join('')||'<tr><td colspan="6">No reporting requirements configured.</td></tr>'}</tbody></table></div>`;
 root.appendChild(container);
 document.getElementById('export-report').onclick=()=>{const link=document.createElement('a');const url=URL.createObjectURL(new Blob([window.MNCS_REPORTING.csv(rows)],{type:'text/csv;charset=utf-8'}));link.href=url;link.download='MNCS-management-report.csv';link.click();URL.revokeObjectURL(url);};
 document.getElementById('requirement-form')?.addEventListener('submit',async e=>{e.preventDefault();try{const f=new FormData(e.target);const row={id:crypto.randomUUID(),kind:f.get('kind'),period:String(f.get('period')).trim(),due_date:f.get('due'),association_id:f.get('association')||null};if(requirements.some(r=>r.kind===row.kind&&r.period===row.period&&r.association_id===row.association_id))throw Error('This requirement already exists.');if(db){const result=await db.from('reporting_requirements').insert(row);if(result.error)throw result.error;await refresh();}else{requirements.push(row);renderPortal();}message('Requirement added.');}catch(e){message(e.message);}});
}
if(db)db.auth.getSession().then(async({data})=>{user=data.session?.user||null;try{await refresh();}catch(e){message(e.message);}});else renderPortal();
window.MNCS_DB=db;
})();
