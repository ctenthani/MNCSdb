-- MNCS v0.9 COMPLETE INSTALLER
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

COMMIT;
