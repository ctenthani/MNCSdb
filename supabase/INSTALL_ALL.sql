-- MNCS v1.1 COMPLETE INSTALLER
-- Run this ONE file in Supabase SQL Editor. Replaces running individual migrations.
-- Supports a new project or the earlier app schemas; preserves records and setup state.
-- All changes commit together. If an existing incompatible record causes an error,
-- the transaction rolls back: inspect the error rather than deleting records.
-- Sourced association candidates are included; no accounts, passwords or secrets.
BEGIN;
-- Component: schema.sql
-- Run once in a new Supabase project. Provision auth users in the dashboard,
-- then insert their profiles here using a trusted administrator connection.
create table if not exists public.profiles (
 id uuid primary key references auth.users(id),
 role text not null check(role in ('admin','reviewer','association')),
 association_id text,
 check(role <> 'association' or association_id is not null)
);
create table if not exists public.registry (
 collection text not null check(collection in ('associations','players','events','results')),
 id text not null,
 payload jsonb not null,
 primary key(collection,id)
);
create table if not exists public.submissions (
 id uuid primary key default gen_random_uuid(),
 association_id text not null,
 created_by uuid not null references auth.users(id),
 kind text not null check(kind in ('Profile update','Constitution','AGM minutes','Strategic plan','Annual report')),
 period text not null check(length(trim(period)) between 1 and 80),
 payload jsonb not null default '{}',
 document_path text,
 status text not null default 'Draft' check(status in ('Draft','Submitted','Returned','Approved')),
 review_comment text,
 history jsonb not null default '[]',
 created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
alter table public.registry enable row level security;
alter table public.submissions enable row level security;
create or replace function public.is_reviewer() returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from profiles where id=auth.uid() and role in ('admin','reviewer')); $$;
drop policy if exists profile_self on public.profiles;
create policy profile_self on public.profiles for select to authenticated using(id=auth.uid());
drop policy if exists registry_public on public.registry;
create policy registry_public on public.registry for select using(true);
drop policy if exists submission_read on public.submissions;
create policy submission_read on public.submissions for select to authenticated using(public.is_reviewer() or association_id=(select association_id from profiles where id=auth.uid()));
drop policy if exists submission_create on public.submissions;
create policy submission_create on public.submissions for insert to authenticated with check(
 created_by=auth.uid() and status='Draft' and history='[]'::jsonb and review_comment is null
 and association_id=(select association_id from profiles where id=auth.uid() and role='association')
 and (document_path is null or document_path=association_id||'/'||id::text||'.pdf')
 and (kind='Profile update' or document_path is not null)
);
-- No direct update/delete policies. Status changes use this guarded transaction.
create or replace function public.transition_submission(submission_id uuid,next_status text,comment text default '') returns void
language plpgsql security definer set search_path=public as $$
declare s submissions; p profiles; merged jsonb;
begin
 select * into p from profiles where id=auth.uid();
 if p.id is null then raise exception 'Authorised account required'; end if;
 select * into s from submissions where id=submission_id for update;
 if s.id is null then raise exception 'Submission not found'; end if;
 if next_status='Submitted' then
  if p.role<>'association' or p.association_id<>s.association_id or s.status not in ('Draft','Returned') then raise exception 'Cannot submit this record'; end if;
 elsif next_status in ('Approved','Returned') then
  if p.role not in ('admin','reviewer') or s.status<>'Submitted' then raise exception 'Cannot review this record'; end if;
  if next_status='Returned' and length(trim(comment))=0 then raise exception 'Correction comment required'; end if;
 else raise exception 'Invalid transition'; end if;
 update submissions set status=next_status,review_comment=comment,
 history=history||jsonb_build_array(jsonb_build_object('status',next_status,'comment',comment,'actor',auth.uid(),'at',now())) where id=submission_id;
 if next_status='Approved' and s.kind='Profile update' then
  -- Publish only selected fields; phone/email stay private in the submission.
  merged=jsonb_strip_nulls(jsonb_build_object('president',nullif(s.payload->>'president',''),'generalSecretary',nullif(s.payload->>'generalSecretary',''),'termStart',nullif(s.payload->>'termStart',''),'termEnd',nullif(s.payload->>'termEnd',''),'committee',nullif(s.payload->>'committee',''),'affiliation',nullif(s.payload->>'affiliation',''),'districts',nullif(s.payload->>'districts',''),'lastAGM',nullif(s.payload->>'lastAGM',''),'verificationStatus','Approved'));
  update registry set payload=payload||merged where collection='associations' and id=s.association_id;
  if not found then raise exception 'Association must be registered before approval'; end if;
 end if;
end $$;
revoke all on function public.transition_submission(uuid,text,text) from public;
grant execute on function public.transition_submission(uuid,text,text) to authenticated;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('association-documents','association-documents',false,10485760,array['application/pdf']) on conflict(id) do update set public=false,file_size_limit=10485760,allowed_mime_types=array['application/pdf'];
drop policy if exists document_read on storage.objects;
create policy document_read on storage.objects for select to authenticated using(bucket_id='association-documents' and (public.is_reviewer() or (storage.foldername(name))[1]=(select association_id from profiles where id=auth.uid())));
drop policy if exists document_upload on storage.objects;
create policy document_upload on storage.objects for insert to authenticated with check(bucket_id='association-documents' and (storage.foldername(name))[1]=(select association_id from profiles where id=auth.uid() and role='association'));

-- Component: v0.3-migration.sql
-- Run AFTER schema.sql. For an existing v0.2 database run only this migration.
create table if not exists public.reporting_requirements (
 id uuid primary key default gen_random_uuid(),
 kind text not null check(kind in ('Annual report','AGM minutes','Strategic plan','Constitution')),
 period text not null check(length(trim(period)) between 1 and 80),
 due_date date not null,
 association_id text,
 created_at timestamptz not null default now()
);
create unique index if not exists requirement_key on public.reporting_requirements(kind,period,coalesce(association_id,''));
alter table public.reporting_requirements enable row level security;
drop policy if exists requirement_read on public.reporting_requirements;
create policy requirement_read on public.reporting_requirements for select to authenticated
 using(public.is_reviewer() or association_id is null or association_id=(select association_id from profiles where id=auth.uid()));
drop policy if exists requirement_create on public.reporting_requirements;
create policy requirement_create on public.reporting_requirements for insert to authenticated with check(public.is_reviewer());
create or replace function public.edit_submission(submission_id uuid,new_payload jsonb,new_document_path text default null) returns void
language plpgsql security definer set search_path=public as $$
declare s submissions; p profiles;
begin
 select * into p from profiles where id=auth.uid();
 select * into s from submissions where id=submission_id for update;
 if p.id is null or p.role<>'association' or s.id is null or p.association_id<>s.association_id or s.status not in ('Draft','Returned') then raise exception 'Only your editable drafts or returned records may be changed'; end if;
 if jsonb_typeof(new_payload)<>'object' or octet_length(new_payload::text)>20000 then raise exception 'Invalid profile payload'; end if;
 if coalesce(new_payload->>'termStart','')<>'' and coalesce(new_payload->>'termEnd','')<>'' and (new_payload->>'termEnd')::date<(new_payload->>'termStart')::date then raise exception 'Invalid leadership term'; end if;
 if new_document_path is distinct from s.document_path and new_document_path is not null then
  if left(new_document_path,length(s.association_id)+1)<>s.association_id||'/' or not exists(select 1 from storage.objects where bucket_id='association-documents' and name=new_document_path) then raise exception 'Invalid supporting document'; end if;
 end if;
 if s.kind<>'Profile update' and new_document_path is null then raise exception 'Supporting document required'; end if;
 update submissions set payload=new_payload,document_path=new_document_path,
 history=history||jsonb_build_array(jsonb_build_object('action','Edited','previousPayload',s.payload,'previousDocument',s.document_path,'actor',auth.uid(),'at',now())) where id=submission_id;
end $$;
revoke all on function public.edit_submission(uuid,jsonb,text) from public;
grant execute on function public.edit_submission(uuid,jsonb,text) to authenticated;

-- Component: v0.4-migration.sql
-- Run after schema.sql and v0.3-migration.sql. One-time migration.
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists email text;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from profiles where id=auth.uid() and role='admin');
$$;
drop policy if exists admin_directory on public.profiles;
create policy admin_directory on public.profiles for select to authenticated using(public.is_admin());
create table if not exists public.initial_admin_setup (
 id integer primary key check(id=1),
 claim uuid,
 completed boolean not null default false
);
insert into public.initial_admin_setup(id) values(1) on conflict(id) do nothing;
alter table public.initial_admin_setup enable row level security;
-- No browser policy. Claims are managed only by the server using a private key.
create or replace function public.claim_initial_admin(operation_id uuid) returns boolean language plpgsql security definer set search_path=public as $$
begin
 perform 1 from initial_admin_setup where id=1 for update;
 if exists(select 1 from profiles where role='admin') then return false; end if;
 update initial_admin_setup set claim=operation_id where id=1 and claim is null and not completed;
 return found;
end $$;
create or replace function public.release_initial_admin(operation_id uuid) returns void language sql security definer set search_path=public as $$
 update initial_admin_setup set claim=null where id=1 and claim=operation_id and not completed;
$$;
create or replace function public.complete_initial_admin(operation_id uuid,user_id uuid,user_email text,user_name text) returns void language plpgsql security definer set search_path=public as $$
begin
 perform 1 from initial_admin_setup where id=1 and claim=operation_id and not completed for update;
 if not found or exists(select 1 from profiles where role='admin') then raise exception 'Initial setup is unavailable'; end if;
 insert into profiles(id,role,email,display_name) values(user_id,'admin',user_email,user_name);
 update initial_admin_setup set completed=true where id=1;
