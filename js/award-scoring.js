(function(global){
// Proposed numerical conventions; MNCS must approve them before official use.
function scoreFinalists(finalists,{normalizationApproved=false,tallyCertified=false}={}){
 if(!normalizationApproved||!tallyCertified)throw Error('An approved normalization rule and certified vote tally are required.');
 if(finalists.length!==3||new Set(finalists.map(f=>f.id)).size!==3)throw Error('Exactly three distinct finalists are required. Resolve shortlist ties first.');
 for(const f of finalists){
  if(!Number.isFinite(f.judgeScore)||f.judgeScore<0||f.judgeScore>100)throw Error('Judge scores must be normalized to 0–100.');
  if(!Number.isSafeInteger(f.votes)||f.votes<0)throw Error('Votes must be nonnegative whole numbers.');
 }
 const total=finalists.reduce((n,f)=>n+f.votes,0);
 if(!Number.isSafeInteger(total)||total===0)throw Error('No valid certified vote total. Refer to MNCS; do not silently redistribute weights.');
 const rows=finalists.map(f=>({...f,publicScore:100*f.votes/total,totalScore:0.7*f.judgeScore+30*f.votes/total})).sort((a,b)=>b.totalScore-a.totalScore);
 let rank=1;rows.forEach((f,i)=>{if(i&&Math.abs(f.totalScore-rows[i-1].totalScore)>1e-9)rank=i+1;f.rank=rank;f.tied=rows.some(other=>other.id!==f.id&&Math.abs(other.totalScore-f.totalScore)<=1e-9);});return rows;
}
function scoreJudgesOnly(candidates,{amendmentApproved=false,policyDisclosed=false}={}){
 if(!amendmentApproved||!policyDisclosed)throw Error('Judges-only awards require an approved and disclosed policy amendment.');
 if(!candidates.length||new Set(candidates.map(c=>c.id)).size!==candidates.length)throw Error('Supply distinct candidates.');
 const rows=candidates.map(c=>{
  if(!Number.isFinite(c.judgeScore)||c.judgeScore<0||c.judgeScore>100)throw Error('Judge scores must be normalized to 0–100.');
  return {id:c.id,judgeScore:c.judgeScore,totalScore:c.judgeScore};
 }).sort((a,b)=>b.totalScore-a.totalScore);
 let rank=1;rows.forEach((c,i)=>{if(i&&Math.abs(c.totalScore-rows[i-1].totalScore)>1e-9)rank=i+1;c.rank=rank;c.tied=rows.some(other=>other.id!==c.id&&Math.abs(other.totalScore-c.totalScore)<=1e-9);});return rows;
}
function juniorEligibility(dateOfBirth,referenceDate){
 const valid=s=>{if(!/^\d{4}-\d{2}-\d{2}$/.test(s||''))return false;const d=new Date(s+'T00:00:00Z');return Number.isFinite(d.getTime())&&d.toISOString().slice(0,10)===s;};
 if(!referenceDate)return {eligible:null,reason:'MNCS must set the age reference date for this awards cycle.'};
 if(!valid(dateOfBirth)||!valid(referenceDate)||dateOfBirth>referenceDate)return {eligible:false,reason:'Valid birth and reference dates are required.'};
 const birth=dateOfBirth.split('-').map(Number),ref=referenceDate.split('-').map(Number);
 const age=ref[0]-birth[0]-(ref[1]<birth[1]||(ref[1]===birth[1]&&ref[2]<birth[2])?1:0);
 return {eligible:age<20,age,reason:age<20?'Under 20 on the reference date.':'Already 20 or older on the reference date.'};
}
global.MNCS_AWARD_SCORING={scoreFinalists,scoreJudgesOnly,juniorEligibility};
})(typeof window==='undefined'?globalThis:window);
