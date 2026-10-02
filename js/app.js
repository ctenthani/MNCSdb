// MNCS Players & Associations Database - Frontend

const state = {
  associations: [],
  players: [],
  events: [],
  results: [],
  currentView: 'dashboard',
  searchQuery: ''
};

const registryCollections=['associations','players','events','results'];
async function loadData() {
 const banner=document.getElementById('data-banner');
 document.getElementById('registry-load-error')?.remove();
 banner.textContent='Loading registry…';
 try {
  // A configured live project never falls back to demonstration records.
  const cfg=window.MNCS_CONFIG||{};
  const db=window.MNCS_DB||(cfg.supabaseUrl&&cfg.supabaseKey?window.supabase.createClient(cfg.supabaseUrl,cfg.supabaseKey):null);
  if(db)window.MNCS_DB=db;
  let next={};
  if(db){
   const result=await db.from('registry').select('*');if(result.error)throw result.error;
   registryCollections.forEach(key=>next[key]=result.data.filter(row=>row.collection===key).map(row=>({...row.payload,id:row.id})));
   banner.textContent=db.demo?'Isolated demo · fictional accounts; changes reset on reload':'Connected registry · association affiliation remains subject to MNCS verification';
  }else{
   const responses=await Promise.all(registryCollections.map(key=>fetch('data/'+key+'.json')));
   if(responses.some(r=>!r.ok))throw Error('Registry data unavailable');
   const data=await Promise.all(responses.map(r=>r.json()));registryCollections.forEach((key,i)=>next[key]=data[i]);
   banner.textContent='Demonstration records · not an official register';
  }
  next.players.forEach(p=>{delete p.phone;delete p.email;delete p.dateOfBirth;});
  next.associations.forEach(a=>{delete a.phone;delete a.email;});
  const today=new Intl.DateTimeFormat('en-CA',{timeZone:'Africa/Blantyre',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
  next.events.forEach(e=>{e.confirmedStatus=e.status;if(!['Cancelled','Postponed'].includes(e.status))e.status=e.startDate>today?'Upcoming':(e.endDate||e.startDate)<today?'Past':'Ongoing';});
  const safe=value=>typeof value==='string'?value.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])):value;
  registryCollections.forEach(key=>{next[key].forEach(row=>Object.keys(row).forEach(k=>row[k]=safe(row[k])));state[key]=next[key];});
  state.associations.forEach(a=>a.playerCount=state.players.filter(p=>p.associationId===a.id).length);
  state.loadedAt=new Date();render();return true;
 }catch(error){
  banner.textContent='Registry connection unavailable · refresh to retry';
  const panel=document.createElement('div');panel.id='registry-load-error';panel.className='registry-error';panel.setAttribute('role','alert');
  panel.innerHTML='<strong>We could not refresh the registry.</strong><p>Check your connection and try again. Previously loaded records remain visible; the workspace is still available.</p><button type="button" id="retry-registry">Try again</button>';
  document.querySelector('main').prepend(panel);document.getElementById('retry-registry').onclick=loadData;return false;
 }
}

function getAssociation(id) {
  return state.associations.find(a => a.id === id) || { name: 'Unknown', shortName: '?' };
}

function getPlayer(id) {
  return state.players.find(p => p.id === id);
}

function getEvent(id) {
  return state.events.find(e => e.id === id);
}

function switchView(view) {
  state.currentView = view;
  document.querySelectorAll('.view').forEach(el => el.classList.add('hidden'));
  const target = document.getElementById(`view-${view}`);
  if (target) target.classList.remove('hidden');

  document.querySelectorAll('.nav-btn').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.view === view);
  });

  document.getElementById('mobile-nav').classList.add('hidden');
  document.getElementById('mobile-menu-btn').setAttribute('aria-expanded','false');
  document.getElementById('search-toolbar').hidden=['portal','awards'].includes(view);
  document.querySelectorAll('.nav-btn').forEach(button=>button.setAttribute('aria-current',button.dataset.view===view?'page':'false'));
  location.hash=view;
  renderCurrentView();
}

