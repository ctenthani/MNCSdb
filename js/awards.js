(() => {
let categories=null;
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
window.renderAwards=async()=>{
 const root=document.getElementById('awards-content');root.textContent='Loading award categories…';
 try{
  if(!categories){const response=await fetch('data/award-categories.json');if(!response.ok)throw Error('Award categories could not be loaded.');categories=await response.json();}
  const db=window.MNCS_DB;let profile=null,user=null;
  if(db){const session=await db.auth.getSession();user=session.data.session?.user;if(user){const result=await db.from('profiles').select('*').eq('id',user.id).maybeSingle();if(result.error)throw result.error;profile=result.data;}}
  root.innerHTML=`<div class="bg-white rounded-xl border p-5"><h3 class="font-bold">Who opens awards participation?</h3><p>The MNCS administrator is responsible for authorising opening and closing, after screening and shortlist approval. Reviewers check dossiers; association administrators nominate candidates. Live voting is not yet implemented. Under an approved and disclosed judges-only policy, any public fan poll has no effect on official awards.</p><h3 class="font-bold mt-3">Handbook selection process</h3><p>Association nomination → eligibility screening → adjudication shortlist of three → public voting → 70% adjudication + 30% public vote → independent audit → confidential confirmation → gala announcement.</p><p class="mt-3 font-semibold">Proposed amendment: official awards based on judges’ scores only; a separate fan poll would have no effect on official results. This changes the handbook and requires MNCS approval and public disclosure.</p><p>Junior categories: strictly under 20. MNCS must set the age reference date for each awards year.</p><p class="mt-3">Official scoring is not yet enabled. MNCS must configure this cycle's dates, age reference date, criterion weights, scoring policy and tie-breakers. The 2024/25 handbook dates are historical.</p></div><h3 class="font-bold mt-5">Award categories</h3><div class="grid sm:grid-cols-2 gap-4 mt-3">${categories.map(c=>`<article class="bg-white rounded-xl border p-4"><h4 class="font-semibold">${esc(c.name)}</h4><p class="text-sm mt-2">${c.criteriaSummary.map(esc).join(' · ')}</p>${c.id==='personality'?'<p class="text-sm text-amber-800 mt-2">Finalist pool depends on confirmed individual athlete category winners.</p>':''}</article>`).join('')}</div><section id="award-workspace" class="bg-white rounded-xl border p-5 mt-5"></section>`;
  const workspace=document.getElementById('award-workspace');
  const cycleResult=db?await db.from('award_cycles').select('*'):null;
  if(cycleResult?.error)throw cycleResult.error;
  const cycles=cycleResult?.data||[];
  const cycleSummary=document.createElement('div');cycleSummary.className='workspace-help';
  cycleSummary.innerHTML='<h3>Awards nomination windows</h3>'+cycles.map(c=>`<p>${c.year}: <strong>${esc(c.nomination_status||'Closed')}</strong> · junior reference date ${esc(c.age_reference_date||'not set')} · ${esc(c.scoring_policy)}. Official award scoring remains disabled.</p>`).join('');
  if(!cycles.length)cycleSummary.innerHTML+='<p>No awards cycles configured yet.</p>';
  workspace.before(cycleSummary);
  if(profile&&['admin','reviewer'].includes(profile.role)){
   const queue={data:(await window.MNCS_SPORTS.all(db,'submissions')).filter(s=>s.kind==='Award nomination')};
   const consolePanel=document.createElement('section');consolePanel.className='workspace-help';
   consolePanel.innerHTML='<h3>Nomination screening overview</h3><p>'+['Draft','Submitted','Returned','Approved'].map(status=>status+': '+queue.data.filter(n=>n.status===status).length).join(' · ')+'</p><p>Approval confirms dossier screening, not an award win.</p><button id="awards-review-queue">Open MNCS review queue</button>';
   workspace.before(consolePanel);
   document.getElementById('awards-review-queue').onclick=()=>{switchView('portal');document.querySelector('[data-panel="submissions"]')?.click();};
  }
  if(profile?.role==='admin'){
   workspace.innerHTML=`<h3 class="font-bold">Configure an awards cycle</h3><p>Junior eligibility is strictly under 20 on the reference date you specify. Judges-only scoring is a change to the handbook; record MNCS approval and disclose it before official use. Official ranking remains disabled pending the judging and audit workflow.</p><form id="award-cycle-form"><label>Awards year<input name="year" type="number" min="2024" max="2100" required></label><label>Junior age reference date<input name="referenceDate" type="date" required></label><label>Nomination window<select name="nominationStatus"><option value="Closed">Closed</option><option value="Open">Open for association submissions</option></select></label><label>Scoring policy<select name="scoringPolicy"><option value="handbook_70_30">Handbook: 70% judges / 30% public</option><option value="judges_only">Proposed amendment: judges-only / separate fan poll</option></select></label><label><input name="approved" type="checkbox"> MNCS has approved this policy amendment</label><label><input name="disclosed" type="checkbox"> This policy has been publicly disclosed</label><button>Save cycle settings</button></form><p id="award-cycle-notice" role="status"></p>`;
   document.getElementById('award-cycle-form').addEventListener('submit',async event=>{
    event.preventDefault();const button=event.target.querySelector('button:not([type="button"])');button.disabled=true;
    try{const f=new FormData(event.target);const result=await db.from('award_cycles').upsert({year:Number(f.get('year')),age_reference_date:f.get('referenceDate'),scoring_policy:f.get('scoringPolicy'),amendment_approved:f.get('approved')==='on',policy_disclosed:f.get('disclosed')==='on',official_ranking_enabled:false,nomination_status:f.get('nominationStatus')});if(result.error)throw result.error;await window.renderAwards();document.getElementById('award-cycle-notice').textContent='Cycle saved. Nomination window updated. Official judging and voting remain disabled.';}catch(error){document.getElementById('award-cycle-notice').textContent=error.message;}finally{button.disabled=false;}
   });
   const cycleForm=document.getElementById('award-cycle-form');
   cycleForm.elements.year.addEventListener('change',()=>{const c=cycles.find(c=>c.year===Number(cycleForm.elements.year.value));if(c){cycleForm.elements.referenceDate.value=c.age_reference_date||'';cycleForm.elements.scoringPolicy.value=c.scoring_policy;cycleForm.elements.nominationStatus.value=c.nomination_status||'Closed';cycleForm.elements.approved.checked=c.amendment_approved;cycleForm.elements.disclosed.checked=c.policy_disclosed;}});
   cycleForm.elements.year.value=new Date().getFullYear();cycleForm.elements.year.dispatchEvent(new Event('change'));
   return;
  }
  if(profile?.role!=='association'){workspace.innerHTML='<p>Association administrators can sign in through Workspace to prepare award nominations. Submitted dossiers are available to MNCS in Workspace for eligibility review. Judges, voting and official rankings require the next implementation stage.</p>';return;}
  const sportsRows=await window.MNCS_SPORTS.all(db,'sport_records');
  const athletes=sportsRows.filter(r=>r.kind==='Athlete'&&r.association_id===profile.association_id&&r.published_payload&&r.status!=='Archived');
  workspace.innerHTML=`<h3 class="font-bold">Prepare an award nomination</h3><p>Include nominee and nominator contact details and the official nomination form in your private PDF dossier. Junior nominations need date-of-birth evidence. Saving creates a draft dossier, not an official award entry. MNCS must open the nomination window before you can submit your draft. Use approved athlete records to fill verified achievements; attach the official supporting dossier.</p><form id="award-nomination-form"><label>Awards year<input name="year" type="number" min="2024" max="2100" required></label><label>Award category<select name="category" required><option value="">Choose award category…</option>${categories.filter(c=>c.id!=='personality').map(c=>`<option value="${esc(c.id)}">${esc(c.name)}</option>`).join('')}</select></label><label>Nominee name<input name="nomineeName" required maxlength="160"></label><label>Approved athlete (optional for non-athlete categories)<select name="athleteId"><option value="">Other nominee / not a registered athlete</option>${athletes.map(a=>`<option value="${esc(a.id)}">${esc(a.published_payload.name)} · ${esc(a.published_payload.discipline)}</option>`).join('')}</select></label><button type="button" id="award-use-results">Fill verified athlete details and achievements</button><label>Date of birth (required for junior nominations)<input name="dateOfBirth" type="date"></label><label>Brief description<textarea name="description" required maxlength="2000"></textarea></label><label>Justification and achievements within the awards year<textarea name="motivation" required maxlength="12000"></textarea></label><label>Supporting evidence dossier (PDF, maximum 10 MB)<input name="document" type="file" accept="application/pdf" required></label><label><input name="declaration" type="checkbox" required> I confirm that the information is accurate and submitted on behalf of my association.</label><button>Save nomination draft</button></form><p id="award-notice" role="status" aria-live="polite"></p>`;
  const nominationForm=document.getElementById('award-nomination-form');
  const fillAchievements=()=>{
   const selected=athletes.find(a=>a.id===nominationForm.elements.athleteId.value);if(!selected){document.getElementById('award-notice').textContent='Choose an approved athlete first.';return;}
   const athlete=selected.published_payload,year=String(nominationForm.elements.year.value);
   nominationForm.elements.nomineeName.value=athlete.name;nominationForm.elements.dateOfBirth.value=athlete.dateOfBirth||'';
   nominationForm.elements.description.value=athlete.name+' — '+athlete.discipline+'; '+athlete.category;
   const results=sportsRows.filter(r=>r.kind==='Result'&&r.published_payload&&r.status!=='Archived'&&r.published_payload.athleteId===selected.id&&r.published_payload.resultDate?.startsWith(year+'-'));
   const lines=results.map(r=>{const v=r.published_payload,c=sportsRows.find(c=>c.id===v.competitionId)?.published_payload;return `${v.resultDate} — ${c?.name||'Competition'} (${c?.level||''}), ${v.outcome}${v.position?' place '+v.position:''}: ${v.mark||''} ${v.unit||''}${v.medal?' · '+v.medal+' medal':''}. Verified result ID: ${r.id}`;});
   nominationForm.elements.motivation.value=('Approved results in '+year+':\n'+(lines.join('\n')||'No approved results recorded in this year. Add evidence and explain the nomination.')).slice(0,12000);
   document.getElementById('award-notice').textContent='Verified athlete details filled. Review the achievements, add your justification and attach the official PDF dossier.';
  };
  document.getElementById('award-use-results').onclick=fillAchievements;
  const prefill=window.MNCS_NOMINATION_PREFILL;
  nominationForm.elements.year.value=prefill?.year||new Date().getFullYear();
  if(prefill){nominationForm.elements.athleteId.value=prefill.athleteId;fillAchievements();window.MNCS_NOMINATION_PREFILL=null;}
  document.getElementById('award-nomination-form').addEventListener('submit',async event=>{
   event.preventDefault();const button=event.target.querySelector('button:not([type="button"])');button.disabled=true;const notice=document.getElementById('award-notice');
   try{
    const f=new FormData(event.target),file=f.get('document'),category=categories.find(c=>c.id===f.get('category'));
    if(!file.size||file.type!=='application/pdf'||file.size>10485760)throw Error('Attach a PDF evidence dossier no larger than 10 MB.');
    const id=crypto.randomUUID(),period=String(f.get('year')),name=String(f.get('nomineeName')).trim();
    if(!name||!String(f.get('motivation')).trim()||!String(f.get('description')).trim())throw Error('Complete the nomination details.');
    const document_path=`${profile.association_id}/${id}.pdf`;
    const payload={categoryId:category.id,categoryName:category.name,nomineeType:category.nomineeType,nomineeName:name,athleteId:String(f.get('athleteId')||'').trim(),description:String(f.get('description')).trim(),motivation:String(f.get('motivation')).trim(),dateOfBirth:String(f.get('dateOfBirth')||''),declaration:true,screeningOnly:true};
    if(category.id.startsWith('junior-')&&!payload.dateOfBirth)throw Error('Junior nominations require a date of birth and evidence in the supporting PDF.');
    const exists=await db.from('submissions').select('id').eq('association_id',profile.association_id).eq('kind','Award nomination').eq('period',period).contains('payload',{categoryId:category.id,nomineeName:name});
    if(exists.error)throw exists.error;if(exists.data.length)throw Error('A nomination for this person/category/year already exists.');
    const upload=await db.storage.from('association-documents').upload(document_path,file,{contentType:'application/pdf'});if(upload.error)throw upload.error;
    const saved=await db.from('submissions').insert({id,association_id:profile.association_id,created_by:user.id,kind:'Award nomination',period,payload,status:'Draft',history:[],document_path});if(saved.error)throw saved.error;
    await window.MNCS_REFRESH_PORTAL?.();event.target.reset();notice.textContent='Nomination draft saved. Open Workspace to submit the dossier for eligibility review. Official acceptance remains subject to MNCS cycle rules.';
   }catch(error){notice.textContent=error.message;}finally{button.disabled=false;}
  });
 }catch(error){root.textContent=error.message;}
};
})();
