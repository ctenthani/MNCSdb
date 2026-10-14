import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';
test('trial cleanup enforces role, explicit labels, stale previews and reversible atomic removal',{skip:!process.env.PGLITE_MODULE},async()=>{
 const {PGlite}=await import(process.env.PGLITE_MODULE),pg=new PGlite();
 try{
 await pg.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('test.user',true),'')::uuid$$;create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(id uuid default gen_random_uuid(),bucket_id text,name text);create function storage.foldername(text) returns text[] language sql immutable as $$select string_to_array($1,'/')$$;grant usage on schema public,auth to anon,authenticated,service_role;alter default privileges in schema public grant all on tables to anon,authenticated,service_role;`);
 await pg.exec(fs.readFileSync('supabase/INSTALL_ALL.sql','utf8'));await pg.exec(fs.readFileSync('supabase/v1.2-trial-cleanup.sql','utf8'));await pg.exec(fs.readFileSync('supabase/v1.3-junior-cutoff.sql','utf8'));
 await assert.rejects(()=>pg.exec("insert into award_cycles(year,age_reference_date) values(2027,'2017-12-31')"),/31 December/);
 await pg.exec("insert into award_cycles(year,age_reference_date) values(2027,'2027-12-31')");
 const admin='10000000-0000-0000-0000-000000000001',reviewer='10000000-0000-0000-0000-000000000002',trial='20000000-0000-0000-0000-000000000001',real='20000000-0000-0000-0000-000000000002';
 await pg.query('insert into auth.users(id,email) values($1,$2),($3,$4)',[admin,'admin@example.org',reviewer,'reviewer@example.org']);await pg.query("insert into profiles(id,role,email) values($1,'admin','admin@example.org'),($2,'reviewer','reviewer@example.org')",[admin,reviewer]);
 await pg.query("insert into submissions(id,association_id,created_by,kind,period,payload) values($1,'TRIAL',$3,'Other request','2026','{\"title\":\"Trial\",\"summary\":\"Test explanation\"}'),($2,'REAL',$3,'Other request','2026','{\"title\":\"Genuine\",\"summary\":\"Real explanation\"}')",[trial,real,reviewer]);
 const login=async id=>{await pg.exec('reset role');await pg.query("select set_config('test.user',$1,false)",[id]);await pg.exec('set role authenticated');};
 const list=async()=>(await pg.query('select trial_cleanup_list() data')).rows[0].data;
 const remove=async records=>pg.query('select remove_trial_records($1::jsonb)',[JSON.stringify(records)]);
 await login(reviewer);await assert.rejects(()=>list(),/administrator/);await assert.rejects(()=>pg.query('select * from trial_recovery'),/permission denied/);
 await login(admin);let data=await list();assert.equal(data.records.length,2);assert(data.records.every(r=>!r.trial));await assert.rejects(()=>remove(data.records.filter(r=>r.id===trial)),/explicitly marked/);
 await pg.query('select tag_trial_record($1,$2,true)',['submissions',trial]);data=await list();const chosen=data.records.filter(r=>r.trial);
 await pg.exec('reset role');await pg.query("update submissions set payload='{\"title\":\"Changed trial\",\"summary\":\"Test explanation\"}' where id=$1",[trial]);await login(admin);await assert.rejects(()=>remove(chosen),/Record changed/);
 data=await list();await assert.rejects(()=>remove(data.records),/explicitly marked/);assert.equal((await list()).records.length,2);assert.equal((await list()).recovery.length,0);
 await remove(data.records.filter(r=>r.trial));data=await list();assert.equal(data.records.length,1);assert.equal(data.records[0].id,real);assert.equal(data.recovery.length,1);
 await pg.query('select restore_trial_record($1)',[data.recovery[0].id]);data=await list();assert.equal(data.records.length,2);assert.equal(data.recovery.length,0);assert(data.records.find(r=>r.id===trial).trial);
 await pg.exec('reset role');const checked=(await pg.query('select account_deletion_check($1) data',[reviewer])).rows[0].data;assert(checked.blockers.some(r=>r.records.includes('submissions')));await assert.rejects(()=>pg.query('select prepare_account_deletion($1,$2)',[reviewer,'reviewer@example.org']),/Linked records/);await assert.rejects(()=>pg.query('select account_deletion_check($1)',[admin]),/protected/);
 await login(admin);await assert.rejects(()=>pg.query('select prepare_account_deletion($1,$2)',[reviewer,'reviewer@example.org']),/permission denied/);
 }finally{await pg.close();}
});

