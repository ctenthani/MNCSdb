// MNCS Players & Associations Database - Frontend

const state = {
  associations: [],
  players: [],
  events: [],
  results: [],
  currentView: 'dashboard',
  searchQuery: ''
};

async function loadData() {
  try {
    const [assocRes, playersRes, eventsRes, resultsRes] = await Promise.all([
      fetch('data/associations.json'),
      fetch('data/players.json'),
      fetch('data/events.json'),
      fetch('data/results.json')
    ]);
    state.associations = await assocRes.json();
    state.players = await playersRes.json();
    state.events = await eventsRes.json();
    state.results = await resultsRes.json();

    if (window.MNCS_DB) {
      const {data,error} = await window.MNCS_DB.from('registry').select('*');
      if(error) throw error;
      ['associations','players','events','results'].forEach(k => state[k] = data.filter(r=>r.collection===k).map(r=>r.payload));
      document.getElementById('data-banner').textContent = window.MNCS_DB.demo?'DEMO ONLY · data in this page session; no live accounts or records':'Connected registry · sourced candidates and registered associations remain subject to MNCS verification';
    }
    // Public data must not contain private athlete or official contact details.
    state.players.forEach(p=>{delete p.phone;delete p.dateOfBirth;});
    state.associations.forEach(a=>{delete a.phone;delete a.email;});
    const today = new Intl.DateTimeFormat('en-CA', {timeZone:'Africa/Blantyre',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
    state.events.forEach(e=>{
      e.confirmedStatus=e.status;
      if(!['Cancelled','Postponed'].includes(e.status)) e.status=e.startDate>today?'Upcoming':(e.endDate||e.startDate)<today?'Past':'Ongoing';
    });
    // Escape strings before interpolation into HTML.
    const safe = v => typeof v==='string'?v.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])):v;
    [state.associations,state.players,state.events,state.results].forEach(rows=>rows.forEach(r=>Object.keys(r).forEach(k=>{r[k]=safe(r[k]);})));
    // Update player counts
    state.associations.forEach(a => {
      a.playerCount = state.players.filter(p => p.associationId === a.id).length;
    });

    render();
  } catch (err) {
    console.error('Failed to load data:', err);
    document.querySelector('main').innerHTML = `
      <div class="bg-red-50 border border-red-200 text-red-800 rounded-xl p-6 text-center">
        <p class="font-semibold">Could not load database files.</p>
        <p class="text-sm mt-2">Make sure the data/ folder is present and you are serving the site (not opening index.html directly as a file).</p>
      </div>`;
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
  renderCurrentView();
}