function render() {
  // Stats
  document.getElementById('stat-associations').textContent = state.associations.length;
  document.getElementById('stat-players').textContent = state.players.length;
  document.getElementById('stat-events').textContent = state.events.length;
  document.getElementById('stat-results').textContent = state.results.length;

  const assocFilter=document.getElementById('player-assoc-filter'),selected=assocFilter.value;
  assocFilter.innerHTML='<option value="">All associations</option>';
  [...state.associations].sort((a,b)=>a.name.localeCompare(b.name)).forEach(a=>{const option=document.createElement('option');option.value=a.id;option.textContent=a.name;assocFilter.appendChild(option);});
  assocFilter.value=selected;
  document.getElementById('verified-associations').textContent=state.associations.filter(a=>a.verificationStatus==='Approved').length;
  document.getElementById('pending-associations').textContent=state.associations.filter(a=>a.verificationStatus!=='Approved').length;
  document.getElementById('registry-updated').textContent=state.loadedAt?'Refreshed '+state.loadedAt.toLocaleTimeString('en-GB',{timeZone:'Africa/Blantyre',hour:'2-digit',minute:'2-digit'})+' CAT':'Waiting for connection';

  renderCurrentView();
}

function renderCurrentView() {
  const q = state.searchQuery.toLowerCase().trim();

  if (state.currentView === 'awards') {
    window.renderAwards?.();
  } else if (state.currentView === 'dashboard') {
    renderDashboard(q);
  } else if (state.currentView === 'associations') {
    renderAssociations(q);
  } else if (state.currentView === 'players') {
    renderPlayers(q);
  } else if (state.currentView === 'events') {
    renderEvents(q);
    window.renderPublicFixtures?.();
  } else if (state.currentView === 'results') {
    renderResults(q);
  }
}

function renderDashboard(q) {
  // Featured players (national team first)
  const featured = state.players
    .filter(p => !q || `${p.firstName} ${p.lastName} ${p.club}`.toLowerCase().includes(q))
    .sort((a, b) => (b.nationalTeam ? 1 : 0) - (a.nationalTeam ? 1 : 0))
    .slice(0, 6);

  document.getElementById('featured-players').innerHTML = featured.map(p => {
    const assoc = getAssociation(p.associationId);
    return `
      <div class="flex items-center gap-3 p-2 rounded-lg hover:bg-slate-50 cursor-pointer" data-player="${p.id}" role="button" tabindex="0">
        <div class="w-9 h-9 rounded-full bg-green-100 text-green-800 flex items-center justify-center text-sm font-semibold">
          ${p.firstName[0]}${p.lastName[0]}
        </div>
        <div class="flex-1 min-w-0">
          <p class="font-medium text-sm truncate">${p.firstName} ${p.lastName}</p>
          <p class="text-xs text-slate-500 truncate">${assoc.shortName} • ${p.position || '—'}</p>
        </div>
        ${p.nationalTeam ? '<span class="text-xs bg-amber-100 text-amber-800 px-1.5 py-0.5 rounded">NT</span>' : ''}
      </div>`;
  }).join('') || '<p class="text-sm text-slate-400">No players match.</p>';

  // Upcoming / Ongoing events
  const upcoming = state.events
    .filter(e => e.status === 'Upcoming' || e.status === 'Ongoing')
    .filter(e => !q || e.name.toLowerCase().includes(q))
    .slice(0, 5);

  document.getElementById('upcoming-events').innerHTML = upcoming.map(e => {
    const assoc = getAssociation(e.associationId);
    return `
      <div class="p-3 rounded-lg border border-slate-100 hover:border-green-200 cursor-pointer" data-event="${e.id}" role="button" tabindex="0">
        <div class="flex items-start justify-between gap-2">
          <p class="font-medium text-sm">${e.name}</p>
          <span class="status-badge status-${e.status}">${e.status}</span>
        </div>
        <p class="text-xs text-slate-500 mt-1">${assoc.shortName} • ${e.startDate}</p>
      </div>`;
  }).join('') || '<p class="text-sm text-slate-400">No upcoming events.</p>';
}

