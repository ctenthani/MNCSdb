-- V1.0: association-owned operations, council oversight, awards and tournaments.
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check(role in ('admin','reviewer','association','judge','auditor','fan'));
alter table public.submissions drop constraint if exists submissions_kind_check;
alter table public.submissions add constraint submissions_kind_check check(kind in ('Profile update','Constitution','AGM minutes','Strategic plan','Annual report','Award nomination','Funding request','Travel abroad','MRA clearance','Other request'));
drop index if exists public.unique_current_submission;
create unique index unique_current_submission on public.submissions(association_id,kind,period) where status in ('Draft','Submitted','Approved') and kind not in ('Award nomination','Funding request','Travel abroad','MRA clearance','Other request');

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
create policy award_category_read on public.award_categories for select using(true);
create or replace function public.is_award_official(y integer,c text,d text default null) returns boolean
language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.award_assignments a join public.profiles p on p.id=a.user_id where a.year=y and a.category=c and a.user_id=auth.uid() and (d is null or a.duty=d) and p.role=a.duty);
$$;
revoke all on function public.is_award_official(integer,text,text) from public,anon;
grant execute on function public.is_award_official(integer,text,text) to authenticated;
create policy assignment_read on public.award_assignments for select to authenticated using(public.is_admin() or user_id=auth.uid());
create policy candidate_read on public.award_candidates for select to authenticated using(public.is_reviewer() or public.is_award_official(year,category) or association_id=(select association_id from public.profiles where id=auth.uid() and role='association'));
create policy ballot_read on public.award_ballots for select to authenticated using(judge_id=auth.uid() or exists(select 1 from public.award_candidates c join public.award_categories g on g.year=c.year and g.category=c.category where c.id=candidate_id and g.phase in ('Auditing','Published') and (public.is_admin() or public.is_award_official(c.year,c.category,'auditor'))));
create policy audit_read on public.award_audits for select to authenticated using(public.is_admin() or public.is_award_official(year,category,'auditor'));
create policy award_log_read on public.award_log for select to authenticated using(public.is_admin() or public.is_award_official(year,category,'auditor'));
create policy nomination_official_read on public.submissions for select to authenticated using(exists(select 1 from public.award_candidates c where c.nomination_id=submissions.id and public.is_award_official(c.year,c.category)));
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
create policy tournament_read on public.tournaments for select to authenticated using(public.is_reviewer() or association_id=(select association_id from public.profiles where id=auth.uid()));
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