function render() {
  // Stats
  document.getElementById('stat-associations').textContent = state.associations.length;
  document.getElementById('stat-players').textContent = state.players.length;
  document.getElementById('stat-events').textContent = state.events.length;
  document.getElementById('stat-results').textContent = state.results.length;

  // Populate filters
  const assocFilter = document.getElementById('player-assoc-filter');
  if (assocFilter.options.length <= 1) {
    state.associations
      .sort((a, b) => a.name.localeCompare(b.name))
      .forEach(a => {
        const opt = document.createElement('option');
        opt.value = a.id;
        opt.textContent = a.shortName || a.name;
        assocFilter.appendChild(opt);
      });
  }

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
      <div class="flex items-center gap-3 p-2 rounded-lg hover:bg-slate-50 cursor-pointer" onclick="showPlayerDetail('${p.id}')">
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
      <div class="p-3 rounded-lg border border-slate-100 hover:border-green-200 cursor-pointer" onclick="showEventDetail('${e.id}')">
        <div class="flex items-start justify-between gap-2">
          <p class="font-medium text-sm">${e.name}</p>
          <span class="status-badge status-${e.status}">${e.status}</span>
        </div>
        <p class="text-xs text-slate-500 mt-1">${assoc.shortName} • ${e.startDate}</p>
      </div>`;
  }).join('') || '<p class="text-sm text-slate-400">No upcoming events.</p>';
}

function renderAssociations(q) {
  const statusFilter = document.getElementById('assoc-status-filter').value;
  let list = state.associations;

  if (statusFilter) list = list.filter(a => a.status === statusFilter);
  if (q) {
    list = list.filter(a =>
      a.name.toLowerCase().includes(q) ||
      (a.shortName && a.shortName.toLowerCase().includes(q)) ||
      a.sport.toLowerCase().includes(q)
    );
  }

  document.getElementById('associations-list').innerHTML = list.map(a => `
    <div class="bg-white rounded-xl border border-slate-100 shadow-sm p-4 card-hover cursor-pointer" onclick="showAssociationDetail('${a.id}')">
      <div class="flex items-start justify-between gap-2">
        <div>
          <h3 class="font-semibold text-sm leading-tight">${a.name}</h3>
          <p class="text-xs text-slate-500 mt-0.5">${a.shortName} • ${a.sport}</p>
        </div>
        <span class="status-badge status-${a.status}">${a.status}</span>
      </div>
      <div class="mt-3 flex items-center justify-between text-xs text-slate-500">
        <span>${a.playerCount} players</span>
        <span>AGM: ${a.lastAGM || '—'}</span>
      </div>
      ${a.strategicPlan ? '<p class="mt-2 text-xs text-green-700">✓ Strategic plan submitted</p>' : '<p class="mt-2 text-xs text-amber-600">No strategic plan on file</p>'}
    </div>
  `).join('') || '<p class="col-span-full text-center text-slate-400 py-8">No associations found.</p>';
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
      <tr class="cursor-pointer" onclick="showPlayerDetail('${p.id}')">
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
      <div class="bg-white rounded-xl border border-slate-100 shadow-sm p-4 card-hover cursor-pointer" onclick="showEventDetail('${e.id}')">
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
        <td class="font-medium">${r.teamName || (player ? player.firstName + ' ' + player.lastName : r.playerId)}</td>
        <td>${event ? event.name : r.eventId}</td>
        <td>${r.category || '—'}</td>
        <td>${r.position ?? '—'}</td>
        <td class="${medalClass}">${r.medal || '—'}</td>
        <td>${r.performance || '—'} ${r.unit || ''}</td>
      </tr>`;
  }).join('');

  document.getElementById('results-list').innerHTML = `
    <table>
      <thead>
        <tr>
          <th>Athlete</th>
          <th>Event</th>
          <th>Category</th>
          <th>Pos</th>
          <th>Medal</th>
          <th>Performance</th>
        </tr>
      </thead>
      <tbody>
        ${rows || '<tr><td colspan="6" class="text-center text-slate-400 py-8">No results found.</td></tr>'}
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
    <p><span class="text-slate-500">Email:</span> ${a.email || '—'}</p>
    <p><span class="text-slate-500">Phone:</span> ${a.phone || '—'}</p>
    <p><span class="text-slate-500">Last AGM:</span> ${a.lastAGM || '—'}</p>
    <p><span class="text-slate-500">Strategic Plan:</span> ${a.strategicPlan ? 'Submitted' : 'Not on file'}</p>
    <p><span class="text-slate-500">Registered Players (sample):</span> ${a.playerCount}</p>
    ${a.website && /^https?:\/\//i.test(a.website) ? `<p><span class="text-slate-500">Website:</span> <a href="${a.website}" target="_blank" rel="noopener noreferrer" class="text-green-700 underline">${a.website}</a></p>` : ''}
  `;
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

function openModal() {
  document.getElementById('modal').classList.add('show');
}
function closeModal() {
  document.getElementById('modal').classList.remove('show');
}

// Event listeners
document.querySelectorAll('.nav-btn').forEach(btn => {
  btn.addEventListener('click', () => switchView(btn.dataset.view));
});

document.getElementById('mobile-menu-btn').addEventListener('click', () => {
  document.getElementById('mobile-nav').classList.toggle('hidden');
});

document.getElementById('global-search').addEventListener('input', (e) => {
  state.searchQuery = e.target.value;
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

// Init
loadData();