let associationPage=1;
function filteredAssociations(q=state.searchQuery.toLowerCase().trim()){
 const status=document.getElementById('assoc-status-filter').value,sport=document.getElementById('assoc-sport-filter').value,verification=document.getElementById('assoc-verification-filter').value;
 return state.associations.filter(a=>(!status||a.status===status)&&(!sport||a.sport===sport)&&(!verification||(verification==='approved')===(a.verificationStatus==='Approved'))&&(!q||`${a.name} ${a.shortName||''} ${a.sport||''}`.toLowerCase().includes(q))).sort((a,b)=>document.getElementById('assoc-sort').value==='sport'?a.sport.localeCompare(b.sport)||a.name.localeCompare(b.name):a.name.localeCompare(b.name));
}
function renderAssociations(q){
 const filter=document.getElementById('assoc-sport-filter'),selected=filter.value;filter.innerHTML='<option value="">All sports</option>';
 [...new Set(state.associations.map(a=>a.sport).filter(Boolean))].sort().forEach(sport=>{const option=document.createElement('option');option.value=sport;option.textContent=sport;filter.appendChild(option);});filter.value=selected;
 const list=filteredAssociations(q),pages=Math.max(1,Math.ceil(list.length/12));associationPage=Math.min(associationPage,pages);
 document.getElementById('association-count').textContent=`${list.length} association${list.length===1?'':'s'} found · page ${associationPage} of ${pages}`;
 document.getElementById('associations-list').innerHTML=list.slice((associationPage-1)*12,associationPage*12).map(a=>`<article class="association-card"><div class="association-card-top"><span class="sport-label">${a.sport||'Sport not recorded'}</span><span class="verification-chip ${a.verificationStatus==='Approved'?'verified':''}">${a.verificationStatus==='Approved'?'Profile approved':'Verification pending'}</span></div><h3>${a.name}</h3><p class="association-code">${a.id} · ${a.shortName||'No abbreviation'}</p><dl><div><dt>Athlete records</dt><dd>${a.playerCount||0}</dd></div><div><dt>Last AGM</dt><dd>${a.lastAGM||'Not recorded'}</dd></div></dl><button type="button" data-association="${a.id}">View association <span aria-hidden="true">↗</span></button></article>`).join('')||'<div class="directory-empty"><h3>No matching associations</h3><p>Try another search or clear your filters.</p><button type="button" id="clear-directory-filters">Clear filters</button></div>';
 document.getElementById('association-pagination').innerHTML=`<button type="button" id="previous-association-page" ${associationPage===1?'disabled':''}>Previous</button><span>${associationPage} / ${pages}</span><button type="button" id="next-association-page" ${associationPage===pages?'disabled':''}>Next</button>`;
 document.getElementById('previous-association-page').onclick=()=>{associationPage--;renderAssociations(q);};document.getElementById('next-association-page').onclick=()=>{associationPage++;renderAssociations(q);};
 document.getElementById('clear-directory-filters')?.addEventListener('click',()=>{['assoc-status-filter','assoc-sport-filter','assoc-verification-filter','global-search'].forEach(id=>document.getElementById(id).value='');state.searchQuery='';associationPage=1;renderAssociations('');});
}

