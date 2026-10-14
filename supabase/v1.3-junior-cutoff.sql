-- The agreed junior rule: strictly under 20 on 31 December of the nomination year.
-- Preserve existing decisions. Misconfigured cycles must be corrected by MNCS.
begin;
create or replace function public.guard_junior_cutoff() returns trigger
language plpgsql security definer set search_path=public as $$
declare cutoff date;
begin
 if tg_table_name='award_cycles' then
  if new.age_reference_date is distinct from make_date(new.year,12,31) then raise exception 'Junior cut-off must be 31 December of the awards year'; end if;
 elsif new.kind='Award nomination' and new.status in ('Submitted','Approved') and new.payload->>'categoryId' in ('junior-male','junior-female') then
  select age_reference_date into cutoff from award_cycles where year=new.period::integer;
  if cutoff is distinct from make_date(new.period::integer,12,31) then raise exception 'Junior nominations blocked: ask MNCS to correct the cycle cut-off to 31 December of its awards year'; end if;
 end if;
 return new;
end $$;
revoke all on function public.guard_junior_cutoff() from public,anon,authenticated;
create or replace function public.lock_award_cycle_policy() returns trigger language plpgsql set search_path=public as $$
begin
 if exists(select 1 from public.award_categories where year=old.year and phase<>'Preparing') and (new.scoring_policy is distinct from old.scoring_policy or new.amendment_approved is distinct from old.amendment_approved or new.policy_disclosed is distinct from old.policy_disclosed) then raise exception 'The scoring policy locks when judging starts'; end if;
 if new.age_reference_date is distinct from old.age_reference_date and exists(select 1 from public.submissions where kind='Award nomination' and period=old.year::text and status in ('Submitted','Approved') and payload->>'categoryId' in ('junior-male','junior-female')) then raise exception 'Age reference date locks after junior nominations are submitted'; end if;
 return new;
end $$;
revoke all on function public.lock_award_cycle_policy() from public,anon,authenticated;
drop trigger if exists guard_junior_cycle_cutoff on award_cycles;
create trigger guard_junior_cycle_cutoff before insert or update on award_cycles for each row execute function guard_junior_cutoff();
drop trigger if exists guard_junior_submission_cutoff on submissions;
create trigger guard_junior_submission_cutoff before insert or update on submissions for each row execute function guard_junior_cutoff();
commit;
