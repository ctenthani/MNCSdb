(() => {
let categories=null;
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
window.renderAwards=async()=>{
 const root=document.getElementById('awards-content');root.textContent='Loading award categories…';
 try{
  if(!categories){const response=await fetch('data/award-categories.json');if(!response.ok)throw Error('Award categories could not be loaded.');categories=await response.json();}
  const db=window.MNCS_DB;let profile=null,user=null;
  if(db){const session=await db.auth.getSession();user=session.data.session?.user;if(user){const result=await db.from('profiles').select('*').eq('id',user.id).maybeSingle();if(result.error)throw result.error;profile=result.data;}}
  root.innerHTML=`<section class="awards-intro"><p class="workspace-eyebrow">MALAWI SPORT AWARDS</p><h2>Choose an award. Tell their story.</h2><p>Association leaders: click a category below, choose your nominee and add the supporting details. Junior nominees must be under 20 on the cycle reference date.</p><p>Official awards use judges’ scores under an approved, disclosed policy. The separate fan poll is for participation and does not change official results.</p></section><div class="award-category-grid">${categories.map(c=>`<article><button type="button" class="award-category" data-award-category="${c.id}"><span class="award-category-name">${esc(c.name)}</span><span>${esc(c.criteriaSummary[0])}</span>${c.id==='personality'?'<small>Chosen from certified athlete-category winners</small>':'<small>Choose this category →</small>'}</button></article>`).join('')}</div><section id="award-workspace" class="bg-white rounded-xl border p-5 mt-5"></section><section id="awards-operations"></section>`;
  const chooseCategory=async id=>{
   window.MNCS_SELECTED_AWARD=id;
   if(profile?.role==='association'&&id!=='personality'){
    const form=document.getElementById('award-nomination-form');if(!form)return;form.hidden=false;form.elements.category.value=id;
    document.getElementById('nomination-category-title').textContent=categories.find(c=>c.id===id).name;
    const junior=id.startsWith('junior-');form.elements.dateOfBirth.required=junior;form.elements.dateOfBirth.closest('label').hidden=!junior;
    const athleteCategory=categories.find(c=>c.id===id).nomineeType==='athlete';form.elements.athleteId.closest('label').hidden=!athleteCategory;document.getElementById('award-use-results').hidden=!athleteCategory;
    if(!athleteCategory)form.elements.athleteId.value='';
    root.querySelectorAll('[data-award-category]').forEach(b=>b.classList.toggle('selected',b.dataset.awardCategory===id));
    form.scrollIntoView?.({block:'start',behavior:'smooth'});
   }else if(['admin','judge','auditor'].includes(profile?.role)){await window.renderAwards();document.getElementById('official-awards-desk')?.scrollIntoView?.({block:'start'});}
   else document.getElementById('portal-notice').textContent='Sign in as an association representative to nominate. Personality finalists are selected from certified athlete winners.';
  };
  root.querySelectorAll('[data-award-category]').forEach(b=>b.onclick=()=>chooseCategory(b.dataset.awardCategory));
  const workspace=document.getElementById('award-workspace');
  const cycleResult=db?await db.from('award_cycles').select('*'):null;
  if(cycleResult?.error)throw cycleResult.error;
  const cycles=cycleResult?.data||[];
  const cycleSummary=document.createElement('div');cycleSummary.className='workspace-help';
  cycleSummary.innerHTML='<h3>Awards nomination windows</h3>'+cycles.map(c=>`<p>${c.year}: <strong>${esc(c.nomination_status||'Closed')}</strong> · junior reference date ${esc(c.age_reference_date||'not set')} · ${esc(c.scoring_policy)}. Official results are published after independent audit.</p>`).join('');
  if(!cycles.length)cycleSummary.innerHTML+='<p>No awards cycles configured yet.</p>';
  workspace.before(cycleSummary);
  if(profile&&['admin','reviewer'].includes(profile.role)){
   const queue={data:(await window.MNCS_SPORTS.all(db,'submissions')).filter(s=>s.kind==='Award nomination')};
   const consolePanel=document.createElement('section');consolePanel.className='workspace-help';
   consolePanel.innerHTML='<h3>Nomination screening overview</h3><p>'+['Draft','Submitted','Returned','Approved'].map(status=>status+': '+queue.data.filter(n=>n.status===status).length).join(' · ')+'</p><p>Approval confirms dossier screening, not an award win.</p><button id="awards-review-queue">Open MNCS review queue</button>';
   workspace.before(consolePanel);
   document.getElementById('awards-review-queue').onclick=()=>{switchView('portal');document.querySelector('[data-panel="submissions"]')?.click();};
  }
  await window.MNCS_AWARDS_DESK?.mount(document.getElementById('awards-operations'),db,profile,categories,cycles);
  if(profile?.role==='admin'){
   workspace.innerHTML=`<h3 class="font-bold">Configure an awards cycle</h3><p>Junior eligibility is strictly under 20 on the reference date you specify. Judges-only scoring is a change to the handbook; record MNCS approval and disclose it before official use. Independent judges and auditors work in the awards desk below.</p><form id="award-cycle-form"><label>Awards year<input name="year" type="number" min="2024" max="2100" required></label><label>Junior age reference date<input name="referenceDate" type="date" required></label><label>Nomination window<select name="nominationStatus"><option value="Closed">Closed</option><option value="Open">Open for association submissions</option></select></label><label>Scoring policy<select name="scoringPolicy"><option value="handbook_70_30">Handbook: 70% judges / 30% public</option><option value="judges_only">Proposed amendment: judges-only / separate fan poll</option></select></label><label><input name="approved" type="checkbox"> MNCS has approved this policy amendment</label><label><input name="disclosed" type="checkbox"> This policy has been publicly disclosed</label><button>Save cycle settings</button></form><p id="award-cycle-notice" role="status"></p>`;
   document.getElementById('award-cycle-form').addEventListener('submit',async event=>{
    event.preventDefault();const button=event.target.querySelector('button:not([type="button"])');button.disabled=true;
    try{const f=new FormData(event.target);const result=await db.from('award_cycles').upsert({year:Number(f.get('year')),age_reference_date:f.get('referenceDate'),scoring_policy:f.get('scoringPolicy'),amendment_approved:f.get('approved')==='on',policy_disclosed:f.get('disclosed')==='on',official_ranking_enabled:false,nomination_status:f.get('nominationStatus')});if(result.error)throw result.error;await window.renderAwards();document.getElementById('award-cycle-notice').textContent='Cycle saved. Nomination window updated. Use the awards desk to shortlist, assign officials and open judging.';}catch(error){document.getElementById('award-cycle-notice').textContent=error.message;}finally{button.disabled=false;}
   });
   const cycleForm=document.getElementById('award-cycle-form');
   cycleForm.elements.year.addEventListener('change',()=>{const c=cycles.find(c=>c.year===Number(cycleForm.elements.year.value));if(c){cycleForm.elements.referenceDate.value=c.age_reference_date||'';cycleForm.elements.scoringPolicy.value=c.scoring_policy;cycleForm.elements.nominationStatus.value=c.nomination_status||'Closed';cycleForm.elements.approved.checked=c.amendment_approved;cycleForm.elements.disclosed.checked=c.policy_disclosed;}});
   cycleForm.elements.year.value=new Date().getFullYear();cycleForm.elements.year.dispatchEvent(new Event('change'));
   return;
  }
  if(profile?.role!=='association'){workspace.innerHTML='<p>Association administrators can sign in through Workspace to prepare award nominations. Submitted dossiers are available to MNCS in Workspace for eligibility review. Judges and auditors can use their assigned awards desk below.</p>';return;}
  const sportsRows=await window.MNCS_SPORTS.all(db,'sport_records');
  const athletes=sportsRows.filter(r=>r.kind==='Athlete'&&r.association_id===profile.association_id&&r.published_payload&&r.status!=='Archived');
  workspace.innerHTML=`<h3 class="font-bold" id="nomination-category-title">Click a category above to start</h3><p>Include nominee and nominator contact details and the official nomination form in your private PDF dossier. Junior nominations need date-of-birth evidence. Saving creates a draft dossier, not an official award entry. MNCS must open the nomination window before you can submit your draft. Use registered athlete records to fill recorded achievements; attach the official supporting dossier.</p><form id="award-nomination-form"><label>Awards year<input name="year" type="number" min="2024" max="2100" required></label><input name="category" type="hidden"><label>Nominee name<input name="nomineeName" required maxlength="160"></label><label>Your registered athlete (optional for non-athlete categories)<select name="athleteId"><option value="">Other nominee / not a registered athlete</option>${athletes.map(a=>`<option value="${esc(a.id)}">${esc(a.published_payload.name)} · ${esc(a.published_payload.discipline)}</option>`).join('')}</select></label><button type="button" id="award-use-results">Fill athlete details and recorded achievements</button><label>Date of birth (required for junior nominations)<input name="dateOfBirth" type="date"></label><label>Brief description<textarea name="description" required maxlength="2000"></textarea></label><label>Justification and achievements within the awards year<textarea name="motivation" required maxlength="12000"></textarea></label><label>Supporting evidence dossier (PDF, maximum 10 MB)<input name="document" type="file" accept="application/pdf" required></label><label><input name="declaration" type="checkbox" required> I confirm that the information is accurate and submitted on behalf of my association.</label><button>Save nomination draft</button></form><p id="award-notice" role="status" aria-live="polite"></p>`;
  const nominationForm=document.getElementById('award-nomination-form');
  const fillAchievements=()=>{
   const selected=athletes.find(a=>a.id===nominationForm.elements.athleteId.value);if(!selected){document.getElementById('award-notice').textContent='Choose a registered athlete first.';return;}
   const athlete=selected.published_payload,year=String(nominationForm.elements.year.value);
   nominationForm.elements.nomineeName.value=athlete.name;nominationForm.elements.dateOfBirth.value=athlete.dateOfBirth||'';
   nominationForm.elements.description.value=athlete.name+' — '+athlete.discipline+'; '+athlete.category;
   const results=sportsRows.filter(r=>r.kind==='Result'&&r.published_payload&&r.status!=='Archived'&&r.published_payload.athleteId===selected.id&&r.published_payload.resultDate?.startsWith(year+'-'));
   const lines=results.map(r=>{const v=r.published_payload,c=sportsRows.find(c=>c.id===v.competitionId)?.published_payload;return `${v.resultDate} — ${c?.name||'Competition'} (${c?.level||''}), ${v.outcome}${v.position?' place '+v.position:''}: ${v.mark||''} ${v.unit||''}${v.medal?' · '+v.medal+' medal':''}. Result record: ${r.id}`;});
   nominationForm.elements.motivation.value=('Association-recorded results in '+year+':\n'+(lines.join('\n')||'No recorded results in this year. Add evidence and explain the nomination.')).slice(0,12000);
   document.getElementById('award-notice').textContent='Athlete details filled. Review the achievements, add your justification and attach the official PDF dossier.';
  };
  document.getElementById('award-use-results').onclick=fillAchievements;nominationForm.elements.athleteId.onchange=()=>{if(nominationForm.elements.athleteId.value)fillAchievements();};
  const prefill=window.MNCS_NOMINATION_PREFILL;
  nominationForm.elements.year.value=prefill?.year||new Date().getFullYear();
  nominationForm.hidden=true;
  if(prefill){nominationForm.elements.athleteId.value=prefill.athleteId;fillAchievements();window.MNCS_NOMINATION_PREFILL=null;}
  const external=window.MNCS_EXTERNAL_NOMINATION;if(external){for(const field of ['nomineeName','description','motivation','dateOfBirth'])nominationForm.elements[field].value=external[field]||'';nominationForm.elements.year.value=external.year;nominationForm.dataset.sourceIntegrationId=external.sourceIntegrationId;window.MNCS_EXTERNAL_NOMINATION=null;}
  if(window.MNCS_SELECTED_AWARD&&window.MNCS_SELECTED_AWARD!=='personality')await chooseCategory(window.MNCS_SELECTED_AWARD);
  else if(prefill){const athlete=athletes.find(a=>a.id===prefill.athleteId);await chooseCategory(athlete?.published_payload.gender==='Female'?'sportswoman':'sportsman');}
  document.getElementById('award-nomination-form').addEventListener('submit',async event=>{
   event.preventDefault();const button=event.target.querySelector('button:not([type="button"])');button.disabled=true;const notice=document.getElementById('award-notice');
   try{
    const f=new FormData(event.target),file=f.get('document'),category=categories.find(c=>c.id===f.get('category'));
    if(!file.size||file.type!=='application/pdf'||file.size>10485760)throw Error('Attach a PDF evidence dossier no larger than 10 MB.');
    const id=crypto.randomUUID(),period=String(f.get('year')),name=String(f.get('nomineeName')).trim();
    if(!name||!String(f.get('motivation')).trim()||!String(f.get('description')).trim())throw Error('Complete the nomination details.');
    const document_path=`${profile.association_id}/${id}.pdf`;
    const payload={categoryId:category.id,categoryName:category.name,nomineeType:category.nomineeType,nomineeName:name,athleteId:String(f.get('athleteId')||'').trim(),description:String(f.get('description')).trim(),motivation:String(f.get('motivation')).trim(),dateOfBirth:String(f.get('dateOfBirth')||''),declaration:true,screeningOnly:true};
    if(event.target.dataset.sourceIntegrationId)payload.sourceIntegrationId=event.target.dataset.sourceIntegrationId;
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
