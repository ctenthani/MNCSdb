import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';
test('TESSAM anonymous aggregate feed excludes TEST competitions, identities and provisional results',{skip:!process.env.PGLITE_MODULE},async()=>{
 const {PGlite}=await import(process.env.PGLITE_MODULE),db=new PGlite();try{
 await db.exec("create role anon;create role authenticated;create table competitions(id uuid primary key,name text,season text,starts_on date,ends_on date,status text);create table teams(id uuid,competition_id uuid);create table eligibility(competition_id uuid,athlete_id uuid,status text);create table fixtures(competition_id uuid,status text);insert into competitions values('11111111-1111-1111-1111-111111111111','Varsity Games','2026',null,null,'open'),('22222222-2222-2222-2222-222222222222','TEST Games','2026',null,null,'open');insert into eligibility values('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333','certified'),('11111111-1111-1111-1111-111111111111','44444444-4444-4444-4444-444444444444','submitted');insert into fixtures values('11111111-1111-1111-1111-111111111111','approved'),('11111111-1111-1111-1111-111111111111','submitted');");
 await db.exec(fs.readFileSync('integrations/tessam/public-stats.sql','utf8'));await db.exec('set role anon');
 const data=(await db.query('select mncs_public_statistics() data')).rows[0].data;
 assert.equal(data.summaries.length,1);assert.equal(data.summaries[0].athletes,1);assert.equal(data.summaries[0].completedFixtures,1);assert.equal(data.summaries[0].fixtures,2);assert(!JSON.stringify(data).includes('33333333'));
 await assert.rejects(()=>db.query('select * from eligibility'),/permission denied/);
 }finally{await db.close();}
});
