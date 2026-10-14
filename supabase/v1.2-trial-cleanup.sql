-- Explicit trial tags and transactional, recoverable removal. No existing rows are tagged.
begin;
create table if not exists public.trial_tags (
 source text not null check(source in ('submissions','sport_records','association_exchange')),
 record_id uuid not null, tagged_by uuid not null, tagged_at timestamptz not null default now(),
 primary key(source,record_id)
);
create table if not exists public.trial_recovery (
 id uuid primary key default gen_random_uuid(), source text not null, record_id uuid not null,
 row_data jsonb not null, registry_data jsonb not null default '[]', removed_by uuid not null,
 removed_at timestamptz not null default now(), restored_at timestamptz
);
alter table public.trial_tags enable row level security;
alter table public.trial_recovery enable row level security;
revoke all on public.trial_tags,public.trial_recovery from public,anon,authenticated;

create or replace function public.trial_cleanup_list() returns jsonb
language plpgsql security definer set search_path=public as $$
declare rows jsonb; recovery jsonb;
begin
 if not public.is_admin() then raise exception 'MNCS administrator required'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('source',r.source,'id',r.id,'association',r.association_id,'kind',r.kind,'status',r.status,'title',coalesce(r.payload->>'title',r.payload->>'name',r.payload->>'nomineeName',r.payload->>'competitionName',r.kind),'trial',t.record_id is not null,'fingerprint',md5(r.data::text)) order by r.source,r.id),'[]') into rows
 from (select 'submissions' source,id,association_id,kind,status,payload,to_jsonb(s) data from submissions s
 union all select 'sport_records',id,association_id,kind,status,payload,to_jsonb(s) from sport_records s
 union all select 'association_exchange',id,association_id,kind,status,payload,to_jsonb(s) from association_exchange s) r
 left join trial_tags t on t.source=r.source and t.record_id=r.id;
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'source',source,'recordId',record_id,'title',coalesce(row_data->'payload'->>'title',row_data->'payload'->>'name',row_data->'payload'->>'nomineeName',row_data->>'kind'),'removedAt',removed_at) order by removed_at desc),'[]') into recovery from trial_recovery where restored_at is null;
 return jsonb_build_object('records',rows,'recovery',recovery);
end $$;

create or replace function public.tag_trial_record(record_source text,record_key uuid,is_trial boolean) returns void
language plpgsql security definer set search_path=public as $$
declare present boolean;
begin
 if not public.is_admin() then raise exception 'MNCS administrator required'; end if;
 if record_source not in ('submissions','sport_records','association_exchange') then raise exception 'Invalid record source'; end if;
 execute format('select exists(select 1 from public.%I where id=$1)',record_source) into present using record_key;
 if not present then raise exception 'Record not found'; end if;
 if is_trial then insert into trial_tags values(record_source,record_key,auth.uid(),now()) on conflict do nothing;
 else delete from trial_tags where source=record_source and record_id=record_key; end if;
end $$;

create or replace function public.remove_trial_records(selection jsonb) returns integer
language plpgsql security definer set search_path=public as $$
declare item jsonb; snapshot jsonb; projections jsonb; count_removed integer=0; ids text[];
begin
 if not public.is_admin() then raise exception 'MNCS administrator required'; end if;
 if jsonb_typeof(selection)<>'array' or jsonb_array_length(selection) not between 1 and 500 then raise exception 'Select between 1 and 500 trial records'; end if;
 -- Locks stop concurrent source edits during validation and removal.
 lock table submissions,sport_records,association_exchange,registry,trial_tags in share row exclusive mode;
 select array_agg(value->>'id') into ids from jsonb_array_elements(selection);
 -- JSON references have no foreign keys: reject references outside this exact removal set.
 if exists(select 1 from sport_records r where r.id::text<>all(ids) and exists(select 1 from jsonb_array_elements(selection) x where x->>'source'='sport_records' and
  (r.payload->>'competitionId'=x->>'id' or r.payload->>'fixtureId'=x->>'id' or r.payload->>'athleteId'=x->>'id' or r.payload->>'teamId'=x->>'id' or r.payload->>'homeTeamId'=x->>'id' or r.payload->>'awayTeamId'=x->>'id'
   or r.published_payload->>'competitionId'=x->>'id' or r.published_payload->>'fixtureId'=x->>'id' or r.published_payload->>'athleteId'=x->>'id' or r.published_payload->>'teamId'=x->>'id' or r.published_payload->>'homeTeamId'=x->>'id' or r.published_payload->>'awayTeamId'=x->>'id'))) then raise exception 'Linked sport records remain. Include their trial records or keep this record'; end if;
 for item in select value from jsonb_array_elements(selection) order by case value->>'source' when 'association_exchange' then 0 when 'sport_records' then 1 else 2 end loop
  if item->>'source' not in ('submissions','sport_records','association_exchange') or not exists(select 1 from trial_tags where source=item->>'source' and record_id=(item->>'id')::uuid) then raise exception 'Only explicitly marked trial records can be removed'; end if;
  execute format('select to_jsonb(r) from public.%I r where id=$1',item->>'source') into snapshot using (item->>'id')::uuid;
  if snapshot is null or md5(snapshot::text) is distinct from item->>'fingerprint' then raise exception 'Record changed. Refresh and review the removal preview again'; end if;
  if item->>'source'='submissions' and snapshot->>'kind'='Profile update' and snapshot->>'status'='Approved' then raise exception 'Approved association profiles cannot be removed as trial records'; end if;
  select coalesce(jsonb_agg(to_jsonb(r)),'[]') into projections from registry r where collection in ('players','events','results') and id=case when item->>'source'='association_exchange' then 'exchange-'||(item->>'id') when item->>'source'='sport_records' then item->>'id' else '' end;
  insert into trial_recovery(source,record_id,row_data,registry_data,removed_by) values(item->>'source',(item->>'id')::uuid,snapshot,projections,auth.uid());
  execute format('delete from public.%I where id=$1',item->>'source') using (item->>'id')::uuid;
  delete from registry where collection in ('players','events','results') and id=case when item->>'source'='association_exchange' then 'exchange-'||(item->>'id') when item->>'source'='sport_records' then item->>'id' else '' end;
  delete from trial_tags where source=item->>'source' and record_id=(item->>'id')::uuid;
  count_removed=count_removed+1;
 end loop;
 return count_removed;
