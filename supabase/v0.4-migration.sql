-- Run after schema.sql and v0.3-migration.sql. One-time migration.
alter table public.profiles add column display_name text;
alter table public.profiles add column email text;
create function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from profiles where id=auth.uid() and role='admin');
$$;
create policy admin_directory on public.profiles for select to authenticated using(public.is_admin());
create table public.initial_admin_setup (
 id integer primary key check(id=1),
 claim uuid,
 completed boolean not null default false
);
insert into public.initial_admin_setup(id) values(1);
alter table public.initial_admin_setup enable row level security;
-- No browser policy. Claims are managed only by the server using a private key.
create function public.claim_initial_admin(operation_id uuid) returns boolean language plpgsql security definer set search_path=public as $$
begin
 perform 1 from initial_admin_setup where id=1 for update;
 if exists(select 1 from profiles where role='admin') then return false; end if;
 update initial_admin_setup set claim=operation_id where id=1 and claim is null and not completed;
 return found;
end $$;
create function public.release_initial_admin(operation_id uuid) returns void language sql security definer set search_path=public as $$
 update initial_admin_setup set claim=null where id=1 and claim=operation_id and not completed;
$$;
create function public.complete_initial_admin(operation_id uuid,user_id uuid,user_email text,user_name text) returns void language plpgsql security definer set search_path=public as $$
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