function renderPlayers(q) {
  const assocId = document.getElementById('player-assoc-filter').value;
  const gender = document.getElementById('player-gender-filter').value;
  const nationalOnly = document.getElementById('player-national-filter').value === 'true';

  let list = state.players;
  if (assocId) list = list.filter(p => p.associationId === assocId);
  if (gender) list = list.filter(p => p.gender === gender);
  if (nationalOnly) list = list.filter(p => p.nationalTeam);
  if (q) {
    list = list.filter(p =>
      `${p.firstName} ${p.lastName}`.toLowerCase().includes(q) ||
      (p.club && p.club.toLowerCase().includes(q)) ||
      (p.position && p.position.toLowerCase().includes(q)) ||
      (p.district && p.district.toLowerCase().includes(q))
    );
  }

  const rows = list.map(p => {
    const assoc = getAssociation(p.associationId);
    return `
      <tr class="cursor-pointer" data-player="${p.id}" role="button" tabindex="0">
        <td class="font-medium">${p.firstName} ${p.lastName}</td>
        <td>${assoc.shortName}</td>
        <td>${p.position || '—'}</td>
        <td>${p.gender}</td>
        <td>${p.district || '—'}</td>
        <td>${p.nationalTeam ? '<span class="text-xs bg-amber-100 text-amber-800 px-1.5 py-0.5 rounded">Yes</span>' : '—'}</td>
        <td><span class="status-badge status-${p.status}">${p.status}</span></td>
      </tr>`;
  }).join('');

  document.getElementById('players-list').innerHTML = `
    <table>
      <thead>
        <tr>
          <th>Name</th>
          <th>Association</th>
          <th>Position / Event</th>
          <th>Gender</th>
          <th>District</th>
          <th>National Team</th>
          <th>Status</th>
        </tr>
      </thead>
      <tbody>
        ${rows || '<tr><td colspan="7" class="text-center text-slate-400 py-8">No players match the filters.</td></tr>'}
      </tbody>
    </table>
    <p class="text-xs text-slate-400 px-4 py-2">${list.length} player(s) shown</p>`;
}

function renderEvents(q) {
  const statusFilter = document.getElementById('event-status-filter').value;
  let list = state.events;
  if (statusFilter) list = list.filter(e => e.status === statusFilter);
  if (q) list = list.filter(e => e.name.toLowerCase().includes(q) || e.type.toLowerCase().includes(q));

  document.getElementById('events-list').innerHTML = list.map(e => {
    const assoc = getAssociation(e.associationId);
    return `
      <div class="bg-white rounded-xl border border-slate-100 shadow-sm p-4 card-hover cursor-pointer" data-event="${e.id}" role="button" tabindex="0">
        <div class="flex flex-wrap items-start justify-between gap-2">
          <div>
            <h3 class="font-semibold">${e.name}</h3>
            <p class="text-sm text-slate-500 mt-0.5">${assoc.name} • ${e.type} • ${e.level}</p>
          </div>
          <span class="status-badge status-${e.status}">${e.status}</span>
        </div>
        <div class="mt-3 flex flex-wrap gap-4 text-xs text-slate-500">
          <span>${e.startDate}${e.endDate && e.endDate !== e.startDate ? ' → ' + e.endDate : ''}</span>
          <span>${e.venue || '—'}</span>
        </div>
      </div>`;
  }).join('') || '<p class="text-center text-slate-400 py-8">No events found.</p>';
}

function renderResults(q) {
  let list = state.results;
  if (q) {
    list = list.filter(r => {
      const player = getPlayer(r.playerId);
      const event = getEvent(r.eventId);
      const name = player ? `${player.firstName} ${player.lastName}` : '';
      return name.toLowerCase().includes(q) ||
             (event && event.name.toLowerCase().includes(q)) ||
             (r.category && r.category.toLowerCase().includes(q));
    });
  }

  const rows = list.map(r => {
    const player = getPlayer(r.playerId);
    const event = getEvent(r.eventId);
    const medalClass = r.medal ? `medal-${r.medal}` : '';
    return `
      <tr>
        <td class="font-medium">${r.teamName || (player ? player.firstName + ' ' + player.lastName : 'Private athlete')}</td>
        <td>${event ? event.name : r.eventId}</td>
        <td>${r.category || '—'}</td>
        <td>${r.position ?? '—'}</td>
        <td class="${medalClass}">${r.medal || '—'}</td>
        <td>${r.performance || '—'} ${r.unit || ''}</td>
        <td>${r.outcome || '—'}<br>${r.resultDate || ''}</td>
      </tr>`;
  }).join('');

  document.getElementById('results-list').innerHTML = `
    <table>
      <thead>
        <tr>
          <th>Participant</th>
          <th>Event</th>
          <th>Category</th>
          <th>Pos</th>
          <th>Medal</th>
          <th>Performance</th>
          <th>Outcome / date</th>
        </tr>
      </thead>
      <tbody>
        ${rows || '<tr><td colspan="7" class="text-center text-slate-400 py-8">No results found.</td></tr>'}
      </tbody>
    </table>`;
}

