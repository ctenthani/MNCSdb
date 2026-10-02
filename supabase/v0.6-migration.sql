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
create policy award_cycle_read on public.award_cycles for select using(true);
create policy award_cycle_admin on public.award_cycles for all to authenticated using(public.is_admin()) with check(public.is_admin());
create function public.validate_junior_submission() returns trigger language plpgsql security definer set search_path=public as $$
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
