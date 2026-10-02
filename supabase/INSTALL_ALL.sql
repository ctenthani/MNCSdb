-- MNCS v0.8 COMPLETE INSTALLER
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
alter table public.submissions add constraint submissions_kind_check check(kind in ('Profile update','Constitution','AGM minutes','Strategic plan','Annual report','Award nomination'));
drop index if exists public.unique_current_submission;
create unique index if not exists unique_current_submission on public.submissions(association_id,kind,period) where status in ('Draft','Submitted','Approved') and kind<>'Award nomination';
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

COMMIT;