// Detail modals
function showPlayerDetail(id) {
  const p = getPlayer(id);
  if (!p) return;
  const assoc = getAssociation(p.associationId);
  document.getElementById('modal-title').textContent = `${p.firstName} ${p.lastName}`;
  document.getElementById('modal-body').innerHTML = `
    <p><span class="text-slate-500">ID:</span> ${p.id}</p>
    <p><span class="text-slate-500">Association:</span> ${assoc.name}</p>
    <p><span class="text-slate-500">Club / Team:</span> ${p.club || '—'}</p>
    <p><span class="text-slate-500">Position / Event:</span> ${p.position || '—'}</p>
    <p><span class="text-slate-500">Gender:</span> ${p.gender}</p>

    <p><span class="text-slate-500">District:</span> ${p.district || '—'}</p>
    <p><span class="text-slate-500">National Team:</span> ${p.nationalTeam ? 'Yes' : 'No'}</p>
    <p><span class="text-slate-500">Status:</span> ${p.status}</p>
    <p><span class="text-slate-500">Registered:</span> ${p.registrationDate || '—'}</p>
    ${p.phone ? `<p><span class="text-slate-500">Phone:</span> ${p.phone}</p>` : ''}
  `;
  openModal();
}

function showAssociationDetail(id) {
  const a = state.associations.find(x => x.id === id);
  if (!a) return;
  document.getElementById('modal-title').textContent = a.name;
  document.getElementById('modal-body').innerHTML = `
    <p><span class="text-slate-500">Short name:</span> ${a.shortName}</p>
    <p><span class="text-slate-500">Sport:</span> ${a.sport}</p>
    <p><span class="text-slate-500">Status:</span> ${a.status}</p>
    <p><span class="text-slate-500">President:</span> ${a.president || '—'}</p>
    <p><span class="text-slate-500">General Secretary:</span> ${a.generalSecretary || '—'}</p>


    <p><span class="text-slate-500">Last AGM:</span> ${a.lastAGM || '—'}</p>
    <p><span class="text-slate-500">Strategic Plan:</span> ${a.strategicPlan ? 'Submitted' : 'Not on file'}</p>
    <p><span class="text-slate-500">Athlete records:</span> ${a.playerCount}</p>
    ${a.website && /^https?:\/\//i.test(a.website) ? `<p><span class="text-slate-500">Website:</span> <a href="${a.website}" target="_blank" rel="noopener noreferrer" class="text-green-700 underline">${a.website}</a></p>` : ''}
  `;
  const body=document.getElementById('modal-body');
  const note=document.createElement('p');note.className='source-note';note.textContent='Profile verification: '+(a.verificationStatus||'Awaiting MNCS review');body.appendChild(note);
  if(a.sourceUrl){try{const url=new URL(a.sourceUrl);if(url.protocol==='https:'){const link=document.createElement('a');link.href=url.href;link.target='_blank';link.rel='noopener noreferrer';link.textContent='View source listing';body.appendChild(link);}}catch{}}
  openModal();
}

function showEventDetail(id) {
  const e = getEvent(id);
  if (!e) return;
  const assoc = getAssociation(e.associationId);
  document.getElementById('modal-title').textContent = e.name;
  document.getElementById('modal-body').innerHTML = `
    <p><span class="text-slate-500">Association:</span> ${assoc.name}</p>
    <p><span class="text-slate-500">Type:</span> ${e.type}</p>
    <p><span class="text-slate-500">Level:</span> ${e.level}</p>
    <p><span class="text-slate-500">Dates:</span> ${e.startDate}${e.endDate && e.endDate !== e.startDate ? ' → ' + e.endDate : ''}</p>
    <p><span class="text-slate-500">Venue:</span> ${e.venue || '—'}</p>
    <p><span class="text-slate-500">Status:</span> ${e.status}</p>
    <p class="mt-2 text-slate-600">${e.description || ''}</p>
  `;
  openModal();
}