end $$;
revoke all on function public.claim_initial_admin(uuid) from public,anon,authenticated;
revoke all on function public.release_initial_admin(uuid) from public,anon,authenticated;
revoke all on function public.complete_initial_admin(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.claim_initial_admin(uuid),public.release_initial_admin(uuid),public.complete_initial_admin(uuid,uuid,text,text) to service_role;

-- Component: v0.5-migration.sql
-- Run once after v0.4. Draft award nominations use the private submission workflow.
alter table public.submissions drop constraint if exists submissions_kind_check;
alter table public.submissions add constraint submissions_kind_check check(kind in ('Profile update','Constitution','AGM minutes','Strategic plan','Annual report','Award nomination','Funding request','Travel abroad','MRA clearance','Other request'));
drop index if exists public.unique_current_submission;
create unique index if not exists unique_current_submission on public.submissions(association_id,kind,period) where status in ('Draft','Submitted','Approved') and kind not in ('Award nomination','Funding request','Travel abroad','MRA clearance','Other request');
create unique index if not exists unique_award_nomination on public.submissions(association_id,period,(payload->>'categoryId'),lower(trim(payload->>'nomineeName'))) where kind='Award nomination' and status in ('Draft','Submitted','Approved');
alter table public.submissions drop constraint if exists nomination_shape;
alter table public.submissions add constraint nomination_shape check(kind<>'Award nomination' or (
 period ~ '^[0-9]{4}$' and period between '2024' and '2100'
 and coalesce(payload->>'categoryId','') in ('junior-male','junior-female','national-team','association','development-programme','sportsman','sportswoman','disability-male','disability-female','coach','administrator','journalist-print','journalist-electronic')
 and length(trim(coalesce(payload->>'nomineeName',''))) between 1 and 160
 and length(trim(coalesce(payload->>'description',''))) between 1 and 2000
 and length(trim(coalesce(payload->>'motivation',''))) between 1 and 12000
 and coalesce(payload->>'declaration','')='true'
 and document_path is not null
));
-- Approval in submissions denotes dossier screening only, never a category win.

-- Component: v0.6-migration.sql
-- Cycle settings are explicit; no age reference date is silently assumed.
create table if not exists public.award_cycles (
 year integer primary key check(year between 2024 and 2100),
 age_reference_date date,
 scoring_policy text not null default 'handbook_70_30' check(scoring_policy in ('handbook_70_30','judges_only')),
 amendment_approved boolean not null default false,
 policy_disclosed boolean not null default false,
 official_ranking_enabled boolean not null default false,
 check(scoring_policy<>'judges_only' or not official_ranking_enabled or (amendment_approved and policy_disclosed))
);
alter table public.award_cycles enable row level security;
drop policy if exists award_cycle_read on public.award_cycles;
create policy award_cycle_read on public.award_cycles for select using(true);
drop policy if exists award_cycle_admin on public.award_cycles;
create policy award_cycle_admin on public.award_cycles for all to authenticated using(public.is_admin()) with check(public.is_admin());
create or replace function public.validate_junior_submission() returns trigger language plpgsql security definer set search_path=public as $$
declare reference_date date; birthday date; years integer;
begin
 if new.kind='Award nomination' and new.status in ('Submitted','Approved') and new.payload->>'categoryId' in ('junior-male','junior-female') then
  select age_reference_date into reference_date from award_cycles where year=new.period::integer;
  if reference_date is null then raise exception 'MNCS must configure the junior age reference date before this nomination can be submitted'; end if;
  if coalesce(new.payload->>'dateOfBirth','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Junior nomination requires a date of birth'; end if;
  birthday=(new.payload->>'dateOfBirth')::date;
  if birthday>reference_date then raise exception 'Birth date cannot follow the age reference date'; end if;
  years=extract(year from reference_date)::integer-extract(year from birthday)::integer;
  if to_char(reference_date,'MMDD')<to_char(birthday,'MMDD') then years=years-1; end if;
  if years>=20 then raise exception 'Junior nominee must be strictly under 20 on the cycle reference date'; end if;
 end if;
 return new;
end $$;
drop trigger if exists validate_junior_submission on public.submissions;
create trigger validate_junior_submission before insert or update on public.submissions for each row execute function public.validate_junior_submission();

-- Component: v0.6.2-migration.sql
-- Allow signed-in MNCS administrators to register associations from the site.
-- Other roles cannot insert registry records. Initial registration contains
-- public association details only; document review remains a separate workflow.
drop policy if exists registry_admin_register on public.registry;
create policy registry_admin_register on public.registry for insert to authenticated
with check (
 public.is_admin()
 and collection='associations'
 and id ~ '^[A-Za-z0-9_-]{1,80}$'
 and jsonb_typeof(payload)='object'
 and payload->>'id'=id
 and jsonb_typeof(payload->'name')='string'
 and length(trim(payload->>'name')) between 1 and 160
 and jsonb_typeof(payload->'shortName')='string'
 and length(trim(payload->>'shortName')) between 1 and 40
 and jsonb_typeof(payload->'sport')='string'
 and length(trim(payload->>'sport')) between 1 and 100
 and payload->>'status'='Under Review'
 and payload->>'verificationStatus'='Awaiting verification'
 and payload->'strategicPlan'='false'::jsonb
 and payload - array['id','name','shortName','sport','status','verificationStatus','strategicPlan'] = '{}'::jsonb
);

-- Component: v0.7-migration.sql
-- Edit only public association basics, preserving document and review history.
create or replace function public.edit_association_basics(association_key text,association_name text,abbreviation text,sport_name text) returns void
language plpgsql security definer set search_path=public as $$
begin
 if not public.is_admin() then raise exception 'MNCS administrator required'; end if;
 if association_key !~ '^[A-Za-z0-9_-]{1,80}$'
 or coalesce(length(trim(association_name)),0) not between 1 and 160
 or coalesce(length(trim(abbreviation)),0) not between 1 and 40
 or coalesce(length(trim(sport_name)),0) not between 1 and 100 then raise exception 'Invalid association details'; end if;
 update registry set payload=payload||jsonb_build_object('name',trim(association_name),'shortName',trim(abbreviation),'sport',trim(sport_name)) where collection='associations' and id=association_key;
 if not found then raise exception 'Association not found'; end if;
end $$;
revoke all on function public.edit_association_basics(text,text,text,text) from public,anon;
grant execute on function public.edit_association_basics(text,text,text,text) to authenticated;

-- Component: researched-associations.sql
-- Sourced candidates, not a certified list of current MNCS affiliates.
-- MOC directory researched 2 October 2026; preserves existing records.
-- Skips existing matching names/sports and never overwrites owner-entered data.
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-01','{"id": "RESEARCH-01", "name": "Amateur Athletic Association of Malawi", "shortName": "Athletics", "sport": "Athletics", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Amateur Athletic Association of Malawi') or lower(trim(payload->>'sport'))=lower('Athletics'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-02','{"id": "RESEARCH-02", "name": "Basketball Association of Malawi", "shortName": "Basketball", "sport": "Basketball", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Basketball Association of Malawi') or lower(trim(payload->>'sport'))=lower('Basketball'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-03','{"id": "RESEARCH-03", "name": "Canoeing Association of Malawi", "shortName": "Canoeing", "sport": "Canoeing", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Canoeing Association of Malawi') or lower(trim(payload->>'sport'))=lower('Canoeing'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-04','{"id": "RESEARCH-04", "name": "Cycling Association of Malawi", "shortName": "Cycling", "sport": "Cycling", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Cycling Association of Malawi') or lower(trim(payload->>'sport'))=lower('Cycling'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-05','{"id": "RESEARCH-05", "name": "Football Association of Malawi", "shortName": "Football", "sport": "Football", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Football Association of Malawi') or lower(trim(payload->>'sport'))=lower('Football'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-06','{"id": "RESEARCH-06", "name": "Judo Association of Malawi", "shortName": "Judo", "sport": "Judo", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Judo Association of Malawi') or lower(trim(payload->>'sport'))=lower('Judo'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-07','{"id": "RESEARCH-07", "name": "Malawi Aquatic Union", "shortName": "Aquatics", "sport": "Aquatics", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Malawi Aquatic Union') or lower(trim(payload->>'sport'))=lower('Aquatics'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-08','{"id": "RESEARCH-08", "name": "Malawi Boxing Association", "shortName": "Boxing", "sport": "Boxing", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Malawi Boxing Association') or lower(trim(payload->>'sport'))=lower('Boxing'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-09','{"id": "RESEARCH-09", "name": "Malawi Handball Association", "shortName": "Handball", "sport": "Handball", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Malawi Handball Association') or lower(trim(payload->>'sport'))=lower('Handball'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-10','{"id": "RESEARCH-10", "name": "Hockey Association of Malawi", "shortName": "Hockey", "sport": "Hockey", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Hockey Association of Malawi') or lower(trim(payload->>'sport'))=lower('Hockey'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-11','{"id": "RESEARCH-11", "name": "Lawn Tennis Association of Malawi", "shortName": "Tennis", "sport": "Tennis", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Lawn Tennis Association of Malawi') or lower(trim(payload->>'sport'))=lower('Tennis'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-12','{"id": "RESEARCH-12", "name": "Table Tennis Association of Malawi", "shortName": "Table tennis", "sport": "Table tennis", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Table Tennis Association of Malawi') or lower(trim(payload->>'sport'))=lower('Table tennis'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-13','{"id": "RESEARCH-13", "name": "Taekwondo Association of Malawi", "shortName": "Taekwondo", "sport": "Taekwondo", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Taekwondo Association of Malawi') or lower(trim(payload->>'sport'))=lower('Taekwondo'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-14','{"id": "RESEARCH-14", "name": "Weightlifting Association of Malawi", "shortName": "Weightlifting", "sport": "Weightlifting", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Weightlifting Association of Malawi') or lower(trim(payload->>'sport'))=lower('Weightlifting'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-15','{"id": "RESEARCH-15", "name": "Volleyball Association of Malawi", "shortName": "Volleyball", "sport": "Volleyball", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Volleyball Association of Malawi') or lower(trim(payload->>'sport'))=lower('Volleyball'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-16','{"id": "RESEARCH-16", "name": "Wrestling Association of Malawi", "shortName": "Wrestling", "sport": "Wrestling", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Wrestling Association of Malawi') or lower(trim(payload->>'sport'))=lower('Wrestling'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-17','{"id": "RESEARCH-17", "name": "Archery Association of Malawi", "shortName": "Archery", "sport": "Archery", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Archery Association of Malawi') or lower(trim(payload->>'sport'))=lower('Archery'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-18','{"id": "RESEARCH-18", "name": "Rowing Association of Malawi", "shortName": "Rowing", "sport": "Rowing", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Rowing Association of Malawi') or lower(trim(payload->>'sport'))=lower('Rowing'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-19','{"id": "RESEARCH-19", "name": "Bowls Association of Malawi", "shortName": "Bowls", "sport": "Bowls", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Bowls Association of Malawi') or lower(trim(payload->>'sport'))=lower('Bowls'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-20','{"id": "RESEARCH-20", "name": "Netball Association of Malawi", "shortName": "Netball", "sport": "Netball", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Netball Association of Malawi') or lower(trim(payload->>'sport'))=lower('Netball'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-21','{"id": "RESEARCH-21", "name": "Squash Association of Malawi", "shortName": "Squash", "sport": "Squash", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Squash Association of Malawi') or lower(trim(payload->>'sport'))=lower('Squash'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-22','{"id": "RESEARCH-22", "name": "Malawi Disabled Sports Association", "shortName": "Disability sport", "sport": "Disability sport", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Malawi Disabled Sports Association') or lower(trim(payload->>'sport'))=lower('Disability sport'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-23','{"id": "RESEARCH-23", "name": "Chess Association of Malawi", "shortName": "Chess", "sport": "Chess", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Chess Association of Malawi') or lower(trim(payload->>'sport'))=lower('Chess'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-24','{"id": "RESEARCH-24", "name": "Darts Association of Malawi", "shortName": "Darts", "sport": "Darts", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Darts Association of Malawi') or lower(trim(payload->>'sport'))=lower('Darts'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-25','{"id": "RESEARCH-25", "name": "Malawi School Sport Association", "shortName": "School sport", "sport": "School sport", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Malawi School Sport Association') or lower(trim(payload->>'sport'))=lower('School sport'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-26','{"id": "RESEARCH-26", "name": "Malawi Wushu Federation", "shortName": "Wushu", "sport": "Wushu", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Malawi Wushu Federation') or lower(trim(payload->>'sport'))=lower('Wushu'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-27','{"id": "RESEARCH-27", "name": "Olympians Association of Malawi", "shortName": "Multisport", "sport": "Multisport", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Olympians Association of Malawi') or lower(trim(payload->>'sport'))=lower('Multisport'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-28','{"id": "RESEARCH-28", "name": "Tertiary Students Sports Association of Malawi", "shortName": "Tertiary sport", "sport": "Tertiary sport", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('Tertiary Students Sports Association of Malawi') or lower(trim(payload->>'sport'))=lower('Tertiary sport'))) on conflict(collection,id) do nothing;
insert into public.registry(collection,id,payload) select 'associations','RESEARCH-29','{"id": "RESEARCH-29", "name": "University Sports Association of Malawi", "shortName": "University sport", "sport": "University sport", "status": "Under Review", "verificationStatus": "MNCS affiliation not yet confirmed", "strategicPlan": false, "sourceUrl": "https://www.moc.org.mw/associations/", "sourceTitle": "Malawi Olympic Committee association directory", "researchedOn": "2026-10-02", "sourceNote": "Listed by MOC; current MNCS affiliation and names require verification. Display abbreviation is a sport label, not an official acronym."}'::jsonb where not exists(select 1 from public.registry where collection='associations' and (lower(trim(payload->>'name'))=lower('University Sports Association of Malawi') or lower(trim(payload->>'sport'))=lower('University sport'))) on conflict(collection,id) do nothing;

-- Component: v0.9-migration.sql
-- V0.9 reviewed sports operations. Private master records; allowlisted public projections.
create table if not exists public.sport_records (
 id uuid primary key default gen_random_uuid(),
 association_id text not null,
 kind text not null check(kind in ('Athlete','Team','Competition','Fixture','Result')),
 payload jsonb not null check(jsonb_typeof(payload)='object'),
 published_payload jsonb,
 status text not null default 'Draft' check(status in ('Draft','Submitted','Returned','Approved','Archived')),
 created_by uuid not null references auth.users(id),
 updated_by uuid not null references auth.users(id),
 review_comment text not null default '',
 history jsonb not null default '[]',
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index if not exists sport_records_association on public.sport_records(association_id,kind,status);
alter table public.sport_records enable row level security;
drop policy if exists sport_records_read on public.sport_records;
create policy sport_records_read on public.sport_records for select to authenticated
 using(public.is_reviewer() or association_id=(select association_id from public.profiles where id=auth.uid()));
revoke all on public.sport_records from anon,authenticated;
grant select on public.sport_records to authenticated;

create table if not exists public.ranking_policies (
 id uuid primary key default gen_random_uuid(),
 association_id text not null,
 name text not null check(length(trim(name)) between 1 and 160),
 discipline text not null check(length(trim(discipline)) between 1 and 100),
 category text not null check(length(trim(category)) between 1 and 100),
 season integer not null check(season between 2024 and 2100),
 placing_points jsonb not null,
 max_results integer not null check(max_results between 1 and 100),
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now()
);
alter table public.ranking_policies enable row level security;
drop policy if exists ranking_policy_read on public.ranking_policies;
create policy ranking_policy_read on public.ranking_policies for select to authenticated
 using(public.is_reviewer() or association_id=(select association_id from public.profiles where id=auth.uid()));
revoke all on public.ranking_policies from anon,authenticated;
grant select on public.ranking_policies to authenticated;

-- Internal validators cannot be called through the browser API.
create or replace function public.sport_reference(record_key text, expected_kind text, owner_key text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare value jsonb;
begin
 select published_payload into value from public.sport_records
 where id=record_key::uuid and kind=expected_kind and association_id=owner_key and status<>'Archived';
 if value is null then raise exception 'An MNCS-approved % from this association is required',expected_kind; end if;
 return value;
end $$;
revoke all on function public.sport_reference(text,text,text) from public,anon,authenticated;

create or replace function public.validate_sport_record(record_key uuid,owner_key text,record_kind text,value jsonb) returns void
language plpgsql security definer set search_path=public as $$
declare competition jsonb; participant jsonb; fixture jsonb; policy public.ranking_policies; date_value date; stamp timestamptz;
begin
 if value is null or jsonb_typeof(value)<>'object' or octet_length(value::text)>20000 then raise exception 'Invalid sports record'; end if;
 if record_kind in ('Athlete','Team','Competition') then
  if coalesce(length(trim(value->>'name')),0) not between 1 and 160
   or coalesce(length(trim(value->>'discipline')),0) not between 1 and 100
   or coalesce(length(trim(value->>'category')),0) not between 1 and 100 then raise exception 'Name, discipline and category are required'; end if;
 end if;
 if record_kind='Athlete' then
  if value->>'gender' is null or value->>'gender' not in ('Male','Female','Other') then raise exception 'Select an athlete gender'; end if;
  if coalesce(value->>'dateOfBirth','')<>'' then
   date_value=(value->>'dateOfBirth')::date;
   if date_value>current_date or date_value<'1900-01-01' then raise exception 'Invalid date of birth'; end if;
  end if;
  if jsonb_typeof(value->'consentPublic') is distinct from 'boolean' then raise exception 'Record the public-profile consent decision'; end if;
 elsif record_kind='Competition' then
  if coalesce(value->>'season','') !~ '^[0-9]{4}$' or (value->>'season')::integer not between 2024 and 2100 then raise exception 'Invalid season'; end if;
  if coalesce(value->>'startDate','')='' or coalesce(value->>'endDate','')='' then raise exception 'Competition dates required'; end if;
  if (value->>'endDate')::date<(value->>'startDate')::date then raise exception 'End date must follow start date'; end if;
  if value->>'level' is null or value->>'level' not in ('District','National','Regional','International') then raise exception 'Invalid competition level'; end if;
  if coalesce(value->>'rankingPolicyId','')<>'' then
   select * into policy from public.ranking_policies where id=(value->>'rankingPolicyId')::uuid;
   if policy.id is null or policy.association_id<>owner_key or policy.discipline<>value->>'discipline'
    or policy.category<>value->>'category' or policy.season<>(value->>'season')::integer then raise exception 'Ranking policy must match association, discipline, category and season'; end if;
  end if;
 elsif record_kind in ('Fixture','Result') then
  competition=public.sport_reference(value->>'competitionId','Competition',owner_key);
  if record_kind='Fixture' then
   stamp=(value->>'scheduledAt')::timestamptz;
   if stamp is null or (stamp at time zone 'Africa/Blantyre')::date not between (competition->>'startDate')::date and (competition->>'endDate')::date then raise exception 'Fixture must fall within competition dates'; end if;
   if value->>'fixtureStatus' is null or value->>'fixtureStatus' not in ('Scheduled','Completed','Postponed','Cancelled') then raise exception 'Invalid fixture status'; end if;
   if value->>'fixtureStatus' in ('Cancelled','Postponed') and exists(select 1 from public.sport_records r where r.kind='Result' and r.status<>'Archived' and r.published_payload->>'fixtureId'=record_key::text) then raise exception 'Archive approved fixture results before cancelling or postponing'; end if;
   if value->>'homeTeamId' is null or value->>'awayTeamId' is null or value->>'homeTeamId'=value->>'awayTeamId' then raise exception 'Two different approved teams are required'; end if;
   participant=public.sport_reference(value->>'homeTeamId','Team',owner_key);
   if participant->>'discipline'<>competition->>'discipline' or participant->>'category'<>competition->>'category' then raise exception 'Home team must match discipline and category'; end if;
   participant=public.sport_reference(value->>'awayTeamId','Team',owner_key);
   if participant->>'discipline'<>competition->>'discipline' or participant->>'category'<>competition->>'category' then raise exception 'Away team must match discipline and category'; end if;
   if value->>'fixtureStatus'='Scheduled' and exists(select 1 from public.sport_records r where r.id<>record_key and r.kind='Fixture' and r.association_id=owner_key and r.status<>'Archived'
    and r.published_payload->>'fixtureStatus'='Scheduled' and (r.published_payload->>'scheduledAt')::timestamptz=stamp
    and (r.published_payload->>'homeTeamId' in (value->>'homeTeamId',value->>'awayTeamId') or r.published_payload->>'awayTeamId' in (value->>'homeTeamId',value->>'awayTeamId'))) then raise exception 'A team already has a fixture at this time'; end if;
  else
   if (coalesce(value->>'athleteId','')='')=(coalesce(value->>'teamId','')='') then raise exception 'Choose exactly one athlete or team'; end if;
   participant=public.sport_reference(coalesce(nullif(value->>'athleteId',''),value->>'teamId'),case when coalesce(value->>'athleteId','')<>'' then 'Athlete' else 'Team' end,owner_key);
   if participant->>'discipline'<>competition->>'discipline' or participant->>'category'<>competition->>'category' then raise exception 'Participant must match competition discipline and category'; end if;
   if value->>'outcome' is null or value->>'outcome' not in ('Placed','Won','Lost','Draw','DNS','DNF','Disqualified') then raise exception 'Invalid result outcome'; end if;
   if value->>'outcome'='Placed' and (coalesce(value->>'position','') !~ '^[1-9][0-9]{0,4}$') then raise exception 'Placed results require a positive placing'; end if;
   if value->>'outcome'<>'Placed' and coalesce(value->>'position','')<>'' then raise exception 'Only placed results can carry a ranking position'; end if;
   if coalesce(length(trim(value->>'evidenceNote')),0) not between 1 and 1000 then raise exception 'An official result evidence reference is required'; end if;
   if coalesce(value->>'medal','') not in ('','Gold','Silver','Bronze') or (coalesce(value->>'medal','')<>'' and value->>'outcome'<>'Placed') then raise exception 'A medal must be explicitly recorded for a placed result'; end if;
   date_value=(value->>'resultDate')::date;
   if date_value is null or date_value not between (competition->>'startDate')::date and (competition->>'endDate')::date or date_value>current_date then raise exception 'Result date must be within the competition and cannot be in the future'; end if;
   if coalesce(value->>'fixtureId','')<>'' then
    fixture=public.sport_reference(value->>'fixtureId','Fixture',owner_key);
    if fixture->>'competitionId'<>value->>'competitionId' or fixture->>'fixtureStatus' in ('Cancelled','Postponed') then raise exception 'Invalid result fixture'; end if;
    if coalesce(value->>'teamId','')<>'' and value->>'teamId' not in (fixture->>'homeTeamId',fixture->>'awayTeamId') then raise exception 'Team must be a participant in the fixture'; end if;
   end if;
   if exists(select 1 from public.sport_records r where r.id<>record_key and r.kind='Result' and r.association_id=owner_key and r.status<>'Archived' and r.published_payload is not null
    and r.published_payload->>'competitionId'=value->>'competitionId'
    and coalesce(r.published_payload->>'athleteId','')=coalesce(value->>'athleteId','')
    and coalesce(r.published_payload->>'teamId','')=coalesce(value->>'teamId','')
    and coalesce(r.published_payload->>'fixtureId','')=coalesce(value->>'fixtureId','')) then raise exception 'A result already exists for this participant and competition/fixture'; end if;
  end if;
 else if record_kind not in ('Athlete','Team') then raise exception 'Invalid sports record type'; end if;
 end if;
end $$;
revoke all on function public.validate_sport_record(uuid,text,text,jsonb) from public,anon,authenticated;

create or replace function public.save_sport_record(record_id uuid,owner_id text,record_kind text,new_payload jsonb) returns uuid
language plpgsql security definer set search_path=public as $$
declare p public.profiles; s public.sport_records; key uuid=coalesce(record_id,gen_random_uuid());
begin
 select * into p from public.profiles where id=auth.uid();
 if p.id is null or p.role not in ('admin','association') or (p.role='association' and p.association_id is distinct from owner_id) then raise exception 'Own association representative or MNCS administrator required'; end if;
 if not exists(select 1 from public.registry where collection='associations' and id=owner_id) then raise exception 'Association not found'; end if;
 perform pg_advisory_xact_lock(hashtextextended(owner_id,909));
 select * into s from public.sport_records where id=key for update;
 if record_id is not null and s.id is null then raise exception 'Record not found'; end if;
 if s.id is not null and (s.association_id<>owner_id or s.kind<>record_kind or s.status not in ('Draft','Returned','Approved')) then raise exception 'This record cannot be edited'; end if;
 -- Approved identities stay stable so dependent results do not change ranking pools.
 if s.published_payload is not null and record_kind in ('Athlete','Team','Competition') and
  (s.published_payload->>'discipline' is distinct from new_payload->>'discipline' or s.published_payload->>'category' is distinct from new_payload->>'category'
   or (record_kind='Competition' and (s.published_payload->>'season' is distinct from new_payload->>'season' or s.published_payload->>'rankingPolicyId' is distinct from new_payload->>'rankingPolicyId'
    or s.published_payload->>'startDate' is distinct from new_payload->>'startDate' or s.published_payload->>'endDate' is distinct from new_payload->>'endDate'))) then raise exception 'Approved discipline/category/competition dates and scoring rule are fixed; create a new record for a different competition or category'; end if;
 perform public.validate_sport_record(key,owner_id,record_kind,new_payload);
 if s.published_payload is not null and record_kind='Fixture' and
  (s.published_payload->>'competitionId' is distinct from new_payload->>'competitionId'
   or s.published_payload->>'homeTeamId' is distinct from new_payload->>'homeTeamId'
   or s.published_payload->>'awayTeamId' is distinct from new_payload->>'awayTeamId') then raise exception 'Approved fixture participants are fixed; create a new fixture'; end if;
 insert into public.sport_records(id,association_id,kind,payload,created_by,updated_by,history)
 values(key,owner_id,record_kind,new_payload,p.id,p.id,jsonb_build_array(jsonb_build_object('action','Draft saved','actor',p.id,'at',now())))
 on conflict(id) do update set payload=new_payload,status='Draft',updated_by=p.id,updated_at=now(),review_comment='',
 history=sport_records.history||jsonb_build_array(jsonb_build_object('action','Draft edited','previousPayload',sport_records.payload,'actor',p.id,'at',now()));
 return key;
end $$;
revoke all on function public.save_sport_record(uuid,text,text,jsonb) from public,anon;
grant execute on function public.save_sport_record(uuid,text,text,jsonb) to authenticated;

create or replace function public.publish_sport_record(record_key uuid) returns void
language plpgsql security definer set search_path=public as $$
declare s public.sport_records; v jsonb; data jsonb; collection_name text; participant jsonb; competition jsonb; related record;
begin
 select * into s from public.sport_records where id=record_key;
 v=s.published_payload;
 if s.kind='Athlete' then
  collection_name='players';
  if v->>'consentPublic'='true' then
   data=jsonb_build_object('id',s.id,'associationId',s.association_id,'firstName',v->>'name','lastName','','gender',v->>'gender','position',v->>'discipline','category',v->>'category','club',v->>'club','district',v->>'district','status','Active','registrationDate',s.created_at::date,'nationalTeam',false);
  else delete from public.registry where collection='players' and id=s.id::text;
  end if;
 elsif s.kind='Competition' then
  collection_name='events';
  data=jsonb_build_object('id',s.id,'associationId',s.association_id,'name',v->>'name','type',v->>'discipline','category',v->>'category','level',v->>'level','startDate',v->>'startDate','endDate',v->>'endDate','venue',v->>'venue','description',v->>'description','status','Approved');
 elsif s.kind='Result' then
  collection_name='results';competition=public.sport_reference(v->>'competitionId','Competition',s.association_id);
  participant=public.sport_reference(coalesce(nullif(v->>'athleteId',''),v->>'teamId'),case when coalesce(v->>'athleteId','')<>'' then 'Athlete' else 'Team' end,s.association_id);
  data=jsonb_build_object('id',s.id,'associationId',s.association_id,'playerId',nullif(v->>'athleteId',''),'eventId',v->>'competitionId','category',competition->>'category','position',nullif(v->>'position','')::integer,'performance',v->>'mark','unit',v->>'unit','outcome',v->>'outcome','resultDate',v->>'resultDate','teamName',case when coalesce(v->>'teamId','')<>'' then participant->>'name' when participant->>'consentPublic'<>'true' then 'Private athlete' else null end,'medal',nullif(v->>'medal',''));
 end if;
 if data is not null then insert into public.registry(collection,id,payload) values(collection_name,s.id::text,data) on conflict(collection,id) do update set payload=excluded.payload; end if;
 -- Propagate consent/name corrections to public result labels.
 if s.kind in ('Athlete','Team') then
  for related in select id from public.sport_records where kind='Result' and published_payload is not null and status<>'Archived' and (published_payload->>'athleteId'=s.id::text or published_payload->>'teamId'=s.id::text)
  loop perform public.publish_sport_record(related.id); end loop;
 end if;
end $$;
revoke all on function public.publish_sport_record(uuid) from public,anon,authenticated;

create or replace function public.transition_sport_record(record_id uuid,next_status text,comment text default '') returns void
language plpgsql security definer set search_path=public as $$
declare p public.profiles; s public.sport_records; owner_key text;
begin
 select * into p from public.profiles where id=auth.uid();
 if p.id is null then raise exception 'Authorised account required'; end if;
 select association_id into owner_key from public.sport_records where id=record_id;
 if owner_key is null then raise exception 'Record not found'; end if;
 perform pg_advisory_xact_lock(hashtextextended(owner_key,909));
 select * into s from public.sport_records where id=record_id for update;
 if next_status='Submitted' then
  if p.role not in ('admin','association') or (p.role='association' and p.association_id is distinct from s.association_id) or s.status not in ('Draft','Returned') then raise exception 'Cannot submit this sports record'; end if;
 elsif next_status in ('Approved','Returned') then
  if p.role not in ('admin','reviewer') or s.status<>'Submitted' then raise exception 'MNCS review of a submitted record required'; end if;
 elsif next_status='Archived' then
  if p.role not in ('admin','reviewer') or s.status='Archived' then raise exception 'MNCS reviewer required'; end if;
  if exists(select 1 from public.sport_records r where r.id<>s.id and r.status<>'Archived' and
   (r.payload->>'competitionId'=s.id::text or r.payload->>'fixtureId'=s.id::text or r.payload->>'athleteId'=s.id::text or r.payload->>'teamId'=s.id::text or r.payload->>'homeTeamId'=s.id::text or r.payload->>'awayTeamId'=s.id::text
    or r.published_payload->>'competitionId'=s.id::text or r.published_payload->>'fixtureId'=s.id::text or r.published_payload->>'athleteId'=s.id::text or r.published_payload->>'teamId'=s.id::text or r.published_payload->>'homeTeamId'=s.id::text or r.published_payload->>'awayTeamId'=s.id::text)) then raise exception 'Archive dependent records first'; end if;
 else raise exception 'Invalid review action'; end if;
 if next_status in ('Returned','Archived') and coalesce(length(trim(comment)),0)=0 then raise exception 'A reason is required'; end if;
 if length(coalesce(comment,''))>3000 then raise exception 'Comment too long'; end if;
 if next_status in ('Submitted','Approved') then perform public.validate_sport_record(s.id,s.association_id,s.kind,s.payload); end if;
 update public.sport_records set status=next_status,review_comment=coalesce(comment,''),updated_by=p.id,updated_at=now(),
 published_payload=case when next_status='Approved' then payload when next_status='Archived' then null else published_payload end,
 history=history||jsonb_build_array(jsonb_build_object('action',next_status,'comment',comment,'actor',p.id,'at',now())) where id=s.id;
 if next_status='Approved' then perform public.publish_sport_record(s.id); end if;
 if next_status='Archived' then delete from public.registry where id=s.id::text and collection in ('players','events','results'); end if;
end $$;
revoke all on function public.transition_sport_record(uuid,text,text) from public,anon;
grant execute on function public.transition_sport_record(uuid,text,text) to authenticated;

create or replace function public.create_ranking_policy(owner_id text,policy_name text,sport_discipline text,division text,season_year integer,points jsonb,count_limit integer) returns uuid
language plpgsql security definer set search_path=public as $$
declare key uuid; v jsonb; previous numeric=1000000; n numeric;
begin
 if not public.is_admin() then raise exception 'MNCS administrator required'; end if;
 if not exists(select 1 from public.registry where collection='associations' and id=owner_id) then raise exception 'Association not found'; end if;
 if points is null or jsonb_typeof(points)<>'array' or jsonb_array_length(points) not between 1 and 20 then raise exception 'Provide points for 1 to 20 placings'; end if;
 for v in select value from jsonb_array_elements(points) loop
  if jsonb_typeof(v)<>'number' then raise exception 'Points must be numbers'; end if;
  n=v::text::numeric;
  if n<0 or n>100000 or n>previous then raise exception 'Points must be nonnegative and descending by place'; end if;
  previous=n;
 end loop;
 insert into public.ranking_policies(association_id,name,discipline,category,season,placing_points,max_results,created_by)
 values(owner_id,trim(policy_name),trim(sport_discipline),trim(division),season_year,points,count_limit,auth.uid()) returning id into key;
 return key;
end $$;
revoke all on function public.create_ranking_policy(text,text,text,text,integer,jsonb,integer) from public,anon;
grant execute on function public.create_ranking_policy(text,text,text,text,integer,jsonb,integer) to authenticated;

-- One best placing per athlete per competition. Best N competition scores count.
-- Equal totals share competition rank (1, 1, 3); names only sort the display.
create or replace function public.sport_rankings() returns table(policy_id uuid,association_id text,policy_name text,discipline text,category text,season integer,athlete_id uuid,athlete_name text,total_points numeric,counted_results bigint,available_results bigint,rank bigint)
language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from public.profiles where id=auth.uid()) then raise exception 'Authorised account required'; end if;
 return query
 with eligible as (
  select rp.id pid,rp.association_id aid,rp.name pname,rp.discipline disc,rp.category cat,rp.season yr,rp.max_results lim,
   a.id athlete,a.published_payload->>'name' aname,c.id competition,
   coalesce((rp.placing_points->>((r.published_payload->>'position')::integer-1))::numeric,0) pts
  from public.sport_records r
  join public.sport_records a on a.id=(nullif(r.published_payload->>'athleteId',''))::uuid and a.kind='Athlete' and a.published_payload is not null and a.status<>'Archived'
  join public.sport_records c on c.id=(r.published_payload->>'competitionId')::uuid and c.kind='Competition' and c.published_payload is not null and c.status<>'Archived'
  join public.ranking_policies rp on rp.id=(nullif(c.published_payload->>'rankingPolicyId',''))::uuid
  where r.kind='Result' and r.published_payload is not null and r.status<>'Archived' and r.published_payload->>'outcome'='Placed'
   and (public.is_reviewer() or r.association_id=(select p.association_id from public.profiles p where p.id=auth.uid()))
 ), competitions as (
  select pid,aid,pname,disc,cat,yr,lim,athlete,aname,competition,max(pts) pts from eligible group by pid,aid,pname,disc,cat,yr,lim,athlete,aname,competition
 ), ordered as (
  select *,row_number() over(partition by pid,athlete order by pts desc,competition) seq from competitions
 ), totals as (
  select pid,aid,pname,disc,cat,yr,athlete,aname,sum(pts) filter(where seq<=lim) total,count(*) filter(where seq<=lim) counted,count(*) available
  from ordered group by pid,aid,pname,disc,cat,yr,athlete,aname
 ) select pid,aid,pname,disc,cat,yr,athlete,aname,total,counted,available,rank() over(partition by pid order by total desc) from totals order by yr desc,pname,total desc,aname;
end $$;
revoke all on function public.sport_rankings() from public,anon;
grant execute on function public.sport_rankings() to authenticated;

create or replace function public.public_fixtures() returns setof jsonb
language sql stable security definer set search_path=public as $$
 select jsonb_build_object('id',f.id,'associationId',f.association_id,'competition',c.published_payload->>'name','homeTeam',h.published_payload->>'name','awayTeam',a.published_payload->>'name','scheduledAt',f.published_payload->>'scheduledAt','venue',f.published_payload->>'venue','stage',f.published_payload->>'stage','status',f.published_payload->>'fixtureStatus')
 from public.sport_records f
 join public.sport_records c on c.id=(f.published_payload->>'competitionId')::uuid and c.published_payload is not null
 join public.sport_records h on h.id=(f.published_payload->>'homeTeamId')::uuid and h.published_payload is not null
 join public.sport_records a on a.id=(f.published_payload->>'awayTeamId')::uuid and a.published_payload is not null
 where f.kind='Fixture' and f.published_payload is not null and f.status<>'Archived'
 order by (f.published_payload->>'scheduledAt')::timestamptz;
$$;
revoke all on function public.public_fixtures() from public;
grant execute on function public.public_fixtures() to anon,authenticated;

-- MNCS controls opening/closing nomination submission independently of voting.
alter table public.award_cycles add column if not exists nomination_status text not null default 'Closed' check(nomination_status in ('Open','Closed'));
create or replace function public.validate_award_cycle_open() returns trigger
language plpgsql security definer set search_path=public as $$
declare athlete jsonb;
begin
 if new.kind='Award nomination' and new.status='Submitted' and (tg_op='INSERT' or old.status is distinct from 'Submitted') then
  if not exists(select 1 from public.award_cycles where year=new.period::integer and nomination_status='Open') then raise exception 'MNCS must open nominations for this awards year'; end if;
  if coalesce(new.payload->>'athleteId','')<>'' then
   athlete=public.sport_reference(new.payload->>'athleteId','Athlete',new.association_id);
   if athlete->>'name' is distinct from new.payload->>'nomineeName' or coalesce(athlete->>'dateOfBirth','') is distinct from coalesce(new.payload->>'dateOfBirth','') then raise exception 'Registered nominee name and birth date must match the athlete master record'; end if;
  end if;
 end if;
 return new;
end $$;
revoke all on function public.validate_award_cycle_open() from public,anon,authenticated;
drop trigger if exists validate_award_cycle_open on public.submissions;
create trigger validate_award_cycle_open before insert or update on public.submissions for each row execute function public.validate_award_cycle_open();

-- Component: v1.0-migration.sql
-- V1.0: association-owned operations, council oversight, awards and tournaments.
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check(role in ('admin','reviewer','association','judge','auditor','fan'));
alter table public.submissions drop constraint if exists submissions_kind_check;
alter table public.submissions add constraint submissions_kind_check check(kind in ('Profile update','Constitution','AGM minutes','Strategic plan','Annual report','Award nomination','Funding request','Travel abroad','MRA clearance','Other request'));
drop index if exists public.unique_current_submission;
create unique index if not exists unique_current_submission on public.submissions(association_id,kind,period) where status in ('Draft','Submitted','Approved') and kind not in ('Award nomination','Funding request','Travel abroad','MRA clearance','Other request');

create or replace function public.save_sport_record(record_id uuid,owner_id text,record_kind text,new_payload jsonb) returns uuid
language plpgsql security definer set search_path=public as $$
declare p public.profiles; s public.sport_records; key uuid=coalesce(record_id,gen_random_uuid());
begin
 select * into p from public.profiles where id=auth.uid();
 if p.id is null or p.role not in ('admin','association') or (p.role='association' and p.association_id is distinct from owner_id) then raise exception 'Own association representative or MNCS administrator required'; end if;
 if not exists(select 1 from public.registry where collection='associations' and id=owner_id) then raise exception 'Association not found'; end if;
 perform pg_advisory_xact_lock(hashtextextended(owner_id,909));
 select * into s from public.sport_records where id=key for update;
 if record_id is not null and s.id is null then raise exception 'Record not found'; end if;
 if s.id is not null and (s.association_id<>owner_id or s.kind<>record_kind or (s.status not in ('Draft','Returned','Approved') and not (record_kind<>'Competition' and s.status='Submitted'))) then raise exception 'This record cannot be edited'; end if;
 -- Approved identities stay stable so dependent results do not change ranking pools.
 if s.published_payload is not null and record_kind in ('Athlete','Team','Competition') and
  (s.published_payload->>'discipline' is distinct from new_payload->>'discipline' or s.published_payload->>'category' is distinct from new_payload->>'category'
   or (record_kind='Competition' and (s.published_payload->>'season' is distinct from new_payload->>'season' or s.published_payload->>'rankingPolicyId' is distinct from new_payload->>'rankingPolicyId'
    or s.published_payload->>'startDate' is distinct from new_payload->>'startDate' or s.published_payload->>'endDate' is distinct from new_payload->>'endDate'))) then raise exception 'Approved discipline/category/competition dates and scoring rule are fixed; create a new record for a different competition or category'; end if;
 perform public.validate_sport_record(key,owner_id,record_kind,new_payload);
 if s.published_payload is not null and record_kind='Fixture' and
  (s.published_payload->>'competitionId' is distinct from new_payload->>'competitionId'
   or s.published_payload->>'homeTeamId' is distinct from new_payload->>'homeTeamId'
   or s.published_payload->>'awayTeamId' is distinct from new_payload->>'awayTeamId') then raise exception 'Approved fixture participants are fixed; create a new fixture'; end if;
 insert into public.sport_records(id,association_id,kind,payload,created_by,updated_by,history)
 values(key,owner_id,record_kind,new_payload,p.id,p.id,jsonb_build_array(jsonb_build_object('action','Draft saved','actor',p.id,'at',now())))
 on conflict(id) do update set payload=new_payload,status='Draft',updated_by=p.id,updated_at=now(),review_comment='',
 history=sport_records.history||jsonb_build_array(jsonb_build_object('action','Draft edited','previousPayload',sport_records.payload,'actor',p.id,'at',now()));
 if record_kind<>'Competition' then
  update public.sport_records set status='Approved',published_payload=payload where id=key;
  perform public.publish_sport_record(key);
  update public.registry set payload=payload||jsonb_build_object('recordSource','Association-reported') where id=key::text and collection in ('players','results');
 end if;
 return key;
end $$;
create or replace function public.transition_sport_record(record_id uuid,next_status text,comment text default '') returns void
language plpgsql security definer set search_path=public as $$
declare p public.profiles; s public.sport_records; owner_key text;
begin
 select * into p from public.profiles where id=auth.uid();
 if p.id is null then raise exception 'Authorised account required'; end if;
 select association_id into owner_key from public.sport_records where id=record_id;
 if owner_key is null then raise exception 'Record not found'; end if;
 perform pg_advisory_xact_lock(hashtextextended(owner_key,909));
 select * into s from public.sport_records where id=record_id for update;
 if s.kind<>'Competition' and next_status<>'Archived' then raise exception 'Association records are saved directly; only competitions go to MNCS'; end if;
 if next_status='Submitted' then
  if p.role not in ('admin','association') or (p.role='association' and p.association_id is distinct from s.association_id) or s.status not in ('Draft','Returned') then raise exception 'Cannot submit this sports record'; end if;
 elsif next_status in ('Approved','Returned') then
  if p.role not in ('admin','reviewer') or s.status<>'Submitted' then raise exception 'MNCS review of a submitted record required'; end if;
 elsif next_status='Archived' then
  if (s.kind='Competition' and p.role not in ('admin','reviewer')) or (s.kind<>'Competition' and p.role<>'admin' and (p.role<>'association' or p.association_id is distinct from s.association_id)) or s.status='Archived' then raise exception 'MNCS reviewer required'; end if;
  if exists(select 1 from public.sport_records r where r.id<>s.id and r.status<>'Archived' and
   (r.payload->>'competitionId'=s.id::text or r.payload->>'fixtureId'=s.id::text or r.payload->>'athleteId'=s.id::text or r.payload->>'teamId'=s.id::text or r.payload->>'homeTeamId'=s.id::text or r.payload->>'awayTeamId'=s.id::text
    or r.published_payload->>'competitionId'=s.id::text or r.published_payload->>'fixtureId'=s.id::text or r.published_payload->>'athleteId'=s.id::text or r.published_payload->>'teamId'=s.id::text or r.published_payload->>'homeTeamId'=s.id::text or r.published_payload->>'awayTeamId'=s.id::text)) then raise exception 'Archive dependent records first'; end if;
 else raise exception 'Invalid review action'; end if;
 if next_status in ('Returned','Archived') and coalesce(length(trim(comment)),0)=0 then raise exception 'A reason is required'; end if;
 if length(coalesce(comment,''))>3000 then raise exception 'Comment too long'; end if;
 if next_status in ('Submitted','Approved') then perform public.validate_sport_record(s.id,s.association_id,s.kind,s.payload); end if;
 update public.sport_records set status=next_status,review_comment=coalesce(comment,''),updated_by=p.id,updated_at=now(),
 published_payload=case when next_status='Approved' then payload when next_status='Archived' then null else published_payload end,
 history=history||jsonb_build_array(jsonb_build_object('action',next_status,'comment',comment,'actor',p.id,'at',now())) where id=s.id;
 if next_status='Approved' then perform public.publish_sport_record(s.id); end if;
 if next_status='Archived' then delete from public.registry where id=s.id::text and collection in ('players','events','results'); end if;
end $$;
create or replace function public.create_ranking_policy(owner_id text,policy_name text,sport_discipline text,division text,season_year integer,points jsonb,count_limit integer) returns uuid
language plpgsql security definer set search_path=public as $$
declare key uuid; v jsonb; previous numeric=1000000; n numeric;
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and (role='admin' or (role='association' and association_id=owner_id))) then raise exception 'Association representative or administrator required'; end if;
 if not exists(select 1 from public.registry where collection='associations' and id=owner_id) then raise exception 'Association not found'; end if;
 if points is null or jsonb_typeof(points)<>'array' or jsonb_array_length(points) not between 1 and 20 then raise exception 'Provide points for 1 to 20 placings'; end if;
 for v in select value from jsonb_array_elements(points) loop
  if jsonb_typeof(v)<>'number' then raise exception 'Points must be numbers'; end if;
  n=v::text::numeric;
  if n<0 or n>100000 or n>previous then raise exception 'Points must be nonnegative and descending by place'; end if;
  previous=n;
 end loop;
 insert into public.ranking_policies(association_id,name,discipline,category,season,placing_points,max_results,created_by)
 values(owner_id,trim(policy_name),trim(sport_discipline),trim(division),season_year,points,count_limit,auth.uid()) returning id into key;
 return key;
end $$;

-- Assigned officials have separate roles and no general council permissions.
create table if not exists public.award_categories (
 year integer not null references public.award_cycles(year), category text not null,
 rubric jsonb not null, rubric_approved boolean not null default false,
 minimum_judges integer not null default 5 check(minimum_judges between 1 and 7),
 phase text not null default 'Preparing' check(phase in ('Preparing','Judging','Auditing','Published')),
 finalists_public boolean not null default false,
 poll_status text not null default 'Closed' check(poll_status in ('Open','Closed')),
 primary key(year,category)
);
create table if not exists public.award_assignments (
 year integer not null,category text not null,user_id uuid not null references public.profiles(id),
 duty text not null check(duty in ('judge','auditor')),
 primary key(year,category,user_id),
 foreign key(year,category) references public.award_categories(year,category)
);
create table if not exists public.award_candidates (
 id uuid primary key default gen_random_uuid(),year integer not null,category text not null,
 nomination_id uuid not null references public.submissions(id),
 nominee_name text not null,association_id text not null,public_consent boolean not null,
 unique(year,category,nomination_id),foreign key(year,category) references public.award_categories(year,category)
);
create table if not exists public.award_ballots (
 candidate_id uuid not null references public.award_candidates(id),judge_id uuid not null references public.profiles(id),
 scores jsonb not null,score numeric not null check(score between 0 and 100),
 rationale text not null,conflict_free boolean not null check(conflict_free),submitted_at timestamptz not null default now(),
 primary key(candidate_id,judge_id)
);
create table if not exists public.award_fan_votes (
 year integer not null,category text not null,candidate_id uuid not null references public.award_candidates(id),
 voter_id uuid not null references auth.users(id),email_hash text not null,created_at timestamptz not null default now(),
 primary key(year,category,voter_id),unique(year,category,email_hash)
);
create table if not exists public.award_audits (
 year integer not null,category text not null,snapshot jsonb not null,fingerprint text not null,
 certified_by uuid not null references public.profiles(id),certified_at timestamptz not null default now(),
 statement text not null,primary key(year,category)
);
create table if not exists public.award_log (
 id uuid primary key default gen_random_uuid(),year integer not null,category text not null,
 actor uuid not null references auth.users(id),action text not null,details jsonb not null default '{}',at timestamptz not null default now()
);
alter table public.award_categories enable row level security;
alter table public.award_assignments enable row level security;
alter table public.award_candidates enable row level security;
alter table public.award_ballots enable row level security;
alter table public.award_fan_votes enable row level security;
alter table public.award_audits enable row level security;
alter table public.award_log enable row level security;
revoke all on public.award_categories,public.award_assignments,public.award_candidates,public.award_ballots,public.award_fan_votes,public.award_audits,public.award_log from anon,authenticated;
grant select on public.award_categories to anon,authenticated;
grant select on public.award_assignments,public.award_candidates,public.award_ballots,public.award_audits,public.award_log to authenticated;
drop policy if exists award_category_read on public.award_categories;
create policy award_category_read on public.award_categories for select using(true);
create or replace function public.is_award_official(y integer,c text,d text default null) returns boolean
language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.award_assignments a join public.profiles p on p.id=a.user_id where a.year=y and a.category=c and a.user_id=auth.uid() and (d is null or a.duty=d) and p.role=a.duty);
$$;
revoke all on function public.is_award_official(integer,text,text) from public,anon;
grant execute on function public.is_award_official(integer,text,text) to authenticated;
drop policy if exists assignment_read on public.award_assignments;
create policy assignment_read on public.award_assignments for select to authenticated using(public.is_admin() or user_id=auth.uid());
drop policy if exists candidate_read on public.award_candidates;
create policy candidate_read on public.award_candidates for select to authenticated using(public.is_reviewer() or public.is_award_official(year,category) or association_id=(select association_id from public.profiles where id=auth.uid() and role='association'));
drop policy if exists ballot_read on public.award_ballots;
create policy ballot_read on public.award_ballots for select to authenticated using(judge_id=auth.uid() or exists(select 1 from public.award_candidates c join public.award_categories g on g.year=c.year and g.category=c.category where c.id=candidate_id and g.phase in ('Auditing','Published') and (public.is_admin() or public.is_award_official(c.year,c.category,'auditor'))));
drop policy if exists audit_read on public.award_audits;
create policy audit_read on public.award_audits for select to authenticated using(public.is_admin() or public.is_award_official(year,category,'auditor'));
drop policy if exists award_log_read on public.award_log;
create policy award_log_read on public.award_log for select to authenticated using(public.is_admin() or public.is_award_official(year,category,'auditor'));
drop policy if exists nomination_official_read on public.submissions;
create policy nomination_official_read on public.submissions for select to authenticated using(exists(select 1 from public.award_candidates c where c.nomination_id=submissions.id and public.is_award_official(c.year,c.category)));
drop policy if exists award_pdf_read on storage.objects;
create policy award_pdf_read on storage.objects for select to authenticated using(bucket_id='association-documents' and exists(select 1 from public.submissions s join public.award_candidates c on c.nomination_id=s.id where s.document_path=name and public.is_award_official(c.year,c.category)));

create or replace function public.configure_award_category(y integer,c text,criteria jsonb,quorum integer) returns void
language plpgsql security definer set search_path=public as $$
declare v jsonb;total numeric=0;
begin
 if not public.is_admin() then raise exception 'MNCS administrator required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(y::text||c,1001));
 if exists(select 1 from public.award_categories where year=y and category=c and phase<>'Preparing') then raise exception 'Rules are locked once judging starts'; end if;
 if c not in ('junior-male','junior-female','national-team','association','development-programme','sportsman','sportswoman','disability-male','disability-female','coach','administrator','journalist-print','journalist-electronic','personality') then raise exception 'Unknown award category'; end if;
 if criteria is null or jsonb_typeof(criteria)<>'array' or jsonb_array_length(criteria) not between 1 and 20 then raise exception 'Add judging criteria'; end if;
 for v in select value from jsonb_array_elements(criteria) loop
  if coalesce(length(trim(v->>'label')),0) not between 1 and 300 or jsonb_typeof(v->'weight')<>'number' or (v->>'weight')::numeric<=0 or (v->>'weight')::numeric>100 then raise exception 'Each criterion needs a label and positive weight'; end if;
  total=total+(v->>'weight')::numeric;
 end loop;
 if total<>100 then raise exception 'Criterion weights must total 100'; end if;
 insert into public.award_categories(year,category,rubric,rubric_approved,minimum_judges) values(y,c,criteria,true,quorum)
 on conflict(year,category) do update set rubric=criteria,rubric_approved=true,minimum_judges=quorum;
 insert into public.award_log(year,category,actor,action,details) values(y,c,auth.uid(),'Rubric approved',jsonb_build_object('rubric',criteria,'quorum',quorum,'tieRule','Joint winners on equal scores'));
end $$;
revoke all on function public.configure_award_category(integer,text,jsonb,integer) from public,anon;
grant execute on function public.configure_award_category(integer,text,jsonb,integer) to authenticated;

create or replace function public.assign_award_official(y integer,c text,official_id uuid,official_duty text) returns void
language plpgsql security definer set search_path=public as $$
begin
 if not public.is_admin() then raise exception 'MNCS administrator required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(y::text||c,1001));
 if not exists(select 1 from public.award_categories where year=y and category=c and phase='Preparing') then raise exception 'Assignments lock when judging starts'; end if;
 if official_duty not in ('judge','auditor') or not exists(select 1 from public.profiles where id=official_id and role=official_duty) then raise exception 'Select an account with the matching judge or auditor role'; end if;
 insert into public.award_assignments(year,category,user_id,duty) values(y,c,official_id,official_duty);
 insert into public.award_log(year,category,actor,action,details) values(y,c,auth.uid(),'Official assigned',jsonb_build_object('user',official_id,'duty',official_duty));
end $$;
revoke all on function public.assign_award_official(integer,text,uuid,text) from public,anon;
grant execute on function public.assign_award_official(integer,text,uuid,text) to authenticated;

create or replace function public.shortlist_award(y integer,c text,nomination uuid,consent_confirmed boolean) returns void
language plpgsql security definer set search_path=public as $$
declare s public.submissions;
begin
 if not public.is_admin() then raise exception 'MNCS administrator required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(y::text||c,1001));
 if consent_confirmed is distinct from true then raise exception 'Confirm permission to publish the finalist name'; end if;
 if not exists(select 1 from public.award_categories where year=y and category=c and phase='Preparing') then raise exception 'Configure this category first; shortlist locks when judging starts'; end if;
 select * into s from public.submissions where id=nomination and kind='Award nomination' and status='Approved' and period=y::text;
 if s.id is null then raise exception 'An eligibility-approved nomination is required'; end if;
 if c='personality' then
  if s.payload->>'categoryId' not in ('junior-male','junior-female','sportsman','sportswoman','disability-male','disability-female') or not exists(select 1 from public.award_audits a,jsonb_array_elements(a.snapshot->'results') r where a.year=y and r->>'nominationId'=nomination::text and (r->>'rank')::integer=1) then raise exception 'Personality finalists must be certified winners of individual athlete categories'; end if;
 else if s.payload->>'categoryId'<>c then raise exception 'Nomination belongs to another category'; end if;
 end if;
 if (select count(*) from public.award_candidates where year=y and category=c)>=3 then raise exception 'A category can have up to three finalists'; end if;
 insert into public.award_candidates(year,category,nomination_id,nominee_name,association_id,public_consent) values(y,c,nomination,s.payload->>'nomineeName',s.association_id,true);
 insert into public.award_log(year,category,actor,action,details) values(y,c,auth.uid(),'Finalist shortlisted',jsonb_build_object('nomination',nomination));
end $$;
revoke all on function public.shortlist_award(integer,text,uuid,boolean) from public,anon;
grant execute on function public.shortlist_award(integer,text,uuid,boolean) to authenticated;

create or replace function public.set_award_phase(y integer,c text,next_phase text) returns void
language plpgsql security definer set search_path=public as $$
declare g public.award_categories; cycle public.award_cycles; judges integer; candidates integer;
begin
 if not public.is_admin() then raise exception 'MNCS administrator required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(y::text||c,1001));
 select * into g from public.award_categories where year=y and category=c for update;
 select * into cycle from public.award_cycles where year=y;
 if next_phase='Judging' and g.phase='Preparing' then
  if cycle.scoring_policy<>'judges_only' or not cycle.amendment_approved or not cycle.policy_disclosed or not g.rubric_approved then raise exception 'Approve and disclose the judges-only policy and category rubric first'; end if;
  select count(*) into judges from public.award_assignments where year=y and category=c and duty='judge';
  select count(*) into candidates from public.award_candidates where year=y and category=c;
  if judges<g.minimum_judges or candidates=0 then raise exception 'Add finalists and the required judges before opening judging'; end if;
  if not exists(select 1 from public.award_assignments where year=y and category=c and duty='auditor') then raise exception 'Assign an independent auditor before opening judging'; end if;
 elsif next_phase='Auditing' and g.phase='Judging' then
  if exists(select 1 from public.award_candidates ca join public.award_assignments j on j.year=ca.year and j.category=ca.category and j.duty='judge' where ca.year=y and ca.category=c and not exists(select 1 from public.award_ballots b where b.candidate_id=ca.id and b.judge_id=j.user_id)) then raise exception 'Every assigned judge must submit a ballot for every finalist'; end if;
 elsif next_phase='Published' and g.phase='Auditing' then
  if not exists(select 1 from public.award_audits where year=y and category=c) or g.poll_status<>'Closed' then raise exception 'Independent certification and a closed fan poll are required'; end if;
 else raise exception 'Invalid awards transition'; end if;
 update public.award_categories set phase=next_phase where year=y and category=c;
 insert into public.award_log(year,category,actor,action) values(y,c,auth.uid(),next_phase);
end $$;
revoke all on function public.set_award_phase(integer,text,text) from public,anon;
grant execute on function public.set_award_phase(integer,text,text) to authenticated;

create or replace function public.submit_award_ballot(candidate uuid,marks jsonb,reason text,no_conflict boolean) returns void
language plpgsql security definer set search_path=public as $$
declare ca public.award_candidates; g public.award_categories; v jsonb; i integer=0; total numeric=0; p public.profiles;
begin
 select * into ca from public.award_candidates where id=candidate;
 if ca.id is null then raise exception 'Finalist not found'; end if;
 perform pg_advisory_xact_lock(hashtextextended(ca.year::text||ca.category,1001));
 select * into g from public.award_categories where year=ca.year and category=ca.category;
 select * into p from public.profiles where id=auth.uid();
 if g.phase<>'Judging' or not public.is_award_official(ca.year,ca.category,'judge') then raise exception 'Assigned judge and open judging required'; end if;
 if no_conflict is distinct from true or p.association_id=ca.association_id then raise exception 'Declare and resolve conflicts of interest before scoring'; end if;
 if coalesce(length(trim(reason)),0) not between 1 and 3000 or marks is null or jsonb_typeof(marks)<>'array' or jsonb_array_length(marks)<>jsonb_array_length(g.rubric) then raise exception 'Complete every criterion and give a rationale'; end if;
 for v in select value from jsonb_array_elements(marks) loop
  if jsonb_typeof(v)<>'number' or v::text::numeric not between 0 and 10 then raise exception 'Criterion marks must be numbers from 0 to 10'; end if;
  total=total+v::text::numeric*(g.rubric->i->>'weight')::numeric/10;i=i+1;
 end loop;
 insert into public.award_ballots(candidate_id,judge_id,scores,score,rationale,conflict_free) values(candidate,auth.uid(),marks,total,trim(reason),true);
 insert into public.award_log(year,category,actor,action,details) values(ca.year,ca.category,auth.uid(),'Ballot sealed',jsonb_build_object('candidate',candidate));
end $$;
revoke all on function public.submit_award_ballot(uuid,jsonb,text,boolean) from public,anon;
grant execute on function public.submit_award_ballot(uuid,jsonb,text,boolean) to authenticated;

create or replace function public.certify_award(y integer,c text,audit_statement text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare g public.award_categories; results jsonb; ballots jsonb; snap jsonb; fingerprint text;
begin
 perform pg_advisory_xact_lock(hashtextextended(y::text||c,1001));
 select * into g from public.award_categories where year=y and category=c;
 if g.phase<>'Auditing' or not public.is_award_official(y,c,'auditor') then raise exception 'Assigned independent auditor and closed judging required'; end if;
 if exists(select 1 from public.award_ballots b join public.award_candidates ca on ca.id=b.candidate_id where ca.year=y and ca.category=c and b.judge_id=auth.uid()) then raise exception 'An auditor cannot certify their own ballots'; end if;
 if coalesce(length(trim(audit_statement)),0) not between 20 and 3000 then raise exception 'Provide an audit statement of 20 to 3000 characters'; end if;
 if exists(select 1 from public.award_candidates ca join public.award_assignments j on j.year=ca.year and j.category=ca.category and j.duty='judge' where ca.year=y and ca.category=c and not exists(select 1 from public.award_ballots b where b.candidate_id=ca.id and b.judge_id=j.user_id)) then raise exception 'Incomplete ballots'; end if;
 select jsonb_agg(jsonb_build_object('candidateId',id,'nominationId',nomination_id,'name',nominee_name,'associationId',association_id,'score',score,'rank',rank,'ballots',ranked.ballots) order by rank,id) into results from (
  select ca.id,ca.nomination_id,ca.nominee_name,ca.association_id,avg(b.score) score,count(*) ballots,rank() over(order by avg(b.score) desc) rank
  from public.award_candidates ca join public.award_ballots b on b.candidate_id=ca.id where ca.year=y and ca.category=c group by ca.id
 ) ranked;
 select jsonb_agg(jsonb_build_object('candidateId',b.candidate_id,'judgeId',b.judge_id,'marks',b.scores,'score',b.score,'rationale',b.rationale,'at',b.submitted_at) order by b.candidate_id,b.judge_id) into ballots from public.award_ballots b join public.award_candidates ca on ca.id=b.candidate_id where ca.year=y and ca.category=c;
 if results is null then raise exception 'No completed results'; end if;
 snap=jsonb_build_object('year',y,'category',c,'rubric',g.rubric,'policy','judges_only','fanWeight',0,'tieRule','Joint winners on equal scores','results',results,'ballots',ballots);
 fingerprint=encode(sha256(convert_to(snap::text,'UTF8')),'hex');
 insert into public.award_audits(year,category,snapshot,fingerprint,certified_by,statement) values(y,c,snap,fingerprint,auth.uid(),trim(audit_statement));
 insert into public.award_log(year,category,actor,action,details) values(y,c,auth.uid(),'Independently certified',jsonb_build_object('fingerprint',fingerprint));
 return jsonb_build_object('fingerprint',fingerprint,'results',results);
end $$;
revoke all on function public.certify_award(integer,text,text) from public,anon;
grant execute on function public.certify_award(integer,text,text) to authenticated;

create or replace function public.set_fan_poll(y integer,c text,opened boolean) returns void
language plpgsql security definer set search_path=public as $$
begin
 if not public.is_admin() then raise exception 'MNCS administrator required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(y::text||c,1001));
 if not exists(select 1 from public.award_categories g join public.award_cycles cy on cy.year=g.year where g.year=y and g.category=c and g.phase in ('Judging','Auditing') and cy.scoring_policy='judges_only' and cy.amendment_approved and cy.policy_disclosed) then raise exception 'Open judging under the approved disclosed policy first'; end if;
 if opened and (select count(*) from public.award_candidates where year=y and category=c)<2 then raise exception 'A fan poll needs at least two finalists'; end if;
 update public.award_categories set poll_status=case when opened then 'Open' else 'Closed' end,finalists_public=true where year=y and category=c;
 insert into public.award_log(year,category,actor,action) values(y,c,auth.uid(),case when opened then 'Fan poll opened' else 'Fan poll closed' end);
end $$;
revoke all on function public.set_fan_poll(integer,text,boolean) from public,anon;
grant execute on function public.set_fan_poll(integer,text,boolean) to authenticated;

create or replace function public.cast_fan_vote(candidate uuid) returns void
language plpgsql security definer set search_path=public as $$
declare ca public.award_candidates; mail text; confirmed timestamptz;
begin
 select * into ca from public.award_candidates where id=candidate;
 if ca.id is null then raise exception 'Finalist not found'; end if;
 perform pg_advisory_xact_lock(hashtextextended(ca.year::text||ca.category,1001));
 if not exists(select 1 from public.award_categories where year=ca.year and category=ca.category and poll_status='Open' and finalists_public and phase<>'Published') then raise exception 'Fan poll is closed'; end if;
 select email,email_confirmed_at into mail,confirmed from auth.users where id=auth.uid();
 if mail is null or confirmed is null then raise exception 'Sign in with a verified email before voting'; end if;
 insert into public.award_fan_votes(year,category,candidate_id,voter_id,email_hash) values(ca.year,ca.category,candidate,auth.uid(),encode(sha256(convert_to(lower(trim(mail)),'UTF8')),'hex'));
end $$;
revoke all on function public.cast_fan_vote(uuid) from public,anon;
grant execute on function public.cast_fan_vote(uuid) to authenticated;

create or replace function public.public_awards() returns setof jsonb
language sql stable security definer set search_path=public as $$
 select jsonb_build_object('year',g.year,'category',g.category,'phase',g.phase,'pollStatus',g.poll_status,'policy','Judges decide official awards; fan poll is separate','rubric',g.rubric,
 'candidates',(select coalesce(jsonb_agg(jsonb_build_object('id',ca.id,'name',ca.nominee_name,'associationId',ca.association_id,'votes',case when g.phase='Published' and g.poll_status='Closed' then (select count(*) from public.award_fan_votes v where v.candidate_id=ca.id) else null end) order by ca.nominee_name),'[]'::jsonb) from public.award_candidates ca where ca.year=g.year and ca.category=g.category),
 'results',case when g.phase='Published' then a.snapshot->'results' else null end,'fingerprint',case when g.phase='Published' then a.fingerprint else null end,'certifiedAt',case when g.phase='Published' then a.certified_at else null end)
 from public.award_categories g left join public.award_audits a on a.year=g.year and a.category=g.category where g.finalists_public or g.phase='Published';
$$;
revoke all on function public.public_awards() from public;
grant execute on function public.public_awards() to anon,authenticated;

-- Tournament schedules are association work, generated only for an accepted competition.
create table if not exists public.tournaments (
 id uuid primary key default gen_random_uuid(),competition_id uuid not null unique references public.sport_records(id),
 association_id text not null,format text not null check(format in ('Round robin','Knockout')),
 starts_at timestamptz not null,gap_minutes integer not null check(gap_minutes between 15 and 1440),
 venue text not null,created_by uuid not null references auth.users(id),created_at timestamptz not null default now()
);
create table if not exists public.tournament_matches (
 id uuid primary key default gen_random_uuid(),tournament_id uuid not null references public.tournaments(id),
 round integer not null,slot integer not null,home_team uuid references public.sport_records(id),away_team uuid references public.sport_records(id),
 home_source uuid references public.tournament_matches(id),away_source uuid references public.tournament_matches(id),
 fixture_id uuid references public.sport_records(id),winner uuid references public.sport_records(id),scheduled_at timestamptz not null,
 unique(tournament_id,round,slot)
);
alter table public.tournaments enable row level security;
alter table public.tournament_matches enable row level security;
revoke all on public.tournaments,public.tournament_matches from anon,authenticated;
grant select on public.tournaments,public.tournament_matches to authenticated;
drop policy if exists tournament_read on public.tournaments;
create policy tournament_read on public.tournaments for select to authenticated using(public.is_reviewer() or association_id=(select association_id from public.profiles where id=auth.uid()));
drop policy if exists tournament_match_read on public.tournament_matches;
create policy tournament_match_read on public.tournament_matches for select to authenticated using(exists(select 1 from public.tournaments t where t.id=tournament_id and (public.is_reviewer() or t.association_id=(select association_id from public.profiles where id=auth.uid()))));
create or replace function public.generate_tournament(competition uuid,team_ids uuid[],format_name text,first_start timestamptz,minutes_between integer,ground text) returns uuid
language plpgsql security definer set search_path=public as $$
declare c public.sport_records;p public.profiles;key uuid=gen_random_uuid();n integer;teams uuid[];previous uuid[];current_matches uuid[];i integer;j integer;r integer;slot integer=0;fixture uuid;match uuid;stamp timestamptz;v jsonb;participant jsonb;
begin
 select * into c from public.sport_records where id=competition and kind='Competition' and published_payload is not null and status<>'Archived';
 select * into p from public.profiles where id=auth.uid();
 if c.id is null or p.id is null or (p.role<>'admin' and (p.role<>'association' or p.association_id is distinct from c.association_id)) then raise exception 'Own association and an accepted competition required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(c.association_id,909));
 n=coalesce(array_length(team_ids,1),0);
 if n not between 2 and 32 or (select count(distinct x) from unnest(team_ids) x)<>n or minutes_between is null or minutes_between not between 15 and 1440 or first_start is null or coalesce(length(trim(ground)),0) not between 1 and 160 then raise exception 'Choose 2 to 32 distinct teams, a start time, venue and valid interval'; end if;
 if format_name not in ('Round robin','Knockout') or (format_name='Knockout' and n not in (2,4,8,16,32)) then raise exception 'Knockout requires 2, 4, 8, 16 or 32 teams; otherwise choose round robin'; end if;
 foreach match in array team_ids loop
  participant=public.sport_reference(match::text,'Team',c.association_id);
  if participant->>'discipline'<>c.published_payload->>'discipline' or participant->>'category'<>c.published_payload->>'category' then raise exception 'Teams must match competition discipline and category'; end if;
 end loop;
 -- Check the entire schedule before committing, including future knockout rounds.
 stamp=first_start+make_interval(mins=>minutes_between*(case when format_name='Round robin' then n*(n-1)/2 else n-1 end-1));
 if (first_start at time zone 'Africa/Blantyre')::date<(c.published_payload->>'startDate')::date or (stamp at time zone 'Africa/Blantyre')::date>(c.published_payload->>'endDate')::date then raise exception 'The whole schedule must fit within competition dates'; end if;
 if exists(select 1 from public.sport_records f where f.kind='Fixture' and f.status<>'Archived' and f.payload->>'competitionId'=competition::text) then raise exception 'This competition already has fixtures; use another competition or manage its existing schedule'; end if;
 insert into public.tournaments(id,competition_id,association_id,format,starts_at,gap_minutes,venue,created_by) values(key,c.id,c.association_id,format_name,first_start,minutes_between,trim(ground),p.id);
 if format_name='Round robin' then
  teams=team_ids;if n%2=1 then teams=array_append(teams,null::uuid);n=n+1;end if;
  for r in 1..n-1 loop
   for i in 1..n/2 loop
    if teams[i] is not null and teams[n+1-i] is not null then
     slot=slot+1;stamp=first_start+make_interval(mins=>minutes_between*(slot-1));
     v=jsonb_build_object('competitionId',competition,'homeTeamId',teams[i],'awayTeamId',teams[n+1-i],'scheduledAt',stamp,'fixtureStatus','Scheduled','venue',ground,'stage','Round '||r,'tournamentId',key);
     fixture=public.save_sport_record(null,c.association_id,'Fixture',v);
     insert into public.tournament_matches(tournament_id,round,slot,home_team,away_team,fixture_id,scheduled_at) values(key,r,i,teams[i],teams[n+1-i],fixture,stamp);
    end if;
   end loop;
   teams=array[teams[1],teams[n]]||teams[2:n-1];
  end loop;
 else
  previous='{}'::uuid[];
  for i in 1..n/2 loop
   slot=slot+1;stamp=first_start+make_interval(mins=>minutes_between*(slot-1));
   v=jsonb_build_object('competitionId',competition,'homeTeamId',team_ids[2*i-1],'awayTeamId',team_ids[2*i],'scheduledAt',stamp,'fixtureStatus','Scheduled','venue',ground,'stage','Round 1','tournamentId',key);
   fixture=public.save_sport_record(null,c.association_id,'Fixture',v);
   insert into public.tournament_matches(tournament_id,round,slot,home_team,away_team,fixture_id,scheduled_at) values(key,1,i,team_ids[2*i-1],team_ids[2*i],fixture,stamp) returning id into match;
   previous=array_append(previous,match);
  end loop;
  r=1;
  while array_length(previous,1)>1 loop
   r=r+1;current_matches='{}'::uuid[];
   for i in 1..array_length(previous,1)/2 loop
    slot=slot+1;stamp=first_start+make_interval(mins=>minutes_between*(slot-1));
    insert into public.tournament_matches(tournament_id,round,slot,home_source,away_source,scheduled_at) values(key,r,i,previous[2*i-1],previous[2*i],stamp) returning id into match;
    current_matches=array_append(current_matches,match);
   end loop;
   previous=current_matches;
  end loop;
 end if;
 return key;
end $$;
revoke all on function public.generate_tournament(uuid,uuid[],text,timestamptz,integer,text) from public,anon;
grant execute on function public.generate_tournament(uuid,uuid[],text,timestamptz,integer,text) to authenticated;

create or replace function public.advance_tournament(match_id uuid,winning_team uuid) returns void
language plpgsql security definer set search_path=public as $$
declare m public.tournament_matches;t public.tournaments;p public.profiles;parent public.tournament_matches;home uuid;away uuid;fixture uuid;
begin
 select * into m from public.tournament_matches where id=match_id;
 select * into t from public.tournaments where id=m.tournament_id;
 select * into p from public.profiles where id=auth.uid();
 if t.id is null or t.format<>'Knockout' or p.id is null or (p.role<>'admin' and (p.role<>'association' or p.association_id is distinct from t.association_id)) then raise exception 'Own association knockout match required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(t.association_id,909));
 select * into m from public.tournament_matches where id=match_id for update;
 if m.winner is not null or winning_team is null or winning_team not in (m.home_team,m.away_team) then raise exception 'Choose a participant in an undecided match'; end if;
 if not exists(select 1 from public.sport_records r where r.kind='Result' and r.status<>'Archived' and r.published_payload->>'fixtureId'=m.fixture_id::text and r.published_payload->>'teamId'=winning_team::text and (r.published_payload->>'outcome'='Won' or (r.published_payload->>'outcome'='Placed' and r.published_payload->>'position'='1'))) then raise exception 'Save the winning team result first'; end if;
 update public.tournament_matches set winner=winning_team where id=m.id;
 update public.sport_records set payload=payload||jsonb_build_object('fixtureStatus','Completed'),published_payload=published_payload||jsonb_build_object('fixtureStatus','Completed'),history=history||jsonb_build_array(jsonb_build_object('action','Winner advanced','winner',winning_team,'actor',p.id,'at',now())) where id=m.fixture_id;
 for parent in select * from public.tournament_matches where tournament_id=t.id and (home_source=m.id or away_source=m.id) loop
  select winner into home from public.tournament_matches where id=parent.home_source;
  select winner into away from public.tournament_matches where id=parent.away_source;
  update public.tournament_matches set home_team=home,away_team=away where id=parent.id;
  if home is not null and away is not null and parent.fixture_id is null then
   fixture=public.save_sport_record(null,t.association_id,'Fixture',jsonb_build_object('competitionId',t.competition_id,'homeTeamId',home,'awayTeamId',away,'scheduledAt',parent.scheduled_at,'fixtureStatus','Scheduled','venue',t.venue,'stage','Round '||parent.round,'tournamentId',t.id));
   update public.tournament_matches set fixture_id=fixture where id=parent.id;
  end if;
 end loop;
end $$;
revoke all on function public.advance_tournament(uuid,uuid) from public,anon;
grant execute on function public.advance_tournament(uuid,uuid) to authenticated;

create or replace function public.publish_sport_record(record_key uuid) returns void
language plpgsql security definer set search_path=public as $$
declare s public.sport_records; v jsonb; data jsonb; collection_name text; participant jsonb; competition jsonb; related record;
begin
 select * into s from public.sport_records where id=record_key;
 v=s.published_payload;
 if s.kind='Athlete' then
  collection_name='players';
  if v->>'consentPublic'='true' then
   data=jsonb_build_object('id',s.id,'associationId',s.association_id,'firstName',v->>'name','lastName','','gender',v->>'gender','position',v->>'discipline','category',v->>'category','club',v->>'club','district',v->>'district','status','Active','registrationDate',s.created_at::date,'nationalTeam',false);
  else delete from public.registry where collection='players' and id=s.id::text;
  end if;
 elsif s.kind='Competition' then
  collection_name='events';
  data=jsonb_build_object('id',s.id,'associationId',s.association_id,'name',v->>'name','type',v->>'discipline','category',v->>'category','level',v->>'level','startDate',v->>'startDate','endDate',v->>'endDate','venue',v->>'venue','description',v->>'description','status','Approved');
 elsif s.kind='Result' then
  collection_name='results';competition=public.sport_reference(v->>'competitionId','Competition',s.association_id);
  participant=public.sport_reference(coalesce(nullif(v->>'athleteId',''),v->>'teamId'),case when coalesce(v->>'athleteId','')<>'' then 'Athlete' else 'Team' end,s.association_id);
  data=jsonb_build_object('id',s.id,'associationId',s.association_id,'playerId',nullif(v->>'athleteId',''),'eventId',v->>'competitionId','category',competition->>'category','position',nullif(v->>'position','')::integer,'performance',v->>'mark','unit',v->>'unit','outcome',v->>'outcome','resultDate',v->>'resultDate','teamName',case when coalesce(v->>'teamId','')<>'' then participant->>'name' when participant->>'consentPublic'<>'true' then 'Private athlete' else null end,'medal',nullif(v->>'medal',''));
 end if;
 if data is not null then data=data||jsonb_build_object('recordSource',case when s.kind='Competition' then 'MNCS-accepted competition' else 'Association-reported' end);insert into public.registry(collection,id,payload) values(collection_name,s.id::text,data) on conflict(collection,id) do update set payload=excluded.payload; end if;
 -- Propagate consent/name corrections to public result labels.
 if s.kind in ('Athlete','Team') then
  for related in select id from public.sport_records where kind='Result' and published_payload is not null and status<>'Archived' and (published_payload->>'athleteId'=s.id::text or published_payload->>'teamId'=s.id::text)
  loop perform public.publish_sport_record(related.id); end loop;
 end if;
end $$;

-- A public voting profile can never acquire operational authority.
create or replace function public.register_fan_profile() returns void
language plpgsql security definer set search_path=public as $$
declare mail text;
begin
 select email into mail from auth.users where id=auth.uid() and email_confirmed_at is not null;
 if mail is null then raise exception 'Verify your email first'; end if;
 insert into public.profiles(id,role,email,display_name) values(auth.uid(),'fan',mail,'Sports fan') on conflict(id) do nothing;
end $$;
revoke all on function public.register_fan_profile() from public,anon;
grant execute on function public.register_fan_profile() to authenticated;

-- Council requests are independent, repeatable cases; supporting PDFs are optional.
drop policy if exists submission_create on public.submissions;
drop policy if exists submission_create on public.submissions;
create policy submission_create on public.submissions for insert to authenticated with check(
 created_by=auth.uid() and status='Draft' and history='[]'::jsonb and review_comment is null
 and association_id=(select association_id from public.profiles where id=auth.uid() and role='association')
 and (document_path is null or document_path=association_id||'/'||id::text||'.pdf')
 and (kind in ('Profile update','Funding request','Travel abroad','MRA clearance','Other request') or document_path is not null)
);
create or replace function public.validate_council_request() returns trigger
language plpgsql set search_path=public as $$
begin
 if new.kind in ('Funding request','Travel abroad','MRA clearance','Other request') then
  if coalesce(length(trim(new.payload->>'title')),0) not between 1 and 160 or coalesce(length(trim(new.payload->>'summary')),0) not between 1 and 12000 then raise exception 'Add a request title and explanation'; end if;
  if new.kind='Funding request' and (coalesce(new.payload->>'requestedAmount','') !~ '^[0-9]+(\.[0-9]{1,2})?$' or (new.payload->>'requestedAmount')::numeric<=0 or new.payload->>'currency' not in ('MWK','USD','EUR')) then raise exception 'Funding requests need an amount and currency'; end if;
  if new.kind='Travel abroad' and (coalesce(length(trim(new.payload->>'country')),0) not between 1 and 100 or coalesce(new.payload->>'departureDate','')='' or coalesce(new.payload->>'returnDate','')='' or (new.payload->>'returnDate')::date<(new.payload->>'departureDate')::date) then raise exception 'Travel requests need a destination and valid departure/return dates'; end if;
 end if;
 return new;
end $$;
revoke all on function public.validate_council_request() from public,anon,authenticated;
drop trigger if exists validate_council_request on public.submissions;
create trigger validate_council_request before insert or update on public.submissions for each row execute function public.validate_council_request();

create or replace function public.edit_submission(submission_id uuid,new_payload jsonb,new_document_path text default null) returns void
language plpgsql security definer set search_path=public as $$
declare s submissions; p profiles;
begin
 select * into p from profiles where id=auth.uid();
 select * into s from submissions where id=submission_id for update;
 if p.id is null or p.role<>'association' or s.id is null or p.association_id<>s.association_id or s.status not in ('Draft','Returned') then raise exception 'Only your editable drafts or returned records may be changed'; end if;
 if jsonb_typeof(new_payload)<>'object' or octet_length(new_payload::text)>20000 then raise exception 'Invalid profile payload'; end if;
 if coalesce(new_payload->>'termStart','')<>'' and coalesce(new_payload->>'termEnd','')<>'' and (new_payload->>'termEnd')::date<(new_payload->>'termStart')::date then raise exception 'Invalid leadership term'; end if;
 if new_document_path is distinct from s.document_path and new_document_path is not null then
  if left(new_document_path,length(s.association_id)+1)<>s.association_id||'/' or not exists(select 1 from storage.objects where bucket_id='association-documents' and name=new_document_path) then raise exception 'Invalid supporting document'; end if;
 end if;
 if s.kind not in ('Profile update','Funding request','Travel abroad','MRA clearance','Other request') and new_document_path is null then raise exception 'Supporting document required'; end if;
 update submissions set payload=new_payload,document_path=new_document_path,
 history=history||jsonb_build_array(jsonb_build_object('action','Edited','previousPayload',s.payload,'previousDocument',s.document_path,'actor',auth.uid(),'at',now())) where id=submission_id;
end $$;

create or replace function public.lock_award_cycle_policy() returns trigger language plpgsql set search_path=public as $$
begin
 if exists(select 1 from public.award_categories where year=old.year and phase<>'Preparing') and (new.scoring_policy is distinct from old.scoring_policy or new.amendment_approved is distinct from old.amendment_approved or new.policy_disclosed is distinct from old.policy_disclosed) then raise exception 'The scoring policy locks when judging starts'; end if;
 if new.age_reference_date is distinct from old.age_reference_date and exists(select 1 from public.submissions where kind='Award nomination' and period=old.year::text and status in ('Submitted','Approved')) then raise exception 'Age reference date locks after nominations are submitted'; end if;
 return new;
end $$;
revoke all on function public.lock_award_cycle_policy() from public,anon,authenticated;
drop trigger if exists lock_award_cycle_policy on public.award_cycles;
create trigger lock_award_cycle_policy before update on public.award_cycles for each row execute function public.lock_award_cycle_policy();

create or replace function public.remove_award_finalist(candidate uuid) returns void language plpgsql security definer set search_path=public as $$
declare ca public.award_candidates;
begin
 if not public.is_admin() then raise exception 'MNCS administrator required'; end if;
 select * into ca from public.award_candidates where id=candidate;
 if ca.id is null then raise exception 'Finalist not found'; end if;
 perform pg_advisory_xact_lock(hashtextextended(ca.year::text||ca.category,1001));
 if not exists(select 1 from public.award_categories where year=ca.year and category=ca.category and phase='Preparing') then raise exception 'Shortlist is locked'; end if;
 delete from public.award_candidates where id=candidate;
 insert into public.award_log(year,category,actor,action,details) values(ca.year,ca.category,auth.uid(),'Finalist removed',jsonb_build_object('nomination',ca.nomination_id));
end $$;
revoke all on function public.remove_award_finalist(uuid) from public,anon;
grant execute on function public.remove_award_finalist(uuid) to authenticated;

create or replace function public.protect_tournament_results() returns trigger language plpgsql set search_path=public as $$
begin
 if old.kind='Result' and exists(select 1 from public.tournament_matches where fixture_id=nullif(old.published_payload->>'fixtureId','')::uuid and winner is not null) and
  (new.published_payload is null or new.payload->>'teamId' is distinct from old.payload->>'teamId' or new.payload->>'fixtureId' is distinct from old.payload->>'fixtureId' or new.payload->>'outcome' is distinct from old.payload->>'outcome' or new.payload->>'position' is distinct from old.payload->>'position') then raise exception 'This result has advanced a knockout bracket; resolve the bracket before changing the winner'; end if;
 if old.kind='Fixture' and new.published_payload is null and exists(select 1 from public.tournament_matches where fixture_id=old.id) then raise exception 'Generated fixtures belong to the tournament; update their status instead of archiving'; end if;
 return new;
end $$;
revoke all on function public.protect_tournament_results() from public,anon,authenticated;
drop trigger if exists protect_tournament_results on public.sport_records;
create trigger protect_tournament_results before update on public.sport_records for each row execute function public.protect_tournament_results();

create or replace function public.remove_award_official(y integer,c text,official_id uuid) returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.is_admin() then raise exception 'MNCS administrator required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(y::text||c,1001));
 if not exists(select 1 from public.award_categories where year=y and category=c and phase='Preparing') then raise exception 'Assignments are locked'; end if;
 delete from public.award_assignments where year=y and category=c and user_id=official_id;
 insert into public.award_log(year,category,actor,action,details) values(y,c,auth.uid(),'Official removed',jsonb_build_object('official',official_id));
end $$;
revoke all on function public.remove_award_official(integer,text,uuid) from public,anon;
grant execute on function public.remove_award_official(integer,text,uuid) to authenticated;

create or replace function public.check_fixture_winner() returns trigger language plpgsql set search_path=public as $$
begin
 if new.kind='Result' and coalesce(new.payload->>'fixtureId','')<>'' and (new.payload->>'outcome'='Won' or (new.payload->>'outcome'='Placed' and new.payload->>'position'='1')) and exists(
  select 1 from public.sport_records r where r.id<>new.id and r.kind='Result' and r.status<>'Archived' and r.published_payload->>'fixtureId'=new.payload->>'fixtureId' and (r.published_payload->>'outcome'='Won' or (r.published_payload->>'outcome'='Placed' and r.published_payload->>'position'='1'))
 ) then raise exception 'This fixture already has a winning result'; end if;
 return new;
end $$;
revoke all on function public.check_fixture_winner() from public,anon,authenticated;
drop trigger if exists check_fixture_winner on public.sport_records;
create trigger check_fixture_winner before insert or update on public.sport_records for each row execute function public.check_fixture_winner();

-- Component: v1.1-migration.sql
-- V1.1: national registry with independently operated association sites.
create table if not exists public.association_connectors(
 id uuid primary key default gen_random_uuid(),association_id text not null unique,
 name text not null,site_url text not null,token_hash text not null,enabled boolean not null default true,
 created_by uuid not null references auth.users(id),created_at timestamptz not null default now(),
 rotated_at timestamptz not null default now(),last_received_at timestamptz
);
create table if not exists public.association_exchange(
 id uuid primary key default gen_random_uuid(),connector_id uuid not null references public.association_connectors(id),
 association_id text not null,kind text not null check(kind in ('Competition','Performance summary','Annual report','Funding request','Travel abroad','MRA clearance','Other request','Award nomination')),
 external_id text not null,revision integer not null check(revision>0),period text not null,
 payload jsonb not null,payload_hash text not null,source_url text not null,status text not null,
 published_payload jsonb,submission_id uuid references public.submissions(id),review_comment text not null default '',
 history jsonb not null default '[]',received_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 unique(connector_id,kind,external_id)
);
alter table public.association_connectors enable row level security;
alter table public.association_exchange enable row level security;
revoke all on public.association_connectors,public.association_exchange from anon,authenticated;
grant select on public.association_exchange to authenticated;
drop policy if exists exchange_read on public.association_exchange;
drop policy if exists exchange_read on public.association_exchange;
create policy exchange_read on public.association_exchange for select to authenticated using(public.is_reviewer() or association_id=(select association_id from public.profiles where id=auth.uid() and role='association'));

create or replace function public.connector_status() returns setof jsonb language sql stable security definer set search_path=public as $$
 select jsonb_build_object('id',id,'association_id',association_id,'name',name,'site_url',site_url,'enabled',enabled,'last_received_at',last_received_at,'rotated_at',rotated_at)
 from public.association_connectors where public.is_reviewer() or association_id=(select association_id from public.profiles where id=auth.uid() and role='association');
$$;
revoke all on function public.connector_status() from public,anon;
grant execute on function public.connector_status() to authenticated;

create or replace function public.configure_association_connector(owner_id text,website text,connector_name text) returns jsonb language plpgsql security definer set search_path=public as $$
declare secret text;key uuid;
begin
 if not public.is_admin() then raise exception 'MNCS administrator required'; end if;
 if not exists(select 1 from public.registry where collection='associations' and id=owner_id) then raise exception 'Select a registered association'; end if;
 if website !~ '^https://[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]/?$' or length(website)>250 or coalesce(length(trim(connector_name)),0) not between 1 and 120 then raise exception 'Use an HTTPS site origin and connector name'; end if;
 secret=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
 insert into public.association_connectors(association_id,name,site_url,token_hash,created_by)
 values(owner_id,trim(connector_name),rtrim(website,'/'),encode(sha256(convert_to(secret,'UTF8')),'hex'),auth.uid())
 on conflict(association_id) do update set name=excluded.name,site_url=excluded.site_url,token_hash=excluded.token_hash,enabled=true,rotated_at=now(),last_received_at=null returning id into key;
 return jsonb_build_object('connectorId',key,'token',secret,'associationId',owner_id,'siteUrl',rtrim(website,'/'));
end $$;
revoke all on function public.configure_association_connector(text,text,text) from public,anon;
grant execute on function public.configure_association_connector(text,text,text) to authenticated;

create or replace function public.set_connector_enabled(connector uuid,active boolean) returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.is_admin() then raise exception 'MNCS administrator required'; end if;
 update public.association_connectors set enabled=active where id=connector;
 if not found then raise exception 'Connector not found'; end if;
end $$;
revoke all on function public.set_connector_enabled(uuid,boolean) from public,anon;
grant execute on function public.set_connector_enabled(uuid,boolean) to authenticated;

create or replace function public.check_connector(connector uuid,secret text) returns public.association_connectors language plpgsql security definer set search_path=public as $$
declare c public.association_connectors;
begin
 select * into c from public.association_connectors where id=connector and enabled and length(secret)=64 and token_hash=encode(sha256(convert_to(secret,'UTF8')),'hex');
 if c.id is null then raise exception 'Integration credentials invalid or disabled'; end if;
 return c;
end $$;
revoke all on function public.check_connector(uuid,text) from public,anon,authenticated;

create or replace function public.integration_receipts(connector uuid,secret text) returns setof jsonb language plpgsql security definer set search_path=public as $$
declare c public.association_connectors;
begin
 c=public.check_connector(connector,secret);
 return query select jsonb_build_object('id',e.id,'kind',e.kind,'externalId',e.external_id,'revision',e.revision,'status',e.status,'comment',e.review_comment,'submissionId',e.submission_id,'updatedAt',e.updated_at) from public.association_exchange e where e.connector_id=c.id order by updated_at desc limit 500;
end $$;
revoke all on function public.integration_receipts(uuid,text) from public;
grant execute on function public.integration_receipts(uuid,text) to anon,authenticated,service_role;

create or replace function public.receive_association_message(connector uuid,secret text,message jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare c public.association_connectors;e public.association_exchange;s public.submissions;v jsonb;clean jsonb;entry jsonb;leaders jsonb='[]';kind_name text;external_key text;year_text text;rev integer;digest text;key uuid;comp public.association_exchange;field text;
begin
 c=public.check_connector(connector,secret);
 perform pg_advisory_xact_lock(hashtextextended(c.id::text,1101));
 if jsonb_typeof(message)<>'object' or octet_length(message::text)>65536 or message->>'revision' !~ '^[1-9][0-9]{0,8}$' then raise exception 'Invalid integration message'; end if;
 kind_name=message->>'kind';external_key=message->>'externalId';year_text=message->>'period';rev=(message->>'revision')::integer;v=message->'payload';
 if kind_name not in ('Competition','Performance summary','Annual report','Funding request','Travel abroad','MRA clearance','Other request','Award nomination') or coalesce(length(external_key),0) not between 1 and 120 or year_text !~ '^(20)[0-9]{2}$' or year_text not between '2024' and '2100' or jsonb_typeof(v)<>'object' then raise exception 'Invalid message kind, ID, year or payload'; end if;
 if kind_name='Competition' then
  if coalesce(length(trim(v->>'name')),0) not between 1 and 160 or coalesce(v->>'startDate','') !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(v->>'endDate','') !~ '^\d{4}-\d{2}-\d{2}$' or (v->>'endDate')::date<(v->>'startDate')::date then raise exception 'Competition needs a name and valid dates'; end if;
  clean=jsonb_build_object('name',v->>'name','startDate',v->>'startDate','endDate',v->>'endDate','discipline',coalesce(v->>'discipline','Darts'),'category',coalesce(v->>'category','Open'),'level',coalesce(v->>'level','National'),'venue',left(coalesce(v->>'venue',''),160),'description',left(coalesce(v->>'description',''),2000));
 elsif kind_name='Performance summary' then
  select * into comp from public.association_exchange where connector_id=c.id and kind='Competition' and external_id=v->>'competitionExternalId' and published_payload is not null;
  if comp.id is null or comp.period<>year_text then raise exception 'Send the matching competition and obtain council acceptance before sharing performance'; end if;
  clean=jsonb_build_object('competitionExternalId',comp.external_id,'competitionName',comp.published_payload->>'name','season',year_text,'rankingRule',left(coalesce(v->>'rankingRule','Association-reported performance'),500));
  foreach field in array array['teams','athletes','fixtures','completedFixtures'] loop
   if coalesce(v->>field,'') !~ '^[0-9]{1,7}$' then raise exception 'Summary counts must be nonnegative whole numbers'; end if;
   clean=clean||jsonb_build_object(field,(v->>field)::integer);
  end loop;
  if (v->>'completedFixtures')::integer>(v->>'fixtures')::integer then raise exception 'Completed fixtures cannot exceed scheduled fixtures'; end if;
  if coalesce(v->'leaders','[]')<>'[]'::jsonb then
   if coalesce(v->>'publicConsent','')<>'true' or jsonb_typeof(v->'leaders')<>'array' or jsonb_array_length(v->'leaders')>50 then raise exception 'Named leaders need confirmed public permission and at most 50 rows'; end if;
   for entry in select value from jsonb_array_elements(v->'leaders') loop
    if coalesce(length(trim(entry->>'name')),0) not between 1 and 160 or coalesce(entry->>'rank','') !~ '^[1-9][0-9]{0,6}$' then raise exception 'Invalid leader name or rank'; end if;
    leaders=leaders||jsonb_build_array(jsonb_build_object('name',entry->>'name','rank',(entry->>'rank')::integer,'singlesWins',coalesce((entry->>'singlesWins')::integer,0),'doublesWins',coalesce((entry->>'doublesWins')::integer,0),'legDifference',coalesce((entry->>'legDifference')::integer,0),'c180',coalesce((entry->>'c180')::integer,0),'c177',coalesce((entry->>'c177')::integer,0),'highOuts',coalesce((entry->>'highOuts')::integer,0)));
   end loop;
  end if;
  clean=clean||jsonb_build_object('leaders',leaders,'publicConsent',leaders<>'[]'::jsonb,'recordSource','Association-reported');
 else
  if kind_name='Award nomination' then
   if coalesce(length(trim(v->>'nomineeName')),0) not between 1 and 160 or coalesce(v->>'categoryId','') not in ('junior-male','junior-female','national-team','association','development-programme','sportsman','sportswoman','disability-male','disability-female','coach','administrator','journalist-print','journalist-electronic') or coalesce(length(trim(v->>'description')),0) not between 1 and 2000 or coalesce(length(trim(v->>'motivation')),0) not between 1 and 12000 then raise exception 'Complete the nomination category, nominee, description and justification'; end if;
   clean=jsonb_build_object('categoryId',v->>'categoryId','nomineeName',v->>'nomineeName','description',v->>'description','motivation',v->>'motivation','dateOfBirth',coalesce(v->>'dateOfBirth',''));
  else
   if coalesce(length(trim(v->>'title')),0) not between 1 and 160 or coalesce(length(trim(v->>'summary')),0) not between 1 and 12000 then raise exception 'Add a title and explanation'; end if;
   clean=jsonb_build_object('title',v->>'title','summary',v->>'summary');
   if kind_name='Funding request' then
    if coalesce(v->>'requestedAmount','') !~ '^[0-9]+(\.[0-9]{1,2})?$' or (v->>'requestedAmount')::numeric<=0 or coalesce(v->>'currency','') not in ('MWK','USD','EUR') then raise exception 'Funding needs a positive amount and currency'; end if;
    clean=clean||jsonb_build_object('requestedAmount',v->>'requestedAmount','currency',v->>'currency');
   elsif kind_name='Travel abroad' then
    if coalesce(length(trim(v->>'country')),0) not between 1 and 100 or coalesce(v->>'departureDate','') !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(v->>'returnDate','') !~ '^\d{4}-\d{2}-\d{2}$' or (v->>'returnDate')::date<(v->>'departureDate')::date then raise exception 'Travel needs a destination and valid dates'; end if;
    clean=clean||jsonb_build_object('country',v->>'country','departureDate',v->>'departureDate','returnDate',v->>'returnDate');
   end if;
  end if;
 end if;
 if octet_length(clean::text)>20000 then raise exception 'Shared payload is too large'; end if;
 digest=encode(sha256(convert_to(jsonb_build_object('period',year_text,'payload',clean)::text,'UTF8')),'hex');
 select * into e from public.association_exchange where connector_id=c.id and kind=kind_name and external_id=external_key;
 if e.submission_id is not null then select * into s from public.submissions where id=e.submission_id for update; end if;
 select * into e from public.association_exchange where connector_id=c.id and kind=kind_name and external_id=external_key for update;
 if e.id is not null and digest=e.payload_hash and (rev=e.revision or (rev=e.revision+1 and not (e.kind='Competition' and e.status='Returned'))) then update public.association_connectors set last_received_at=now() where id=c.id;return jsonb_build_object('id',e.id,'revision',e.revision,'status',e.status,'duplicate',true); end if;
 if rev<>coalesce(e.revision,0)+1 then raise exception 'Revision conflict; refresh receipts before retrying'; end if;
 if e.id is not null and year_text<>e.period then raise exception 'Use a new external ID for a different reporting year'; end if;
 if e.submission_id is not null and exists(select 1 from public.submissions where id=e.submission_id and status in ('Submitted','Approved')) then raise exception 'This dossier is with council; finish its review before sending a correction'; end if;
 key=coalesce(e.id,gen_random_uuid());
 insert into public.association_exchange(id,connector_id,association_id,kind,external_id,revision,period,payload,payload_hash,source_url,status,history)
 values(key,c.id,c.association_id,kind_name,external_key,rev,year_text,clean,digest,c.site_url,case when kind_name='Competition' then 'Submitted' when kind_name='Performance summary' then 'Received' else 'Ready to complete' end,jsonb_build_array(jsonb_build_object('action','Received','revision',rev,'at',now())))
 on conflict(id) do update set revision=rev,payload=clean,payload_hash=digest,source_url=c.site_url,status=case when kind_name='Competition' then 'Submitted' when kind_name='Performance summary' then 'Received' when e.submission_id is not null then e.status else 'Ready to complete' end,review_comment='',updated_at=now(),history=association_exchange.history||jsonb_build_array(jsonb_build_object('action','Updated from association','revision',rev,'previousPayload',association_exchange.payload,'at',now()));
 if kind_name in ('Funding request','Travel abroad','MRA clearance','Other request') then
  if e.submission_id is null then
   insert into public.submissions(association_id,created_by,kind,period,payload,status,history)
   values(c.association_id,c.created_by,kind_name,year_text,clean||jsonb_build_object('sourceIntegrationId',key),'Submitted',jsonb_build_array(jsonb_build_object('action','Submitted from association site','connector',c.id,'at',now())));
  else
   update public.submissions set payload=clean||jsonb_build_object('sourceIntegrationId',key),status='Submitted',review_comment='',history=history||jsonb_build_array(jsonb_build_object('action','Correction from association site','previousPayload',payload,'connector',c.id,'at',now())) where id=e.submission_id;
  end if;
 end if;
 update public.association_connectors set last_received_at=now() where id=c.id;
 return jsonb_build_object('id',key,'revision',rev,'status',(select status from public.association_exchange where id=key),'duplicate',false);
end $$;
revoke all on function public.receive_association_message(uuid,text,jsonb) from public;
grant execute on function public.receive_association_message(uuid,text,jsonb) to anon,authenticated,service_role;

drop function if exists public.review_shared_competition(uuid,text,text);
create or replace function public.review_shared_competition(message_id uuid,decision text,comment text,expected_revision integer) returns void language plpgsql security definer set search_path=public as $$
declare e public.association_exchange;
begin
 if not public.is_reviewer() then raise exception 'MNCS reviewer required'; end if;
 select * into e from public.association_exchange where id=message_id for update;
 if e.revision is distinct from expected_revision then raise exception 'Competition changed; refresh and review the latest revision'; end if;
 if e.id is null or e.kind<>'Competition' or e.status<>'Submitted' or decision not in ('Approved','Returned') or coalesce(length(comment),0)>3000 or (decision='Returned' and coalesce(length(trim(comment)),0)=0) then raise exception 'Choose an awaiting competition and a valid decision/comment'; end if;
 update public.association_exchange set status=decision,review_comment=coalesce(comment,''),published_payload=case when decision='Approved' then payload else published_payload end,updated_at=now(),history=history||jsonb_build_array(jsonb_build_object('action',decision,'actor',auth.uid(),'comment',comment,'at',now(),'revision',revision)) where id=e.id;
 if decision='Approved' then
  insert into public.registry(collection,id,payload) values('events','exchange-'||e.id::text,e.payload||jsonb_build_object('id','exchange-'||e.id::text,'associationId',e.association_id,'type',e.payload->>'discipline','status','Approved','sourceUrl',e.source_url,'recordSource','MNCS-accepted association competition','sourceRevision',e.revision)) on conflict(collection,id) do update set payload=excluded.payload;
 end if;
end $$;
revoke all on function public.review_shared_competition(uuid,text,text,integer) from public,anon;
grant execute on function public.review_shared_competition(uuid,text,text,integer) to authenticated;

create or replace function public.public_performance_summaries() returns setof jsonb language sql stable security definer set search_path=public as $$
 select jsonb_build_object('associationId',association_id,'year',period,'sourceUrl',source_url,'updatedAt',updated_at,'payload',payload) from public.association_exchange where kind='Performance summary' order by updated_at desc;
$$;
revoke all on function public.public_performance_summaries() from public;
grant execute on function public.public_performance_summaries() to anon,authenticated;

create or replace function public.link_exchange_submission() returns trigger language plpgsql security definer set search_path=public as $$
declare e public.association_exchange;
begin
 if tg_op='UPDATE' and coalesce(old.payload->>'sourceIntegrationId','')<>'' and new.payload->>'sourceIntegrationId' is distinct from old.payload->>'sourceIntegrationId' then raise exception 'An imported dossier retains its source link'; end if;
 if coalesce(new.payload->>'sourceIntegrationId','')='' then return new; end if;
 select * into e from public.association_exchange where id=(new.payload->>'sourceIntegrationId')::uuid for update;
 if e.id is null or e.association_id<>new.association_id or e.kind<>new.kind or e.period<>new.period or (e.submission_id is not null and e.submission_id<>new.id) then raise exception 'The imported case must match your association, kind and year and can create only one dossier'; end if;
 if e.kind='Award nomination' and new.payload->>'categoryId' is distinct from e.payload->>'categoryId' then raise exception 'Keep the imported award category; use a separate nomination for another category'; end if;
 update public.association_exchange set submission_id=new.id,status=new.status,review_comment=coalesce(new.review_comment,''),updated_at=now(),history=history||jsonb_build_array(jsonb_build_object('action','Dossier '||new.status,'submissionId',new.id,'at',now())) where id=e.id;
 return new;
end $$;
revoke all on function public.link_exchange_submission() from public,anon,authenticated;
drop trigger if exists link_exchange_submission on public.submissions;
create trigger link_exchange_submission after insert or update on public.submissions for each row execute function public.link_exchange_submission();

COMMIT;
