// Server-derived league summaries. Never read browser caches or return private contacts.
export function leagueSummary(data,fixtureCount,shareNames=false){
 const results=data.results||{},stats=new Map();let completed=0;
 const value=n=>Number.isFinite(Number(n))&&Number(n)>=0?Number(n):0;
 function player(name){name=String(name||'').trim().replace(/\s+/g,' ');if(!name)return null;const key=name.toLowerCase();if(!stats.has(key))stats.set(key,{name,singlesWins:0,doublesWins:0,legDifference:0,c180:0,c177:0,highOuts:0});return stats.get(key);}
 for(const r of Object.values(results)){
  if(!r||r.h===null||r.a===null||r.h===''||r.a===''||!Number.isFinite(Number(r.h))||!Number.isFinite(Number(r.a)))continue;completed++;
  for(const s of r.sheet?.singles||[]){if(s.hs===null||s.as===null||s.hs===''||s.as===''||!Number.isFinite(Number(s.hs))||!Number.isFinite(Number(s.as)))continue;for(const [name,own,other,side] of [[s.hp,+s.hs,+s.as,'h'],[s.ap,+s.as,+s.hs,'a']]){const p=player(name);if(!p)continue;p.singlesWins+=own>other?1:0;p.legDifference+=own-other;p.c180+=value(s[side+'180']);p.c177+=value(s[side+'177']);p.highOuts+=value(s[side+'Hi']);}}
  for(const s of r.sheet?.doubles||[]){if(s.hs===null||s.as===null||s.hs===''||s.as===''||!Number.isFinite(Number(s.hs))||!Number.isFinite(Number(s.as)))continue;for(const [names,own,other] of [[[s.h1,s.h2],+s.hs,+s.as],[[s.a1,s.a2],+s.as,+s.hs]])for(const name of new Set(names)){const p=player(name);if(p){p.doublesWins+=own>other?1:0;p.legDifference+=own-other;}}}
 }
 const keys=['singlesWins','doublesWins','legDifference','c180','c177','highOuts'];const rows=[...stats.values()].sort((a,b)=>{for(const k of keys)if(a[k]!==b[k])return b[k]-a[k];return a.name.localeCompare(b.name);});
 rows.forEach((p,i)=>p.rank=i&&keys.every(k=>p[k]===rows[i-1][k])?rows[i-1].rank:i+1);
 return {teams:Object.keys(data.teams||{}).length,athletes:stats.size,fixtures:Math.max(fixtureCount||0,completed),completedFixtures:completed,rankingRule:'Published league scoresheets only: singles wins, doubles wins, leg difference, 180s, 177s, high outs; equal metrics share rank. Excludes EGENCO and KK Singles.',publicConsent:shareNames===true,leaders:shareNames?rows.slice(0,50):[]};
}