let modalReturnFocus=null;
function openModal() {
  modalReturnFocus=document.activeElement;
  document.getElementById('modal').classList.add('show');
  document.getElementById('modal-close').focus();
  document.body.style.overflow='hidden';
}
function closeModal() {
  document.getElementById('modal').classList.remove('show');
  document.body.style.overflow='';modalReturnFocus?.focus();
}

// Event listeners
document.querySelectorAll('.nav-btn').forEach(btn => {
  btn.addEventListener('click', () => switchView(btn.dataset.view));
});

document.getElementById('mobile-menu-btn').addEventListener('click', () => {
  const hidden=document.getElementById('mobile-nav').classList.toggle('hidden');
  document.getElementById('mobile-menu-btn').setAttribute('aria-expanded',String(!hidden));
});

document.getElementById('global-search').addEventListener('input', (e) => {
  state.searchQuery = e.target.value;
  associationPage=1;
  renderCurrentView();
});

['assoc-status-filter', 'player-assoc-filter', 'player-gender-filter', 'player-national-filter', 'event-status-filter']
  .forEach(id => {
    const el = document.getElementById(id);
    if (el) el.addEventListener('change', () => renderCurrentView());
  });

document.getElementById('modal-close').addEventListener('click', closeModal);
document.getElementById('modal').addEventListener('click', (e) => {
  if (e.target.id === 'modal') closeModal();
});

document.querySelector('main').addEventListener('click',event=>{const target=event.target.closest('[data-association],[data-player],[data-event]');if(!target)return;if(target.dataset.association)showAssociationDetail(target.dataset.association);if(target.dataset.player)showPlayerDetail(target.dataset.player);if(target.dataset.event)showEventDetail(target.dataset.event);});
document.querySelector('main').addEventListener('keydown',event=>{if(['Enter',' '].includes(event.key)&&event.target.matches('[data-player],[data-event]')){event.preventDefault();event.target.click();}});
document.addEventListener('keydown',event=>{const modal=document.getElementById('modal');if(!modal.classList.contains('show'))return;if(event.key==='Escape')closeModal();if(event.key==='Tab'){const nodes=[...modal.querySelectorAll('button,a[href],input,select,textarea')];const first=nodes[0],last=nodes[nodes.length-1];if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus();}else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus();}}});
document.getElementById('explore-directory').onclick=()=>switchView('associations');document.getElementById('open-workspace').onclick=()=>switchView('portal');
['assoc-status-filter','assoc-sport-filter','assoc-verification-filter','assoc-sort'].forEach(id=>document.getElementById(id).addEventListener('change',()=>{associationPage=1;renderAssociations(state.searchQuery.toLowerCase().trim());}));
document.getElementById('export-associations').onclick=()=>{const headers=['id','name','sport','shortName','status','verificationStatus','sourceUrl'];const decode=value=>{const node=document.createElement('textarea');node.innerHTML=String(value??'');return node.value;};const cell=value=>{let text=decode(value);if(/^[\s]*[=+@\-]/.test(text))text="'"+text;return '"'+text.replace(/"/g,'""')+'"';};const content=[headers,...filteredAssociations().map(a=>headers.map(key=>a[key]))].map(row=>row.map(cell).join(',')).join('\r\n');const url=URL.createObjectURL(new Blob([content],{type:'text/csv;charset=utf-8'}));const link=document.createElement('a');link.href=url;link.download='MNCS-association-directory.csv';link.click();URL.revokeObjectURL(url);};
window.addEventListener('hashchange',()=>{const next=location.hash.slice(1);if(['dashboard','associations','players','events','results','awards','portal'].includes(next)&&next!==state.currentView)switchView(next);});
// Init
const initialView=location.hash.slice(1);if(['dashboard','associations','players','events','results','awards','portal'].includes(initialView))switchView(initialView);
loadData();
