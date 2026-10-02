-- Run AFTER schema.sql. For an existing v0.2 database run only this migration.
create table public.reporting_requirements (
 id uuid primary key default gen_random_uuid(),
 kind text not null check(kind in ('Annual report','AGM minutes','Strategic plan','Constitution')),
 period text not null check(length(trim(period)) between 1 and 80),
 due_date date not null,
 association_id text,
 created_at timestamptz not null default now()
);
create unique index requirement_key on public.reporting_requirements(kind,period,coalesce(association_id,''));
alter table public.reporting_requirements enable row level security;
create policy requirement_read on public.reporting_requirements for select to authenticated
 using(public.is_reviewer() or association_id is null or association_id=(select association_id from profiles where id=auth.uid()));
create policy requirement_create on public.reporting_requirements for insert to authenticated with check(public.is_reviewer());
create function public.edit_submission(submission_id uuid,new_payload jsonb,new_document_path text default null) returns void
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