exception when foreign_key_violation then raise exception 'A linked nomination, award or other record prevents removal. No records were removed';
end $$;

create or replace function public.restore_trial_record(recovery_key uuid) returns void
language plpgsql security definer set search_path=public as $$
declare saved trial_recovery; projection jsonb;
begin
 if not public.is_admin() then raise exception 'MNCS administrator required'; end if;
 select * into saved from trial_recovery where id=recovery_key and restored_at is null for update;
 if saved.id is null then raise exception 'Recovery record not found'; end if;
 if saved.source not in ('submissions','sport_records','association_exchange') then raise exception 'Invalid recovery source'; end if;
 update trial_recovery set restored_at=now() where id=saved.id;
 execute format('insert into public.%I select (jsonb_populate_record(null::public.%I,$1)).*',saved.source,saved.source) using saved.row_data;
 for projection in select value from jsonb_array_elements(saved.registry_data) loop
  insert into registry select (jsonb_populate_record(null::public.registry,projection)).*;
 end loop;
 insert into trial_tags values(saved.source,saved.record_id,auth.uid(),now()) on conflict do nothing;
 update trial_recovery set restored_at=now() where id=saved.id;
exception when unique_violation then raise exception 'An existing record conflicts with this restore. No records were overwritten';
 when foreign_key_violation then raise exception 'Restore linked parent records first. No records were changed';
end $$;
-- Connected senders cannot silently recreate a trial exchange after it was removed.
create or replace function public.guard_removed_trial_exchange() returns trigger
language plpgsql security definer set search_path=public as $$
begin
 if exists(select 1 from trial_recovery where source='association_exchange' and restored_at is null
  and row_data->>'connector_id'=new.connector_id::text and row_data->>'kind'=new.kind and row_data->>'external_id'=new.external_id) then
  raise exception 'This trial exchange was removed by MNCS. Restore it in Trial cleanup before resending';
 end if;
 return new;
end $$;
revoke all on function public.guard_removed_trial_exchange() from public,anon,authenticated;
drop trigger if exists guard_removed_trial_exchange on association_exchange;
create trigger guard_removed_trial_exchange before insert or update on association_exchange for each row execute function guard_removed_trial_exchange();
revoke all on function public.trial_cleanup_list(),public.tag_trial_record(text,uuid,boolean),public.remove_trial_records(jsonb),public.restore_trial_record(uuid) from public,anon;
grant execute on function public.trial_cleanup_list(),public.tag_trial_record(text,uuid,boolean),public.remove_trial_records(jsonb),public.restore_trial_record(uuid) to authenticated;
-- Used only by the authenticated administrator's server function. No browser grant.
create or replace function public.account_deletion_check(target uuid) returns jsonb
language plpgsql security definer set search_path=public as $$
declare constraint_row record; n bigint; blockers jsonb='[]'; managed profiles;
begin
 select * into managed from profiles where id=target;
 if managed.id is null then raise exception 'Managed account not found'; end if;
 if managed.role='admin' then raise exception 'Administrator accounts are protected'; end if;
 for constraint_row in select c.conrelid::regclass relation,a.attname column_name from pg_constraint c
 join pg_attribute a on a.attrelid=c.conrelid and a.attnum=c.conkey[1]
 where c.contype='f' and c.confrelid in ('auth.users'::regclass,'public.profiles'::regclass) and c.conrelid<>'public.profiles'::regclass loop
  execute format('select count(*) from %s where %I=$1',constraint_row.relation,constraint_row.column_name) into n using target;
  if n>0 then blockers=blockers||jsonb_build_array(jsonb_build_object('records',constraint_row.relation::text,'count',n)); end if;
 end loop;
 select count(*) into n from trial_recovery where restored_at is null and row_data::text like '%'||target::text||'%';
 if n>0 then blockers=blockers||jsonb_build_array(jsonb_build_object('records','recoverable trial records','count',n)); end if;
 return jsonb_build_object('profile',to_jsonb(managed),'blockers',blockers);
end $$;
create or replace function public.prepare_account_deletion(target uuid,expected_email text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare checked jsonb;
begin
 perform 1 from profiles where id=target for update;
 checked=account_deletion_check(target);
 if checked->'profile'->>'email' is distinct from expected_email then raise exception 'Account changed. Review deletion again'; end if;
 if jsonb_array_length(checked->'blockers')>0 then raise exception 'Linked records prevent account deletion'; end if;
 delete from profiles where id=target;
 return checked->'profile';
end $$;
revoke all on function public.account_deletion_check(uuid),public.prepare_account_deletion(uuid,text) from public,anon,authenticated;
grant execute on function public.account_deletion_check(uuid),public.prepare_account_deletion(uuid,text) to service_role;
commit;

