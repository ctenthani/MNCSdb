const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');require('../js/award-scoring.js');
const score=global.MNCS_AWARD_SCORING.scoreFinalists;
const sample=[{id:'A',judgeScore:90,votes:600},{id:'B',judgeScore:85,votes:300},{id:'C',judgeScore:80,votes:100}];const options={normalizationApproved:true,tallyCertified:true};
test('all 14 handbook categories are present',()=>{const c=JSON.parse(fs.readFileSync('data/award-categories.json'));assert.equal(c.length,14);assert.equal(new Set(c.map(r=>r.id)).size,14);});
test('70/30 proposed computation produces transparent final scores',()=>{const result=score(sample,options);assert.equal(result[0].totalScore,81);assert.equal(result[1].totalScore,68.5);assert.equal(result[2].totalScore,59);});
test('ranking requires approved normalization and certified votes',()=>{assert.throws(()=>score(sample));assert.throws(()=>score(sample,{normalizationApproved:true}));});
test('rejects invalid inputs, zero votes and unresolved shortlist size',()=>{assert.throws(()=>score(sample.slice(0,2),options));assert.throws(()=>score(sample.map(f=>({...f,votes:0})),options));assert.throws(()=>score(sample.map(f=>({...f,judgeScore:101})),options));assert.throws(()=>score(sample.map(f=>({...f,votes:1.5})),options));});
test('equal final scores preserve joint ranks',()=>{const rows=score(sample.map((f,i)=>({...f,judgeScore:80,votes:100})),options);assert(rows.every(r=>r.rank===1&&r.tied));});
test('judges-only requires an approved publicly disclosed amendment',()=>{
 const fn=global.MNCS_AWARD_SCORING.scoreJudgesOnly;
 assert.throws(()=>fn([{id:'A',judgeScore:90}]));assert.throws(()=>fn([{id:'A',judgeScore:90}],{amendmentApproved:true}));
});
test('fan votes never change disclosed judges-only awards',()=>{
 const fn=global.MNCS_AWARD_SCORING.scoreJudgesOnly,opts={amendmentApproved:true,policyDisclosed:true};
 assert.deepEqual(fn(sample,opts),fn(sample.map((f,i)=>({...f,votes:i===2?1000000:0})),opts));
 assert.equal(fn(sample,opts)[0].id,'A');
});
test('junior eligibility is strictly under 20 on an explicit reference date',()=>{
 const fn=global.MNCS_AWARD_SCORING.juniorEligibility;
 assert.equal(fn('2006-12-31','2026-12-31').eligible,false);
 assert.equal(fn('2007-01-01','2026-12-31').eligible,true);
 assert.equal(fn('2006-12-31','2026-12-30').eligible,true);
 assert.equal(fn('2007-02-30','2026-12-31').eligible,false);
 assert.equal(fn('2007-01-01',null).eligible,null);
});
