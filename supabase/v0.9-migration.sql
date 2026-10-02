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
